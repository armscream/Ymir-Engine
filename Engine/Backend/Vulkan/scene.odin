package Vulkan

// Core
import "base:builtin"
import "core:encoding/json"
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

// Render object that holds drawing data.
Render_Object :: struct {
    index_count:           u32,
    first_index:           u32,
    index_buffer:          vk.Buffer,
    vertex_buffer:         vk.Buffer,
    material:              u32, // Index into materials array
    transform:             la.Matrix4f32,
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
    // Transform components
    local_transforms:  [dynamic]la.Matrix4f32,
    world_transforms:  [dynamic]la.Matrix4f32,

    // Hierarchy components
    hierarchy:         [dynamic]Hierarchy,

    // Mesh components (Node index -> Mesh index)
    mesh_for_node:     [dynamic]u32,

    // Material components (Node index -> Material index)
    material_for_node: [dynamic]u32,

    // Optional debug components
    name_for_node:     [dynamic]u32,
    node_names:        [dynamic]string,

    // Material instances
    materials:         [dynamic]Material_Instance,

    // Mesh assets
    meshes:            Mesh_Asset_List,
}

// Initialize a new scene.
scene_init :: proc(scene: ^Scene, allocator := context.allocator) {
    context.allocator = allocator
    scene.local_transforms = make([dynamic]la.Matrix4f32)
    scene.world_transforms = make([dynamic]la.Matrix4f32)
    scene.hierarchy = make([dynamic]Hierarchy)
    scene.mesh_for_node = make([dynamic]u32)
    scene.material_for_node = make([dynamic]u32)
    scene.name_for_node = make([dynamic]u32)
    scene.node_names = make([dynamic]string)
    scene.materials = make([dynamic]Material_Instance)
    scene.meshes = make([dynamic]Mesh_Asset)
}

// Free scene resources.
scene_destroy :: proc(scene: ^Scene, allocator := context.allocator) {
    context.allocator = allocator
	for name in scene.node_names {
		delete(name)
	}
    delete(scene.local_transforms)
    delete(scene.world_transforms)
    delete(scene.hierarchy)
    delete(scene.mesh_for_node)
    delete(scene.material_for_node)
    delete(scene.name_for_node)
    delete(scene.node_names)
    delete(scene.materials)
    delete(scene.meshes)
}

// Add a new node to the scene
scene_add_node :: proc(scene: ^Scene, #any_int parent, level: i32) -> i32 {
    // Create new node ID
    node := i32(len(scene.hierarchy))

    // Add transform components with identity matrices
    append(&scene.local_transforms, la.MATRIX4F32_IDENTITY)
    append(&scene.world_transforms, la.MATRIX4F32_IDENTITY)

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
update_transforms :: proc(scene: ^Scene, #any_int node_index: i32) {
    node := scene.hierarchy[node_index]
    parent := node.parent

    // Calculate world transform
    if parent > -1 {
        // Node has a parent, multiply with parent's world transform
        scene.world_transforms[node_index] = la.matrix_mul(
            scene.world_transforms[parent],
            scene.local_transforms[node_index],
        )
    } else {
        // Node is a root, world transform equals local transform
        scene.world_transforms[node_index] = scene.local_transforms[node_index]
    }

    // Recursively update all children
    child := node.first_child
    for child != -1 {
        update_transforms(scene, child)
        child = scene.hierarchy[child].next_sibling
    }
}

// Update all world transforms in the scene.
update_all_transforms :: proc(scene: ^Scene) {
    // Find all root nodes and update their hierarchies
    for &node, i in scene.hierarchy {
        if node.parent == -1 {
            // This is a root node
            update_transforms(scene, i)
        }
    }
}

// Draw a specific node and its children.
scene_draw_node :: proc(scene: ^Scene, #any_int node_index: i32, ctx: ^Draw_Context) {
    node_matrix := scene.world_transforms[node_index]

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

            // Create render object with a valid material index
            def := Render_Object {
                index_count           = surface.count,
                first_index           = surface.start_index,
                index_buffer          = mesh.mesh_buffers.index_buffer.buffer,
                vertex_buffer         = mesh.mesh_buffers.vertex_buffer.buffer,
                material              = material_index, // Direct material index
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
    name:     string,
    mesh:     string,
    parent:   i32,
    material: u32,
    position: [3]f32,
    scale:    [3]f32,
}

Scene_File :: struct {
    name:  string,
    nodes: []Scene_Node_File,
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
}

scene_extract_local_position :: proc(m: la.Matrix4f32) -> [3]f32 {
    return {m[0, 3], m[1, 3], m[2, 3]}
}

scene_extract_local_scale :: proc(m: la.Matrix4f32) -> [3]f32 {
    sx := f32(math.sqrt(f64(m[0, 0] * m[0, 0] + m[1, 0] * m[1, 0] + m[2, 0] * m[2, 0])))
    sy := f32(math.sqrt(f64(m[0, 1] * m[0, 1] + m[1, 1] * m[1, 1] + m[2, 1] * m[2, 1])))
    sz := f32(math.sqrt(f64(m[0, 2] * m[0, 2] + m[1, 2] * m[1, 2] + m[2, 2] * m[2, 2])))

    if sx == 0 {sx = 1}
    if sy == 0 {sy = 1}
    if sz == 0 {sz = 1}

    return {sx, sy, sz}
}

scene_clear_nodes :: proc(engine: ^Engine) {
	for name in engine.scene.node_names {
		delete(name)
	}
    clear(&engine.scene.local_transforms)
    clear(&engine.scene.world_transforms)
    clear(&engine.scene.hierarchy)
    clear(&engine.scene.mesh_for_node)
    clear(&engine.scene.material_for_node)
    clear(&engine.scene.name_for_node)
    clear(&engine.scene.node_names)
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

scene_build_default_nodes :: proc(engine: ^Engine) {
    default_material_idx: u32 = 0

    for mesh, i in engine.scene.meshes {
        if mesh.name == "Sphere" {
            continue
        }

        node_idx := scene_add_mesh_node(
            &engine.scene,
            -1,
            u32(i),
            default_material_idx,
            mesh.name,
        )
        engine.name_for_node[mesh.name] = u32(node_idx)
    }
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

    // Current level files only define metadata. In that case we build a default scene.
    if len(scene_file.nodes) == 0 {
        scene_build_default_nodes(engine)
        return true
    }

    for node in scene_file.nodes {
        mesh_index, mesh_ok := scene_find_mesh_index_by_name(&engine.scene, node.mesh)
        if !mesh_ok {
            log.warnf("scene_load_from_file: skipping node '%s', unknown mesh '%s'", node.name, node.mesh)
            continue
        }

        material_index := node.material
        if len(engine.scene.materials) == 0 {
            log.warnf("scene_load_from_file: skipping node '%s', no materials available", node.name)
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

        scale := la.Vector3f32{node.scale[0], node.scale[1], node.scale[2]}
        if scale.x == 0 && scale.y == 0 && scale.z == 0 {
            scale = {1, 1, 1}
        }

        translation := la.matrix4_translate(la.Vector3f32{node.position[0], node.position[1], node.position[2]})
        transform := la.matrix_mul(translation, la.matrix4_scale(scale))

        engine.scene.local_transforms[u32(node_idx)] = transform
		stored_name := scene_get_node_name(&engine.scene, node_idx)
		engine.name_for_node[stored_name] = u32(node_idx)
    }

    // If every node was skipped due to bad data, keep a usable fallback scene.
    if len(engine.scene.hierarchy) == 0 {
        scene_build_default_nodes(engine)
    }

    return true
}

save_scene_graph :: proc(engine: ^Engine, file_path: string) -> (ok: bool) {
    ensure(engine != nil, "Invalid 'Engine'")

    out := Scene_File {name = "scene"}
    nodes := make([dynamic]Scene_Node_File, 0, len(engine.scene.hierarchy), context.temp_allocator)

    for _, i in engine.scene.hierarchy {
        mesh_index := engine.scene.mesh_for_node[i]
        if mesh_index == NO_MESH {
            continue
        }

        if int(mesh_index) >= len(engine.scene.meshes) {
            continue
        }

        local := engine.scene.local_transforms[i]
        node_name := scene_get_node_name(&engine.scene, i)
        mesh_name := engine.scene.meshes[mesh_index].name
        if len(node_name) == 0 {
            node_name = mesh_name
        }

        material_index := engine.scene.material_for_node[i]
        if material_index == NO_MATERIAL {
            material_index = 0
        }

        append(&nodes, Scene_Node_File {
            name     = node_name,
            mesh     = mesh_name,
            parent   = engine.scene.hierarchy[i].parent,
            material = material_index,
            position = scene_extract_local_position(local),
            scale    = scene_extract_local_scale(local),
        })
    }

    out.nodes = nodes[:]

    json_opt := json.Marshal_Options {
        pretty     = true,
        use_spaces = true,
        spaces     = 2,
    }

    data, marshal_err := json.marshal(out, json_opt, context.temp_allocator)
    if marshal_err != nil {
        log.errorf("save_scene_graph: failed to serialize scene: %v", marshal_err)
        return false
    }

    if write_err := os.write_entire_file(
        file_path,
        data,
        os.Permissions_Read_All + {.Write_User},
        true,
    ); write_err != nil {
        log.errorf("save_scene_graph: failed to write '%s': %v", file_path, write_err)
        return false
    }

    return true
}