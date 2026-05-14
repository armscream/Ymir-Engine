package imguizmo

when ODIN_OS == .Windows {
	when ODIN_ARCH == .amd64 {
		foreign import lib "imguizmo_windows_x64.lib"
	} else {
		foreign import lib "imguizmo_windows_arm64.lib"
	}
}

Operation :: enum i32 {
	Translate_X = 1 << 0,
	Translate_Y = 1 << 1,
	Translate_Z = 1 << 2,
	Rotate_X = 1 << 3,
	Rotate_Y = 1 << 4,
	Rotate_Z = 1 << 5,
	Rotate_Screen = 1 << 6,
	Scale_X = 1 << 7,
	Scale_Y = 1 << 8,
	Scale_Z = 1 << 9,
	Bounds = 1 << 10,
	Scale_XU = 1 << 11,
	Scale_YU = 1 << 12,
	Scale_ZU = 1 << 13,

	Translate = Translate_X | Translate_Y | Translate_Z,
	Rotate = Rotate_X | Rotate_Y | Rotate_Z | Rotate_Screen,
	Scale = Scale_X | Scale_Y | Scale_Z,
	ScaleU = Scale_XU | Scale_YU | Scale_ZU,
	Universal = Translate | Rotate | ScaleU,
}

Mode :: enum i32 {
	Local = 0,
	World = 1,
}

foreign lib {
	@(link_name = "ImGuizmo_SetOrthographic")
	set_orthographic :: proc(orthographic: bool) ---

	@(link_name = "ImGuizmo_SetDrawlist")
	set_drawlist :: proc(drawlist: rawptr = nil) ---

	@(link_name = "ImGuizmo_SetImGuiContext")
	set_imgui_context :: proc(ctx: rawptr) ---

	@(link_name = "ImGuizmo_BeginFrame")
	begin_frame :: proc() ---

	@(link_name = "ImGuizmo_SetRect")
	set_rect :: proc(x, y, width, height: f32) ---

	@(link_name = "ImGuizmo_Manipulate")
	manipulate :: proc(
		view: ^f32,
		projection: ^f32,
		operation: Operation,
		mode: Mode,
		mat_ptr: ^f32,
		delta_matrix: ^f32 = nil,
		snap: ^f32 = nil,
		local_bounds: ^f32 = nil,
		bounds_snap: ^f32 = nil,
	) -> bool ---

	@(link_name = "ImGuizmo_DecomposeMatrixToComponents")
	decompose_matrix_to_components :: proc(
		mat_ptr: ^f32,
		translation: ^f32,
		rotation: ^f32,
		scale: ^f32,
	) ---

	@(link_name = "ImGuizmo_RecomposeMatrixFromComponents")
	recompose_matrix_from_components :: proc(
		translation: ^f32,
		rotation: ^f32,
		scale: ^f32,
		mat_ptr: ^f32,
	) ---

	@(link_name = "ImGuizmo_IsOver")
	is_over :: proc() -> bool ---

	@(link_name = "ImGuizmo_IsUsing")
	is_using :: proc() -> bool ---
}
