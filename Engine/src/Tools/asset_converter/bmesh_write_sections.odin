// Engine/src/Tools/asset_converter/bmesh_write_sections.odin
//
// Low-level .bmesh section writer. Called by bmesh_writer.odin's
// convert_primitive with the optimized + quantized vertex/index data.
//
// Section order written (one or more of each, depending on flags):
//
//   STRINGS       -- shared material / mesh name table
//   HEADER_INFO   -- counts + per-channel quantization + num_lods
//   SUBMESHES     -- one BMESH_Submesh_Header per primitive
//   LOD_CHAIN     -- one BMESH_LOD_Entry per LOD level
//   VERTICES      -- quantized, strided per-vertex data
//   INDICES       -- U16 or U32 per project settings
//   JOINT_INDICES -- only when BMESH_FLAG_HAS_SKIN is set
//   WEIGHTS       -- only when BMESH_FLAG_HAS_SKIN is set

package asset_converter

import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"

import Core "../../Core"
import gltf "../../dependencies/gltf"

@(private)
Write_Result :: struct {
	ok:      bool,
	message: string,
}

// write_bmesh writes the full .bmesh file for a single primitive.
// The function is internal -- it's invoked from convert_primitive in
// bmesh_writer.odin.
@(private)
write_bmesh :: proc(
	doc: ^gltf.GLTF_Document,
	prim: ^gltf.GLTF_Primitive,
	output_path: string,
	primitive_index: int,
	renderer_settings: Core.Renderer_Settings,
	base_indices: []u32,
	base_positions: []f32,
	lod_indices: [][]u32,
	lod_errors:  []f32,
	normals:     []f32,
	uvs:         []f32,
	tangents:    []f32,
	bounds:      Mesh_Bounds,
	emit_skin:   bool,
) -> Write_Result {
	// -- 1. resolve material name --
	material_name := ""
	if prim.material >= 0 && prim.material < len(doc.materials) {
		material_name = doc.materials[prim.material].name
	}

	// -- 2. quantize vertices into the per-vertex section --
	stride := compute_vertex_stride(renderer_settings.vertex_quantization, renderer_settings.oct_encoded_normals)

	vw: Vertex_Writer
	vertex_writer_init(
		&vw,
		renderer_settings.vertex_quantization,
		renderer_settings.oct_encoded_normals,
		bounds.pos_min, bounds.pos_max,
		bounds.uv_min,  bounds.uv_max,
	)
	defer vertex_writer_destroy(&vw)

	vc := len(base_positions) / 3
	if vc * 3 != len(base_positions) {
		return {false, fmt.tprintf("non-aligned positions buffer: %d floats", len(base_positions))}
	}
	// We always write exactly `vc` vertices (one row per unique vertex
	// in the optimized buffer). The source mesh supplies normals/uvs
	// in the original vertex order; the optimize step has remapped
	// them into base_positions order. The remap table is implicit
	// in the optimized buffer layout -- but for v1 we require the
	// caller to pass normals/uvs already aligned with the optimized
	// vertex buffer.
	//
	// For v1 the optimize step keeps the original vertex order (no
	// reindexing of vertex attributes), so `normals`/`uvs`/`tangents`
	// are taken as-is. A more complete implementation would pass a
	// remap table into this function and reorder the attribute arrays.
	for vi in 0..<vc {
		p := base_positions[vi*3:][:3]
		n := normals[vi*3:][:3] if vi*3+3 <= len(normals) else [3]f32{0, 0, 1}
		t := tangents[vi*4:][:4] if vi*4+4 <= len(tangents) else [4]f32{1, 0, 0, 1}
		u := uvs[vi*2:][:2] if vi*2+2 <= len(uvs) else [2]f32{0, 0}
		write_vertex(&vw, ([3]f32)(p[:3]), n[0:3], t[0:3], u[0:2])
	}

	vertices_data := vw.data[:]

	// -- 3. flatten LOD index buffer into a single INDICES section --
	// Each LOD's index range is recorded in LOD_CHAIN; the INDICES
	// section concatenates them.
	indices_data, lod_records, err := flatten_lod_indices(
		lod_indices, lod_errors,
		renderer_settings.index_buffer_format,
	)
	defer delete(indices_data)
	defer delete(lod_records)
	if err != nil {
		return {false, err}
	}

	// -- 4. compute header info flags --
	flags := BMESH_FLAG_LITTLE_ENDIAN
	if renderer_settings.oct_encoded_normals do flags |= BMESH_FLAG_OCT_NORMALS
	if emit_skin do flags |= BMESH_FLAG_HAS_SKIN

	hinfo := BMESH_Header_Info {
		position_quant = quant_level_to_u8(renderer_settings.vertex_quantization.position),
		normal_quant   = quant_level_to_u8(renderer_settings.vertex_quantization.position), // 0=oct8,1=oct16,2=fl
		uv_quant       = quant_level_to_u8(renderer_settings.vertex_quantization.uv),
		tangent_quant  = quant_level_to_u8(renderer_settings.vertex_quantization.tangent),
		index_format   = index_format_to_u8(renderer_settings.index_buffer_format),
		num_lods       = u16(len(lod_records)),
		num_submeshes  = 1, // one primitive per .bmesh in v1
		vertex_count   = u32(vc),
		triangle_count = u32(lod_records[0].index_count / 3),
		vertex_stride  = u16(stride),
		reserved       = 0,
	}

	// -- 5. build the section payloads (lazy; written below) --
	strings: String_Table
	string_table_init(&strings)
	defer string_table_destroy(&strings)
	mat_off := string_table_add(&strings, material_name)
	mesh_off := string_table_add(&strings, doc.meshes[0].name)

	submesh := BMESH_Submesh_Header {
		material_name_offset = mat_off,
		index_offset         = 0,
		index_count          = u32(lod_records[0].index_count),
	}

	_ = mesh_off // reserved for future top-level mesh name lookup

	// -- 6. open output file and write --
	out, open_err := os.open(output_path, os.O_CREATE | os.O_TRUNC | os.O_WRONLY, 0o644)
	if open_err != nil {
		return {false, fmt.tprintf("open(%q): %v", output_path, open_err)}
	}
	defer os.close(out)

	// --- 6a. file header (placeholder; we patch section_count) ---
	file_hdr := BMESH_File_Header {
		magic         = BMESH_MAGIC,
		version       = BMESH_VERSION,
		flags         = flags,
		section_count = 0, // patched below
		reserved      = 0,
	}

	// Estimate section count for header write.
	section_count: u16 = 6
	if emit_sink_needed(emit_skin) do section_count += 2

	// Write the file header with section_count populated.
	file_hdr.section_count = section_count
	if w_err := write_struct(out, &file_hdr); w_err != nil {
		return {false, fmt.tprintf("write header: %v", w_err)}
	}

	// --- 6b. section headers (placeholders; we patch lengths) ---
	section_headers_start := file_offset(out)

	// Allocate space for the section table.
	sh := make([dynamic]BMESH_Section_Header, section_count, context.allocator)
	defer delete(sh)

	// Reserve slot for the section header table.
	for _ in 0..<section_count {
		zero := BMESH_Section_Header{}
		if w_err := write_struct(out, &zero); w_err != nil {
			return {false, fmt.tprintf("write section slot: %v", w_err)}
		}
	}
	section_bodies_start := file_offset(out)

	// --- 6c. write each section in order, recording payload length ---
	slot: int = 0
	// 1. STRINGS
	sh[slot].id = BMESH_SECTION_STRINGS
	if w_err := write_bytes(out, strings.bytes[:]); w_err != nil {
		return {false, fmt.tprintf("write STRINGS: %v", w_err)}
	}
	sh[slot].length = u32(len(strings.bytes))
	slot += 1

	// 2. HEADER_INFO
	sh[slot].id = BMESH_SECTION_HEADER_INFO
	if w_err := write_struct(out, &hinfo); w_err != nil {
		return {false, fmt.tprintf("write HEADER_INFO: %v", w_err)}
	}
	sh[slot].length = u32(size_of(BMESH_Header_Info))
	slot += 1

	// 3. SUBMESHES
	sh[slot].id = BMESH_SECTION_SUBMESHES
	if w_err := write_struct(out, &submesh); w_err != nil {
		return {false, fmt.tprintf("write SUBMESHES: %v", w_err)}
	}
	sh[slot].length = u32(size_of(BMESH_Submesh_Header))
	slot += 1

	// 4. LOD_CHAIN
	sh[slot].id = BMESH_SECTION_LOD_CHAIN
	sh[slot].length = u32(len(lod_records) * size_of(BMESH_LOD_Entry))
	if w_err := write_struct_array(out, lod_records[:]); w_err != nil {
		return {false, fmt.tprintf("write LOD_CHAIN: %v", w_err)}
	}
	slot += 1

	// 5. VERTICES
	sh[slot].id = BMESH_SECTION_VERTICES
	if w_err := write_bytes(out, vertices_data); w_err != nil {
		return {false, fmt.tprintf("write VERTICES: %v", w_err)}
	}
	sh[slot].length = u32(len(vertices_data))
	slot += 1

	// 6. INDICES
	sh[slot].id = BMESH_SECTION_INDICES
	if w_err := write_bytes(out, indices_data); w_err != nil {
		return {false, fmt.tprintf("write INDICES: %v", w_err)}
	}
	sh[slot].length = u32(len(indices_data))
	slot += 1

	// (Optional) 7. JOINT_INDICES + 8. WEIGHTS
	if emit_sink_needed(emit_skin) {
		// TODO(skin): pull JOINTS_0 + WEIGHTS_0 from the primitive,
		// quantize per `bone_weight_format`, write both sections.
		sh[slot].id = BMESH_SECTION_JOINT_INDICES
		sh[slot].length = 0
		slot += 1
		sh[slot].id = BMESH_SECTION_WEIGHTS
		sh[slot].length = 0
		slot += 1
	}

	// --- 6d. patch the section headers with the recorded lengths ---
	os.seek(out, i64(section_headers_start), io.Seek_Set)
	for &s in sh {
		if w_err := write_struct(out, &s); w_err != nil {
			return {false, fmt.tprintf("patch section header: %v", w_err)}
		}
	}

	log.infof(
		"[asset_converter] wrote %q (%d bytes, %d vertices, %d LODs)",
		output_path,
		file_offset(out),
		vc,
		len(lod_records),
	)
	return {true, ""}
}

@(private)
emit_sink_needed :: proc(emit_skin: bool) -> bool {
	return emit_skin
}

@(private)
quant_level_to_u8 :: proc(q: Core.Quantization_Level) -> u8 {
	switch q {
	case .U8:  return 0
	case .U16: return 1
	case .F32: return 2
	}
	return 2
}

@(private)
index_format_to_u8 :: proc(f: Core.Index_Buffer_Format) -> u8 {
	switch f {
	case .U16: return 0
	case .U32: return 1
	}
	return 1
}

// ============================================================================
// LOD index flattening
// ============================================================================

@(private)
flatten_lod_indices :: proc(
	lod_indices: [][]u32,
	lod_errors:  []f32,
	format: Core.Index_Buffer_Format,
) -> (
	data: [dynamic]u8,
	lods: [dynamic]BMESH_LOD_Entry,
	err: string,
) {
	data = make([dynamic]u8, context.allocator)
	lods = make([dynamic]BMESH_LOD_Entry, context.allocator)

	stride := u32(2) if format == .U16 else u32(4)
	off: u32 = 0

	for lod_i in 0..<len(lod_indices) {
		idx := lod_indices[lod_i]
		if len(idx) % 3 != 0 {
			delete(data); delete(lods)
			return {}, {}, fmt.tprintf("LOD %d index count %d not a multiple of 3", lod_i, len(idx))
		}

		err_v: f32 = 0
		if lod_i < len(lod_errors) do err_v = lod_errors[lod_i]

		switch format {
		case .U16:
			for x in idx {
				if x > 0xFFFF {
					delete(data); delete(lods)
					return {}, {}, fmt.tprintf(
						"LOD %d has index %d > 65535; switch project settings to U32 indices",
						lod_i, x,
					)
				}
				v: u16 = u16(x)
				buf: [2]u8 = transmute([2]u8)v
				append(&data, buf[:])
			}
		case .U32:
			for x in idx {
				buf: [4]u8 = transmute([4]u8)x
				append(&data, buf[:])
			}
		}

		append(&lods, BMESH_LOD_Entry {
			index_offset = off,
			index_count  = u32(len(idx)),
			target_error = err_v,
		})
		off += u32(len(idx)) * stride
	}

	return data, lods, ""
}

// ============================================================================
// Low-level file write helpers
// ============================================================================

@(private)
write_struct :: proc(h: os.Handle, s: ^$T) -> os.Error {
	data := mem.bytes_from_ptr(s, size_of(T))
	_, err := os.write(h, data)
	return err
}

@(private)
write_struct_array :: proc(h: os.Handle, arr: []$T) -> os.Error {
	if len(arr) == 0 do return nil
	data := mem.bytes_from_ptr(raw_data(arr), size_of(T) * len(arr))
	_, err := os.write(h, data)
	return err
}

@(private)
write_bytes :: proc(h: os.Handle, b: []u8) -> os.Error {
	if len(b) == 0 do return nil
	_, err := os.write(h, b)
	return err
}

@(private)
file_offset :: proc(h: os.Handle) -> int {
	pos, err := os.seek(h, 0, io.Seek_Current{})
	if err != nil do return -1
	return int(pos)
}
