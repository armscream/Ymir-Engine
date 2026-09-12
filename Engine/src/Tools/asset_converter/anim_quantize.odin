// Engine/src/Tools/asset_converter/anim_quantize.odin
//
// Animation quantization for the .bmesh format.
//
// Honors Core.Animation_Quantization / Core.Quantization_Level:
//
//   rotation:    quaternion (x,y,z,w) -> smallest-three via
//                https://github.com/zeux/meshoptimizer - .U16 quant,
//                4 components, 48 bits effective.
//   translation: f32 -> .U8 / .U16 / .F32 per-component quantized to
//                the AABB of the animation channel.
//   scale:       same as translation.
//
// Quantized keyframes are stored as POD arrays, one track per
// (node, path). The runtime decoder is a tiny piecewise-linear /
// slerp / lerp lookup; full keyframes are not needed for v1.

package asset_converter

import "core:math"
import Core "../../Core"

// ============================================================================
// Rotation: smallest-three + 16-bit per-component (meshopt format)
// ============================================================================

// Encodes a (x,y,z,w) quaternion into meshopt's smallest-three
// 16-bit-per-component format. Returns a 4 x u16 = 64-bit value
// representing the encoded rotation.
//
// Stored as: [a, b, c, idx_bits] where a, b, c are the three largest
// components (in [-1/sqrt(2), 1/sqrt(2)]) quantized to 16 bits, and
// idx_bits packs the index of the dropped component (2 bits) into the
// high bits of the 4th u16.
//
// Reference: https://github.com/zeux/meshoptimizer/blob/master/src/quantization.cpp
Quantized_Rotation :: struct {
	a, b, c: u16,
	idx_bits: u16, // top 2 bits = dropped-component index, bottom 14 bits unused
}

quantize_rotation :: proc(q: [4]f32) -> Quantized_Rotation {
	// Pick the smallest-magnitude component to drop.
	c := math.abs(q[0])
	idx: int = 0
	if math.abs(q[1]) < c { c = math.abs(q[1]); idx = 1 }
	if math.abs(q[2]) < c { c = math.abs(q[2]); idx = 2 }
	if math.abs(q[3]) < c { c = math.abs(q[3]); idx = 3 }

	// Recover the dropped component (q^2 sums to 1; sign by parity).
	sum := q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]
	d2 := math.sqrt(math.max(1.0 - sum, 0.0))
	if idx == 0 || idx == 2 do d2 = -d2 // recover sign

	// Map the three kept components from [-1/sqrt(2), 1/sqrt(2)] to [0, 65535].
	encode :: proc "contextless" (v: f32) -> u16 {
		scale := 1.0 / math.sqrt_f32(2.0)
		t := (v * scale + 1.0) * 0.5 * 65535.0
		return u16(math.clamp(t, 0.0, 65535.0))
	}

	out: Quantized_Rotation
	switch idx {
	case 0:
		out.a = encode(q[1])
		out.b = encode(q[2])
		out.c = encode(q[3])
	case 1:
		out.a = encode(q[0])
		out.b = encode(q[2])
		out.c = encode(q[3])
	case 2:
		out.a = encode(q[0])
		out.b = encode(q[1])
		out.c = encode(q[3])
	case 3:
		out.a = encode(q[0])
		out.b = encode(q[1])
		out.c = encode(q[2])
	}
	out.idx_bits = u16(idx) << 14
	return out
}

// ============================================================================
// Translation / scale: per-track AABB quantization
// ============================================================================

// Per-channel AABB used to quantize translation / scale keyframes.
Vec_Channel_Bounds :: struct {
	min, max: [3]f32,
}

compute_vec_channel_bounds :: proc(values: []f32) -> Vec_Channel_Bounds {
	b: Vec_Channel_Bounds
	if len(values) < 3 do return b
	b.min = {values[0], values[1], values[2]}
	b.max = {values[0], values[1], values[2]}
	for i in 0..<len(values)/3 {
		for k in 0..<3 {
			v := values[i*3+k]
			if v < b.min[k] do b.min[k] = v
			if v > b.max[k] do b.max[k] = v
		}
	}
	return b
}

quantize_vec3 :: proc(v: [3]f32, b: Vec_Channel_Bounds, q: Core.Quantization_Level) -> [3]u16 {
	out: [3]u16
	switch q {
	case .U8:
		for i in 0..<3 {
			t: f32 = 0
			if b.max[i] > b.min[i] {
				t = (v[i] - b.min[i]) / (b.max[i] - b.min[i])
			}
			t = math.clamp(t, 0.0, 1.0)
			out[i] = u16(u8(t * 255.0 + 0.5)) // widen for uniform return type
		}
	case .U16:
		for i in 0..<3 {
			t: f32 = 0
			if b.max[i] > b.min[i] {
				t = (v[i] - b.min[i]) / (b.max[i] - b.min[i])
			}
			t = math.clamp(t, 0.0, 1.0)
			out[i] = u16(t * 65535.0 + 0.5)
		}
	case .F32:
		// F32 path stores raw float; the writer converts to bytes.
		// Returning zeroed u16 here signals "no quantization"; the
		// writer reads the original f32 array directly.
		out = {0, 0, 0}
	}
	return out
}
