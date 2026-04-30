package editor

import ye "../Engine"
import imgui "../vendor/odin-imgui"
import imgui_sdl3 "../vendor/odin-imgui/imgui_impl_sdl3"
import imgui_sdlrenderer3 "../vendor/odin-imgui/imgui_impl_sdlrenderer3"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:sdl3"
import sdl_image "vendor:sdl3/image"


// Asset browser state
asset_browser_state := Asset_Browser_State {
	directory_tree   = {},
	selected_indices = {},
	active_tab       = 0,
	terminal_log     = "",
}

// Directory browser state
directory_browser_state := Directory_Browser_State {
	root_path        = "App/Assets",
	current_path     = "App/Assets",
	entries          = {},
	selected_index   = -1,
	filter_text      = {},
	show_hidden      = false,
	new_file_name    = {},
	rename_file_name = {},
	error_message    = {},
}

state := Editor_State {
    running      = true,
    level_editor = Level_Editor_State{},
}

// Load config from file
load_editor_config :: proc(path: string) -> Editor_Config {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || data == nil {
		return Editor_Config{backend = "SDLRenderer3", theme = "Dark", layout = "default"}
	}
	config := Editor_Config{}
	json.unmarshal(data, &config)
	return config
}

// Initialize ImGui and backend
init_imgui :: proc(state: ^Editor_State) -> bool {
	state.imgui_ctx = imgui.create_context()
	imgui.set_current_context(state.imgui_ctx)
	if state.config.backend == "SDLRenderer3" {
		if !imgui_sdlrenderer3.init(state.renderer) {
			fmt.eprintln("Failed to init ImGui SDLRenderer3 backend")
			return false
		}
	} else {
		fmt.eprintln("Unknown backend: ", state.config.backend)
		return false
	}
	return true
}

// Helper procs for cstring conversion and length

cstring_to_string :: proc(buf: ^[256]u8) -> string {
	n := 0
	for buf^[n] != 0 && n < 256 {
		n += 1
	}
	return string(buf^[0:n])
}


cstring_len :: proc(buf: ^[256]u8) -> int {
	n := 0
	for buf^[n] != 0 && n < 256 {
		n += 1
	}
	return n
}


string_to_cstring :: proc(src: string, dst: ^[256]u8, max: int) {
	n := min(len(src), max - 1)
	for i in 0 ..< n {
		dst^[i] = src[i]
	}
	dst^[n] = 0
}

// Panel stubs
show_asset_browser_panel :: proc(state: ^Asset_Browser_State, dir_state: ^Directory_Browser_State) {
	imgui.begin("Asset Browser")
	// Tabs: Assets | Terminal
	if imgui.begin_tab_bar("asset_browser_tabs") {
		if imgui.begin_tab_item("Assets") {
			// Filter/search bar
			imgui.input_text("Filter", (cast(cstring)&dir_state.filter_text[0]), 256)
			imgui.same_line()
			if imgui.button("Clear") {
				state.filter_text = {}
			}
			imgui.separator()
			// Directory tree
			filter := cstring_to_string(&state.filter_text)
			for i in 0 ..< len(state.directory_tree) {
				entry := state.directory_tree[i]
				show := filter == "" || strings.contains(entry.path, filter)
				if !show {continue}
				icon := entry.icon
				if icon == "" {
					icon = entry.is_directory ? "[DIR]" : "[FILE]"
				}
				imgui.text("%s %s", icon, entry.path)
				if imgui.is_item_clicked() {
					state.selected_indices = {}
					append(&state.selected_indices, i)
				}
			}
			imgui.end_tab_item()
		}
		if imgui.begin_tab_item("Terminal") {
			terminal_log_buf: [256]u8
			string_to_cstring(state.terminal_log, &terminal_log_buf, 256)
			imgui.text_wrapped(cast(cstring)&terminal_log_buf[0]);  
			imgui.end_tab_item()
		}
		imgui.end_tab_bar()
	}
	imgui.end()
}

show_directory_browser_panel :: proc(state: ^Directory_Browser_State) {
	imgui.begin("Directory Browser")
	// Filter/search bar
	imgui.input_text("Filter", (cast(cstring)&state.filter_text[0]), 256)
	imgui.same_line()
	if imgui.button("Clear") {
		state.filter_text = {}
	}
	imgui.same_line()
	if imgui.button("Refresh") {
		refresh_directory_entries(state)
	}
	imgui.separator()
	// Directory entries
	filter := cstring_to_string(&state.filter_text)
	for i in 0 ..< len(state.entries) {
		entry := state.entries[i]
		show := filter == "" || strings.contains(entry.path, filter)
		if !show {continue}
		icon := entry.icon
		if icon == "" {
			icon = entry.is_directory ? "[DIR]" : "[FILE]"
		}
		imgui.text("%s %s", icon, entry.path)
		if imgui.is_item_clicked() {
			state.selected_index = i
		}
	}
	// File operations (create, rename, delete)
	if imgui.button("New File") {
		imgui.open_popup("Create File")
	}
	if imgui.begin_popup_modal("Create File") {
		imgui.input_text("File Name", (cast(cstring)&state.new_file_name[0]), 256)
		if imgui.button("Create") && cstring_len(&state.new_file_name) > 0 {
			name := cstring_to_string(&state.new_file_name)
			path := os.join_path({state.current_path, name}, context.temp_allocator)
			file, err := os.create(path)
			if err == nil {
				refresh_directory_entries(state)
				state.new_file_name = {}
				imgui.close_current_popup()
			} else {
				string_to_cstring("Failed to create file", &state.error_message, 256)
			}
		}
		imgui.same_line()
		if imgui.button("Cancel") {
			state.new_file_name = {}
			imgui.close_current_popup()
		}
		if cstring_len(&state.error_message) > 0 {
			imgui.text_colored({1, 0, 0, 1}, (cast(cstring)&state.error_message[0]))
		}
		imgui.end_popup()
	}
	if imgui.button("Rename") && state.selected_index >= 0 {
		entry := state.entries[state.selected_index]
		entry_name := entry.path
		string_to_cstring(entry_name, &state.rename_file_name, 256)
		imgui.open_popup("Rename File")
	}
	if imgui.begin_popup_modal("Rename File") {
		imgui.input_text("New Name", (cast(cstring)&state.rename_file_name[0]), 256)
		if imgui.button("Rename") && cstring_len(&state.rename_file_name) > 0 {
			old_path := state.entries[state.selected_index].path
			new_name := cstring_to_string(&state.rename_file_name)
			path := os.join_path({state.current_path, new_name}, context.temp_allocator)
			err := os.rename(old_path, path)
			if err == nil {
				refresh_directory_entries(state)
				state.rename_file_name = {}
				imgui.close_current_popup()
			} else {
				string_to_cstring("Failed to rename file", &state.error_message, 256)
			}
		}
		imgui.same_line()
		if imgui.button("Cancel") {
			state.rename_file_name = {}
			imgui.close_current_popup()
		}
		if cstring_len(&state.error_message) > 0 {
			imgui.text_colored({1, 0, 0, 1}, (cast(cstring)&state.error_message[0]))
		}
		imgui.end_popup()
	}
	if imgui.button("Delete") && state.selected_index >= 0 {
		imgui.open_popup("Delete File")
	}
	if imgui.begin_popup_modal("Delete File") {
		if imgui.button("Confirm Delete") {
			path := state.entries[state.selected_index].path
			err := os.remove(path)
			if err == nil {
				refresh_directory_entries(state)
				imgui.close_current_popup()
			} else {
				string_to_cstring("Failed to delete file", &state.error_message, 256)
			}
		}
		imgui.same_line()
		if imgui.button("Cancel") {
			imgui.close_current_popup()
		}
		if cstring_len(&state.error_message) > 0 {
			imgui.text_colored({1, 0, 0, 1}, (cast(cstring)&state.error_message[0]))
		}
		imgui.end_popup()
	}
	imgui.end()
}

refresh_directory_entries :: proc(state: ^Directory_Browser_State) {
	entries, err := os.read_all_directory_by_path(state.current_path, context.allocator)
	if err != nil {
		state.entries = nil
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	new_entries := make([dynamic]Directory_Browser_Entry, 0)
	for entry in entries {
		is_dir := entry.type == .Directory
		icon := is_dir ? "[DIR]" : "[FILE]"
		// Optionally, assign icons based on file extension
		if !is_dir {
			lower, _ := strings.to_lower(entry.name, context.temp_allocator)
			if strings.has_suffix(
				lower,
				".png",
			) {icon = "[PNG]"} else if strings.has_suffix(lower, ".jpg") {icon = "[JPG]"} else if strings.has_suffix(lower, ".gltf") {icon = "[GLTF]"} else if strings.has_suffix(lower, ".csv") {icon = "[CSV]"}
			// Add more as needed
		}
		append(
			&new_entries,
			Directory_Browser_Entry{path = entry.fullpath, is_directory = is_dir, icon = icon},
		)
	}
	state.entries = new_entries
}

// Main entry
main :: proc() {
	config := load_editor_config("editor.json")
	window := sdl3.CreateWindow("Ymir Editor", 1280, 720, sdl3.WINDOW_RESIZABLE)
	renderer := sdl3.CreateRenderer(window, nil)
	run_level_editor := true
	force_default_layout_next_frame := false
	if !init_imgui(&state) {
		fmt.eprintln("ImGui initialization failed")
		return
	}
	defer {
		imgui.destroy_context(state.imgui_ctx)
		sdl3.DestroyRenderer(state.renderer)
		sdl3.DestroyWindow(state.window)
	}
        for event: sdl3.Event; sdl3.PollEvent(&event); {
            if event.type == sdl3.EventType.QUIT {
                state.running = false
            }
            // Handle other events
        }
		imgui.new_frame()
		// Modular panel rendering
		show_asset_browser_panel(&asset_browser_state)
		show_directory_browser_panel(&directory_browser_state)
		// ...other panels...
		imgui.render()

		// SDL3 GPU backend frame logic
		if state.config.backend == "SDL3" {
			// TODO: Initialize and manage these objects at startup and per-frame:
			//   gpu_device: ^sdl3.GPUDevice
			//   command_buffer: ^sdl3.GPUCommandBuffer
			//   render_pass: ^sdl3.GPURenderPass
			//   pipeline: ^sdl3.GPUGraphicsPipeline (optional)
			// Begin GPU frame (pseudo-code, replace with actual API calls):
			// sdl3.BeginGPUFrame(gpu_device)
			// sdl3.BeginRenderPass(command_buffer, render_pass)
			// imgui_sdlrenderer3.render_draw_data(imgui.get_draw_data(), command_buffer, render_pass)
			// sdl3.EndRenderPass(command_buffer, render_pass)
			// sdl3.Present(gpu_device)
		}
		sdl3.Delay(16) // ~60 FPS
	}
