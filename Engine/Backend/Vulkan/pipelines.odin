package Vulkan

// Core
import "base:runtime"
import sa "core:container/small_array"
import "core:log"
import "core:os"

// Vendor
import vk "vendor:vulkan"

load_shader_module :: proc(
	device: vk.Device,
	file_path: string,
) -> (
	shader: vk.ShaderModule,
	ok: bool,
) #optional_ok {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if code, read_err := os.read_entire_file(file_path, context.temp_allocator); read_err == nil {
		return create_shader_module(device, code)
	}
	log.errorf("Failed to load shader file: [%s]", file_path)
	return
}

// Create a new shader module, using the given code.
create_shader_module :: proc(
	device: vk.Device,
	code: []byte,
	loc := #caller_location,
) -> (
	shader: vk.ShaderModule,
	ok: bool,
) #optional_ok {
	assert(device != nil, "Invalid 'Device'", loc)

	create_info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}

	vk_check(
		vk.CreateShaderModule(device, &create_info, nil, &shader),
		"failed to create shader module",
	) or_return

	return shader, true
}


MAX_SHADER_STAGES :: #config(MAX_SHADER_STAGES, 4)

Shader_Stages :: sa.Small_Array(MAX_SHADER_STAGES, vk.PipelineShaderStageCreateInfo)

Pipeline_Builder :: struct {
	shader_stages:           Shader_Stages,
	input_assembly:          vk.PipelineInputAssemblyStateCreateInfo,
	rasterizer:              vk.PipelineRasterizationStateCreateInfo,
	color_blend_attachment:  vk.PipelineColorBlendAttachmentState,
	multisampling:           vk.PipelineMultisampleStateCreateInfo,
	vertex_input_enabled:    bool,
	vertex_bindings:         [1]vk.VertexInputBindingDescription,
	vertex_attributes:       [5]vk.VertexInputAttributeDescription,
	vertex_attribute_count:  u32,
	pipeline_layout:         vk.PipelineLayout,
	depth_stencil:           vk.PipelineDepthStencilStateCreateInfo,
	render_info:             vk.PipelineRenderingCreateInfo,
	color_attachment_format: vk.Format,
	tessellation_state:      vk.PipelineTessellationStateCreateInfo,
	base_pipeline:           vk.Pipeline,
	base_pipeline_index:     i32,
	flags:                   vk.PipelineCreateFlags,
	allocator:               runtime.Allocator,
}

// Clear all of the structs we need back to `0` with their correct `sType`.
pipeline_builder_clear :: proc(self: ^Pipeline_Builder) {
	assert(self != nil)

	self.input_assembly = {
		sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
	}

	self.rasterizer = {
		sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
	}

	self.multisampling = {
		sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
	}

	self.depth_stencil = {
		sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
	}

	self.render_info = {
		sType = .PIPELINE_RENDERING_CREATE_INFO,
	}

	self.tessellation_state = {
		sType = .PIPELINE_TESSELLATION_STATE_CREATE_INFO,
	}

	sa.clear(&self.shader_stages)
	self.vertex_input_enabled = false
	self.vertex_attribute_count = 0
	self.pipeline_layout = {}
	self.base_pipeline = {}
	self.base_pipeline_index = -1
	self.flags = {}
}

pipeline_builder_create_default :: proc() -> (builder: Pipeline_Builder) {
	pipeline_builder_clear(&builder)
	return
}

pipeline_builder_build :: proc(
	self: ^Pipeline_Builder,
	device: vk.Device,
) -> (
	pipeline: vk.Pipeline,
	ok: bool,
) #optional_ok {
	// Make viewport state from our stored viewport and scissor.
	// At the moment we wont support multiple viewports or scissors
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = 1,
		height   = 1,
		minDepth = 0,
		maxDepth = 1,
	}
	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = {width = 1, height = 1},
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}

	// Setup dummy color blending. We arent using transparent objects yet,
	// the blending is just "no blend", but we do write to the color attachment
	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &self.color_blend_attachment,
	}

	vertex_binding_count: u32 = 0
	vertex_bindings_ptr: [^]vk.VertexInputBindingDescription = nil
	vertex_attribute_count: u32 = 0
	vertex_attributes_ptr: [^]vk.VertexInputAttributeDescription = nil
	if self.vertex_input_enabled {
		vertex_binding_count = 1
		vertex_bindings_ptr = raw_data(self.vertex_bindings[:])
		vertex_attribute_count = self.vertex_attribute_count
		vertex_attributes_ptr = raw_data(self.vertex_attributes[:])
	}

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                         = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount = vertex_binding_count,
		pVertexBindingDescriptions    = vertex_bindings_ptr,
		vertexAttributeDescriptionCount = vertex_attribute_count,
		pVertexAttributeDescriptions  = vertex_attributes_ptr,
	}

	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		pDynamicStates    = raw_data(dynamic_states[:]),
		dynamicStateCount = u32(len(dynamic_states)),
	}
	shader_stages := sa.slice(&self.shader_stages)

	// Build the actual pipeline.
	// We now use all of the info structs we have been writing into into this one
	// to create the pipeline.
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		// connect the renderInfo to the pNext extension mechanism
		pNext               = &self.render_info,
		flags               = self.flags,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &self.input_assembly,
		pTessellationState  = nil,
		pViewportState      = &viewport_state,
		pRasterizationState = &self.rasterizer,
		pMultisampleState   = &self.multisampling,
		pDepthStencilState  = &self.depth_stencil,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_info,
		layout              = self.pipeline_layout,
		basePipelineHandle  = self.base_pipeline,
		basePipelineIndex   = self.base_pipeline_index,
	}

	if vk.CreateGraphicsPipelines == nil {
		log.error("pipeline_builder_build: vk.CreateGraphicsPipelines proc is nil")
		return
	}

	create_result := vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_info, nil, &pipeline)

	vk_check(
		create_result,
		"Failed to create pipeline",
	) or_return

	return pipeline, true
}

pipeline_builder_add_shader :: proc(
	self: ^Pipeline_Builder,
	shader: vk.ShaderModule,
	stage: vk.ShaderStageFlags,
	entry_point: cstring = "main",
) {
	create_info := pipeline_shader_stage_create_info(stage, shader, entry_point)
	sa.push(&self.shader_stages, create_info)
}

pipeline_builder_set_shaders :: proc(
	self: ^Pipeline_Builder,
	vertex_shader, fragment_shader: vk.ShaderModule,
) {
	pipeline_builder_add_shader(self, vertex_shader, {.VERTEX})
	pipeline_builder_add_shader(self, fragment_shader, {.FRAGMENT})
}

pipeline_builder_set_input_topology :: proc(
	self: ^Pipeline_Builder,
	topology: vk.PrimitiveTopology,
	primitive_restart_enable: bool = false,
) {
	self.input_assembly.topology = topology
	// we are not going to use primitive restart on the entire tutorial so leave it on false
	self.input_assembly.primitiveRestartEnable = b32(primitive_restart_enable)
}

pipeline_builder_set_polygon_mode :: proc(
	self: ^Pipeline_Builder,
	polygon_mode: vk.PolygonMode,
	line_width: f32 = 1.0,
) {
	self.rasterizer.polygonMode = polygon_mode
	self.rasterizer.lineWidth = line_width
}

pipeline_builder_set_cull_mode :: proc(
	self: ^Pipeline_Builder,
	cull_mode: vk.CullModeFlags,
	front_face: vk.FrontFace,
) {
	self.rasterizer.cullMode = cull_mode
	self.rasterizer.frontFace = front_face
}

pipeline_builder_set_multisampling :: proc(
	self: ^Pipeline_Builder,
	rasterization_samples: vk.SampleCountFlags,
	min_sample_shading: f32 = 1.0,
	sample_mask: ^vk.SampleMask = nil,
	alpha_to_coverage_enable: bool = false,
	alpha_to_one_enable: bool = false,
) {
	self.multisampling.rasterizationSamples = rasterization_samples
	self.multisampling.sampleShadingEnable = min_sample_shading < 1.0
	self.multisampling.minSampleShading = min_sample_shading
	self.multisampling.pSampleMask = sample_mask
	self.multisampling.alphaToCoverageEnable = b32(alpha_to_coverage_enable)
	self.multisampling.alphaToOneEnable = b32(alpha_to_one_enable)
}

pipeline_builder_set_multisampling_none :: proc(self: ^Pipeline_Builder) {
	pipeline_builder_set_multisampling(self, {._1})
}

pipeline_builder_set_blend_state :: proc(
	self: ^Pipeline_Builder,
	blend_enable: bool,
	src_color_blend: vk.BlendFactor,
	dst_color_blend: vk.BlendFactor,
	color_blend_op: vk.BlendOp,
	src_alpha_blend: vk.BlendFactor,
	dst_alpha_blend: vk.BlendFactor,
	alpha_blend_op: vk.BlendOp,
	color_write_mask: vk.ColorComponentFlags,
) {
	self.color_blend_attachment = {
		blendEnable         = b32(blend_enable),
		srcColorBlendFactor = src_color_blend,
		dstColorBlendFactor = dst_color_blend,
		colorBlendOp        = color_blend_op,
		srcAlphaBlendFactor = src_alpha_blend,
		dstAlphaBlendFactor = dst_alpha_blend,
		alphaBlendOp        = alpha_blend_op,
		colorWriteMask      = color_write_mask,
	}
}

pipeline_builder_disable_blending :: proc(self: ^Pipeline_Builder) {
	// Default write mask
	self.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	// No blending
	self.color_blend_attachment.blendEnable = false
}

pipeline_builder_set_color_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format) {
	self.color_attachment_format = format
	// Connect the format to the `render_info`  structure
	self.render_info.colorAttachmentCount = 1
	self.render_info.pColorAttachmentFormats = &self.color_attachment_format
}

pipeline_builder_set_depth_attachment_format :: proc(self: ^Pipeline_Builder, format: vk.Format) {
	self.render_info.depthAttachmentFormat = format
}

pipeline_builder_set_stencil_attachment_format :: proc(
	self: ^Pipeline_Builder,
	format: vk.Format,
) {
	self.render_info.stencilAttachmentFormat = format
}

pipeline_builder_set_vertex_input_for_vertex_struct :: proc(self: ^Pipeline_Builder) {
	self.vertex_input_enabled = true
	if USE_QUANTIZED_VERTICES {
		self.vertex_bindings[0] = {
			binding   = 0,
			stride    = size_of(Vertex_Quantized),
			inputRate = .VERTEX,
		}

		self.vertex_attributes[0] = {
			location = 0,
			binding  = 0,
			format   = .R16G16B16A16_SFLOAT,
			offset   = u32(offset_of(Vertex_Quantized, position)),
		}
		self.vertex_attributes[1] = {
			location = 1,
			binding  = 0,
			format   = .R16_SFLOAT,
			offset   = u32(offset_of(Vertex_Quantized, uv_x)),
		}
		self.vertex_attributes[2] = {
			location = 2,
			binding  = 0,
			format   = .R16G16B16A16_SFLOAT,
			offset   = u32(offset_of(Vertex_Quantized, normal)),
		}
		self.vertex_attributes[3] = {
			location = 3,
			binding  = 0,
			format   = .R16_SFLOAT,
			offset   = u32(offset_of(Vertex_Quantized, uv_y)),
		}
		self.vertex_attributes[4] = {
			location = 4,
			binding  = 0,
			format   = .R8G8B8A8_UNORM,
			offset   = u32(offset_of(Vertex_Quantized, color)),
		}
	} else {
		self.vertex_bindings[0] = {
			binding   = 0,
			stride    = size_of(Vertex),
			inputRate = .VERTEX,
		}

		self.vertex_attributes[0] = {
			location = 0,
			binding  = 0,
			format   = .R32G32B32_SFLOAT,
			offset   = u32(offset_of(Vertex, position)),
		}
		self.vertex_attributes[1] = {
			location = 1,
			binding  = 0,
			format   = .R32_SFLOAT,
			offset   = u32(offset_of(Vertex, uv_x)),
		}
		self.vertex_attributes[2] = {
			location = 2,
			binding  = 0,
			format   = .R32G32B32_SFLOAT,
			offset   = u32(offset_of(Vertex, normal)),
		}
		self.vertex_attributes[3] = {
			location = 3,
			binding  = 0,
			format   = .R32_SFLOAT,
			offset   = u32(offset_of(Vertex, uv_y)),
		}
		self.vertex_attributes[4] = {
			location = 4,
			binding  = 0,
			format   = .R32G32B32A32_SFLOAT,
			offset   = u32(offset_of(Vertex, color)),
		}
	}

	self.vertex_attribute_count = 5
}

pipeline_builder_set_depth_bias :: proc(
	self: ^Pipeline_Builder,
	constant_factor: f32,
	clamp: f32,
	slope_factor: f32,
) {
	self.rasterizer.depthBiasEnable = true
	self.rasterizer.depthBiasConstantFactor = constant_factor
	self.rasterizer.depthBiasClamp = clamp
	self.rasterizer.depthBiasSlopeFactor = slope_factor
}

pipeline_builder_set_depth_state :: proc(
	self: ^Pipeline_Builder,
	depth_test: bool,
	depth_write: bool,
	compare_op: vk.CompareOp,
) {
	self.depth_stencil.depthTestEnable = b32(depth_test)
	self.depth_stencil.depthWriteEnable = b32(depth_write)
	self.depth_stencil.depthCompareOp = compare_op
}

pipeline_builder_set_depth_bounds :: proc(
	self: ^Pipeline_Builder,
	min_depth_bounds: f32,
	max_depth_bounds: f32,
) {
	self.depth_stencil.depthBoundsTestEnable = true
	self.depth_stencil.minDepthBounds = min_depth_bounds
	self.depth_stencil.maxDepthBounds = max_depth_bounds
}

pipeline_builder_disable_depth_test :: proc(self: ^Pipeline_Builder) {
	self.depth_stencil.depthTestEnable = false
	self.depth_stencil.depthWriteEnable = false
	self.depth_stencil.depthCompareOp = .NEVER
	self.depth_stencil.depthBoundsTestEnable = false
	self.depth_stencil.stencilTestEnable = false
	self.depth_stencil.front = {}
	self.depth_stencil.back = {}
	self.depth_stencil.minDepthBounds = 0.0
	self.depth_stencil.maxDepthBounds = 1.0
}

pipeline_builder_enable_depth_test :: proc(
	self: ^Pipeline_Builder,
	depth_write_enable: bool,
	op: vk.CompareOp,
) {
	self.depth_stencil.depthTestEnable = true
	self.depth_stencil.depthWriteEnable = b32(depth_write_enable)
	self.depth_stencil.depthCompareOp = op
	self.depth_stencil.depthBoundsTestEnable = false
	self.depth_stencil.stencilTestEnable = false
	self.depth_stencil.front = {}
	self.depth_stencil.back = {}
	self.depth_stencil.minDepthBounds = 0.0
	self.depth_stencil.maxDepthBounds = 1.0
}

pipeline_builder_set_tessellation :: proc(self: ^Pipeline_Builder, patch_control_points: u32) {
	self.tessellation_state.patchControlPoints = patch_control_points
}

pipeline_builder_set_rasterizer_discard :: proc(self: ^Pipeline_Builder, discard_enable: bool) {
	self.rasterizer.rasterizerDiscardEnable = b32(discard_enable)
}

pipeline_builder_set_depth_clamp :: proc(self: ^Pipeline_Builder, clamp_enable: bool) {
	self.rasterizer.depthClampEnable = b32(clamp_enable)
}

pipeline_builder_set_base_pipeline :: proc(
	self: ^Pipeline_Builder,
	base_pipeline: vk.Pipeline,
	base_pipeline_index: i32 = -1,
) {
	self.base_pipeline = base_pipeline
	self.base_pipeline_index = base_pipeline_index
	self.flags += {.DERIVATIVE}
}

pipeline_builder_enable_blending_additive :: proc(self: ^Pipeline_Builder) {
	self.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	self.color_blend_attachment.blendEnable = true
	self.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
	self.color_blend_attachment.dstColorBlendFactor = .ONE
	self.color_blend_attachment.colorBlendOp = .ADD
	self.color_blend_attachment.srcAlphaBlendFactor = .ONE
	self.color_blend_attachment.dstAlphaBlendFactor = .ZERO
	self.color_blend_attachment.alphaBlendOp = .ADD
}

pipeline_builder_enable_blending_alphablend :: proc(self: ^Pipeline_Builder) {
	self.color_blend_attachment.colorWriteMask = {.R, .G, .B, .A}
	self.color_blend_attachment.blendEnable = true
	self.color_blend_attachment.srcColorBlendFactor = .SRC_ALPHA
	self.color_blend_attachment.dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA
	self.color_blend_attachment.colorBlendOp = .ADD
	self.color_blend_attachment.srcAlphaBlendFactor = .ONE
	self.color_blend_attachment.dstAlphaBlendFactor = .ZERO
	self.color_blend_attachment.alphaBlendOp = .ADD
}
