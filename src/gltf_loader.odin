package graphics

import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import "vendor:cgltf"


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

parse_model :: proc(file_name: string) -> (model: Model) {
	file_path, _ := filepath.join({MODELS_PATH, file_name}, context.temp_allocator)
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

					tex_file_name := filepath.base(uri_str)
					texture_id := load_texture(tex_file_name)
					model.materials[j].texture_id = texture_id
				} else if img.buffer_view != nil {
					data_ptr := cast([^]u8)img.buffer_view.buffer.data
					start := img.buffer_view.offset
					size := uint(img.buffer_view.size)

					model.materials[j].texture_id = load_texture_raw_data(
						img.name,
						data_ptr,
						start,
						size,
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
					if positions != nil do log.warnf("[%s] Vertices attribute data already loaded", file_name)
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
					if uvs != nil do log.warnf("[%s] Uvs attribute data already loaded", file_name)
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
					if colors != nil do log.warnf("[%s] Colors attribute data already loaded", file_name)
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

				if model.meshes[mesh_index].indices != nil do log.warnf("[%s] Indices attribute data already loaded", file_name)
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

parse_model_with_texture :: proc(file_name: string, texture_name: string) -> (model: Model) {
	model = parse_model(file_name)

	texture_id := load_texture(texture_name)

	// Insert texture to the model
	for i in 0 ..< len(model.meshes) {
		material_index := model.mesh_materials[i]
		model.materials[material_index].texture_id = texture_id
	}

	free_all(context.temp_allocator)

	return
}
