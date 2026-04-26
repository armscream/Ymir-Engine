package editor

import ye "../Engine"
import "core:encoding/json"
import "core:math"
import "core:os"
import "core:strings"
import "vendor:sdl3"
import imgui "../vendor/odin-imgui"


Level_Editor_Config_File :: struct {
	cameras: [dynamic]Level_Editor_Config_File,
}

@(private) normalize_level_editor_path :: proc(path: string) -> string {
	lower, _ := strings.to_lower(path, context.temp_allocator)
	normalized, _ := strings.replace_all(lower, "\\", "/", context.temp_allocator)
	for len(normalized) > 0 && normalized[len(normalized)-1] == '/' {
		normalized = normalized[:len(normalized)-1]
	}
	return normalized
}

@(private) resolve_level_editor_config_path :: proc() -> string {
	if os.exists("Editor") {
		return "Editor/level_editor.json"
	}
	return "level_editor.json"
}

@(private) free_level_editor_config :: proc(cfg: ^Level_Editor_Config_File) {
	for i in 0 ..< len(cfg.cameras) {
		if cfg.cameras[i].level_path != "" {
			delete(cfg.cameras[i].level_path)
			cfg.cameras[i].level_path = ""
		}
	}
	delete(cfg.cameras)
	cfg.cameras = nil
}

@(private) load_level_editor_config :: proc(path: string) -> (cfg: Level_Editor_Config_File, ok: bool) {
	if !os.exists(path) {
		return Level_Editor_Config_File{}, true
	}

	raw, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return Level_Editor_Config_File{}, false
	}
	defer delete(raw)

	if unmarshal_err := json.unmarshal(raw, &cfg); unmarshal_err != nil {
		free_level_editor_config(&cfg)
		return Level_Editor_Config_File{}, false
	}

	return cfg, true
}

@(private) save_level_editor_config :: proc(path: string, cfg: Level_Editor_Config_File) -> bool {
	out, err := json.marshal(cfg, allocator = context.temp_allocator)
	if err != nil {
		return false
	}

	write_err := os.write_entire_file(
		path,
		out,
		os.Permissions_Read_All + {.Write_User},
		true,
	)
	return write_err == nil
}

@(private) reset_level_editor_camera_defaults :: proc(state: ^Level_Editor_State) {
	state.camera_position[0] = 0
	state.camera_position[1] = 0
	state.camera_position[2] = 0
	state.camera_rotation.x = 0 //{0, 0, 0, 1} // order for quat is xyzw 
	state.camera_rotation.y = 0
	state.camera_rotation.z = 0
	state.camera_rotation.w = 1

	state.camera_move_speed = 6.0
	state.camera_mouse_sensitivity = 0.0025

	state.move_forward = false
	state.move_backward = false
	state.move_left = false
	state.move_right = false
	state.move_up = false
	state.move_down = false
	state.viewport_input_captured = false
	state.viewport_hovered = false
}

@(private) quat_from_axis_angle :: proc(axis: [3]f32, angle_rad: f32) -> [4]f32 {
	half := angle_rad * 0.5
	s := f32(math.sin(f64(half)))
	c := f32(math.cos(f64(half)))
	return {axis[0] * s, axis[1] * s, axis[2] * s, c}
}

@(private) quat_multiply :: proc(a, b: [4]f32) -> [4]f32 {
	return {
		a[3]*b[0] + a[0]*b[3] + a[1]*b[2] - a[2]*b[1],
		a[3]*b[1] - a[0]*b[2] + a[1]*b[3] + a[2]*b[0],
		a[3]*b[2] + a[0]*b[1] - a[1]*b[0] + a[2]*b[3],
		a[3]*b[3] - a[0]*b[0] - a[1]*b[1] - a[2]*b[2],
	}
}

/*
@(private) rebuild_level_camera_rotation :: proc(state: ^Level_Editor_State) {
	q_yaw := quat_from_axis_angle({0, 0, 1}, state.camera_yaw)
	q_pitch := quat_from_axis_angle({1, 0, 0}, state.camera_pitch)
	state.camera_rotation = ye.quat_normalize(quat_multiply(q_yaw, q_pitch))
}
*/

@(private) load_saved_camera_for_level :: proc(state: ^Level_Editor_State, level_path: string) {
	reset_level_editor_camera_defaults(state)
	if level_path == "" {
		return
	}

	config_path := resolve_level_editor_config_path()
	cfg, ok := load_level_editor_config(config_path)
	if !ok {
		set_level_editor_save_message("Failed to read level editor camera config")
		return
	}
	defer free_level_editor_config(&cfg)

	target := normalize_level_editor_path(level_path)
}	

@(private) save_camera_for_active_level :: proc(state: ^Level_Editor_State) -> bool {
	active_level := state.level_path
	if active_level == "" {
		return false
	}

	config_path := resolve_level_editor_config_path()
	cfg, ok := load_level_editor_config(config_path)
	if !ok {
		set_level_editor_save_message("Failed to load level editor camera config")
		return false
	}
	defer free_level_editor_config(&cfg)

	target := normalize_level_editor_path(active_level)
	updated := false
	for i in 0 ..< len(cfg.cameras) {
		if normalize_level_editor_path(cfg.cameras[i].level_path) == target {
	//		cfg.cameras[i] .camera_position[0] = state.camera_position[0],
	//		cfg.cameras[i] .camera_position[1] = state.camera_position[1],
	//		cfg.cameras[i] .camera_position[2] = state.camera_position[2],
			updated = true
			break
		}
	}

	if !updated {
		cloned_path, clone_err := strings.clone(active_level, context.allocator)
		if clone_err != nil {
			set_level_editor_save_message("Failed to allocate camera config level path")
			return false
		}

		append(&cfg.cameras, Level_Editor_Config_File.cameras{
			level_path = cloned_path,
			camera_x = state.camera_position[0],
			camera_y = state.camera_position[1],
			camera_z = state.camera_position[2],
		})
	}

	if !save_level_editor_config(config_path, cfg) {
		set_level_editor_save_message("Failed to save level editor camera config")
		return false
	}

	return true
}

@(private) set_level_selector_error :: proc(message: string) {
	if state.selector_error != "" {
		delete(state.selector_error)
		state.selector_error = ""
	}

	if message == "" {
		return
	}

	cloned, err := strings.clone(message, context.allocator)
	if err == nil {
		state.selector_error = cloned
	}
}

@(private) set_level_editor_save_message :: proc(message: string) {
	if state.save_message != "" {
		delete(state.save_message)
		state.save_message = ""
	}

	if message == "" {
		return
	}

	cloned, err := strings.clone(message, context.allocator)
	if err == nil {
		state.save_message = cloned
	}
}

@(private) clear_level_selector_paths :: proc() {
	for path in state.selector_paths {
		if path != "" {
			delete(path)
		}
	}
	delete(state.selector_paths)
	state.selector_paths = nil
	state.selector_selected_index = -1
}

clear_level_editor_state :: proc() {
	clear_level_selector_paths()
	set_level_selector_error("")
	set_level_editor_save_message("")

	if state.level_path != "" {
		delete(state.level_path)
		state.level_path = ""
	}

	if state.window_title != "" {
		delete(state.window_title)
		state.window_title = ""
	}

	for i in 0 ..< len(state.text_buffer) {
		state.text_buffer[i] = 0
	}
	state.text_dirty = false
	reset_level_editor_camera_defaults(&state.level_editor)
	state.close_confirm_open_modal = false
}

@(private) resolve_levels_folder_path :: proc() -> string {
	candidates := [4]string{
		strings.concatenate({editor_runtime.directory_browser.root_path, "/App/Levels"}, context.temp_allocator),
		strings.concatenate({editor_runtime.directory_browser.root_path, "/app/levels"}, context.temp_allocator),
		"App/Levels",
		"../App/Levels",
	}

	for candidate in candidates {
		if os.exists(candidate) {
			return candidate
		}
	}

	return ""
}

@(private) level_name_from_path :: proc(path: string) -> string {
	_, file_name := os.split_path(path)
	if file_name == "" {
		return "level"
	}

	for i := len(file_name) - 1; i >= 0; i -= 1 {
		if file_name[i] == '.' {
			if i == 0 {
				break
			}
			return file_name[:i]
		}
	}

	return file_name
}

@(private) load_level_editor_text_from_file :: proc(path: string) -> bool {
	raw, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		set_level_editor_save_message("Failed to read selected level file")
		return false
	}
	defer delete(raw)

	buffer_cap := len(state.text_buffer)
	if buffer_cap <= 1 {
		set_level_editor_save_message("Level editor buffer unavailable")
		return false
	}

	max_copy := buffer_cap - 1
	copy_count := len(raw)
	if copy_count > max_copy {
		copy_count = max_copy
		set_level_editor_save_message("Level file is too large, loaded partially")
	} else {
		set_level_editor_save_message("")
	}

	for i in 0 ..< copy_count {
		state.text_buffer[i] = raw[i]
	}
	for i in copy_count ..< buffer_cap {
		state.text_buffer[i] = 0
	}

	state.text_dirty = false
	return true
}

@(private) save_level_editor_changes :: proc(state: ^Level_Editor_State) -> bool {
	if state.level_path == "" {
		set_level_editor_save_message("No level selected")
		return false
	}

	text := strings.clone_from_cstring(cstring(&state.text_buffer[0]), context.temp_allocator)
	write_err := os.write_entire_file(
		state.level_path,
		text,
		os.Permissions_Read_All + {.Write_User},
		true,
	)
	if write_err != nil {
		set_level_editor_save_message("Failed to save level changes")
		return false
	}
	if !save_camera_for_active_level(state) {
		return false
	}

	state.text_dirty = false
	set_level_editor_save_message("Level saved")
	clear_directory_cache()
	return true
}

@(private) choose_level_for_editor :: proc(path: string) -> bool {
	if path == "" {
		return false
	}

	if state.level_path != "" {
		delete(state.level_path)
		state.level_path = ""
	}

	cloned_path, path_err := strings.clone(path, context.allocator)
	if path_err != nil {
		set_level_selector_error("Failed to store selected level path")
		return false
	}

	if state.window_title != "" {
		delete(state.window_title)
		state.window_title = ""
	}

	level_name := level_name_from_path(path)
	title := strings.concatenate({level_name, " editor"}, context.temp_allocator)
	cloned_title, title_err := strings.clone(title, context.allocator)
	if title_err != nil {
		delete(cloned_path)
		set_level_selector_error("Failed to allocate level editor title")
		return false
	}

	state.level_path = cloned_path
	state.window_title = cloned_title
	if !load_level_editor_text_from_file(path) {
		delete(state.level_path)
		state.level_path = ""
		delete(state.window_title)
		state.window_title = ""
		return false
	}
	load_saved_camera_for_level(path)
	set_level_selector_error("")
	return true
}

consume_level_editor_input_event :: proc(event: ^sdl3.Event) -> bool {
	if !RUNLEVELEDITOR || !state.viewport_input_captured {
		return false
	}

	#partial switch event.type {
	case .KEY_DOWN:
		handled := false
		switch event.key.key {
		case sdl3.K_W:
			state.move_forward = true
			handled = true
		case sdl3.K_S:
			state.move_backward = true
			handled = true
		case sdl3.K_A:
			state.move_left = true
			handled = true
		case sdl3.K_D:
			state.move_right = true
			handled = true
		case sdl3.K_SPACE:
			state.move_up = true
			handled = true
		case sdl3.K_LCTRL:
			state.move_down = true
			handled = true
		case sdl3.K_RCTRL:
			state.move_down = true
			handled = true
		}
		return handled

	case .KEY_UP:
		handled := false
		switch event.key.key {
		case sdl3.K_W:
			state.move_forward = false
			handled = true
		case sdl3.K_S:
			state.move_backward = false
			handled = true
		case sdl3.K_A:
			state.move_left = false
			handled = true
		case sdl3.K_D:
			state.move_right = false
			handled = true
		case sdl3.K_SPACE:
			state.move_up = false
			handled = true
		case sdl3.K_LCTRL:
			state.move_down = false
			handled = true
		case sdl3.K_RCTRL:
			state.move_down = false
			handled = true
		}
		return handled

	case .TEXT_INPUT, .TEXT_EDITING:
		return true
	}

	return false
}

refresh_level_selector_paths :: proc() -> bool {
	clear_level_selector_paths()

	levels_folder := resolve_levels_folder_path()
	if levels_folder == "" {
		set_level_selector_error("Levels folder not found")
		return false
	}

	entries, err := os.read_all_directory_by_path(levels_folder, context.allocator)
	if err != nil {
		set_level_selector_error("Failed to read Levels folder")
		return false
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	sort_directory_entries(entries)
	for entry in entries {
		if entry.type == .Directory {
			continue
		}

		name_lower, _ := strings.to_lower(entry.name, context.temp_allocator)
		if !strings.has_suffix(name_lower, ".json") {
			continue
		}

		cloned, clone_err := strings.clone(entry.fullpath, context.allocator)
		if clone_err != nil {
			continue
		}

		append(&state.selector_paths, cloned)
	}

	if len(state.selector_paths) == 0 {
		set_level_selector_error("No level files found in Levels folder")
		return false
	}

	state.selector_selected_index = 0
	set_level_selector_error("")
	return true
}

@(private) draw_scene_hierarchy_content :: proc() {
	imgui.text("Scene Hierarchy")
	imgui.separator()
	imgui.text("Coordinate System: Right-handed (X right, Y forward, Z up)")
	imgui.text("Positive rotation: Counter-Clockwise")
	imgui.separator()
	if state.level_path != "" {
		imgui.text("Selected level:")
		path_c, path_err := strings.clone_to_cstring(state.level_path)
		if path_err == nil {
			imgui.text_wrapped("%s", path_c)
			delete(path_c)
		}
	}

	imgui.separator()
	imgui.text("Camera position")
	imgui.text("x: %.3f", state.camera_position[0])
	imgui.text("y: %.3f", state.camera_position[1])
	imgui.text("z: %.3f", state.camera_position[2])
	imgui.text("Camera rotation quaternion")
	imgui.text("x: %.4f", state.camera_rotation[0])
	imgui.text("y: %.4f", state.camera_rotation[1])
	imgui.text("z: %.4f", state.camera_rotation[2])
	imgui.text("w: %.4f", state.camera_rotation[3])
	imgui.separator()

	if state.text_dirty {
		imgui.text_colored({1.0, 0.75, 0.2, 1.0}, "Unsaved changes")
	} else {
		imgui.text("No pending changes")
	}

	if state.save_message != "" {
		msg_c, msg_err := strings.clone_to_cstring(state.save_message)
		if msg_err == nil {
			imgui.text_wrapped("%s", msg_c)
			delete(msg_c)
		}
	}

	imgui.spacing()
	avail := imgui.get_content_region_avail()
	if avail.y > 40 {
		imgui.set_cursor_pos_y(imgui.get_cursor_pos_y() + (avail.y - 34))
	}

	imgui.begin_disabled(!state.RUNLEVELEDITOR)
	if imgui.button("Stop Level Editor") && state.RUNLEVELEDITOR {
		request_close_level_editor(state, run_flag, force_default_layout_next_frame)
	}
	imgui.end_disabled()
}

@(private) draw_level_json_editor_content :: proc() {
	imgui.text("Level JSON")
	imgui.separator()
	editor_area := imgui.get_content_region_avail()
	if editor_area.y < 160 {
		editor_area.y = 160
	}
	editor_area.y -= 44
	if editor_area.y < 120 {
		editor_area.y = 120
	}

	if imgui.input_text_multiline(
		"##level_json_editor",
		cstring(&state.text_buffer[0]),
		uint(len(state.text_buffer)),
		editor_area,
	) {
		state.text_dirty = true
	}

	save_enabled := state.level_path != ""
	imgui.begin_disabled(!save_enabled)
	if imgui.button("Save Changes") && save_enabled {
		_ = save_level_editor_changes(state)
	}
	imgui.end_disabled()
}

draw_level_selector_modal :: proc() {
	if state.selector_open_modal {
		imgui.open_popup("Select Level")
		state.selector_open_modal = false
	}

	if !imgui.begin_popup_modal("Select Level") {
		return
	}

	imgui.text("Choose a level from the Levels folder")
	imgui.separator()

	if len(state.selector_paths) > 0 {
		selected_index := state.selector_selected_index
		if selected_index < 0 || selected_index >= i32(len(state.selector_paths)) {
			selected_index = 0
			state.selector_selected_index = 0
		}

		preview := level_name_from_path(state.selector_paths[int(selected_index)])
		preview_c, preview_err := strings.clone_to_cstring(preview)
		if preview_err == nil {
			if imgui.begin_combo("Level", preview_c) {
				for i in 0 ..< len(state.selector_paths) {
					level_label := level_name_from_path(state.selector_paths[i])
					level_label_c, label_err := strings.clone_to_cstring(level_label)
					if label_err != nil {
						continue
					}
					is_selected := state.selector_selected_index == i32(i)
					if imgui.selectable(level_label_c, is_selected) {
						state.selector_selected_index = i32(i)
					}
					delete(level_label_c)
				}
				imgui.end_combo()
			}
			delete(preview_c)
		}
	} else {
		imgui.text("No levels available")
	}

	if state.selector_error != "" {
		err_c, err_alloc := strings.clone_to_cstring(state.selector_error)
		if err_alloc == nil {
			imgui.text_colored({1.0, 0.5, 0.5, 1.0}, "%s", err_c)
			delete(err_c)
		}
	}

	ok_enabled := len(state.selector_paths) > 0 &&
		state.selector_selected_index >= 0 &&
		state.selector_selected_index < i32(len(state.selector_paths))

	imgui.begin_disabled(!ok_enabled)
	ok_clicked := imgui.button("Run Level Editor")
	imgui.end_disabled()
	imgui.same_line()
	cancel_clicked := imgui.button("Cancel")

	if ok_clicked && ok_enabled {
		selected_path := state.selector_paths[int(state.selector_selected_index)]
		if choose_level_for_editor(selected_path) {
			state.RUNLEVELEDITOR = true
			force_default_layout_next_frame = true
			imgui.close_current_popup()
		}
	}

	if cancel_clicked {
		imgui.close_current_popup()
	}

	imgui.end_popup()
}

draw_level_editor_panel :: proc() {
	if workspace_dock_id != 0 {
		imgui.set_next_window_dock_id(workspace_dock_id, .Always)
	}

	window_title := "Level Editor"
	if state.window_title != "" {
		window_title = state.window_title
	}

	window_title_c, title_err := strings.clone_to_cstring(window_title)
	window_open := false
	level_editor_window_open := true
	if title_err == nil {
		window_open = imgui.begin(window_title_c, &level_editor_window_open)
		delete(window_title_c)
	} else {
		window_open = imgui.begin("Level Editor", &level_editor_window_open)
	}

	if !level_editor_window_open {
		request_close_level_editor(state, run_flag, force_default_layout_next_frame)
	}

	if window_open {
		avail := imgui.get_content_region_avail()
		right_width: f32 = 320
		if right_width > avail.x*0.6 {
			right_width = avail.x * 0.6
		}
		if right_width < 220 {
			right_width = 220
		}

		left_width := avail.x - right_width - 8
		if left_width < 200 {
			left_width = 200
		}

		if imgui.begin_child("level_editor_main", imgui.Vec2{left_width, 0}, {.Borders}) {
			imgui.text("Level Editor View")
			imgui.separator()

			view_height := imgui.get_content_region_avail().y
			if view_height < 120 {
				view_height = 120
			}

			if imgui.begin_child("level_editor_viewport", imgui.Vec2{0, view_height}, {.Borders}) {
				viewport_avail := imgui.get_content_region_avail()
				if viewport_avail.x > 0 && viewport_avail.y > 0 {
					_ = imgui.invisible_button("level_editor_viewport_surface", viewport_avail)
					state.viewport_hovered = imgui.is_item_hovered()
					if imgui.is_item_clicked(.Left) {
						state.viewport_input_captured = true
					} else if imgui.is_mouse_clicked(.Left) && !state.viewport_hovered && !imgui.is_window_hovered() {
						state.viewport_input_captured = false
					}

					draw_pos := imgui.get_item_rect_min()
					draw_max := imgui.get_item_rect_max()
					draw_list := imgui.get_window_draw_list()
					bg_col := imgui.get_color_u32vec4(imgui.Vec4{0.09, 0.11, 0.12, 1.0})
					imgui.draw_list_add_rect_filled(draw_list, draw_pos, draw_max, bg_col)
				}

				if state.viewport_input_captured {
					imgui.text("Input captured (WASD, Space, L-Ctrl move, mouse rotates)")
				} else {
					imgui.text("Click in this view to capture input")
				}
			}
			imgui.end_child()
		}
		imgui.end_child()

		imgui.same_line()
		if imgui.begin_child("level_editor_scene_hierarchy", imgui.Vec2{0, 0}, {.Borders}) {
			if imgui.begin_tab_bar("level_editor_side_tabs") {
				if imgui.begin_tab_item("Scene Hierarchy") {
					draw_scene_hierarchy_content()
					imgui.end_tab_item()
				}
				if imgui.begin_tab_item("JSON Editor") {
					draw_level_json_editor_content()
					imgui.end_tab_item()
				}
				imgui.end_tab_bar()
			} else {
				draw_scene_hierarchy_content()
			}
		}
		imgui.end_child()
	}
	imgui.end()
}

init_level_editor :: proc() {
	reset_level_editor_camera_defaults()
}

run_level_editor :: proc() {
	if !state.RUNLEVELEDITOR || !state.viewport_input_captured {
		return
	}

	io := imgui.get_io()
	dt := io.delta_time
	if dt <= 0 {
		dt = 1.0 / 60.0
	}

	speed := state.camera_move_speed
	if speed <= 0 {
		speed = 6.0
	}
	step := speed * dt

	mouse_delta := io.mouse_delta
	sensitivity := state.camera_mouse_sensitivity
	state.camera_yaw -= mouse_delta.x * sensitivity
	state.camera_pitch -= mouse_delta.y * sensitivity

	pitch_limit := f32(89.0 * math.PI / 180.0)
	if state.camera_pitch > pitch_limit {
		state.camera_pitch = pitch_limit
	}
	if state.camera_pitch < -pitch_limit {
		state.camera_pitch = -pitch_limit
	}

	rebuild_level_camera_rotation(state.Level_Editor_State)

	forward := ye.RotateVector(state.camera_rotation, {0, 1, 0})
	right := ye.RotateVector(state.camera_rotation, {1, 0, 0})
	world_up := [3]f32{0, 0, 1}

	if state.move_forward {
		state.camera_position[0] += forward[0] * step
		state.camera_position[1] += forward[1] * step
		state.camera_position[2] += forward[2] * step
	}
	if state.move_backward {
		state.camera_position[0] -= forward[0] * step
		state.camera_position[1] -= forward[1] * step
		state.camera_position[2] -= forward[2] * step
	}
	if state.move_left {
		state.camera_position[0] -= right[0] * step
		state.camera_position[1] -= right[1] * step
		state.camera_position[2] -= right[2] * step
	}
	if state.move_right {
		state.camera_position[0] += right[0] * step
		state.camera_position[1] += right[1] * step
		state.camera_position[2] += right[2] * step
	}
	if state.move_up {
		state.camera_position[0] += world_up[0] * step
		state.camera_position[1] += world_up[1] * step
		state.camera_position[2] += world_up[2] * step
	}
	if state.move_down {
		state.camera_position[0] -= world_up[0] * step
		state.camera_position[1] -= world_up[1] * step
		state.camera_position[2] -= world_up[2] * step
	}
}

unload_level_editor :: proc() {
	state.viewport_input_captured = false
	state.viewport_hovered = false
}