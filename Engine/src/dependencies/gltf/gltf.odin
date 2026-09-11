// Engine/src/dependencies/gltf/gltf.odin
//
// GLTF / GLB parser, built on top of the vendored cgltf library
// (https://github.com/jkuhlmann/cgltf). cgltf handles the full
// GLTF 2.0 spec + the GLB container; this file is a thin adapter
// that produces the in-memory GLTF_Document consumers (BF_MapDB
// importer, asset_converter) operate on.
//
// Parsed once at import time and consumed by both:
//   - BF_MapDB        (runtime map import -> .bmap)
//   - asset_converter (offline glTF -> .bmesh)
//
// Animations / skins are exposed so asset_converter can quantize
// them; BF_MapDB v1 ignores them.
//
// All lifecycle is owned by the caller:
//   gltf_parse_bytes / gltf_parse_file -> gltf_document_destroy.

package gltf

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import cgltf "vendor:cgltf"

// ============================================================================
// GLB header constants (kept for format detection only; parsing is delegated)
// ============================================================================

GLB_Magic   :: u32(0x46546C67) // 'glTF' little-endian
GLB_Version :: u32(2)
GLB_Header_Size :: 12

GLB_Header :: struct {
	magic:   u32,
	version: u32,
	length:  u32,
}

// ============================================================================
// Lifecycle
// ============================================================================

gltf_document_init :: proc(doc: ^GLTF_Document, allocator := context.allocator) {
	if doc == nil do return
	doc.allocator     = allocator
	doc.source_format = .GLTF_JSON
	doc.default_scene = -1
}

gltf_document_destroy :: proc(doc: ^GLTF_Document) {
	if doc == nil do return
	for &s in doc.scenes {
		delete(s.nodes)
	}
	delete(doc.scenes)
	for &n in doc.nodes {
		delete(n.children)
	}
	delete(doc.nodes)
	for &m in doc.meshes {
		for &p in m.primitives {
			delete(p.attributes)
		}
		delete(m.primitives)
	}
	delete(doc.meshes)
	delete(doc.materials)
	delete(doc.textures)
	delete(doc.samplers)
	delete(doc.images)
	delete(doc.accessors)
	delete(doc.buffer_views)
	delete(doc.buffers)
	for &a in doc.animations {
		delete(a.channels)
		delete(a.samplers)
	}
	delete(doc.animations)
	if doc.cgltf_data != nil {
		cgltf.free(doc.cgltf_data)
		doc.cgltf_data = nil
	}
	doc^ = {}
}

// ============================================================================
// Parse error
// ============================================================================

GLTF_Parse_Error :: enum {
	None,
	Bad_Input,
	Parse_Failed,
	Empty_Document,
}

GLTF_Parse_Result :: struct {
	error:   GLTF_Parse_Error,
	message: string,
}

// ============================================================================
// Format detection
// ============================================================================

// Identify whether a byte buffer is a GLB or a raw GLTF JSON.
gltf_detect_format :: proc(data: []byte) -> GLTF_Source_Format {
	if len(data) >= GLB_Header_Size {
		hdr := cast(^GLB_Header)raw_data(data)
		if hdr.magic == GLB_Magic && hdr.version == GLB_Version {
			return .GLB
		}
	}
	return .GLTF_JSON
}

// ============================================================================
// Top-level: parse from bytes / file
// ============================================================================

// Parses a GLTF/GLB byte buffer into `doc`. The byte buffer must remain
// valid for the lifetime of the document (cgltf references it directly;
// in particular the GLB BIN chunk is a slice of the input).
gltf_parse_bytes :: proc(
	data: []byte,
	doc: ^GLTF_Document,
	source_path: string = "",
	allocator := context.allocator,
) -> GLTF_Parse_Result {
	result: GLTF_Parse_Result
	if len(data) == 0 || doc == nil {
		result.error   = .Bad_Input
		result.message = "empty input or nil doc"
		return result
	}

	context.allocator = allocator
	defer { context.allocator = {} }

	gltf_document_init(doc, allocator)
	doc.source_path   = source_path
	doc.source_format = gltf_detect_format(data)

	opts := cgltf.options {
		type = cgltf.file_type(doc.source_format),
	}
	parsed, res := cgltf.parse(opts, raw_data(data), uint(len(data)))
	if parsed == nil {
		result.error   = .Parse_Failed
		result.message = fmt.tprintf("cgltf.parse failed: %v", res)
		return result
	}

	doc.cgltf_data = parsed

	if err := gltf_translate(parsed, doc); err.error != .None {
		gltf_document_destroy(doc)
		cgltf.free(parsed)
		return err
	}

	if len(doc.nodes) == 0 && len(doc.meshes) == 0 {
		result.error   = .Empty_Document
		result.message = "cgltf parsed zero nodes / meshes"
		return result
	}

	return result
}

// Convenience wrapper for .gltf / .glb files on disk. Uses cgltf's own
// file loader which reads external .bin files relative to the GLTF.
gltf_parse_file :: proc(
	path: string,
	doc: ^GLTF_Document,
	allocator := context.allocator,
) -> GLTF_Parse_Result {
	result: GLTF_Parse_Result
	if len(path) == 0 {
		result.error   = .Bad_Input
		result.message = "empty path"
		return result
	}

	context.allocator = allocator
	defer { context.allocator = {} }

	gltf_document_init(doc, allocator)
	doc.source_path = path

	opts := cgltf.options {}
	parsed, res := cgltf.parse_file(opts, strings.unsafe_string_to_cstring(path))
	if parsed == nil {
		result.error   = .Parse_Failed
		result.message = fmt.tprintf("cgltf.parse_file(%q) failed: %v", path, res)
		return result
	}
	doc.cgltf_data = parsed
	doc.source_format = parsed.file_type == .glb ? .GLB : .GLTF_JSON

	if err := gltf_translate(parsed, doc); err.error != .None {
		gltf_document_destroy(doc)
		cgltf.free(parsed)
		return err
	}

	return result
}

// ============================================================================
// cgltf -> GLTF_Document translation
// ============================================================================

@(private)
gltf_translate :: proc(parsed: ^cgltf.data, doc: ^GLTF_Document) -> GLTF_Parse_Result {
	result: GLTF_Parse_Result

	//* asset
	if parsed.asset.version != nil {
		doc.asset.version = string(parsed.asset.version)
	}
	if parsed.asset.min_version != nil {
		doc.asset.min_version = string(parsed.asset.min_version)
	}
	if parsed.asset.generator != nil {
		doc.asset.generator = string(parsed.asset.generator)
	}
	if parsed.asset.copyright != nil {
		doc.asset.copyright = string(parsed.asset.copyright)
	}

	//* buffers (record source / size; raw pointer exposed for read-only access)
	for &b in parsed.buffers {
		brec := GLTF_Buffer {
			uri         = b.uri != nil ? string(b.uri) : "",
			byte_length = int(b.size),
		}
		if b.data != nil && b.size > 0 {
			brec.data = mem_byte_view(b.data, int(b.size))
		}
		append(&doc.buffers, brec)
	}

	//* buffer views (raw offset/size/target)
	for &bv in parsed.buffer_views {
		bvrec := GLTF_Buffer_View {
			buffer      = int(cgltf.buffer_view_index(parsed, &bv)),
			byte_offset = int(bv.offset),
			byte_length = int(bv.size),
			target      = int(bv.type),
		}
		append(&doc.buffer_views, bvrec)
	}

	//* accessors
	for &a in parsed.accessors {
		ct, ok := cgltf_component_type_to(a.component_type)
		if !ok do ct = .FLOAT
		t, ok2 := cgltf_type_to(a.type)
		if !ok2 do t = .Scalar
		acc := GLTF_Accessor {
			buffer_view    = int(cgltf.accessor_index(parsed, &a)),
			byte_offset    = int(a.offset),
			component_type = ct,
			count          = int(a.count),
			type           = t,
			has_min        = bool(a.has_min),
			has_max        = bool(a.has_max),
		}
		if a.has_min do for v, i in a.min {if i < 4 do acc.min[i] = v}
		if a.has_max do for v, i in a.max {if i < 4 do acc.max[i] = v}
		append(&doc.accessors, acc)
	}

	//* samplers / images / textures
	for s in parsed.samplers {
		append(&doc.samplers, GLTF_Sampler {
			mag_filter = int(s.mag_filter),
			min_filter = int(s.min_filter),
			wrap_s     = int(s.wrap_s),
			wrap_t     = int(s.wrap_t),
		})
	}
	for &img in parsed.images {
		bv_idx: int = -1
		if img.buffer_view != nil {
			bv_idx = int(cgltf.buffer_view_index(parsed, img.buffer_view))
		}
		append(&doc.images, GLTF_Image {
			uri         = img.uri != nil ? string(img.uri) : "",
			mime_type   = img.mime_type != nil ? string(img.mime_type) : "",
			buffer_view = bv_idx,
			name        = img.name != nil ? string(img.name) : "",
		})
	}
	for &t in parsed.textures {
		s_idx: int = -1
		if t.sampler != nil {
			s_idx = int(cgltf.sampler_index(parsed, t.sampler))
		}
		img_idx: int = -1
		if t.image_ != nil {
			img_idx = int(cgltf.image_index(parsed, t.image_))
		}
		append(&doc.textures, GLTF_Texture {
			sampler = s_idx,
			source  = img_idx,
			name    = t.name != nil ? string(t.name) : "",
		})
	}

	//* materials
	for &m in parsed.materials {
		mrec := GLTF_Material {
			name           = m.name != nil ? string(m.name) : "",
			double_sided   = bool(m.double_sided),
			alpha_mode     = int(m.alpha_mode),
			alpha_cutoff   = m.alpha_cutoff,
			emissive_factor = {m.emissive_factor[0], m.emissive_factor[1], m.emissive_factor[2]},
		}
		if bool(m.has_pbr_metallic_roughness) {
			pbr := &m.pbr_metallic_roughness
			pbr_base_color_tex: int = -1
			if pbr.base_color_texture.texture != nil {
				pbr_base_color_tex = int(cgltf.texture_index(parsed, pbr.base_color_texture.texture))
			}
			pbr_mr_tex: int = -1
			if pbr.metallic_roughness_texture.texture != nil {
				pbr_mr_tex = int(cgltf.texture_index(parsed, pbr.metallic_roughness_texture.texture))
			}
			mrec.pbr = GLTF_Material_PBR {
				base_color_factor          = {pbr.base_color_factor[0], pbr.base_color_factor[1], pbr.base_color_factor[2], pbr.base_color_factor[3]},
				metallic_factor            = pbr.metallic_factor,
				roughness_factor           = pbr.roughness_factor,
				base_color_texture         = pbr_base_color_tex,
				metallic_roughness_texture = pbr_mr_tex,
				has_base_color_texture     = pbr.base_color_texture.texture != nil,
				has_metallic_roughness     = pbr.metallic_roughness_texture.texture != nil,
			}
		}
		if m.normal_texture.texture != nil {
			mrec.normal_texture = int(cgltf.texture_index(parsed, m.normal_texture.texture))
		}
		if m.emissive_texture.texture != nil {
			mrec.emissive_texture = int(cgltf.texture_index(parsed, m.emissive_texture.texture))
		}
		append(&doc.materials, mrec)
	}

	//* meshes
	for &m in parsed.meshes {
		mrec := GLTF_Mesh {
			name = m.name != nil ? string(m.name) : "",
		}
		for &p in m.primitives {
			prec := GLTF_Primitive {
				indices  = p.indices  != nil ? int(cgltf.accessor_index(parsed, p.indices))  : -1,
				material = p.material != nil ? int(cgltf.material_index(parsed, p.material)) : -1,
				mode     = cgltf_primitive_mode_to(p.type),
			}
			for &attr in p.attributes {
				append(&prec.attributes, GLTF_Primitive_Attribute {
					key      = attr.name != nil ? string(attr.name) : "",
					accessor = attr.data != nil ? int(cgltf.accessor_index(parsed, attr.data)) : -1,
				})
			}
			append(&mrec.primitives, prec)
		}
		append(&doc.meshes, mrec)
	}

	//* nodes
	for &n in parsed.nodes {
		nrec := GLTF_Node {
			name    = n.name != nil ? string(n.name) : "",
			mesh    = n.mesh != nil ? int(cgltf.mesh_index(parsed, n.mesh)) : -1,
			scale   = {1, 1, 1},
			rotation = {0, 0, 0, 1},
		}
		if bool(n.has_translation) {
			nrec.has_translation = true
			nrec.translation = {n.translation[0], n.translation[1], n.translation[2]}
		}
		if bool(n.has_rotation) {
			nrec.has_rotation = true
			nrec.rotation = {n.rotation[0], n.rotation[1], n.rotation[2], n.rotation[3]}
		}
		if bool(n.has_scale) {
			nrec.has_scale = true
			nrec.scale = {n.scale[0], n.scale[1], n.scale[2]}
		}
		if bool(n.has_matrix) {
			nrec.has_matrix = true
			for v, i in n.matrix_ {if i < 16 do nrec.matrix_data[i] = v}
		}
		for &c in n.children {
			append(&nrec.children, c != nil ? int(cgltf.node_index(parsed, c)) : -1)
		}
		append(&doc.nodes, nrec)
	}

	//* scenes
	for &s in parsed.scenes {
		srec := GLTF_Scene {
			name = s.name != nil ? string(s.name) : "",
		}
		for &n in s.nodes {
			append(&srec.nodes, n != nil ? int(cgltf.node_index(parsed, n)) : -1)
		}
		append(&doc.scenes, srec)
	}
	if parsed.scene != nil {
		doc.default_scene = int(cgltf.scene_index(parsed, parsed.scene))
	} else if len(doc.scenes) > 0 {
		doc.default_scene = 0
	} else {
		doc.default_scene = -1
	}

	//* animations (used by asset_converter for animation quantization)
	for &a in parsed.animations {
		arec := GLTF_Animation {
			name = a.name != nil ? string(a.name) : "",
		}
		for &s in a.samplers {
			append(&arec.samplers, GLTF_Animation_Sampler {
				input_accessor  = s.input  != nil ? int(cgltf.accessor_index(parsed, s.input))  : -1,
				output_accessor = s.output != nil ? int(cgltf.accessor_index(parsed, s.output)) : -1,
				interpolation   = cgltf_interpolation_to(s.interpolation),
			})
		}
		for &c in a.channels {
			append(&arec.channels, GLTF_Animation_Channel {
				target_node   = c.target_node != nil ? int(cgltf.node_index(parsed, c.target_node)) : -1,
				target_path   = cgltf_animation_path_to(c.target_path),
				sampler_index = int(cgltf.animation_sampler_index(&a, &c) if cgltf.animation_sampler_index != nil else cgltf_size(0)),
			})
		}
		// cgltf stores channels->sampler as a pointer; we resolve the
		// sampler index via the channel's offset into the channel array
		// since animation_sampler_index lookup helpers differ across
		// versions. Use the sampler pointer identity via the channel
		// array mapping (channels share samplers pool).
		for &c, ci in a.channels {
			for &s, si in a.samplers {
				if c.sampler == &s {
					arec.channels[ci].sampler_index = si
					break
				}
			}
		}
		append(&doc.animations, arec)
	}

	return result
}

// ============================================================================
// cgltf enum mapping
// ============================================================================

@(private)
cgltf_component_type_to :: proc(ct: cgltf.component_type) -> (GLTF_Component_Type, bool) {
	#partial switch ct {
	case .r_8:   return .BYTE, true
	case .r_8u:  return .UNSIGNED_BYTE, true
	case .r_16:  return .SHORT, true
	case .r_16u: return .UNSIGNED_SHORT, true
	case .r_32u: return .UNSIGNED_INT, true
	case .r_32f: return .FLOAT, true
	}
	return .FLOAT, false
}

@(private)
cgltf_type_to :: proc(t: cgltf.type) -> (GLTF_Type, bool) {
	#partial switch t {
	case .scalar: return .Scalar, true
	case .vec2:   return .Vec2, true
	case .vec3:   return .Vec3, true
	case .vec4:   return .Vec4, true
	case .mat2:   return .Mat2, true
	case .mat3:   return .Mat3, true
	case .mat4:   return .Mat4, true
	}
	return .Scalar, false
}

@(private)
cgltf_primitive_mode_to :: proc(t: cgltf.primitive_type) -> GLTF_Primitive_Mode {
	#partial switch t {
	case .points:         return .Points
	case .lines:          return .Lines
	case .line_loop:      return .Line_Loop
	case .line_strip:     return .Line_Strip
	case .triangles:      return .Triangles
	case .triangle_strip: return .Triangle_Strip
	case .triangle_fan:   return .Triangle_Fan
	}
	return .Triangles
}

@(private)
cgltf_animation_path_to :: proc(t: cgltf.animation_path_type) -> GLTF_Animation_Path {
	#partial switch t {
	case .translation: return .Translation
	case .rotation:    return .Rotation
	case .scale:       return .Scale
	case .weights:     return .Weights
	}
	return .Translation
}

@(private)
cgltf_interpolation_to :: proc(t: cgltf.interpolation_type) -> GLTF_Animation_Interpolation {
	#partial switch t {
	case .linear:       return .Linear
	case .step:         return .Step
	case .cubic_spline: return .Cubic_Spline
	}
	return .Linear
}

// Reinterpret a rawptr + size as a []byte without copying. Used for
// the cgltf buffer pointer, which cgltf itself owns (free()d by cgltf).
@(private)
mem_byte_view :: #force_inline proc(p: rawptr, size: int) -> []byte {
	if p == nil || size <= 0 do return nil
	return ([^]byte)(p)[:size]
}

// ============================================================================
// Accessor helpers
// ============================================================================

gltf_accessor_bytes :: proc(doc: ^GLTF_Document, accessor_index: int) -> []byte {
	if doc == nil do return nil
	if accessor_index < 0 || accessor_index >= len(doc.accessors) do return nil
	acc := &doc.accessors[accessor_index]
	if acc.buffer_view < 0 || acc.buffer_view >= len(doc.buffer_views) do return nil
	bv := &doc.buffer_views[acc.buffer_view]
	if bv.buffer < 0 || bv.buffer >= len(doc.buffers) do return nil
	buf := &doc.buffers[bv.buffer]
	if bv.byte_offset + acc.byte_offset + bv.byte_length > len(buf.data) do return nil
	offset := bv.byte_offset + acc.byte_offset
	return buf.data[offset:offset + bv.byte_length]
}

gltf_accessor_component_size :: proc(acc: ^GLTF_Accessor) -> int {
	if acc == nil do return 0
	cs: int
	switch acc.component_type {
	case .BYTE, .UNSIGNED_BYTE:  cs = 1
	case .SHORT, .UNSIGNED_SHORT: cs = 2
	case .UNSIGNED_INT, .FLOAT:  cs = 4
	}
	cc: int
	switch acc.type {
	case .Scalar: cc = 1
	case .Vec2:   cc = 2
	case .Vec3:   cc = 3
	case .Vec4:   cc = 4
	case .Mat2:   cc = 4
	case .Mat3:   cc = 9
	case .Mat4:   cc = 16
	}
	return cs * cc
}

gltf_accessor_count :: proc(acc: ^GLTF_Accessor) -> int {
	return acc == nil ? 0 : acc.count
}

// gltf_find_attribute returns the accessor index for a primitive attribute
// by name (POSITION, NORMAL, TANGENT, TEXCOORD_0, COLOR_0, JOINTS_0,
// WEIGHTS_0, ...). Returns -1 if absent.
gltf_find_attribute :: proc(prim: ^GLTF_Primitive, key: string) -> int {
	if prim == nil do return -1
	for attr in prim.attributes {
		if attr.key == key do return attr.accessor
	}
	return -1
}

// ============================================================================
// Pretty-printer (debug / log)
// ============================================================================

gltf_document_log_summary :: proc(doc: ^GLTF_Document) {
	if doc == nil do return
	log.info(fmt.tprintf(
		"[GLTF] %q (format=%v) asset=%q generator=%q scenes=%d nodes=%d meshes=%d materials=%d textures=%d images=%d accessors=%d bufferViews=%d buffers=%d animations=%d",
		doc.source_path,
		doc.source_format,
		doc.asset.version,
		doc.asset.generator,
		len(doc.scenes), len(doc.nodes), len(doc.meshes),
		len(doc.materials), len(doc.textures), len(doc.images),
		len(doc.accessors), len(doc.buffer_views), len(doc.buffers),
		len(doc.animations),
	))
}
