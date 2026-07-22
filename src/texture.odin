package graphics

import "core:log"
import "core:path/filepath"
import "core:strings"
import sdl "vendor:sdl3"
import sdl_image "vendor:sdl3/image"

TEXTURES_PATH :: "assets/textures"

load_default_textures :: proc() {
	// For now just load one thing, but we might need to iterate
	// over all the textures in the directory
	load_texture("default/white_default.png")
}

load_texture :: proc(tex_file_name: string) -> int {

	if t_id, t_ok := d.loaded_textures_id[tex_file_name]; t_ok {
		return t_id
	}

	texture_path, _ := filepath.join({TEXTURES_PATH, tex_file_name}, context.temp_allocator)
	c_texture_path := strings.clone_to_cstring(texture_path, context.temp_allocator)

	texture_image := sdl_image.Load(c_texture_path)

	if texture_image == nil {
		log.warnf("SDL Warning: %s", sdl.GetError())
		return 0
	}

	texture_id := len(d.loaded_textures)
	d.loaded_textures[texture_id] = texture_image
	d.loaded_textures_id[tex_file_name] = texture_id

	free_all(context.temp_allocator)

	return texture_id
}

load_texture_raw_data :: proc(name: cstring, data_ptr: [^]u8, start: uint, size: uint) -> int {
	name_string := strings.clone_from_cstring(name, context.temp_allocator)

	if t, t_ok := d.loaded_textures_id[name_string]; t_ok {
		return t
	}

	stream := sdl.IOFromConstMem(&data_ptr[start], size)

	texture_id := len(d.loaded_textures)
	d.loaded_textures[texture_id] = sdl_image.Load_IO(stream, true)
	d.loaded_textures_id[name_string] = texture_id

	free_all(context.temp_allocator)

	return texture_id
}

get_texture :: proc(id: int) -> ^sdl.Surface {
	if t, t_ok := d.loaded_textures[id]; t_ok {
		return t
	}

	log.warnf("Framework Warning: Texture not found. Returning default texture")
	return d.loaded_textures[0]
}

get_gpu_texture :: proc(id: int) -> ^sdl.GPUTexture {
	if t, t_ok := d.loaded_textures_gpu[id]; t_ok {
		return t
	}

	log.warnf("Framework Warning: Texture not found. Returning default texture")
	return d.loaded_textures_gpu[0]
}

load_default_material :: proc() -> Material {
	return Material{texture_id = 0, color = WHITE}
}
