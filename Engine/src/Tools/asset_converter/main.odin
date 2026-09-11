// Engine/src/Tools/asset_converter/main.odin
//
// Entry point for the Bifrost Asset Converter.
//
// Boots an SDL3 + Dear ImGui modal window, lets the user pick a
// .gltf / .glb file, an output directory and filename, and tweak the
// quantization / optimization / LOD chain settings (defaults pulled
// from Core.GLOBAL_PROJECT_SETTINGS). On "Convert" the tool invokes
// the glTF -> .bmesh pipeline (bmesh_writer.odin) and writes the
// output to disk.
//
// Build:
//
//     odin build Engine\\src\\Tools\\asset_converter\\
//         -out:Project\\bin\\Tools\\asset_converter.exe
//
// The asset_converter shares Engine/src/Core for project settings
// (no engine runtime, no DAG, no render modules).

package asset_converter

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import imgui "..\\..\\dependencies\\imgui"
import Core   "..\\..\\Core"

import sdl "vendor:sdl3"

// ============================================================================
// UI state (everything the modal needs)
// ============================================================================

App_State :: struct {
	source_path:    [512]u8,
	source_len:     int,

	output_dir:     [512]u8,
	output_dir_len: int,

	output_name:    [256]u8,
	output_name_len: int,

	// Quantization controls (mirrored from project settings on init)
	position_quant:   Core.Quantization_Level,
	uv_quant:         Core.Quantization_Level,
	tangent_quant:    Core.Quantization_Level,

	index_format:     Core.Index_Buffer_Format,

	oct_normals:      bool,
	bone_weight_format: Core.Quantization_Level,

	// Mesh optimization
	vertex_cache:      bool,
	triangle_strips:   bool,
	overdraw_enabled:  bool,
	overdraw_threshold: f32,

	// LOD chain
	generate_lods:  bool,
	lod_count:      int,
	lod_base_ratio: f32,

	// Animation quantization
	anim_rotation_quant:    Core.Quantization_Level,
	anim_translation_quant: Core.Quantization_Level,
	anim_scale_quant:       Core.Quantization_Level,

	// Status
	last_message: string,
	last_ok:      bool,
	status_lines: [dynamic]string,
}

init_app_state :: proc(s: ^App_State) {
	// -- bootstrap Core so project settings are available --
	Core.inject_default_project_settings()
	rs := Core.renderer_settings_get()

	s.source_path[0]    = 0
	s.source_len        = 0

	strings.copy(s.output_dir[:], "Project\\import\\meshes")
	s.output_dir_len    = len("Project\\import\\meshes")

	strings.copy(s.output_name[:], "mesh.bmesh")
	s.output_name_len   = len("mesh.bmesh")

	s.position_quant = rs.vertex_quantization.position
	s.uv_quant       = rs.vertex_quantization.uv
	s.tangent_quant  = rs.vertex_quantization.tangent
	s.index_format   = rs.index_buffer_format
	s.oct_normals    = rs.oct_encoded_normals
	s.bone_weight_format = rs.bone_weight_format

	s.vertex_cache     = rs.mesh_optimization.vertex_cache_reordering
	s.triangle_strips  = rs.mesh_optimization.triangle_stripification
	s.overdraw_enabled = false
	s.overdraw_threshold = 1.05

	s.generate_lods  = rs.lod_count > 1
	s.lod_count      = int(rs.lod_count) if rs.lod_count > 0 else 4
	s.lod_base_ratio = rs.lod_simplification

	s.anim_rotation_quant    = rs.animation_quantization.rotation
	s.anim_translation_quant = rs.animation_quantization.translation
	s.anim_scale_quant       = rs.animation_quantization.scale

	s.last_message = ""
	s.last_ok      = false
}

// ============================================================================
// Helpers
// ============================================================================

@(private)
str_from_buf :: proc(buf: []u8, n: int) -> string {
	// Locate the first NUL; the cached `n` from InputText is unreliable
	// because ImGui mutates the buffer in place without telling us the
	// new length.
	for b, i in buf {
		if b == 0 do return string(buf[:i])
	}
	_ = n
	if len(buf) == 0 do return ""
	return string(buf)
}

@(private)
copy_to_fixed_buf :: proc(s: string, buf: ^[$N]u8, n: ^int) {
	copy_len := len(s)
	if copy_len > len(buf) - 1 do copy_len = len(buf) - 1
	for i in 0..<copy_len do buf[i] = s[i]
	buf[copy_len] = 0
	n^ = copy_len
}

@(private)
log_status :: proc(s: ^App_State, line: string) {
	append(&s.status_lines, strings.clone(line))
	if len(s.status_lines) > 64 {
		old := s.status_lines[0]
		ordered_remove(&s.status_lines, 0)
		delete(old)
	}
	log.info(line)
}

// ============================================================================
// ImGui widgets for our enums
// ============================================================================

@(private)
quant_level_combo :: proc(label: cstring, q: ^Core.Quantization_Level) -> bool {
	preview := quant_level_cstring(q^)
	changed := false
	if imgui.BeginCombo(label, preview) {
		for v in Core.Quantization_Level {
			sel := v == q^
			label_v := quant_level_cstring(v)
			if imgui.Selectable(label_v, sel) {
				q^ = v
				changed = true
			}
			if sel do imgui.SetItemDefaultFocus()
		}
		imgui.EndCombo()
	}
	return changed
}

@(private)
quant_level_cstring :: proc(q: Core.Quantization_Level) -> cstring {
	switch q {
	case .U8:  return "U8"
	case .U16: return "U16"
	case .F32: return "F32"
	}
	return "F32"
}

@(private)
index_format_combo :: proc(label: cstring, f: ^Core.Index_Buffer_Format) -> bool {
	preview := index_format_cstring(f^)
	changed := false
	if imgui.BeginCombo(label, preview) {
		for v in Core.Index_Buffer_Format {
			sel := v == f^
			label_v := index_format_cstring(v)
			if imgui.Selectable(label_v, sel) {
				f^ = v
				changed = true
			}
			if sel do imgui.SetItemDefaultFocus()
		}
		imgui.EndCombo()
	}
	return changed
}

@(private)
index_format_cstring :: proc(f: Core.Index_Buffer_Format) -> cstring {
	switch f {
	case .U16: return "U16"
	case .U32: return "U32"
	}
	return "U32"
}

// ============================================================================
// Main
// ============================================================================

main :: proc() {
	context.logger = log.create_console_logger()

	ui: UI_State
	init_err := ui_init(&ui, "Bifrost Asset Converter", 720, 760)
	if init_err != .None {
		fmt.eprintf("Failed to initialize UI: %v\n", init_err)
		os.exit(1)
	}
	defer ui_shutdown(&ui)

	app: App_State
	init_app_state(&app)
	defer delete(app.status_lines)

	// -- main loop --
	for !ui_pump_events(&ui) {
		ui_begin_frame()
		draw_main_window(&app)
		draw_status_window(&app)
		ui_end_frame(&ui)
	}

	fmt.println("Asset Converter exited cleanly.")
}

// ============================================================================
// Main window
// ============================================================================

@(private)
draw_main_window :: proc(app: ^App_State) {
	io := imgui.GetIO()
	imgui.SetNextWindowPos({0, 0}, .Always)
	imgui.SetNextWindowSize(io.DisplaySize, .Always)

	flags: imgui.WindowFlags = {.NoTitleBar, .NoResize, .NoMove, .NoCollapse}
	imgui.Begin("Bifrost Asset Converter", nil, flags)

	imgui.Text("Convert glTF / GLB -> .bmesh")
	imgui.Separator()

	// -- source --
	imgui.Text("Source asset")
	imgui.InputText("##source", cast(cstring)&app.source_path[0], 512)
	imgui.SameLine()
	if imgui.Button("Help##source") {
		imgui.OpenPopup("source_help")
	}
	if imgui.BeginPopupModal("source_help", nil, {.AlwaysAutoResize}) {
		imgui.Text("Paste a full path to a .gltf or .glb file in the source field.")
		imgui.Text("(An OS-native file picker is on the follow-up list.)")
		if imgui.Button("OK", {120, 0}) do imgui.CloseCurrentPopup()
		imgui.EndPopup()
	}

	// -- output --
	imgui.Text("Output")
	imgui.InputText("Dir",  cast(cstring)&app.output_dir[0],  512)
	imgui.InputText("Name", cast(cstring)&app.output_name[0], 256)

	imgui.Separator()
	imgui.Text("Vertex quantization (defaults from project settings)")
	quant_level_combo("Position", &app.position_quant)
	quant_level_combo("UV",       &app.uv_quant)
	quant_level_combo("Tangent",  &app.tangent_quant)
	imgui.Checkbox("Octahedral-encoded normals", &app.oct_normals)
	index_format_combo("Index buffer format", &app.index_format)
	quant_level_combo("Bone weights", &app.bone_weight_format)

	imgui.Separator()
	imgui.Text("Animation quantization")
	quant_level_combo("Rotation",    &app.anim_rotation_quant)
	quant_level_combo("Translation", &app.anim_translation_quant)
	quant_level_combo("Scale",       &app.anim_scale_quant)

	imgui.Separator()
	imgui.Text("Mesh optimization")
	imgui.Checkbox("Vertex cache reordering",    &app.vertex_cache)
	imgui.Checkbox("Triangle stripification",    &app.triangle_strips)
	imgui.Checkbox("Overdraw reordering",        &app.overdraw_enabled)
	if app.overdraw_enabled {
		imgui.SliderFloat("Overdraw threshold", &app.overdraw_threshold, 1.0, 2.0)
	}

	imgui.Separator()
	imgui.Text("LOD chain")
	imgui.Checkbox("Generate LODs", &app.generate_lods)
	if app.generate_lods {
		imgui.SliderInt ("LOD count",         cast(^i32)&app.lod_count,     1, 8)
		imgui.SliderFloat("LOD base ratio",   &app.lod_base_ratio, 0.1, 0.9)
		imgui.TextWrapped(
			"LODs are generated via meshopt_simplify; each level keeps " +
			"a fraction of the previous level's triangles (base_ratio^(n-1)).",
		)
	}

	imgui.Separator()
	can_convert := len(str_from_buf(app.source_path[:], 0)) > 0 &&
	               len(str_from_buf(app.output_dir[:],  0)) > 0 &&
	               len(str_from_buf(app.output_name[:], 0)) > 0
	if !can_convert do imgui.BeginDisabled()
	if imgui.Button("Convert", {160, 32}) {
		run_conversion(app)
	}
	if !can_convert do imgui.EndDisabled()

	if len(app.last_message) > 0 {
		imgui.Spacing()
		if app.last_ok do imgui.TextColored({0.3, 0.9, 0.4, 1}, "OK: %s", app.last_message)
		else            do imgui.TextColored({0.9, 0.4, 0.4, 1}, "FAILED: %s", app.last_message)
	}

	imgui.End()
}

// ============================================================================
// Status / log sub-window
// ============================================================================

@(private)
draw_status_window :: proc(app: ^App_State) {
	if !imgui.Begin("Conversion Log") do return
	for line in app.status_lines {
		buf := transmute([]u8)line
		imgui.TextUnformatted(cstring(raw_data(buf)))
	}
	imgui.End()
}

// ============================================================================
// Conversion entry point (called from UI thread)
// ============================================================================

@(private)
run_conversion :: proc(app: ^App_State) {
	src := str_from_buf(app.source_path[:], 0)
	out_dir := str_from_buf(app.output_dir[:], 0)
	out_name := str_from_buf(app.output_name[:], 0)

	out_path, join_err := filepath.join({out_dir, out_name}, context.allocator)
	if join_err != nil {
		app.last_ok = false
		app.last_message = fmt.tprintf("could not join output path: %v", join_err)
		log_status(app, app.last_message)
		return
	}
	defer delete(out_path)

	// -- build LOD level list --
	lod_levels := make([dynamic]LOD_Level, context.allocator)
	defer delete(lod_levels)
	if app.generate_lods {
		for i in 1..<app.lod_count {
			ratio := math.pow(app.lod_base_ratio, f32(i))
			append(&lod_levels, LOD_Level {
				target_ratio = ratio,
				target_error = 0.05 * f32(i),
			})
		}
	}

	settings := Conversion_Settings {
		source_path = src,
		output_path = out_path,
		lods        = lod_levels[:],
		opt = Mesh_Opt_Options {
			vertex_cache_reordering = app.vertex_cache,
			triangle_stripification = app.triangle_strips,
			overdraw_threshold      = app.overdraw_threshold if app.overdraw_enabled else 0,
		},
		emit_skin = true, // v1: always try to emit skin; primitive decides
	}

	rs := Core.Renderer_Settings {
		texture_compression = .None,
		generate_mips       = false,
		max_texture_size    = 4096,
		colour_space        = .Linear,
		mesh_optimization   = Mesh_Optimization {
			vertex_cache_reordering = app.vertex_cache,
			triangle_stripification = app.triangle_strips,
		},
		lod_count           = u32(app.lod_count),
		lod_simplification  = app.lod_base_ratio,
		oct_encoded_normals = app.oct_normals,
		vertex_quantization = Core.Vertex_Quantization {
			position = app.position_quant,
			uv       = app.uv_quant,
			tangent  = app.tangent_quant,
		},
		index_buffer_format    = app.index_format,
		animation_quantization = Core.Animation_Quantization {
			rotation    = app.anim_rotation_quant,
			translation = app.anim_translation_quant,
			scale       = app.anim_scale_quant,
		},
		bone_weight_format = app.bone_weight_format,
	}

	res := convert_asset_with_overrides(settings, rs)

	app.last_ok = res.ok
	app.last_message = res.message
	log_status(app, fmt.tprintf("[%s] %s", res.ok ? "OK" : "ERR", res.message))
	if res.ok {
		log_status(app, fmt.tprintf("output: %s", res.output_path))
	}
}

// Conversion wrapper that injects a Renderer_Settings override (the
// raw convert_asset always reads GLOBAL_PROJECT_SETTINGS).
@(private)
convert_asset_with_overrides :: proc(
	settings: Conversion_Settings,
	rs: Core.Renderer_Settings,
) -> Conversion_Result {
	saved := Core.project_settings_get().renderer_settings
	defer Core.project_settings_get().renderer_settings = saved
	Core.project_settings_get().renderer_settings = rs
	return convert_asset(settings)
}
