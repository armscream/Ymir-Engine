package Vulkan

import im "../../Libs/imgui"

Editor_Draw_Hierarchy_Content_Proc :: #type proc(user_data: rawptr)
Editor_Load_Level_Proc :: #type proc(file_path: string) -> bool
Editor_Save_Level_Proc :: #type proc(file_path: string) -> bool

Editor_Draw_UI_Params :: struct {
	display_size:           im.Vec2,
	runtime_config:         rawptr,
	draw_hierarchy_content: Editor_Draw_Hierarchy_Content_Proc,
	hierarchy_user_data:    rawptr,
	load_level:             Editor_Load_Level_Proc,
	save_level:             Editor_Save_Level_Proc,
}

Editor_Draw_UI_Hook :: #type proc(params: Editor_Draw_UI_Params)
Editor_Shutdown_Hook :: #type proc()

g_editor_draw_ui_hook: Editor_Draw_UI_Hook
g_editor_shutdown_hook: Editor_Shutdown_Hook

set_editor_hooks :: proc(draw_ui: Editor_Draw_UI_Hook, shutdown: Editor_Shutdown_Hook = nil) {
	g_editor_draw_ui_hook = draw_ui
	g_editor_shutdown_hook = shutdown
}

clear_editor_hooks :: proc() {
	g_editor_draw_ui_hook = nil
	g_editor_shutdown_hook = nil
}
