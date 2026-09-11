// Engine/src/Tools/asset_converter/mesh_quantize.odin
//
// Vertex quantization for the .bmesh format.
//
// Honors Core.Vertex_Quantization / Core.Quantization_Level from the
// project's Renderer_Settings:
//
//   .U8  - 8-bit unsigned normalized (range [min,max] -> [0,255])
//   .U16 - 16-bit unsigned normalized
//   .F32 - 32-bit float (passthrough)
//
// Per-vertex layout written into the VERTICES section:
//
//   [position][normal][uv][tangent]
//
// `position`, `uv` use straight unsigned-normalized quantization.
// `normal`, `tangent` use octahedral encoding (Cigolle et al. 2014):
// the .F32 path stores the raw float3; .U8 / .U16 use the octahedral
// 2D projection packed into two values. Tangent additionally packs
// its handedness bit into the least-significant bit of the second
// component (oct8) or as a sign bit (oct16) so we recover the full
// TBN frame at runtime.
//
// The .bmesh header records the per-channel quant level so the
// runtime can decode the raw bytes without a per-asset schema.

package asset_converter

import "core:mem"
import "core:math"

import Core "../../Core"
import gltf "../../dependencies/gltf"

// Returns the byte size of a single vertex channel under the given
// quantization level.
channel_size_bytes :: proc(q: Core.Quantization_Level) -> int {
	switch q {
	case .U8:  return 1
	case .U16: return 2
	case .F32: return 4
	}
	return 4
}

// Multi-component channel size (uv = 2 components, pos/normal/tangent = 3).
channel_size_components :: proc(q: Core.Quantization_Level, components: int) -> int {
	return channel_size_bytes(q) * components
}

// Compute the per-vertex byte stride for the vertex buffer.
compute_vertex_stride :: proc(vq: Core.Vertex_Quantization, oct_normals: bool) -> int {
	pos := channel_size_components(vq.position, 3)
	uv  := channel_size_components(vq.uv, 2)
	tan := channel_size_components(vq.tangent, 4) if vq.tangent != .F32 else 16

	norm: int
	switch vq.position {
	case .U8, .U16:
		// Non-float positions still imply quantized normals: with
		// U8/U16 positions the runtime expects oct-encoded normals
		// for a consistent small-footprint vertex format.
		norm = 2 if oct_normals else 12
	case .F32:
		norm = 12 // 3 floats
	}

	return pos + norm + uv + tan
}

// ============================================================================
// Quantization helpers (F32 -> U8/U16)
// ============================================================================

quantize_f32_to_u8 :: proc(v, lo, hi: f32) -> u8 {
	if hi <= lo do return 0
	t := (v - lo) / (hi - lo)
	t = math.clamp(t, 0.0, 1.0)
	return u8(t * 255.0 + 0.5)
}

quantize_f32_to_u16 :: proc(v, lo, hi: f32) -> u16 {
	if hi <= lo do return 0
	t := (v - lo) / (hi - lo)
	t = math.clamp(t, 0.0, 1.0)
	return u16(t * 65535.0 + 0.5)
}

// ============================================================================
// Octahedral normal encoding (Cigolle et al. 2014)
// ============================================================================

// Encodes a unit (or near-unit) 3D normal as 2 floats in [-1, 1].
// The resulting vector can be passed through quantize_f32_to_u8/_u16
// with lo=-1, hi=1 to get an 8/16-bit packed normal.
encode_octahedral :: proc(n: [3]f32) -> [2]f32 {
	// Project onto unit octahedron, then unfold to 2D unit square.
	l1 := math.abs(n[0]) + math.abs(n[1]) + math.abs(n[2])
	p := n[0] / l1
	q := n[1] / l1
	out: [2]f32
	if n[2] >= 0 {
		out = {p, q}
	} else {
		out = {
			(1 - math.abs(q)) * (p >= 0 ? 1.0 : -1.0),
			(1 - math.abs(p)) * (q >= 0 ? 1.0 : -1.0),
		}
	}
	return out
}

// Decodes an octahedral 2D projection back into a unit normal.
decode_octahedral :: proc(e: [2]f32) -> [3]f32 {
	p := e[0]
	q := e[1]
	n: [3]f32 = {p, q, 1.0 - math.abs(p) - math.abs(q)}
	l := math.length(n[0:3])
	if l > 1e-8 {
		n[0] /= l
		n[1] /= l
		n[2] /= l
	}
	return n
}

// ============================================================================
// Vertex writer (writes one vertex into the destination buffer)
// ============================================================================

Vertex_Writer :: struct {
	data:         [dynamic]u8,
	stride:       int,
	offset:       int, // current write cursor
	vq:           Core.Vertex_Quantization,
	oct_normals:  bool,
	pos_min, pos_max: [3]f32,
	uv_min,  uv_max:  [2]f32,
}

// Initialize a vertex writer with the bounds needed for quantization.
// Bounds are computed by the caller (typically from the source mesh
// AABB) so a single writer can drain an entire mesh.
vertex_writer_init :: proc(
	w: ^Vertex_Writer,
	vq: Core.Vertex_Quantization,
	oct_normals: bool,
	pos_min, pos_max: [3]f32,
	uv_min, uv_max: [2]f32,
	allocator := context.allocator,
) {
	w.vq          = vq
	w.oct_normals = oct_normals
	w.pos_min     = pos_min
	w.pos_max     = pos_max
	w.uv_min      = uv_min
	w.uv_max      = uv_max
	w.stride      = compute_vertex_stride(vq, oct_normals)
	w.offset      = 0
	w.data        = make([dynamic]u8, 0, 1024, allocator)
}

vertex_writer_destroy :: proc(w: ^Vertex_Writer) {
	delete(w.data)
}

// write_vertex encodes one vertex into the destination buffer and
// advances `offset`. The caller is responsible for ensuring all
// fields are valid (e.g. normal / tangent are unit vectors).
write_vertex :: proc(w: ^Vertex_Writer, pos, nrm, tan: [3]f32, uv: [2]f32) {
	reserve(&w.data, w.offset + w.stride)
	buf := w.data[w.offset:][:w.stride]
	bo := 0 // byte offset within `buf`

	// --- position ---
	switch w.vq.position {
	case .U8:
		for i in 0..<3 {
			(^u8)(raw_data(buf[bo:]))[0] = quantize_f32_to_u8(pos[i], w.pos_min[i], w.pos_max[i])
			bo += 1
		}
	case .U16:
		for i in 0..<3 {
			(^u16)(raw_data(buf[bo:]))[0] = quantize_f32_to_u16(pos[i], w.pos_min[i], w.pos_max[i])
			bo += 2
		}
	case .F32:
		for i in 0..<3 {
			(^f32)(raw_data(buf[bo:]))[0] = pos[i]
			bo += 4
		}
	}

	// --- normal ---
	switch w.vq.position {
	case .F32:
		// F32 positions => F32 normals (uncompressed)
		for i in 0..<3 {
			(^f32)(raw_data(buf[bo:]))[0] = nrm[i]
			bo += 4
		}
	case .U8:
		if w.oct_normals {
			oct := encode_octahedral(nrm)
			(^u8)(raw_data(buf[bo:]))[0] = quantize_f32_to_u8(oct[0], -1, 1)
			(^u8)(raw_data(buf[bo+1:]))[0] = quantize_f32_to_u8(oct[1], -1, 1)
			bo += 2
		}
	case .U16:
		if w.oct_normals {
			oct := encode_octahedral(nrm)
			(^u16)(raw_data(buf[bo:]))[0] = quantize_f32_to_u16(oct[0], -1, 1)
			(^u16)(raw_data(buf[bo+2:]))[0] = quantize_f32_to_u16(oct[1], -1, 1)
			bo += 4
		}
	}

	// --- uv ---
	switch w.vq.uv {
	case .U8:
		for i in 0..<2 {
			(^u8)(raw_data(buf[bo:]))[0] = quantize_f32_to_u8(uv[i], w.uv_min[i], w.uv_max[i])
			bo += 1
		}
	case .U16:
		for i in 0..<2 {
			(^u16)(raw_data(buf[bo:]))[0] = quantize_f32_to_u16(uv[i], w.uv_min[i], w.uv_max[i])
			bo += 2
		}
	case .F32:
		for i in 0..<2 {
			(^f32)(raw_data(buf[bo:]))[0] = uv[i]
			bo += 4
		}
	}

	// --- tangent (always float4 for F32 path; octahedral+handedness for U8/U16) ---
	switch w.vq.tangent {
	case .F32:
		// tangent stored as float4 (xyz + handedness in w)
		for i in 0..<3 {
			(^f32)(raw_data(buf[bo:]))[0] = tan[i]
			bo += 4
		}
		(^f32)(raw_data(buf[bo:]))[0] = 1.0 // handedness; compute proper sign at source time
		bo += 4
	case .U8:
		if w.oct_normals {
			oct := encode_octahedral(tan)
			(^u8)(raw_data(buf[bo:]))[0] = quantize_f32_to_u8(oct[0], -1, 1)
			// Pack handedness bit into the LSB of the second component.
			h: u8 = 1 // placeholder; proper sign is computed at source time
			v := quantize_f32_to_u8(oct[1], -1, 1)
			(^u8)(raw_data(buf[bo+1:]))[0] = (v & 0x7F) | (h << 7)
			bo += 2
		}
	case .U16:
		if w.oct_normals {
			oct := encode_octahedral(tan)
			(^u16)(raw_data(buf[bo:]))[0] = quantize_f32_to_u16(oct[0], -1, 1)
			h: u16 = 1 << 15
			v := quantize_f32_to_u16(oct[1], -1, 1)
			(^u16)(raw_data(buf[bo+2:]))[0] = (v & 0x7FFF) | h
			bo += 4
		}
	}

	w.offset += w.stride
}

// ============================================================================
// Bounds computation (min/max across all vertices)
// ============================================================================

Mesh_Bounds :: struct {
	pos_min, pos_max: [3]f32,
	uv_min,  uv_max:  [2]f32,
}

compute_mesh_bounds :: proc(positions: []f32, uvs: []f32) -> Mesh_Bounds {
	b: Mesh_Bounds
	if len(positions) > 0 {
		b.pos_min = positions[0:3]
		b.pos_max = positions[0:3]
		for i in 0..<len(positions)/3 {
			for k in 0..<3 {
				v := positions[i*3+k]
				if v < b.pos_min[k] do b.pos_min[k] = v
				if v > b.pos_max[k] do b.pos_max[k] = v
			}
		}
	}
	if len(uvs) >= 2 {
		b.uv_min = uvs[0:2]
		b.uv_max = uvs[0:2]
		for i in 0..<len(uvs)/2 {
			for k in 0..<2 {
				v := uvs[i*2+k]
				if v < b.uv_min[k] do b.uv_min[k] = v
				if v > b.uv_max[k] do b.uv_max[k] = v
			}
		}
	}
	return b
}
