package rcp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import rbs ".."

// Shader_Type is the source language family. The Bifrost renderer ships
// GLSL shaders only; HLSL is reserved for future DirectX-backend work.
Shader_Type :: enum {
    Glsl,
    Hlsl,
}

// Shader_Format is the target bytecode format. Vulkan requires SPIR-V;
// MoltenVK consumes SPIR-V and translates it to MSL.
Shader_Format :: enum {
    SPIR_V,
}

// Shader_Stage is the shader stage derived from the source file
// extension. The renderer pipelines map 1:1 onto Vulkan stages.
Shader_Stage :: enum {
    Comp,
    Vert,
    Frag,
    Geom,
    Tesc,
    Tese,
    Task,
    Mesh,
    Rgen,
    Rmiss,
    Rchit,
    Rint,
    Rcall,
    Unknown,
}

// stage_from_extension returns the shader stage implied by a file
// extension. Unknown stages are rejected at the call site.
stage_from_extension :: proc(ext: string) -> Shader_Stage {
    if ext == ".comp"  do return .Comp
    if ext == ".vert"  do return .Vert
    if ext == ".frag"  do return .Frag
    if ext == ".geom"  do return .Geom
    if ext == ".tesc"  do return .Tesc
    if ext == ".tese"  do return .Tese
    if ext == ".task"  do return .Task
    if ext == ".mesh"  do return .Mesh
    if ext == ".rgen"  do return .Rgen
    if ext == ".rmiss" do return .Rmiss
    if ext == ".rchit" do return .Rchit
    if ext == ".rint"  do return .Rint
    if ext == ".rcall" do return .Rcall
    return .Unknown
}

// stage_to_glslang_flag returns the lowercase identifier passed to
// glslangValidator's `-S` flag (matches the file extension by
// convention).
stage_to_glslang_flag :: proc(s: Shader_Stage) -> string {
    #partial switch s {
    case .Comp:  return "comp"
    case .Vert:  return "vert"
    case .Frag:  return "frag"
    case .Geom:  return "geom"
    case .Tesc:  return "tesc"
    case .Tese:  return "tese"
    case .Task:  return "task"
    case .Mesh:  return "mesh"
    case .Rgen:  return "rgen"
    case .Rmiss: return "rmiss"
    case .Rchit: return "rchit"
    case .Rint:  return "rint"
    case .Rcall: return "rcall"
    case .Unknown: return ""
    }
    return ""
}

// Shader_Info describes one shader source file and where its compiled
// SPIR-V output should land. `path` is the absolute (or command-relative)
// source file. `output` is the path RELATIVE to the profile's output
// directory, including the `.spv` extension.
Shader_Info :: struct {
    path:     string,
    output:   string,
    type:     Shader_Type,
    format:   Shader_Format,
    stage:    Shader_Stage,
}

// SHADER_EXTENSIONS lists the extensions rbs discovers when walking the
// shader trees.
@(private="file")
SHADER_EXTENSIONS :: []string{".comp", ".vert", ".frag", ".geom", ".tesc", ".tese", ".task", ".mesh"}

// is_shader_file returns true if the path ends in one of the
// recognised shader extensions.
is_shader_file :: proc(path: string) -> bool {
    ext := filepath.ext(path)
    for e in SHADER_EXTENSIONS {
        if ext == e do return true
    }
    return false
}

// shader_output_path converts a project-relative source path to a
// relative SPIR-V output path under the profile's output directory.
//
// On-disk layout:
//   <profile.output>/shaders/<repo-root-relative-path>.spv
//
// Any leading `../` segments are stripped so the on-disk mirror
// starts at the repo root, not at the project root.
shader_output_path :: proc(source: string) -> string {
    rel := source
    for strings.has_prefix(rel, "../") {
        rel = strings.trim_prefix(rel, "../")
    }
    return fmt.aprintf("shaders/%s.spv", rel)
}

// process_shader compiles one shader to SPIR-V under
// `<profile.output>/<shader.output>`. The hash cache
// (cache.odin) short-circuits when both the source content hash and
// the .spv output already match.
process_shader :: proc(p: rbs.Profile, shader: Shader_Info) {
    output_abs := strings.join({p.output, shader.output}, "/")
    defer delete(output_abs)

    if check_cache(shader.path, output_abs) do return

    switch shader.format {
    case .SPIR_V:
        process_spirv(p, shader, output_abs)
    }
}

// to_forward_slash replaces backslashes with forward slashes.
to_forward_slash :: proc(s: string) -> string {
    out, _ := strings.replace_all(s, "\\", "/")
    return out
}

// absolute_include_root resolves a project-relative include root
// (relative to CWD = <repo>/Project/rbs) to an absolute, forward-slash
// path. glslangValidator on Windows does not honour relative `-I`
// flags (it resolves them against the source file's directory, not
// CWD), so every include root must be absolute before being passed
// through. See shader_build.odin:absolute_path for the matching
// helper used by the shader walker.
absolute_include_root :: proc(rel: string) -> string {
    abs, err := filepath.abs(rel, context.allocator)
    if err != nil {
        return strings.clone(rel)
    }
    return to_forward_slash(abs)
}

// process_spirv runs glslangValidator on the source. `-V` selects
// SPIR-V codegen, `-S <stage>` selects the shader stage, `-I<dir>`
// adds the engine shader roots as include search paths so
// `#include "Includes/Core.glsl"` resolves identically to the
// runtime linker.
@(private="file")
process_spirv :: proc(p: rbs.Profile, shader: Shader_Info, output_abs: string) {
    log_processor(.Shader, shader.path, output_abs)

    // Ensure the output subdirectory exists.
    output_dir := filepath.dir(output_abs)
    if !os.exists(output_dir) {
        if mk_err := os.make_directory_all(output_dir); mk_err != nil {
            fmt.eprintfln("Failed to create shader output directory %s: %v", output_dir, mk_err)
            return
        }
    }

    // Resolve include roots. Both Engine/src/Modules/BF_GPU/Shaders
    // and Engine/src/Extensions/BF_GPU_Mesh/Shaders are exposed so
    // module and extension shaders share the same include layout.
    //
    // IMPORTANT: must use the persistent allocator (aprintf) here.
    // tprintf uses the temp allocator, and the matching `delete` below
    // would then free temp-allocated memory through the default
    // allocator -> heap corruption (STATUS_HEAP_CORRUPTION on Windows).
    //
    // IMPORTANT: glslangValidator on Windows does NOT honour relative
    // `-I` paths (it resolves them against the source file's directory,
    // not CWD), so the include roots are converted to absolute form
    // before being passed through. The shader `#include "Includes/..."`
    // directives are written relative to the Shaders root (the `-I`
    // target), matching how the module shaders are laid out.
    include_arg_module := fmt.aprintf("-I%s", absolute_include_root("../Engine/src/Modules/BF_GPU/Shaders"))
    include_arg_ext    := fmt.aprintf("-I%s", absolute_include_root("../Engine/src/Extensions/BF_GPU_Mesh/Shaders"))
    defer delete(include_arg_module)
    defer delete(include_arg_ext)

    stage_flag := stage_to_glslang_flag(shader.stage)
    if stage_flag == "" {
        fmt.eprintfln("Unknown shader stage for %s", shader.path)
        return
    }

    // Build argv in a [dynamic]string (heap-backed) instead of a
    // []string{...} literal. delete on a []string backing produced by
    // a slice literal has been observed to corrupt the heap on Windows
    // (STATUS_HEAP_CORRUPTION), likely because the compiler emits the
    // backing as a read-only constant. [dynamic] gives us a normal
    // heap allocation that delete() can safely free.
    argv_buf: [dynamic]string
    append(&argv_buf, "glslangValidator")
    append(&argv_buf, "-V")
    append(&argv_buf, "--target-env", "vulkan1.3")
    append(&argv_buf, "-S", stage_flag)
    append(&argv_buf, include_arg_module)
    append(&argv_buf, include_arg_ext)
    append(&argv_buf, "-o", output_abs)
    append(&argv_buf, shader.path)
    argv := argv_buf[:]
    defer delete(argv_buf)

    script := strings.join(argv, " ", context.allocator)
    defer delete(script)

    if err := rbs.run_argv(argv, script); err != nil {
        fmt.eprintfln("Shader compile failed: %s", shader.path)
    }
}