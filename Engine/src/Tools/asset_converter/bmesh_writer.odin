// Engine/src/Tools/asset_converter/bmesh_writer.odin
//
// Orchestrates the full glTF -> .bmesh conversion and writes the
// output file. Pulls project settings from Core.GLOBAL_PROJECT_SETTINGS
// at call time so the runtime renderer and the converter agree on
// quantization layout.
//
// Pipeline:
//   1. parse glTF
//   2. for each primitive:
//        - extract positions / normals / uvs / tangents
//        - compute mesh bounds
//        - mesh_optimize (cache + fetch reorder)
//        - mesh_quantize (per-vertex packed layout)
//        - generate LOD chain
//   3. write BMESH file header + sections
//
// The result is a single .bmesh file per primitive (or per source
// mesh, depending on how the caller invokes it). For v1 we emit
// one .bmesh per GLTF primitive; multi-primitive GLTF meshes produce
// one .bmesh per primitive, sharing the same name + an index suffix.

package asset_converter

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import Core "../../Core"
import gltf "../../dependencies/gltf"

Conversion_Settings :: struct {
	// Source path (.gltf or .glb). Required.
	source_path: string,

	// Output path (full file path including .bmesh extension).
	output_path: string,

	// Override the project settings' renderer settings. When nil,
	// uses Core.project_settings_get().renderer_settings.
	renderer_settings_override: ^Core.Renderer_Settings,

	// LOD levels beyond LOD 0. LOD 0 is always the full mesh.
	lods: []LOD_Level,

	// Mesh optimization options.
	opt: Mesh_Opt_Options,

	// Whether to emit a skinning section (Joints + Weights).
	// When true and the source primitive has JOINTS_0/WEIGHTS_0
	// attributes, joints are emitted as U8 and weights as
	// (bone_weight_format)-quantized.
	emit_skin: bool,
}

Conversion_Result :: struct {
	ok:         bool,
	message:    string,
	stats:      Mesh_Stats,
	output_path: string,
}

// ============================================================================
// String table helpers (for material names + mesh names)
// ============================================================================

// Builder that accumulates strings into a single section payload
// plus an index per added string. Strings are stored NUL-terminated.
// offset[i] is the byte position where string i begins; its length
// is the position of the next offset (or the buffer end) minus offset[i].
@(private)
String_Table :: struct {
	bytes:   [dynamic]u8,
	offsets: [dynamic]u32,
}

@(private)
string_table_init :: proc(st: ^String_Table, allocator := context.allocator) {
	st.bytes   = make([dynamic]u8, 0, 256, allocator)
	st.offsets = make([dynamic]u32, 0, 16, allocator)
	// Reserve offset 0 = empty string (always present, NUL-terminated)
	append(&st.bytes, 0)
	append(&st.offsets, 0)
}

@(private)
string_table_destroy :: proc(st: ^String_Table) {
	delete(st.bytes)
	delete(st.offsets)
}

// Adds a string to the table; returns its offset. Idempotent for
// matching strings (returns the existing offset).
@(private)
string_table_add :: proc(st: ^String_Table, s: string) -> u32 {
	// Linear search; typical mesh counts are small.
	for off, i in st.offsets {
		next := len(st.bytes)
		if i + 1 < len(st.offsets) do next = int(st.offsets[i+1])
		// next is the NUL terminator of this string; exclude it.
		str_len := next - int(off)
		if str_len == len(s) {
			existing := string(st.bytes[off:next])
			if existing == s do return off
		}
	}
	off := u32(len(st.bytes))
	append(&st.bytes, transmute([]u8)s)
	append(&st.bytes, 0) // NUL terminator
	append(&st.offsets, off)
	return off
}

// ============================================================================
// Section helpers
// ============================================================================

@(private)
Writer :: struct {
	out:           os.Handle,
	file_offset:   int,
	section_table: [dynamic]BMESH_Section_Header,
	section_ids:   [dynamic]u32,
	strings:       String_Table,
}

// ============================================================================
// Entry point
// ============================================================================

convert_asset :: proc(settings: Conversion_Settings) -> Conversion_Result {
	result: Conversion_Result
	result.output_path = settings.output_path

	if len(settings.source_path) == 0 {
		result.message = "source_path is empty"
		return result
	}
	if len(settings.output_path) == 0 {
		result.message = "output_path is empty"
		return result
	}

	// -- resolve renderer settings --
	rs: ^Core.Renderer_Settings = settings.renderer_settings_override
	if rs == nil do rs = Core.renderer_settings_get()

	// -- parse glTF --
	doc: gltf.GLTF_Document
	parse_res := gltf.gltf_parse_file(settings.source_path, &doc)
	if parse_res.error != .None {
		result.message = parse_res.message
		return result
	}
	defer gltf.gltf_document_destroy(&doc)

	log.info(fmt.tprintf("[asset_converter] converting %q -> %q", settings.source_path, settings.output_path))
	gltf.gltf_document_log_summary(&doc)

	if len(doc.meshes) == 0 {
		result.message = "glTF has no meshes"
		return result
	}

	// For v1 we convert mesh 0 (and emit one .bmesh per primitive).
	// A more advanced version would batch all meshes into one .bmap.
	mesh := &doc.meshes[0]

	if len(mesh.primitives) == 0 {
		result.message = "glTF mesh has no primitives"
		return result
	}

	// -- ensure output directory exists --
	out_dir := filepath.dir(settings.output_path, context.allocator)
	defer delete(out_dir)
	if !os.exists(out_dir) {
		if mk_err := os.make_directory_all(out_dir); mk_err != nil {
			result.message = fmt.tprintf("could not create output dir %q: %v", out_dir, mk_err)
			return result
		}
	}

	// For a multi-primitive mesh, write one .bmesh per primitive.
	// The supplied output_path is treated as a base path; if there
	// are multiple primitives, "<base>.bmesh" + "<base>_N.bmesh".
	base := settings.output_path
	ext := filepath.ext(base)
	stem := base[:len(base)-len(ext)] if len(ext) > 0 else base

	best_stats: Mesh_Stats
	converted_any := false
	for prim_i in 0..<len(mesh.primitives) {
		prim := &mesh.primitives[prim_i]
		out_path := base
		if len(mesh.primitives) > 1 {
			out_path = fmt.tprintf("%s_%d%s", stem, prim_i, ext)
		}

		per_res := convert_primitive(
			&doc, prim, out_path,
			prim_i, rs^,
			settings.lods, settings.opt,
			settings.emit_skin,
		)
		if !per_res.ok {
			result.message = per_res.message
			return result
		}

		converted_any = true
		if per_res.stats.vertex_count > 0 {
			best_stats = per_res.stats
		}
	}

	result.ok = converted_any
	result.stats = best_stats
	result.message = "ok"
	return result
}

// convert_primitive handles a single GLTF primitive: extracts
// positions/normals/uvs/tangents, optimizes, quantizes, writes .bmesh.
@(private)
convert_primitive :: proc(
	doc: ^gltf.GLTF_Document,
	prim: ^gltf.GLTF_Primitive,
	output_path: string,
	primitive_index: int,
	renderer_settings: Core.Renderer_Settings,
	lods: []LOD_Level,
	opt: Mesh_Opt_Options,
	emit_skin: bool,
) -> Conversion_Result {
	result: Conversion_Result

	// -- 1. extract attributes --
	pos_idx := gltf.gltf_find_attribute(prim, "POSITION")
	nrm_idx := gltf.gltf_find_attribute(prim, "NORMAL")
	uv_idx  := gltf.gltf_find_attribute(prim, "TEXCOORD_0")
	tan_idx := gltf.gltf_find_attribute(prim, "TANGENT")

	if pos_idx < 0 {
		result.message = fmt.tprintf("primitive %d: missing POSITION", primitive_index)
		return result
	}

	positions, pos_ok := read_accessor_f32_vec3(doc, pos_idx)
	if !pos_ok || len(positions) == 0 {
		result.message = fmt.tprintf("primitive %d: POSITION accessor invalid", primitive_index)
		return result
	}

	normals: [dynamic]f32
	if nrm_idx >= 0 {
		n, ok := read_accessor_f32_vec3(doc, nrm_idx)
		if ok { normals = n } else { normals = make([dynamic]f32, len(positions), context.allocator) }
	} else {
		normals = make([dynamic]f32, len(positions), context.allocator)
	}
	defer delete(normals)

	uvs: [dynamic]f32
	if uv_idx >= 0 {
		u, ok := read_accessor_f32_vec2(doc, uv_idx)
		if ok { uvs = u } else { uvs = make([dynamic]f32, len(positions) / 3 * 2, context.allocator) }
	} else {
		uvs = make([dynamic]f32, len(positions) / 3 * 2, context.allocator)
	}
	defer delete(uvs)

	tangents: [dynamic]f32
	if tan_idx >= 0 {
		t, ok := read_accessor_f32_vec4(doc, tan_idx)
		if ok { tangents = t } else { tangents = make([dynamic]f32, len(positions) / 3 * 4, context.allocator) }
	} else {
		tangents = make([dynamic]f32, len(positions) / 3 * 4, context.allocator)
	}
	defer delete(tangents)

	// -- 2. extract / generate indices --
	indices_u32, indices_ok := read_indices_u32(doc, prim.indices)
	if !indices_ok || len(indices_u32) == 0 {
		// Unindexed geometry: synthesize sequential indices.
		vcount := len(positions) / 3
		indices_u32 = make([dynamic]u32, vcount, context.allocator)
		for v in 0..<vcount do indices_u32[v] = u32(v)
	}
	defer delete(indices_u32)

	// -- 3. optimize (cache + fetch + LOD chain) --
	opt_indices, opt_positions, opt_ok := optimize_mesh(
		indices_u32[:],
		positions[:],
		opt,
	)
	defer if opt_ok { delete(opt_indices) }
	defer if opt_ok { delete(opt_positions) }
	if !opt_ok {
		result.message = "optimize_mesh failed"
		return result
	}

	// LOD chain generation. lod_indices[0] = optimized LOD 0 mesh.
	lod_indices, lod_errors, lod_ok := generate_lod_chain(
		opt_indices,
		opt_positions,
		lods,
	)
	defer {
		for li in lod_indices do delete(li)
		delete(lod_indices)
		delete(lod_errors)
	}
	if !lod_ok {
		result.message = "generate_lod_chain failed"
		return result
	}

	// -- 4. compute bounds on the optimized positions --
	bounds := compute_mesh_bounds(opt_positions, uvs[:])

	// -- 5. write the .bmesh --
	write_res := write_bmesh(
		doc, prim,
		output_path,
		primitive_index,
		renderer_settings,
		opt_indices, opt_positions,
		lod_indices[:],
		lod_errors[:],
		normals[:], uvs[:], tangents[:],
		bounds,
		emit_skin,
	)
	if !write_res.ok {
		result.message = write_res.message
		return result
	}

	result.ok = true
	result.message = "ok"
	result.output_path = output_path
	result.stats = compute_mesh_stats(
		opt_indices,
		opt_positions,
		channel_size_bytes(renderer_settings.vertex_quantization.position) * 3,
	)
	return result
}

// ============================================================================
// Accessor helpers
// ============================================================================

@(private)
read_accessor_f32_vec3 :: proc(doc: ^gltf.GLTF_Document, accessor_index: int) -> ([dynamic]f32, bool) {
	if accessor_index < 0 || accessor_index >= len(doc.accessors) do return nil, false
	acc := &doc.accessors[accessor_index]
	if acc.type != .Vec3 {
		log.warnf("[asset_converter] expected Vec3 accessor, got %v", acc.type)
		return nil, false
	}
	raw := gltf.gltf_accessor_bytes(doc, accessor_index)
	if len(raw) == 0 do return nil, false
	// Handle non-FLOAT by casting/copying; v1 only supports FLOAT.
	out := make([dynamic]f32, acc.count * 3, context.allocator)
	switch acc.component_type {
	case .FLOAT:
		src := cast([^]f32)raw_data(raw)
		copy(out[:], src[:acc.count * 3])
	case .UNSIGNED_SHORT:
		src := cast([^]u16)raw_data(raw)
		for i in 0..<acc.count * 3 do out[i] = f32(src[i]) / 65535.0
	case .UNSIGNED_BYTE:
		src := cast([^]u8)raw_data(raw)
		for i in 0..<acc.count * 3 do out[i] = f32(src[i]) / 255.0
	case .SHORT:
		src := cast([^]i16)raw_data(raw)
		for i in 0..<acc.count * 3 do out[i] = f32(src[i]) / 32767.0
	case .BYTE:
		src := cast([^]i8)raw_data(raw)
		for i in 0..<acc.count * 3 do out[i] = f32(src[i]) / 127.0
	case:
		log.warnf("[asset_converter] unsupported POSITION component type %v", acc.component_type)
		delete(out)
		return nil, false
	}
	return out, true
}

@(private)
read_accessor_f32_vec2 :: proc(doc: ^gltf.GLTF_Document, accessor_index: int) -> ([dynamic]f32, bool) {
	if accessor_index < 0 || accessor_index >= len(doc.accessors) do return nil, false
	acc := &doc.accessors[accessor_index]
	if acc.type != .Vec2 {
		// Some files pack UVs as Vec4 or normalize them; for v1 we
		// only support the common Vec2 + FLOAT case.
		log.warnf("[asset_converter] expected Vec2 UV accessor, got %v", acc.type)
		return nil, false
	}
	raw := gltf.gltf_accessor_bytes(doc, accessor_index)
	if len(raw) == 0 do return nil, false
	out := make([dynamic]f32, acc.count * 2, context.allocator)
	switch acc.component_type {
	case .FLOAT:
		src := cast([^]f32)raw_data(raw)
		copy(out[:], src[:acc.count * 2])
	case .UNSIGNED_SHORT:
		src := cast([^]u16)raw_data(raw)
		for i in 0..<acc.count * 2 do out[i] = f32(src[i]) / 65535.0
	case .UNSIGNED_BYTE:
		src := cast([^]u8)raw_data(raw)
		for i in 0..<acc.count * 2 do out[i] = f32(src[i]) / 255.0
	case:
		delete(out)
		return nil, false
	}
	return out, true
}

@(private)
read_accessor_f32_vec4 :: proc(doc: ^gltf.GLTF_Document, accessor_index: int) -> ([dynamic]f32, bool) {
	if accessor_index < 0 || accessor_index >= len(doc.accessors) do return nil, false
	acc := &doc.accessors[accessor_index]
	if acc.type != .Vec4 do return nil, false
	raw := gltf.gltf_accessor_bytes(doc, accessor_index)
	if len(raw) == 0 do return nil, false
	out := make([dynamic]f32, acc.count * 4, context.allocator)
	src := cast([^]f32)raw_data(raw)
	copy(out[:], src[:acc.count * 4])
	return out, true
}

@(private)
read_indices_u32 :: proc(doc: ^gltf.GLTF_Document, accessor_index: int) -> ([dynamic]u32, bool) {
	if accessor_index < 0 do return nil, false
	if accessor_index >= len(doc.accessors) do return nil, false
	acc := &doc.accessors[accessor_index]
	if acc.type != .Scalar do return nil, false
	raw := gltf.gltf_accessor_bytes(doc, accessor_index)
	if len(raw) == 0 do return nil, false
	out := make([dynamic]u32, acc.count, context.allocator)
	switch acc.component_type {
	case .UNSIGNED_INT:
		src := cast([^]u32)raw_data(raw)
		copy(out[:], src[:acc.count])
	case .UNSIGNED_SHORT:
		src := cast([^]u16)raw_data(raw)
		for i in 0..<acc.count do out[i] = u32(src[i])
	case .UNSIGNED_BYTE:
		src := cast([^]u8)raw_data(raw)
		for i in 0..<acc.count do out[i] = u32(src[i])
	case:
		delete(out)
		return nil, false
	}
	return out, true
}
