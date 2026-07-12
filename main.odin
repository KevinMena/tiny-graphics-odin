package game

import "core:log"
import "core:math/linalg"
import "core:strings"
import "libs/shadercross"
import sdl "vendor:sdl3"

vert_shader_code := #load("shaders/basic.vert.hlsl", string)
frag_shader_code := #load("shaders/basic.frag.hlsl", string)

UniformBufferObject :: struct {
	mvp: matrix[4, 4]f32,
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
	spirv_bytecode := shadercross.CompileSPIRVFromHLSL(vertex_info, &size)

	if spirv_bytecode == nil {
		log.panicf("Failed to compile HLSL to SPIRV: %s", sdl.GetError())
	}
	defer sdl.free(rawptr(spirv_bytecode))

	reflect := shadercross.ReflectGraphicsSPIRV(spirv_bytecode, size, prop_id)
	if reflect == nil {
		log.panicf("Failed to reflect graphics SPIRV: %s", sdl.GetError())
	}
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
	context.logger = log.create_console_logger(); defer log.destroy_console_logger(context.logger)

	if !sdl.Init({.VIDEO}) {
		log.panicf("Failed to initialize SDL: %s", sdl.GetError())
	}
	defer sdl.Quit()

	// TODO: ADD .SPIRV WHEN TRYING TO WOKR WITH VULKAN
	shader_formats: sdl.GPUShaderFormat = {.DXIL}
	device := sdl.CreateGPUDevice(shader_formats, true, nil)

	if device == nil {
		log.panicf("Failed to create GPU device: %s", sdl.GetError())
	}
	defer sdl.DestroyGPUDevice(device)

	//Shadercross setup for translating shaders
	if !shadercross.Init() {
		log.panicf("Failed to initialize Shadercross: %s", sdl.GetError())
	}
	defer shadercross.Quit()

	windows_flags: sdl.WindowFlags = {.RESIZABLE, .HIGH_PIXEL_DENSITY}
	window := sdl.CreateWindow("SDL Test", 1280, 720, windows_flags)

	if window == nil {
		log.panicf("Failed to create window: %s", sdl.GetError())
	}
	defer sdl.DestroyWindow(window)

	if !sdl.ClaimWindowForGPUDevice(device, window) {
		log.panicf("Failed to claim window: %s", sdl.GetError())
	}
	defer sdl.ReleaseWindowFromGPUDevice(device, window)

	// Testing shaders
	vertex_shader := compile_shader_stage(vert_shader_code, cstring("MainVS"), .VERTEX, device)

	if vertex_shader == nil {
		log.panicf("Failed to compile vertex shader: %s", sdl.GetError())
	}
	defer sdl.ReleaseGPUShader(device, vertex_shader)

	frag_shader := compile_shader_stage(frag_shader_code, cstring("MainPS"), .FRAGMENT, device)

	if frag_shader == nil {
		log.panicf("Failed to compile fragment shader: %s", sdl.GetError())
	}
	defer sdl.ReleaseGPUShader(device, frag_shader)

	pipeline_info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vertex_shader,
		fragment_shader = frag_shader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = nil,
			num_vertex_buffers = 0,
			vertex_attributes = nil,
			num_vertex_attributes = 0,
		},
		target_info = sdl.GPUGraphicsPipelineTargetInfo {
			num_color_targets = 1,
			color_target_descriptions = &sdl.GPUColorTargetDescription {
				format = sdl.GetGPUSwapchainTextureFormat(device, window),
			},
		},
	}

	pipeline := sdl.CreateGPUGraphicsPipeline(device, pipeline_info)

	if pipeline == nil {
		log.panicf("Failed to create graphics pipeline: %s", sdl.GetError())
	}
	defer sdl.ReleaseGPUGraphicsPipeline(device, pipeline)

	window_size: [2]i32
	if !sdl.GetWindowSize(window, &window_size.x, &window_size.y) {
		log.panicf("Failed to get window size: %s", sdl.GetError())
	}

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
			linalg.matrix4_translate_f32({0, 0, -5}) *
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
			// Bind uniform data
			sdl.PushGPUVertexUniformData(cmd_buffer, 0, &ubo, size_of(ubo))
			// Draw calls
			sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)

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
