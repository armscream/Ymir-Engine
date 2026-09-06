package BF_Math

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

World_Transform :: struct {
    local: Transform,
    world: Transform,
}
Transform :: struct {
    pos: Vec3,
    rot: quaternion128,
    scale: Vec3,
}