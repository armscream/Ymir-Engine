// Engine/src/Tools/asset_converter/mesh_optimize.odin
//
// Vertex cache / fetch / LOD generation pipeline built on top of
// zeux/meshoptimizer. Drives:
//
//   - vertex cache reordering  (meshopt_optimizeVertexCache)
//   - vertex fetch reindexing  (meshopt_optimizeVertexFetch)
//   - overdraw reordering      (meshopt_optimizeOverdraw) -- opt-in
//   - triangle stripification  (meshopt_stripify) -- opt-in
//   - LOD chain generation     (meshopt_simplify, per LOD level)
//
// All functions operate on raw []f32 positions + []u32 indices. The
// caller (bmesh_writer) feeds it data extracted from GLTF and writes
// the resulting vertex/index buffers to disk with the quantization
// step (mesh_quantize.odin) applied.
//
// This pipeline is the only place meshopt is used -- the runtime
// renderer never links meshoptimizer. The .bmesh file is the
// hand-off.

package asset_converter

import "core:c"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"

import meshopt "../../dependencies/meshoptimizer"

Mesh_Opt_Options :: struct {
	vertex_cache_reordering: bool,
	triangle_stripification: bool,
	overdraw_threshold:      f32, // 0 disables overdraw optimization
}

// LOD generation target (relative triangle ratio + error threshold).
LOD_Level :: struct {
	target_ratio:  f32, // 0..1; ratio of original triangle count
	target_error:  f32, // meshopt_simplify target_error (relative)
}

// ============================================================================
// Single-mesh optimization pass (no LOD)
// ============================================================================

// Optimize a triangle list in place: vertex cache + fetch + optional
// stripification. `indices` and `positions` are resliced to the new
// sizes on success. `indices_in` may be reshuffled (the same buffer
// is reused as the destination for cache + fetch optimization).
//
// Returns true on success.
optimize_mesh :: proc(
	indices_in:  []u32,
	positions:   []f32,
	options:     Mesh_Opt_Options,
	allocator := context.allocator,
) -> (
	indices_out: []u32,
	vertices_out: []f32,
	ok: bool,
) {
	if len(indices_in) == 0 || len(positions) == 0 do return nil, nil, false
	if len(indices_in) % 3 != 0 do return nil, nil, false
	if len(positions) % 3 != 0 do return nil, nil, false

	vertex_count := len(positions) / 3

	// -- 1. vertex cache reorder --
	indices := make([dynamic]u32, len(indices_in), allocator)
	defer if !ok { delete(indices) }

	if options.vertex_cache_reordering {
		meshopt.optimizeVertexCache(
			raw_data(indices),
			raw_data(indices_in),
			c.size_t(len(indices_in)),
			c.size_t(vertex_count),
		)
	} else {
		copy(indices[:], indices_in)
	}

	// -- 2. vertex fetch reorder (also compacts) --
	positions_buf := make([dynamic]f32, len(positions), allocator)
	defer if !ok { delete(positions_buf) }

	new_vc := int(meshopt.optimizeVertexFetch(
		raw_data(positions_buf),
		raw_data(indices),
		c.size_t(len(indices)),
		raw_data(positions),
		c.size_t(vertex_count),
		c.size_t(size_of(f32) * 3),
	))

	positions_buf = positions_buf[:new_vc * 3]

	// -- 3. optional overdraw reorder (operates on already cache-ordered indices) --
	if options.overdraw_threshold > 0 {
		over := make([dynamic]u32, len(indices), allocator)
		defer if !ok { delete(over) }
		meshopt.optimizeOverdraw(
			raw_data(over),
			raw_data(indices),
			c.size_t(len(indices)),
			raw_data(positions_buf),
			c.size_t(new_vc),
			c.size_t(size_of(f32) * 3),
			options.overdraw_threshold,
		)
		copy(indices[:], over[:])
		delete(over)
	}

	// -- 4. optional stripification --
	if options.triangle_stripification {
		bound := int(meshopt.stripifyBound(c.size_t(len(indices))))
		strips := make([dynamic]u32, bound, allocator)
		defer if !ok { delete(strips) }
		n := int(meshopt.stripify(
			raw_data(strips),
			raw_data(indices),
			c.size_t(len(indices)),
			c.size_t(new_vc),
			u32(0xFFFFFFFF), // restart index
		))
		// We keep the stripified index buffer as-is; the runtime will
		// issue strip draws. For simplicity we replace indices with
		// the strip output.
		delete(indices)
		indices = make([dynamic]u32, n, allocator)
		copy(indices[:], strips[:n])
		delete(strips)
	}

	indices_out = indices[:]
	vertices_out = positions_buf[:]
	ok = true
	return
}

// ============================================================================
// LOD chain generation
// ============================================================================

// Generates `len(lods)` LOD levels for a mesh. LOD 0 is always the
// original (or optimized) mesh. Each subsequent LOD is produced by
// meshopt_simplify targeting `target_ratio` of the previous level's
// triangle count, with the supplied `target_error`.
//
// Returns a slice of LOD records. The caller is responsible for
// ownership of the returned `lod_indices[i]` slices.
generate_lod_chain :: proc(
	base_indices:  []u32,
	base_positions: []f32,
	lods:          []LOD_Level,
	allocator := context.allocator,
) -> (
	lod_indices: [dynamic][]u32,
	lod_errors:  [dynamic]f32,
	ok: bool,
) {
	lod_indices = make([dynamic][]u32, allocator)
	lod_errors  = make([dynamic]f32, allocator)

	// LOD 0 = base mesh.
	append(&lod_indices, slice.clone(base_indices, allocator))
	append(&lod_errors, 0.0)

	prev_indices := base_indices
	for lod, level in lods {
		if level == 0 do continue // LOD 0 placeholder
		if len(prev_indices) == 0 do break

		target_tris := int(f32(len(prev_indices) / 3) * lod.target_ratio)
		if target_tris < 1 do target_tris = 1

		dst := make([dynamic]u32, len(prev_indices), allocator)
		err: f32
		n := int(meshopt.simplify(
			raw_data(dst),
			raw_data(prev_indices),
			c.size_t(len(prev_indices)),
			raw_data(base_positions),
			c.size_t(len(base_positions) / 3),
			c.size_t(size_of(f32) * 3),
			c.size_t(target_tris * 3),
			lod.target_error,
			0,
			&err,
		))
		if n == 0 {
			log.warnf("[asset_converter] LOD %d simplification returned 0 indices; stopping chain", level + 1)
			delete(dst)
			break
		}

		lod_indices[len(lod_indices)-1] = dst[:n]
		// Append instead of replace so lod_indices[i] stays aligned with lods[i].
		append(&lod_indices, dst[:n])
		append(&lod_errors, err)
		prev_indices = dst[:n]
	}

	ok = true
	return
}

// ============================================================================
// Stats (mostly for the UI summary in the converter modal)
// ============================================================================

Mesh_Stats :: struct {
	acmr: f32, // average cached mesh ratio (0.5..3.0)
	atvr: f32, // average transformed-to-vertex ratio (1.0..6.0)
	overfetch: f32,
	vertex_count: int,
	triangle_count: int,
	index_count: int,
}

compute_mesh_stats :: proc(indices: []u32, positions: []f32, vertex_size_bytes: int) -> Mesh_Stats {
	stats: Mesh_Stats
	stats.triangle_count = len(indices) / 3
	stats.index_count    = len(indices)
	stats.vertex_count   = len(positions) / 3
	if stats.vertex_count == 0 do return stats

	cache := meshopt.analyzeVertexCache(
		raw_data(indices),
		c.size_t(len(indices)),
		c.size_t(stats.vertex_count),
		meshopt.DEFAULT_CACHE_SIZE,
		meshopt.DEFAULT_WARP_SIZE,
		0,
	)
	stats.acmr = cache.acmr
	stats.atvr = cache.atvr

	fetch := meshopt.analyzeVertexFetch(
		raw_data(indices),
		c.size_t(len(indices)),
		c.size_t(stats.vertex_count),
		c.size_t(vertex_size_bytes),
	)
	stats.overfetch = fetch.overfetch

	return stats
}
