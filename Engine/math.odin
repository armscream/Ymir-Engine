package ye

import "core:math"
import "core:math/linalg/glsl"

Vec2 :: distinct [2]f32
Vec3 :: distinct [3]f32
Vec4 :: distinct [4]f32
Matrix4x4 :: [4][4]f32

DEG_TO_RAD :: 0.01745329251

Vector3Normalize :: proc(v: Vec3) -> Vec3 {
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

Vector3CrossProduct :: proc(v1, v2: Vec3) -> Vec3 {
    return {
        v1[1]*v2[2] - v1[2]*v2[1],
        v1[2]*v2[0] - v1[0]*v2[2],
        v1[0]*v2[1] - v1[1]*v2[0],
    }
}

Vector3DotProduct :: proc(v1, v2: Vec3) -> f32 {
    return v1[0]*v2[0] + v1[1]*v2[1] + v1[2]*v2[2]
}

Mat4MulVec3 :: proc(mat: Matrix4x4, vec: Vec3) -> Vec3 {
    x := mat[0][0]*vec.x + mat[0][1]*vec.y + mat[0][2]*vec.z + mat[0][3]
    y := mat[1][0]*vec.x + mat[1][1]*vec.y + mat[1][2]*vec.z + mat[1][3]
    z := mat[2][0]*vec.x + mat[2][1]*vec.y + mat[2][2]*vec.z + mat[2][3]

    return Vec3{x, y, z}
}

Mat4MulVec4 :: proc(mat: Matrix4x4, vec: Vec4) -> Vec4 {
    x := mat[0][0]*vec.x + mat[0][1]*vec.y + mat[0][2]*vec.z + mat[0][3]*vec.w
    y := mat[1][0]*vec.x + mat[1][1]*vec.y + mat[1][2]*vec.z + mat[1][3]*vec.w
    z := mat[2][0]*vec.x + mat[2][1]*vec.y + mat[2][2]*vec.z + mat[2][3]*vec.w
    w := mat[3][0]*vec.x + mat[3][1]*vec.y + mat[3][2]*vec.z + mat[3][3]*vec.w

    return Vec4{x, y, z, w}
}

Mat4Mul :: proc(a, b: Matrix4x4) -> Matrix4x4 {
    result: Matrix4x4
    for i in 0..<4 {
        for j in 0..<4 {
            result[i][j] = a[i][0] * b[0][j] +
                           a[i][1] * b[1][j] +
                           a[i][2] * b[2][j] +
                           a[i][3] * b[3][j]
        }
    }
    return result
}

// Rotation order: Yaw (Y), Pitch (X), Roll (Z)
MakeRotationMatrix :: proc(pitch, yaw, roll: f32) -> Matrix4x4 {
    alpha := yaw * DEG_TO_RAD
    beta  := pitch * DEG_TO_RAD
    gamma := roll * DEG_TO_RAD

    ca := math.cos(alpha)
    sa := math.sin(alpha)

    cb := math.cos(beta)
    sb := math.sin(beta)

    cg := math.cos(gamma)
    sg := math.sin(gamma)

    return Matrix4x4 {
        {ca*cb, ca*sb*sg-sa*cg,  ca*sb*cg+sa*sg,  0.0},
        {sa*cb, sa*sb*sg+ca*cg,  sa*sb*cg-ca*sg,  0.0},
        {  -sb,          cb*sg,  cb*cg,           0.0},
        {  0.0,              0.0,  0.0,           1.0}
    }
}

// Handedness: Right-handed coordinate system
// Here's an example of a coordinate system where X-axis is positive to the left, 
// the Y-axis is positive upward, and the Z-axis is positive forward. 
// This makes it a so-called right-handed coordinate system

//Let's now construct our view matrix. First, we need a normalized direction from a target, 
//the point a camera is looking towards. We'll call this vector forward, and we calculate it by subtracting the target position from the camera position, 
//then dividing the resulting vector by its length to normalize it.
//Then we take our global up vector, and calculate the cross product with the forward vector. 
//This will give us the right vector.

//Then the local up vector is simply the cross product of the forward and right vectors. 
//Be careful about the order, as we saw in the previous part, taking the cross product of 
//right and forward (opposite order) would result in the local down vector.


// LookAt function to create a view matrix
MakeViewMatrix :: proc(eye: Vec3, target: Vec3) -> Matrix4x4 {
    forward := Vector3Normalize(eye - target)
    right   := Vector3CrossProduct(Vec3{0.0, 1.0, 0.0}, forward)
    up      := Vector3CrossProduct(forward, right)

    return Matrix4x4{
        {   right.x,   right.y,   right.z,  -Vector3DotProduct(right, eye)},
        {      up.x,      up.y,      up.z,  -Vector3DotProduct(up, eye)},
        { forward.x, forward.y, forward.z,  -Vector3DotProduct(forward, eye)},
        {       0.0,       0.0,       0.0,   1.0}
    }
}

// Perspective projection matrix
MakeProjectionMatrix :: proc(fov: f32, screenWidth: i32, screenHeight: i32, near: f32, far: f32) -> Matrix4x4 {
    f := 1.0 / math.tan_f32(fov * 0.5 * DEG_TO_RAD)
    aspect := f32(screenWidth) / f32(screenHeight)

    return Matrix4x4{
        { f / aspect, 0.0,                        0.0,  0.0},
        {        0.0,   f,                        0.0,  0.0},
        {        0.0, 0.0,        -far / (far - near), -1.0},
        {        0.0, 0.0, -far * near / (far - near),  0.0},
    }
}

RotateVector :: proc(v: Vec3, q: quaternion128) -> Vec3 {
    // Quaternion-vector multiplication (q * v * q^-1)
    qvec := Vec3{q.x, q.y, q.z}
    uv := Vector3CrossProduct(qvec, v)
    uuv := Vector3CrossProduct(qvec, uv)
    uv = uv * (2.0 * q.w)
    uuv = uuv * 2.0
    return v + uv + uuv
}

Conjugate :: proc(q: quaternion128) -> Vec4 {
    return Vec4{-q.x, -q.y, -q.z, q.w}
}

quat_normalize :: proc(q: [4]f32) -> [4]f32 {
	len_sq := q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]
	if len_sq <= 0.0 {
		return {0, 0, 0, 1}
	}
	inv_len := 1.0 / f32(math.sqrt(f64(len_sq)))
	return {q[0] * inv_len, q[1] * inv_len, q[2] * inv_len, q[3] * inv_len}
}

quat_multiply :: proc(q1, q2: [4]f32) -> [4]f32 {
    return {
        q1[3]*q2[0] + q1[0]*q2[3] + q1[1]*q2[2] - q1[2]*q2[1], // x
        q1[3]*q2[1] - q1[0]*q2[2] + q1[1]*q2[3] + q1[2]*q2[0], // y
        q1[3]*q2[2] + q1[0]*q2[1] - q1[1]*q2[0] + q1[2]*q2[3], // z
        q1[3]*q2[3] - q1[0]*q2[0] - q1[1]*q2[1] - q1[2]*q2[2], // w
    }
}
