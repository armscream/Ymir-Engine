package editor

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import ye "../Engine"
import "vendor:glfw"
import gl "vendor:OpenGL"
import imgui "../vendor/odin-imgui"
import imgui_glfw "../vendor/odin-imgui/imgui_impl_glfw"
import imgui_gl3 "../vendor/odin-imgui/imgui_impl_opengl3"

RUNANIMATIONGRAPHEDITOR: bool = false
RUNMATERIALGRAPHEDITOR: bool = false
RUNLEVELEDITOR: bool = false

window: glfw.WindowHandle
imgui_context: ^imgui.Context

Window_Settings :: struct {
	window_x:      i32,
	window_y:      i32,
	window_width:  i32,
	window_height: i32,
	fullscreen:    bool,
}

Editor_Settings :: struct {
	window:       Window_Settings,
	animgraph:    Window_Settings,
	materialgraph: Window_Settings,
	level:        Window_Settings,
}

Editor_Config_File :: struct {
	editor_name: string,
	app_config_directory_path: string,
	ui_theme: string,
	settings:    Editor_Settings,
}

Ui_Render_Backend :: enum {
	Undefined,
	OpenGL,
	SDL3,
	Vulkan,
	Raylib,
	Software,
}

Ui_Theme :: enum {
	Dark,
	Light,
	Light_Orange,
	Terracotta,
	Citrus_Sand,
	Apricot_Paper,
	Ocean_Mist,
	Olive_Studio,
}

Ui_Theme_Font :: enum {
	Default,
	Inter,
	Manrope,
}

UI_THEME_ORDER :: [8]Ui_Theme{
	.Dark,
	.Light,
	.Terracotta,
	.Light_Orange,
	.Citrus_Sand,
	.Apricot_Paper,
	.Ocean_Mist,
	.Olive_Studio,
}

UI_THEME_LABELS :: [8]cstring{
	"Dark",
	"Light",
	"Terracotta",
	"Light Orange",
	"Citrus Sand (Manrope)",
	"Apricot Paper (Inter)",
	"Ocean Mist",
	"Olive Studio",
}

Game_Renderer_Config :: struct {
	renderer_backend: string,
}

Editor_Runtime_Core_State :: struct {
	app_config_directory_path: string,
}

Editor_Runtime_Theme_State :: struct {
	active_theme: Ui_Theme,
	pending_theme: Ui_Theme,
	theme_change_pending: bool,
	clear_color: [4]f32,
}

Editor_Runtime_Directory_Tree_State :: struct {
	selected_path: string,
	selected_is_dir: bool,
	show_png: bool,
	show_skm: bool,
	show_sm: bool,
	show_mtl: bool,
	hide_non_primary_root_dirs: bool,
	create_folder_parent_path: string,
	create_folder_error: string,
	open_create_folder_popup: bool,
	new_folder_name: [256]u8,
	delete_folder_target_path: string,
	delete_folder_open_modal: bool,
}

Editor_Runtime_Asset_Browser_State :: struct {
	selected_asset_path: string,
	error: string,
	import_source_path: string,
	import_open_modal: bool,
	import_target_name: [256]u8,
	delete_target_path: string,
	delete_open_modal: bool,
}

Editor_Runtime_Directory_Cache_State :: struct {
	paths: [dynamic]string,
	entries: [dynamic][]os.File_Info,
}

Editor_Runtime_State :: struct {
	core: Editor_Runtime_Core_State,
	theme: Editor_Runtime_Theme_State,
	directory_tree: Editor_Runtime_Directory_Tree_State,
	asset_browser: Editor_Runtime_Asset_Browser_State,
	directory_cache: Editor_Runtime_Directory_Cache_State,
}

active_ui_backend := Ui_Render_Backend.Undefined
editor_runtime := Editor_Runtime_State{
	theme = Editor_Runtime_Theme_State{
		active_theme = .Olive_Studio,
		pending_theme = .Olive_Studio,
		clear_color = {1.00, 0.95, 0.88, 1.00},
	},
	directory_tree = Editor_Runtime_Directory_Tree_State{
		show_png = true,
		show_skm = true,
		show_sm = true,
		show_mtl = true,
		hide_non_primary_root_dirs = true,
	},
}
imgui_layout_path: string
force_default_layout_next_frame: bool

@(private) active_game_config_path_label :: proc() -> string {
	if editor_runtime.core.app_config_directory_path == "" {
		return "<unknown game config path>"
	}

	if resolved := resolve_game_config_path(editor_runtime.core.app_config_directory_path); resolved != "" {
		return resolved
	}

	return editor_runtime.core.app_config_directory_path
}

@(private) ui_backend_from_string :: proc(name: string) -> Ui_Render_Backend {
	all_backends := [6]Ui_Render_Backend{
		.Undefined,
		.OpenGL,
		.SDL3,
		.Vulkan,
		.Raylib,
		.Software,
	}

	for backend in all_backends {
		if ui_backend(backend) == name {
			return backend
		}
	}
	return .Undefined
}

@(private) ui_backend :: proc(backend: Ui_Render_Backend) -> string {
	switch backend {
	case .Undefined:
		return "Undefined"
	case .OpenGL:
		return "OpenGL"
	case .SDL3:
		return "SDL3"
	case .Vulkan:
		return "Vulkan"
	case .Raylib:
		return "Raylib"
	case .Software:
		return "Software"
	}
	return "Undefined"
}

@(private) ui_theme :: proc(theme: Ui_Theme) -> string {
	switch theme {
	case .Dark:
		return "Dark"
	case .Light:
		return "Light"
	case .Light_Orange:
		return "Light Orange"
	case .Terracotta:
		return "Terracotta"
	case .Citrus_Sand:
		return "Citrus Sand"
	case .Apricot_Paper:
		return "Apricot Paper"
	case .Ocean_Mist:
		return "Ocean Mist"
	case .Olive_Studio:
		return "Olive Studio"
	}
	return "Olive Studio"
}

@(private) ui_theme_cstring :: proc(theme: Ui_Theme) -> cstring {
	order := UI_THEME_ORDER
	labels := UI_THEME_LABELS

	for i in 0 ..< len(order) {
		if order[i] == theme {
			return labels[i]
		}
	}

	return "Olive Studio"
}

@(private) ui_theme_from_string :: proc(name: string) -> Ui_Theme {
	if name == "" {
		return .Olive_Studio
	}

	lower, _ := strings.to_lower(name, context.temp_allocator)
	if lower == "dark" {
		return .Dark
	}
	if lower == "light" {
		return .Light
	}
	if lower == "light orange" || lower == "light_orange" || lower == "light-orange" {
		return .Light_Orange
	}
	if lower == "terracotta" {
		return .Terracotta
	}
	if lower == "citrus sand" || lower == "citrus_sand" || lower == "citrus-sand" {
		return .Citrus_Sand
	}
	if lower == "apricot paper" || lower == "apricot_paper" || lower == "apricot-paper" {
		return .Apricot_Paper
	}
	if lower == "ocean mist" || lower == "ocean_mist" || lower == "ocean-mist" {
		return .Ocean_Mist
	}
	if lower == "olive studio" || lower == "olive_studio" || lower == "olive-studio" {
		return .Olive_Studio
	}

	return .Olive_Studio
}

@(private) set_ui_clear_color :: proc(r, g, b, a: f32) {
	editor_runtime.theme.clear_color[0] = r
	editor_runtime.theme.clear_color[1] = g
	editor_runtime.theme.clear_color[2] = b
	editor_runtime.theme.clear_color[3] = a
}

@(private) apply_ui_theme :: proc(theme: Ui_Theme, io: ^imgui.IO, rebuild_font_texture := true) {
	editor_runtime.theme.active_theme = theme

	switch theme {
	case .Dark:
		apply_dark_theme(io)
	case .Light:
		apply_light_theme(io)
	case .Light_Orange:
		apply_light_orange_theme(io)
	case .Terracotta:
		apply_terracotta_theme(io)
	case .Citrus_Sand:
		apply_citrus_sand_theme(io)
	case .Apricot_Paper:
		apply_apricot_paper_theme(io)
	case .Ocean_Mist:
		apply_ocean_mist_theme(io)
	case .Olive_Studio:
		apply_olive_studio_theme(io)
	}

	apply_theme_font_preset(theme, io, rebuild_font_texture)
}

@(private) queue_ui_theme_change :: proc(theme: Ui_Theme) {
	if theme == editor_runtime.theme.active_theme {
		return
	}
	editor_runtime.theme.pending_theme = theme
	editor_runtime.theme.theme_change_pending = true
}

@(private) process_pending_ui_theme_change :: proc() {
	if !editor_runtime.theme.theme_change_pending || imgui_context == nil {
		return
	}

	apply_ui_theme(editor_runtime.theme.pending_theme, imgui.get_io())
	editor_runtime.theme.theme_change_pending = false
}

@(private) resolve_theme_font :: proc(theme: Ui_Theme) -> Ui_Theme_Font {
	switch theme {
	case .Citrus_Sand:
		return .Manrope
	case .Apricot_Paper:
		return .Inter
	case .Dark, .Light, .Light_Orange, .Terracotta, .Ocean_Mist, .Olive_Studio:
		return .Default
	}
	return .Default
}

@(private) apply_dark_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_dark(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.tab_rounding = 6
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Window_Bg] = {0.12, 0.13, 0.14, 1.00}
	style.colors[imgui.Col.Child_Bg] = {0.15, 0.16, 0.18, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {0.14, 0.15, 0.17, 1.00}
	style.colors[imgui.Col.Button] = {0.31, 0.39, 0.49, 0.80}
	style.colors[imgui.Col.Button_Hovered] = {0.39, 0.48, 0.60, 0.95}
	style.colors[imgui.Col.Button_Active] = {0.24, 0.31, 0.40, 1.00}
	style.colors[imgui.Col.Header] = {0.30, 0.37, 0.46, 0.75}
	style.colors[imgui.Col.Tab_Selected] = {0.40, 0.50, 0.62, 0.92}

	io.font_global_scale = 1.04
	set_ui_clear_color(0.10, 0.11, 0.12, 1.00)
}

@(private) apply_light_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.tab_rounding = 6
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Window_Bg] = {0.97, 0.97, 0.97, 1.00}
	style.colors[imgui.Col.Child_Bg] = {0.94, 0.95, 0.96, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {0.95, 0.96, 0.97, 1.00}
	style.colors[imgui.Col.Button] = {0.54, 0.63, 0.74, 0.78}
	style.colors[imgui.Col.Button_Hovered] = {0.46, 0.56, 0.68, 0.92}
	style.colors[imgui.Col.Button_Active] = {0.36, 0.46, 0.58, 1.00}
	style.colors[imgui.Col.Header] = {0.65, 0.73, 0.81, 0.72}
	style.colors[imgui.Col.Tab_Selected] = {0.48, 0.58, 0.70, 0.90}

	io.font_global_scale = 1.04
	set_ui_clear_color(0.97, 0.97, 0.97, 1.00)
}

@(private) add_font_from_candidates :: proc(io: ^imgui.IO, size_pixels: f32, candidates: []string) -> bool {
	if io == nil || io.fonts == nil {
		return false
	}

	for candidate in candidates {
		if !os.exists(candidate) {
			continue
		}

		path_c, alloc_err := strings.clone_to_cstring(candidate)
		if alloc_err != nil {
			continue
		}

		loaded := imgui.font_atlas_add_font_from_file_ttf(io.fonts, path_c, size_pixels, nil, nil) != nil
		delete(path_c)
		if loaded {
			return true
		}
	}

	return false
}

@(private) apply_theme_font_preset :: proc(theme: Ui_Theme, io: ^imgui.IO, rebuild_font_texture: bool) {
	if io == nil || io.fonts == nil {
		return
	}

	imgui.font_atlas_clear(io.fonts)

	loaded_custom := false
	font_choice := resolve_theme_font(theme)

	switch font_choice {
	case .Manrope:
		manrope_candidates := [4]string{
			"Editor/Fonts/Manrope-Regular.ttf",
			"Fonts/Manrope-Regular.ttf",
			"C:/Windows/Fonts/Manrope-Regular.ttf",
			"C:/Windows/Fonts/Manrope.ttf",
		}
		loaded_custom = add_font_from_candidates(io, 17, manrope_candidates[:])
	case .Inter:
		inter_candidates := [4]string{
			"Editor/Fonts/Inter-Regular.ttf",
			"Fonts/Inter-Regular.ttf",
			"C:/Windows/Fonts/Inter-Regular.ttf",
			"C:/Windows/Fonts/Inter.ttf",
		}
		loaded_custom = add_font_from_candidates(io, 17, inter_candidates[:])
	case .Default:
		loaded_custom = false
	}

	if !loaded_custom {
		_ = imgui.font_atlas_add_font_default(io.fonts, nil)
	}

	if rebuild_font_texture && active_ui_backend == .OpenGL {
		imgui_gl3.destroy_fonts_texture()
		_ = imgui_gl3.create_fonts_texture()
	}
}

@(private) resolve_game_config_path :: proc(app_config_directory_path: string) -> string {
	if app_config_directory_path == "" {
		return ""
	}

	// Allow editor config to point either to a directory (containing game.json)
	// or directly to a game config file.
	if strings.has_suffix(app_config_directory_path, ".json") {
		if os.exists(app_config_directory_path) {
			return app_config_directory_path
		}

		up_one := strings.concatenate({"../", app_config_directory_path}, context.temp_allocator)
		if os.exists(up_one) {
			return up_one
		}
	}

	candidates := [4]string{
		strings.concatenate({app_config_directory_path, "/game.json"}, context.temp_allocator),
		strings.concatenate({"../", app_config_directory_path, "/game.json"}, context.temp_allocator),
		app_config_directory_path,
		strings.concatenate({"../", app_config_directory_path}, context.temp_allocator),
	}

	for candidate in candidates {
		if os.exists(candidate) && strings.has_suffix(candidate, ".json") {
			return candidate
		}
	}

	return ""
}

@(private) load_requested_ui_backend :: proc(app_config_directory_path: string) -> Ui_Render_Backend {
	path := resolve_game_config_path(app_config_directory_path)
	if path == "" {
		fmt.eprintln("Could not find game config for editor backend selection in:", app_config_directory_path)
		return .Undefined
	}

	raw, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read game config for editor backend selection:", path, "-", read_err)
		return .Undefined
	}
	defer delete(raw)

	cfg: Game_Renderer_Config
	if err := json.unmarshal(raw, &cfg); err != nil {
		fmt.eprintln("Failed to parse game config for editor backend selection:", path, "-", err)
		return .Undefined
	}
	defer delete(cfg.renderer_backend)

	return ui_backend_from_string(cfg.renderer_backend)
}

@(private) init_imgui :: proc(backend: Ui_Render_Backend) -> bool {
	imgui.CHECKVERSION()
	imgui_context = imgui.create_context(nil)
	if imgui_context == nil {
		fmt.eprintln("Failed to create ImGui context")
		return false
	}

	io := imgui.get_io()
	io.config_flags += {.Docking_Enable}
	apply_ui_theme(editor_runtime.theme.active_theme, io, false)

	if imgui_layout_path != "" && os.exists(imgui_layout_path) {
		layout_path_c, alloc_err := strings.clone_to_cstring(imgui_layout_path)
		if alloc_err != nil {
			fmt.eprintln("Failed to allocate ImGui layout path cstring")
		} else {
			imgui.load_ini_settings_from_disk(layout_path_c)
			delete(layout_path_c)
		}
	}

	switch backend {
	case .OpenGL:
		if !imgui_glfw.init_for_open_gl(window, true) {
			fmt.eprintln("Failed to initialize ImGui GLFW backend")
			imgui.destroy_context(imgui_context)
			imgui_context = nil
			return false
		}

		if !imgui_gl3.init("#version 450") {
			fmt.eprintln("Failed to initialize ImGui OpenGL3 backend")
			imgui_glfw.shutdown()
			imgui.destroy_context(imgui_context)
			imgui_context = nil
			return false
		}
	case .SDL3, .Vulkan, .Raylib, .Software:
		fmt.eprintln("Editor ImGui backend is not wired for:", ui_backend(backend))
		imgui.destroy_context(imgui_context)
		imgui_context = nil
		return false
	case .Undefined:
		fmt.eprintln("renderer_backend in", active_game_config_path_label(), "is missing or unknown")
		imgui.destroy_context(imgui_context)
		imgui_context = nil
		return false
	}

	return true
}

@(private) apply_terracotta_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.grab_rounding = 6
	style.tab_rounding = 6
	style.scrollbar_rounding = 8
	style.window_border_size = 1
	style.frame_border_size = 1
	style.popup_border_size = 1
	style.item_spacing = {8, 7}
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Text] = {0.21, 0.13, 0.10, 1.00}
	style.colors[imgui.Col.Text_Disabled] = {0.47, 0.35, 0.30, 1.00}
	style.colors[imgui.Col.Window_Bg] = {0.99, 0.95, 0.90, 1.00}
	style.colors[imgui.Col.Child_Bg] = {0.98, 0.92, 0.86, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {0.99, 0.93, 0.87, 1.00}
	style.colors[imgui.Col.Border] = {0.76, 0.50, 0.39, 0.90}
	style.colors[imgui.Col.Border_Shadow] = {0.00, 0.00, 0.00, 0.00}
	style.colors[imgui.Col.Frame_Bg] = {0.95, 0.79, 0.68, 0.85}
	style.colors[imgui.Col.Frame_Bg_Hovered] = {0.92, 0.67, 0.53, 0.95}
	style.colors[imgui.Col.Frame_Bg_Active] = {0.84, 0.48, 0.34, 1.00}
	style.colors[imgui.Col.Title_Bg] = {0.85, 0.51, 0.36, 0.90}
	style.colors[imgui.Col.Title_Bg_Active] = {0.74, 0.37, 0.27, 1.00}
	style.colors[imgui.Col.Title_Bg_Collapsed] = {0.84, 0.54, 0.39, 0.70}
	style.colors[imgui.Col.Menu_Bar_Bg] = {0.96, 0.84, 0.73, 1.00}
	style.colors[imgui.Col.Scrollbar_Bg] = {0.95, 0.84, 0.74, 0.65}
	style.colors[imgui.Col.Scrollbar_Grab] = {0.83, 0.53, 0.39, 0.75}
	style.colors[imgui.Col.Scrollbar_Grab_Hovered] = {0.79, 0.44, 0.31, 0.90}
	style.colors[imgui.Col.Scrollbar_Grab_Active] = {0.69, 0.34, 0.24, 1.00}
	style.colors[imgui.Col.Check_Mark] = {0.67, 0.26, 0.16, 1.00}
	style.colors[imgui.Col.Slider_Grab] = {0.77, 0.40, 0.27, 0.90}
	style.colors[imgui.Col.Slider_Grab_Active] = {0.66, 0.25, 0.16, 1.00}
	style.colors[imgui.Col.Button] = {0.86, 0.56, 0.43, 0.90}
	style.colors[imgui.Col.Button_Hovered] = {0.80, 0.45, 0.33, 1.00}
	style.colors[imgui.Col.Button_Active] = {0.68, 0.32, 0.23, 1.00}
	style.colors[imgui.Col.Header] = {0.92, 0.71, 0.59, 0.80}
	style.colors[imgui.Col.Header_Hovered] = {0.86, 0.56, 0.43, 0.95}
	style.colors[imgui.Col.Header_Active] = {0.75, 0.40, 0.29, 1.00}
	style.colors[imgui.Col.Separator] = {0.75, 0.51, 0.40, 0.80}
	style.colors[imgui.Col.Separator_Hovered] = {0.74, 0.43, 0.32, 0.95}
	style.colors[imgui.Col.Separator_Active] = {0.66, 0.34, 0.25, 1.00}
	style.colors[imgui.Col.Resize_Grip] = {0.73, 0.41, 0.30, 0.55}
	style.colors[imgui.Col.Resize_Grip_Hovered] = {0.70, 0.34, 0.25, 0.85}
	style.colors[imgui.Col.Resize_Grip_Active] = {0.61, 0.28, 0.20, 1.00}
	style.colors[imgui.Col.Tab] = {0.90, 0.70, 0.59, 0.80}
	style.colors[imgui.Col.Tab_Hovered] = {0.84, 0.52, 0.39, 0.95}
	style.colors[imgui.Col.Tab_Selected] = {0.75, 0.39, 0.28, 0.95}
	style.colors[imgui.Col.Tab_Dimmed] = {0.93, 0.78, 0.69, 0.75}
	style.colors[imgui.Col.Tab_Dimmed_Selected] = {0.83, 0.58, 0.46, 0.85}
	style.colors[imgui.Col.Docking_Preview] = {0.72, 0.36, 0.25, 0.60}
	style.colors[imgui.Col.Docking_Empty_Bg] = {0.99, 0.94, 0.88, 1.00}
	style.colors[imgui.Col.Table_Header_Bg] = {0.92, 0.73, 0.62, 0.85}
	style.colors[imgui.Col.Table_Border_Strong] = {0.78, 0.53, 0.42, 0.95}
	style.colors[imgui.Col.Table_Border_Light] = {0.82, 0.66, 0.56, 0.70}
	style.colors[imgui.Col.Table_Row_Bg] = {1.00, 0.97, 0.94, 0.55}
	style.colors[imgui.Col.Table_Row_Bg_Alt] = {0.98, 0.91, 0.85, 0.55}
	style.colors[imgui.Col.Text_Selected_Bg] = {0.80, 0.46, 0.33, 0.45}
	style.colors[imgui.Col.Drag_Drop_Target] = {0.70, 0.26, 0.16, 0.95}
	style.colors[imgui.Col.Nav_Cursor] = {0.69, 0.27, 0.17, 0.90}
	style.colors[imgui.Col.Modal_Window_Dim_Bg] = {0.36, 0.20, 0.14, 0.24}

	io.font_global_scale = 1.04
	set_ui_clear_color(0.99, 0.94, 0.88, 1.00)
}

@(private) apply_light_orange_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.grab_rounding = 6
	style.tab_rounding = 6
	style.scrollbar_rounding = 8
	style.window_border_size = 1
	style.frame_border_size = 1
	style.popup_border_size = 1
	style.item_spacing = {8, 7}
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Text] = {0.23, 0.16, 0.09, 1.00}
	style.colors[imgui.Col.Text_Disabled] = {0.55, 0.44, 0.33, 1.00}
	style.colors[imgui.Col.Window_Bg] = {1.00, 0.96, 0.84, 1.00}
	style.colors[imgui.Col.Child_Bg] = {1.00, 0.97, 0.88, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {1.00, 0.96, 0.86, 1.00}
	style.colors[imgui.Col.Border] = {0.90, 0.73, 0.54, 0.85}
	style.colors[imgui.Col.Border_Shadow] = {0.00, 0.00, 0.00, 0.00}
	style.colors[imgui.Col.Frame_Bg] = {1.00, 0.91, 0.78, 0.75}
	style.colors[imgui.Col.Frame_Bg_Hovered] = {1.00, 0.84, 0.63, 0.85}
	style.colors[imgui.Col.Frame_Bg_Active] = {0.98, 0.76, 0.49, 0.90}
	style.colors[imgui.Col.Title_Bg] = {0.95, 0.73, 0.47, 0.88}
	style.colors[imgui.Col.Title_Bg_Active] = {0.95, 0.64, 0.33, 0.95}
	style.colors[imgui.Col.Title_Bg_Collapsed] = {0.94, 0.72, 0.49, 0.70}
	style.colors[imgui.Col.Menu_Bar_Bg] = {0.99, 0.92, 0.82, 1.00}
	style.colors[imgui.Col.Scrollbar_Bg] = {0.98, 0.91, 0.80, 0.65}
	style.colors[imgui.Col.Scrollbar_Grab] = {0.94, 0.70, 0.41, 0.75}
	style.colors[imgui.Col.Scrollbar_Grab_Hovered] = {0.95, 0.60, 0.28, 0.88}
	style.colors[imgui.Col.Scrollbar_Grab_Active] = {0.93, 0.53, 0.22, 0.95}
	style.colors[imgui.Col.Check_Mark] = {0.86, 0.42, 0.10, 1.00}
	style.colors[imgui.Col.Slider_Grab] = {0.92, 0.53, 0.19, 0.85}
	style.colors[imgui.Col.Slider_Grab_Active] = {0.86, 0.42, 0.10, 1.00}
	style.colors[imgui.Col.Button] = {0.95, 0.72, 0.45, 0.85}
	style.colors[imgui.Col.Button_Hovered] = {0.95, 0.62, 0.30, 0.95}
	style.colors[imgui.Col.Button_Active] = {0.88, 0.49, 0.17, 1.00}
	style.colors[imgui.Col.Header] = {0.98, 0.82, 0.60, 0.80}
	style.colors[imgui.Col.Header_Hovered] = {0.98, 0.73, 0.45, 0.95}
	style.colors[imgui.Col.Header_Active] = {0.91, 0.56, 0.24, 1.00}
	style.colors[imgui.Col.Separator] = {0.88, 0.66, 0.44, 0.70}
	style.colors[imgui.Col.Separator_Hovered] = {0.90, 0.57, 0.28, 0.90}
	style.colors[imgui.Col.Separator_Active] = {0.85, 0.50, 0.23, 1.00}
	style.colors[imgui.Col.Resize_Grip] = {0.90, 0.56, 0.25, 0.45}
	style.colors[imgui.Col.Resize_Grip_Hovered] = {0.90, 0.52, 0.20, 0.80}
	style.colors[imgui.Col.Resize_Grip_Active] = {0.85, 0.45, 0.16, 1.00}
	style.colors[imgui.Col.Tab] = {0.97, 0.83, 0.65, 0.75}
	style.colors[imgui.Col.Tab_Hovered] = {0.96, 0.69, 0.40, 0.90}
	style.colors[imgui.Col.Tab_Selected] = {0.95, 0.62, 0.30, 0.95}
	style.colors[imgui.Col.Tab_Dimmed] = {0.97, 0.87, 0.74, 0.75}
	style.colors[imgui.Col.Tab_Dimmed_Selected] = {0.95, 0.73, 0.49, 0.85}
	style.colors[imgui.Col.Docking_Preview] = {0.95, 0.57, 0.22, 0.60}
	style.colors[imgui.Col.Docking_Empty_Bg] = {1.00, 0.95, 0.82, 1.00}
	style.colors[imgui.Col.Table_Header_Bg] = {0.97, 0.84, 0.65, 0.85}
	style.colors[imgui.Col.Table_Border_Strong] = {0.89, 0.69, 0.48, 0.95}
	style.colors[imgui.Col.Table_Border_Light] = {0.91, 0.78, 0.64, 0.70}
	style.colors[imgui.Col.Table_Row_Bg] = {1.00, 0.98, 0.95, 0.55}
	style.colors[imgui.Col.Table_Row_Bg_Alt] = {1.00, 0.95, 0.87, 0.55}
	style.colors[imgui.Col.Text_Selected_Bg] = {0.99, 0.76, 0.42, 0.55}
	style.colors[imgui.Col.Drag_Drop_Target] = {0.97, 0.50, 0.10, 0.95}
	style.colors[imgui.Col.Nav_Cursor] = {0.90, 0.50, 0.13, 0.80}
	style.colors[imgui.Col.Modal_Window_Dim_Bg] = {0.45, 0.30, 0.17, 0.20}

	io.font_global_scale = 1.04
	set_ui_clear_color(1.00, 0.95, 0.82, 1.00)
}

@(private) apply_citrus_sand_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.tab_rounding = 6
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Text] = {0.23, 0.15, 0.09, 1.00}
	style.colors[imgui.Col.Text_Disabled] = {0.48, 0.38, 0.29, 1.00}
	style.colors[imgui.Col.Window_Bg] = {1.00, 0.95, 0.84, 1.00}
	style.colors[imgui.Col.Child_Bg] = {1.00, 0.91, 0.75, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {1.00, 0.93, 0.79, 1.00}
	style.colors[imgui.Col.Border] = {0.85, 0.71, 0.53, 0.90}
	style.colors[imgui.Col.Frame_Bg] = {1.00, 0.86, 0.64, 0.80}
	style.colors[imgui.Col.Frame_Bg_Hovered] = {0.97, 0.74, 0.44, 0.90}
	style.colors[imgui.Col.Frame_Bg_Active] = {0.89, 0.48, 0.18, 0.95}
	style.colors[imgui.Col.Button] = {0.89, 0.48, 0.18, 0.84}
	style.colors[imgui.Col.Button_Hovered] = {0.79, 0.38, 0.12, 0.95}
	style.colors[imgui.Col.Button_Active] = {0.72, 0.31, 0.10, 1.00}
	style.colors[imgui.Col.Header] = {0.94, 0.70, 0.42, 0.82}
	style.colors[imgui.Col.Header_Hovered] = {0.89, 0.53, 0.23, 0.95}
	style.colors[imgui.Col.Header_Active] = {0.82, 0.40, 0.16, 1.00}
	style.colors[imgui.Col.Tab] = {0.96, 0.80, 0.56, 0.80}
	style.colors[imgui.Col.Tab_Hovered] = {0.92, 0.60, 0.30, 0.95}
	style.colors[imgui.Col.Tab_Selected] = {0.89, 0.48, 0.18, 0.92}

	io.font_global_scale = 1.00
	set_ui_clear_color(1.00, 0.95, 0.84, 1.00)
}

@(private) apply_apricot_paper_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.tab_rounding = 6
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Text] = {0.20, 0.14, 0.10, 1.00}
	style.colors[imgui.Col.Text_Disabled] = {0.46, 0.37, 0.30, 1.00}
	style.colors[imgui.Col.Window_Bg] = {1.00, 0.96, 0.91, 1.00}
	style.colors[imgui.Col.Child_Bg] = {1.00, 0.93, 0.85, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {1.00, 0.94, 0.88, 1.00}
	style.colors[imgui.Col.Border] = {0.84, 0.66, 0.50, 0.85}
	style.colors[imgui.Col.Frame_Bg] = {0.99, 0.86, 0.73, 0.78}
	style.colors[imgui.Col.Frame_Bg_Hovered] = {0.93, 0.73, 0.54, 0.90}
	style.colors[imgui.Col.Frame_Bg_Active] = {0.85, 0.54, 0.32, 0.95}
	style.colors[imgui.Col.Button] = {0.85, 0.54, 0.32, 0.82}
	style.colors[imgui.Col.Button_Hovered] = {0.78, 0.45, 0.26, 0.95}
	style.colors[imgui.Col.Button_Active] = {0.68, 0.36, 0.20, 1.00}
	style.colors[imgui.Col.Header] = {0.92, 0.74, 0.56, 0.82}
	style.colors[imgui.Col.Header_Hovered] = {0.86, 0.58, 0.38, 0.95}
	style.colors[imgui.Col.Header_Active] = {0.76, 0.44, 0.24, 1.00}
	style.colors[imgui.Col.Tab] = {0.95, 0.82, 0.66, 0.78}
	style.colors[imgui.Col.Tab_Hovered] = {0.90, 0.64, 0.43, 0.94}
	style.colors[imgui.Col.Tab_Selected] = {0.82, 0.50, 0.30, 0.92}

	io.font_global_scale = 1.00
	set_ui_clear_color(1.00, 0.96, 0.91, 1.00)
}

@(private) apply_ocean_mist_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.tab_rounding = 6
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Text] = {0.11, 0.20, 0.24, 1.00}
	style.colors[imgui.Col.Window_Bg] = {0.93, 0.97, 0.97, 1.00}
	style.colors[imgui.Col.Child_Bg] = {0.89, 0.95, 0.95, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {0.92, 0.96, 0.96, 1.00}
	style.colors[imgui.Col.Button] = {0.28, 0.62, 0.66, 0.80}
	style.colors[imgui.Col.Button_Hovered] = {0.21, 0.54, 0.58, 0.92}
	style.colors[imgui.Col.Button_Active] = {0.15, 0.43, 0.47, 1.00}
	style.colors[imgui.Col.Header] = {0.45, 0.73, 0.75, 0.75}
	style.colors[imgui.Col.Tab_Selected] = {0.20, 0.54, 0.58, 0.90}

	io.font_global_scale = 1.04
	set_ui_clear_color(0.93, 0.97, 0.97, 1.00)
}

@(private) apply_olive_studio_theme :: proc(io: ^imgui.IO) {
	imgui.style_colors_light(nil)

	style := imgui.get_style()
	style.window_rounding = 7
	style.child_rounding = 6
	style.popup_rounding = 6
	style.frame_rounding = 6
	style.tab_rounding = 6
	style.frame_padding = {10, 6}
	style.window_padding = {10, 10}

	style.colors[imgui.Col.Text] = {0.19, 0.22, 0.14, 1.00}
	style.colors[imgui.Col.Window_Bg] = {0.95, 0.95, 0.86, 1.00}
	style.colors[imgui.Col.Child_Bg] = {0.90, 0.91, 0.78, 1.00}
	style.colors[imgui.Col.Popup_Bg] = {0.93, 0.94, 0.82, 1.00}
	style.colors[imgui.Col.Button] = {0.46, 0.57, 0.33, 0.82}
	style.colors[imgui.Col.Button_Hovered] = {0.37, 0.48, 0.26, 0.95}
	style.colors[imgui.Col.Button_Active] = {0.29, 0.39, 0.20, 1.00}
	style.colors[imgui.Col.Header] = {0.62, 0.70, 0.46, 0.80}
	style.colors[imgui.Col.Tab_Selected] = {0.36, 0.46, 0.24, 0.90}

	io.font_global_scale = 1.04
	set_ui_clear_color(0.95, 0.95, 0.86, 1.00)
}

@(private) shutdown_imgui :: proc(backend: Ui_Render_Backend) {
	if imgui_context == nil {
		return
	}

	if imgui_layout_path != "" {
		layout_path_c, alloc_err := strings.clone_to_cstring(imgui_layout_path)
		if alloc_err != nil {
			fmt.eprintln("Failed to allocate ImGui layout path cstring")
		} else {
			imgui.save_ini_settings_to_disk(layout_path_c)
			delete(layout_path_c)
		}
	}

	switch backend {
	case .SDL3, .Vulkan, .Raylib, .Software, .Undefined: fmt.println("No shutdown implemented for ImGui backend:", ui_backend(backend))
		break
	case .OpenGL:
		imgui_gl3.shutdown()
		imgui_glfw.shutdown()
	}

	imgui.destroy_context(imgui_context)
	imgui_context = nil
}

@(private) begin_imgui_frame :: proc(backend: Ui_Render_Backend) {
	switch backend {
	case .OpenGL:
		imgui_gl3.new_frame()
		imgui_glfw.new_frame()
	case .SDL3, .Vulkan, .Raylib, .Software, .Undefined:
		return
	}
	imgui.new_frame()
}

@(private) end_imgui_frame :: proc(backend: Ui_Render_Backend, fb_width, fb_height: i32) {
	imgui.render()

	switch backend {
	case .OpenGL:
		gl.Viewport(0, 0, fb_width, fb_height)
		gl.ClearColor(editor_runtime.theme.clear_color[0], editor_runtime.theme.clear_color[1], editor_runtime.theme.clear_color[2], editor_runtime.theme.clear_color[3])
		gl.Clear(gl.COLOR_BUFFER_BIT)
		imgui_gl3.render_draw_data(imgui.get_draw_data())
		glfw.SwapBuffers(window)
	case .SDL3, .Vulkan, .Raylib, .Software, .Undefined:
		return
	}
}

@(private) draw_directory_tree :: proc() {
	if imgui.begin("Directory Tree") {
		if imgui.begin_combo("File-visibility", "Select file types") {
			_ = imgui.checkbox("show .png", &editor_runtime.directory_tree.show_png)
			_ = imgui.checkbox("show .skm", &editor_runtime.directory_tree.show_skm)
			_ = imgui.checkbox("show .sm", &editor_runtime.directory_tree.show_sm)
			_ = imgui.checkbox("show .mtl", &editor_runtime.directory_tree.show_mtl)
			imgui.end_combo()
		}

		root_path := resolve_project_root_path()
		root_open := imgui.tree_node("Ymir-Engine")
		if imgui.is_item_clicked(.Right) {
			set_directory_tree_selection(root_path, true)
			imgui.open_popup("dir_ctx_root")
		}
		if imgui.begin_popup("dir_ctx_root") {
			if imgui.menu_item("add-folder") {
				queue_create_folder_popup(root_path)
				imgui.close_current_popup()
			}
			imgui.end_popup()
		}
		if root_open {
			draw_directory_entries(root_path, root_path)
			imgui.tree_pop()
		}

		imgui.separator()
		imgui.text("Selected:")
		if editor_runtime.directory_tree.selected_path != "" {
			imgui.same_line()
			selected_path_c, alloc_err := strings.clone_to_cstring(editor_runtime.directory_tree.selected_path)
			if alloc_err == nil {
				imgui.text("%s", selected_path_c)
				delete(selected_path_c)
			}
		}
		draw_create_folder_modal()
		draw_delete_folder_modal()
	}
	imgui.end()
}

@(private) resolve_project_root_path :: proc() -> string {
	candidates := [2]string{".", ".."}
	for candidate in candidates {
		app_path := strings.concatenate({candidate, "/App"}, context.temp_allocator)
		engine_path := strings.concatenate({candidate, "/Engine"}, context.temp_allocator)
		if os.exists(app_path) && os.exists(engine_path) {
			return candidate
		}
	}

	return "."
}

@(private) clear_directory_cache :: proc() {
	for i in 0 ..< len(editor_runtime.directory_cache.paths) {
		if editor_runtime.directory_cache.paths[i] != "" {
			delete(editor_runtime.directory_cache.paths[i])
		}
		os.file_info_slice_delete(editor_runtime.directory_cache.entries[i], context.allocator)
	}

	delete(editor_runtime.directory_cache.paths)
	delete(editor_runtime.directory_cache.entries)
	editor_runtime.directory_cache.paths = nil
	editor_runtime.directory_cache.entries = nil
}

@(private) invalidate_directory_cache :: proc() {
	clear_directory_cache()
}

@(private) get_cached_directory_entries :: proc(path: string) -> (entries: []os.File_Info, ok: bool) {
	for i in 0 ..< len(editor_runtime.directory_cache.paths) {
		if editor_runtime.directory_cache.paths[i] == path {
			return editor_runtime.directory_cache.entries[i], true
		}
	}

	fresh_entries, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		return nil, false
	}
	sort_directory_entries(fresh_entries)

	cloned_path, clone_err := strings.clone(path, context.allocator)
	if clone_err != nil {
		os.file_info_slice_delete(fresh_entries, context.allocator)
		return nil, false
	}

	append(&editor_runtime.directory_cache.paths, cloned_path)
	append(&editor_runtime.directory_cache.entries, fresh_entries)
	return fresh_entries, true
}

@(private) draw_directory_entries :: proc(path: string, root_path: string) {
	entries, ok := get_cached_directory_entries(path)
	if !ok {
		imgui.text("Failed to read directory")
		return
	}

	for entry in entries {
		if entry.type == .Directory {
			if entry.name == ".git" {
				continue
			}
			if editor_runtime.directory_tree.hide_non_primary_root_dirs && path == root_path {
				if entry.name != "App" && entry.name != "Editor" {
					continue
				}
			}

			flags: imgui.Tree_Node_Flags = {.Span_Avail_Width}
			if editor_runtime.directory_tree.selected_is_dir && editor_runtime.directory_tree.selected_path == entry.fullpath {
				flags += {.Selected}
			}

			entry_name_c, name_alloc_err := strings.clone_to_cstring(entry.name)
			if name_alloc_err != nil {
				continue
			}

			if imgui.tree_node_ex(entry_name_c, flags) {
			context_menu_id := strings.concatenate({"dir_ctx::", entry.fullpath}, context.temp_allocator)
			context_menu_id_c, ctx_alloc_err := strings.clone_to_cstring(context_menu_id)
				delete_allowed := !is_folder_protected_from_deletion(entry.fullpath)
				delete(entry_name_c)
				if ctx_alloc_err == nil {
					if imgui.is_item_clicked(.Right) {
						set_directory_tree_selection(entry.fullpath, true)
						imgui.open_popup(context_menu_id_c)
					}
					if imgui.begin_popup(context_menu_id_c) {
						if imgui.menu_item("add-folder") {
							queue_create_folder_popup(entry.fullpath)
							imgui.close_current_popup()
						}
						imgui.begin_disabled(!delete_allowed)
						if imgui.menu_item("delete-folder") && delete_allowed {
							queue_delete_folder_modal(entry.fullpath)
							imgui.close_current_popup()
						}
						imgui.end_disabled()
						imgui.end_popup()
					}
					delete(context_menu_id_c)
				}
				if imgui.is_item_clicked() {
					set_directory_tree_selection(entry.fullpath, true)
				}
				draw_directory_entries(entry.fullpath, root_path)
				imgui.tree_pop()
			} else {
				context_menu_id := strings.concatenate({"dir_ctx::", entry.fullpath}, context.temp_allocator)
				context_menu_id_c, ctx_alloc_err := strings.clone_to_cstring(context_menu_id)
				delete_allowed := !is_folder_protected_from_deletion(entry.fullpath)
				delete(entry_name_c)
				if ctx_alloc_err == nil {
					if imgui.is_item_clicked(.Right) {
						set_directory_tree_selection(entry.fullpath, true)
						imgui.open_popup(context_menu_id_c)
					}
					if imgui.begin_popup(context_menu_id_c) {
						if imgui.menu_item("add-folder") {
							queue_create_folder_popup(entry.fullpath)
							imgui.close_current_popup()
						}
						imgui.begin_disabled(!delete_allowed)
						if imgui.menu_item("delete-folder") && delete_allowed {
							queue_delete_folder_modal(entry.fullpath)
							imgui.close_current_popup()
						}
						imgui.end_disabled()
						imgui.end_popup()
					}
					delete(context_menu_id_c)
				}
				if imgui.is_item_clicked() {
					set_directory_tree_selection(entry.fullpath, true)
				}
			}
		}
	}

	for entry in entries {
		if entry.type != .Directory {
			if !directory_tree_file_visible(entry.name) {
				continue
			}

			flags: imgui.Tree_Node_Flags = {.Leaf, .No_Tree_Push_On_Open, .Span_Avail_Width}
			if !editor_runtime.directory_tree.selected_is_dir && editor_runtime.directory_tree.selected_path == entry.fullpath {
				flags += {.Selected}
			}

			entry_name_c, name_alloc_err := strings.clone_to_cstring(entry.name)
			if name_alloc_err != nil {
				continue
			}

			_ = imgui.tree_node_ex(entry_name_c, flags)
			delete(entry_name_c)
			if imgui.is_item_clicked() {
				set_directory_tree_selection(entry.fullpath, false)
			}
		}
	}
}

@(private) delete_folder_recursive :: proc(path: string) {
	if is_folder_protected_from_deletion(path) {
		return
	}

	err := os.remove_all(path)
	if err != nil {
		fmt.eprintln("Failed to delete folder:", path, "-", err)
		return
	}

	if editor_runtime.directory_tree.selected_path != "" && editor_runtime.directory_tree.selected_path == path {
		parent, _ := os.split_path(path)
		if parent == "" {
			parent = resolve_project_root_path()
		}
		set_directory_tree_selection(parent, true)
	}

	invalidate_directory_cache()
}

@(private) queue_delete_folder_modal :: proc(path: string) {
	if is_folder_protected_from_deletion(path) {
		return
	}

	if editor_runtime.directory_tree.delete_folder_target_path != "" {
		delete(editor_runtime.directory_tree.delete_folder_target_path)
		editor_runtime.directory_tree.delete_folder_target_path = ""
	}

	cloned, err := strings.clone(path, context.allocator)
	if err != nil {
		return
	}

	editor_runtime.directory_tree.delete_folder_target_path = cloned
	editor_runtime.directory_tree.delete_folder_open_modal = true
}

@(private) is_folder_protected_from_deletion :: proc(folder: string) -> bool {
	root_path := resolve_project_root_path()
	root_abs, root_err := os.get_absolute_path(root_path, context.temp_allocator)
	folder_abs, folder_err := os.get_absolute_path(folder, context.temp_allocator)
	if root_err != nil || folder_err != nil {
		return true
	}

	root_norm := normalize_import_gate_path(root_abs)
	folder_norm := normalize_import_gate_path(folder_abs)
	app_root := strings.concatenate({root_norm, "/app"}, context.temp_allocator)
	editor_root := strings.concatenate({root_norm, "/editor"}, context.temp_allocator)
	engine_root := strings.concatenate({root_norm, "/engine"}, context.temp_allocator)
	config_root := strings.concatenate({app_root, "/config"}, context.temp_allocator)
	levels_root := strings.concatenate({app_root, "/levels"}, context.temp_allocator)

	if folder_norm == app_root || folder_norm == editor_root {
		return true
	}

	if folder_norm == config_root || folder_norm == levels_root {
		return true
	}

	if folder_norm == engine_root || strings.has_prefix(folder_norm, strings.concatenate({engine_root, "/"}, context.temp_allocator)) {
		return true
	}

	return false
}

@(private) draw_delete_folder_modal :: proc() {
	if editor_runtime.directory_tree.delete_folder_open_modal {
		imgui.open_popup("Delete Folder")
		editor_runtime.directory_tree.delete_folder_open_modal = false
	}

	if !imgui.begin_popup_modal("Delete Folder") {
		return
	}

	imgui.text("This will delete the folder and all of it's contents. Are you sure?")
	if editor_runtime.directory_tree.delete_folder_target_path != "" {
		path_c, path_err := strings.clone_to_cstring(editor_runtime.directory_tree.delete_folder_target_path)
		if path_err == nil {
			imgui.text("%s", path_c)
			delete(path_c)
		}
	}

	ok := imgui.button("OK")
	imgui.same_line()
	cancel := imgui.button("Cancel")

	if ok {
		if editor_runtime.directory_tree.delete_folder_target_path != "" {
			delete_folder_recursive(editor_runtime.directory_tree.delete_folder_target_path)
			delete(editor_runtime.directory_tree.delete_folder_target_path)
			editor_runtime.directory_tree.delete_folder_target_path = ""
		}
		imgui.close_current_popup()
	}

	if cancel {
		if editor_runtime.directory_tree.delete_folder_target_path != "" {
			delete(editor_runtime.directory_tree.delete_folder_target_path)
			editor_runtime.directory_tree.delete_folder_target_path = ""
		}
		imgui.close_current_popup()
	}

	imgui.end_popup()
}

@(private) queue_create_folder_popup :: proc(parent_path: string) {
	clear_create_folder_modal_state()

	cloned_parent, err := strings.clone(parent_path, context.allocator)
	if err != nil {
		return
	}
	editor_runtime.directory_tree.create_folder_parent_path = cloned_parent

	for i in 0 ..< len(editor_runtime.directory_tree.new_folder_name) {
		editor_runtime.directory_tree.new_folder_name[i] = 0
	}
	default_name := "New Folder"
	copy(editor_runtime.directory_tree.new_folder_name[:], default_name)

	editor_runtime.directory_tree.open_create_folder_popup = true
}

@(private) draw_create_folder_modal :: proc() {
	if editor_runtime.directory_tree.open_create_folder_popup {
		imgui.open_popup("Create Folder")
		editor_runtime.directory_tree.open_create_folder_popup = false
	}

	if imgui.begin_popup_modal("Create Folder") {
		if imgui.is_window_appearing() {
			imgui.set_keyboard_focus_here()
		}

		imgui.text("Parent:")
		imgui.same_line()
		if editor_runtime.directory_tree.create_folder_parent_path != "" {
			parent_c, alloc_err := strings.clone_to_cstring(editor_runtime.directory_tree.create_folder_parent_path)
			if alloc_err == nil {
				imgui.text("%s", parent_c)
				delete(parent_c)
			}
		}

		_ = imgui.input_text("Folder Name", cstring(&editor_runtime.directory_tree.new_folder_name[0]), uint(len(editor_runtime.directory_tree.new_folder_name)))

		if editor_runtime.directory_tree.create_folder_error != "" {
			err_c, err_alloc := strings.clone_to_cstring(editor_runtime.directory_tree.create_folder_error)
			if err_alloc == nil {
				imgui.text("%s", err_c)
				delete(err_c)
			}
		}

		confirm := imgui.button("OK")
		imgui.same_line()
		cancel := imgui.button("Cancel")

		if confirm {
			folder_name := strings.clone_from_cstring(cstring(&editor_runtime.directory_tree.new_folder_name[0]), context.temp_allocator)
			folder_name = strings.trim_space(folder_name)
			if folder_name == "" {
				set_create_folder_error("Folder name cannot be empty")
			} else {
				new_folder_path := strings.concatenate({editor_runtime.directory_tree.create_folder_parent_path, "/", folder_name}, context.temp_allocator)
				if err := os.make_directory(new_folder_path); err != nil {
					if err == .Exist {
						set_create_folder_error("Folder already exists")
					} else {
						set_create_folder_error(fmt.tprintf("Failed to create folder: %v", err))
					}
				} else {
					set_directory_tree_selection(new_folder_path, true)
					invalidate_directory_cache()
					clear_create_folder_modal_state()
					imgui.close_current_popup()
				}
			}
		}

		if cancel {
			clear_create_folder_modal_state()
			imgui.close_current_popup()
		}

		imgui.end_popup()
	}
}

@(private) set_create_folder_error :: proc(message: string) {
	if editor_runtime.directory_tree.create_folder_error != "" {
		delete(editor_runtime.directory_tree.create_folder_error)
		editor_runtime.directory_tree.create_folder_error = ""
	}

	cloned, err := strings.clone(message, context.allocator)
	if err == nil {
		editor_runtime.directory_tree.create_folder_error = cloned
	}
}

@(private) clear_create_folder_modal_state :: proc() {
	if editor_runtime.directory_tree.create_folder_parent_path != "" {
		delete(editor_runtime.directory_tree.create_folder_parent_path)
		editor_runtime.directory_tree.create_folder_parent_path = ""
	}
	if editor_runtime.directory_tree.create_folder_error != "" {
		delete(editor_runtime.directory_tree.create_folder_error)
		editor_runtime.directory_tree.create_folder_error = ""
	}
}

@(private) sort_directory_entries :: proc(entries: []os.File_Info) {
	for i in 0 ..< len(entries) {
		for j in i+1 ..< len(entries) {
			if directory_entry_less(entries[j], entries[i]) {
				tmp := entries[i]
				entries[i] = entries[j]
				entries[j] = tmp
			}
		}
	}
}

@(private) directory_entry_less :: proc(a, b: os.File_Info) -> bool {
	a_is_dir := a.type == .Directory
	b_is_dir := b.type == .Directory

	if a_is_dir != b_is_dir {
		return a_is_dir
	}

	return strings.compare(a.name, b.name) < 0
}

@(private) directory_tree_file_visible :: proc(name: string) -> bool {
	name_lower, _ := strings.to_lower(name, context.temp_allocator)

	if strings.has_suffix(name_lower, ".odin") ||
		strings.has_suffix(name_lower, ".ini") ||
		strings.has_suffix(name_lower, ".ps1") ||
		strings.has_suffix(name_lower, ".gitignore") ||
		strings.has_suffix(name_lower, ".md") ||
		strings.has_suffix(name_lower, ".exe") {
		return false
	}

	if strings.has_suffix(name_lower, ".png") {
		return editor_runtime.directory_tree.show_png
	}
	if strings.has_suffix(name_lower, ".skm") {
		return editor_runtime.directory_tree.show_skm
	}
	if strings.has_suffix(name_lower, ".sm") {
		return editor_runtime.directory_tree.show_sm
	}
	if strings.has_suffix(name_lower, ".mtl") {
		return editor_runtime.directory_tree.show_mtl
	}

	return true
}

@(private) set_directory_tree_selection :: proc(path: string, is_dir: bool) {
	if editor_runtime.directory_tree.selected_path != "" {
		delete(editor_runtime.directory_tree.selected_path)
		editor_runtime.directory_tree.selected_path = ""
	}

	cloned, err := strings.clone(path, context.allocator)
	if err != nil {
		editor_runtime.directory_tree.selected_is_dir = is_dir
		return
	}

	editor_runtime.directory_tree.selected_path = cloned
	editor_runtime.directory_tree.selected_is_dir = is_dir
}

@(private) set_asset_browser_error :: proc(message: string) {
	if editor_runtime.asset_browser.error != "" {
		delete(editor_runtime.asset_browser.error)
		editor_runtime.asset_browser.error = ""
	}

	if message == "" {
		return
	}

	cloned, err := strings.clone(message, context.allocator)
	if err == nil {
		editor_runtime.asset_browser.error = cloned
	}
}

@(private) set_selected_asset_path :: proc(path: string) {
	if editor_runtime.asset_browser.selected_asset_path != "" {
		delete(editor_runtime.asset_browser.selected_asset_path)
		editor_runtime.asset_browser.selected_asset_path = ""
	}

	cloned, err := strings.clone(path, context.allocator)
	if err == nil {
		editor_runtime.asset_browser.selected_asset_path = cloned
	}
}

@(private) clear_asset_import_state :: proc() {
	if editor_runtime.asset_browser.import_source_path != "" {
		delete(editor_runtime.asset_browser.import_source_path)
		editor_runtime.asset_browser.import_source_path = ""
	}
	editor_runtime.asset_browser.import_open_modal = false
}

@(private) queue_asset_delete_modal :: proc(path: string) {
	if editor_runtime.asset_browser.delete_target_path != "" {
		delete(editor_runtime.asset_browser.delete_target_path)
		editor_runtime.asset_browser.delete_target_path = ""
	}

	cloned, err := strings.clone(path, context.allocator)
	if err != nil {
		return
	}

	editor_runtime.asset_browser.delete_target_path = cloned
	editor_runtime.asset_browser.delete_open_modal = true
}

@(private) escape_ps_literal :: proc(value: string) -> string {
	escaped, _ := strings.replace_all(value, "'", "''", context.temp_allocator)
	return escaped
}

@(private) run_powershell_dialog_script :: proc(script_contents: string, result_file_name: string) -> string {
	root_path := resolve_project_root_path()
	script_path := strings.concatenate({root_path, "/Editor/.asset_dialog_temp.ps1"}, context.temp_allocator)
	result_path := strings.concatenate({root_path, "/Editor/", result_file_name}, context.temp_allocator)

	_ = os.remove(result_path)

	write_err := os.write_entire_file(
		script_path,
		script_contents,
		os.Permissions_Read_All + {.Write_User},
		true,
	)
	if write_err != nil {
		set_asset_browser_error(fmt.tprintf("Failed to write dialog script: %v", write_err))
		return ""
	}

	desc := os.Process_Desc{
		working_dir = root_path,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
		command = {
			"powershell.exe",
			"-NoProfile",
			"-ExecutionPolicy",
			"Bypass",
			"-STA",
			"-File",
			script_path,
		},
	}

	process_handle, start_err := os.process_start(desc)
	if start_err != nil {
		set_asset_browser_error(fmt.tprintf("Failed to open file dialog: %v", start_err))
		_ = os.remove(script_path)
		return ""
	}

	_, wait_err := os.process_wait(process_handle)
	_ = os.remove(script_path)
	if wait_err != nil {
		set_asset_browser_error(fmt.tprintf("File dialog process failed: %v", wait_err))
		return ""
	}

	raw, read_err := os.read_entire_file(result_path, context.allocator)
	_ = os.remove(result_path)
	if read_err != nil {
		return ""
	}
	defer delete(raw)

	path := strings.trim_space(string(raw))
	if path == "" {
		return ""
	}

	cloned, clone_err := strings.clone(path, context.allocator)
	if clone_err != nil {
		return ""
	}

	return cloned
}

@(private) open_file_dialog_for_import :: proc() -> string {
	root_path := resolve_project_root_path()
	result_path := strings.concatenate({root_path, "/Editor/.asset_import_result.txt"}, context.temp_allocator)
	result_path_ps := escape_ps_literal(result_path)

	script := strings.concatenate({
		"Add-Type -AssemblyName System.Windows.Forms\n",
		"$dialog = New-Object System.Windows.Forms.OpenFileDialog\n",
		"$dialog.Filter = 'All files (*.*)|*.*'\n",
		"$dialog.Multiselect = $false\n",
		"if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [System.IO.File]::WriteAllText('",
		result_path_ps,
		"', $dialog.FileName) }\n",
	}, context.temp_allocator)

	return run_powershell_dialog_script(script, ".asset_import_result.txt")
}

@(private) open_save_dialog_for_export :: proc(default_name: string) -> string {
	root_path := resolve_project_root_path()
	result_path := strings.concatenate({root_path, "/Editor/.asset_export_result.txt"}, context.temp_allocator)
	result_path_ps := escape_ps_literal(result_path)
	default_name_ps := escape_ps_literal(default_name)

	script := strings.concatenate({
		"Add-Type -AssemblyName System.Windows.Forms\n",
		"$dialog = New-Object System.Windows.Forms.SaveFileDialog\n",
		"$dialog.Filter = 'All files (*.*)|*.*'\n",
		"$dialog.FileName = '",
		default_name_ps,
		"'\n",
		"if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [System.IO.File]::WriteAllText('",
		result_path_ps,
		"', $dialog.FileName) }\n",
	}, context.temp_allocator)

	return run_powershell_dialog_script(script, ".asset_export_result.txt")
}

@(private) draw_asset_browser :: proc() {
	if imgui.begin("Asset Browser") {
		active_folder := resolve_active_folder_for_asset_browser()
		import_allowed := is_import_allowed_for_folder(active_folder)

		imgui.begin_disabled(!import_allowed)
		if imgui.button("Import Asset") {
			set_asset_browser_error("")
			source_path := open_file_dialog_for_import()
			if source_path != "" {
				clear_asset_import_state()
				cloned_source, clone_err := strings.clone(source_path, context.allocator)
				if clone_err == nil {
					editor_runtime.asset_browser.import_source_path = cloned_source
					_, source_file_name := os.split_path(source_path)
					for i in 0 ..< len(editor_runtime.asset_browser.import_target_name) {
						editor_runtime.asset_browser.import_target_name[i] = 0
					}
					copy(editor_runtime.asset_browser.import_target_name[:], source_file_name)
					editor_runtime.asset_browser.import_open_modal = true
				}
				delete(source_path)
			}
		}
		imgui.end_disabled()
		imgui.same_line()
		if imgui.button("Refresh") {
			invalidate_directory_cache()
			set_asset_browser_error("")
		}
		if !import_allowed {
			imgui.same_line()
			imgui.text_disabled("Import allowed only under App/ or Editor/")
		}

		imgui.separator_text("Assets")
		imgui.text("Folder:")
		imgui.same_line()
		folder_c, folder_alloc_err := strings.clone_to_cstring(active_folder)
		if folder_alloc_err == nil {
			imgui.text("%s", folder_c)
			delete(folder_c)
		}

		entries, ok := get_cached_directory_entries(active_folder)
		if !ok {
			imgui.text("Failed to read active folder")
			imgui.end()
			return
		}

		asset_count := 0
		for entry in entries {
			if entry.type == .Directory {
				continue
			}
			if !directory_tree_file_visible(entry.name) {
				continue
			}

			entry_name_c, entry_name_err := strings.clone_to_cstring(entry.name)
			if entry_name_err != nil {
				continue
			}

			is_selected := editor_runtime.asset_browser.selected_asset_path == entry.fullpath
			if imgui.selectable(entry_name_c, is_selected) {
				set_selected_asset_path(entry.fullpath)
			}

			menu_id := strings.concatenate({"asset_ctx::", entry.fullpath}, context.temp_allocator)
			menu_id_c, menu_id_err := strings.clone_to_cstring(menu_id)
			if menu_id_err == nil {
				if imgui.is_item_clicked(.Right) {
					set_selected_asset_path(entry.fullpath)
					imgui.open_popup(menu_id_c)
				}

				if is_selected && imgui.begin_popup(menu_id_c) {
					if imgui.menu_item("export-asset") {
						set_asset_browser_error("")
						target_path := open_save_dialog_for_export(entry.name)
						if target_path != "" {
							if err := os.copy_file(target_path, entry.fullpath); err != nil {
								set_asset_browser_error(fmt.tprintf("Asset export failed: %v", err))
							}
							delete(target_path)
						}
						imgui.close_current_popup()
					}
					if imgui.menu_item("delete-asset") {
						queue_asset_delete_modal(entry.fullpath)
						imgui.close_current_popup()
					}
					imgui.end_popup()
				}

				delete(menu_id_c)
			}

			delete(entry_name_c)
			asset_count += 1
		}

		if asset_count == 0 {
			imgui.text("No matching files in active folder")
		}

		if editor_runtime.asset_browser.error != "" {
			err_c, err_alloc := strings.clone_to_cstring(editor_runtime.asset_browser.error)
			if err_alloc == nil {
				imgui.text("%s", err_c)
				delete(err_c)
			}
		}

		draw_asset_import_modal(active_folder)
		draw_asset_delete_modal()
	}
	imgui.end()
}

@(private) is_import_allowed_for_folder :: proc(folder: string) -> bool {
	root_path := resolve_project_root_path()
	root_abs, root_err := os.get_absolute_path(root_path, context.temp_allocator)
	folder_abs, folder_err := os.get_absolute_path(folder, context.temp_allocator)
	if root_err != nil || folder_err != nil {
		return false
	}

	root_norm := normalize_import_gate_path(root_abs)
	folder_norm := normalize_import_gate_path(folder_abs)
	app_prefix := strings.concatenate({root_norm, "/app"}, context.temp_allocator)
	editor_prefix := strings.concatenate({root_norm, "/editor"}, context.temp_allocator)

	if folder_norm == app_prefix || strings.has_prefix(folder_norm, strings.concatenate({app_prefix, "/"}, context.temp_allocator)) {
		return true
	}
	if folder_norm == editor_prefix || strings.has_prefix(folder_norm, strings.concatenate({editor_prefix, "/"}, context.temp_allocator)) {
		return true
	}

	return false
}

@(private) normalize_import_gate_path :: proc(path: string) -> string {
	lower, _ := strings.to_lower(path, context.temp_allocator)
	normalized, _ := strings.replace_all(lower, "\\", "/", context.temp_allocator)
	for len(normalized) > 0 && normalized[len(normalized)-1] == '/' {
		normalized = normalized[:len(normalized)-1]
	}
	return normalized
}

@(private) draw_asset_delete_modal :: proc() {
	if editor_runtime.asset_browser.delete_open_modal {
		imgui.open_popup("Delete Asset")
		editor_runtime.asset_browser.delete_open_modal = false
	}

	if !imgui.begin_popup_modal("Delete Asset") {
		return
	}

	imgui.text("Delete selected asset?")
	if editor_runtime.asset_browser.delete_target_path != "" {
		path_c, path_err := strings.clone_to_cstring(editor_runtime.asset_browser.delete_target_path)
		if path_err == nil {
			imgui.text("%s", path_c)
			delete(path_c)
		}
	}

	ok := imgui.button("OK")
	imgui.same_line()
	cancel := imgui.button("Cancel")

	if ok {
		if editor_runtime.asset_browser.delete_target_path == "" {
			set_asset_browser_error("No asset selected for deletion")
		} else if err := os.remove(editor_runtime.asset_browser.delete_target_path); err != nil {
			set_asset_browser_error(fmt.tprintf("Asset delete failed: %v", err))
		} else {
			if editor_runtime.asset_browser.selected_asset_path == editor_runtime.asset_browser.delete_target_path {
				set_selected_asset_path("")
			}
			if editor_runtime.asset_browser.delete_target_path != "" {
				delete(editor_runtime.asset_browser.delete_target_path)
				editor_runtime.asset_browser.delete_target_path = ""
			}
			set_asset_browser_error("")
			invalidate_directory_cache()
			imgui.close_current_popup()
		}
	}

	if cancel {
		if editor_runtime.asset_browser.delete_target_path != "" {
			delete(editor_runtime.asset_browser.delete_target_path)
			editor_runtime.asset_browser.delete_target_path = ""
		}
		imgui.close_current_popup()
	}

	imgui.end_popup()
}

@(private) draw_asset_import_modal :: proc(active_folder: string) {
	if editor_runtime.asset_browser.import_open_modal {
		imgui.open_popup("Import Asset")
		editor_runtime.asset_browser.import_open_modal = false
	}

	if !imgui.begin_popup_modal("Import Asset") {
		return
	}

	imgui.text("Source:")
	imgui.same_line()
	if editor_runtime.asset_browser.import_source_path != "" {
		source_c, source_err := strings.clone_to_cstring(editor_runtime.asset_browser.import_source_path)
		if source_err == nil {
			imgui.text("%s", source_c)
			delete(source_c)
		}
	}

	imgui.text("Save into current folder as:")
	_ = imgui.input_text("Asset Name", cstring(&editor_runtime.asset_browser.import_target_name[0]), uint(len(editor_runtime.asset_browser.import_target_name)))

	confirm := imgui.button("OK")
	imgui.same_line()
	cancel := imgui.button("Cancel")

	if confirm {
		name := strings.clone_from_cstring(cstring(&editor_runtime.asset_browser.import_target_name[0]), context.temp_allocator)
		name = strings.trim_space(name)
		if name == "" {
			set_asset_browser_error("Asset name cannot be empty")
		} else if editor_runtime.asset_browser.import_source_path == "" {
			set_asset_browser_error("No source asset selected")
		} else {
			destination := strings.concatenate({active_folder, "/", name}, context.temp_allocator)
			if err := os.copy_file(destination, editor_runtime.asset_browser.import_source_path); err != nil {
				set_asset_browser_error(fmt.tprintf("Asset import failed: %v", err))
			} else {
				set_asset_browser_error("")
				set_selected_asset_path(destination)
				invalidate_directory_cache()
				clear_asset_import_state()
				imgui.close_current_popup()
			}
		}
	}

	if cancel {
		clear_asset_import_state()
		imgui.close_current_popup()
	}

	imgui.end_popup()
}

@(private) resolve_active_folder_for_asset_browser :: proc() -> string {
	if editor_runtime.directory_tree.selected_path == "" {
		return resolve_project_root_path()
	}

	if editor_runtime.directory_tree.selected_is_dir {
		return editor_runtime.directory_tree.selected_path
	}

	dir, _ := os.split_path(editor_runtime.directory_tree.selected_path)
	if dir == "" {
		return resolve_project_root_path()
	}

	return dir
}

@(private) draw_scene_panel :: proc() {
	if imgui.begin("Scene Graph") {
		imgui.text("Dock windows into the central workspace.")
		imgui.separator()
		imgui.text("Editor runtime is active.")
	}
	imgui.end()
}

@(private) draw_workspace_panel :: proc() {
	if imgui.begin("Workspace") {
		dock_id := imgui.get_id("EditorWorkspaceDock")
		_ = imgui.dock_space(dock_id, imgui.Vec2{0, 0})
	}
	imgui.end()
}

@(private) reset_editor_layout_to_defaults :: proc() {
	force_default_layout_next_frame = true

	if imgui_layout_path != "" && os.exists(imgui_layout_path) {
		if err := os.remove(imgui_layout_path); err != nil {
			fmt.eprintln("Failed to remove editor layout file:", imgui_layout_path, "-", err)
		}
	}
}

@(private) draw_top_toolbar :: proc() {
	if imgui.begin("Top Toolbar", nil, {.No_Title_Bar, .No_Collapse, .No_Docking, .No_Move, .No_Resize}) {
		if imgui.button("Reset Layout") {
			reset_editor_layout_to_defaults()
		}

		imgui.same_line()
		imgui.text("Theme")
		imgui.same_line()
		theme_preview := ui_theme_cstring(editor_runtime.theme.active_theme)

		if imgui.begin_combo("##ThemeSelector", theme_preview) {
			order := UI_THEME_ORDER
			labels := UI_THEME_LABELS
			for i in 0 ..< len(order) {
				theme := order[i]
				label := labels[i]
				if imgui.selectable(label, editor_runtime.theme.active_theme == theme) {
					queue_ui_theme_change(theme)
				}
			}
			imgui.end_combo()
		}
	}
	imgui.end()
}

@(private) draw_editor_ui :: proc() {
	viewport := imgui.get_main_viewport()
	if viewport == nil {
		return
	}

	_ = imgui.dock_space_over_viewport({}, viewport)

	scene_width: f32 = 360
	bottom_height: f32 = 220
	directory_width: f32 = 220
	top_toolbar_height: f32 = 34

	scene_x := viewport.work_pos.x + viewport.work_size.x - scene_width
	bottom_y := viewport.work_pos.y + viewport.work_size.y - bottom_height
	upper_y := viewport.work_pos.y + top_toolbar_height
	upper_height := viewport.work_size.y - bottom_height - top_toolbar_height
	asset_x := viewport.work_pos.x + directory_width
	asset_width := viewport.work_size.x - directory_width
	workspace_width := scene_x - viewport.work_pos.x

	if force_default_layout_next_frame {
		imgui.set_next_window_pos(viewport.work_pos, .Always)
		imgui.set_next_window_size(imgui.Vec2{viewport.work_size.x, top_toolbar_height}, .Always)
	} else {
		imgui.set_next_window_pos(viewport.work_pos, .First_Use_Ever)
		imgui.set_next_window_size(imgui.Vec2{viewport.work_size.x, top_toolbar_height}, .First_Use_Ever)
	}
	draw_top_toolbar()

	if force_default_layout_next_frame {
		imgui.set_next_window_pos(imgui.Vec2{viewport.work_pos.x, upper_y}, .Always)
		imgui.set_next_window_size(imgui.Vec2{workspace_width, upper_height}, .Always)
	} else {
		imgui.set_next_window_pos(imgui.Vec2{viewport.work_pos.x, upper_y}, .First_Use_Ever)
		imgui.set_next_window_size(imgui.Vec2{workspace_width, upper_height}, .First_Use_Ever)
	}
	draw_workspace_panel()

	if force_default_layout_next_frame {
		imgui.set_next_window_pos(imgui.Vec2{scene_x, upper_y}, .Always)
		imgui.set_next_window_size(imgui.Vec2{scene_width, upper_height}, .Always)
	} else {
		imgui.set_next_window_pos(imgui.Vec2{scene_x, upper_y}, .First_Use_Ever)
		imgui.set_next_window_size(imgui.Vec2{scene_width, upper_height}, .First_Use_Ever)
	}
	draw_scene_panel()

	if force_default_layout_next_frame {
		imgui.set_next_window_pos(imgui.Vec2{viewport.work_pos.x, bottom_y}, .Always)
		imgui.set_next_window_size(imgui.Vec2{directory_width, bottom_height}, .Always)
	} else {
		imgui.set_next_window_pos(imgui.Vec2{viewport.work_pos.x, bottom_y}, .First_Use_Ever)
		imgui.set_next_window_size(imgui.Vec2{directory_width, bottom_height}, .First_Use_Ever)
	}
	draw_directory_tree()

	if force_default_layout_next_frame {
		imgui.set_next_window_pos(imgui.Vec2{asset_x, bottom_y}, .Always)
		imgui.set_next_window_size(imgui.Vec2{asset_width, bottom_height}, .Always)
	} else {
		imgui.set_next_window_pos(imgui.Vec2{asset_x, bottom_y}, .First_Use_Ever)
		imgui.set_next_window_size(imgui.Vec2{asset_width, bottom_height}, .First_Use_Ever)
	}
	draw_asset_browser()

	if force_default_layout_next_frame {
		force_default_layout_next_frame = false
	}
}


main :: proc() {
	// Memory tracking
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    defer {
        for _, entry in track.allocation_map {
            fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
        }
        for entry in track.bad_free_array {
            fmt.eprintf("%v bad free\n", entry.location)
        }
        mem.tracking_allocator_destroy(&track)
    }
    // End memory tracking
	defer if editor_runtime.directory_tree.selected_path != "" {
		delete(editor_runtime.directory_tree.selected_path)
		editor_runtime.directory_tree.selected_path = ""
	}
	defer if editor_runtime.asset_browser.selected_asset_path != "" {
		delete(editor_runtime.asset_browser.selected_asset_path)
		editor_runtime.asset_browser.selected_asset_path = ""
	}
	defer if editor_runtime.asset_browser.error != "" {
		delete(editor_runtime.asset_browser.error)
		editor_runtime.asset_browser.error = ""
	}
	defer if editor_runtime.asset_browser.delete_target_path != "" {
		delete(editor_runtime.asset_browser.delete_target_path)
		editor_runtime.asset_browser.delete_target_path = ""
	}
	defer if editor_runtime.directory_tree.delete_folder_target_path != "" {
		delete(editor_runtime.directory_tree.delete_folder_target_path)
		editor_runtime.directory_tree.delete_folder_target_path = ""
	}
	defer clear_directory_cache()
	defer clear_asset_import_state()
	defer clear_create_folder_modal_state()


	startup_mode := ye.Engine_Startup.editor
	_ = startup_mode
	run_game := false

	config_path := resolve_editor_config_path()
	imgui_layout_path = resolve_imgui_layout_path()

	cfg, ok := load_editor_config(config_path)
	if !ok {
		return
	}
	defer free_editor_config(&cfg)

	editor_runtime.core.app_config_directory_path = cfg.app_config_directory_path
	editor_runtime.theme.active_theme = ui_theme_from_string(cfg.ui_theme)
	editor_runtime.theme.pending_theme = editor_runtime.theme.active_theme
	requested_backend := load_requested_ui_backend(cfg.app_config_directory_path)
	active_ui_backend = requested_backend

	if !create_window(cfg.editor_name, cfg.settings.window, active_ui_backend) {
		return
	}
	if !init_imgui(active_ui_backend) {
		destroy_window()
		return
	}
	defer shutdown_imgui(active_ui_backend)

    // Create game instance if running game from editor, otherwise just run editor windows.
	if run_game {
	    rungame()
	}
    

	for glfw.WindowShouldClose(window) == glfw.FALSE {
		glfw.PollEvents()
		process_pending_ui_theme_change()

		fb_width, fb_height := glfw.GetFramebufferSize(window)
		if fb_width <= 0 || fb_height <= 0 {
			continue
		}

		begin_imgui_frame(active_ui_backend)

		if RUNANIMATIONGRAPHEDITOR {
			run_animationgraph_editor()
		}
		if RUNMATERIALGRAPHEDITOR {
			run_materialgraph_editor()
		}
		if RUNLEVELEDITOR {
			run_level_editor()
		}

		draw_editor_ui()

		end_imgui_frame(active_ui_backend, fb_width, fb_height)
	}

	capture_main_window_settings(&cfg.settings.window)
	_ = set_editor_config_ui_theme(&cfg, editor_runtime.theme.active_theme)
	_ = save_editor_config(config_path, cfg)
	destroy_window()
}

@(private) resolve_imgui_layout_path :: proc() -> string {
	if os.exists("Editor") {
		return "Editor/editor_layout.ini"
	}
	return "editor_layout.ini"
}

@(private) default_window_settings :: proc(fullscreen: bool) -> Window_Settings {
	return Window_Settings{
		window_x = -1,
		window_y = -1,
		window_width = 1280,
		window_height = 720,
		fullscreen = fullscreen,
	}
}

@(private) default_editor_settings :: proc() -> Editor_Settings {
	return Editor_Settings{
		window = default_window_settings(true),
		animgraph = default_window_settings(false),
		materialgraph = default_window_settings(false),
		level = default_window_settings(false),
	}
}

@(private) default_editor_config :: proc() -> Editor_Config_File {
	return Editor_Config_File{
		editor_name = "",
		app_config_directory_path = "",
		ui_theme = "",
		settings = default_editor_settings(),
	}
}

@(private) ensure_editor_name :: proc(cfg: ^Editor_Config_File) -> bool {
	if cfg.editor_name != "" {
		return true
	}

	name, err := strings.clone("Ymir Editor", context.allocator)
	if err != nil {
		fmt.eprintln("Failed to allocate default editor name")
		return false
	}
	cfg.editor_name = name
	return true
}

@(private) ensure_app_config_directory_path :: proc(cfg: ^Editor_Config_File) -> bool {
	if cfg.app_config_directory_path != "" {
		return true
	}

	path, err := strings.clone("App/Config", context.allocator)
	if err != nil {
		fmt.eprintln("Failed to allocate default app config directory path")
		return false
	}
	cfg.app_config_directory_path = path
	return true
}

@(private) ensure_ui_theme :: proc(cfg: ^Editor_Config_File) -> bool {
	normalized := ui_theme(ui_theme_from_string(cfg.ui_theme))
	if cfg.ui_theme == normalized {
		return true
	}

	if cfg.ui_theme != "" {
		delete(cfg.ui_theme)
		cfg.ui_theme = ""
	}

	cloned, err := strings.clone(normalized, context.allocator)
	if err != nil {
		fmt.eprintln("Failed to allocate ui theme")
		return false
	}

	cfg.ui_theme = cloned
	return true
}

@(private) set_editor_config_ui_theme :: proc(cfg: ^Editor_Config_File, theme: Ui_Theme) -> bool {
	name := ui_theme(theme)
	if cfg.ui_theme == name {
		return true
	}

	if cfg.ui_theme != "" {
		delete(cfg.ui_theme)
		cfg.ui_theme = ""
	}

	cloned, err := strings.clone(name, context.allocator)
	if err != nil {
		fmt.eprintln("Failed to allocate ui theme")
		return false
	}

	cfg.ui_theme = cloned
	return true
}

@(private) free_editor_config :: proc(cfg: ^Editor_Config_File) {
	if cfg.editor_name != "" {
		delete(cfg.editor_name)
		cfg.editor_name = ""
	}
	if cfg.app_config_directory_path != "" {
		delete(cfg.app_config_directory_path)
		cfg.app_config_directory_path = ""
	}
	if cfg.ui_theme != "" {
		delete(cfg.ui_theme)
		cfg.ui_theme = ""
	}
}

@(private) normalize_window_settings :: proc(w: ^Window_Settings, fullscreen_default: bool) {
	if w.window_width <= 0 {
		w.window_width = 1280
	}
	if w.window_height <= 0 {
		w.window_height = 720
	}
	if w.window_x == 0 && w.window_y == 0 && w.window_width == 1280 && w.window_height == 720 && !w.fullscreen && fullscreen_default {
		// Likely zero-value from missing JSON section; first run should default fullscreen.
		w.fullscreen = true
		w.window_x = -1
		w.window_y = -1
	}
}

@(private) normalize_editor_settings :: proc(s: ^Editor_Settings) {
	normalize_window_settings(&s.window, true)
	normalize_window_settings(&s.animgraph, false)
	normalize_window_settings(&s.materialgraph, false)
	normalize_window_settings(&s.level, false)
}

@(private) resolve_editor_config_path :: proc() -> string {
	if os.exists("Editor") {
		return "Editor/editor.json"
	}
	return "editor.json"
}

@(private) load_editor_config :: proc(path: string) -> (cfg: Editor_Config_File, ok: bool) {
	cfg = default_editor_config()

	if !os.exists(path) {
		if !ensure_editor_name(&cfg) {
			return Editor_Config_File{}, false
		}
		if !ensure_app_config_directory_path(&cfg) {
			free_editor_config(&cfg)
			return Editor_Config_File{}, false
		}
		if !ensure_ui_theme(&cfg) {
			free_editor_config(&cfg)
			return Editor_Config_File{}, false
		}
		_ = save_editor_config(path, cfg)
		return cfg, true
	}

	raw, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read editor config:", read_err)
		return Editor_Config_File{}, false
	}
	defer delete(raw)

	if unmarshal_err := json.unmarshal(raw, &cfg); unmarshal_err != nil {
		fmt.eprintln("Failed to parse editor config:", unmarshal_err)
		free_editor_config(&cfg)
		return Editor_Config_File{}, false
	}

	if !ensure_editor_name(&cfg) {
		free_editor_config(&cfg)
		return Editor_Config_File{}, false
	}
	if !ensure_app_config_directory_path(&cfg) {
		free_editor_config(&cfg)
		return Editor_Config_File{}, false
	}
	if !ensure_ui_theme(&cfg) {
		free_editor_config(&cfg)
		return Editor_Config_File{}, false
	}
	normalize_editor_settings(&cfg.settings)
	return cfg, true
}

@(private) save_editor_config :: proc(path: string, cfg: Editor_Config_File) -> bool {
	out, err := json.marshal(cfg, allocator = context.temp_allocator)
	if err != nil {
		fmt.eprintln("Failed to serialize editor config:", err)
		return false
	}

	write_err := os.write_entire_file(
		path,
		out,
		os.Permissions_Read_All + {.Write_User},
		true,
	)
	if write_err != nil {
		fmt.eprintln("Failed to write editor config:", write_err)
		return false
	}
	return true
}

@(private) create_window :: proc(game_name: string, settings: Window_Settings, backend: Ui_Render_Backend) -> bool {
	if !glfw.Init() {
		fmt.eprintln("Failed to initialize GLFW")
		return false
	}

	title, alloc_err := strings.clone_to_cstring(game_name)
	if alloc_err != nil {
		fmt.eprintln("Failed to allocate GLFW window title")
		glfw.Terminate()
		return false
	}
	defer delete(title)

	glfw.DefaultWindowHints()

	switch backend {
	case .Undefined:
		fmt.eprintln("renderer_backend in", active_game_config_path_label(), "is missing or unknown")
		glfw.Terminate()
		return false
	case .SDL3, .Vulkan, .Raylib, .Software:
		fmt.eprintln("Editor window creation is not wired for:", ui_backend(backend))
		glfw.Terminate()
		return false
	case .OpenGL:
		glfw.WindowHint(glfw.CLIENT_API, glfw.OPENGL_API)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 4)
		glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 5)
		glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
		glfw.WindowHint(glfw.DOUBLEBUFFER, glfw.TRUE)
	}

	width := settings.window_width
	height := settings.window_height

	monitor: glfw.MonitorHandle = nil
	if settings.fullscreen {
		monitor = glfw.GetPrimaryMonitor()
		if monitor != nil {
			mode := glfw.GetVideoMode(monitor)
			if mode != nil {
				width = i32(mode.width)
				height = i32(mode.height)
			}
		}
	}

	window = glfw.CreateWindow(width, height, title, monitor, nil)
	if window == nil {
		fmt.eprintln("Failed to create GLFW window")
		glfw.Terminate()
		return false
	}

	switch backend {
	case .Undefined:
		fmt.eprintln("renderer_backend in", active_game_config_path_label(), "is missing or unknown")
		glfw.DestroyWindow(window)
		glfw.Terminate()
		return false
	case .SDL3, .Vulkan, .Raylib, .Software:
		fmt.eprintln("Editor window creation is not wired for:", ui_backend(backend))
		glfw.DestroyWindow(window)
		glfw.Terminate()
		return false
	case .OpenGL:
		glfw.MakeContextCurrent(window)
		glfw.SwapInterval(1)
		gl.load_up_to(4, 5, glfw.gl_set_proc_address)
	}

	if monitor == nil {
		if settings.window_x >= 0 && settings.window_y >= 0 {
			glfw.SetWindowPos(window, settings.window_x, settings.window_y)
		}
	}

	glfw.ShowWindow(window)
	return true
}

@(private) capture_main_window_settings :: proc(dst: ^Window_Settings) {
	if window == nil {
		return
	}

	width, height := glfw.GetWindowSize(window)
	dst.window_width = i32(width)
	dst.window_height = i32(height)
	dst.fullscreen = glfw.GetWindowMonitor(window) != nil

	if !dst.fullscreen {
		x, y := glfw.GetWindowPos(window)
		dst.window_x = i32(x)
		dst.window_y = i32(y)
	}
}

@(private) destroy_window :: proc() {
	if window != nil {
		glfw.DestroyWindow(window)
		window = nil
	}
	glfw.Terminate()
}

@(private) rungame :: proc() {
    working_dir := "."

    if !os.exists("run_from_game_config.ps1") {
        if os.exists("../run_from_game_config.ps1") {
            working_dir = ".."
        } else {
            fmt.eprintln("Could not find run_from_game_config.ps1 from current or parent directory")
            return
        }
    }

	desc := os.Process_Desc{
		working_dir = working_dir,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
		command = {
			"powershell.exe",
			"-NoProfile",
			"-ExecutionPolicy",
			"Bypass",
			"-File",
			"run_from_game_config.ps1",
		},
	}

	process, err := os.process_start(desc)
	if err != nil {
		fmt.eprintln("Failed to start game build/run PowerShell:", err)
		return
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintln("Failed while waiting for game build/run PowerShell:", wait_err)
		return
	}
	if !state.success || state.exit_code != 0 {
		fmt.eprintln("Game build/run script exited with code:", state.exit_code)
	}
}


