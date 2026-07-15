package graphics

import "core:mem"
import sdl "vendor:sdl3"

Vertex :: struct {
	pos:   Vector3,
	uv:    Vector2,
	color: Vector4,
}

Mesh :: struct {
	vertices: []Vertex,
	indices:  []u32,
}

Material :: struct {
	texture_id: int,
	color:      Vector4,
}

Model :: struct {
	meshes:         []Mesh,
	materials:      []Material,
	mesh_materials: []int,
}

GPUTextureData :: struct {
	texture: ^sdl.GPUTexture,
	surface: ^sdl.Surface,
}

GPUMesh :: struct {
	index_count:   u32,
	first_index:   u32,
	vertex_offset: i32,
	texture_idx:   int,
}

GPUModel :: struct {
	vertex_buffer: ^sdl.GPUBuffer,
	index_buffer:  ^sdl.GPUBuffer,
	meshes:        []GPUMesh,
	textures_data: []GPUTextureData,
}

free_gpu_model :: proc(gpu_model: ^GPUModel, device: ^sdl.GPUDevice) {
	sdl.ReleaseGPUBuffer(device, gpu_model.vertex_buffer)
	sdl.ReleaseGPUBuffer(device, gpu_model.index_buffer)

	for data in gpu_model.textures_data {
		sdl.ReleaseGPUTexture(device, data.texture)
	}
}

upload_model :: proc(model: ^Model, device: ^sdl.GPUDevice) -> (gpu_model: GPUModel) {
	// Generate triangle vertex data
	// 1. Describe vertex attributes and vertex buffers in the pipeline
	// 2. Create vertex data
	total_vertices: u32 = 0
	total_indices: u32 = 0

	for mesh in model.meshes {
		total_vertices += u32(len(mesh.vertices))
		total_indices += u32(len(mesh.indices))
	}

	vertex_buffer_size := total_vertices * u32(size_of(Vertex))
	index_buffer_size := total_indices * u32(size_of(u32))

	// 3. Create data buffers buffer
	gpu_model.vertex_buffer = sdl.CreateGPUBuffer(
		device,
		{usage = {.VERTEX}, size = vertex_buffer_size},
	)
	gpu_model.index_buffer = sdl.CreateGPUBuffer(
		device,
		{usage = {.INDEX}, size = index_buffer_size},
	)
	gpu_model.meshes = make([]GPUMesh, len(model.meshes))

	// 4. Upload vertex data to the vertex buffer
	// 4.1 Create transfer buffer
	transfer_buffer := sdl.CreateGPUTransferBuffer(
		device,
		{usage = .UPLOAD, size = vertex_buffer_size + index_buffer_size},
	)

	transfer_mem := transmute([^]byte)sdl.MapGPUTransferBuffer(device, transfer_buffer, false)

	current_vertex_offset: u32 = 0
	current_index_offset: u32 = 0

	// We need to track texture transfer buffers so we can release them AT THE END
	tex_transfers := make([dynamic]^sdl.GPUTransferBuffer)

	created_textures := make(map[int]^sdl.GPUTexture)
	defer delete(created_textures)
	unique_textures := make([dynamic]GPUTextureData)
	defer delete(unique_textures)
	texture_len := -1

	// 4.2 Map Transfer buffer mem and copy it to the gpu
	for i in 0 ..< len(model.meshes) {
		mesh := model.meshes[i]
		vertex_count := u32(len(mesh.vertices))
		index_count := u32(len(mesh.indices))

		// Copy Vertices into the mapped memory
		vertex_offset := current_vertex_offset * u32(size_of(Vertex))
		mem.copy(
			transfer_mem[vertex_offset:],
			raw_data(mesh.vertices),
			int(vertex_count * u32(size_of(Vertex))),
		)

		// Copy Indices
		index_offset := vertex_buffer_size + (current_index_offset * u32(size_of(u32)))
		mem.copy(
			transfer_mem[index_offset:],
			raw_data(mesh.indices),
			int(index_count * u32(size_of(u32))),
		)

		// Texture
		texture_id := model.materials[model.mesh_materials[i]].texture_id
		texture_image := get_texture(texture_id)

		gpu_texture: ^sdl.GPUTexture
		if existing_tex, created := created_textures[texture_id]; created {
			gpu_texture = existing_tex
		} else {
			gpu_texture = sdl.CreateGPUTexture(
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

			created_textures[texture_id] = gpu_texture
			append(
				&unique_textures,
				GPUTextureData{texture = gpu_texture, surface = texture_image},
			)
			texture_len += 1
		}

		gpu_model.meshes[i] = GPUMesh {
			index_count   = index_count,
			first_index   = current_index_offset,
			vertex_offset = i32(current_vertex_offset),
			texture_idx   = texture_len,
		}

		current_vertex_offset += vertex_count
		current_index_offset += index_count
	}

	// Need to put the unique textures into the model
	gpu_model.textures_data = make([]GPUTextureData, len(unique_textures))
	copy(gpu_model.textures_data, unique_textures[:])

	for data in gpu_model.textures_data {
		texture_image := data.surface
		tex_size := u32(texture_image.w * texture_image.h * 4)

		tex_transfer_buffer := sdl.CreateGPUTransferBuffer(
			device,
			{usage = .UPLOAD, size = tex_size},
		)
		append(&tex_transfers, tex_transfer_buffer)

		tex_transfer_mem := sdl.MapGPUTransferBuffer(device, tex_transfer_buffer, false)
		mem.copy(tex_transfer_mem, texture_image.pixels, int(tex_size))
		sdl.UnmapGPUTransferBuffer(device, tex_transfer_buffer)
	}

	// 4.3 Begin Copy pass
	copy_cmd_buffer := sdl.AcquireGPUCommandBuffer(device)
	copy_pass := sdl.BeginGPUCopyPass(copy_cmd_buffer)

	// 4.4 Invoke upload commands
	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer_buffer, offset = 0},
		{buffer = gpu_model.vertex_buffer, size = vertex_buffer_size, offset = 0},
		false,
	)

	sdl.UploadToGPUBuffer(
		copy_pass,
		{transfer_buffer = transfer_buffer, offset = vertex_buffer_size},
		{buffer = gpu_model.index_buffer, size = index_buffer_size, offset = 0},
		false,
	)

	for i in 0 ..< len(gpu_model.textures_data) {
		data := gpu_model.textures_data[i]

		sdl.UploadToGPUTexture(
			copy_pass,
			{transfer_buffer = tex_transfers[i]},
			{texture = data.texture, w = u32(data.surface.w), h = u32(data.surface.h), d = 1},
			false,
		)
	}

	// 4.5 End copy pass and submit to gpu
	sdl.EndGPUCopyPass(copy_pass)
	ok := sdl.SubmitGPUCommandBuffer(copy_cmd_buffer); sdl_assert(ok)

	//4.6 Release transfer buffer
	sdl.ReleaseGPUTransferBuffer(device, transfer_buffer)

	for tb in tex_transfers {
		sdl.ReleaseGPUTransferBuffer(device, tb)
	}

	return
}
