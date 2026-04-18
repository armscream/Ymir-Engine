package yemath

import "core:math"

vec3 :: [3]f32
mat4 :: [4][4]f32

Vector3Normalize :: proc(v: vec3) -> vec3 {
    length := math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2])

    if length == 0.0 {
        return {0.0, 0.0, 0.0}
    }

    return {
        v[0] / length,
        v[1] / length,
        v[2] / length,
    }
}

Vector3CrossProduct :: proc(v1, v2: vec3) -> vec3 {
    return {
        v1[1]*v2[2] - v1[2]*v2[1],
        v1[2]*v2[0] - v1[0]*v2[2],
        v1[0]*v2[1] - v1[1]*v2[0],
    }
}

Vector3DotProduct :: proc(v1, v2: vec3) -> f32 {
    return v1[0]*v2[0] + v1[1]*v2[1] + v1[2]*v2[2]
}
