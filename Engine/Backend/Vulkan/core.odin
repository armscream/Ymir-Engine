package Vulkan

// Core
import intr "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import la "core:math/linalg"

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

Allocated_Buffer :: struct {
    buffer:     vk.Buffer,
    info:       vma.Allocation_Info,
    allocation: vma.Allocation,
    allocator:  vma.Allocator,
}

Vertex :: struct {
    position: la.Vector3f32,
    uv_x:     f32,
    normal:   la.Vector3f32,
    uv_y:     f32,
    color:    la.Vector4f32,
}

// Holds the resources needed for a mesh
GPU_Mesh_Buffers :: struct {
    index_buffer:          Allocated_Buffer,
    vertex_buffer:         Allocated_Buffer,
    vertex_buffer_address: vk.DeviceAddress,
}

// Push constants for our mesh object draws
GPU_Draw_Push_Constants :: struct {
    world_matrix: la.Matrix4f32,
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

	if !self.is_initialized {
		log.error("Vulkan engine is not initialized — skipping main loop")
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

create_buffer :: proc(
    self: ^Engine,
    alloc_size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    memory_usage: vma.Memory_Usage,
) -> (
    new_buffer: Allocated_Buffer,
    ok: bool,
) {
    // allocate buffer
    buffer_info := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size  = alloc_size,
        usage = usage,
    }

    vma_alloc_info := vma.Allocation_Create_Info {
        usage = memory_usage,
        flags = {.Mapped},
    }

    new_buffer.allocator = self.vma_allocator

    // allocate the buffer
    vk_check(
        vma.create_buffer(
            self.vma_allocator,
            buffer_info,
            vma_alloc_info,
            &new_buffer.buffer,
            &new_buffer.allocation,
            &new_buffer.info,
        ),
    ) or_return

    return new_buffer, true
}

destroy_buffer :: proc(self: Allocated_Buffer) {
    vma.destroy_buffer(self.allocator, self.buffer, self.allocation)
}

upload_mesh :: proc(
    self: ^Engine,
    indices: []u32,
    vertices: []Vertex,
) -> (
    new_surface: GPU_Mesh_Buffers,
    ok: bool,
) {
    vertex_buffer_size := vk.DeviceSize(len(vertices) * size_of(Vertex))
    index_buffer_size := vk.DeviceSize(len(indices) * size_of(u32))

    // Create vertex buffer
    new_surface.vertex_buffer = create_buffer(
        self,
        vertex_buffer_size,
        {.STORAGE_BUFFER, .TRANSFER_DST, .SHADER_DEVICE_ADDRESS, .VERTEX_BUFFER},
        .Gpu_Only,
    ) or_return
    defer if !ok {
        destroy_buffer(new_surface.vertex_buffer)
    }

    // Find the address of the vertex buffer
    device_address_info := vk.BufferDeviceAddressInfo {
        sType  = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = new_surface.vertex_buffer.buffer,
    }
    new_surface.vertex_buffer_address = vk.GetBufferDeviceAddress(
        self.vk_device,
        &device_address_info,
    )

    // Create index buffer
    new_surface.index_buffer = create_buffer(
        self,
        index_buffer_size,
        {.INDEX_BUFFER, .TRANSFER_DST},
        .Gpu_Only,
    ) or_return
    defer if !ok {
        destroy_buffer(new_surface.index_buffer)
    }

    staging := create_buffer(
        self,
        vertex_buffer_size + index_buffer_size,
        {.TRANSFER_SRC},
        .Cpu_Only,
    ) or_return
    defer destroy_buffer(staging)

    data := staging.info.mapped_data
    // Copy vertex buffer
    intr.mem_copy(data, raw_data(vertices), vertex_buffer_size)
    // Copy index buffer
    intr.mem_copy(
        rawptr(uintptr(data) + uintptr(vertex_buffer_size)),
        raw_data(indices),
        index_buffer_size,
    )

    // Create a struct to hold all the copy parameters
    Copy_Data :: struct {
        staging_buffer:     vk.Buffer,
        vertex_buffer:      vk.Buffer,
        index_buffer:       vk.Buffer,
        vertex_buffer_size: vk.DeviceSize,
        index_buffer_size:  vk.DeviceSize,
    }

    // Prepare the data structure
    copy_data := Copy_Data {
        staging_buffer     = staging.buffer,
        vertex_buffer      = new_surface.vertex_buffer.buffer,
        index_buffer       = new_surface.index_buffer.buffer,
        vertex_buffer_size = vertex_buffer_size,
        index_buffer_size  = index_buffer_size,
    }

    // Call the immediate submit with our data and procedure
    engine_immediate_submit(
        self,
        copy_data,
        proc(engine: ^Engine, cmd: vk.CommandBuffer, data: Copy_Data) {
            // Setup vertex buffer copy
            vertex_copy := vk.BufferCopy {
                srcOffset = 0,
                dstOffset = 0,
                size      = data.vertex_buffer_size,
            }

            // Copy vertex data from staging to the new surface vertex buffer
            vk.CmdCopyBuffer(cmd, data.staging_buffer, data.vertex_buffer, 1, &vertex_copy)

            // Setup index buffer copy
            index_copy := vk.BufferCopy {
                srcOffset = data.vertex_buffer_size,
                dstOffset = 0,
                size      = data.index_buffer_size,
            }

            // Copy index data from staging to the new surface index buffer
            vk.CmdCopyBuffer(cmd, data.staging_buffer, data.index_buffer, 1, &index_copy)
        },
    )

    return new_surface, true
}