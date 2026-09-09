// Engine/src/Core/project_settings.odin
package Core

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import toml "../dependencies/toml_parser"
import ts "../dependencies/toml_serializer"

// ============================================================================
// RENDERER + ASSET PIPELINE SETTINGS
// ============================================================================
//
// Project-wide settings read by:
//   - the Bifrost_Renderer module at activate() to drive device /
//     swapchain / pipeline choices;
//   - (later) the asset import pipeline to drive mesh / texture /
//     animation encoding.
// In-process, read-only data; not behind any ABI.
// ============================================================================

Quantization_Level :: enum {
	U8,
	U16,
	F32,
}

Index_Buffer_Format :: enum {
	U16,
	U32,
}

Texture_Compression_Format :: enum {
	None,
	BC,
	ASTC,
	ETC2,
}

Colour_Space :: enum {
	Linear,
	sRGB,
}

Mesh_Optimization :: struct {
	vertex_cache_reordering: bool,
	triangle_stripification: bool,
}

Vertex_Quantization :: struct {
	position: Quantization_Level,
	uv:       Quantization_Level,
	tangent:  Quantization_Level,
}

Animation_Quantization :: struct {
	rotation:    Quantization_Level,
	translation: Quantization_Level,
	scale:       Quantization_Level,
}

Renderer_Settings :: struct {
	// --- Texture import ---
	texture_compression:    Texture_Compression_Format,
	generate_mips:          bool,
	max_texture_size:       u32,
	colour_space:           Colour_Space,

	// --- Mesh / geometry ---
	mesh_optimization:      Mesh_Optimization,
	lod_count:              u32,
	lod_simplification:     f32,
	oct_encoded_normals:    bool,
	vertex_quantization:    Vertex_Quantization,
	index_buffer_format:    Index_Buffer_Format,

	// --- Animation ---
	animation_quantization: Animation_Quantization,
	bone_weight_format:     Quantization_Level,
}

Spatial_Settings :: struct {
	cubic:      bool, // true = 3D, false = 2D (square).
	chunk_size: u32, // cells per chunk axis
	cell_size:  f32, // world meters per cell
}


// ============================================================================
// PROJECT SETTINGS (TOML)
// ============================================================================
Project_Settings :: struct {
	project_name:      string,
	version:           Version,
	renderer_settings: Renderer_Settings,
	spatial_settings:  Spatial_Settings,
	modules:           [dynamic]Component_Project_Entry,
	extensions:        [dynamic]Component_Project_Entry,
	plugins:           [dynamic]Component_Project_Entry,
}

// Project_Module / Project_Extension / Project_Plugin are now
// Component_Project_Entry under the hood. Kept as type aliases so
// any existing call sites that named the old types still compile.
Project_Module    :: Component_Project_Entry
Project_Extension :: Component_Project_Entry
Project_Plugin    :: Component_Project_Entry
// ===============================
// GLOBAL STATE
//
// Engine-owned singleton. All manager init/destroy is driven from
// engine.init / engine.destroy in engine.odin.
//
// The pointer returned by project_settings_get points at the live
// global; callers MUST NOT mutate the dynamic-array fields directly.
// Mutation goes through engine.init's setup path or through a future
// settings-API surface (see TODO(settings-mutation)).
// ===============================
@(private)
GLOBAL_PROJECT_SETTINGS := Project_Settings{}

// project_settings_get returns a pointer to the engine's live
// Project_Settings. Read-only by convention; the underlying slices may
// be replaced by engine.init's setup phase.
project_settings_get :: proc() -> ^Project_Settings {
	return &GLOBAL_PROJECT_SETTINGS
}

// renderer_settings_get returns a pointer to the live Renderer_Settings.
// Read-only by convention. Modules (most commonly the renderer) read this
// at activate() to drive device / swapchain / pipeline choices.
//
// IMPORTANT: this proc reads Core package globals. A DLL that imports
// Core has its OWN copy of those globals — it would see zeros. DLLs must
// call `renderer_settings_from_lib(ctx)` with the Lib_Context the engine
// passed them; that path goes through lib_context_query into engine
// memory.
renderer_settings_get :: proc() -> ^Renderer_Settings {
	return &project_settings_get().renderer_settings
}

// renderer_settings_from_lib looks up the project's Renderer_Settings via
// the supplied Lib_Context (the ABI struct every DLL receives). This is
// the path DLLs must use — `renderer_settings_get()` reads Core's
// per-DLL globals, which are zero; `renderer_settings_from_lib()` reads
// the engine-owned settings via the user_data pointer the engine passes
// to each DLL.
//
// Returns nil if the interface is not exposed (which would indicate the
// engine wasn't built with project_settings support, or the user_data
// pointer was malformed).
renderer_settings_from_lib :: proc(lib_ctx: ^Lib_Context) -> ^Renderer_Settings {
	if lib_ctx == nil do return nil
	raw := lib_context_query(
		lib_ctx,
		CORE_LIB_INTERFACE_PROJECT_SETTINGS,
		PROJECT_SETTINGS_API_VERSION,
	)
	if raw == nil do return nil
	ps := cast(^Project_Settings)raw
	return &ps.renderer_settings
}

// TODO(settings-mutation): provide a proper mutation API
// (project_settings_set_module, project_settings_remove_extension, etc.)
// so the editor and rbs-driven workflows can edit the live settings
// without reaching into the global. The current API is intentionally
// read-only outside of engine.init.

// ========================
// DEFAULT PROJECT SETTINGS
//
// `inject_default_project_settings` is exposed publicly so the build tool
// (Project/rbs/rbs.odin) can seed Core's in-memory defaults when
// project.toml is missing on disk. The build tool then writes those
// defaults back to Project/config/project.toml via
// `render_project_settings_toml` so the engine can find them at next
// startup.
//
DEFAULT_RENDERER_SETTINGS := Renderer_Settings {
	texture_compression = .BC,
	generate_mips = true,
	max_texture_size = 4096,
	colour_space = .sRGB,
	mesh_optimization = Mesh_Optimization {
		vertex_cache_reordering = true,
		triangle_stripification = false,
	},
	lod_count = 4,
	lod_simplification = 0.5,
	oct_encoded_normals = true,
	vertex_quantization = Vertex_Quantization{position = .F32, uv = .F32, tangent = .F32},
	index_buffer_format = .U32,
	animation_quantization = Animation_Quantization {
		rotation = .U16,
		translation = .U16,
		scale = .U8,
	},
	bone_weight_format = .U8,
}

DEFAULT_SPATIAL_SETTINGS := Spatial_Settings {
	cubic      = false,
	chunk_size = 16,
	cell_size  = 4,
}

// inject_default_project_settings populates GLOBAL_PROJECT_SETTINGS with
// the engine's compile-time defaults (project name, version, renderer
// settings, default module/extension/plugin lists).
//
// Exposed publicly so the build tool (Project/rbs/rbs.odin) can call it
// when no project.toml exists on disk; the build tool then persists the
// populated defaults to Project/config/project.toml via
// `render_project_settings_toml`.
inject_default_project_settings :: proc() {
	GLOBAL_PROJECT_SETTINGS.project_name = "New Project"
	GLOBAL_PROJECT_SETTINGS.version = BASEVERSION
	GLOBAL_PROJECT_SETTINGS.renderer_settings = DEFAULT_RENDERER_SETTINGS
	GLOBAL_PROJECT_SETTINGS.spatial_settings = DEFAULT_SPATIAL_SETTINGS

	default_modules := []Project_Module {
		{name = "BF_GPU", version = BASEVERSION, enabled = true, required = true},
		{name = "BF_DAG", version = BASEVERSION, enabled = true, required = true},
		{name = "BF_ECS", version = BASEVERSION, enabled = true, required = true},
		{name = "BF_REP", version = BASEVERSION, enabled = true, required = true},
		{name = "BF_Input", version = BASEVERSION, enabled = false},
		{name = "BF_Miniaudio", version = BASEVERSION, enabled = false},
		{name = "BF_Box3D_Physics", version = BASEVERSION, enabled = false},
		{name = "ATLAS-RMGUI", version = BASEVERSION, enabled = false},
		{name = "BF_Scripting", version = BASEVERSION, enabled = false},
		{name = "BF_Editor", version = BASEVERSION, enabled = false},
		{name = "BF_ENet", version = BASEVERSION, enabled = false},
	}
	for m in default_modules {
		append(&GLOBAL_PROJECT_SETTINGS.modules, m)
	}

	default_extensions := []Project_Extension {
		{name = "Example_Extension", version = BASEVERSION, enabled = false},
	}
	for e in default_extensions {
		append(&GLOBAL_PROJECT_SETTINGS.extensions, e)
	}

	default_plugins := []Project_Plugin {
		{name = "Example Plugin", version = BASEVERSION, enabled = false},
	}
	for p in default_plugins {
		append(&GLOBAL_PROJECT_SETTINGS.plugins, p)
	}
}

// ============================================================================
// TOML LOAD
// ============================================================================
@(private)
project_config_path :: proc(allocator := context.allocator) -> (string, bool) {
	exe_dir, err := os.get_executable_directory(allocator)
	if err != nil {
		return "", false
	}
	defer delete(exe_dir)
	path, jerr := filepath.join({exe_dir, "config", "project.toml"}, allocator)
	if jerr != nil {
		return "", false
	}
	return path, true
}

@(private)
load_project_settings_toml :: proc() -> bool {
	config_path, ok := project_config_path()
	if !ok {
		log.warn("Could not resolve project configuration path")
		return false
	}
	defer delete(config_path)

	if !os.exists(config_path) {
		log.warnf("Project configuration not found: %s", config_path)
		return false
	}

	data, read_err := os.read_entire_file(config_path, context.allocator)
	if read_err != nil {
		log.errorf("Could not read %s: %v", config_path, read_err)
		return false
	}
	defer delete(data)

	// Section-presence probes: toml.unmarshal leaves a struct field at
	// its zero value when the corresponding TOML section is missing, but
	// "zero" is also a valid configuration. We can't tell "user
	// explicitly set to 0" from "section absent" from the post-parse
	// struct alone, so probe the raw text before parsing.
	//
	// For each optional section, we apply DEFAULT_RENDERER_SETTINGS if
	// the section is absent.
	renderer_section_present := strings.contains(string(data), "[renderer_settings]")

	unmarshal_err := toml.unmarshal(data, &GLOBAL_PROJECT_SETTINGS)
	if unmarshal_err != .None {
		log.errorf("Could not parse %s: %v", config_path, unmarshal_err)
		return false
	}

	if !renderer_section_present {
		GLOBAL_PROJECT_SETTINGS.renderer_settings = DEFAULT_RENDERER_SETTINGS
	}

	fmt.printfln("  Project: %s", GLOBAL_PROJECT_SETTINGS.project_name)
	fmt.printfln(
		"  Version: v%d.%d.%d",
		GLOBAL_PROJECT_SETTINGS.version.major,
		GLOBAL_PROJECT_SETTINGS.version.minor,
		GLOBAL_PROJECT_SETTINGS.version.patch,
	)
	return true
}

@(private)
cleanup_project_settings :: proc(s: ^Project_Settings) {
	if s == nil do return
	delete(s.modules)
	delete(s.extensions)
	delete(s.plugins)
	s.modules = nil
	s.extensions = nil
	s.plugins = nil
}

// ============================================
// TOML WRITE (default project.toml generation)
@(private)
setup_default_project_settings_toml :: proc() -> bool {
	exe_dir, err := os.get_executable_directory(context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to get executable directory: %v", err)
		return false
	}
	defer delete(exe_dir)

	config_dir, err1 := filepath.join({exe_dir, "config"}, context.allocator)
	if err1 != nil {
		fmt.eprintfln("Failed to join config path: %v", err1)
		return false
	}
	defer delete(config_dir)

	file_path, err2 := filepath.join({config_dir, "project.toml"}, context.allocator)
	if err2 != nil {
		fmt.eprintfln("Failed to join file path: %v", err2)
		return false
	}
	defer delete(file_path)

	if !os.exists(config_dir) {
		if mkdir_err := os.make_directory_all(config_dir); mkdir_err != nil {
			fmt.eprintfln("Failed to create config directory at %s: %v", config_dir, mkdir_err)
			return false
		}
	}

	toml_text := render_project_settings_toml(GLOBAL_PROJECT_SETTINGS)
	defer delete(toml_text)

	if write_err := os.write_entire_file(file_path, transmute([]byte)toml_text); write_err != nil {
		fmt.eprintfln("Failed to write %s: %v", file_path, write_err)
		return false
	}

	fmt.printfln("Wrote default project configuration to %s", file_path)
	return true
}

// render_project_settings_toml builds the on-disk project.toml from the
// current settings. Driven entirely by Engine/src/ext/toml_serializer's
// Document API, so escaping / formatting / blank-line rules match the rest
// of the manifest pipeline.
//
// Exposed publicly so the build tool (Project/rbs/rbs.odin) can re-emit
// a default project.toml when one is missing on disk.
render_project_settings_toml :: proc(s: Project_Settings) -> string {
	doc: ts.Document
	ts.document_init(&doc)
	defer ts.document_destroy(&doc)

	// Top-level scalars.
	ts.doc_add_string(&doc, "project_name", s.project_name)

	// [version] inline table.
	{
		it: ts.Inline_Table
		ts.inline_table_init(&it)
		ts.it_add_int(&it, "major", int(s.version.major))
		ts.it_add_int(&it, "minor", int(s.version.minor))
		ts.it_add_int(&it, "patch", int(s.version.patch))
		append(&doc.entries, ts.Key_Value{key = "version", value = it})
	}

	// [renderer_settings] inline table.
	renderer_settings_inline_into(&doc, s.renderer_settings) // TODO: make the struct show multi-line

	// [spatial_settings] inline table.
	spatial_settings_inline_into(&doc, s.spatial_settings) // TODO: create this proc, make the struct show multi-line

	// [[modules]]
	if len(s.modules) > 0 {
		aot: ts.Array_Of_Tables
		ts.array_of_tables_init(&aot, "modules")
		for &m in s.modules {
			t: ts.Inline_Table
			ts.inline_table_init(&t)
			ts.it_add_string(&t, "name", m.name)
			ts.it_add_bool(&t, "enabled", m.enabled)
			if m.required do ts.it_add_bool(&t, "required", m.required)
			version_inline_into(&t, m.version)
			append(&aot.tables, t)
		}
		append(&doc.arrays_of_tables, aot)
	}

	// [[extensions]]
	if len(s.extensions) > 0 {
		aot: ts.Array_Of_Tables
		ts.array_of_tables_init(&aot, "extensions")
		for &e in s.extensions {
			t: ts.Inline_Table
			ts.inline_table_init(&t)
			ts.it_add_string(&t, "name", e.name)
			ts.it_add_bool(&t, "enabled", e.enabled)
			if e.required do ts.it_add_bool(&t, "required", e.required)
			version_inline_into(&t, e.version)
			append(&aot.tables, t)
		}
		append(&doc.arrays_of_tables, aot)
	}

	// [[plugins]]
	if len(s.plugins) > 0 {
		aot: ts.Array_Of_Tables
		ts.array_of_tables_init(&aot, "plugins")
		for &p in s.plugins {
			t: ts.Inline_Table
			ts.inline_table_init(&t)
			ts.it_add_string(&t, "name", p.name)
			ts.it_add_bool(&t, "enabled", p.enabled)
			if p.required do ts.it_add_bool(&t, "required", p.required)
			version_inline_into(&t, p.version)
			append(&aot.tables, t)
		}
		append(&doc.arrays_of_tables, aot)
	}

	return ts.writer_to_string(&doc)
}

// renderer_settings_inline_into writes the `[renderer_settings]` block.
// Always emitted so consumers can rely on the section's existence after
// reading project.toml; default values flow through DEFAULT_RENDERER_SETTINGS
// in inject_default_project_settings.
@(private)
renderer_settings_inline_into :: proc(doc: ^ts.Document, r: Renderer_Settings) {
	t: ts.Inline_Table
	ts.inline_table_init(&t)
	log.info("TODO: make the render_settings struct show multi-line")
	ts.it_add_string(
		&t,
		"texture_compression",
		texture_compression_to_string(r.texture_compression),
	)
	ts.it_add_bool(&t, "generate_mips", r.generate_mips)
	ts.it_add_int(&t, "max_texture_size", int(r.max_texture_size))
	ts.it_add_string(&t, "colour_space", colour_space_to_string(r.colour_space))

	ts.it_add_bool(&t, "mesh_vertex_cache_reordering", r.mesh_optimization.vertex_cache_reordering)
	ts.it_add_bool(&t, "mesh_triangle_stripification", r.mesh_optimization.triangle_stripification)
	ts.it_add_int(&t, "lod_count", int(r.lod_count))
	ts.it_add_float(&t, "lod_simplification", f64(r.lod_simplification))
	ts.it_add_bool(&t, "oct_encoded_normals", r.oct_encoded_normals)

	ts.it_add_string(
		&t,
		"vertex_quant_position",
		quant_level_to_string(r.vertex_quantization.position),
	)
	ts.it_add_string(&t, "vertex_quant_uv", quant_level_to_string(r.vertex_quantization.uv))
	ts.it_add_string(
		&t,
		"vertex_quant_tangent",
		quant_level_to_string(r.vertex_quantization.tangent),
	)
	ts.it_add_string(&t, "index_buffer_format", index_format_to_string(r.index_buffer_format))

	ts.it_add_string(
		&t,
		"anim_quant_rotation",
		quant_level_to_string(r.animation_quantization.rotation),
	)
	ts.it_add_string(
		&t,
		"anim_quant_translation",
		quant_level_to_string(r.animation_quantization.translation),
	)
	ts.it_add_string(&t, "anim_quant_scale", quant_level_to_string(r.animation_quantization.scale))
	ts.it_add_string(&t, "bone_weight_format", quant_level_to_string(r.bone_weight_format))

	append(&doc.entries, ts.Key_Value{key = "renderer_settings", value = t})
}

// spatial_settings_inline_into writes the `[spatial_settings]` block.
// Always emitted so consumers can rely on the section's existence after
// reading project.toml; default values flow through DEFAULT_SPATIAL_SETTINGS
// in inject_default_project_settings.
@(private)
spatial_settings_inline_into :: proc(doc: ^ts.Document, s: Spatial_Settings) {
	t: ts.Inline_Table
	ts.inline_table_init(&t)
	ts.it_add_bool(&t, "cubic", s.cubic)
	ts.it_add_int(&t, "chunk_size", int(s.chunk_size))
	ts.it_add_float(&t, "cell_size", f64(s.cell_size))

	append(&doc.entries, ts.Key_Value{key = "spatial_settings", value = t})
}

// ------------------------------------------------------------------------
// Enum -> string converters used by both TOML emission and logging
// ------------------------------------------------------------------------

@(private)
texture_compression_to_string :: proc(v: Texture_Compression_Format) -> string {
	switch v {
	case .None:
		return "None"
	case .BC:
		return "BC"
	case .ASTC:
		return "ASTC"
	case .ETC2:
		return "ETC2"
	}
	return "None"
}

@(private)
colour_space_to_string :: proc(v: Colour_Space) -> string {
	switch v {
	case .Linear:
		return "Linear"
	case .sRGB:
		return "sRGB"
	}
	return "Linear"
}

@(private)
index_format_to_string :: proc(v: Index_Buffer_Format) -> string {
	switch v {
	case .U16:
		return "U16"
	case .U32:
		return "U32"
	}
	return "U32"
}

@(private)
quant_level_to_string :: proc(v: Quantization_Level) -> string {
	switch v {
	case .U8:
		return "U8"
	case .U16:
		return "U16"
	case .F32:
		return "F32"
	}
	return "F32"
}

// version_inline_into writes a 'version = { major = ..., minor = ..., patch = ... }'
// entry into the given inline table.
@(private)
version_inline_into :: proc(t: ^ts.Inline_Table, v: Version) {
	inner: ts.Inline_Table
	ts.inline_table_init(&inner)
	ts.it_add_int(&inner, "major", int(v.major))
	ts.it_add_int(&inner, "minor", int(v.minor))
	ts.it_add_int(&inner, "patch", int(v.patch))
	append(t, ts.Key_Value{key = "version", value = inner})
}