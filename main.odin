package game

import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "libs/shadercross"
import sdl "vendor:sdl3"
import sdl_image "vendor:sdl3/image"

shader_code := #load("assets/shaders/basic.hlsl", string)

UniformBufferObject :: struct {
	mvp: matrix[4, 4]f32,
}

Vector2 :: [2]f32
Vector3 :: [3]f32

Vertex :: struct {
	pos:   Vector3,
	color: sdl.FColor,
	uv:    Vector2,
}

WHITE :: sdl.FColor{1, 1, 1, 1}

sdl_assert :: proc(ok: bool) {
	if !ok do log.panicf("SDL Error: %s", sdl.GetError())
}

compile_shader_stage :: proc(
	raw_code: string,
	entrypoint: cstring,
	stage: shadercross.ShaderStage,
	device: ^sdl.GPUDevice,
) -> (
	shader: ^sdl.GPUShader,
) {
	prop_id: sdl.PropertiesID
	vertex_text := strings.clone_to_cstring(raw_code, context.temp_allocator)
	vertex_info := shadercross.HLSL_Info {
		source       = vertex_text,
		entrypoint   = entrypoint,
		include_dir  = nil,
		shader_stage = stage,
		props        = prop_id,
	}

	size: uint
	spirv_bytecode := shadercross.CompileSPIRVFromHLSL(
		vertex_info,
		&size,
	); sdl_assert(spirv_bytecode != nil)
	defer sdl.free(rawptr(spirv_bytecode))

	reflect := shadercross.ReflectGraphicsSPIRV(
		spirv_bytecode,
		size,
		prop_id,
	); sdl_assert(reflect != nil)
	defer sdl.free(rawptr(reflect))

	shader = shadercross.CompileGraphicsShaderFromSPIRV(
		device,
		{
			bytecode = spirv_bytecode,
			bytecode_size = size,
			entrypoint = entrypoint,
			shader_stage = stage,
			props = prop_id,
		},
		reflect.resource_info,
		prop_id,
	)

	return
}

main :: proc() {
	context.logger = log.create_console_logger()

	sdl_ok := sdl.Init({.VIDEO}); sdl_assert(sdl_ok)
	defer sdl.Quit()

	// TODO: ADD .SPIRV WHEN TRYING TO WOKR WITH VULKAN
	shader_formats: sdl.GPUShaderFormat = {.DXIL}
	device := sdl.CreateGPUDevice(shader_formats, true, nil); sdl_assert(device != nil)
	defer sdl.DestroyGPUDevice(device)

	//Shadercross setup for translating shaders
	shadercross_ok := shadercross.Init(); sdl_assert(shadercross_ok)
	defer shadercross.Quit()

	windows_flags: sdl.WindowFlags = {.RESIZABLE, .HIGH_PIXEL_DENSITY}
	window := sdl.CreateWindow("SDL Test", 1280, 720, windows_flags); sdl_assert(window != nil)
	defer sdl.DestroyWindow(window)

	ok := sdl.ClaimWindowForGPUDevice(device, window); sdl_assert(ok)
	defer sdl.ReleaseWindowFromGPUDevice(device, window)

	// Testing shaders
	vertex_shader := compile_shader_stage(shader_code, cstring("MainVS"), .VERTEX, device)
	sdl_assert(vertex_shader != nil)
	defer sdl.ReleaseGPUShader(device, vertex_shader)

	frag_shader := compile_shader_stage(shader_code, cstring("MainPS"), .FRAGMENT, device)
	sdl_assert(frag_shader != nil)
	defer sdl.ReleaseGPUShader(device, frag_shader)

	// Texture
	texture_image := sdl_image.Load("./assets/cobblestone_1.png"); sdl_assert(texture_image != nil)
	tex_image_size := u32(texture_image.w * texture_image.h * 4)
	texture := sdl.CreateGPUTexture(
		device,
		{
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = u32(texture_image.w),
			height = u32(texture_image.h),
			layer_count_or_depth = 1,
			num_levels = 1,
		},
	)

	// Generate triangle vertex data
	// 1. Describe vertex attributes and vertex buffers in the pipeline
	// 2. Create vertex data
	vertices := []Vertex {
		{{-0.5, 0.5, 0.0}, WHITE, {0, 0}}, // tl
		{{0.5, 0.5, 0.0}, WHITE, {1, 0}}, // tr
		{{-0.5, -0.5, 0.0}, WHITE, {0, 1}}, // bl
		{{0.5, -0.5, 0.0}, WHITE, {1, 1}}, // br
	}
	vertex_size := u32(len(vertices) * size_of(Vertex))

	indices := []u16{0, 1, 2, 2, 1, 3}
	index_size := u32(len(indices) * size_of(u16))

	// 3. Create vertex buffer
	vertex_buffer := sdl.CreateGPUBuffer(device, {usage = {.VERTEX}, size = vertex_size})
	index_buffer := sdl.CreateGPUBuffer(device, {usage = {.INDEX}, size = index_size})

	// 4. Upload vertex data to the vertex buffer
	// 4.1 Create transfer buffer
	transfer_buffer := sdl.CreateGPUTransferBuffer(
		device,
		{usage = .UPLOAD, size = vertex_size + index_size},
	)

	tex_transfer_buffer := sdl.CreateGPUTransferBuffer(
		device,
		{usage = .UPLOAD, size = tex_image_size},
	)

	// 4.2 Map Transfer buffer mem and copy it to the gpu
	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(device, transfer_buffer, false)
	mem.copy(transfer_mem, raw_data(vertices), int(vertex_size))
	mem.copy(transfer_mem[int(vertex_size):], raw_data(indices), int(index_size))
	sdl.UnmapGPUTransferBuffer(device, transfer_buffer)

	tex_transfer_mem := sdl.MapGPUTransferBuffer(device, tex_transfer_buffer, false)
	mem.copy(tex_transfer_mem, texture_image.pixels, int(tex_image_size))
	sdl.UnmapGPUTransferBuffer(device, tex_transfer_buffer)

	// 4.3 Begin Copy pass
	copy_cmd_buffer := sdl.AcquireGPUCommandBuffer(device)
	copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buffer)

	// 4.4 Invoke upload commands
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer_buffer, offset = 0},
		{buffer = vertex_buffer, size = vertex_size, offset = 0},
		false,
	)

	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer_buffer, offset = vertex_size},
		{buffer = index_buffer, size = index_size, offset = 0},
		false,
	)

	sdl.UploadToGPUTexture(
		copy_pass,
		{transfer_buffer = tex_transfer_buffer},
		{texture = texture, w = u32(texture_image.w), h = u32(texture_image.h), d = 1},
		false,
	)

	// 4.5 End copy pass and submit to gpu
	sdl.EndGPUCopyPass(copy_pass)
	ok = sdl.SubmitGPUCommandBuffer(copy_cmd_buffer); sdl_assert(ok)

	//4.6 Release transfer buffer
	sdl.ReleaseGPUTransferBuffer(device, transfer_buffer)
	sdl.ReleaseGPUTransferBuffer(device, tex_transfer_buffer)

	// Texture sampler
	sampler := sdl.CreateGPUSampler(device, {})

	vertex_attributes := []sdl.GPUVertexAttribute {
		{
			location    = 0, // Matches TEXCOORD0 (pos)
			buffer_slot = 0,
			format      = .FLOAT3,
			offset      = u32(offset_of(Vertex, pos)),
		},
		{
			location    = 1, // Matches TEXCOORD1 (color)
			buffer_slot = 0,
			format      = .FLOAT4,
			offset      = u32(offset_of(Vertex, color)),
		},
		{
			location    = 2, // Matches TEXCOORD2 (uv)
			buffer_slot = 0,
			format      = .FLOAT2,
			offset      = u32(offset_of(Vertex, uv)),
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
		target_info = sdl.GPUGraphicsPipelineTargetInfo {
			num_color_targets = 1,
			color_target_descriptions = &sdl.GPUColorTargetDescription {
				format = sdl.GetGPUSwapchainTextureFormat(device, window),
			},
		},
	}

	pipeline := sdl.CreateGPUGraphicsPipeline(device, pipeline_info); sdl_assert(pipeline != nil)
	defer sdl.ReleaseGPUGraphicsPipeline(device, pipeline)

	window_size: [2]i32
	ok = sdl.GetWindowSize(window, &window_size.x, &window_size.y); sdl_assert(ok)

	rotation: f32
	proj_mat := linalg.matrix4_perspective_f32(
		linalg.to_radians(f32(60)),
		f32(window_size.x) / f32(window_size.y),
		0.0001,
		1000,
	)

	running := true
	event: sdl.Event

	last_ticks := sdl.GetTicks()

	for running {
		current_ticks := sdl.GetTicks()
		delta_time := f32(current_ticks - last_ticks) / 1000
		last_ticks = current_ticks

		// Poll events
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				log.debug("Quit event received. Shutting down framework...")
				running = false
			case .KEY_DOWN:
				if event.key.key == sdl.K_ESCAPE {
					log.debug("Quit event received. Shutting down framework...")
					running = false
				}
			}
		}

		// Update game

		// Render
		// 1. Acquire command buffer
		cmd_buffer := sdl.AcquireGPUCommandBuffer(device)
		// 2. Acquire swapchain texture
		swapchain_tex: ^sdl.GPUTexture

		rotation += linalg.to_radians(f32(90)) * delta_time
		model_mat :=
			linalg.matrix4_translate_f32({0, 0, -2}) *
			linalg.matrix4_rotate_f32(rotation, {0, 1, 0})

		ubo := UniformBufferObject {
			mvp = proj_mat * model_mat,
		}

		if sdl.WaitAndAcquireGPUSwapchainTexture(cmd_buffer, window, &swapchain_tex, nil, nil) {
			// 3. Begin Render pass
			color_target := sdl.GPUColorTargetInfo {
				texture     = swapchain_tex,
				clear_color = {0.1, 0.15, 0.25, 1.0},
				load_op     = .CLEAR,
				store_op    = .STORE,
			}
			render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, nil)

			// 4. Draw something
			// Bind graphics pipeline
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
			// Bind vertex data
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = vertex_buffer}),
				1,
			)

			sdl.BindGPUIndexBuffer(render_pass, {buffer = index_buffer}, ._16BIT)

			// Bind uniform data
			sdl.PushGPUVertexUniformData(cmd_buffer, 0, &ubo, size_of(ubo))
			sdl.BindGPUFragmentSamplers(
				render_pass,
				0,
				&(sdl.GPUTextureSamplerBinding{texture = texture, sampler = sampler}),
				1,
			)

			// Draw calls
			// sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
			sdl.DrawGPUIndexedPrimitives(render_pass, u32(len(indices)), 1, 0, 0, 0)

			// 5. End Render pass
			sdl.EndGPURenderPass(render_pass)

			// 6. More render passes if needed
		}

		// 7. Submit to command buffer
		if !sdl.SubmitGPUCommandBuffer(cmd_buffer) {
			log.errorf("Failed to submit the command buffer: %s", sdl.GetError())
		}
	}

	free_all(context.temp_allocator)
}
