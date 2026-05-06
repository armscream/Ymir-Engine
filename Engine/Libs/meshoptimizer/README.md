
# meshoptimizer — Odin Bindings (v1.1)

Odin bindings for [meshoptimizer v1.1](https://github.com/zeux/meshoptimizer) by Arseny Kapoulkine.
A mesh optimization library that reduces GPU vertex processing and memory bandwidth by reordering and compressing mesh data.

## Files

| File | Description |
|---|---|
| `meshoptimizer.odin` | Odin foreign bindings (`package meshoptimizer`) |
| `meshoptimizer_windows_x86_64.lib` | Pre-compiled static library (MSVC x64) |
| `src/` | meshoptimizer v1.1 C++ source files (for rebuilding on other platforms) |

## Import

```odin
import meshopt "Engine/Libs/meshoptimizer"
```

---

## Usage Patterns

### 1. Full mesh optimization pipeline (recommended order)

The standard three-step pipeline to prepare a mesh for GPU rendering:

```odin
import "core:c"

// Step 1 — generate a remap table to deduplicate vertices
remap := make([]c.uint, vertex_count)
unique_count := meshopt.generateVertexRemap(
    raw_data(remap),
    raw_data(indices), index_count,
    raw_data(vertices), vertex_count, size_of(Vertex),
)

// Apply remap to both buffers
new_vertices := make([]Vertex, unique_count)
new_indices  := make([]c.uint, index_count)
meshopt.remapVertexBuffer(raw_data(new_vertices), raw_data(vertices), vertex_count, size_of(Vertex), raw_data(remap))
meshopt.remapIndexBuffer(raw_data(new_indices), raw_data(indices), index_count, raw_data(remap))

// Step 2 — optimize for vertex cache (reduces vertex shader invocations)
meshopt.optimizeVertexCache(raw_data(new_indices), raw_data(new_indices), index_count, unique_count)

// Step 3 — optimize for overdraw (improves pixel throughput); threshold 1.05 = 5% cache degradation allowed
meshopt.optimizeOverdraw(
    raw_data(new_indices), raw_data(new_indices), index_count,
    cast([^]f32)raw_data(new_vertices), unique_count, size_of(Vertex),
    1.05,
)

// Step 4 — optimize for vertex fetch (minimizes memory bandwidth)
meshopt.optimizeVertexFetch(
    raw_data(new_vertices), raw_data(new_indices), index_count,
    raw_data(new_vertices), unique_count, size_of(Vertex),
)
```

---

### 2. Vertex remapping with multiple streams

When position, normals, and UVs are stored in separate arrays:

```odin
streams := []meshopt.Stream{
    { data = raw_data(positions), size = size_of([3]f32), stride = size_of([3]f32) },
    { data = raw_data(normals),   size = size_of([3]f32), stride = size_of([3]f32) },
    { data = raw_data(uvs),       size = size_of([2]f32), stride = size_of([2]f32) },
}
remap := make([]c.uint, vertex_count)
unique_count := meshopt.generateVertexRemapMulti(
    raw_data(remap), raw_data(indices), index_count, vertex_count,
    raw_data(streams), len(streams),
)
// Then call remapVertexBuffer for each stream separately
```

---

### 3. Mesh simplification (LOD generation)

Reduce triangle count for level-of-detail meshes:

```odin
target_count  := index_count / 4  // target 25% of original triangles
target_error  : f32 = 0.01        // 1% geometric error tolerance
result_error  : f32

lod_indices := make([]c.uint, index_count)  // worst-case size = index_count
lod_count := meshopt.simplify(
    raw_data(lod_indices),
    raw_data(indices), index_count,
    cast([^]f32)raw_data(vertices), vertex_count, size_of(Vertex),
    target_count, target_error,
    meshopt.SIMPLIFY_LOCK_BORDER,  // combine flags with | as needed
    &result_error,
)
lod_indices = lod_indices[:lod_count]

// Convert absolute error to relative, or vice versa:
scale := meshopt.simplifyScale(cast([^]f32)raw_data(vertices), vertex_count, size_of(Vertex))
absolute_error := result_error * scale
```

Available simplify flags (combine with `|`):

| Flag | Effect |
|---|---|
| `SIMPLIFY_LOCK_BORDER` | Prevent border vertices from moving |
| `SIMPLIFY_SPARSE` | Input is a sparse subset of a larger mesh |
| `SIMPLIFY_ERROR_ABSOLUTE` | Treat `target_error` as absolute, not relative |
| `SIMPLIFY_PRUNE` | Remove disconnected mesh islands |
| `SIMPLIFY_REGULARIZE` | Produce more uniform triangle shapes |
| `SIMPLIFY_PERMISSIVE` | Allow collapses across attribute discontinuities (experimental) |

---

### 4. Meshlet generation (mesh shading / cluster rendering)

Split a mesh into meshlets for NVidia mesh shaders or cluster-based renderers:

```odin
MAX_VERTICES  :: 128
MAX_TRIANGLES :: 256

bound := meshopt.buildMeshletsBound(index_count, MAX_VERTICES, MAX_TRIANGLES)

meshlets          := make([]meshopt.Meshlet, bound)
meshlet_vertices  := make([]c.uint,  index_count)  // worst case
meshlet_triangles := make([]c.uchar, index_count)  // worst case

meshlet_count := meshopt.buildMeshlets(
    raw_data(meshlets),
    raw_data(meshlet_vertices),
    raw_data(meshlet_triangles),
    raw_data(indices), index_count,
    cast([^]f32)raw_data(vertices), vertex_count, size_of(Vertex),
    MAX_VERTICES, MAX_TRIANGLES,
    0.5,  // cone_weight: 0 = no backface culling, >0 = smaller clusters with better cone culling
)

// Trim to actual counts
meshlets          = meshlets[:meshlet_count]
last              := meshlets[meshlet_count - 1]
meshlet_vertices  = meshlet_vertices[:last.vertex_offset + last.vertex_count]
meshlet_triangles = meshlet_triangles[:last.triangle_offset + ((last.triangle_count * 3 + 3) &~ 3)]

// Optimize each meshlet for rasterizer locality
for &m in meshlets {
    meshopt.optimizeMeshlet(
        &meshlet_vertices[m.vertex_offset],
        &meshlet_triangles[m.triangle_offset],
        m.triangle_count, m.vertex_count,
    )
}

// Per-meshlet bounds for frustum + backface cone culling
for m in meshlets {
    bounds := meshopt.computeMeshletBounds(
        &meshlet_vertices[m.vertex_offset],
        &meshlet_triangles[m.triangle_offset],
        m.triangle_count,
        cast([^]f32)raw_data(vertices), vertex_count, size_of(Vertex),
    )
    // bounds.center / bounds.radius — bounding sphere for frustum/occlusion
    // bounds.cone_apex/axis/cutoff  — normal cone for backface culling
}
```

---

### 5. Index/vertex buffer encoding (GPU-ready compressed storage)

Encode buffers for compact on-disk storage or streaming. Decoders are designed for fast runtime decoding (7–10 GB/s).

```odin
// Index buffer encoding
enc_bound  := meshopt.encodeIndexBufferBound(index_count, vertex_count)
enc_buffer := make([]c.uchar, enc_bound)
enc_size   := meshopt.encodeIndexBuffer(raw_data(enc_buffer), enc_bound, raw_data(indices), index_count)
enc_buffer  = enc_buffer[:enc_size]

// Index buffer decoding
decoded_indices := make([]c.uint, index_count)
ok := meshopt.decodeIndexBuffer(raw_data(decoded_indices), index_count, size_of(c.uint), raw_data(enc_buffer), enc_size)
assert(ok == 0)

// Vertex buffer encoding (vertex_size must be a multiple of 4)
venc_bound  := meshopt.encodeVertexBufferBound(vertex_count, size_of(Vertex))
venc_buffer := make([]c.uchar, venc_bound)
venc_size   := meshopt.encodeVertexBuffer(raw_data(venc_buffer), venc_bound, raw_data(vertices), vertex_count, size_of(Vertex))
venc_buffer  = venc_buffer[:venc_size]

// Vertex buffer decoding
decoded_vertices := make([]Vertex, vertex_count)
ok = meshopt.decodeVertexBuffer(raw_data(decoded_vertices), vertex_count, size_of(Vertex), raw_data(venc_buffer), venc_size)
assert(ok == 0)
```

---

### 6. Meshlet encoding (experimental, v1.1+)

Compress meshlet topology for streaming or storage:

```odin
// Optimize for best compression first (level 3 recommended)
meshopt.optimizeMeshletLevel(
    &meshlet_vertices[m.vertex_offset], m.vertex_count,
    &meshlet_triangles[m.triangle_offset], m.triangle_count,
    3,
)

enc_bound  := meshopt.encodeMeshletBound(m.vertex_count, m.triangle_count)
enc_buffer := make([]c.uchar, enc_bound)
enc_size   := meshopt.encodeMeshlet(
    raw_data(enc_buffer), enc_bound,
    &meshlet_vertices[m.vertex_offset],  m.vertex_count,
    &meshlet_triangles[m.triangle_offset], m.triangle_count,
)

// Decode at runtime (targeting write-combined memory for GPU upload)
out_verts := make([]c.uint,  m.vertex_count)
out_tris  := make([]c.uint,  m.triangle_count)
meshopt.decodeMeshletRaw(raw_data(out_verts), m.vertex_count, raw_data(out_tris), m.triangle_count, raw_data(enc_buffer), enc_size)
```

---

### 7. Vertex quantization helpers

```odin
// Pack a float normal component into 8-bit snorm
snorm8 := meshopt.quantizeSnorm_odin(normal_x, 8)  // use quantizeSnorm from your math lib

// Half-precision float conversion
half := meshopt.quantizeHalf(some_float)
back := meshopt.dequantizeHalf(half)

// Encode normals as oct-mapped 8-bit pairs for decode in shader
// Input: slice of float4 (count * 4 floats); output: stride=4 bytes per normal
meshopt.encodeFilterOct(raw_data(packed_normals), normal_count, 4, 8, raw_data(float4_normals))
// Decode in-place after loading vertex buffer:
meshopt.decodeFilterOct(raw_data(packed_normals), normal_count, 4)

// Encode quaternions (stride must be 8 bytes, 4 x int16)
meshopt.encodeFilterQuat(raw_data(packed_quats), quat_count, 8, 12, raw_data(float4_quats))
meshopt.decodeFilterQuat(raw_data(packed_quats), quat_count, 8)
```

---

### 8. Analysis / statistics

Measure the quality of an optimized mesh:

```odin
vcache := meshopt.analyzeVertexCache(raw_data(indices), index_count, vertex_count, 16, 32, 32)
fmt.printf("ACMR: %.3f  ATVR: %.3f\n", vcache.acmr, vcache.atvr)
// ACMR best case = 0.5, worst = 3.0
// ATVR best case = 1.0 (each vertex transformed once)

vfetch := meshopt.analyzeVertexFetch(raw_data(indices), index_count, vertex_count, size_of(Vertex))
fmt.printf("Overfetch: %.3f\n", vfetch.overfetch)
// Overfetch best case = 1.0

overdraw := meshopt.analyzeOverdraw(raw_data(indices), index_count, cast([^]f32)raw_data(vertices), vertex_count, size_of(Vertex))
fmt.printf("Overdraw: %.3f\n", overdraw.overdraw)
// Overdraw best case = 1.0
```

---

### 9. Shadow / depth-only index buffer

Generate a secondary index buffer that deduplicates vertices by position only, for Z-prepass or shadowmap rendering:

```odin
shadow_indices := make([]c.uint, index_count)
meshopt.generateShadowIndexBuffer(
    raw_data(shadow_indices),
    raw_data(indices), index_count,
    raw_data(vertices), vertex_count,
    size_of([3]f32),   // only compare position (first 12 bytes)
    size_of(Vertex),   // full vertex stride
)
```

---

### 10. Custom allocator

Replace the default `operator new/delete` used internally for temporary allocations:

```odin
meshopt.setAllocator(my_alloc, my_free)

my_alloc :: proc "c" (size: c.size_t) -> rawptr { ... }
my_free  :: proc "c" (ptr:  rawptr)             { ... }
```

---

## Building for other platforms

All C++ source files are in `src/`. Compile them into a static library and name it according to the pattern in `meshoptimizer.odin`:

| Platform | Expected lib name |
|---|---|
| Windows x64 | `meshoptimizer_windows_x86_64.lib` |
| Windows ARM64 | `meshoptimizer_windows_ARM64.lib` |
| macOS x64 | `libmeshoptimizer_macosx_x86_64.a` |
| macOS ARM64 | `libmeshoptimizer_macosx_ARM64.a` |
| Linux x64 | `libmeshoptimizer_linux_x86_64.a` |
| Linux ARM64 | `libmeshoptimizer_linux_ARM64.a` |

Example (GCC/Clang):
```sh
cd Engine/Libs/meshoptimizer/src
c++ -O2 -c *.cpp
ar rcs ../libmeshoptimizer_linux_x86_64.a *.o
```

---

## License

meshoptimizer is MIT licensed. See `src/meshoptimizer.h` for the full notice.