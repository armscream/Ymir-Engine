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
//   converts every search root to absolute before descending. Paths
//   handed to glslangValidator are still project-relative (computed
//   against CWD = <repo>/Project/rbs) so include resolution matches
//   what the engine runtime would do.

package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../Engine/src/Tools/rbs"
import rcp "../../Engine/src/Tools/rbs/rcp"

// SHADER_SEARCH_ROOTS_REL are PROJECT-RELATIVE paths rbs walks for
// shader sources. Resolved to absolute before read_dir (Windows).
@(private="file")
SHADER_SEARCH_ROOTS_REL :: []string{
	"../../Engine/src/Modules",
	"../../Engine/src/Extensions",
	"../../Engine/src/Plugins",
	"Project/Shaders",
}

// SHADER_DIR_NAME is the subdirectory inside each component
// that holds the shader tree.
@(private="file")
SHADER_DIR_NAME :: "Shaders"

// compile_shaders is the entry point invoked from pre_build_* in
// rbs.odin. It walks SHADER_SEARCH_ROOTS_REL, collects every shader
// file, and calls process_shader for each.
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

	discovered, ok := discover_shaders()
	if !ok {
		fmt.println("  [warn] shader discovery failed; check Engine/Modules and Engine/Extensions paths.")
		return
	}
	if discovered.count == 0 {
		fmt.println("  [skip] no shader sources discovered.")
		return
	}

	fmt.printfln("  Found %d shader source(s).", discovered.count)

	compiled, failed: int
	for idx in 0 ..< discovered.count {
		s := &discovered.infos[idx]
		had_output := output_exists(profile, s^)
		rcp.process_shader(profile, s^)
		has_output := output_exists(profile, s^)
		if !had_output {
			if has_output {
				compiled += 1
			} else {
				failed += 1
			}
		}
	}

	fmt.printfln("  Result: %d compiled, %d cached, %d failed", compiled, discovered.count - compiled - failed, failed)
	if failed > 0 {
		fmt.eprintfln("  [warn] %d shader(s) failed to compile; check the output above.", failed)
	}
}

// to_forward_slash replaces backslashes with forward slashes.
to_forward_slash :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "\\", "/")
	return out
}

// absolute_path returns the absolute form of `rel` against the
// current working directory. The result uses forward slashes.
absolute_path :: proc(rel: string) -> string {
	abs, err := filepath.abs(rel, context.allocator)
	if err != nil {
		return strings.clone(rel)
	}
	return to_forward_slash(abs)
}

// discover_shaders walks SHADER_SEARCH_ROOTS_REL (resolved against
// the CWD) and collects every shader file under
// `<root>/<name>/Shaders/`. The path stored on each Shader_Info is
// PROJECT-RELATIVE so glslangValidator can resolve its
// `#include "../../Includes/..."` directives.
//
// Implementation note: we use a fixed-size array of strings plus a
// parallel [dynamic]int index list rather than a [dynamic]Shader_Info
// because the latter has shown mysterious corruption under Odin
// when storing heap-cloned strings across array growth. Keeping the
// strings in a stable backing buffer eliminates the issue.
@(private)
DISCOVER_CAP :: 256

@(private="file")
Discover_Result :: struct {
	infos:  [DISCOVER_CAP]rcp.Shader_Info,
	count:  int,
}

discover_shaders :: proc() -> (result: Discover_Result, ok: bool) {
	root_ok := false
	for rel_root in SHADER_SEARCH_ROOTS_REL {
		if walk_root(rel_root, &result) {
			root_ok = true
		}
	}
	return result, root_ok
}

walk_root :: proc(rel_root: string, result: ^Discover_Result) -> bool {
	abs_root := absolute_path(rel_root)

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

		walk_shader_dir(shader_abs, rel_root, result)
		root_ok = true
	}

	return root_ok
}

walk_shader_dir :: proc(abs_dir: string, rel_root: string, result: ^Discover_Result) {
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
			walk_shader_dir(abs_full_fwd, rel_root, result)
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

		// Project-relative path (CWD is <repo>/Project/rbs).
		rel_path, rp_ok := make_relative_to_cwd(abs_full_fwd)
		if !rp_ok {
			fmt.eprintfln("  [warn] could not relativise shader path %s", abs_full_fwd)
			continue
		}
		defer delete(rel_path)

		if result.count >= DISCOVER_CAP {
			fmt.eprintfln("  [warn] shader discovery cap (%d) exceeded", DISCOVER_CAP)
			return
		}

		idx := result.count
		result.infos[idx] = rcp.Shader_Info{
			path   = strings.clone(rel_path),
			output = strings.clone(rcp.shader_output_path(rel_path)),
			type   = .Glsl,
			format = .SPIR_V,
			stage  = stage,
		}
		result.count += 1
	}
}

// run_shaders_only is the entry point for the `rune shaders` subcommand.
// It runs the same compile_shaders as the pre_build hook but with no
// surrounding build steps - useful for iterating on the shader
// pipeline when the rest of the build chain is broken upstream.
run_shaders_only :: proc(profile: rbs.Profile) {
	compile_shaders(profile)
}

// make_relative_to_cwd converts an absolute path under the same
// subtree as CWD to its PROJECT-RELATIVE form. For
//   abs_path = C:/.../Bifrost Engine/Engine/src/.../X.comp
//   cwd      = C:/.../Bifrost Engine/Project/rbs
// the result is "../../Engine/src/.../X.comp".
//
// The returned string is heap-allocated so the caller owns its
// lifetime and may `delete` it independently.
make_relative_to_cwd :: proc(abs_path: string) -> (string, bool) {
	cwd, _ := os.get_working_directory(context.allocator)
	defer delete(cwd)
	cwd_fwd := to_forward_slash(cwd)
	if len(cwd_fwd) > 1 && cwd_fwd[len(cwd_fwd)-1] == '/' {
		cwd_fwd = cwd_fwd[:len(cwd_fwd)-1]
	}

	cwd_parts := strings.split(cwd_fwd, "/")
	defer delete(cwd_parts)
	abs_parts := strings.split(abs_path, "/")
	defer delete(abs_parts)

	// Find longest common prefix component count.
	common := 0
	limit := min(len(cwd_parts), len(abs_parts))
	for i in 0 ..< limit {
		if cwd_parts[i] == abs_parts[i] {
			common = i + 1
		} else {
			break
		}
	}

	ups := len(cwd_parts) - common
	downs := len(abs_parts) - common

	buf: [dynamic]u8
	defer delete(buf)
	for _ in 0 ..< ups {
		append_elem_string(&buf, "../")
	}
	for i in 0 ..< downs {
		if i > 0 do append(&buf, '/')
		append_elem_string(&buf, abs_parts[i + common])
	}
	if len(buf) == 0 {
		append(&buf, '.')
	}
	return strings.clone(cast(string)buf[:]), true
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
output_exists :: proc(profile: rbs.Profile, s: rcp.Shader_Info) -> bool {
	abs := strings.join({profile.output, s.output}, "/")
	defer delete(abs)
	return os.exists(abs)
}