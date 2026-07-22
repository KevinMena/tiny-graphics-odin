package graphics

import "base:runtime"
import "core:log"
import "core:math"
import "core:math/linalg"
import im "shared:imgui"
import im_sdl "shared:imgui/imgui_impl_sdl3"
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

CAMERA_MOVE_SPEED :: 5
MOUSE_SENSITIVITY :: 0.1
ROTATION_SPEED :: f32(90) * linalg.RAD_PER_DEG

key_down: [^]bool
mouse_delta: Vector2

proj_mat: matrix[4, 4]f32
view_mat: matrix[4, 4]f32

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

	init()

	// Load Model
	model := load_model("animal-elephant.glb")
	// model := load_model_with_texture("animal-elephant.glb", "colormap.png")
	// model := load_model("Mannequin_F.glb")

	defer free_model(&model, d.device)

	rotation_angle: Quaternion = 1
	rotate := true

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

		ui_input_mode := !sdl.GetWindowRelativeMouseMode(d.window)

		// Poll events
		for sdl.PollEvent(&event) {
			if ui_input_mode do im_sdl.ProcessEvent(&event)

			#partial switch event.type {
			case .QUIT:
				log.debug("Quit event received. Shutting down framework...")
				running = false
			case .KEY_DOWN:
				if event.key.key == sdl.K_ESCAPE {
					log.debug("Quit event received. Shutting down framework...")
					running = false
				}
			case .MOUSE_BUTTON_DOWN:
				if event.button.button == 2 {
					log.debugf("MOUSE BUTTON PRESSED")
					ui_input_mode = !ui_input_mode
					_ = sdl.SetWindowRelativeMouseMode(d.window, !ui_input_mode)
				}
			}
		}

		if !ui_input_mode {
			key_down = sdl.GetKeyboardState(nil)
			_ = sdl.GetRelativeMouseState(&mouse_delta.x, &mouse_delta.y)
		}

		new_frame_imgui()

		if im.Begin("Inspector") {
			im.ColorEdit3("Clear Color", transmute(^[3]f32)&d.clear_color)
			im.Checkbox("Rotate", &rotate)
		}
		im.End()

		// Update game
		update_camera(&camera, &look, delta_time)
		if rotate do rotation_angle *= linalg.quaternion_from_euler_angle_y_f32(ROTATION_SPEED * delta_time)

		// Render
		if ctx, ok := begin_render(); ok {

			// 4. Draw something
			proj_mat = linalg.matrix4_perspective_f32(
				linalg.to_radians(f32(60)),
				f32(d.window_size.x) / f32(d.window_size.y),
				0.01,
				1000,
			)
			view_mat = linalg.matrix4_look_at_f32(camera.position, camera.target, {0, 1, 0})

			draw_model(
				model,
				ctx.render_pass,
				ctx.cmd_buffer,
				d.sampler,
				{0, 0, 0},
				rotation_angle,
			)

			end_render(ctx)
		}
	}
}
