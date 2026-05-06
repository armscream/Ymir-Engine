package Vulkan

// Core
import "base:runtime"
import "core:log"
import "core:os"

// Vendor
import vk "vendor:vulkan"
// Core
import sa "core:container/small_array"

MAX_SHADER_STAGES :: #config(MAX_SHADER_STAGES, 8)

Shader_Stages :: sa.Small_Array(MAX_SHADER_STAGES, vk.PipelineShaderStageCreateInfo)

Pipeline_Builder :: struct {
	shader_stages:           Shader_Stages,
	input_assembly:          vk.PipelineInputAssemblyStateCreateInfo,
	rasterizer:              vk.PipelineRasterizationStateCreateInfo,
	color_blend_attachment:  vk.PipelineColorBlendAttachmentState,
	multisampling:           vk.PipelineMultisampleStateCreateInfo,
	pipeline_layout:         vk.PipelineLayout,
	depth_stencil:           vk.PipelineDepthStencilStateCreateInfo,
	render_info:             vk.PipelineRenderingCreateInfo,
	color_attachment_format: vk.Format,
	tessellation_state:      vk.PipelineTessellationStateCreateInfo,
	base_pipeline:           vk.Pipeline,
	base_pipeline_index:     i32,
	flags:                   vk.PipelineCreateFlags,
	allocator:               runtime.Allocator,
	vertex_binding_descs:    [4]vk.VertexInputBindingDescription,
	vertex_binding_count:    u32,
	vertex_attribute_descs:  [16]vk.VertexInputAttributeDescription,
	vertex_attribute_count:  u32,
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

pipeline_builder_build :: proc(
	self: ^Pipeline_Builder,
	device: vk.Device,
) -> (
	pipeline: vk.Pipeline,
	ok: bool,
) #optional_ok {
	// Make viewport state from our stored viewport and scissor.
	// At the moment we wont support multiple viewports or scissors
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
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

	vertex_input_info := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = self.vertex_binding_count,
		pVertexBindingDescriptions      = &self.vertex_binding_descs[0],
		vertexAttributeDescriptionCount = self.vertex_attribute_count,
		pVertexAttributeDescriptions    = &self.vertex_attribute_descs[0],
	}

	dynamic_states := [?]vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_info := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		pDynamicStates    = raw_data(dynamic_states[:]),
		dynamicStateCount = u32(len(dynamic_states)),
	}

	// Build the actual pipeline.
	// We now use all of the info structs we have been writing into into this one
	// to create the pipeline.
	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		// Connect the renderInfo to the pNext extension mechanism
		pNext               = &self.render_info,
		flags               = self.flags,
		stageCount          = u32(sa.len(self.shader_stages)),
		pStages             = raw_data(sa.slice(&self.shader_stages)),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &self.input_assembly,
		pTessellationState  = &self.tessellation_state,
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

	res := vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_info, nil, &pipeline)
	log.debugf(
		"vkCreateGraphicsPipelines: result=%v pipeline=0x%x layout=0x%x device=0x%x",
		res,
		u64(pipeline),
		u64(pipeline_info.layout),
		u64(uintptr(device)),
	)
	vk_check(res, "Failed to create pipeline") or_return

	if pipeline == 0 {
		log.error("vkCreateGraphicsPipelines returned VK_SUCCESS but pipeline handle is VK_NULL_HANDLE")
		ok = false
		return
	}

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

pipeline_builder_set_vertex_layout :: proc(
	self: ^Pipeline_Builder,
	bindings: []vk.VertexInputBindingDescription,
	attributes: []vk.VertexInputAttributeDescription,
) {
	assert(len(bindings) <= len(self.vertex_binding_descs))
	assert(len(attributes) <= len(self.vertex_attribute_descs))
	copy(self.vertex_binding_descs[:], bindings)
	self.vertex_binding_count = u32(len(bindings))
	copy(self.vertex_attribute_descs[:], attributes)
	self.vertex_attribute_count = u32(len(attributes))
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
    polygon_mode: vk.PolygonMode, // e.g., FILL, LINE, POINT, etc. can set wireframe or solid
    line_width: f32 = 1.0,
) {
    self.rasterizer.polygonMode = polygon_mode
    self.rasterizer.lineWidth = line_width
}

pipeline_builder_set_cull_mode :: proc(
    self: ^Pipeline_Builder,
    cull_mode: vk.CullModeFlags, // e.g., NONE, FRONT, BACK, FRONT_AND_BACK
    front_face: vk.FrontFace,   // e.g., CLOCKWISE, COUNTER_CLOCKWISE
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
// End of pipeline builder procs

// Clear all fields to default values. This is useful to ensure that any fields we forget to set
// will have a known default value, and not some random uninitialized data.
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
	self.pipeline_layout = {}
	self.base_pipeline = {}
	self.base_pipeline_index = -1
	self.flags = {}
}

pipeline_builder_create_default :: proc() -> (builder: Pipeline_Builder) {
	pipeline_builder_clear(&builder)
	return
}

load_shader_module :: proc(
	device: vk.Device,
	file_path: string,
) -> (
	shader: vk.ShaderModule,
	ok: bool,
) #optional_ok {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if code, code_ok := os.read_entire_file(file_path, context.temp_allocator); code_ok == nil {
		// Create a new shader module, using the code we loaded
		return create_shader_module(device, code)
	}
	log.errorf("Failed to load shader file: [%s]", file_path)
	return
}

create_shader_module :: proc(
	device: vk.Device,
	code: []byte,
) -> (
	shader: vk.ShaderModule,
	ok: bool,
) #optional_ok {
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
