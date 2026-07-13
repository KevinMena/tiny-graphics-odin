package graphics

import "core:log"
import "core:math/linalg"
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

load_model :: proc(filepath: string) -> (vertices: [dynamic]Vertex, indices: [dynamic]u32) {
	path := strings.clone_to_cstring(filepath, context.temp_allocator)

	// 1. Parse the JSON structure
	options := cgltf.options{}
	data, parse_result := cgltf.parse_file(
		options,
		path,
	); gltf_assert(parse_result == .success, "Failed to parse glTF file.")
	defer cgltf.free(data)

	log.debugf("Meshes count: %i", len(data.meshes))
	log.debugf("Buffers count: %i", len(data.buffers))
	log.debugf("Images count: %i", len(data.images))
	log.debugf("Textures count: %i", len(data.textures))

	// 2. Load the binary data (.bin) into memory
	buffer_result := cgltf.load_buffers(
		options,
		data,
		path,
	); gltf_assert(buffer_result == .success, "Failed to load glTF buffers.")

	gltf_assert(
		len(data.meshes) > 0 && len(data.meshes[0].primitives) > 0,
		"No meshes found in glTF file.",
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

	vertices = make([dynamic]Vertex)
	indices = make([dynamic]u32)

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

			vertex_count: uint = 0
			for i in 0 ..< len(primitive.attributes) {
				if primitive.attributes[i].type == .position {
					vertex_count = primitive.attributes[i].data.count
					break
				}
			}

			base_vertex := u32(len(vertices))
			resize(&vertices, len(vertices) + int(vertex_count))

			// Pre-fill colors with White (in case the model doesn't have vertex colors exported)
			for v in int(base_vertex) ..< len(vertices) do vertices[v].color = {1.0, 1.0, 1.0, 1.0}

			// 3. Extract vertices data
			for a in 0 ..< len(primitive.attributes) {
				attributes := primitive.attributes[a]
				accessor := attributes.data

				#partial switch attributes.type {
				case .position:
					// if vertices[index].pos != nil do log.warnf("[%s] Vertices attribute data already loaded", filepath)
					for v in 0 ..< vertex_count {
						val: Vector3
						if cgltf.accessor_read_float(accessor, v, &val[0], 3) {
							vertices[uint(base_vertex) + v].pos =
								(world_matrix * [4]f32{val[0], val[1], val[2], 1.0}).xyz
						}
					}
				case .texcoord:
					for v in 0 ..< vertex_count {
						val: Vector2
						if cgltf.accessor_read_float(accessor, v, &val[0], 2) {
							vertices[uint(base_vertex) + v].uv = val
						}
					}
				case .color:
					for v in 0 ..< vertex_count {
						val: Vector4
						if cgltf.accessor_read_float(accessor, v, &val[0], 4) {
							vertices[uint(base_vertex) + v].color = val
						}
					}
				}
			}

			// 4. Extract indices
			if primitive.indices != nil && primitive.indices.buffer_view != nil {
				accesor := primitive.indices

				for i in 0 ..< accesor.count {
					val: u32
					if cgltf.accessor_read_uint(accesor, i, &val, 1) {
						append(&indices, val + base_vertex)
					}
				}
			} else {
				// Fallback: Generate sequential indices if none exist
				for i in 0 ..< vertex_count {
					append(&indices, base_vertex + u32(i))
				}
			}
		}
	}

	free_all(context.temp_allocator)

	return
}
