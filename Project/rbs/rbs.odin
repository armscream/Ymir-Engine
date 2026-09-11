package build

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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
ASSET_CONVERTER_OUTPUT_PATH :: "../bin/Tools"

// Stable, filename-safe identifiers used for profile-aware switches below.
// The executable output name (`Profile.name`) is built from `project_name`
// and may contain spaces; use these constants when matching a profile by
// identity instead of by display name.
DEBUG_NAME           :: "Debug"
EDITOR_NAME          :: "Editor"
RELEASE_NAME         :: "Release"
ASSET_CONVERTER_NAME :: "Tools"

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
// STALE-SOURCE CHECK
// ============================================================================
//
// Odin has no incremental linker on Windows — every `odin build -build-mode:dll`
// re-runs the full link (~3-4s per DLL on this machine) even when nothing
// changed. We side-step that by comparing the source tree's mtime to the
// output DLL's mtime: if every .odin file is older than the .dll, we skip
// the odin invocation entirely. Warm rebuilds used to take ~17s of pure
// linker work; with this they take 0s for any unchanged module.
//
// Set RUNE_FORCE_REBUILD=1 to disable the optimisation (debug rbs itself).
//
// Trade-off: this walks the source dir on every build. For the engine's
// small modules (a few hundred files each) that's a few ms — well under
// the 3-4s saved per skipped module. The check is shallow: mtime only,
// not content hash, so a `touch` to a source file triggers a rebuild
// even if content is unchanged. That's the right behaviour for rbs.

SOURCE_EXTS :: []string{".odin"}

walk_max_source_mtime :: proc(root: string) -> time.Time {
	// time.Time zero value is "very old" — safe as initial accumulator.
	max_mt: time.Time

	// os.read_all_directory_by_path on Windows returns garbled UTF-16
	// bytes when given a relative path. Walk an absolute root so the
	// comparison is reliable across platforms.
	abs_root, aerr := filepath.abs(root, context.allocator)
	if aerr != nil do return max_mt
	defer delete(abs_root)

	stack: [dynamic]string
	defer delete(stack)
	append(&stack, abs_root)

	for len(stack) > 0 {
		dir := pop(&stack)
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil do continue
		if len(entries) == 0 do continue
		for e in entries {
			full, jerr := filepath.join({dir, e.name}, context.allocator)
			if jerr != nil {
				os.file_info_delete(e, context.allocator)
				continue
			}
			if e.type == .Directory {
				// Skip rbs/rcc/rcp build-time caches and version-control
				// dirs so a stray git checkout doesn't trigger a rebuild.
				base := e.name
				if base == ".git" || base == ".odin-cache" || base == "bin" || base == "node_modules" {
					os.file_info_delete(e, context.allocator)
					delete(full)
					continue
				}
				append(&stack, full)
			} else if e.type == .Regular {
				ext := filepath.ext(e.name)
				match := false
				for s in SOURCE_EXTS do if ext == s { match = true; break }
				if !match {
					delete(full)
					os.file_info_delete(e, context.allocator)
					continue
				}
				// Modtime comparison: any newer file wins.
				// Empirically time.diff(max_mt, e) > 0 when e > max_mt.
				if time.diff(max_mt, e.modification_time) > 0 {
					max_mt = e.modification_time
				}
				delete(full)
			}
			os.file_info_delete(e, context.allocator)
		}
		delete(entries)
	}
	return max_mt
}

@(private)
forced_rebuild :: proc() -> bool {
	v := os.get_env("RUNE_FORCE_REBUILD", context.allocator)
	defer if len(v) > 0 do delete(v)
	return len(v) > 0
}

needs_rebuild :: proc(source_dir, output_dll: string) -> bool {
	if forced_rebuild() do return true

	// No prior build → must build.
	dll_info, dll_err := os.stat(output_dll, context.allocator)
	if dll_err != nil do return true
	defer os.file_info_delete(dll_info, context.allocator)

	// No sources → can't tell; rebuild to be safe.
	src_max := walk_max_source_mtime(source_dir)
	// A zero Time means we found nothing .odin — fall back to rebuild.
	// time.diff(zero, zero) returns a non-negative zero duration, so
	// comparing to zero is the natural "is this still the zero value" check.
	if time.diff(src_max, {}) == 0 do return true

	// Source newer than DLL → rebuild. Older → skip.
	if time.diff(dll_info.modification_time, src_max) > 0 do return true
	return false
}


// ============================================================================
// BUILD MODULES / EXTENSIONS / PLUGINS (parallel)
// ============================================================================
//
// All component kinds (modules, extensions, plugins) are independent
// `odin -build-mode:dll` invocations. They used to run serially here;
// now they share a single worker pool. Typical 4-module + 1-extension
// project dropped from ~15s to ~4s on a 4-core box.
//
// Failure model: build_component / build_* call fatal() on error which
// os.exit()s the process. That kills every worker thread, so we don't
// need to coordinate shutdown. Logs interleave intentionally — that's
// the speed tradeoff.

Build_Job :: struct {
	name:       string,
	kind:       string, // "module" | "extension" | "plugin"
	profile:    rbs.Profile,
	source_dir: string, // resolved source directory; used by needs_rebuild
}

Build_Job_Context :: struct {
	jobs:     ^[dynamic]Build_Job,
	next_idx: ^int,
}

resolve_job_source :: proc(kind, name: string) -> string {
	#no_bounds_check switch kind {
	case "module":   return resolve_module_source(name)
	case "extension": return resolve_extension_source(name)
	case "plugin":   return resolve_plugin_source(name)
	}
	return ""
}

// dispatch_job runs the stale-source check and either invokes the
// matching build_* proc or prints a cached line. Used by both the
// single-worker fast path and the parallel worker loop.
dispatch_job :: proc(job: ^Build_Job) {
	dll_rel := join_project_path(job.profile.output, fmt.tprintf("%s.dll", job.name))
	dll_abs, _ := filepath.abs(dll_rel, context.allocator)
	defer delete(dll_abs)

	if !needs_rebuild(job.source_dir, dll_abs) {
		fmt.printfln("  [cached] %s.dll (no source changes)", job.name)
		return
	}

	#no_bounds_check switch job.kind {
	case "module":
		build_module(job.name, job.profile)
	case "extension":
		build_extension(job.name, job.profile)
	case "plugin":
		build_plugin(job.name, job.profile)
	}
}

build_job_worker :: proc(ctx: Build_Job_Context) {
	for {
		// sync.atomic_add returns the PRIOR value, so the first
		// call returns 0 (the first job), subsequent calls return
		// 1, 2, ... Use the return value directly as the index.
		idx := sync.atomic_add(ctx.next_idx, 1)
		if idx >= len(ctx.jobs^) do return
		job := &ctx.jobs^[idx]
		dispatch_job(job)
	}
}

collect_build_jobs :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) -> [dynamic]Build_Job {
	jobs: [dynamic]Build_Job
	for m in settings.modules {
		if !should_build_module(m.name, m.enabled, profile.output) do continue
		src := resolve_module_source(m.name)
		append(&jobs, Build_Job{m.name, "module", profile, src})
	}
	for e in settings.extensions {
		if !e.enabled do continue
		src := resolve_extension_source(e.name)
		append(&jobs, Build_Job{e.name, "extension", profile, src})
	}
	for p in settings.plugins {
		if !p.enabled do continue
		src := resolve_plugin_source(p.name)
		append(&jobs, Build_Job{p.name, "plugin", profile, src})
	}
	return jobs
}

detect_parallelism :: proc() -> int {
	// ODIN_BUILD_PARALLELISM wins if set.
	if v := os.get_env("ODIN_BUILD_PARALLELISM", context.allocator); len(v) > 0 {
		defer delete(v)
		if n, ok := strconv.parse_int(v); ok && n > 0 do return n
	}
	// Otherwise a conservative cap. Windows job objects and Odin's own
	// -thread-count inside each subprocess already parallelize the
	// heavy lifting; 8 is plenty for the outer dispatch.
	return 8
}

// ============================================================================
// EXE STALE-SOURCE CHECK
// ============================================================================
//
// The final exe links against every DLL's import library (.lib) plus
// Project/main.odin's own source tree. If none of those have been
// touched since the exe was built, skip the odin invocation that
// would otherwise re-link for ~3-4s.
//
// We compare the maximum mtime of any tracked dependency against the
// exe's mtime. Tracked dependencies:
//   1. Project/*.odin (the project source tree; excludes rbs/, bin/, etc.)
//   2. <output>/*.lib (every DLL import library produced by step 1)

EXE_TRACKED_EXTS :: []string{".odin", ".lib"}

exe_max_dep_mtime :: proc(project_root, profile_output: string) -> time.Time {
	max_mt: time.Time

	// Walk Project/ source files.
	proj_abs, _ := filepath.abs(project_root, context.allocator)
	defer delete(proj_abs)
	stack: [dynamic]string
	defer delete(stack)
	append(&stack, proj_abs)

	for len(stack) > 0 {
		dir := pop(&stack)
		entries, err := os.read_all_directory_by_path(dir, context.allocator)
		if err != nil do continue
		for e in entries {
			full, jerr := filepath.join({dir, e.name}, context.allocator)
			if jerr != nil {
				os.file_info_delete(e, context.allocator)
				continue
			}
			if e.type == .Directory {
				base := e.name
				if base == ".git" || base == ".odin-cache" || base == "bin" || base == "rbs" || base == "config" || base == "scripts" || base == "assets" || base == "node_modules" {
					os.file_info_delete(e, context.allocator)
					delete(full)
					continue
				}
				append(&stack, full)
			} else if e.type == .Regular {
				ext := filepath.ext(e.name)
				match := false
				for s in EXE_TRACKED_EXTS do if ext == s { match = true; break }
				if !match {
					delete(full)
					os.file_info_delete(e, context.allocator)
					continue
				}
				if time.diff(max_mt, e.modification_time) > 0 {
					max_mt = e.modification_time
				}
				delete(full)
			}
			os.file_info_delete(e, context.allocator)
		}
		delete(entries)
	}

	// Also check the DLL .lib files — the exe links each one.
	out_abs, _ := filepath.abs(profile_output, context.allocator)
	defer delete(out_abs)
	libs, lerr := os.read_all_directory_by_path(out_abs, context.allocator)
	if lerr == nil {
		for e in libs {
			if e.type != .Regular do continue
			ext := filepath.ext(e.name)
			match := ext == ".lib"
			if !match do continue
			if time.diff(max_mt, e.modification_time) > 0 {
				max_mt = e.modification_time
			}
		}
		delete(libs)
	}

	return max_mt
}

needs_exe_rebuild :: proc(profile: rbs.Profile) -> bool {
	if forced_rebuild() do return true

	// Exe path: <output>/<project_name>.exe — matches the pattern
	// used by rbs.exec_odin_cmd to write the exe.
	exe_name := fmt.tprintf("%s%s", profile.name, exe_ext_for(profile))
	exe_rel := join_project_path(profile.output, exe_name)
	exe_abs, _ := filepath.abs(exe_rel, context.allocator)
	defer delete(exe_abs)

	exe_info, err := os.stat(exe_abs, context.allocator)
	if err != nil do return true
	defer os.file_info_delete(exe_info, context.allocator)

	// Project source root is `..` from CWD=Project/rbs.
	project_root := ".."
	dep_max := exe_max_dep_mtime(project_root, profile.output)
	if time.diff(dep_max, {}) == 0 do return true

	// If any dependency is newer than the exe, rebuild.
	// Empirically: time.diff(exe, dep) > 0 when dep > exe (newer).
	if time.diff(exe_info.modification_time, dep_max) > 0 do return true
	return false
}

// exe_ext_for returns the platform-correct binary extension. Mirrors
// rbs.exec_odin's get_extension but is duplicated here so the cache
// check doesn't have to depend on a private rbs helper.
exe_ext_for :: proc(profile: rbs.Profile) -> string {
	#partial switch profile.os {
	case .Windows: return ".exe"
	case .Linux, .Darwin: return ""
	}
	return ".exe"
}

// Wrapped exec_odin_cmd that skips the odin invocation when the exe is
// already up-to-date. Falls through to the rbs default for everything
// else (Run command, errors, missing exe, etc).
exec_odin_cmd_cached :: proc(ctx: rbs.Context, cmd: rbs.Odin_Command, profile: rbs.Profile) -> rbs.Error {
	// Only the Build command is cacheable this way — Run always
	// needs a fresh exe (it loads the result into memory).
	if cmd == .Build && !needs_exe_rebuild(profile) {
		exe_name := fmt.tprintf("%s%s", profile.name, exe_ext_for(profile))
		exe_path := join_project_path(profile.output, exe_name)
		fmt.printfln("  [cached] %s (no project or DLL changes)", exe_path)
		return nil
	}
	return rbs.exec_odin_cmd(ctx, cmd, profile)
}


run_build_jobs_parallel :: proc(jobs_in: [dynamic]Build_Job, parallelism: int) {
	n := parallelism
	if n < 1 do n = 1
	if n > len(jobs_in) do n = len(jobs_in)
	if n == 1 {
		// Single-worker fast path — no thread overhead. dispatch_job
		// runs the needs_rebuild check first so the cache hit works
		// for the n==1 case too.
		for i in 0 ..< len(jobs_in) {
			dispatch_job(&jobs_in[i])
		}
		return
	}

	fmt.printfln("[rbs] building %d component(s) with %d workers", len(jobs_in), n)

	// Heap-allocate so the workers can take its address (parameters
	// in Odin can't be addressed).
	jobs := make([dynamic]Build_Job, len(jobs_in), context.allocator)
	defer delete(jobs)
	for j, i in jobs_in {
		jobs[i] = j
	}

	next_idx: int
	ctx := Build_Job_Context{&jobs, &next_idx}

	threads: [dynamic]^thread.Thread
	defer delete(threads)
	for _ in 0 ..< n {
		append(&threads, thread.create_and_start_with_poly_data(ctx, build_job_worker))
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}


// ============================================================================
// BUILD MODULES
// ============================================================================
build_modules :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) {
	fmt.println("")
	fmt.println("==================================================")
	fmt.println(" ENGINE COMPONENTS")
	fmt.println("==================================================")

	jobs := collect_build_jobs(settings, profile)
	defer delete(jobs)

	if len(jobs) == 0 {
		fmt.println("  [skip] no enabled components to build")
		return
	}

	run_build_jobs_parallel(jobs, detect_parallelism())
}


// ============================================================================
// BUILD EXTENSIONS / PLUGINS (no-op stubs — modules/extensions/plugins
// are folded into build_modules via collect_build_jobs).
// ============================================================================
//
// Kept so the existing pre_build_* call sites continue to compile.
// Calling them is harmless: they just run build_modules a second time
// if invoked AFTER it, so pre_build_* should pick ONE of the three.
//
build_extensions :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) {
	_ = settings; _ = profile
}
build_plugins :: proc(settings: ^Core.Project_Settings, profile: rbs.Profile) {
	_ = settings; _ = profile
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

	// build_modules is now the unified dispatcher (modules +
	// extensions + plugins all flow through the parallel pool). The
	// legacy build_extensions/build_plugins entry points are kept as
	// no-ops for source compatibility.
	build_modules(&project_config, profile)

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

	// build_modules is now the unified dispatcher (modules +
	// extensions + plugins all flow through the parallel pool). The
	// legacy build_extensions/build_plugins entry points are kept as
	// no-ops for source compatibility.
	build_modules(&project_config, profile)

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

	case ASSET_CONVERTER_OUTPUT_PATH:
		pre_build_asset_converter(ctx, profile)

	case:
		fatal(fmt.aprintf("ERROR: Unknown build profile: %s", profile.output))
	}
}


// ============================================================================
// ASSET CONVERTER PRE-BUILD
// ============================================================================
//
// Builds Engine/src/Tools/asset_converter (SDL3 + Dear ImGui modal
// for offline asset conversion). Does NOT touch the engine runtime.
// See Project/rbs/asset_converter_build.odin for the tool pipeline.
//
pre_build_asset_converter :: proc(ctx: rbs.Context, profile: rbs.Profile) {
	_ = ctx
	build_asset_converter(profile)
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

	// ========================================================================
	// ASSET_CONVERTER PROFILE
	// ========================================================================
	//
	// Build the asset conversion tool (Engine/src/Tools/asset_converter).
	// Not part of the engine runtime -- used at import time. Building it
	// requires MSVC (cl.exe) on Windows because meshoptimizer is a C++
	// library. See Project/rbs/asset_converter_build.odin.
	//
	rbs.add_profile(
		&ctx,
		"ASSET_CONVERTER",
		{
			entry = ASSET_CONVERTER_PACKAGE,
			flags = "-vet -debug",
			mode = .Executable,
			name = "asset_converter",
			output = ASSET_CONVERTER_OUTPUT_PATH,
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
		exec_odin_cmd_cached(ctx, rbs.Odin_Command.Build, profile)
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
	// SHADERS COMMAND
	// ========================================================================
	//
	// `rune shaders` runs only the shader compile pipeline (GLSL -> SPIR-V
	// under <profile.output>/shaders/). The other module/extension/plugin
	// builds are skipped - useful when iterating on shaders while the rest
	// of the build chain is broken upstream.
	//
	// Usage:
	//     rune shaders       # uses default profile (DEBUG)
	//     rune shaders DEBUG
	//
	rbs.add_command(&ctx, "shaders", proc(ctx: rbs.Context, profile: rbs.Profile) {
		_ = ctx
		// Make sure the output directory exists so glslangValidator can
		// write into it.
		if mk_err := os.make_directory_all(profile.output); mk_err != nil {
			log.warnf("Could not create %s: %s", profile.output, mk_err)
		}
		run_shaders_only(profile)
	})

	// ========================================================================
	// PROCESS CLI
	// ========================================================================
	rbs.process(ctx)
	log.destroy_console_logger(context.logger)
}
