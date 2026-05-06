// meshoptimizer v1.1 bindings for Odin
// https://github.com/zeux/meshoptimizer
package meshoptimizer

import "core:c"

when ODIN_OS == .Windows {
	when ODIN_ARCH == .amd64 {
		foreign import _lib_ "meshoptimizer_windows_x86_64.lib"
	} else when ODIN_ARCH == .arm64 {
		foreign import _lib_ "meshoptimizer_windows_ARM64.lib"
	} else {
		#panic("Unsupported architecture for meshoptimizer on Windows")
	}
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .amd64 {
		foreign import _lib_ "libmeshoptimizer_macosx_x86_64.a"
	} else when ODIN_ARCH == .arm64 {
		foreign import _lib_ "libmeshoptimizer_macosx_ARM64.a"
	} else {
		#panic("Unsupported architecture for meshoptimizer on MacOSX")
	}
} else when ODIN_OS == .Linux {
	when ODIN_ARCH == .amd64 {
		foreign import _lib_ "libmeshoptimizer_linux_x86_64.a"
	} else when ODIN_ARCH == .arm64 {
		foreign import _lib_ "libmeshoptimizer_linux_ARM64.a"
	} else {
		#panic("Unsupported architecture for meshoptimizer on Linux")
	}
} else {
	foreign import _lib_ "system:meshoptimizer"
}

// -------------------------------------------------------------------------
// Structs
// -------------------------------------------------------------------------

// Vertex attribute stream; each element takes `size` bytes beginning at
// `data`, with `stride` controlling spacing between successive elements.
Stream :: struct {
	data:   rawptr,
	size:   c.size_t,
	stride: c.size_t,
}

VertexCacheStatistics :: struct {
	vertices_transformed: c.uint,
	warps_executed:       c.uint,
	acmr:                 f32, // transformed vertices / triangle count
	atvr:                 f32, // transformed vertices / vertex count
}

VertexFetchStatistics :: struct {
	bytes_fetched: c.uint,
	overfetch:     f32, // fetched bytes / vertex buffer size
}

OverdrawStatistics :: struct {
	pixels_covered: c.uint,
	pixels_shaded:  c.uint,
	overdraw:       f32, // shaded pixels / covered pixels
}

CoverageStatistics :: struct {
	coverage: [3]f32,
	extent:   f32, // viewport size in mesh coordinates
}

// Meshlet: a small mesh cluster consisting of a micro index buffer and a
// vertex indirection buffer. Offsets index into the shared meshlet_vertices /
// meshlet_triangles arrays.
Meshlet :: struct {
	vertex_offset:   c.uint,
	triangle_offset: c.uint,
	vertex_count:    c.uint,
	triangle_count:  c.uint,
}

// Bounding volumes for frustum, backface, and occlusion culling.
Bounds :: struct {
	center:         [3]f32,
	radius:         f32,
	cone_apex:      [3]f32,
	cone_axis:      [3]f32,
	cone_cutoff:    f32,        // cos(angle/2)
	cone_axis_s8:   [3]c.schar, // 8-bit SNORM; decode with x/127.0
	cone_cutoff_s8: c.schar,
}

// -------------------------------------------------------------------------
// Enums / flags
// -------------------------------------------------------------------------

EncodeExpMode :: enum c.int {
	Separate        = 0, // separate exponent per component (max quality)
	SharedVector    = 1, // shared exponent per vector (better compression)
	SharedComponent = 2, // shared exponent per component across all vectors (best compression)
	Clamped         = 3, // separate, but clamp to 0
}

// Bitmask flags for simplify functions (combine with |)
Simplify_Flags :: distinct c.uint
SIMPLIFY_LOCK_BORDER     : Simplify_Flags : 1 << 0
SIMPLIFY_SPARSE          : Simplify_Flags : 1 << 1
SIMPLIFY_ERROR_ABSOLUTE  : Simplify_Flags : 1 << 2
SIMPLIFY_PRUNE           : Simplify_Flags : 1 << 3
SIMPLIFY_REGULARIZE      : Simplify_Flags : 1 << 4
SIMPLIFY_PERMISSIVE      : Simplify_Flags : 1 << 5 // experimental
SIMPLIFY_REGULARIZE_LIGHT: Simplify_Flags : 1 << 6 // experimental

// Per-vertex lock/flag values for use in vertex_lock arrays
Simplify_Vertex_Flags :: distinct c.uchar
SIMPLIFY_VERTEX_LOCK     : Simplify_Vertex_Flags : 1 << 0
SIMPLIFY_VERTEX_PROTECT  : Simplify_Vertex_Flags : 1 << 1
SIMPLIFY_VERTEX_PRIORITY : Simplify_Vertex_Flags : 1 << 2 // experimental

// -------------------------------------------------------------------------
// Foreign function declarations
// -------------------------------------------------------------------------

@(default_calling_convention = "c", link_prefix = "meshopt_")
foreign _lib_ {

	// --- Index / vertex remapping ---

	generateVertexRemap :: proc(
		destination:   [^]c.uint,
		indices:       [^]c.uint,
		index_count:   c.size_t,
		vertices:      rawptr,
		vertex_count:  c.size_t,
		vertex_size:   c.size_t,
	) -> c.size_t ---

	generateVertexRemapMulti :: proc(
		destination:   [^]c.uint,
		indices:       [^]c.uint,
		index_count:   c.size_t,
		vertex_count:  c.size_t,
		streams:       [^]Stream,
		stream_count:  c.size_t,
	) -> c.size_t ---

	generateVertexRemapCustom :: proc(
		destination:              [^]c.uint,
		indices:                  [^]c.uint,
		index_count:              c.size_t,
		vertex_positions:         [^]f32,
		vertex_count:             c.size_t,
		vertex_positions_stride:  c.size_t,
		callback:                 proc "c" (context_: rawptr, lhs: c.uint, rhs: c.uint) -> c.int,
		context_:                 rawptr,
	) -> c.size_t ---

	remapVertexBuffer :: proc(
		destination:  rawptr,
		vertices:     rawptr,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
		remap:        [^]c.uint,
	) ---

	remapIndexBuffer :: proc(
		destination: [^]c.uint,
		indices:     [^]c.uint,
		index_count: c.size_t,
		remap:       [^]c.uint,
	) ---

	generateShadowIndexBuffer :: proc(
		destination:  [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertices:     rawptr,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
		vertex_stride: c.size_t,
	) ---

	generateShadowIndexBufferMulti :: proc(
		destination:  [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
		streams:      [^]Stream,
		stream_count: c.size_t,
	) ---

	generatePositionRemap :: proc(
		destination:             [^]c.uint,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) ---

	generateAdjacencyIndexBuffer :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) ---

	generateTessellationIndexBuffer :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) ---

	generateProvokingIndexBuffer :: proc(
		destination:  [^]c.uint,
		reorder:      [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
	) -> c.size_t ---

	// --- Vertex cache optimizers ---

	optimizeVertexCache :: proc(
		destination:  [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
	) ---

	optimizeVertexCacheStrip :: proc(
		destination:  [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
	) ---

	optimizeVertexCacheFifo :: proc(
		destination:  [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
		cache_size:   c.uint,
	) ---

	optimizeOverdraw :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		threshold:               f32,
	) ---

	optimizeVertexFetch :: proc(
		destination:  rawptr,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertices:     rawptr,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
	) -> c.size_t ---

	optimizeVertexFetchRemap :: proc(
		destination:  [^]c.uint,
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
	) -> c.size_t ---

	// --- Index buffer codec ---

	encodeIndexBuffer :: proc(
		buffer:      [^]c.uchar,
		buffer_size: c.size_t,
		indices:     [^]c.uint,
		index_count: c.size_t,
	) -> c.size_t ---

	encodeIndexBufferBound :: proc(index_count: c.size_t, vertex_count: c.size_t) -> c.size_t ---

	encodeIndexVersion :: proc(version: c.int) ---

	decodeIndexBuffer :: proc(
		destination: rawptr,
		index_count: c.size_t,
		index_size:  c.size_t,
		buffer:      [^]c.uchar,
		buffer_size: c.size_t,
	) -> c.int ---

	decodeIndexVersion :: proc(buffer: [^]c.uchar, buffer_size: c.size_t) -> c.int ---

	encodeIndexSequence :: proc(
		buffer:      [^]c.uchar,
		buffer_size: c.size_t,
		indices:     [^]c.uint,
		index_count: c.size_t,
	) -> c.size_t ---

	encodeIndexSequenceBound :: proc(index_count: c.size_t, vertex_count: c.size_t) -> c.size_t ---

	decodeIndexSequence :: proc(
		destination: rawptr,
		index_count: c.size_t,
		index_size:  c.size_t,
		buffer:      [^]c.uchar,
		buffer_size: c.size_t,
	) -> c.int ---

	// --- Meshlet codec (experimental) ---

	encodeMeshlet :: proc(
		buffer:         [^]c.uchar,
		buffer_size:    c.size_t,
		vertices:       [^]c.uint,
		vertex_count:   c.size_t,
		triangles:      [^]c.uchar,
		triangle_count: c.size_t,
	) -> c.size_t ---

	encodeMeshletBound :: proc(max_vertices: c.size_t, max_triangles: c.size_t) -> c.size_t ---

	decodeMeshlet :: proc(
		vertices:       rawptr,
		vertex_count:   c.size_t,
		vertex_size:    c.size_t,
		triangles:      rawptr,
		triangle_count: c.size_t,
		triangle_size:  c.size_t,
		buffer:         [^]c.uchar,
		buffer_size:    c.size_t,
	) -> c.int ---

	decodeMeshletRaw :: proc(
		vertices:       [^]c.uint,
		vertex_count:   c.size_t,
		triangles:      [^]c.uint,
		triangle_count: c.size_t,
		buffer:         [^]c.uchar,
		buffer_size:    c.size_t,
	) -> c.int ---

	// --- Vertex buffer codec ---

	encodeVertexBuffer :: proc(
		buffer:       [^]c.uchar,
		buffer_size:  c.size_t,
		vertices:     rawptr,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
	) -> c.size_t ---

	encodeVertexBufferBound :: proc(vertex_count: c.size_t, vertex_size: c.size_t) -> c.size_t ---

	encodeVertexBufferLevel :: proc(
		buffer:       [^]c.uchar,
		buffer_size:  c.size_t,
		vertices:     rawptr,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
		level:        c.int,
		version:      c.int,
	) -> c.size_t ---

	encodeVertexVersion :: proc(version: c.int) ---

	decodeVertexBuffer :: proc(
		destination:  rawptr,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
		buffer:       [^]c.uchar,
		buffer_size:  c.size_t,
	) -> c.int ---

	decodeVertexVersion :: proc(buffer: [^]c.uchar, buffer_size: c.size_t) -> c.int ---

	// --- Vertex buffer filters ---

	decodeFilterOct  :: proc(buffer: rawptr, count: c.size_t, stride: c.size_t) ---
	decodeFilterQuat :: proc(buffer: rawptr, count: c.size_t, stride: c.size_t) ---
	decodeFilterExp  :: proc(buffer: rawptr, count: c.size_t, stride: c.size_t) ---
	decodeFilterColor :: proc(buffer: rawptr, count: c.size_t, stride: c.size_t) ---

	encodeFilterOct :: proc(
		destination: rawptr,
		count:       c.size_t,
		stride:      c.size_t,
		bits:        c.int,
		data:        [^]f32,
	) ---

	encodeFilterQuat :: proc(
		destination: rawptr,
		count:       c.size_t,
		stride:      c.size_t,
		bits:        c.int,
		data:        [^]f32,
	) ---

	encodeFilterExp :: proc(
		destination: rawptr,
		count:       c.size_t,
		stride:      c.size_t,
		bits:        c.int,
		data:        [^]f32,
		mode:        EncodeExpMode,
	) ---

	encodeFilterColor :: proc(
		destination: rawptr,
		count:       c.size_t,
		stride:      c.size_t,
		bits:        c.int,
		data:        [^]f32,
	) ---

	// --- Mesh simplifiers ---

	simplify :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		target_index_count:      c.size_t,
		target_error:            f32,
		options:                 Simplify_Flags,
		result_error:            ^f32,
	) -> c.size_t ---

	simplifyWithAttributes :: proc(
		destination:              [^]c.uint,
		indices:                  [^]c.uint,
		index_count:              c.size_t,
		vertex_positions:         [^]f32,
		vertex_count:             c.size_t,
		vertex_positions_stride:  c.size_t,
		vertex_attributes:        [^]f32,
		vertex_attributes_stride: c.size_t,
		attribute_weights:        [^]f32,
		attribute_count:          c.size_t,
		vertex_lock:              [^]Simplify_Vertex_Flags,
		target_index_count:       c.size_t,
		target_error:             f32,
		options:                  Simplify_Flags,
		result_error:             ^f32,
	) -> c.size_t ---

	simplifyWithUpdate :: proc(
		indices:                  [^]c.uint,
		index_count:              c.size_t,
		vertex_positions:         [^]f32,
		vertex_count:             c.size_t,
		vertex_positions_stride:  c.size_t,
		vertex_attributes:        [^]f32,
		vertex_attributes_stride: c.size_t,
		attribute_weights:        [^]f32,
		attribute_count:          c.size_t,
		vertex_lock:              [^]Simplify_Vertex_Flags,
		target_index_count:       c.size_t,
		target_error:             f32,
		options:                  Simplify_Flags,
		result_error:             ^f32,
	) -> c.size_t ---

	simplifySloppy :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		vertex_lock:             [^]Simplify_Vertex_Flags,
		target_index_count:      c.size_t,
		target_error:            f32,
		result_error:            ^f32,
	) -> c.size_t ---

	simplifyPrune :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		target_error:            f32,
	) -> c.size_t ---

	simplifyPoints :: proc(
		destination:             [^]c.uint,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		vertex_colors:           [^]f32,
		vertex_colors_stride:    c.size_t,
		color_weight:            f32,
		target_vertex_count:     c.size_t,
	) -> c.size_t ---

	simplifyScale :: proc(
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) -> f32 ---

	// --- Stripifier ---

	stripify :: proc(
		destination:   [^]c.uint,
		indices:       [^]c.uint,
		index_count:   c.size_t,
		vertex_count:  c.size_t,
		restart_index: c.uint,
	) -> c.size_t ---

	stripifyBound :: proc(index_count: c.size_t) -> c.size_t ---

	unstripify :: proc(
		destination:   [^]c.uint,
		indices:       [^]c.uint,
		index_count:   c.size_t,
		restart_index: c.uint,
	) -> c.size_t ---

	unstripifyBound :: proc(index_count: c.size_t) -> c.size_t ---

	// --- Analysis ---

	analyzeVertexCache :: proc(
		indices:       [^]c.uint,
		index_count:   c.size_t,
		vertex_count:  c.size_t,
		cache_size:    c.uint,
		warp_size:     c.uint,
		primgroup_size: c.uint,
	) -> VertexCacheStatistics ---

	analyzeVertexFetch :: proc(
		indices:      [^]c.uint,
		index_count:  c.size_t,
		vertex_count: c.size_t,
		vertex_size:  c.size_t,
	) -> VertexFetchStatistics ---

	analyzeOverdraw :: proc(
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) -> OverdrawStatistics ---

	analyzeCoverage :: proc(
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) -> CoverageStatistics ---

	// --- Meshlet builder ---

	buildMeshlets :: proc(
		meshlets:                [^]Meshlet,
		meshlet_vertices:        [^]c.uint,
		meshlet_triangles:       [^]c.uchar,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		max_vertices:            c.size_t,
		max_triangles:           c.size_t,
		cone_weight:             f32,
	) -> c.size_t ---

	buildMeshletsScan :: proc(
		meshlets:          [^]Meshlet,
		meshlet_vertices:  [^]c.uint,
		meshlet_triangles: [^]c.uchar,
		indices:           [^]c.uint,
		index_count:       c.size_t,
		vertex_count:      c.size_t,
		max_vertices:      c.size_t,
		max_triangles:     c.size_t,
	) -> c.size_t ---

	buildMeshletsBound :: proc(
		index_count:   c.size_t,
		max_vertices:  c.size_t,
		max_triangles: c.size_t,
	) -> c.size_t ---

	buildMeshletsFlex :: proc(
		meshlets:                [^]Meshlet,
		meshlet_vertices:        [^]c.uint,
		meshlet_triangles:       [^]c.uchar,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		max_vertices:            c.size_t,
		min_triangles:           c.size_t,
		max_triangles:           c.size_t,
		cone_weight:             f32,
		split_factor:            f32,
	) -> c.size_t ---

	buildMeshletsSpatial :: proc(
		meshlets:                [^]Meshlet,
		meshlet_vertices:        [^]c.uint,
		meshlet_triangles:       [^]c.uchar,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		max_vertices:            c.size_t,
		min_triangles:           c.size_t,
		max_triangles:           c.size_t,
		fill_weight:             f32,
	) -> c.size_t ---

	optimizeMeshlet :: proc(
		meshlet_vertices:  [^]c.uint,
		meshlet_triangles: [^]c.uchar,
		triangle_count:    c.size_t,
		vertex_count:      c.size_t,
	) ---

	optimizeMeshletLevel :: proc(
		meshlet_vertices:  [^]c.uint,
		vertex_count:      c.size_t,
		meshlet_triangles: [^]c.uchar,
		triangle_count:    c.size_t,
		level:             c.int,
	) ---

	// --- Cluster bounds ---

	computeClusterBounds :: proc(
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) -> Bounds ---

	computeMeshletBounds :: proc(
		meshlet_vertices:        [^]c.uint,
		meshlet_triangles:       [^]c.uchar,
		triangle_count:          c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) -> Bounds ---

	computeSphereBounds :: proc(
		positions:        [^]f32,
		count:            c.size_t,
		positions_stride: c.size_t,
		radii:            [^]f32,
		radii_stride:     c.size_t,
	) -> Bounds ---

	// --- Meshlet utilities (experimental) ---

	extractMeshletIndices :: proc(
		vertices:    [^]c.uint,
		triangles:   [^]c.uchar,
		indices:     [^]c.uint,
		index_count: c.size_t,
	) -> c.size_t ---

	// --- Cluster partitioner ---

	partitionClusters :: proc(
		destination:          [^]c.uint,
		cluster_indices:      [^]c.uint,
		total_index_count:    c.size_t,
		cluster_index_counts: [^]c.uint,
		cluster_count:        c.size_t,
		vertex_positions:     [^]f32,
		vertex_count:         c.size_t,
		vertex_positions_stride: c.size_t,
		target_partition_size: c.size_t,
	) -> c.size_t ---

	// --- Spatial sort ---

	spatialSortRemap :: proc(
		destination:             [^]c.uint,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) ---

	spatialSortTriangles :: proc(
		destination:             [^]c.uint,
		indices:                 [^]c.uint,
		index_count:             c.size_t,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
	) ---

	spatialClusterPoints :: proc(
		destination:             [^]c.uint,
		vertex_positions:        [^]f32,
		vertex_count:            c.size_t,
		vertex_positions_stride: c.size_t,
		cluster_size:            c.size_t,
	) ---

	// --- Opacity micromap (experimental) ---

	opacityMapMeasure :: proc(
		levels:          [^]c.uchar,
		sources:         [^]c.uint,
		omm_indices:     [^]c.int,
		indices:         [^]c.uint,
		index_count:     c.size_t,
		vertex_uvs:      [^]f32,
		vertex_count:    c.size_t,
		vertex_uvs_stride: c.size_t,
		texture_width:   c.uint,
		texture_height:  c.uint,
		max_level:       c.int,
		target_edge:     f32,
	) -> c.size_t ---

	opacityMapRasterize :: proc(
		result:         [^]c.uchar,
		level:          c.int,
		states:         c.int,
		uv0:            [^]f32,
		uv1:            [^]f32,
		uv2:            [^]f32,
		texture_data:   [^]c.uchar,
		texture_stride: c.size_t,
		texture_pitch:  c.size_t,
		texture_width:  c.uint,
		texture_height: c.uint,
	) ---

	opacityMapEntrySize :: proc(level: c.int, states: c.int) -> c.size_t ---

	opacityMapCompact :: proc(
		data:           [^]c.uchar,
		data_size:      c.size_t,
		levels:         [^]c.uchar,
		offsets:        [^]c.uint,
		omm_count:      c.size_t,
		omm_indices:    [^]c.int,
		triangle_count: c.size_t,
		states:         c.int,
	) -> c.size_t ---

	// --- Quantization ---

	quantizeHalf     :: proc(v: f32) -> c.ushort ---
	quantizeFloat    :: proc(v: f32, N: c.int) -> f32 ---
	dequantizeHalf   :: proc(h: c.ushort) -> f32 ---

	// --- Allocator ---

	setAllocator :: proc(
		allocate:   proc "c" (size: c.size_t) -> rawptr,
		deallocate: proc "c" (ptr: rawptr),
	) ---
}
