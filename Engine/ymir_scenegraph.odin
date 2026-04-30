package ye

import "core:math"
import "core:fmt"

// Gonna grab level and layer data to this file and then construct efficient data structures for 
// rendering

// root node for the scene graph, contains all other nodes as children. 
// This is the main entry point for traversing the scene graph.
RootNode :: struct {
    world_transform: Transform,
    children: [dynamic]^GroupNode,
    isDirty: bool, // flag to indicate if the node has changed and needs to be re-rendered
}

GroupNode :: struct { // group node for organizing the scene graph, has scene nodes as children
    parent: ^RootNode, // pointer to parent node, used for traversing up the graph and calculating world transforms
    children: [dynamic]^SceneNode,
    isDirty: bool, // flag to indicate if the node has changed and needs to be re-rendered
}

SceneNode :: struct {
    isInstance: bool, // is this node an instance of another node? used for instanced rendering
    name: string,
    children: [dynamic]^SceneNode,
    instance_count: int, // number of instances for this node, used for instanced rendering
    // how would i handle dirty flag for instances? maybe we can have a separate array of dirty flags for each instance, or we can just mark the whole node as dirty if any instance has changed
    dirtyInstances: [dynamic]bool, // array of dirty flags for each instance, used for instanced rendering
    instances: [dynamic]Transform, // array of transforms for each instance, used for instanced rendering. 
    world_transform: Transform, // transform for the non-instanced version of this node, used when instance_count is 0
    local_transform: Transform, // local transform for the non-instanced version of this node, used when instance_count is 0. This is the transform that is edited in the editor, and then the world transform is calculated from this and the parent transforms.

    isDirty: bool, // flag to indicate if the node has changed and needs to be re-rendered
    renderable: ^Renderable, // optional renderable component - not sure how to handle optionality in Odin yet, 
}

Transform :: struct {
    position: Vec3,
    rotation: quaternion128, // quaternion for rotation to avoid gimbal lock
    scale: Vec3,
}

Renderable :: struct {
    mesh: Mesh,
    material: Material,
}

Mesh :: struct {
    vertices: [dynamic]Vertex,
    indices: [dynamic]int,
}

Vertex :: struct {
    position: Vec3,
    normal: Vec3,
    uv: Vec2,
}

Material :: struct {
    albedo: Vec3,
    metallic: f32,
    roughness: f32,
    normal: f32,
}

UpdateSceneGraph :: proc(root: ^RootNode) {
    // traverse the scene graph and update world transforms for each node
    for x in root.children {
        UpdateSceneGraphGroupNode(x, root.world_transform)
    }
}

UpdateSceneGraphGroupNode :: proc(node: ^GroupNode, parent_world_transform: Transform) {
   // pass root world transform to children marked dirty
    if node.isDirty {
        for child in node.children {
            UpdateSceneGraphNode(child, parent_world_transform)
        }
    }
}

UpdateSceneGraphNode :: proc(node: ^SceneNode, parent_world_transform: Transform) {
    // calculate world transform for this node based on its local transform and the parent's world transform
    if node.isDirty {
        node.world_transform = CombineTransforms(node.local_transform, parent_world_transform)
        for child in node.children {
            UpdateSceneGraphNode(child, node.world_transform)
        }
        node.isDirty = false // reset dirty flag after updating this node and its children
        fmt.println("Updated world transform for node: ", node.name)
    if node.isInstance {
            for i in 0..<len(node.dirtyInstances) {
                if node.dirtyInstances[i] {
                    node.instances[i] = CombineTransforms(node.local_transform, parent_world_transform)
                    node.dirtyInstances[i] = false // reset dirty flag for this instance after updating its transform
                    fmt.println("Updated world transform for instance ", i, " of node: ", node.name)
                }
            }
        }
    }
}

CombineTransforms :: proc(local: Transform, parent: Transform) -> Transform {
    new_position := parent.position + RotateVector(local.position, parent.rotation)
    new_rotation := parent.rotation * local.rotation
    new_scale := parent.scale * local.scale
    return Transform{new_position, new_rotation, new_scale}
}

// we can also have a function to mark a node and all of its children as dirty, so that we know which nodes need to be re-rendered
MarkNodeDirty :: proc(node: ^SceneNode) {
    node.isDirty = true
    for child in node.children {
        MarkNodeDirty(child)
    }
    if node.isInstance {
        for i in 0..<node.instance_count {
            node.dirtyInstances[i] = true // this would mark each instance as dirty as well, so that we know which instances need to be re-rendered
        }
    }
}


