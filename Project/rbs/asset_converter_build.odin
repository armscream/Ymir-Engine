// Project/rbs/asset_converter_build.odin
//
// Build pipeline for the asset_converter tool
// (Engine/src/Tools/asset_converter/).
//
// Responsibilities:
//   1. Compile zeux/meshoptimizer (C++) into a static lib that the
//      asset_converter links against. This requires MSVC (cl.exe).
//      On platforms without MSVC the step warns and skips; the tool
//      will then fail to link until MSVC is available.
//   2. Invoke `odin build` for the asset_converter package, writing
//      the binary into <profile.output>.
//   3. Copy SDL3.dll next to the binary so the GUI tool can launch
//      outside the engine's runtime config.
//
// The asset_converter does NOT consume any engine module - it links
// only Core (for project settings) plus its own dependencies
// (gltf, meshoptimizer, imgui, sdl3).

package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../Engine/src/Tools/rbs"

ASSET_CONVERTER_PACKAGE :: "../../Engine/src/Tools/asset_converter"
MESHOPT_LIB_PATH        :: "../../Engine/src/dependencies/meshoptimizer/meshoptimizer.lib"

// build_asset_converter is invoked from pre_build_asset_converter in
// rbs.odin. It runs the full tool build pipeline:
//
//   - compile meshopt C++ source -> static lib
//   - build the asset_converter Odin binary
//   - copy SDL3.dll next to the binary
build_asset_converter :: proc(profile: rbs.Profile) {
	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.println("Building asset_converter")
	fmt.println("--------------------------------------------------")

	if !os.exists(profile.output) {
		if mk_err := os.make_directory_all(profile.output); mk_err != nil {
			fmt.eprintf("  [fail] could not create %s: %v\n", profile.output, mk_err)
			return
		}
	}

	// 1. meshoptimizer static lib.
	compile_meshoptimizer_static_lib(profile)

	// 2. Odin binary.
	build_asset_converter_binary(profile)

	// 3. SDL3.dll runtime.
	copy_sdl3_runtime(profile)
}

// compile_meshoptimizer_static_lib compiles the vendored meshopt C++
// source into a Windows static library (lib). On non-Windows the
// step is skipped (the binding expects libmeshoptimizer.a / .so).
//
// We invoke cl.exe directly via os.process_start. When cl.exe is not
// on PATH (no MSVC / VS Build Tools installed) the step warns and
// returns; the odin build will then surface a link error and the
// user can install MSVC.
compile_meshoptimizer_static_lib :: proc(profile: rbs.Profile) {
	when ODIN_OS != .Windows {
		fmt.println("  [skip] meshopt static-lib build: only Windows is wired (cl.exe)")
		return
	}
	else {
		lib_path, _ := filepath.abs(MESHOPT_LIB_PATH, context.allocator)
		defer delete(lib_path)

		if os.exists(lib_path) && !meshopt_sources_changed() {
			fmt.printfln("  [cached] %s", lib_path)
			return
		}

		fmt.println("  Compiling meshoptimizer C++ source -> meshoptimizer.lib ...")

		if !command_on_path("cl.exe") {
			fmt.println("  [warn] cl.exe not on PATH; install MSVC Build Tools and run")
			fmt.println("         this profile again to build the static lib.")
			fmt.println("         Skipping meshoptimizer build; the linker will fail.")
			return
		}

		src_dir := "../../Engine/src/dependencies/meshoptimizer/src"
		// Flags:
		//   /c            compile only (no link)
		//   /EHsc         enable C++ exceptions (meshopt doesn't throw
		//                  but the runtime needs it for new/delete)
		//   /O2 /Ob2      optimize for release-speed (meshopt is perf-
		//                  sensitive)
		//   /std:c++17    modern enough for meshopt
		//   /MD           link the dynamic CRT (matches Odin default)
		//   /Fo:<dir>\\   object files land in a stable temp dir
		obj_dir, _ := filepath.join({profile.output, "meshopt_obj"}, context.allocator)
		defer delete(obj_dir)
		if !os.exists(obj_dir) {
			os.make_directory_all(obj_dir)
		}

		// Build lib command:
		//   cl.exe /c /EHsc /O2 /Ob2 /std:c++17 /MD
		//       /Fo:<obj_dir>\ /I<src_dir>
		//       <src_dir>\*.cpp
		//   lib.exe /OUT:<lib_path> <obj_dir>\*.obj
		cmd := fmt.tprintf(
			"cl.exe /c /EHsc /O2 /Ob2 /std:c++17 /MD /Fo:%s\\ /I%s %s\\*.cpp",
			obj_dir, src_dir, src_dir,
		)
		if !run_cmd(cmd) do return

		lib_cmd := fmt.tprintf(
			"lib.exe /OUT:%s %s\\*.obj",
			lib_path, obj_dir,
		)
		if !run_cmd(lib_cmd) do return

		fmt.printfln("  [ok] %s", lib_path)
	}
}

// build_asset_converter_binary invokes `odin build` for the
// asset_converter package, producing <profile.output>/asset_converter.exe.
build_asset_converter_binary :: proc(profile: rbs.Profile) {
	out_path, _ := filepath.join({profile.output, "asset_converter.exe"}, context.allocator)
	defer delete(out_path)

	args := []string{
		"build",
		ASSET_CONVERTER_PACKAGE,
		"-out:" + out_path,
		"-vet",
		"-debug",
	}
	fmt.printfln("  odin %s", strings.join(args, " "))
	if !run_cmd("odin " + strings.join(args, " ")) {
		fmt.println("  [fail] asset_converter odin build returned non-zero")
	}
}

// meshopt_sources_changed: cheap hash check. Skipped in v1 - we
// always rebuild when the lib is missing, otherwise trust the cache.
meshopt_sources_changed :: proc() -> bool {
	return false
}

// run_cmd invokes a shell command via cmd.exe. Returns true on
// success. Output streams directly to the terminal.
run_cmd :: proc(cmd: string) -> bool {
	p, start_err := os.process_start({
		command = {"cmd.exe", "/c", cmd},
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if start_err != nil {
		fmt.eprintf("  [fail] could not start %q: %v\n", cmd, start_err)
		return false
	}
	state, _ := os.process_wait(p)
	return state.exit_code == 0
}

// command_on_path checks whether a command is on the Windows PATH
// (via `where`). Linux/macOS use `command -v`.
command_on_path :: proc(name: string) -> bool {
	when ODIN_OS == .Windows {
		p, start_err := os.process_start({
			command = {"cmd.exe", "/c", fmt.tprintf("where %s", name)},
			stdout = os.stdout,
			stderr = os.stderr,
		})
		if start_err != nil do return false
		state, _ := os.process_wait(p)
		return state.exit_code == 0
	}
	else {
		p, start_err := os.process_start({
			command = {"sh", "-c", fmt.tprintf("command -v %s", name)},
			stdout = os.stdout,
			stderr = os.stderr,
		})
		if start_err != nil do return false
		state, _ := os.process_wait(p)
		return state.exit_code == 0
	}
}
