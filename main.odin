package graphics

import "core:log"
import "core:math/linalg"
import "core:strings"
import "libs/shadercross"
import sdl "vendor:sdl3"

shader_code := #load("assets/shaders/basic.hlsl", string)

VertexUniform :: struct {
	mvp: matrix[4, 4]f32,
}

FragmentUniform :: struct {
	color: Vector4,
}

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32

WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}

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

	window_size: [2]i32
	ok = sdl.GetWindowSize(window, &window_size.x, &window_size.y); sdl_assert(ok)

	// Testing shaders
	vertex_shader := compile_shader_stage(shader_code, cstring("MainVS"), .VERTEX, device)
	sdl_assert(vertex_shader != nil)
	defer sdl.ReleaseGPUShader(device, vertex_shader)

	frag_shader := compile_shader_stage(shader_code, cstring("MainPS"), .FRAGMENT, device)
	sdl_assert(frag_shader != nil)
	defer sdl.ReleaseGPUShader(device, frag_shader)

	// Load default textures
	load_default_textures()

	depth_tex_props := sdl.CreateProperties()
	defer sdl.DestroyProperties(depth_tex_props)

	sdl.SetFloatProperty(depth_tex_props, sdl.PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT, 1.0)

	DEPTH_TEXTURE_FORMAT :: sdl.GPUTextureFormat.D32_FLOAT
	depth_texture := sdl.CreateGPUTexture(
		device,
		{
			format = DEPTH_TEXTURE_FORMAT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(window_size.x),
			height = u32(window_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
			props = depth_tex_props,
		},
	)
	defer sdl.ReleaseGPUTexture(device, depth_texture)

	// Load Model
	// model := load_model("./assets/animal-elephant.glb")
	// model := load_model_with_texture("./assets/animal-elephant.glb", "./assets/colormap.png")
	model := load_model("./assets/Mannequin_F.glb")

	gpu_model := upload_model(&model, device)
	defer free_gpu_model(&gpu_model, device)

	// Texture sampler
	sampler := sdl.CreateGPUSampler(device, {})
	defer sdl.ReleaseGPUSampler(device, sampler)

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
		target_info = sdl.GPUGraphicsPipelineTargetInfo {
			num_color_targets = 1,
			color_target_descriptions = &sdl.GPUColorTargetDescription {
				format = sdl.GetGPUSwapchainTextureFormat(device, window),
			},
			has_depth_stencil_target = true,
			depth_stencil_format = DEPTH_TEXTURE_FORMAT,
		},
	}

	pipeline := sdl.CreateGPUGraphicsPipeline(device, pipeline_info); sdl_assert(pipeline != nil)
	defer sdl.ReleaseGPUGraphicsPipeline(device, pipeline)

	rotation: f32
	proj_mat := linalg.matrix4_perspective_f32(
		linalg.to_radians(f32(60)),
		f32(window_size.x) / f32(window_size.y),
		0.01,
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
			linalg.matrix4_translate_f32({0, -1, -3}) *
			linalg.matrix4_rotate_f32(rotation, {0, 1, 0})

		ubo := VertexUniform {
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
			depth_target_info := sdl.GPUDepthStencilTargetInfo {
				texture          = depth_texture,
				clear_depth      = 1.0,
				load_op          = .CLEAR,
				store_op         = .DONT_CARE,
				stencil_load_op  = .DONT_CARE,
				stencil_store_op = .DONT_CARE,
			}
			render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, &depth_target_info)

			// 4. Draw something
			// Bind graphics pipeline
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)

			// Bind vertex data
			sdl.BindGPUVertexBuffers(
				render_pass,
				0,
				&(sdl.GPUBufferBinding{buffer = gpu_model.vertex_buffer}),
				1,
			)
			sdl.BindGPUIndexBuffer(render_pass, {buffer = gpu_model.index_buffer}, ._32BIT)

			for i in 0 ..< len(model.meshes) {
				gpu_mesh := gpu_model.meshes[i]

				// Fragment uniform data
				material_id := model.mesh_materials[i]
				ufd := FragmentUniform {
					color = model.materials[material_id].color,
				}

				// Bind uniform data
				sdl.PushGPUVertexUniformData(cmd_buffer, 0, &ubo, size_of(ubo))
				sdl.PushGPUFragmentUniformData(cmd_buffer, 0, &ufd, size_of(ufd))
				sdl.BindGPUFragmentSamplers(
					render_pass,
					0,
					&(sdl.GPUTextureSamplerBinding{texture = gpu_mesh.texture, sampler = sampler}),
					1,
				)

				// Draw calls
				sdl.DrawGPUIndexedPrimitives(
					render_pass,
					gpu_mesh.index_count,
					1,
					gpu_mesh.first_index,
					gpu_mesh.vertex_offset,
					0,
				)
			}

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
