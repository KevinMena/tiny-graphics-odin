package graphics

import "core:strings"
import "libs/shadercross"
import sdl "vendor:sdl3"

VertexUniform :: struct {
	mvp: matrix[4, 4]f32,
}

FragmentUniform :: struct {
	color: Vector4,
}

shader_code := #load("assets/shaders/basic.hlsl", string)

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
