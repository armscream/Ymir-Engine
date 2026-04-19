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

Game_Renderer_Config :: struct {
	renderer_backend: string,
}

active_ui_backend := Ui_Render_Backend.Undefined
active_app_config_directory_path: string
imgui_layout_path: string
directory_tree_selected_path: string
directory_tree_selected_is_dir: bool
directory_tree_show_png: bool = true
directory_tree_show_skm: bool = true
directory_tree_show_sm: bool = true
directory_tree_show_mtl: bool = true
directory_tree_hide_non_primary_root_dirs: bool = true
directory_tree_create_folder_parent_path: string
directory_tree_create_folder_error: string
directory_tree_open_create_folder_popup: bool
directory_tree_new_folder_name: [256]u8
force_default_layout_next_frame: bool

@(private) active_game_config_path_label :: proc() -> string {
	if active_app_config_directory_path == "" {
		return "<unknown game config path>"
	}

	if resolved := resolve_game_config_path(active_app_config_directory_path); resolved != "" {
		return resolved
	}

	return active_app_config_directory_path
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
	imgui.style_colors_dark(nil)

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
		gl.ClearColor(0.09, 0.1, 0.12, 1.0)
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
			_ = imgui.checkbox("show .png", &directory_tree_show_png)
			_ = imgui.checkbox("show .skm", &directory_tree_show_skm)
			_ = imgui.checkbox("show .sm", &directory_tree_show_sm)
			_ = imgui.checkbox("show .mtl", &directory_tree_show_mtl)
			imgui.end_combo()
		}

		root_path := resolve_project_root_path()
		if imgui.tree_node("Ymir-Engine") {
			draw_directory_entries(root_path, root_path)

			if imgui.begin_popup_context_item() {
				if imgui.menu_item("Create New Folder") {
					queue_create_folder_popup(root_path)
					imgui.close_current_popup()
				}
				imgui.end_popup()
			}
			if imgui.is_item_clicked(.Right) {
				set_directory_tree_selection(root_path, true)
			}

			imgui.tree_pop()
		}

		imgui.separator()
		imgui.text("Selected:")
		if directory_tree_selected_path != "" {
			imgui.same_line()
			selected_path_c, alloc_err := strings.clone_to_cstring(directory_tree_selected_path)
			if alloc_err == nil {
				imgui.text("%s", selected_path_c)
				delete(selected_path_c)
			}
		}
		draw_create_folder_modal()
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

@(private) draw_directory_entries :: proc(path: string, root_path: string) {
	entries, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		imgui.text("Failed to read directory")
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	sort_directory_entries(entries)

	for entry in entries {
		if entry.type == .Directory {
			if entry.name == ".git" {
				continue
			}
			if directory_tree_hide_non_primary_root_dirs && path == root_path {
				if entry.name != "App" && entry.name != "Editor" {
					continue
				}
			}

			flags: imgui.Tree_Node_Flags = {.Span_Avail_Width}
			if directory_tree_selected_is_dir && directory_tree_selected_path == entry.fullpath {
				flags += {.Selected}
			}

			entry_name_c, name_alloc_err := strings.clone_to_cstring(entry.name)
			if name_alloc_err != nil {
				continue
			}

			if imgui.tree_node_ex(entry_name_c, flags) {
				delete(entry_name_c)
				if imgui.begin_popup_context_item() {
					if imgui.menu_item("Create New Folder") {
						queue_create_folder_popup(entry.fullpath)
						imgui.close_current_popup()
					}
					imgui.end_popup()
				}
				if imgui.is_item_clicked(.Right) {
					set_directory_tree_selection(entry.fullpath, true)
				}
				if imgui.is_item_clicked() {
					set_directory_tree_selection(entry.fullpath, true)
				}
				draw_directory_entries(entry.fullpath, root_path)
				imgui.tree_pop()
			} else {
				delete(entry_name_c)
				if imgui.begin_popup_context_item() {
					if imgui.menu_item("Create New Folder") {
						queue_create_folder_popup(entry.fullpath)
						imgui.close_current_popup()
					}
					imgui.end_popup()
				}
				if imgui.is_item_clicked(.Right) {
					set_directory_tree_selection(entry.fullpath, true)
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
			if !directory_tree_selected_is_dir && directory_tree_selected_path == entry.fullpath {
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

@(private) queue_create_folder_popup :: proc(parent_path: string) {
	clear_create_folder_modal_state()

	cloned_parent, err := strings.clone(parent_path, context.allocator)
	if err != nil {
		return
	}
	directory_tree_create_folder_parent_path = cloned_parent

	for i in 0 ..< len(directory_tree_new_folder_name) {
		directory_tree_new_folder_name[i] = 0
	}
	default_name := "New Folder"
	copy(directory_tree_new_folder_name[:], default_name)

	directory_tree_open_create_folder_popup = true
}

@(private) draw_create_folder_modal :: proc() {
	if directory_tree_open_create_folder_popup {
		imgui.open_popup("Create Folder")
		directory_tree_open_create_folder_popup = false
	}

	if imgui.begin_popup_modal("Create Folder") {
		if imgui.is_window_appearing() {
			imgui.set_keyboard_focus_here()
		}

		imgui.text("Parent:")
		imgui.same_line()
		if directory_tree_create_folder_parent_path != "" {
			parent_c, alloc_err := strings.clone_to_cstring(directory_tree_create_folder_parent_path)
			if alloc_err == nil {
				imgui.text("%s", parent_c)
				delete(parent_c)
			}
		}

		_ = imgui.input_text("Folder Name", cstring(&directory_tree_new_folder_name[0]), uint(len(directory_tree_new_folder_name)))

		if directory_tree_create_folder_error != "" {
			err_c, err_alloc := strings.clone_to_cstring(directory_tree_create_folder_error)
			if err_alloc == nil {
				imgui.text("%s", err_c)
				delete(err_c)
			}
		}

		confirm := imgui.button("OK")
		imgui.same_line()
		cancel := imgui.button("Cancel")

		if confirm {
			folder_name := strings.clone_from_cstring(cstring(&directory_tree_new_folder_name[0]), context.temp_allocator)
			folder_name = strings.trim_space(folder_name)
			if folder_name == "" {
				set_create_folder_error("Folder name cannot be empty")
			} else {
				new_folder_path := strings.concatenate({directory_tree_create_folder_parent_path, "/", folder_name}, context.temp_allocator)
				if err := os.make_directory(new_folder_path); err != nil {
					if err == .Exist {
						set_create_folder_error("Folder already exists")
					} else {
						set_create_folder_error(fmt.tprintf("Failed to create folder: %v", err))
					}
				} else {
					set_directory_tree_selection(new_folder_path, true)
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
	if directory_tree_create_folder_error != "" {
		delete(directory_tree_create_folder_error)
		directory_tree_create_folder_error = ""
	}

	cloned, err := strings.clone(message, context.allocator)
	if err == nil {
		directory_tree_create_folder_error = cloned
	}
}

@(private) clear_create_folder_modal_state :: proc() {
	if directory_tree_create_folder_parent_path != "" {
		delete(directory_tree_create_folder_parent_path)
		directory_tree_create_folder_parent_path = ""
	}
	if directory_tree_create_folder_error != "" {
		delete(directory_tree_create_folder_error)
		directory_tree_create_folder_error = ""
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
		return directory_tree_show_png
	}
	if strings.has_suffix(name_lower, ".skm") {
		return directory_tree_show_skm
	}
	if strings.has_suffix(name_lower, ".sm") {
		return directory_tree_show_sm
	}
	if strings.has_suffix(name_lower, ".mtl") {
		return directory_tree_show_mtl
	}

	return true
}

@(private) set_directory_tree_selection :: proc(path: string, is_dir: bool) {
	if directory_tree_selected_path != "" {
		delete(directory_tree_selected_path)
		directory_tree_selected_path = ""
	}

	cloned, err := strings.clone(path, context.allocator)
	if err != nil {
		directory_tree_selected_is_dir = is_dir
		return
	}

	directory_tree_selected_path = cloned
	directory_tree_selected_is_dir = is_dir
}

@(private) draw_asset_browser :: proc() {
	if imgui.begin("Asset Browser") {
		active_folder := resolve_active_folder_for_asset_browser()

		imgui.separator_text("Assets")
		imgui.text("Folder:")
		imgui.same_line()
		folder_c, folder_alloc_err := strings.clone_to_cstring(active_folder)
		if folder_alloc_err == nil {
			imgui.text("%s", folder_c)
			delete(folder_c)
		}

		entries, read_err := os.read_all_directory_by_path(active_folder, context.allocator)
		if read_err != nil {
			imgui.text("Failed to read active folder")
			imgui.end()
			return
		}
		defer os.file_info_slice_delete(entries, context.allocator)
		sort_directory_entries(entries)

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

			_ = imgui.selectable(entry_name_c)
			delete(entry_name_c)
			asset_count += 1
		}

		if asset_count == 0 {
			imgui.text("No matching files in active folder")
		}
	}
	imgui.end()
}

@(private) resolve_active_folder_for_asset_browser :: proc() -> string {
	if directory_tree_selected_path == "" {
		return resolve_project_root_path()
	}

	if directory_tree_selected_is_dir {
		return directory_tree_selected_path
	}

	dir, _ := os.split_path(directory_tree_selected_path)
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
	if imgui.begin("Top Toolbar", nil, {.No_Collapse, .No_Docking, .No_Move, .No_Resize}) {
		if imgui.button("Reset Layout") {
			reset_editor_layout_to_defaults()
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
	top_toolbar_height: f32 = 44

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
	defer if directory_tree_selected_path != "" {
		delete(directory_tree_selected_path)
		directory_tree_selected_path = ""
	}
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

	active_app_config_directory_path = cfg.app_config_directory_path
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
		editor_name = "Ymir Editor",
		app_config_directory_path = "App/Config",
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

@(private) free_editor_config :: proc(cfg: ^Editor_Config_File) {
	if cfg.editor_name != "" {
		delete(cfg.editor_name)
		cfg.editor_name = ""
	}
	if cfg.app_config_directory_path != "" {
		delete(cfg.app_config_directory_path)
		cfg.app_config_directory_path = ""
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


