package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../Engine/src/Tools/rbs"
import toml "../../Engine/src/dependencies/toml_parser"

import "../../Engine/src/Core"


// ============================================================================
// PROJECT CONFIGURATION
// ============================================================================
//
// The project configuration schema is owned by the engine
// (Engine/src/Core/engine.odin). We import and reuse those types here so the
// build system and runtime always agree on what project.toml contains.
//


// ============================================================================
// PROJECT PATHS
// ============================================================================
//
// IMPORTANT:
//
// rune.exe lives at the project root and chdirs into it at startup (see
// main()). After that, all relative paths below are anchored to the project
// root, so this code is correct no matter what the project folder is called
// or where the user invoked rune from.
//
// Project layout:
//
//     Ymir Engine/
//     ├── Engine/
//     │   └── src/
//     │       └── Modules/
//     │
//     ├── Project/
//     │   ├── config/
//     │   ├── modules/
//     │   ├── bin/
//     │   └── rbs/
//     │       └── rbs.odin
//     │
//     └── Tools/
//         └── rbs/
//
// ============================================================================

PROJECT_CONFIG_PATH :: "../config/project.toml"

ENGINE_MODULES_PATH    :: "../../Engine/src/Modules"
PROJECT_MODULES_PATH   :: "../modules"

ENGINE_EXTENSIONS_PATH :: "../../Engine/src/Extensions"
PROJECT_EXTENSIONS_PATH :: "../extensions"

ENGINE_PLUGINS_PATH    :: "../../Engine/src/Plugins"
PROJECT_PLUGINS_PATH   :: "../plugins"

DEBUG_OUTPUT_PATH   :: "../bin/Debug"
EDITOR_OUTPUT_PATH  :: "../bin/Editor"
RELEASE_OUTPUT_PATH :: "../bin/Release"

// Stable, filename-safe identifiers used for profile-aware switches below.
// The executable output name (`Profile.name`) is built from `project_name`
// and may contain spaces; use these constants when matching a profile by
// identity instead of by display name.
DEBUG_NAME   :: "Debug"
EDITOR_NAME  :: "Editor"
RELEASE_NAME :: "Release"

ConfigState :: enum {
	None, // none found, continue and lets the engine create one
	Failed,
	Loaded, // loaded successfully
}
CONFIG_STATE := ConfigState.None
// ============================================================================
// GLOBAL CONFIGURATION
// ============================================================================
//
// RBS pre-build callbacks only receive Context + Profile.
//
// The project configuration is therefore loaded once and kept here for the
// duration of the RBS process.
//
project_config: Core.Project_Settings


// ============================================================================
// FATAL ERROR
// ============================================================================
fatal :: proc(message: string) -> ! {
	log.error(message)
	os.exit(1)
}


// ============================================================================
// PATH JOIN
// ============================================================================
join_project_path :: proc(a: string, b: string) -> string {
	result, err := filepath.join({a, b}, context.allocator)
	if err != nil {
		fatal(fmt.aprintf("Could not join paths:\n  %s\n  %s\n  %s", a, b, err))
	}

	return result
}


// ============================================================================
// COMMAND PATH
// ============================================================================
//
// RBS currently executes commands by splitting them on spaces.
//
// Because the repository itself is located at:
//
//     Ymir Engine
//
// absolute paths would introduce spaces into the Odin command.
//
// Therefore commands use repository-relative paths:
//
//     ../../Engine/src/Modules/...
//     ../bin/Editor/...
//
// Both contain no spaces.
//
command_path :: proc(path: string) -> string {
	result := strings.clone(path)

	result, _ = strings.replace(result, "\\", "/", -1)

	return result
}


// ============================================================================
// LOAD PROJECT CONFIGURATION
// ============================================================================
load_project_config :: proc() -> Core.Project_Settings {
	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.println("Loading project configuration")
	fmt.println("--------------------------------------------------")

	if !os.exists(PROJECT_CONFIG_PATH) {
		// No project.toml on disk: ask Core to seed its in-memory
		// defaults, then persist that default file to Project/config/
		// so the engine can find it next launch. pre_build_*
		// calls seed_default_project_config to actually write the
		// file; we just need to keep CONFIG_STATE = .Loaded so
		// pre_build runs (don't bail with .None).
		log.warn("Project configuration not found: %s", PROJECT_CONFIG_PATH)
		log.warn("Seeding defaults via Core.inject_default_project_settings().")

		Core.inject_default_project_settings()
		CONFIG_STATE = .Loaded
		return Core.project_settings_get()^
	}

	// ------------------------------------------------------------------------
	// Read file
	// ------------------------------------------------------------------------
	data, read_err := os.read_entire_file(PROJECT_CONFIG_PATH, context.allocator)
	config: Core.Project_Settings

	if read_err != nil {
		log.error("Could not read project configuration:\n  %s", read_err)
		CONFIG_STATE = .Failed
		return config
	}

	defer delete(data)

	// ------------------------------------------------------------------------
	// Parse TOML
	// ------------------------------------------------------------------------
	toml_err := toml.unmarshal(data, &config)

	if toml_err != nil {
		log.error("Could not parse project configuration:\n  %s", toml_err)
		CONFIG_STATE = .Failed
		return config
	}

	fmt.printfln("  Project: %s", config.project_name)

	fmt.printfln(
		"  Version: v%d.%d.%d",
		config.version.major,
		config.version.minor,
		config.version.patch,
	)
	CONFIG_STATE = .Loaded
	return config
}


// ============================================================================
// CLEANUP PROJECT CONFIGURATION
// ============================================================================
//
// Core.Project_Settings owns three [dynamic] arrays TOML unmarshalling fills
// them with heap allocations that we own. Free them here.
//
cleanup_project_config :: proc(s: ^Core.Project_Settings) {
	delete(s.modules)
	delete(s.extensions)
	delete(s.plugins)
}


// ============================================================================
// NORMALIZE MODULE NAME
// ============================================================================
//
// Accepts:
//
//     Bifrost_Renderer
//
// or:
//
//     Bifrost_Renderer.dll
//
// Internally:
//
//     Bifrost_Renderer
//

normalize_module_name :: proc(input: string) -> string {
	module := strings.clone(input)

	if strings.has_suffix(module, ".dll") {
		module = strings.trim_suffix(module, ".dll")
	}

	return module
}


// ============================================================================
// RESOLVE COMPONENT SOURCE
// ============================================================================
//
// Each component kind has its own project/engine source roots. Search
// order is the same for every kind:
//
//     1. Project/<kind>s/<name>
//     2. Engine/src/<Kind>s/<name>
//
// Project sources override engine sources of the same name.
//
// IMPORTANT:
//
// These return RELATIVE paths. Do not convert them to absolute paths
// because the RBS command runner currently splits commands on spaces.
//

resolve_module_source :: proc(input: string) -> string {
	return _resolve_component_source(input, "module", PROJECT_MODULES_PATH, ENGINE_MODULES_PATH)
}

resolve_extension_source :: proc(input: string) -> string {
	return _resolve_component_source(input, "extension", PROJECT_EXTENSIONS_PATH, ENGINE_EXTENSIONS_PATH)
}

resolve_plugin_source :: proc(input: string) -> string {
	return _resolve_component_source(input, "plugin", PROJECT_PLUGINS_PATH, ENGINE_PLUGINS_PATH)
}

@(private)
_resolve_component_source :: proc(input, kind, project_root, engine_root: string) -> string {
	name := normalize_module_name(input)

	// ------------------------------------------------------------------------
	// Project override
	// ------------------------------------------------------------------------

	project_source := join_project_path(project_root, name)

	if os.exists(project_source) && os.is_dir(project_source) {
		fmt.printfln("    Project %s: %s", kind, project_source)
		return project_source
	}

	// ------------------------------------------------------------------------
	// Engine fallback
	// ------------------------------------------------------------------------

	engine_source := join_project_path(engine_root, name)

	if os.exists(engine_source) && os.is_dir(engine_source) {
		fmt.printfln("    Engine %s:  %s", kind, engine_source)
		return engine_source
	}

	// ------------------------------------------------------------------------
	// Not found
	// ------------------------------------------------------------------------
	fatal(
		fmt.aprintf(
			"ERROR: Required %s source was not found:\n\n" +
			"  %s\n\n" +
			"Searched:\n" +
			"  %s\n" +
			"  %s",
			kind,
			name,
			project_source,
			engine_source,
		),
	)
}


// ============================================================================
// BUILD ONE COMPONENT DLL
// ============================================================================
//
// `kind_label` is the human label printed in the section header
// ("module", "extension", "plugin"). `source_resolver` looks up the
// source directory for the component. Everything else — output paths,
// flags, command construction, verification — is identical for every
// component kind because every kind is just an Odin -build-mode:dll.
//
build_component :: proc(
	input, kind_label: string,
	source_resolver: proc(string) -> string,
	profile: rbs.Profile,
) {
	if input == "" {
		return
	}

	name := normalize_module_name(input)

	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.printfln("Building %s: %s", kind_label, name)
	fmt.println("--------------------------------------------------")

	// ------------------------------------------------------------------------
	// Resolve source
	// ------------------------------------------------------------------------

	source := source_resolver(name)

	fmt.printfln("  Source: %s", source)

	// ------------------------------------------------------------------------
	// DLL output
	// ------------------------------------------------------------------------

	dll_name := fmt.aprintf("%s.dll", name)

	defer delete(dll_name)

	output := join_project_path(profile.output, dll_name)

	fmt.printfln("  Output: %s", output)

	// ------------------------------------------------------------------------
	// Ensure output directory
	// ------------------------------------------------------------------------

	if !os.exists(profile.output) {
		err := os.make_directory_all(profile.output)

		if err != nil {
			fatal(
				fmt.aprintf(
					"ERROR: Could not create output directory:\n" + "  %s\n" + "  %s",
					profile.output,
					err,
				),
			)
		}
	}

	// ------------------------------------------------------------------------
	// Remove old DLL
	// ------------------------------------------------------------------------
	//
	// This is important.
	//
	// Otherwise Odin can fail while an old DLL remains on disk and the build
	// system could incorrectly report success merely because the DLL exists.
	//

	if os.exists(output) {
		remove_err := os.remove(output)

		if remove_err != nil {
			fatal(
				fmt.aprintf(
					"ERROR: Could not remove previous component DLL:\n\n" + "  %s\n\n" + "  %s",
					output,
					remove_err,
				),
			)
		}
	}

	// ------------------------------------------------------------------------
	// Build flags
	// ------------------------------------------------------------------------
	//
	// Do NOT inherit profile.flags.
	//
	// EDITOR contains:
	//
	//     -define:RUN_EDITOR=true
	//
	// That define belongs to the executable, not the component DLL.
	//
	// We also pass `-define:BUILDING_<NAME>_DLL=true` so that the
	// component's @export gate (see each mod.odin's `when BUILDING_...`)
	// is set ONLY when that specific DLL is being built. When another
	// component (e.g. an extension) imports this package, the flag is
	// absent and the @export proc is not emitted, so we don't get a
	// duplicate-symbol link error. rbs generates the flag uniformly
	// from the DLL name — no per-module hand-maintenance.
	//

	mode_flag := "-debug"
	if strings.contains(profile.flags, "-release") {
		mode_flag = "-release"
	}
	component_flags := fmt.tprintf("%s -define:BUILDING_%s_DLL=true", mode_flag, strings.to_upper(name))

	// ------------------------------------------------------------------------
	// Convert paths for Odin command
	// ------------------------------------------------------------------------

	command_source := command_path(source)
	command_output := command_path(output)

	// ------------------------------------------------------------------------
	// Construct command
	// ------------------------------------------------------------------------
	//
	// No quotes are used because the current RBS runner splits commands on
	// spaces. The relative paths contain no spaces.
	//

	command := fmt.aprintf(
		"odin build %s -build-mode:dll -out:%s %s",
		command_source,
		command_output,
		component_flags,
	)

	defer delete(command)

	fmt.printfln("  Command: %s", command)

	// ------------------------------------------------------------------------
	// Run Odin
	// ------------------------------------------------------------------------
	err := rbs.run_script(command)

	if err != nil {
		fatal(
			fmt.aprintf(
				"ERROR: Failed to build %s:\n\n" +
				"  %s\n\n" +
				"Source:\n" +
				"  %s\n\n" +
				"Command:\n" +
				"  %s\n\n" +
				"RBS error:\n" +
				"  %s",
				kind_label,
				name,
				source,
				command,
				err,
			),
		)
	}

	// ------------------------------------------------------------------------
	// Verify DLL
	// ------------------------------------------------------------------------
	if !os.exists(output) {
		fatal(
			fmt.aprintf(
				"ERROR: Odin finished, but the DLL was not produced:\n\n" + "  %s",
				output,
			),
		)
	}

	fmt.printfln("  SUCCESS: %s", output)
}

// Backwards-compatible alias — older callers used build_module.
build_module :: proc(input: string, profile: rbs.Profile) {
	build_component(input, "module", resolve_module_source, profile)
}

build_extension :: proc(input: string, profile: rbs.Profile) {
	build_component(input, "extension", resolve_extension_source, profile)
}

build_plugin :: proc(input: string, profile: rbs.Profile) {
	build_component(input, "plugin", resolve_plugin_source, profile)
}


// ============================================================================
// EDITOR MODULE NAME
// ============================================================================
//
// The Editor entry lives in settings.modules. A single constant lets us filter
// it consistently for non-editor profiles.
//
EDITOR_MODULE_NAME :: "BF_Editor"


// ============================================================================
// SHOULD BUILD MODULE
// ============================================================================
//
// Centralized gating policy for a (module, profile) pair.
//
//   - If the module is disabled in project.toml, skip it.
//   - If the module is the Editor and the profile is not the editor build,
//     skip it. The Editor DLL only ships with the editor executable.
//
should_build_module :: proc(name: string, enabled: bool, profile_output: string) -> bool {
	if !enabled do return false
	if name == EDITOR_MODULE_NAME && profile_output != EDITOR_OUTPUT_PATH do return false
	return true
}


// ============================================================================
// BUILD MODULES
// ============================================================================
build_modules :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) {
	fmt.println("")
	fmt.println("==================================================")
	fmt.println(" ENGINE MODULES")
	fmt.println("==================================================")

	for m in settings.modules {
		if !should_build_module(m.name, m.enabled, profile.output) do continue
		build_module(m.name, profile)
	}
}


// ============================================================================
// BUILD EXTENSIONS
// ============================================================================
//
// Each enabled extension in project.toml becomes a DLL built from
// Project/extensions/<name> (project override) or
// Engine/src/Extensions/<name> (engine fallback).
//
build_extensions :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) {
	if len(settings.extensions) == 0 {
		return
	}

	fmt.println("")
	fmt.println("==================================================")
	fmt.println(" EXTENSIONS")
	fmt.println("==================================================")

	for e in settings.extensions {
		if !e.enabled do continue
		build_extension(e.name, profile)
	}
}


// ============================================================================
// BUILD PLUGINS
// ============================================================================
//
// Each enabled plugin in project.toml becomes a DLL built from
// Project/plugins/<name> or Engine/src/Plugins/<name>. Currently the
// plugin ABI is stubbed in Core (plugins.odin); this still produces a
// DLL so the loader finds it when the plugin path is wired.
//
build_plugins :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) {
	if len(settings.plugins) == 0 {
		return
	}

	fmt.println("")
	fmt.println("==================================================")
	fmt.println(" PLUGINS")
	fmt.println("==================================================")

	for p in settings.plugins {
		if !p.enabled do continue
		build_plugin(p.name, profile)
	}
}


// ============================================================================
// COPY CONFIGURATION
// ============================================================================
//
// From:
//
//     Project/config
//
// To:
//
//     Project/bin/<Profile>/config
//
// Since RBS executes from:
//
//     Project/rbs
//
// the source path is:
//
//     ../config
//
// and the destination is relative to profile.output:
//
//     config
//

copy_project_config :: proc(profile: rbs.Profile) {
	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.println("Copying project configuration")
	fmt.println("--------------------------------------------------")

	err := rbs.copy(profile, "../config", "config")

	if err != nil {
		fatal(
			fmt.aprintf(
				"ERROR: Failed to copy project configuration:\n\n" +
				"  Source: ../config\n" +
				"  Destination: %s/config\n" +
				"  Error: %s",
				profile.output,
				err,
			),
		)
	}

	fmt.printfln("  ../config -> %s/config", profile.output)
}

copy_project_scripts :: proc(profile: rbs.Profile) {
	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.println("Copying project scripts")
	fmt.println("--------------------------------------------------")

	err := rbs.copy(profile, "../scripts", "scripts")

	if err != nil {
		fatal(
			fmt.aprintf(
				"ERROR: Failed to copy project scripts:\n\n" +
				"  Source: ../scripts\n" +
				"  Destination: %s/scripts\n" +
				"  Error: %s",
				profile.output,
				err,
			),
		)
	}

	fmt.printfln("  ../assets -> %s/assets", profile.output)
}

copy_project_assets :: proc(profile: rbs.Profile) {
	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.println("Copying project assets")
	fmt.println("--------------------------------------------------")

	err := rbs.copy(profile, "../assets", "assets")

	if err != nil {
		fatal(
			fmt.aprintf(
				"ERROR: Failed to copy project assets:\n\n" +
				"  Source: ../assets\n" +
				"  Destination: %s/assets\n" +
				"  Error: %s",
				profile.output,
				err,
			),
		)
	}

	fmt.printfln("  ../assets -> %s/assets", profile.output)
}


// ============================================================================
// NATIVE RUNTIME LIBRARIES (SDL3.dll)
// ============================================================================
//
// Modules built against `vendor:sdl3` link against `SDL3.lib` at build
// time, but at runtime the resulting DLL has a soft dependency on
// `SDL3.dll`. The Windows DLL loader searches:
//   1. The directory of the loaded module (bin/<config>/)
//   2. The current working directory
//   3. System directories + PATH
//
// Running the engine from the project root with CWD != bin/<config>
// makes #1 miss and #2 unreliable. The safest fix is to deploy SDL3.dll
// into the profile output directory alongside the built engine binary.
//
// On Linux/macOS `vendor:sdl3` links against `system:SDL3` (no DLL to
// copy), so this step is a no-op there.

// find_odin_root locates the Odin installation by running `odin root`
// and reading stdout. Returns "" on failure. Prefer the ODIN_ROOT env
// var if set (some CI / package managers set it explicitly).
@(private)
find_odin_root :: proc() -> string {
	if env_root, ok := os.lookup_env_alloc("ODIN_ROOT", context.allocator); ok {
		defer delete(env_root)
		root := strings.trim_space(env_root)
		if len(root) > 0 do return root
	}

	stdout_r, stdout_w, _ := os.pipe()
	defer os.close(stdout_r)

	p, start_err := os.process_start({
		command = {"odin", "root"},
		stdout  = stdout_w,
	})
	if start_err != nil do return ""

	state, _ := os.process_wait(p)
	os.close(stdout_w)
	if state.exit_code != 0 do return ""

	buf: [4096]u8
	n, read_err := os.read(stdout_r, buf[:])
	if read_err != nil || n <= 0 do return ""

	// `odin root` prints the path with a trailing newline; strip it.
	return strings.trim_space(string(buf[:n]))
}

// copy_sdl3_runtime copies SDL3.dll from `<odin_root>/vendor/sdl3/` to
// `<profile.output>/`. Silently no-ops if the source file doesn't
// exist (e.g. platforms where SDL3 is system-linked rather than
// vendored). Logs a warning and returns on copy failure so a missing
// DLL doesn't fail the build outright.
copy_sdl3_runtime :: proc(profile: rbs.Profile) {
	fmt.println("")
	fmt.println("--------------------------------------------------")
	fmt.println("Copying native runtime libraries")
	fmt.println("--------------------------------------------------")

	root := find_odin_root()
	if len(root) == 0 {
		fmt.println("  [warn] could not locate Odin root (ODIN_ROOT / `odin root` failed); SDL3.dll not deployed")
		return
	}

	src_path: string
	src_path, _ = filepath.join({root, "vendor", "sdl3", "SDL3.dll"}, context.allocator)
	defer delete(src_path)

	if !os.exists(src_path) {
		// Not all Odin installs ship the sdl3 vendor directory (e.g.
		// older builds, custom installs). On Linux/macOS the SDL3
		// binding links via system:SDL3 so there's nothing to copy.
		fmt.printfln("  [skip] %s not found (system-linked or non-vendored SDL3)", src_path)
		return
	}

	dst_path: string
	dst_path, _ = filepath.join({profile.output, "SDL3.dll"}, context.allocator)
	defer delete(dst_path)

	if copy_err := os.copy_file(dst_path, src_path); copy_err != nil {
		fmt.eprintf("  [warn] failed to copy SDL3.dll (%s -> %s): %s\n", src_path, dst_path, copy_err)
		return
	}

	fmt.printfln("  %s -> %s", src_path, dst_path)
}


// ============================================================================
// VERIFY MANIFESTS
// ============================================================================
//
// Runs `rbs manifest codegen --check` semantics: every package on disk
// must produce a <PackageName>.toml that matches what its IDENTITY/
// DEPENDENCIES blocks declare. Fails the build if anything is stale or
// missing.

verify_manifests :: proc() {
    if rbs.manifest_codegen_run_check() != 0 {
        fatal(
            "ERROR: Manifest check failed. Run `rune manifest` to regenerate, " +
            "or fix the offending IDENTITY/DEPENDENCIES blocks before building.",
        )
    }
}


// ============================================================================
// SEED DEFAULT PROJECT CONFIG
// ============================================================================
//
// When Project/config/project.toml is missing, write one based on Core's
// already-populated defaults. The default injection happens ONCE — in
// load_project_config when it detects the missing file. This proc only
// persists what is already in GLOBAL_PROJECT_SETTINGS; calling inject
// again here would double the default module/extension/plugin entries.
//
// Core's render_project_settings_toml helper is the canonical writer; we
// just provide the path plumbing here.
//
seed_default_project_config :: proc() {
    if os.exists(PROJECT_CONFIG_PATH) do return

    fmt.println("")
    fmt.println("--------------------------------------------------")
    fmt.println("Seeding default project configuration")
    fmt.println("--------------------------------------------------")

    // os.write_entire_file only creates the file itself; we ensure the
    // parent dir (Project/config/) exists here. os.make_directory_all is
    // a no-op if the path already exists.
    if mkdir_err := os.make_directory_all("../config"); mkdir_err != nil {
        log.warnf("Could not create ../config: %v", mkdir_err)
        return
    }

    toml_text := Core.render_project_settings_toml(Core.project_settings_get()^)
    defer delete(toml_text)

    if write_err := os.write_entire_file(PROJECT_CONFIG_PATH, transmute([]byte)toml_text); write_err != nil {
        log.warnf("Could not write default %s: %v", PROJECT_CONFIG_PATH, write_err)
        return
    }
    fmt.printfln("  Wrote default project configuration to %s", PROJECT_CONFIG_PATH)
}


// ============================================================================
// DEBUG PRE-BUILD
// ============================================================================

pre_build_debug :: proc(ctx: rbs.Context, profile: rbs.Profile) {
	_ = ctx

	seed_default_project_config()

	verify_manifests()

	build_modules(&project_config, profile)

	build_extensions(&project_config, profile)

	build_plugins(&project_config, profile)

	compile_shaders(profile)

	copy_project_config(profile)

	copy_project_scripts(profile)

	copy_project_assets(profile)

	copy_sdl3_runtime(profile)
}


// ============================================================================
// EDITOR PRE-BUILD
// ============================================================================

pre_build_editor :: proc(ctx: rbs.Context, profile: rbs.Profile) {
	_ = ctx

	seed_default_project_config()

	verify_manifests()

	build_modules(&project_config, profile)

	build_extensions(&project_config, profile)

	build_plugins(&project_config, profile)

	compile_shaders(profile)

	copy_project_config(profile)

	copy_project_scripts(profile)

	copy_project_assets(profile)

	copy_sdl3_runtime(profile)
}


// ============================================================================
// RELEASE PRE-BUILD
// ============================================================================

pre_build_release :: proc(ctx: rbs.Context, profile: rbs.Profile) {
	_ = ctx

	seed_default_project_config()

	verify_manifests()

	build_modules(&project_config, profile)

	build_extensions(&project_config, profile)

	build_plugins(&project_config, profile)

	compile_shaders(profile)

	copy_project_config(profile)

	copy_project_scripts(profile)

	copy_project_assets(profile)

	copy_sdl3_runtime(profile)
}


// ============================================================================
// PRE-BUILD DISPATCH
// ============================================================================

pre_build :: proc(ctx: rbs.Context, profile: rbs.Profile) {
	switch profile.output {
	case DEBUG_OUTPUT_PATH:
		pre_build_debug(ctx, profile)

	case EDITOR_OUTPUT_PATH:
		pre_build_editor(ctx, profile)

	case RELEASE_OUTPUT_PATH:
		pre_build_release(ctx, profile)

	case:
		fatal(fmt.aprintf("ERROR: Unknown build profile: %s", profile.output))
	}
}


// ============================================================================
// MAIN
// ============================================================================

main :: proc() {
	context.logger = log.create_console_logger()

	// ------------------------------------------------------------------------
	// PROJECT ROOT
	// ------------------------------------------------------------------------
	//
	// rune.exe always lives at the root of the project directory, alongside
	// rbs/, config/, modules/, etc. All relative paths in this file are
	// written from the rbs/ subdirectory (so `../` is the project root and
	// `../../` is the engine root). Resolve the executable directory and
	// chdir into <project_root>/rbs/ so those paths stay valid regardless of
	// the project's folder name or where the user invoked rune from.
	//
	exe_dir, exe_err := os.get_executable_directory(context.allocator)
	if exe_err == nil {
		build_dir, join_err := filepath.join({exe_dir, "rbs"}, context.allocator)
		delete(exe_dir)
		if join_err == nil {
			if chdir_err := os.chdir(build_dir); chdir_err != nil {
				log.warnf(
					"Could not chdir to project build directory (%s): %s",
					build_dir,
					chdir_err,
				)
			}
			delete(build_dir)
		} else {
			log.warnf("Could not resolve build directory path: %s", join_err)
		}
	} else {
		log.warnf("Could not determine executable directory: %s", exe_err)
	}

	// ------------------------------------------------------------------------
	// RBS context
	// ------------------------------------------------------------------------
	ctx := rbs.init_context()
	defer rbs.dispose_context(ctx)

	// ------------------------------------------------------------------------
	// Load project configuration
	// ------------------------------------------------------------------------
	project_config = load_project_config()

	// Free the dynamic arrays owned by Core.Project_Settings at exit. Safe to
	// call on the zero-value returned by the .None / failed-read paths.
	defer cleanup_project_config(&project_config)

	// ========================================================================
	// DEBUG PROFILE
	// ========================================================================
	rbs.add_profile(
		&ctx,
		"DEBUG",
		{
			entry = "..",
			flags = "-vet -debug",
			mode = .Executable,
			name = fmt.aprintf("%s - Debug", project_config.project_name),   
			output = DEBUG_OUTPUT_PATH,
			arch = ODIN_ARCH,
			os = ODIN_OS,
		},
	)

	// ========================================================================
	// EDITOR PROFILE
	// ========================================================================

	rbs.add_profile(
		&ctx,
		"EDITOR",
		{
			entry = "..",
			flags = "-vet -debug -define:RUN_EDITOR=true",
			mode = .Executable,
			name = fmt.aprintf("%s - Editor", project_config.project_name),
			output = EDITOR_OUTPUT_PATH,
			arch = ODIN_ARCH,
			os = ODIN_OS,
		},
	)

	// ========================================================================
	// RELEASE PROFILE
	// ========================================================================

	rbs.add_profile(
		&ctx,
		"RELEASE",
		{
			entry = "..",
			flags = "-vet -release",
			mode = .Executable,
			name = project_config.project_name,
			output = RELEASE_OUTPUT_PATH,
			arch = ODIN_ARCH,
			os = ODIN_OS,
		},
	)

	switch CONFIG_STATE {
	case .None:
		log.warn("Starting engine without project.toml..")
		return
	case .Failed:
		log.error(
			"Failed to load project configuration, please check your project.toml file format.",
		)
		log.destroy_console_logger(context.logger)
		os.exit(1)
	case .Loaded:
		log.info("Loaded project configuration.")
		// ------------------------------------------------------------------------
		// Header
		// ------------------------------------------------------------------------

		fmt.println("")
		fmt.println("==================================================")
		fmt.println(" Odin Practice Build System")
		fmt.println("==================================================")

		fmt.printfln(" Project: %s", project_config.project_name)

		fmt.printfln(
			" Version: v%d.%d.%d",
			project_config.version.major,
			project_config.version.minor,
			project_config.version.patch,
		)

		fmt.printfln(" Config:  %s", PROJECT_CONFIG_PATH)

		fmt.println("==================================================")
	}

	// ========================================================================
	// PRE-BUILD
	// ========================================================================
	rbs.add_pre_build_step(&ctx, pre_build)

	// ========================================================================
	// DEFAULT RUN COMMAND
	// ========================================================================
	rbs.add_command(&ctx, "", proc(ctx: rbs.Context, profile: rbs.Profile) {
		rbs.exec_odin_cmd(ctx, .Run, profile)
	})

	// ========================================================================
	// RUN COMMAND
	// ========================================================================
	rbs.add_command(&ctx, "run", proc(ctx: rbs.Context, profile: rbs.Profile) {
		rbs.exec_odin_cmd(ctx, .Run, profile)
	})

	// ========================================================================
	// BUILD COMMAND
	// ========================================================================
	rbs.add_command(&ctx, "build", proc(ctx: rbs.Context, profile: rbs.Profile) {
		rbs.exec_odin_cmd(ctx, rbs.Odin_Command.Build, profile)
	})

	// ========================================================================
	// MANIFEST COMMAND
	// ========================================================================
	//
	// `rbs manifest` walks Engine/src/Modules, Engine/src/Extensions, and
	// Project/Plugins, extracts the IDENTITY/DEPENDENCIES/TARGETS blocks
	// from each package's .odin source, and emits <PackageName>.toml next
	// to the source.
	//
	// Usage:
	//     rune manifest                       # generate everything
	//     rune manifest Bifrost_Renderer      # one package, relative path
	//     rune manifest --check               # exit 1 if any manifest is stale
	//
	rbs.add_command(&ctx, "manifest", proc(ctx: rbs.Context, profile: rbs.Profile) {
		rbs.manifest_codegen_run(ctx, profile)
	})

	// ========================================================================
	// PROCESS CLI
	// ========================================================================
	rbs.process(ctx)
	log.destroy_console_logger(context.logger)
}
