package editor

// Asset handling, optimization, and baking helpers for editor workflows.
// Texture baking lives in the shared asset_manager package so runtime can use it too.

import "core:c"
import "core:log"
import am "../asset_manager"
import mo "../Libs/meshoptimizer"

Loaded_Texture :: am.Loaded_Texture
Atlas_Bake_Input :: am.Atlas_Bake_Input

load_texture_from_file :: proc(file_path: string, allocator := context.allocator) -> (tex: Loaded_Texture, ok: bool) {
	return am.load_texture_from_file(file_path, allocator)
}

free_texture :: proc(tex: Loaded_Texture, allocator := context.allocator) {
	am.free_texture(tex, allocator)
}

sample_texture :: proc(tex: Loaded_Texture, u, v: f32) -> [4]u8 {
	return am.sample_texture(tex, u, v)
}

bake_texture_into_atlas :: proc(
	src: Loaded_Texture,
	dst: [^]u8,
	dst_width, dst_height: i32,
	dest_x, dest_y: i32,
	dest_width, dest_height: i32,
) {
	am.bake_texture_into_atlas(
		src,
		dst,
		dst_width, dst_height,
		dest_x, dest_y,
		dest_width, dest_height,
	)
}

bake_atlas_page :: proc(
	inputs: []Atlas_Bake_Input,
	page_width, page_height: i32,
	allocator := context.allocator,
) -> (pixels: [^]u8, ok: bool) {
	return am.bake_atlas_page(inputs, page_width, page_height, allocator)
}

// ============================================================================
// Mesh Optimization with meshoptimizer
// ============================================================================

Mesh_Optimize_Input :: struct {
	name:         string,
	indices:      [dynamic]u32,
	vertices:     [dynamic][3]f32,
	target_ratio: f32,
	lock_borders: bool,
}

optimize_mesh_simplify :: proc(
	input: Mesh_Optimize_Input,
	allocator := context.allocator,
) -> (indices: [dynamic]u32, ok: bool) {
	if len(input.indices) == 0 || len(input.vertices) == 0 {
		return {}, false
	}
	target_count := c.size_t(f32(len(input.indices)) * input.target_ratio)
	target_count = max(target_count, 3)
	indices = make([dynamic]u32, len(input.indices), allocator)
	defer if !ok {
		delete(indices)
	}
	positions := make([dynamic]f32, len(input.vertices) * 3, allocator)
	defer delete(positions)
	for i := 0; i < len(input.vertices); i += 1 {
		v := input.vertices[i]
		positions[i*3 + 0] = v.x
		positions[i*3 + 1] = v.y
		positions[i*3 + 2] = v.z
	}
	options := mo.Simplify_Flags{}
	if input.lock_borders {
		options |= mo.SIMPLIFY_LOCK_BORDER
	}
	lod_indices := mo.simplify(
		raw_data(indices[:]),
		raw_data(input.indices[:]),
		c.size_t(len(input.indices)),
		raw_data(positions[:]),
		c.size_t(len(input.vertices)),
		size_of(f32) * 3,
		target_count,
		0.01,
		options,
		nil,
	)
	if lod_indices == 0 {
		return {}, false
	}
	resize(&indices, int(lod_indices))
	return indices, true
}

optimize_mesh_vertex_cache :: proc(
	indices: [dynamic]u32,
	vertex_count: u32,
	allocator := context.allocator,
) -> (optimized: [dynamic]u32) {
	if len(indices) == 0 {
		return {}
	}
	optimized = make([dynamic]u32, len(indices), allocator)
	mo.optimizeVertexCache(
		raw_data(optimized[:]),
		raw_data(indices[:]),
		c.size_t(len(indices)),
		c.size_t(vertex_count),
	)
	return optimized
}

// ============================================================================
// GPU Integration (Opaque)
// ============================================================================
// These procedures handle GPU image creation from baked atlas pages.
// Uses void pointers to avoid cross-package type dependencies.

gpu_create_image_from_atlas_page :: proc(
	gpu_engine: rawptr,
	pixels: [^]u8,
	width, height: i32,
	allocator := context.allocator,
) -> (gpu_image: rawptr, ok: bool) {
	if pixels == nil || width <= 0 || height <= 0 {
		log.warnf("gpu_create_image_from_atlas_page: invalid input (width=%d, height=%d)", width, height)
		return nil, false
	}
	// This is a placeholder that will be called from the Vulkan backend.
	// The actual GPU image creation happens in scene.odin via create_image_from_data.
	// We return the pixels pointer which will be consumed by the backend.
	return cast(rawptr)pixels, true
}
