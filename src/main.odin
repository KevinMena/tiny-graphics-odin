package graphics

import "../libs/shadercross"
import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import sdl "vendor:sdl3"

Camera :: struct {
	position: Vector3,
	target:   Vector3,
}

Look :: struct {
	yaw:   f32,
	pitch: f32,
	roll:  f32,
}

Vector2 :: [2]f32
Vector3 :: [3]f32
Vector4 :: [4]f32

WHITE :: [4]f32{1.0, 1.0, 1.0, 1.0}

CAMERA_MOVE_SPEED :: 5
MOUSE_SENSITIVITY :: 0.1

key_down: [^]bool
mouse_delta: Vector2

proj_mat: matrix[4, 4]f32
view_mat: matrix[4, 4]f32

device: ^sdl.GPUDevice
window: ^sdl.Window
window_size: [2]i32
depth_texture: ^sdl.GPUTexture
depth_texture_format: sdl.GPUTextureFormat

// TODO: Make these a properties of the materials instead, not a global one
pipeline: ^sdl.GPUGraphicsPipeline
sampler: ^sdl.GPUSampler

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

free_sdl :: proc() {
	shadercross.Quit()
	sdl.ReleaseGPUTexture(device, depth_texture)
	sdl.ReleaseWindowFromGPUDevice(device, window)
	sdl.DestroyWindow(window)
	sdl.DestroyGPUDevice(device)
	sdl.Quit()
}

@(deferred_none = free_sdl)
init_sdl :: proc() {
	@(static) sdl_log_context: runtime.Context
	sdl_log_context = context
	sdl_log_context.logger.options -= {.Short_File_Path, .Line, .Procedure}
	sdl.SetLogPriorities(.VERBOSE)
	sdl.SetLogOutputFunction(sdl_log, &sdl_log_context)

	sdl_ok := sdl.Init({.VIDEO}); sdl_assert(sdl_ok)

	// TODO: ADD .SPIRV WHEN TRYING TO WOKR WITH VULKAN
	shader_formats: sdl.GPUShaderFormat = {.DXIL}
	device = sdl.CreateGPUDevice(shader_formats, true, nil); sdl_assert(device != nil)

	//Shadercross setup for translating shaders
	shadercross_ok := shadercross.Init(); sdl_assert(shadercross_ok)

	windows_flags: sdl.WindowFlags = {.HIGH_PIXEL_DENSITY}
	window = sdl.CreateWindow("SDL Test", 1280, 720, windows_flags); sdl_assert(window != nil)

	ok := sdl.ClaimWindowForGPUDevice(device, window); sdl_assert(ok)

	ok = sdl.GetWindowSize(window, &window_size.x, &window_size.y); sdl_assert(ok)

	depth_tex_props := sdl.CreateProperties()
	defer sdl.DestroyProperties(depth_tex_props)

	sdl.SetFloatProperty(depth_tex_props, sdl.PROP_GPU_TEXTURE_CREATE_D3D12_CLEAR_DEPTH_FLOAT, 1.0)

	depth_texture_format = get_depth_format()
	depth_texture = sdl.CreateGPUTexture(
		device,
		{
			format = depth_texture_format,
			usage = {.DEPTH_STENCIL_TARGET},
			width = u32(window_size.x),
			height = u32(window_size.y),
			layer_count_or_depth = 1,
			num_levels = 1,
			props = depth_tex_props,
		},
	)

	_ = sdl.SetWindowRelativeMouseMode(window, true)
}

get_depth_format :: proc() -> sdl.GPUTextureFormat {
	formats := [3]sdl.GPUTextureFormat{.D16_UNORM, .D24_UNORM, .D32_FLOAT}

	for format in formats {
		if sdl.GPUTextureSupportsFormat(device, format, .D2, {.DEPTH_STENCIL_TARGET}) {
			return format
		}
	}

	return .INVALID
}

free_pipeline :: proc() {
	sdl.ReleaseGPUSampler(device, sampler)
	sdl.ReleaseGPUGraphicsPipeline(device, pipeline)
}

@(deferred_none = free_pipeline)
setup_pipeline :: proc() {
	vertex_shader := compile_shader_stage(shader_code, cstring("MainVS"), .VERTEX, device)
	sdl_assert(vertex_shader != nil)
	defer sdl.ReleaseGPUShader(device, vertex_shader)

	frag_shader := compile_shader_stage(shader_code, cstring("MainPS"), .FRAGMENT, device)
	sdl_assert(frag_shader != nil)
	defer sdl.ReleaseGPUShader(device, frag_shader)

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
				format = sdl.GetGPUSwapchainTextureFormat(device, window),
			},
			has_depth_stencil_target = true,
			depth_stencil_format = depth_texture_format,
		},
	}

	pipeline = sdl.CreateGPUGraphicsPipeline(device, pipeline_info); sdl_assert(pipeline != nil)

	// Texture sampler
	sampler = sdl.CreateGPUSampler(device, {})
}

update_camera :: proc(camera: ^Camera, look: ^Look, dt: f32) {
	move_input: Vector2
	if key_down[sdl.Scancode.W] do move_input.y = 1
	else if key_down[sdl.Scancode.S] do move_input.y = -1
	if key_down[sdl.Scancode.A] do move_input.x = -1
	else if key_down[sdl.Scancode.D] do move_input.x = 1

	// Camera look at
	look_input := mouse_delta * MOUSE_SENSITIVITY

	look.yaw = math.wrap(look.yaw - look_input.x, 360)
	look.pitch = math.clamp(look.pitch - look_input.y, -89, 89)
	look.roll = 0

	look_mat := linalg.matrix3_from_yaw_pitch_roll_f32(
		linalg.to_radians(look.yaw),
		linalg.to_radians(look.pitch),
		look.roll,
	)

	forward := look_mat * Vector3{0, 0, -1}
	right := look_mat * Vector3{1, 0, 0}
	move_dir := forward * move_input.y + right * move_input.x
	move_dir.y = 0

	delta := linalg.normalize0(move_dir) * CAMERA_MOVE_SPEED * dt

	camera.position += delta
	camera.target = camera.position + forward
}

main :: proc() {
	context.logger = log.create_console_logger()

	init_sdl()

	// Load default textures
	load_default_textures()

	// Load Model
	model := load_model("animal-elephant.glb")
	// model := load_model_with_texture("animal-elephant.glb", "colormap.png")
	// model := load_model("Mannequin_F.glb")

	gpu_model := upload_model(&model, device)
	defer free_gpu_model(&gpu_model, device)

	// Create the graphics pipeline
	setup_pipeline()

	rotation_angle: f32
	proj_mat = linalg.matrix4_perspective_f32(
		linalg.to_radians(f32(60)),
		f32(window_size.x) / f32(window_size.y),
		0.01,
		1000,
	)

	camera := Camera {
		position = {0, 1, 3},
		target   = {0, 1, 0},
	}

	look: Look

	running := true
	event: sdl.Event

	key_down = sdl.GetKeyboardState(nil)
	last_ticks := sdl.GetTicks()

	for running {
		free_all(context.temp_allocator)
		mouse_delta = {}

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

		_ = sdl.GetRelativeMouseState(&mouse_delta.x, &mouse_delta.y)

		// Update game
		update_camera(&camera, &look, delta_time)
		rotation_angle += linalg.to_radians(f32(90)) * delta_time

		// Render
		// 1. Acquire command buffer
		cmd_buffer := sdl.AcquireGPUCommandBuffer(device)
		// 2. Acquire swapchain texture
		swapchain_tex: ^sdl.GPUTexture

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
			view_mat = linalg.matrix4_look_at_f32(camera.position, camera.target, {0, 1, 0})

			// Bind graphics pipeline
			sdl.BindGPUGraphicsPipeline(render_pass, pipeline)

			draw_model(
				gpu_model,
				render_pass,
				cmd_buffer,
				sampler,
				{0, 0, 0},
				{0, rotation_angle, 0},
			)

			// 5. End Render pass
			sdl.EndGPURenderPass(render_pass)

			// 6. More render passes if needed
		}

		// 7. Submit to command buffer
		if !sdl.SubmitGPUCommandBuffer(cmd_buffer) {
			log.errorf("Failed to submit the command buffer: %s", sdl.GetError())
		}
	}
}
