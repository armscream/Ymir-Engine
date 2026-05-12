package Vulkan

// Core
import "base:builtin"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:math"
import la "core:math/linalg"
import "core:os"
import "core:strings"

// Vendor
import vk "vendor:vulkan"

// Define sentinel values for indicating invalid node
NO_MESH :: max(u32)
NO_MATERIAL :: max(u32)
NO_NAME :: max(u32)

Material_Atlas_Policy :: enum u8 {
	Auto,
	Force_Atlas,
	Force_Standalone,
}

Material_Source_Mode :: enum u8 {
	Standalone,
	Atlas,
}

Atlas_Page_File :: struct {
	name:   string,
	width:  i32,
	height: i32,
}

Atlas_Material_Mapping_File :: struct {
	material:    u32,
	policy:      Material_Atlas_Policy,
	source_mode: Material_Source_Mode,
	atlas_page:  i32,
	uv_offset:   [2]f32,
	uv_scale:    [2]f32,
}

Level_Atlas_Manifest_File :: struct {
	enabled:  bool,
	settings: Atlas_Build_Settings_File,
	pages:    [dynamic]Atlas_Page_File,
	mappings: [dynamic]Atlas_Material_Mapping_File,
}

Atlas_Build_Settings_File :: struct {
	max_page_size: i32,
	max_pages:     i32,
	padding_px:    i32,
}

// Quaternion-based transform: more efficient for hierarchy composition
// Memory layout: position (12) + rotation (16) + scale (12) = 40 bytes (vs 64 for 4x4 matrix)
Transform :: struct {
	position: [3]f32,
	rotation: la.Quaternionf32,
	scale:    [3]f32,
}

// Create identity quaternion as a distinct type
make_identity_quat :: proc() -> la.Quaternionf32 {
	q: la.Quaternionf32
	q.w = 1
	q.x = 0
	q.y = 0
	q.z = 0
	return q
}

// Create identity transform
transform_identity :: proc() -> Transform {
	return {position = {0, 0, 0}, rotation = make_identity_quat(), scale = {1, 1, 1}}
}

// Create transform from position, rotation (quat), and scale
transform_from_pos_rot_scale :: proc(
	pos: [3]f32,
	rot: la.Quaternionf32,
	scale: [3]f32,
) -> Transform {
	return {position = pos, rotation = rot, scale = scale}
}

// Compose two transforms: parent * local (hierarchical multiplication)
// Result represents local transform in parent space
transform_compose :: proc(parent, local: Transform) -> Transform {
	// Compose rotations: parent_rot * local_rot
	composed_rot := la.quaternion_mul_quaternion(parent.rotation, local.rotation)

	// Compose scales: parent_scale * local_scale (element-wise for non-uniform scaling)
	composed_scale := parent.scale * local.scale

	// Compose positions: rotate local position by parent rotation, scale by parent scale, then add parent position
	rotated_pos := la.quaternion128_mul_vector3(parent.rotation, local.position * parent.scale)
	composed_pos := parent.position + rotated_pos

	return {position = composed_pos, rotation = composed_rot, scale = composed_scale}
}

// Convert transform to matrix4x4 for GPU/rendering
transform_to_matrix :: proc(t: Transform) -> la.Matrix4f32 {
	rot_matrix := la.matrix4_from_quaternion(t.rotation)
	scale_matrix := la.matrix4_scale(la.Vector3f32{t.scale.x, t.scale.y, t.scale.z})
	scaled_rotation := rot_matrix * scale_matrix
	trans_matrix := la.matrix4_translate(la.Vector3f32{t.position.x, t.position.y, t.position.z})
	return trans_matrix * scaled_rotation
}

// Extract position from transform
transform_get_position :: proc(t: Transform) -> [3]f32 {
	return t.position
}

// Extract scale from transform
transform_get_scale :: proc(t: Transform) -> [3]f32 {
	return t.scale
}

// Inverse of a transform (for parent->child coordinate conversions)
transform_inverse :: proc(t: Transform) -> Transform {
	inv_rot := conj(t.rotation)
	inv_scale := [3]f32{1 / t.scale.x, 1 / t.scale.y, 1 / t.scale.z}

	// Inverse position: rotate by inverse rotation, scale by inverse scale
	neg_pos := -t.position
	inv_pos := la.quaternion128_mul_vector3(inv_rot, neg_pos * inv_scale)

	return {position = inv_pos, rotation = inv_rot, scale = inv_scale}
}

// Render object that holds drawing data.
Render_Object :: struct {
	index_count:           u32,
	first_index:           u32,
	index_buffer:          vk.Buffer,
	vertex_buffer:         vk.Buffer,
	material:              u32, // Index into materials array
	uv_remap:              la.Vector4f32,
	material_source_mode:  Material_Source_Mode,
	atlas_page:            i32,
	transform:             la.Matrix4f32, // Converted from Transform to matrix for GPU
	vertex_buffer_address: vk.DeviceAddress,
}

// Define our base drawing context and renderable types.
Draw_Context :: struct {
	opaque_surfaces: [dynamic]Render_Object,
}

// Hierarchy component for scene nodes
Hierarchy :: struct {
	parent:       i32, // -1 means no parent
	first_child:  i32, // -1 means no children
	next_sibling: i32, // -1 means no next sibling
	last_sibling: i32, // -1 means no siblings, otherwise the last sibling for quick appending
	level:        i32, // Depth in the hierarchy, root = 0
}

// Scene container to store all node data in arrays
Scene :: struct {
	// Transform components (quaternion-based for better cache efficiency and composition performance)
	local_transforms:    [dynamic]Transform,
	world_transforms:    [dynamic]Transform,
	transform_dirty:     [dynamic]bool,
	subtree_dirty:       [dynamic]bool,

	// Hierarchy components
	hierarchy:           [dynamic]Hierarchy,

	// Mesh components (Node index -> Mesh index)
	mesh_for_node:       [dynamic]u32,

	// Material components (Node index -> Material index)
	material_for_node:   [dynamic]u32,

	// Optional debug components
	name_for_node:       [dynamic]u32,
	node_names:          [dynamic]string,

	// Material instances
	materials:           [dynamic]Material_Instance,
	material_uv_remap:   [dynamic]la.Vector4f32,
	material_source:     [dynamic]Material_Source_Mode,

	// Atlas GPU resources
	material_atlas_page: [dynamic]i32,
	atlas_pages:         [dynamic]Allocated_Image,
	atlas_manifest:      Level_Atlas_Manifest_File,

	// Mesh assets
	meshes:              Mesh_Asset_List,
}

// Initialize a new scene.
scene_init :: proc(scene: ^Scene, allocator := context.allocator) {
	context.allocator = allocator
	scene.local_transforms = make([dynamic]Transform)
	scene.world_transforms = make([dynamic]Transform)
	scene.transform_dirty = make([dynamic]bool)
	scene.subtree_dirty = make([dynamic]bool)
	scene.hierarchy = make([dynamic]Hierarchy)
	scene.mesh_for_node = make([dynamic]u32)
	scene.material_for_node = make([dynamic]u32)
	scene.name_for_node = make([dynamic]u32)
	scene.node_names = make([dynamic]string)
	scene.materials = make([dynamic]Material_Instance)
	scene.material_uv_remap = make([dynamic]la.Vector4f32)
	scene.material_source = make([dynamic]Material_Source_Mode)
	scene.material_atlas_page = make([dynamic]i32)
	scene.meshes = make([dynamic]Mesh_Asset)
	scene.atlas_pages = make([dynamic]Allocated_Image)
}

// Free scene resources.
scene_destroy :: proc(scene: ^Scene, allocator := context.allocator) {
	context.allocator = allocator
	for name in scene.node_names {
		delete(name)
	}
	for atlas_page in scene.atlas_pages {
		destroy_image(atlas_page)
	}
	delete(scene.local_transforms)
	delete(scene.world_transforms)
	delete(scene.transform_dirty)
	delete(scene.subtree_dirty)
	delete(scene.hierarchy)
	delete(scene.mesh_for_node)
	delete(scene.material_for_node)
	delete(scene.name_for_node)
	delete(scene.node_names)
	delete(scene.materials)
	delete(scene.material_uv_remap)
	delete(scene.material_source)
	delete(scene.material_atlas_page)
	delete(scene.atlas_pages)

	for p in scene.atlas_manifest.pages {
		delete(p.name)
	}
	delete(scene.atlas_manifest.pages)
	delete(scene.atlas_manifest.mappings)
	delete(scene.meshes)
}

// Add a new node to the scene
scene_add_node :: proc(scene: ^Scene, #any_int parent, level: i32) -> i32 {
	// Create new node ID
	node := i32(len(scene.hierarchy))

	// Add transform components with identity transforms
	append(&scene.local_transforms, transform_identity())
	append(&scene.world_transforms, transform_identity())
	append(&scene.transform_dirty, true)
	append(&scene.subtree_dirty, true)

	// Add default associations
	append(&scene.name_for_node, NO_NAME)
	append(&scene.mesh_for_node, NO_MESH)
	append(&scene.material_for_node, NO_MATERIAL)

	// Add hierarchy component
	new_hierarchy := Hierarchy {
		parent       = parent,
		first_child  = -1,
		next_sibling = -1,
		last_sibling = -1,
		level        = level,
	}
	append(&scene.hierarchy, new_hierarchy)

	// If we have a parent, update the parent's hierarchy
	if parent > -1 {
		// Get the first child of the parent
		first_child := scene.hierarchy[parent].first_child

		if first_child == -1 {
			// This is the first child, update parent
			scene.hierarchy[parent].first_child = node
			scene.hierarchy[parent].last_sibling = node
		} else {
			// Add as a sibling to the existing children
			// Get the last sibling for O(1) insertion instead of traversing
			last_sibling := scene.hierarchy[first_child].last_sibling

			if last_sibling > -1 {
				scene.hierarchy[last_sibling].next_sibling = node
			} else {
				// Legacy fallback traversal method
				dest := first_child
				for scene.hierarchy[dest].next_sibling != -1 {
					dest = scene.hierarchy[dest].next_sibling
				}
				scene.hierarchy[dest].next_sibling = node
			}

			// Update the cached last sibling for future quick additions
			scene.hierarchy[first_child].last_sibling = node
		}
	}

	return node
}

scene_mark_node_dirty :: proc(scene: ^Scene, #any_int node_index: i32) {
	if node_index < 0 || node_index >= i32(len(scene.hierarchy)) {
		return
	}

	scene.transform_dirty[node_index] = true

	n := node_index
	for n != -1 {
		scene.subtree_dirty[n] = true
		n = scene.hierarchy[n].parent
	}
}

scene_set_local_transform :: proc(scene: ^Scene, #any_int node_index: i32, transform: Transform) {
	if node_index < 0 || node_index >= i32(len(scene.local_transforms)) {
		return
	}
	scene.local_transforms[node_index] = transform
	scene_mark_node_dirty(scene, node_index)
}

// Add a mesh node to the scene.
scene_add_mesh_node :: proc(
	scene: ^Scene,
	#any_int parent: i32,
	#any_int mesh_index, material_index: u32,
	name: string = "",
) -> i32 {
	// Create a new node
	level := parent > -1 ? scene.hierarchy[parent].level + 1 : 0
	node := scene_add_node(scene, parent, level)

	// Associate the mesh with this node
	scene.mesh_for_node[node] = mesh_index

	// Associate the material with this node
	scene.material_for_node[node] = material_index

	// Add name if provided
	if len(name) > 0 {
		owned_name := strings.clone(name)
		name_idx := append_and_get_idx(&scene.node_names, owned_name)
		scene.name_for_node[u32(node)] = name_idx
	}

	return node
}

// Update all world transforms starting from a specific node.
update_transforms :: proc(scene: ^Scene, #any_int node_index: i32, parent_dirty: bool) {
	node := scene.hierarchy[node_index]
	branch_dirty := parent_dirty || scene.subtree_dirty[node_index]
	if !branch_dirty {
		return
	}

	parent := node.parent
	node_dirty := parent_dirty || scene.transform_dirty[node_index]

	// Calculate world transform using quaternion composition (cheaper than matrix multiplication)
	if node_dirty {
		if parent > -1 {
			// Node has a parent, compose with parent's world transform
			scene.world_transforms[node_index] = transform_compose(
				scene.world_transforms[parent],
				scene.local_transforms[node_index],
			)
		} else {
			// Node is a root, world transform equals local transform
			scene.world_transforms[node_index] = scene.local_transforms[node_index]
		}

		scene.transform_dirty[node_index] = false
	}

	// Recursively update all children
	child := node.first_child
	for child != -1 {
		update_transforms(scene, child, node_dirty)
		child = scene.hierarchy[child].next_sibling
	}

	scene.subtree_dirty[node_index] = false
}

// Update all world transforms in the scene.
update_all_transforms :: proc(scene: ^Scene) {
	// Find all root nodes and update their hierarchies
	for &node, i in scene.hierarchy {
		if node.parent == -1 && scene.subtree_dirty[i] {
			// This is a root node
			update_transforms(scene, i, false)
		}
	}
}

// Draw a specific node and its children.
scene_draw_node :: proc(scene: ^Scene, #any_int node_index: i32, ctx: ^Draw_Context) {
	// Convert transform to matrix for GPU (once per node, at render time)
	node_transform := scene.world_transforms[node_index]
	node_matrix := transform_to_matrix(node_transform)

	// Check if this node has a mesh
	if scene.mesh_for_node[node_index] != NO_MESH {
		mesh_index := scene.mesh_for_node[node_index]
		mesh := &scene.meshes[mesh_index]

		// Add render objects for each surface in the mesh
		for &surface in mesh.surfaces {
			// Get the material index from the node or use the surface's default
			material_index := surface.material_index
			if scene.material_for_node[node_index] != NO_MATERIAL {
				material_index = scene.material_for_node[node_index]
			}

			uv_remap := la.Vector4f32{0, 0, 1, 1}
			source_mode := Material_Source_Mode.Standalone
			atlas_page: i32 = -1
			if int(material_index) < len(scene.material_uv_remap) {
				uv_remap = scene.material_uv_remap[material_index]
				source_mode = scene.material_source[material_index]
				atlas_page = scene.material_atlas_page[material_index]
			}

			// Create render object with a valid material index
			def := Render_Object {
				index_count           = surface.count,
				first_index           = surface.start_index,
				index_buffer          = mesh.mesh_buffers.index_buffer.buffer,
				vertex_buffer         = mesh.mesh_buffers.vertex_buffer.buffer,
				material              = material_index, // Direct material index
				uv_remap              = uv_remap,
				material_source_mode  = source_mode,
				atlas_page            = atlas_page,
				transform             = node_matrix,
				vertex_buffer_address = mesh.mesh_buffers.vertex_buffer_address,
			}

			// Add to render context
			append(&ctx.opaque_surfaces, def)
		}
	}

	// Draw all children
	child := scene.hierarchy[node_index].first_child
	for child != -1 {
		scene_draw_node(scene, child, ctx)
		child = scene.hierarchy[child].next_sibling
	}
}

scene_get_node_name :: proc(self: ^Scene, #any_int node: i32) -> string {
	name_idx := self.name_for_node[u32(node)]
	if name_idx == NO_NAME {
		return ""
	}
	return self.node_names[name_idx]
}

Scene_Node_File :: struct {
	name:         string,
	mesh:         string,
	parent:       i32,
	material:     u32,
	atlas_policy: Material_Atlas_Policy,
	position:     [3]f32,
	rotation:     [4]f32,
	scale:        [3]f32,
}

Scene_File :: struct {
	name:           string,
	nodes:          []Scene_Node_File,
	atlas_manifest: Level_Atlas_Manifest_File,
}

free_scene_file :: proc(scene_file: ^Scene_File) {
	if scene_file == nil {
		return
	}

	delete(scene_file.name)
	for node in scene_file.nodes {
		delete(node.name)
		delete(node.mesh)
	}
	delete(scene_file.nodes)

	for p in scene_file.atlas_manifest.pages {
		delete(p.name)
	}
	delete(scene_file.atlas_manifest.pages)
	delete(scene_file.atlas_manifest.mappings)
}

scene_extract_local_position :: proc(t: Transform) -> [3]f32 {
	return t.position
}

scene_extract_local_scale :: proc(t: Transform) -> [3]f32 {
	return t.scale
}

scene_extract_local_rotation :: proc(t: Transform) -> [4]f32 {
	return [4]f32{t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w}
}

scene_clear_nodes :: proc(engine: ^Engine) {
	for name in engine.scene.node_names {
		delete(name)
	}
	for atlas_page in engine.scene.atlas_pages {
		destroy_image(atlas_page)
	}
	for p in engine.scene.atlas_manifest.pages {
		delete(p.name)
	}
	clear(&engine.scene.local_transforms)
	clear(&engine.scene.world_transforms)
	clear(&engine.scene.transform_dirty)
	clear(&engine.scene.subtree_dirty)
	clear(&engine.scene.hierarchy)
	clear(&engine.scene.mesh_for_node)
	clear(&engine.scene.material_for_node)
	clear(&engine.scene.name_for_node)
	clear(&engine.scene.node_names)
	clear(&engine.scene.material_uv_remap)
	clear(&engine.scene.material_source)
	clear(&engine.scene.material_atlas_page)
	clear(&engine.scene.atlas_pages)
	clear(&engine.scene.atlas_manifest.pages)
	clear(&engine.scene.atlas_manifest.mappings)
	engine.scene.atlas_manifest.enabled = false
	clear(&engine.main_draw_context.opaque_surfaces)

	clear(&engine.name_for_node)
}

scene_find_mesh_index_by_name :: proc(scene: ^Scene, name: string) -> (u32, bool) {
	for mesh, i in scene.meshes {
		if mesh.name == name {
			return u32(i), true
		}
	}
	return 0, false
}

scene_init_material_remap_state :: proc(scene: ^Scene) {
	clear(&scene.material_uv_remap)
	clear(&scene.material_source)
	clear(&scene.material_atlas_page)

	reserve(&scene.material_uv_remap, len(scene.materials))
	reserve(&scene.material_source, len(scene.materials))
	reserve(&scene.material_atlas_page, len(scene.materials))

	for _ in scene.materials {
		append(&scene.material_uv_remap, la.Vector4f32{0, 0, 1, 1})
		append(&scene.material_source, Material_Source_Mode.Standalone)
		append(&scene.material_atlas_page, -1)
	}
}

scene_apply_atlas_manifest :: proc(scene: ^Scene) {
	scene_init_material_remap_state(scene)

	for m in scene.atlas_manifest.mappings {
		idx := int(m.material)
		if idx < 0 || idx >= len(scene.materials) {
			continue
		}

		scene.material_uv_remap[idx] = {
			m.uv_offset[0],
			m.uv_offset[1],
			m.uv_scale[0],
			m.uv_scale[1],
		}
		scene.material_source[idx] = m.source_mode
		scene.material_atlas_page[idx] = m.atlas_page
	}
}

scene_ensure_default_atlas_settings :: proc(scene: ^Scene) {
	if scene.atlas_manifest.settings.max_page_size <= 0 {
		scene.atlas_manifest.settings.max_page_size = 2048
	}
	if scene.atlas_manifest.settings.max_pages <= 0 {
		scene.atlas_manifest.settings.max_pages = 8
	}
	if scene.atlas_manifest.settings.padding_px < 0 {
		scene.atlas_manifest.settings.padding_px = 4
	}
}

scene_material_is_atlas_compatible :: proc(scene: ^Scene, #any_int material_index: int) -> bool {
	if material_index < 0 || material_index >= len(scene.materials) {
		return false
	}

	m := scene.materials[material_index].source
	if m.color_extent[0] <= 0 || m.color_extent[1] <= 0 {
		return false
	}
	if m.metal_rough_extent[0] <= 0 || m.metal_rough_extent[1] <= 0 {
		return false
	}
	if m.color_extent != m.metal_rough_extent {
		return false
	}

	s := scene.atlas_manifest.settings
	required_w := m.color_extent[0] + s.padding_px * 2
	required_h := m.color_extent[1] + s.padding_px * 2
	if required_w > s.max_page_size || required_h > s.max_page_size {
		return false
	}

	return true
}

scene_atlas_start_new_page :: proc(
	scene: ^Scene,
	settings: Atlas_Build_Settings_File,
	next_page: ^i32,
	cursor_x: ^i32,
	cursor_y: ^i32,
	row_h: ^i32,
) -> bool {
	if next_page^ >= settings.max_pages {
		return false
	}

	page_name := strings.clone(fmt.aprintf("atlas_page_%d", next_page^))
	append(
		&scene.atlas_manifest.pages,
		Atlas_Page_File {
			name = page_name,
			width = settings.max_page_size,
			height = settings.max_page_size,
		},
	)
	next_page^ += 1
	cursor_x^ = 0
	cursor_y^ = 0
	row_h^ = 0
	return true
}

scene_build_level_atlas_manifest :: proc(scene: ^Scene) {
	scene_ensure_default_atlas_settings(scene)

	// Preserve policy decisions from previous mappings.
	policies := make(
		[dynamic]Material_Atlas_Policy,
		0,
		len(scene.materials),
		context.temp_allocator,
	)
	for _, i in scene.materials {
		append(&policies, scene_get_material_policy(scene, u32(i)))
	}

	for p in scene.atlas_manifest.pages {
		delete(p.name)
	}
	clear(&scene.atlas_manifest.pages)
	clear(&scene.atlas_manifest.mappings)

	if !scene.atlas_manifest.enabled {
		for _, i in scene.materials {
			append(
				&scene.atlas_manifest.mappings,
				Atlas_Material_Mapping_File {
					material = u32(i),
					policy = policies[i],
					source_mode = .Standalone,
					atlas_page = -1,
					uv_offset = {0, 0},
					uv_scale = {1, 1},
				},
			)
		}
		return
	}

	s := scene.atlas_manifest.settings
	next_page: i32 = 0
	cursor_x: i32 = 0
	cursor_y: i32 = 0
	row_h: i32 = 0

	if len(scene.materials) > 0 {
		_ = scene_atlas_start_new_page(scene, s, &next_page, &cursor_x, &cursor_y, &row_h)
	}

	for _, i in scene.materials {
		material_index := u32(i)
		policy := policies[i]
		mode := Material_Source_Mode.Standalone
		atlas_page: i32 = -1
		uv_offset := [2]f32{0, 0}
		uv_scale := [2]f32{1, 1}

		compatible := scene_material_is_atlas_compatible(scene, i)
		wants_atlas := policy == .Force_Atlas || policy == .Auto

		if wants_atlas && compatible {
			src := scene.materials[i].source
			w := src.color_extent[0]
			h := src.color_extent[1]
			packed_w := w + s.padding_px * 2
			packed_h := h + s.padding_px * 2

			if cursor_x + packed_w > s.max_page_size {
				cursor_x = 0
				cursor_y += row_h
				row_h = 0
			}
			if cursor_y + packed_h > s.max_page_size {
				if !scene_atlas_start_new_page(
					scene,
					s,
					&next_page,
					&cursor_x,
					&cursor_y,
					&row_h,
				) {
					compatible = false
				}
			}

			if compatible {
				mode = .Atlas
				atlas_page = i32(next_page - 1)
				page_size := f32(s.max_page_size)
				uv_offset = {
					f32(cursor_x + s.padding_px) / page_size,
					f32(cursor_y + s.padding_px) / page_size,
				}
				uv_scale = {f32(w) / page_size, f32(h) / page_size}

				cursor_x += packed_w
				if packed_h > row_h {
					row_h = packed_h
				}
			}
		}

		append(
			&scene.atlas_manifest.mappings,
			Atlas_Material_Mapping_File {
				material = material_index,
				policy = policy,
				source_mode = mode,
				atlas_page = atlas_page,
				uv_offset = uv_offset,
				uv_scale = uv_scale,
			},
		)
	}
}

scene_build_default_atlas_mappings :: proc(scene: ^Scene) {
	scene_ensure_default_atlas_settings(scene)

	if !scene.atlas_manifest.enabled || len(scene.atlas_manifest.mappings) > 0 {
		return
	}

	for _, i in scene.materials {
		append(
			&scene.atlas_manifest.mappings,
			Atlas_Material_Mapping_File {
				material = u32(i),
				policy = .Auto,
				source_mode = .Standalone,
				atlas_page = -1,
				uv_offset = {0, 0},
				uv_scale = {1, 1},
			},
		)
	}
}

scene_build_default_nodes :: proc(engine: ^Engine) {
	default_material_idx: u32 = 0

	for mesh, i in engine.scene.meshes {
		if mesh.name == "Sphere" {
			continue
		}

		node_idx := scene_add_mesh_node(&engine.scene, -1, u32(i), default_material_idx, mesh.name)
		engine.name_for_node[mesh.name] = u32(node_idx)
	}
}

scene_get_material_policy :: proc(scene: ^Scene, material_index: u32) -> Material_Atlas_Policy {
	for m in scene.atlas_manifest.mappings {
		if m.material == material_index {
			return m.policy
		}
	}
	return .Auto
}

scene_bake_atlas_pages_gpu :: proc(engine: ^Engine, scene: ^Scene) {
	if engine == nil || scene == nil {
		return
	}

	for atlas_page in scene.atlas_pages {
		destroy_image(atlas_page)
	}
	clear(&scene.atlas_pages)

	if !scene.atlas_manifest.enabled || len(scene.atlas_manifest.pages) == 0 {
		return
	}

	reserve(&scene.atlas_pages, len(scene.atlas_manifest.pages))
	for _ in scene.atlas_manifest.pages {
		append(&scene.atlas_pages, Allocated_Image{})
	}

	log.infof(
		"scene_bake_atlas_pages_gpu: placeholder baked %d atlas pages",
		len(scene.atlas_pages),
	)
}

// Loads scene nodes from a level json file.
// If the file has no explicit nodes, falls back to placing one root node per mesh.
scene_load_from_file :: proc(engine: ^Engine, file_path: string) -> (ok: bool) {
	ensure(engine != nil, "Invalid 'Engine'")

	file_data, read_err := os.read_entire_file(file_path, context.temp_allocator)
	if read_err != nil {
		log.errorf("scene_load_from_file: failed to read '%s': %v", file_path, read_err)
		return false
	}

	scene_file: Scene_File
	if unmarshal_err := json.unmarshal(file_data, &scene_file); unmarshal_err != nil {
		log.errorf("scene_load_from_file: failed to parse '%s': %v", file_path, unmarshal_err)
		return false
	}
	defer free_scene_file(&scene_file)

	scene_clear_nodes(engine)

	// Copy atlas manifest from level file into runtime scene state.
	engine.scene.atlas_manifest.enabled = scene_file.atlas_manifest.enabled
	engine.scene.atlas_manifest.settings = scene_file.atlas_manifest.settings
	for p in scene_file.atlas_manifest.pages {
		append(
			&engine.scene.atlas_manifest.pages,
			Atlas_Page_File{name = strings.clone(p.name), width = p.width, height = p.height},
		)
	}
	for m in scene_file.atlas_manifest.mappings {
		append(&engine.scene.atlas_manifest.mappings, m)
	}

	// Current level files only define metadata. In that case we build a default scene.
	if len(scene_file.nodes) == 0 {
		scene_build_default_nodes(engine)
		scene_build_level_atlas_manifest(&engine.scene)
		scene_apply_atlas_manifest(&engine.scene)
		scene_bake_atlas_pages_gpu(engine, &engine.scene)
		return true
	}

	for node in scene_file.nodes {
		mesh_index, mesh_ok := scene_find_mesh_index_by_name(&engine.scene, node.mesh)
		if !mesh_ok {
			log.warnf(
				"scene_load_from_file: skipping node '%s', unknown mesh '%s'",
				node.name,
				node.mesh,
			)
			continue
		}

		material_index := node.material
		if len(engine.scene.materials) == 0 {
			log.warnf(
				"scene_load_from_file: skipping node '%s', no materials available",
				node.name,
			)
			continue
		}
		if int(material_index) >= len(engine.scene.materials) {
			log.warnf(
				"scene_load_from_file: node '%s' material index %d is out of range, using 0",
				node.name,
				material_index,
			)
			material_index = 0
		}

		parent := node.parent
		if parent < -1 || parent >= i32(len(engine.scene.hierarchy)) {
			if parent != -1 {
				log.warnf(
					"scene_load_from_file: node '%s' has invalid parent %d, using root",
					node.name,
					parent,
				)
			}
			parent = -1
		}

		node_name := node.name
		if len(node_name) == 0 {
			node_name = node.mesh
		}

		node_idx := scene_add_mesh_node(
			&engine.scene,
			parent,
			mesh_index,
			material_index,
			node_name,
		)

		mapping_exists := false
		for &m in engine.scene.atlas_manifest.mappings {
			if m.material == material_index {
				mapping_exists = true
				if m.policy == .Auto {
					m.policy = node.atlas_policy
				}
				break
			}
		}
		if !mapping_exists {
			append(
				&engine.scene.atlas_manifest.mappings,
				Atlas_Material_Mapping_File {
					material = material_index,
					policy = node.atlas_policy,
					source_mode = .Standalone,
					atlas_page = -1,
					uv_offset = {0, 0},
					uv_scale = {1, 1},
				},
			)
		}

		scale := [3]f32{node.scale[0], node.scale[1], node.scale[2]}
		if scale.x == 0 && scale.y == 0 && scale.z == 0 {
			scale = {1, 1, 1}
		}

		rotation: la.Quaternionf32
		rotation.x = node.rotation[0]
		rotation.y = node.rotation[1]
		rotation.z = node.rotation[2]
		rotation.w = node.rotation[3]
		rot_len_sq := rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z + rotation.w * rotation.w
		if rot_len_sq <= 0 {
			rotation = make_identity_quat()
		}

		position := [3]f32{node.position[0], node.position[1], node.position[2]}

		// Create transform from position, rotation, and scale.
		transform := transform_from_pos_rot_scale(position, rotation, scale)
		scene_set_local_transform(&engine.scene, node_idx, transform)
		stored_name := scene_get_node_name(&engine.scene, node_idx)
		engine.name_for_node[stored_name] = u32(node_idx)
	}

	// If every node was skipped due to bad data, keep a usable fallback scene.
	if len(engine.scene.hierarchy) == 0 {
		scene_build_default_nodes(engine)
	}

	scene_build_level_atlas_manifest(&engine.scene)
	scene_apply_atlas_manifest(&engine.scene)

    return true
}

// Save the current scene to a JSON file.
scene_save_to_file :: proc(engine: ^Engine, file_path: string) -> bool {
	// Build a Scene_File from the current scene state
	scene_file: Scene_File
	// TODO: Fill out all fields as needed for your serialization
	// Example: scene_file.nodes = ...; scene_file.atlas_manifest = ...
	// For now, just create an empty file as a placeholder
	scene_file.name = "runtime_scene"
	// TODO: Serialize nodes, meshes, materials, atlas, etc.

	// Marshal to JSON
	json_data, marshal_err := json.marshal(scene_file, allocator = context.temp_allocator)
	if marshal_err != nil {
		log.errorf("scene_save_to_file: failed to marshal scene: %v", marshal_err)
		return false
	}
	// Write to file
	write_err := os.write_entire_file(file_path, json_data)
	if write_err != nil {
		log.errorf("scene_save_to_file: failed to write file '%s': %v", file_path, write_err)
		return false
	}
	return true
}