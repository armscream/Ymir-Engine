package Vulkan

// Core
import intr "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"

// Vendor
import glfw "vendor:glfw"
import vk "vendor:vulkan"

// Local packages
import im "../../Libs/imgui"
import im_glfw "../../Libs/imgui/imgui_impl_glfw"
import im_vk "../../Libs/imgui/imgui_impl_vulkan"
import "../../Libs/vma"

Allocated_Image :: struct {
	device:       vk.Device,
	image:        vk.Image,
	image_view:   vk.ImageView,
	image_extent: vk.Extent3D,
	image_format: vk.Format,
	allocator:    vma.Allocator,
	allocation:   vma.Allocation,
}

@(require_results)
vk_check :: #force_inline proc(
	res: vk.Result,
	message := "Detected Vulkan error",
	loc := #caller_location,
) -> bool {
	if intr.expect(res, vk.Result.SUCCESS) == .SUCCESS {
		return true
	}
	log.errorf("[Vulkan Error] %s: %v", message, res)
	runtime.print_caller_location(loc)
	return false
}

engine_ui_definition :: proc(self: ^Engine) {
	im_glfw.new_frame()
	im_vk.new_frame()
	im.new_frame()

	if im.begin("Background", nil, {.Always_Auto_Resize}) {
		selected := &self.background_effects[self.current_background_effect]

		im.text("Selected effect: %s", selected.name)

		@(static) current_background_effect: i32
		current_background_effect = i32(self.current_background_effect)

		// If the combo is opened and an item is selected, update the current effect
		if im.begin_combo("Effect", selected.name) {
			for effect, i in self.background_effects {
				is_selected := i32(i) == current_background_effect
				if im.selectable(effect.name, is_selected) {
					current_background_effect = i32(i)
					self.current_background_effect = Compute_Effect_Kind(current_background_effect)
				}

				// Set initial focus when the currently selected item becomes visible
				if is_selected {
					im.set_item_default_focus()
				}
			}
			im.end_combo()
		}

		im.input_float4("data1", &selected.data.data1)
		im.input_float4("data2", &selected.data.data2)
		im.input_float4("data3", &selected.data.data3)
		im.input_float4("data4", &selected.data.data4)

	}
	im.end()

	im.render()
}

// Run main loop.
@(require_results)
engine_run :: proc(runtime: rawptr) -> (ok: bool) {
	_ = runtime

	if self.window == nil {
		fmt.println("Vulkan renderer window not initialized")
		return
	}

	monitor_info := get_primary_monitor_info()
	t: Timer
	timer_init(&t, monitor_info.refresh_rate)

	log.info("Entering main loop...")

	loop: for !glfw.WindowShouldClose(self.window) {

		// Do not draw if we are minimized
		if glfw.GetWindowAttrib(self.window, glfw.ICONIFIED) == 0 {
			engine_acquire_next_image(&self) or_return
		}

		// Advance timer and set for FPS update
		timer_tick(&t)
		engine_ui_definition(&self)

		// Do not draw if we are minimized
		if glfw.GetWindowAttrib(self.window, glfw.ICONIFIED) != 0 {
			glfw.WaitEvents() // Wait to avoid endless spinning
			timer_init(&t, monitor_info.refresh_rate) // Reset timer after wait
			continue
		}

		engine_draw(&self) or_return

		when ODIN_DEBUG {
			if timer_check_fps_updated(t) {
				window_update_title_with_fps(self.window, self.window_title, timer_get_fps(t))
			}
		}

		glfw.PollEvents() // Poll window events (e.g., close, minimize)
	}

	log.info("Exiting...")

	return true
}

destroy_image :: proc(self: Allocated_Image) {
	vk.DestroyImageView(self.device, self.image_view, nil)
	vma.destroy_image(self.allocator, self.image, self.allocation)
}

engine_acquire_next_image :: proc(self: ^Engine) -> (ok: bool) {
	frame := engine_get_current_frame(self)

	// Wait until the gpu has finished rendering the last frame. Timeout of 1 second
	vk_check(vk.WaitForFences(self.vk_device, 1, &frame.render_fence, true, 1e9)) or_return

	deletion_queue_flush(&frame.deletion_queue)

	vk_check(vk.ResetFences(self.vk_device, 1, &frame.render_fence)) or_return

	// Request image from the swapchain
	vk_check(
		vk.AcquireNextImageKHR(
			self.vk_device,
			self.vk_swapchain,
			max(u64),
			frame.swapchain_semaphore,
			0,
			&frame.swapchain_image_index,
		),
	) or_return

	return true
}
