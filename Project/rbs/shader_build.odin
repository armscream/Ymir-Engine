// Project/rbs/shader_build.odin
//
// Shader compile pipeline. Walks the engine shader trees, discovers
// every .comp/.vert/.frag/.task/.mesh shader, and produces SPIR-V
// (.spv) files under `<profile.output>/shaders/`. The layout mirrors
// the source tree so the renderer can resolve a source path like
// "Engine/src/Modules/BF_GPU/Shaders/Passes/Culling/Geometry/GeometryModelCulling.comp"
// to "shaders/Engine/src/Modules/BF_GPU/Shaders/Passes/Culling/Geometry/GeometryModelCulling.comp.spv"
// on disk.
//
// The hash cache (rcp/cache.odin) skips shaders whose content hash
// has not changed since the last build.
//
// glslangValidator is the compiler (Vulkan SDK). When missing the step
// warns and continues rather than failing the build - the Vulkan
// backend is still TODO and shader compilation is only needed once
// the backend lands.
//
// Windows path encoding note:
//   os.read_all_directory_by_path on Windows returns garbled UTF-16
//   bytes when given a relative path. The shader walker therefore
//   converts every search root to absolute before descending. The paths
//   handed to process_shader are still project-relative (so they
//   resolve identically for glslangValidator, which is also run from
//   the project root) - we just use them only for glslangValidator,
//   not for read_dir.

package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../Engine/src/Tools/rbs"
import rcp "../../Engine/src/Tools/rbs/rcp"

// SHADER_SEARCH_ROOTS are the PROJECT-RELATIVE paths rbs walks for
// shader sources. Resolved against the project root (rune.exe's CWD)
// at compile time so glslangValidator sees the same paths the rbs
// command runner emits.
@(private="file")
SHADER_SEARCH_ROOTS_REL :: []string{
    "../../Engine/src/Modules",
    "../../Engine/src/Extensions",
}

// SHADER_DIR_NAME is the subdirectory inside each module/extension
// that holds the shader tree.
@(private="file")
SHADER_DIR_NAME :: "Shaders"

// compile_shaders is the entry point invoked from pre_build_* in
// rbs.odin. It walks the SHADER_SEARCH_ROOTS_REL, collects every
// shader file, and calls process_shader for each.
compile_shaders :: proc(profile: rbs.Profile) {
    fmt.println("")
    fmt.println("--------------------------------------------------")
    fmt.println("Compiling shaders (GLSL -> SPIR-V)")
    fmt.println("--------------------------------------------------")

    if !glslang_validator_available() {
        fmt.println("  [skip] glslangValidator not found on PATH; shader compile skipped.")
        fmt.println("         (install the Vulkan SDK or `glslang-tools` package;")
        fmt.println("          compilation is required once the Vulkan backend lands.)")
        return
    }

    shaders, ok := discover_shaders()
    if !ok {
        fmt.println("  [warn] shader discovery failed; check Engine/Modules and Engine/Extensions paths.")
        return
    }
    if len(shaders) == 0 {
        fmt.println("  [skip] no shader sources discovered.")
        return
    }

    fmt.printfln("  Found %d shader source(s).", len(shaders))

    compiled, failed: int
    for s in shaders {
        had_output := output_exists(profile, s)
        rcp.process_shader(profile, s)
        has_output := output_exists(profile, s)
        if !had_output {
            if has_output {
                compiled += 1
            } else {
                failed += 1
            }
        }
    }

    fmt.printfln("  Result: %d compiled, %d cached, %d failed", compiled, len(shaders) - compiled - failed, failed)
    if failed > 0 {
        fmt.eprintfln("  [warn] %d shader(s) failed to compile; check the output above.", failed)
    }
}

// to_forward_slash replaces backslashes with forward slashes. On
// Windows, filepath.join emits backslashes; glslangValidator invoked
// from a Linux-style shell quoting layer prefers forward slashes.
to_forward_slash :: proc(s: string) -> string {
    out, _ := strings.replace_all(s, "\\", "/")
    return out
}

// absolute_path returns the absolute form of `rel` against the
// current working directory. The result uses forward slashes and
// has no trailing separator. On Windows we go through
// filepath.abs; on POSIX the CWD-relative form is already absolute.
absolute_path :: proc(rel: string) -> string {
    abs, err := filepath.abs(rel, context.allocator)
    if err != nil {
        return strings.clone(rel)
    }
    return to_forward_slash(abs)
}

// discover_shaders walks SHADER_SEARCH_ROOTS_REL (resolved against
// the project root) and collects every shader file under
// `<root>/<name>/Shaders/`. The path stored on each Shader_Info is
// PROJECT-RELATIVE so glslangValidator can resolve its
// `#include "../../Includes/..."` directives the same way the engine
// runtime would.
@(private="file")
discover_shaders :: proc() -> ([]rcp.Shader_Info, bool) {
    out := make([dynamic]rcp.Shader_Info, context.allocator)
    defer delete(out)

    root_ok := false
    for rel_root in SHADER_SEARCH_ROOTS_REL {
        if walk_root(rel_root, &out) {
            root_ok = true
        }
    }

    return out[:], root_ok
}

@(private="file")
walk_root :: proc(rel_root: string, out: ^[dynamic]rcp.Shader_Info) -> bool {
    abs_root := absolute_path(rel_root)

    // read_dir rejects relative paths on Windows; we must convert
    // before calling.
    entries, err := os.read_all_directory_by_path(abs_root, context.allocator)
    defer {
        if entries != nil {
            for e in entries {
                os.file_info_delete(e, context.allocator)
            }
            delete(entries)
        }
    }
    if err != nil {
        return false
    }

    root_ok := false
    for entry in entries {
        if entry.type != .Directory do continue

        module_abs, mj_err := filepath.join({abs_root, entry.name}, context.allocator)
        if mj_err != nil do continue
        defer delete(module_abs)

        shader_abs, sj_err := filepath.join({module_abs, SHADER_DIR_NAME}, context.allocator)
        if sj_err != nil do continue
        defer delete(shader_abs)

        if !os.exists(shader_abs) do continue

        // Recurse using the ABSOLUTE path so nested reads also work
        // on Windows.
        walk_shader_dir(shader_abs, rel_root, out)
        root_ok = true
    }

    return root_ok
}

@(private="file")
walk_shader_dir :: proc(abs_dir: string, rel_root: string, out: ^[dynamic]rcp.Shader_Info) {
    files, err := os.read_all_directory_by_path(abs_dir, context.allocator)
    defer {
        if files != nil {
            for f in files {
                os.file_info_delete(f, context.allocator)
            }
            delete(files)
        }
    }
    if err != nil {
        fmt.eprintfln("  [warn] cannot read shader directory %s: %v", abs_dir, err)
        return
    }

    for f in files {
        abs_full, fj_err := filepath.join({abs_dir, f.name}, context.allocator)
        if fj_err != nil do continue
        defer delete(abs_full)

        abs_full_fwd := to_forward_slash(abs_full)

        if f.type == .Directory {
            walk_shader_dir(abs_full_fwd, rel_root, out)
            continue
        }
        if f.type != .Regular do continue

        if !rcp.is_shader_file(abs_full_fwd) do continue

        ext := filepath.ext(f.name)
        stage := rcp.stage_from_extension(ext)
        if stage == .Unknown {
            fmt.eprintfln("  [warn] unrecognised shader extension on %s", abs_full_fwd)
            continue
        }

        // Build the PROJECT-RELATIVE path used by glslangValidator.
        // abs_full_fwd looks like:
        //   C:/Users/.../Bifrost Engine/Engine/src/Modules/BF_GPU/Shaders/Passes/.../X.comp
        // We want:
        //   ../../Engine/src/Modules/BF_GPU/Shaders/Passes/.../X.comp
        // The rbs runner is launched from <repo>/Project/rbs, so two
        // `../` bring us back to the repo root.
        rel_path, rp_ok := make_relative_to_repo(abs_full_fwd)
        if !rp_ok {
            fmt.eprintfln("  [warn] could not relativise shader path %s", abs_full_fwd)
            continue
        }
        defer delete(rel_path)

        append(out, rcp.Shader_Info{
            path   = rel_path,
            output = rcp.shader_output_path(rel_path),
            type   = .Glsl,
            format = .SPIR_V,
            stage  = stage,
        })
    }
}

// repo_root_abs is the absolute path of the repo root (the parent
// of the project root). Shader paths are anchored here so the
// on-disk mirror in `<profile.output>/shaders/...` mirrors the repo
// tree, not the project tree.
//
// CWD when rune runs is `<repo>/Project/rbs`, so the repo root is
// `cwd/../..`.
@(private="file")
repo_root_abs: string
repo_root_abs_resolved := false

repo_root :: proc() -> string {
    if repo_root_abs_resolved do return repo_root_abs
    cwd, _ := os.get_working_directory(context.allocator)
    repo_root_abs, _ = filepath.join({cwd, "..", ".."}, context.allocator)
    repo_root_abs = to_forward_slash(repo_root_abs)
    repo_root_abs_resolved = true
    return repo_root_abs
}

// make_relative_to_repo converts an absolute path under the repo
// tree to its repo-relative form (e.g.
// "Engine/src/Modules/BF_GPU/Shaders/Passes/.../X.comp"). Returns
// false if the path lies outside the repo tree.
make_relative_to_repo :: proc(abs_path: string) -> (string, bool) {
    root := repo_root()
    if !strings.has_prefix(abs_path, root) {
        return abs_path, false
    }
    rel := abs_path[len(root)+1:] // +1 to drop the trailing slash
    return rel, true
}

@(private="file")
Glslang_Probe :: enum {
    Unknown,
    Available,
    Missing,
}
GLSLANG_PROBE_VALUE := Glslang_Probe.Unknown

// glslang_validator_available probes PATH + VULKAN_SDK for the
// glslangValidator executable. Cached after the first probe per
// build session.
glslang_validator_available :: proc() -> bool {
    if GLSLANG_PROBE_VALUE != .Unknown {
        return GLSLANG_PROBE_VALUE == .Available
    }

    candidates := []string{"glslangValidator", "glslangValidator.exe"}
    for c in candidates {
        probe_path, ok := os.lookup_env_alloc("PATH", context.allocator)
        if !ok || len(probe_path) == 0 do continue
        defer delete(probe_path)

        for dir in strings.split(probe_path, string(os.Path_Separator_String)) {
            full, _ := filepath.join({dir, c}, context.allocator)
            defer delete(full)
            if len(full) > 0 && os.exists(full) {
                GLSLANG_PROBE_VALUE = .Available
                return true
            }
        }
    }

    sdk_envs := []string{"VULKAN_SDK", "VK_SDK_PATH"}
    for env in sdk_envs {
        sdk, ok := os.lookup_env_alloc(env, context.allocator)
        if !ok || len(sdk) == 0 do continue
        defer delete(sdk)

        candidate, _ := filepath.join({sdk, "Bin", "glslangValidator.exe"}, context.allocator)
        defer delete(candidate)
        if len(candidate) > 0 && os.exists(candidate) {
            GLSLANG_PROBE_VALUE = .Available
            return true
        }
    }

    GLSLANG_PROBE_VALUE = .Missing
    return false
}

// output_exists checks whether the .spv output is on disk for the
// given shader.
@(private="file")
output_exists :: proc(profile: rbs.Profile, s: rcp.Shader_Info) -> bool {
    abs := strings.join({profile.output, s.output}, "/")
    defer delete(abs)
    return os.exists(abs)
}