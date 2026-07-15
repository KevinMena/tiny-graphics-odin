package graphics

import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "vendor:cgltf"
import sdl "vendor:sdl3"
import sdl_image "vendor:sdl3/image"

loaded_textures: map[int]^sdl.Surface
loaded_textures_id: map[string]int

gltf_assert :: proc(ok: bool, message: string) {
	if !ok do log.panicf(message)
}

get_world_matrix :: proc(node: ^cgltf.node) -> linalg.Matrix4f32 {
	world_matrix := linalg.MATRIX4F32_IDENTITY

	if node.has_matrix {
		world_transform: [^]f32
		cgltf.node_transform_world(node, world_transform)

		world_matrix = linalg.Matrix4f32 {
			world_transform[0],
			world_transform[4],
			world_transform[8],
			world_transform[12],
			world_transform[1],
			world_transform[5],
			world_transform[9],
			world_transform[13],
			world_transform[2],
			world_transform[6],
			world_transform[10],
			world_transform[14],
			world_transform[3],
			world_transform[7],
			world_transform[11],
			world_transform[15],
		}
	} else {
		t := linalg.MATRIX4F32_IDENTITY
		if node.has_translation {
			t = linalg.matrix4_translate_f32(node.translation)
		}

		r := linalg.MATRIX4F32_IDENTITY
		if node.has_rotation {
			q := quaternion(
				w = node.rotation[0],
				x = node.rotation[1],
				y = node.rotation[2],
				z = node.rotation[3],
			)
			r = linalg.matrix4_from_quaternion_f32(q)
		}

		s := linalg.MATRIX4F32_IDENTITY
		if node.has_scale {
			s = linalg.matrix4_scale_f32(node.scale)
		}

		world_matrix = t * r * s
	}

	return world_matrix
}

load_model :: proc(file_path: string) -> (model: Model) {
	c_file_path := strings.clone_to_cstring(file_path, context.temp_allocator)

	// 1. Parse the JSON structure
	options := cgltf.options{}
	data, parse_result := cgltf.parse_file(
		options,
		c_file_path,
	); gltf_assert(parse_result == .success, "Framework Error: Failed to parse glTF file.")
	defer cgltf.free(data)

	log.debugf("Meshes count: %i", len(data.meshes))
	log.debugf("Buffers count: %i", len(data.buffers))
	log.debugf("Images count: %i", len(data.images))
	log.debugf("Textures count: %i", len(data.textures))
	log.debugf("Materials count: %i", len(data.materials))

	// 2. Load the binary data (.bin) into memory
	buffer_result := cgltf.load_buffers(
		options,
		data,
		c_file_path,
	); gltf_assert(buffer_result == .success, "Framework Error: Failed to load glTF buffers.")

	gltf_assert(
		len(data.meshes) > 0 && len(data.meshes[0].primitives) > 0,
		"Framework Error: No meshes found in glTF file.",
	)

	// Determine total number of meshes needed from the node hierarchy
	primitives_count: int
	for i in 0 ..< len(data.nodes) {
		node := data.nodes[i]
		mesh := node.mesh

		if mesh == nil do continue

		// NOTE: Only support primitives defined by triangles
		for p in 0 ..< len(mesh.primitives) {
			if mesh.primitives[p].type == .triangles {
				primitives_count += 1
			}
		}
	}

	log.debugf("Primitives (triangles only) count based on hierarchy : %i", primitives_count)

	model.meshes = make([]Mesh, primitives_count)

	material_count := len(data.materials) + 1
	model.mesh_materials = make([]int, primitives_count)
	model.materials = make([]Material, material_count)
	model.materials[0] = load_default_material()

	j := 1
	for i in 0 ..< len(data.materials) {
		model.materials[j] = load_default_material()

		if data.materials[i].has_pbr_metallic_roughness {
			if data.materials[i].pbr_metallic_roughness.base_color_texture.texture != nil {
				img := data.materials[i].pbr_metallic_roughness.base_color_texture.texture.image_

				if img.uri != nil {
					uri_str := string(img.uri)
					base_dir := filepath.dir(file_path)
					full_path, err := filepath.join({base_dir, uri_str}, context.temp_allocator)

					c_path := strings.clone_to_cstring(full_path, context.temp_allocator)
					texture_image := sdl_image.Load(c_path)

					texture_id := load_texture(full_path)
					model.materials[j].texture_id = texture_id
				} else if img.buffer_view != nil {
					model.materials[j].texture_id = load_texture_raw_data(
						img.name,
						img.buffer_view,
					)
				}
			}
		}
		model.materials[j].color = data.materials[i].pbr_metallic_roughness.base_color_factor

		j += 1
	}

	mesh_index: int
	for i in 0 ..< len(data.nodes) {
		node := data.nodes[i]
		mesh := node.mesh

		if mesh == nil do continue

		world_matrix := get_world_matrix(&node)

		// Normal matrix (Transpose of the Inverse)
		world_matrix_normals := linalg.transpose(linalg.inverse(world_matrix))

		for p in 0 ..< len(mesh.primitives) {
			primitive := mesh.primitives[p]

			// NOTE: Only support primitives defined by triangles
			if primitive.type != .triangles do continue

			positions: []Vector3
			uvs: []Vector2
			colors: []Vector4

			// 3. Extract vertices data
			for a in 0 ..< len(primitive.attributes) {
				attribute := primitive.attributes[a]
				accessor := attribute.data

				#partial switch attribute.type {
				case .position:
					if positions != nil do log.warnf("[%s] Vertices attribute data already loaded", file_path)
					else {
						positions = make([]Vector3, accessor.count)
						for v in 0 ..< accessor.count {
							val: Vector3
							if cgltf.accessor_read_float(accessor, v, &val[0], 3) {
								positions[v] = (world_matrix * [4]f32{val[0], val[1], val[2], 1.0}).xyz
							}
						}
					}
				case .texcoord:
					if uvs != nil do log.warnf("[%s] Uvs attribute data already loaded", file_path)
					else {
						uvs = make([]Vector2, accessor.count)
						for v in 0 ..< accessor.count {
							val: Vector2
							if cgltf.accessor_read_float(accessor, v, &val[0], 2) {
								uvs[v] = val
							}
						}
					}
				case .color:
					if colors != nil do log.warnf("[%s] Colors attribute data already loaded", file_path)
					else {
						colors = make([]Vector4, accessor.count)
						for v in 0 ..< accessor.count {
							val: Vector4
							if cgltf.accessor_read_float(accessor, v, &val[0], 4) {
								colors[v] = val
							}
						}
					}
				}
			}

			// If the GLTF doesn't have any information about the vertex colors, we assign WHITE
			if colors == nil {
				vertex_count := len(positions)
				colors = make([]Vector4, vertex_count)

				for i in 0 ..< vertex_count {
					colors[i] = {1.0, 1.0, 1.0, 1.0}
				}
			}

			// Assign vertex data to the mesh
			model.meshes[mesh_index].vertices = make([]Vertex, len(positions))

			for v in 0 ..< len(positions) {
				model.meshes[mesh_index].vertices[v] = Vertex {
					pos   = positions[v],
					uv    = uvs[v],
					color = colors[v],
				}
			}

			// 4. Extract indices
			if primitive.indices != nil && primitive.indices.buffer_view != nil {
				accesor := primitive.indices

				if model.meshes[mesh_index].indices != nil do log.warnf("[%s] Indices attribute data already loaded", file_path)
				else {
					model.meshes[mesh_index].indices = make([]u32, accesor.count)
					for i in 0 ..< accesor.count {
						val: u32
						if cgltf.accessor_read_uint(accesor, i, &val, 1) {
							model.meshes[mesh_index].indices[i] = val
						}
					}
				}
			}

			for m in 0 ..< len(data.materials) {
				if &data.materials[m] == primitive.material {
					model.mesh_materials[mesh_index] = m + 1
					break
				}
			}

			mesh_index += 1
		}
	}

	free_all(context.temp_allocator)

	return
}

load_model_with_texture :: proc(file_path: string, texture_path: string) -> (model: Model) {
	model = load_model(file_path)

	texture_id := load_texture(texture_path)

	// Insert texture to the model
	for i in 0 ..< len(model.meshes) {
		material_index := model.mesh_materials[i]
		model.materials[material_index].texture_id = texture_id
	}

	free_all(context.temp_allocator)

	return
}

load_default_material :: proc() -> Material {
	return Material{texture_id = 0, color = WHITE}
}

load_default_textures :: proc() {
	// For now just load one thing, but we might need to iterate
	// over all the textures in the directory
	load_texture("./assets/defaults/white_default.png")
}

load_texture :: proc(texture_path: string) -> int {

	if t_id, t_ok := loaded_textures_id[texture_path]; t_ok {
		return t_id
	}

	c_texture_path := strings.clone_to_cstring(texture_path, context.temp_allocator)

	texture_image := sdl_image.Load(c_texture_path)

	if texture_image == nil {
		log.warnf("SDL Warning: %s", sdl.GetError())
		return 0
	}

	texture_id := len(loaded_textures)
	loaded_textures[texture_id] = texture_image
	loaded_textures_id[texture_path] = texture_id

	free_all(context.temp_allocator)

	return texture_id
}

load_texture_raw_data :: proc(name: cstring, buffer_view: ^cgltf.buffer_view) -> int {
	name_string := strings.clone_from_cstring(name, context.temp_allocator)

	if t, t_ok := loaded_textures_id[name_string]; t_ok {
		return t
	}

	data_ptr := cast([^]u8)buffer_view.buffer.data
	start := buffer_view.offset

	stream := sdl.IOFromConstMem(&data_ptr[start], uint(buffer_view.size))

	texture_id := len(loaded_textures)
	loaded_textures[texture_id] = sdl_image.Load_IO(stream, true)
	loaded_textures_id[name_string] = texture_id

	free_all(context.temp_allocator)

	return texture_id
}

get_texture :: proc(id: int) -> ^sdl.Surface {
	if t, t_ok := loaded_textures[id]; t_ok {
		return t
	}

	log.warnf("Framework Warning: Texture not found. Returning default texture")
	return loaded_textures[0]
}
