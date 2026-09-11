// Engine/src/dependencies/gltf/types.odin
//
// Shared GLTF / GLB document types used by both the runtime asset
// pipeline (BF_MapDB importer, future renderer) and the editor-time
// asset converter (Engine/src/Tools/asset_converter).
//
// Built on top of the vendored cgltf library (vendor:cgltf) - this
// file owns the Odin-friendly view; the parser lives in gltf.odin.
//
// Out of scope in v1:
//   - skins / animations / morph targets (used by asset_converter)
//   - draco mesh compression
//   - KHR_texture_transform / KHR_materials_* extensions
//
// Hoisted from BF_MapDB into shared dependencies so the asset
// converter and BF_MapDB both consume the same representation.
// See Plans/prompt_plan.md item 9.

package gltf

import "base:runtime"
import cgltf "vendor:cgltf"

// ============================================================================
// Component / type enums (mirror the GLTF 2.0 spec values)
// ============================================================================

GLTF_Component_Type :: enum u16 {
	BYTE          = 5120,
	UNSIGNED_BYTE = 5121,
	SHORT         = 5122,
	UNSIGNED_SHORT = 5123,
	UNSIGNED_INT  = 5125,
	FLOAT         = 5126,
}

GLTF_Type :: enum u8 {
	Scalar,
	Vec2,
	Vec3,
	Vec4,
	Mat2,
	Mat3,
	Mat4,
}

GLTF_Primitive_Mode :: enum u8 {
	Points,
	Lines,
	Line_Loop,
	Line_Strip,
	Triangles,
	Triangle_Strip,
	Triangle_Fan,
}

GLTF_Source_Format :: enum u8 {
	GLTF_JSON, // standalone .gltf referencing external .bin + textures
	GLB,       // single-file .glb with embedded JSON + optional BIN
}

// ============================================================================
// Per-array records
// ============================================================================

// A typed view over a bufferView. `data` is a pointer into the parent
// buffer's bytes; `count` is the number of elements of `component_type`x`type`.
GLTF_Accessor :: struct {
	buffer_view:    int,
	byte_offset:    int,
	component_type: GLTF_Component_Type,
	count:          int,
	type:           GLTF_Type,
	min:            [4]f32,
	max:            [4]f32,
	has_min:        bool,
	has_max:        bool,
}

GLTF_Buffer_View :: struct {
	buffer:      int, // index into GLTF_Document.buffers, -1 if absent
	byte_offset: int,
	byte_length: int,
	target:      int, // 34962 ARRAY_BUFFER, 34963 ELEMENT_ARRAY_BUFFER, 0 unknown
}

GLTF_Buffer :: struct {
	// Source: either a relative URI (gltf) or a slot in the parent
	// .glb (the BIN chunk is indexed as `glb_bin`).
	source:      string,
	uri:         string, // empty if data is in the GLB BIN chunk
	byte_length: int,
	// Direct byte storage. For URI-based buffers this is loaded lazily
	// by the caller; for the GLB BIN chunk this points into the file
	// buffer and is not owned by the document.
	data:       []byte,
	is_glb_bin: bool,
}

GLTF_Image :: struct {
	uri:         string,
	mime_type:   string,
	buffer_view: int, // -1 if URI
	name:        string,
}

GLTF_Sampler :: struct {
	mag_filter: int, // 0 if unspecified
	min_filter: int,
	wrap_s:     int,
	wrap_t:     int,
}

GLTF_Texture :: struct {
	sampler: int, // -1 if absent
	source:  int, // -1 if absent
	name:    string,
}

GLTF_Material_PBR :: struct {
	base_color_factor:          [4]f32,
	base_color_texture:         int, // -1 if absent (texture index)
	metallic_factor:            f32,
	roughness_factor:           f32,
	metallic_roughness_texture: int,
	has_base_color_texture:     bool,
	has_metallic_roughness:     bool,
}

GLTF_Material :: struct {
	name:             string,
	pbr:              GLTF_Material_PBR,
	double_sided:     bool,
	alpha_mode:       int, // 0 OPAQUE, 1 MASK, 2 BLEND
	alpha_cutoff:     f32,
	normal_texture:   int, // -1 if absent
	emissive_texture: int,
	emissive_factor:  [3]f32,
}

GLTF_Primitive_Attribute :: struct {
	key:      string, // POSITION, NORMAL, TANGENT, TEXCOORD_0, COLOR_0, ...
	accessor: int, // accessor index
}

GLTF_Primitive :: struct {
	attributes: [dynamic]GLTF_Primitive_Attribute,
	indices:    int, // -1 if absent
	material:   int, // -1 if absent
	mode:       GLTF_Primitive_Mode,
}

GLTF_Mesh :: struct {
	name:       string,
	primitives: [dynamic]GLTF_Primitive,
}

GLTF_Node :: struct {
	name:           string,
	mesh:           int, // -1 if none
	children:       [dynamic]int,
	translation:    [3]f32,
	rotation:       [4]f32, // quaternion (x, y, z, w)
	scale:          [3]f32,
	has_translation: bool,
	has_rotation:    bool,
	has_scale:       bool,
	has_matrix:      bool,
	matrix_data:  [16]f32,
}

GLTF_Scene :: struct {
	name:  string,
	nodes: [dynamic]int,
}

GLTF_Asset_Info :: struct {
	version:     string,
	min_version: string,
	generator:   string,
	copyright:   string,
}

// ============================================================================
// Animation (used by asset_converter; BF_MapDB importer ignores for v1)
// ============================================================================

GLTF_Animation_Path :: enum u8 {
	Translation,
	Rotation,
	Scale,
	Weights,
}

GLTF_Animation_Interpolation :: enum u8 {
	Linear,
	Step,
	Cubic_Spline,
}

GLTF_Animation_Channel :: struct {
	target_node:      int, // node index
	target_path:      GLTF_Animation_Path,
	sampler_index:    int, // index into animation.samplers
}

GLTF_Animation_Sampler :: struct {
	input_accessor:  int, // times (Scalar, FLOAT)
	output_accessor: int, // translation (Vec3), rotation (Vec4), scale (Vec3)
	interpolation:   GLTF_Animation_Interpolation,
}

GLTF_Animation :: struct {
	name:     string,
	channels: [dynamic]GLTF_Animation_Channel,
	samplers: [dynamic]GLTF_Animation_Sampler,
}

// ============================================================================
// Top-level document
// ============================================================================

// Parsed GLTF document. Owned by the caller; use gltf_document_destroy.
GLTF_Document :: struct {
	allocator:     runtime.Allocator,
	source_format: GLTF_Source_Format,
	source_path:   string,
	asset:         GLTF_Asset_Info,
	scenes:        [dynamic]GLTF_Scene,
	default_scene: int, // -1 if absent
	nodes:         [dynamic]GLTF_Node,
	meshes:        [dynamic]GLTF_Mesh,
	materials:     [dynamic]GLTF_Material,
	textures:      [dynamic]GLTF_Texture,
	samplers:      [dynamic]GLTF_Sampler,
	images:        [dynamic]GLTF_Image,
	accessors:     [dynamic]GLTF_Accessor,
	buffer_views:  [dynamic]GLTF_Buffer_View,
	buffers:       [dynamic]GLTF_Buffer,
	animations:    [dynamic]GLTF_Animation,
	// Owned cgltf parse tree; freed by gltf_document_destroy via cgltf.free.
	// Held only as a handle for callers that need full access (rare).
	cgltf_data: ^cgltf.data,
}
