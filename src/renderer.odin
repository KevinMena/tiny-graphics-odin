package graphics

import "base:runtime"
import "core:log"
import "libs:shadercross"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
import im_sdlgpu "shared:imgui/imgui_impl_sdlgpu3"
import sdl "vendor:sdl3"

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32
Mat4 :: matrix[4, 4]f32
Quaternion :: quaternion128


WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}

RendererData :: struct {
	device:               ^sdl.GPUDevice,
	window:               ^sdl.Window,
	window_size:          [2]i32,
	depth_texture:        ^sdl.GPUTexture,
	depth_texture_format: sdl.GPUTextureFormat,
	clear_color:          sdl.FColor,

	// TODO: Make these a properties of the materials instead, not a global one
	pipeline:             ^sdl.GPUGraphicsPipeline,
	sampler:              ^sdl.GPUSampler,
	loaded_textures:      map[int]^sdl.Surface,
	loaded_textures_id:   map[string]int,
	loaded_textures_gpu:  map[int]^sdl.GPUTexture,
}

RenderContext :: struct {
	cmd_buffer:    ^sdl.GPUCommandBuffer,
	render_pass:   ^sdl.GPURenderPass,
	swapchain_tex: ^sdl.GPUTexture,
	im_draw_data:  ^im.DrawData,
}

d: RendererData

@(deferred_none = quit)
init :: proc() {
	init_sdl()
	init_imgui()

	// Load default textures
	load_default_textures()

	// Create the graphics pipeline
	setup_pipeline()
}

quit :: proc() {
	for id, texture in d.loaded_textures_gpu {
		sdl.ReleaseGPUTexture(d.device, texture)
	}

	free_pipeline()
	free_imgui()
	free_sdl()
}

begin_render :: proc() -> (RenderContext, bool) {
	// 1. Acquire command buffer
	cmd_buffer := sdl.AcquireGPUCommandBuffer(d.device)
	// 2. Acquire swapchain texture
	swapchain_tex: ^sdl.GPUTexture

	// IMGUI Rendering
	im.Render()
	im_draw_data := im.GetDrawData()

	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buffer, d.window, &swapchain_tex, nil, nil) {
		return {}, false
	}

	// 3. Begin Render pass
	color_target := sdl.GPUColorTargetInfo {
		texture     = swapchain_tex,
		clear_color = d.clear_color,
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	depth_target_info := sdl.GPUDepthStencilTargetInfo {
		texture          = d.depth_texture,
		clear_depth      = 1.0,
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .DONT_CARE,
		stencil_store_op = .DONT_CARE,
	}
	render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, &depth_target_info)

	// Bind graphics pipeline
	sdl.BindGPUGraphicsPipeline(render_pass, d.pipeline)

	ctx := RenderContext {
		cmd_buffer    = cmd_buffer,
		swapchain_tex = swapchain_tex,
		render_pass   = render_pass,
		im_draw_data  = im_draw_data,
	}

	return ctx, true
}

end_render :: proc(ctx: RenderContext) {
	// 5. End Render pass
	sdl.EndGPURenderPass(ctx.render_pass)

	// 6. More render passes if needed
	// IMGUI Render pass
	if ctx.im_draw_data.DisplaySize.x > 0 && ctx.im_draw_data.DisplaySize.y > 0 {
		im_sdlgpu.PrepareDrawData(ctx.im_draw_data, ctx.cmd_buffer)
		im_color_target := sdl.GPUColorTargetInfo {
			texture  = ctx.swapchain_tex,
			load_op  = .LOAD,
			store_op = .STORE,
		}

		im_render_pass := sdl.BeginGPURenderPass(ctx.cmd_buffer, &im_color_target, 1, nil)
		im_sdlgpu.RenderDrawData(ctx.im_draw_data, ctx.cmd_buffer, im_render_pass)
		sdl.EndGPURenderPass(im_render_pass)
	}

	// 7. Submit to command buffer
	if !sdl.SubmitGPUCommandBuffer(ctx.cmd_buffer) {
		log.errorf("Failed to submit the command buffer: %s", sdl.GetError())
	}
}

//////////////////////////////////////////////////////////////////////////
////////////////                SDL                      ////////////////
////////////////////////////////////////////////////////////////////////

sdl_assert :: proc(ok: bool) {
	if !ok do log.panicf("SDL Error: %s", sdl.GetError())
}

sdl_log :: proc "c" (
	userdata: rawptr,
	category: sdl.LogCategory,
	priority: sdl.LogPriority,
	message: cstring,
) {
	context = (transmute(^runtime.Context)userdata)^
	level: log.Level
	switch priority {
	case .INVALID, .TRACE, .VERBOSE, .DEBUG:
		level = .Debug
	case .INFO:
		level = .Info
	case .WARN:
		level = .Warning
	case .ERROR:
		level = .Error
	case .CRITICAL:
		level = .Fatal
	}
	log.logf(level, "SDL {}: {}", category, message)
}

@(private = "file")
free_sdl :: proc() {
	shadercross.Quit()
	sdl.ReleaseGPUTexture(d.device, d.depth_texture)
	sdl.ReleaseWindowFromGPUDevice(d.device, d.window)
	sdl.DestroyWindow(d.window)
	sdl.DestroyGPUDevice(d.device)
	sdl.Quit()
}

@(private = "file")
init_sdl :: proc() {
	@(static) sdl_log_context: runtime.Context
	sdl_log_context = context
	sdl_log_context.logger.options -= {.Short_File_Path, .Line, .Procedure}
	sdl.SetLogPriorities(.VERBOSE)
	sdl.SetLogOutputFunction(sdl_log, &sdl_log_context)

	sdl_ok := sdl.Init({.VIDEO}); sdl_assert(sdl_ok)

	// TODO: ADD .SPIRV WHEN TRYING TO WOKR WITH VULKAN
	shader_formats: sdl.GPUShaderFormat = {.DXIL}
	d.device = sdl.CreateGPUDevice(shader_formats, true, nil); sdl_assert(d.device != nil)

	//Shadercross setup for translating shaders
	shadercross_ok := shadercross.Init(); sdl_assert(shadercross_ok)

	windows_flags: sdl.WindowFlags = {.HIGH_PIXEL_DENSITY}
	d.window = sdl.CreateWindow("SDL Test", 1280, 720, windows_flags); sdl_assert(d.window != nil)

	ok := sdl.ClaimWindowForGPUDevice(d.device, d.window); sdl_assert(ok)

	ok = sdl.GetWindowSize(d.window, &d.window_size.x, &d.window_size.y); sdl_assert(ok)

	depth_tex_props := sdl.CreateProperties()
	defer sdl.DestroyProperties(depth_tex_props)

	sdl.SetFloatProperty(depth_tex_props, sdl.PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT, 1.0)

	d.depth_texture_format = get_depth_format()
	d.depth_texture = sdl.CreateGPUTexture(
		d.device,
		{
			format = d.depth_texture_format,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(d.window_size.x),
			height = u32(d.window_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
			props = depth_tex_props,
		},
	)

	d.clear_color = sdl.FColor{0.1, 0.15, 0.25, 1.0}

	_ = sdl.SetWindowRelativeMouseMode(d.window, true)
}

@(private = "file")
get_depth_format :: proc() -> sdl.GPUTextureFormat {
	formats := [3]sdl.GPUTextureFormat{.D16_UNORM, .D24_UNORM, .D32_FLOAT}

	for format in formats {
		if sdl.GPUTextureSupportsFormat(d.device, format, .D2, {.DEPTH_STENCIL_TARGET}) {
			return format
		}
	}

	return .INVALID
}

@(private = "file")
free_pipeline :: proc() {
	sdl.ReleaseGPUSampler(d.device, d.sampler)
	sdl.ReleaseGPUGraphicsPipeline(d.device, d.pipeline)
}

@(private = "file")
setup_pipeline :: proc() {
	vertex_shader := compile_shader_stage(shader_code, cstring("MainVS"), .VERTEX, d.device)
	sdl_assert(vertex_shader != nil)
	defer sdl.ReleaseGPUShader(d.device, vertex_shader)

	frag_shader := compile_shader_stage(shader_code, cstring("MainPS"), .FRAGMENT, d.device)
	sdl_assert(frag_shader != nil)
	defer sdl.ReleaseGPUShader(d.device, frag_shader)

	vertex_attributes := []sdl.GPUVertexAttribute {
		{
			location    = 0, // Matches TEXCOORD0 (pos)
			buffer_slot = 0,
			format      = .FLOAT3,
			offset      = u32(offset_of(Vertex, pos)),
		},
		{
			location    = 1, // Matches TEXCOORD1 (uv)
			buffer_slot = 0,
			format      = .FLOAT2,
			offset      = u32(offset_of(Vertex, uv)),
		},
		{
			location    = 2, // Matches TEXCOORD2 (color)
			buffer_slot = 0,
			format      = .FLOAT4,
			offset      = u32(offset_of(Vertex, color)),
		},
	}

	pipeline_info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vertex_shader,
		fragment_shader = frag_shader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			num_vertex_buffers = 1,
			vertex_buffer_descriptions = &(sdl.GPUVertexBufferDescription {
					slot = 0,
					pitch = size_of(Vertex),
				}),
			num_vertex_attributes = u32(len(vertex_attributes)),
			vertex_attributes = raw_data(vertex_attributes),
		},
		depth_stencil_state = {
			enable_depth_test = true,
			enable_depth_write = true,
			compare_op = .LESS,
		},
		rasterizer_state = {cull_mode = .BACK},
		target_info = sdl.GPUGraphicsPipelineTargetInfo {
			num_color_targets = 1,
			color_target_descriptions = &sdl.GPUColorTargetDescription {
				format = sdl.GetGPUSwapchainTextureFormat(d.device, d.window),
			},
			has_depth_stencil_target = true,
			depth_stencil_format = d.depth_texture_format,
		},
	}

	d.pipeline = sdl.CreateGPUGraphicsPipeline(
		d.device,
		pipeline_info,
	); sdl_assert(d.pipeline != nil)

	// Texture sampler
	d.sampler = sdl.CreateGPUSampler(d.device, {})
}

//////////////////////////////////////////////////////////////////////////
////////////////                IMGUI                    ////////////////
////////////////////////////////////////////////////////////////////////

@(private = "file")
free_imgui :: proc() {
	im_sdl.Shutdown()
	im_sdlgpu.Shutdown()
}

@(private = "file")
init_imgui :: proc() {
	im.CHECKVERSION()
	im.CreateContext()
	im_sdl.InitForSDLGPU(d.window)
	im_sdlgpu.Init(
		&{
			Device = d.device,
			ColorTargetFormat = sdl.GetGPUSwapchainTextureFormat(d.device, d.window),
		},
	)
}

new_frame_imgui :: proc() {
	im_sdlgpu.NewFrame()
	im_sdl.NewFrame()
	im.NewFrame()
}
