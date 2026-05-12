package editor

import im "../Libs/imgui"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import vk "../Backend/Vulkan"

BROWSER_PANEL_DEFAULT_HEIGHT :: f32(220)

Level_UI_Action :: enum {
	None,
	Load_Ok,
	Load_Failed,
	Save_Ok,
	Save_Failed,
}

Runtime_Game_Config_View :: struct {
	renderer_backend: string,
	editor_backend:   string,
	game_name:        string,
	window_x:         i32,
	window_y:         i32,
	window_width:     i32,
	window_height:    i32,
	fullscreen:       bool,
	keybinds_path:    string,
	current_level:    string,
	levels:           []string,
}

Level_Load_Proc :: #type proc(file_path: string) -> bool
Level_Save_Proc :: #type proc(file_path: string) -> bool

Editor_UI_Params :: struct {
	display_size:   im.Vec2,
	runtime_config: ^Runtime_Game_Config_View,
	scene:          ^vk.Scene,
	load_level:     Level_Load_Proc,
	save_level:     Level_Save_Proc,
}

@(private = "file")
Browser_State :: struct {
	initialized:      bool,
	// Directory panel
	dir_root:         string, // owned
	dir_current:      string, // owned
	// Asset browser
	file_entries:     []os.File_Info,
	file_entries_dir: string, // owned — tracks which dir was last loaded
	asset_selected:   string, // owned
	search_buf:       [256]byte,
}

@(private = "file")
g: Browser_State

// editor_browser_init sets the root path for the directory panel.
// Safe to call every frame — only initialises once.
editor_browser_init :: proc(root_path: string = ".") {
	if g.initialized do return
	g.dir_root = strings.clone(root_path)
	g.dir_current = strings.clone(root_path)
	g.initialized = true
}

// editor_browser_shutdown releases all owned memory.  Call on editor exit.
editor_browser_shutdown :: proc() {
	delete(g.dir_root)
	delete(g.dir_current)
	delete(g.asset_selected)
	delete(g.file_entries_dir)
	if g.file_entries != nil {
		os.file_info_slice_delete(g.file_entries, context.allocator)
	}
	g = {}
}

@(private = "file")
navigate_to :: proc(path: string) {
	if g.dir_current == path do return
	delete(g.dir_current)
	g.dir_current = strings.clone(path)
	reload_file_entries()
}

@(private = "file")
reload_file_entries :: proc() {
	if g.file_entries != nil {
		os.file_info_slice_delete(g.file_entries, context.allocator)
		g.file_entries = nil
	}
	delete(g.file_entries_dir)
	entries, err := os.read_all_directory_by_path(g.dir_current, context.allocator)
	if err == nil {
		g.file_entries = entries
	}
	g.file_entries_dir = strings.clone(g.dir_current)
}

// draw_dir_node renders one directory entry as a collapsible tree node.
// Children (sub-directories) are read from disk only when the node is open.
@(private = "file")
draw_dir_node :: proc(path: string, name: string) {
	entries, err := os.read_all_directory_by_path(path, context.allocator)
	has_subdirs := false
	if err == nil {
		for e in entries {
			if e.type == .Directory {
				has_subdirs = true
				break
			}
		}
	}
	defer if err == nil {
		os.file_info_slice_delete(entries, context.allocator)
	}

	flags: im.Tree_Node_Flags = {.Open_On_Arrow, .Span_Avail_Width}
	if !has_subdirs {flags += {.Leaf}}
	if path == g.dir_current {flags += {.Selected}}

	opened := im.tree_node_ex(fmt.ctprintf("%s", name), flags)

	if im.is_item_clicked() && !im.is_item_toggled_open() {
		navigate_to(path)
	}

	if opened {
		if err == nil {
			for e in entries {
				if e.type == .Directory {
					draw_dir_node(e.fullpath, e.name)
				}
			}
		}
		im.tree_pop()
	}
}

@(private = "file")
render_scene_tree_ui :: proc(scene: ^vk.Scene, #any_int node: i32, selected_node: ^i32) -> i32 {
	name := vk.scene_get_node_name(scene, node)
	label := len(name) == 0 ? "NO NODE" : name
	is_leaf := scene.hierarchy[node].first_child < 0
	flags: im.Tree_Node_Flags = is_leaf ? {.Leaf, .Bullet} : {}

	if node == selected_node^ {
		flags += {.Selected}
	}

	// Make the node span the entire width
	flags += {.Span_Full_Width, .Frame_Padding}

	is_opened := im.tree_node_ex_ptr(&scene.hierarchy[node], flags, "%s", cstring(raw_data(label)))

	// Check for clicks in the entire row area
	was_clicked := im.is_item_clicked()

	im.push_id_int(node)
	{
		if was_clicked {
			log.debugf("Selected node: %d (%s)", node, label)
			selected_node^ = node
		}

		if is_opened {
			for ch := scene.hierarchy[node].first_child;
			    ch != -1;
			    ch = scene.hierarchy[ch].next_sibling {
				if sub_node := render_scene_tree_ui(scene, ch, selected_node); sub_node > -1 {
					selected_node^ = sub_node
				}
			}
			im.tree_pop()
		}
	}
	im.pop_id()

	return selected_node^
}

@(private = "file")
draw_hierarchy_content_ui :: proc(scene: ^vk.Scene) {
	if scene == nil {
		return
	}
	@(static) selected_node: i32 = -1
	for &hierarchy, i in scene.hierarchy {
		if hierarchy.parent == -1 {
			render_scene_tree_ui(scene, i, &selected_node)
		}
	}
}

runtime_find_current_level_index :: proc(cfg: ^Runtime_Game_Config_View) -> i32 {
	if cfg == nil {
		return -1
	}
	for lvl, i in cfg.levels {
		if lvl == cfg.current_level {
			return i32(i)
		}
	}
	return -1
}

editor_draw_ui :: proc(params: Editor_UI_Params) {
	editor_browser_init()

	hierarchy_h := params.display_size.y - BROWSER_PANEL_DEFAULT_HEIGHT - 20
	if hierarchy_h < 120 {
		hierarchy_h = 120
	}

	im.set_next_window_pos({10, 10})
	im.set_next_window_size({300, hierarchy_h})
	hierarchy_open := im.begin("Hierarchy", nil, {.No_Focus_On_Appearing, .No_Resize})
	if hierarchy_open {
		if params.scene != nil {
			draw_hierarchy_content_ui(params.scene)

			im.separator()
			if params.scene.atlas_manifest.enabled {
				im.text("Atlas: enabled")
			} else {
				im.text("Atlas: disabled")
			}
			im.text("Atlas pages: %d", len(params.scene.atlas_manifest.pages))
			im.text("Atlas mappings: %d", len(params.scene.atlas_manifest.mappings))
			im.text("Atlas max size: %d", params.scene.atlas_manifest.settings.max_page_size)
			im.text("Atlas max pages: %d", params.scene.atlas_manifest.settings.max_pages)
		}

		im.separator()
		im.text("Level")

		cfg := params.runtime_config
		if cfg != nil {
			@(static) selected_level_idx: i32 = -1
			@(static) last_level_action: Level_UI_Action = .None

			if selected_level_idx < 0 || selected_level_idx >= i32(len(cfg.levels)) {
				selected_level_idx = runtime_find_current_level_index(cfg)
			}
			if selected_level_idx < 0 && len(cfg.levels) > 0 {
				selected_level_idx = 0
			}

			preview_level := cfg.current_level
			if selected_level_idx >= 0 && selected_level_idx < i32(len(cfg.levels)) {
				preview_level = cfg.levels[selected_level_idx]
			}

			if im.begin_combo("Level File", cstring(raw_data(preview_level))) {
				for lvl, i in cfg.levels {
					is_selected := i32(i) == selected_level_idx
					if im.selectable(cstring(raw_data(lvl)), is_selected) {
						selected_level_idx = i32(i)
					}
					if is_selected {
						im.set_item_default_focus()
					}
				}
				im.end_combo()
			}

			if im.button("Load Level") {
				if params.load_level != nil &&
				   selected_level_idx >= 0 &&
				   selected_level_idx < i32(len(cfg.levels)) {
					selected_path := cfg.levels[selected_level_idx]
					if params.load_level(selected_path) {
						last_level_action = .Load_Ok
						if cfg.current_level != selected_path {
							delete(cfg.current_level)
							cfg.current_level = strings.clone(selected_path)
						}
					} else {
						last_level_action = .Load_Failed
					}
				} else {
					last_level_action = .Load_Failed
				}
			}

			if im.button("Save Level") {
				if params.save_level != nil && params.save_level(cfg.current_level) {
					last_level_action = .Save_Ok
				} else {
					last_level_action = .Save_Failed
				}
			}

			if last_level_action != .None {
				im.separator()
				switch last_level_action {
				case .Load_Ok:
					im.text("Last action: Load Level OK")
				case .Load_Failed:
					im.text("Last action: Load Level FAILED")
				case .Save_Ok:
					im.text("Last action: Save Level OK")
				case .Save_Failed:
					im.text("Last action: Save Level FAILED")
				case .None:
				}
			}
		} else {
			im.text("Runtime unavailable")
		}
	}
	im.end()

	editor_draw_bottom_panels(params.display_size)
}

@(private = "file")
draw_ui_from_vulkan_hook :: proc(params: vk.Editor_Draw_UI_Params) {
	editor_draw_ui(Editor_UI_Params{
		display_size   = params.display_size,
		runtime_config = cast(^Runtime_Game_Config_View)params.runtime_config,
		scene          = params.scene,
		load_level     = params.load_level,
		save_level     = params.save_level,
	})
}

register_with_vulkan :: proc() {
	vk.set_editor_hooks(draw_ui_from_vulkan_hook, editor_browser_shutdown)
}

// editor_draw_bottom_panels is the main entry point.
// Call it from engine_ui_definition (drawing.odin) after im.new_frame, before im.render.
// display_size should be the main viewport's work_size.
// left_reserved_w is the horizontal space reserved for other editor windows (e.g. hierarchy).
editor_draw_bottom_panels :: proc(display_size: im.Vec2, left_reserved_w: f32 = 0) {
	editor_browser_init()

	// Lazily load file entries when the current directory changes.
	if g.file_entries_dir != g.dir_current {
		reload_file_entries()
	}

	// Both panels are anchored to the bottom-left of the screen.
	// Pivot {0,1} makes the y-coordinate refer to the bottom edge of the window,
	// so collapsing to just the title bar keeps the bar at the screen bottom.
	reserved_w := left_reserved_w
	if reserved_w < 0 {
		reserved_w = 0
	}
	total_w := display_size.x - reserved_w
	if total_w < 200 {
		total_w = 200
	}
	dir_w := total_w * 0.30
	asset_x := reserved_w + dir_w + 4
	asset_w := total_w - dir_w - 4

	base_flags: im.Window_Flags = {
		.No_Move,
		.No_Resize,
		.No_Focus_On_Appearing,
		.No_Bring_To_Front_On_Focus,
	}

	// ── Directory Panel ───────────────────────────────────────────────────────
	im.set_next_window_pos({reserved_w, display_size.y}, .Always, {0, 1})
	im.set_next_window_size({dir_w, BROWSER_PANEL_DEFAULT_HEIGHT})
	if im.begin("Directory##ymir", nil, base_flags) {
		im.text_disabled("Root: %s", cstring(raw_data(g.dir_root)))
		im.separator()
		if im.begin_child("##dir_tree", {0, 0}, {}, {}) {
			draw_dir_node(g.dir_root, "(root)")
		}
		im.end_child()
	}
	im.end()

	// ── Asset Browser Panel ───────────────────────────────────────────────────
	im.set_next_window_pos({asset_x, display_size.y}, .Always, {0, 1})
	im.set_next_window_size({asset_w, BROWSER_PANEL_DEFAULT_HEIGHT})
	if im.begin("Asset Browser##ymir", nil, base_flags) {
		// Toolbar
		if im.small_button("Import") { /* TODO: open native file dialog */}
		im.same_line()
		if im.small_button("Export") { /* TODO: export g.asset_selected */}
		im.same_line()
		im.set_next_item_width(200)
		im.input_text("##ab_search", cstring(&g.search_buf[0]), size_of(g.search_buf))
		im.same_line()
		im.text_disabled("Search")
		im.separator()

		search := string(cstring(&g.search_buf[0]))

		if im.begin_child("##asset_list", {0, 0}, {}, {}) {
			if g.file_entries == nil {
				im.text_disabled("(directory empty or unreadable)")
			} else {
				for entry in g.file_entries {
					// Filter by search term (case-sensitive).
					if len(search) > 0 && !strings.contains(entry.name, search) {
						continue
					}
					icon := entry.type == .Directory ? "[D] " : "[F] "
					label := fmt.ctprintf("%s%s", icon, entry.name)
					is_sel := entry.fullpath == g.asset_selected

					if im.selectable(label, is_sel, {.Allow_Double_Click}) {
						delete(g.asset_selected)
						g.asset_selected = strings.clone(entry.fullpath)
						// Double-click a folder to navigate into it.
						if entry.type == .Directory && im.is_mouse_double_clicked(.Left) {
							navigate_to(entry.fullpath)
						}
					}
				}
			}
		}
		im.end_child()
	}
	im.end()
}
