// Engine/src/Tools/asset_converter/bmesh_format.odin
//
// .bmesh on-disk binary format (Bifrost Mesh).
//
// Stable, versioned, section-based binary layout designed for the
// runtime renderer. Stores:
//
//   - vertex data laid out per-vertex (quantized per project settings)
//   - index buffer (U16 or U32 per project settings)
//   - LOD chain (each LOD = vertex range + index range)
//   - optional octahedral-encoded normals
//   - optional per-vertex skinning data (joints + weights)
//   - one or more submeshes (material slots per primitive)
//
// All variable-length sections are 16-byte aligned so we can mmap
// straight from disk at runtime without per-field fixing.
//
// Layout:
//
//   BMAP-style header + section table (see BMAP_* in
//   Engine/src/Modules/BF_MapDB/Types.odin for inspiration; the
//   format is similar but independent).
//
//   BMESH_Header {
//     magic:    [4]u8  == 'BM' 'S' 'H'
//     version:  u32     BMESH_VERSION
//     flags:    u32     BMESH_FLAG_*
//     section_count: u16
//     reserved: u16
//     // followed by `section_count` BMESH_Section_Header records
//   }
//
//   BMESH_Section_Header {
//     id:     u32      BMESH_SECTION_*
//     length: u32      payload bytes (does not include this header)
//     flags:  u32      reserved
//   }

package asset_converter

// ============================================================================
// Magic + version
// ============================================================================

BMESH_MAGIC :: [4]u8{'B', 'M', 'S', 'H'}

// Bump MAJOR on any breaking change. Additive sections (new ids
// appended at the end) do NOT require a bump as long as readers
// consult the section table.
BMESH_VERSION_MAJOR :: u32(1)
BMESH_VERSION_MINOR :: u32(0)
BMESH_VERSION_PATCH :: u32(0)

BMESH_VERSION :: u32(
	(BMESH_VERSION_MAJOR << 24) |
	(BMESH_VERSION_MINOR << 16) |
	(BMESH_VERSION_PATCH <<  0),
)

// ============================================================================
// File-level flags
// ============================================================================

BMESH_FLAG_NONE         :: u32(0)
BMESH_FLAG_LITTLE_ENDIAN :: u32(1 << 0) // informational; readers assume LE
BMESH_FLAG_OCT_NORMALS   :: u32(1 << 1) // normals stored as 16-bit octahedral (XY), W=1.0 implied
BMESH_FLAG_HAS_SKIN      :: u32(1 << 2) // JOINT_INDICES + WEIGHTS sections present

// ============================================================================
// Section IDs. Stable; new sections get new IDs and older readers skip them.
// ============================================================================

BMESH_SECTION_NONE         :: u32(0)
BMESH_SECTION_STRINGS      :: u32(1) // shared string table (mesh name, submesh names)
BMESH_SECTION_HEADER_INFO  :: u32(2) // BMESH_Header_Info -- counts + quantization metadata
BMESH_SECTION_SUBMESHES    :: u32(3) // one BMESH_Submesh_Header per primitive
BMESH_SECTION_LOD_CHAIN    :: u32(4) // BMESH_LOD_Entry[num_lods]
BMESH_SECTION_VERTICES     :: u32(5) // raw, layout described by Header_Info
BMESH_SECTION_INDICES      :: u32(6) // U16 or U32 per project settings
BMESH_SECTION_JOINT_INDICES :: u32(7) // present only when BMESH_FLAG_HAS_SKIN
BMESH_SECTION_WEIGHTS       :: u32(8) // present only when BMESH_FLAG_HAS_SKIN

// ============================================================================
// On-disk headers
// ============================================================================

BMESH_File_Header :: struct #packed {
	magic:        [4]u8,
	version:      u32,
	flags:        u32,
	section_count: u16,
	reserved:     u16,
}

BMESH_Section_Header :: struct #packed {
	id:     u32,
	length: u32, // payload bytes; does not include this 12-byte header
	flags:  u32,
}

// Quantization layout as it appears on disk. Mirrors the project's
// Renderer_Settings.vertex_quantization + index_buffer_format so the
// runtime renderer can lay out vertex buffers from raw bytes without
// a per-asset schema.
BMESH_Header_Info :: struct #packed {
	// Quantization level for each vertex channel (0=U8, 1=U16, 2=F32).
	// Values map to Core.Quantization_Level. The runtime uses these
	// to determine the stride of each channel and the dequantization
	// math.
	position_quant: u8,
	normal_quant:   u8, // 0=oct8, 1=oct16, 2=float
	uv_quant:       u8,
	tangent_quant:  u8, // 0=oct8, 1=oct16, 2=float

	// Index buffer format (0=U16, 1=U32). Mirrors Core.Index_Buffer_Format.
	index_format: u8,

	// LOD chain length (>=1). LOD 0 is the full mesh.
	num_lods:      u16,
	num_submeshes: u16,

	// Total unique vertex count (all LODs share the same vertex pool;
	// each LOD references a contiguous vertex range).
	vertex_count: u32,

	// Total triangle count across all submeshes in LOD 0.
	triangle_count: u32,

	// Per-vertex byte stride used in the VERTICES section.
	vertex_stride: u16,

	reserved: u16,
}

// One entry per LOD. Each LOD is a contiguous slice of the index
// buffer + a contiguous slice of the vertex buffer. LODs MUST be
// ordered from most-detailed (lod=0) to least-detailed.
BMESH_LOD_Entry :: struct #packed {
	index_offset: u32, // into INDICES section
	index_count:  u32, // number of indices (multiple of 3)
	target_error: f32, // simplification target error (meshopt result_error)
}

// One entry per GLTF primitive (submesh). Submeshes partition the
// index buffer into disjoint ranges. The runtime uses this to bind
// per-submesh materials.
BMESH_Submesh_Header :: struct #packed {
	material_name_offset: u32, // into STRINGS section
	index_offset:         u32, // into INDICES section
	index_count:          u32, // number of indices (multiple of 3)
}
