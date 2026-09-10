// Engine\src\Core\engine.odin
//
// Engine entry points. Lifecycle (init / run / destroy) and the scheduler wiring. 
package Core

import "core:fmt"
import "core:log"
import "core:mem"
import "core:time"

import hm "core:container/handle_map"

// ============================================================================
//* GLOBAL REGISTRIES / MANAGERS
//
// Engine-owned singletons. All manager init/destroy is driven from
// engine.init / engine.destroy in this file.
//
// Module / Extension / Plugin managers are Component_Managers tagged
// with their kind at init time. Service/Resource/Event registries are
// separate types; the rollback helpers below reinterpret a
// Component_Manager pointer so we can store all six globals uniformly.
@(private)
GLOBAL_MODULE_MANAGER:    Component_Manager
@(private)
GLOBAL_EXTENSION_MANAGER: Component_Manager
@(private)
GLOBAL_PLUGIN_MANAGER:    Component_Manager
@(private)
GLOBAL_SERVICE_REGISTRY:  Service_Registry
@(private)
GLOBAL_RESOURCE_REGISTRY: Resource_Registry
@(private)
GLOBAL_EVENT_REGISTRY:    Event_Registry

// ============================================================================
//* QUIT PROVIDERS
//
// Modules can ask the engine to exit without taking a Core dependency.
// Each provider is a no-arg proc returning true when the module wants the
// run loop to terminate (e.g. window-close received, gameplay requested
// shutdown). The engine calls them once per frame at the top of the
// run loop; any provider returning true sets ENGINE_RUNNING = false.
//
// Core stays decoupled from any specific module - the registry just
// stores opaque (name, callback) pairs.
// ============================================================================

Quit_Request_Provider :: struct {
	name:    string,
	request: proc() -> bool,
}

@(private)
GLOBAL_QUIT_PROVIDERS: [dynamic]Quit_Request_Provider

// engine_register_quit_provider installs a quit request callback under
// `name`. Duplicate names are rejected (the first registration wins).
// Returns false if request is nil or name is already registered.
engine_register_quit_provider :: proc(name: string, request: proc() -> bool) -> bool {
	if request == nil do return false
	if len(name) == 0 do return false
	for p in GLOBAL_QUIT_PROVIDERS {
		if p.name == name {
			log.warnf("[Engine] quit provider '%s' already registered", name)
			return false
		}
	}
	append(&GLOBAL_QUIT_PROVIDERS, Quit_Request_Provider{name = name, request = request})
	return true
}

// engine_unregister_quit_provider removes a previously registered quit
// provider by name. Returns true if a provider was removed.
engine_unregister_quit_provider :: proc(name: string) -> bool {
	for p, i in GLOBAL_QUIT_PROVIDERS {
		if p.name == name {
			ordered_remove(&GLOBAL_QUIT_PROVIDERS, i)
			return true
		}
	}
	return false
}

// engine_poll_quit returns true if any registered quit provider asked
// the engine to stop. Called once per frame at the top of run().
engine_poll_quit :: proc() -> bool {
	for p in GLOBAL_QUIT_PROVIDERS {if p.request != nil && p.request() do return true}
	return false
}

// Rollback_Op is the entry pushed onto engine.init's rollback stack
// when a subsystem successfully starts. On failure, the deferred
// rollback drains the stack in reverse order.
Rollback_Op :: struct {
	kind:   registry_kind,
	target: rawptr,
}

// Engine_App_Interface is the application's hook surface.
Engine_App_Interface :: struct {
	on_init:     proc(), // Called after modules are activated and the empty DAG is built.
	on_pre_tick: proc(dt: f32, frame_index: u64), // Game intent at the top of each frame.
	on_present:  proc(dt: f32, frame_index: u64), // Present / swap after the DAG finishes.
	on_shutdown: proc(), // Once, at the end of engine.destroy, before scheduler teardown.
}

@(private)
GLOBAL_APP_INTERFACE: ^Engine_App_Interface

RUN_EDITOR: bool = false
ENGINE_RUNNING: bool = false

//* LIFECYCLE INIT (defer-based rollback on partial failure)
init :: proc(app: ^Engine_App_Interface, run_editor: bool) -> bool {
	context.logger = log.create_console_logger()
	inject_default_project_settings()

	// Allocate the shared Engine_State before any DLL loads so the
	// pointer can be wired into every Core_Lib_Context via
	// engine_state_get().
	engine_state_init(context.allocator)

	RUN_EDITOR = run_editor
	GLOBAL_APP_INTERFACE = app

	fmt.println("")
	fmt.println("========================================")
	fmt.println(" ENGINE INIT")
	fmt.println("========================================")

	// Track which subsystems have started so we can roll back on
	// partial failure. Each successful step pushes a Rollback_Op
	// onto `rollback`. The final init returns true if everything
	// succeeded; on failure the deferred rollback drains the stack
	// in reverse order.
	rollback := make([dynamic]Rollback_Op, 0, context.allocator)
	defer {
		if !ENGINE_RUNNING {
			for i := len(rollback) - 1; i >= 0; i -= 1 {
				op := rollback[i]
				switch op.kind {
				case .RK_Module, .RK_Extension, .RK_Plugin:
					component_manager_destroy(cast(^Component_Manager)op.target)
				case .RK_Service:
					service_registry_destroy(cast(^Service_Registry)op.target)
				case .RK_Resource:
					resource_registry_destroy(cast(^Resource_Registry)op.target)
				case .RK_Event:
					event_registry_destroy(cast(^Event_Registry)op.target)
				case .RK_EngineState:
					engine_state_destroy()
				}
			}
		}
		delete(rollback)
	}

	// Project Settings (TOML).
	if !load_project_settings_toml() {
		setup_default_project_settings_toml()
	}

	// Singletons: init in dependency order. Each subsystem registers
	// its rollback op on failure.
	if !registry_init_with_rollback(&rollback, rawptr(&GLOBAL_MODULE_MANAGER), context.allocator, .RK_Module) do return false
	if !registry_init_with_rollback(&rollback, rawptr(&GLOBAL_EXTENSION_MANAGER), context.allocator, .RK_Extension) do return false
	if !registry_init_with_rollback(&rollback, rawptr(&GLOBAL_PLUGIN_MANAGER), context.allocator, .RK_Plugin) do return false
	if !registry_init_with_rollback(&rollback, rawptr(&GLOBAL_SERVICE_REGISTRY), context.allocator, .RK_Service) do return false
	if !registry_init_with_rollback(&rollback, rawptr(&GLOBAL_RESOURCE_REGISTRY), context.allocator, .RK_Resource) do return false
	if !registry_init_with_rollback(&rollback, rawptr(&GLOBAL_EVENT_REGISTRY), context.allocator, .RK_Event) do return false

	// Quit providers list. Modules register their (name, callback)
	// during module_register; the run loop polls them per frame.
	GLOBAL_QUIT_PROVIDERS = make([dynamic]Quit_Request_Provider, context.allocator)

	// MODULES
	if !component_manager_load_project(&GLOBAL_MODULE_MANAGER, GLOBAL_PROJECT_SETTINGS.modules) do return false
	if !component_manager_resolve(&GLOBAL_MODULE_MANAGER) do return false
	if !component_manager_activate_all(&GLOBAL_MODULE_MANAGER) do return false

	// EXTENSIONS
	if !component_manager_load_project(&GLOBAL_EXTENSION_MANAGER, GLOBAL_PROJECT_SETTINGS.extensions) do return false
	if !component_manager_resolve(&GLOBAL_EXTENSION_MANAGER) do return false
	if !component_manager_activate_all(&GLOBAL_EXTENSION_MANAGER) do return false

	// PLUGINS
	if !component_manager_load_project(&GLOBAL_PLUGIN_MANAGER, GLOBAL_PROJECT_SETTINGS.plugins) do return false
	if !component_manager_resolve(&GLOBAL_PLUGIN_MANAGER) do return false
	if !component_manager_activate_all(&GLOBAL_PLUGIN_MANAGER) do return false

	// Game registration before DAG compile.
	if app != nil && app.on_init != nil {
		log.info("[Engine] Engine_App_Interface.on_init()")
		app.on_init()
	}

	// Populate the Scheduler_Frame.world handle now that we know which
	// modules are active. Done lazily — we don't require BF_ECS.
	if world_raw := engine_get_ecs_world(); world_raw != nil {
		engine_world_handle = World_Handle{ptr = world_raw}
	}
	// engine_self_handle is a sentinel pointing at ENGINE_RUNNING.
	// Future code can dereference this through a typed wrapper if
	// it needs to recover engine state from a system callback.
	engine_self_handle = Engine_Handle{ptr = rawptr(&ENGINE_RUNNING)}

	// Build the DAG and start the worker pool.
	if !scheduler_build() do return false
	if !scheduler_start_workers() do return false

	fmt.println("")
	fmt.println("Engine initialization complete.")
	ENGINE_RUNNING = true
	return true
}

// registry_kind is a tag for the four kinds of subsystem init paths.
// Distinct from Component_Kind so the names don't shadow the manager types.
registry_kind :: enum {
	RK_Module,
	RK_Extension,
	RK_Plugin,
	RK_Service,
	RK_Resource,
	RK_Event,
	RK_EngineState,
}

registry_init_with_rollback :: proc(
	rollback: ^[dynamic]Rollback_Op,
	target: rawptr,
	allocator: mem.Allocator,
	kind: registry_kind,
) -> bool {
	ok := false
	switch kind {
	case .RK_Module:
		cm := cast(^Component_Manager)target
		ok = component_manager_init(cm, allocator, .Module)
	case .RK_Extension:
		cm := cast(^Component_Manager)target
		ok = component_manager_init(cm, allocator, .Extension)
	case .RK_Plugin:
		cm := cast(^Component_Manager)target
		ok = component_manager_init(cm, allocator, .Plugin)
	case .RK_Service:
		sr := cast(^Service_Registry)target
		ok = service_registry_init(sr, allocator)
	case .RK_Resource:
		rr := cast(^Resource_Registry)target
		ok = resource_registry_init(rr, allocator)
	case .RK_Event:
		er := cast(^Event_Registry)target
		ok = event_registry_init(er, allocator)
	case .RK_EngineState:
		// Engine_State is a host-only singleton; init happens in
		// engine_state_init() before any DLL load. Nothing to do here.
		ok = true
	}
	if !ok do return false
	append(rollback, Rollback_Op{kind = kind, target = target})
	return true
}

engine_quit :: proc() {
	ENGINE_RUNNING = false
}

// ============================================================================
//* ENGINE STATE — shared across the host + every loaded DLL
//
// A single Engine_State struct lives in the engine executable. Every DLL
// gets the same pointer via lib_context_query("engine_state"), so writes
// from a DLL pump and reads from the engine's main loop see the same
// memory. This is the recommended path for any cross-DLL flag; do NOT
// stash engine-wide state in package-level globals because Odin
// duplicates those per DLL.
// ============================================================================

@(private)
GLOBAL_ENGINE_STATE: ^Engine_State

@(private)
ENGINE_STATE_ALLOCATOR: mem.Allocator

// engine_state_get returns the engine's shared Engine_State pointer.
// Allocated once during engine.init and freed by engine.destroy.
engine_state_get :: proc() -> ^Engine_State {
	return GLOBAL_ENGINE_STATE
}

// engine_state_init allocates the shared Engine_State. Called once from
// engine.init; subsequent calls return false and leave the existing
// state untouched.
@(private)
engine_state_init :: proc(allocator: mem.Allocator) -> bool {
	if GLOBAL_ENGINE_STATE != nil do return false
	GLOBAL_ENGINE_STATE = new(Engine_State, allocator)
	GLOBAL_ENGINE_STATE.quit_requested = false
	GLOBAL_ENGINE_STATE.pump_names     = make([dynamic]string, allocator)
	GLOBAL_ENGINE_STATE.pump_procs     = make([dynamic]Platform_Pump_Proc, allocator)
	GLOBAL_ENGINE_STATE.pump_count     = 0
	// register_pump routes DLL-side registration calls back into
	// engine.exe's GLOBAL_ENGINE_STATE.pump_procs list. Without this
	// indirection a DLL calling `engine_register_platform_pump` would
	// silently write into its own (nil, here) package global and
	// never register with the engine.
	GLOBAL_ENGINE_STATE.register_pump  = engine_register_platform_pump
	ENGINE_STATE_ALLOCATOR              = allocator
	return true
}

@(private)
engine_state_destroy :: proc() {
	if GLOBAL_ENGINE_STATE == nil do return
	delete(GLOBAL_ENGINE_STATE.pump_names)
	delete(GLOBAL_ENGINE_STATE.pump_procs)
	free(GLOBAL_ENGINE_STATE, ENGINE_STATE_ALLOCATOR)
	GLOBAL_ENGINE_STATE = nil
}

// engine_register_platform_pump adds a pump proc to the engine's pump
// list. Returns false if name is empty, proc is nil, or the name was
// already registered.
engine_register_platform_pump :: proc(name: string, pump: Platform_Pump_Proc) -> bool {
	if GLOBAL_ENGINE_STATE == nil do return false
	if len(name) == 0 || pump == nil do return false
	for n in GLOBAL_ENGINE_STATE.pump_names {
		if n == name do return false
	}
	append(&GLOBAL_ENGINE_STATE.pump_names, name)
	append(&GLOBAL_ENGINE_STATE.pump_procs, pump)
	GLOBAL_ENGINE_STATE.pump_count = len(GLOBAL_ENGINE_STATE.pump_procs)
	return true
}

// engine_run_platform_pumps invokes every registered pump. Called by
// the engine run loop on the main thread, once per frame, BEFORE the
// DAG dispatches.
@(private)
engine_run_platform_pumps :: proc() {
	if GLOBAL_ENGINE_STATE == nil do return
	for p in GLOBAL_ENGINE_STATE.pump_procs {
		if p != nil do p()
	}
}

//* ENGINE RUN — frame loop driver
run :: proc() {
	fmt.println("")
	fmt.println("========================================")
	fmt.println(" ENGINE RUN")
	fmt.println("========================================")

	if GLOBAL_SCHEDULER_SERVICE == nil {
		fmt.println("[Engine] No scheduler service; running on_pre_tick / on_present only.")
	}

	// High-resolution timer for dt. time.tick_now() is monotonic.
	last_tick := time.tick_now()

	frame_index: u64 = 0

	// ENGINE_MAX_DT_S clamp prevents spiral-of-death after a hitch.
	ENGINE_MAX_DT_S :: f32(1.0 / 30.0)

	// First-frame dt spike guard. Seed last_tick at the top of the
	// first iteration so the first dt only measures time since init.
	first_frame := true

	ENGINE_RUN: for ENGINE_RUNNING {
		// Run module-registered platform pumps FIRST. These typically
		// translate OS-level signals (window-close button, resize,
		// focus loss) into engine_state flags that engine_poll_quit
		// then checks below. Pumps must be lightweight — long work
		// belongs in DAG systems.
		engine_run_platform_pumps()

		// Two quit sources, both checked at the top of every frame:
		//   1. engine_state.quit_requested — set by any platform pump
		//      that owns the OS window (BF_GPU/SDL).
		//   2. GLOBAL_QUIT_PROVIDERS — proc() -> bool callbacks
		//      installed via the SDK by any module (BF_Input, the
		//      game app, ...).
		if GLOBAL_ENGINE_STATE != nil && GLOBAL_ENGINE_STATE.quit_requested {
			break ENGINE_RUN
		}
		if engine_poll_quit() {
			break ENGINE_RUN
		}

		now_tick := time.tick_now()
		if first_frame {
			last_tick = now_tick
			first_frame = false
		}
		d := time.tick_diff(last_tick, now_tick)
		last_tick = now_tick

		dt := f32(time.duration_seconds(d))
		if dt > ENGINE_MAX_DT_S do dt = ENGINE_MAX_DT_S
		if dt < 0 do dt = 0

		frame := Scheduler_Frame {
			world       = engine_world_handle,
			engine      = engine_self_handle,
			dt          = dt,
			frame_index = frame_index,
		}

		// 1. Begin frame — resets per-frame scheduler state, enqueues
		//    root nodes, computes frame budget.
		if GLOBAL_SCHEDULER_SERVICE != nil {
			GLOBAL_SCHEDULER_SERVICE.begin_frame(GLOBAL_SCHEDULER_SERVICE, rawptr(&frame))
		}

		// 2. Game intent — single-threaded, before any worker starts.
		if GLOBAL_APP_INTERFACE != nil && GLOBAL_APP_INTERFACE.on_pre_tick != nil {
			GLOBAL_APP_INTERFACE.on_pre_tick(dt, frame_index)
		}

		// 3. Drive DAG on the main thread.
		if GLOBAL_SCHEDULER_SERVICE != nil {
			GLOBAL_SCHEDULER_SERVICE.run(GLOBAL_SCHEDULER_SERVICE)
		}

		// 4. Block until every worker drained (lock-free via frame_gen).
		if GLOBAL_SCHEDULER_SERVICE != nil {
			GLOBAL_SCHEDULER_SERVICE.wait(GLOBAL_SCHEDULER_SERVICE)
		}

		// 5. Present / swap. Runs on the main thread AFTER the DAG
		//    finishes; renderers register their Submit work in the
		//    .Render stage of the DAG, so by the time we get here the
		//    command buffers are recorded but not yet presented.
		if GLOBAL_APP_INTERFACE != nil && GLOBAL_APP_INTERFACE.on_present != nil {
			GLOBAL_APP_INTERFACE.on_present(dt, frame_index)
		}

		frame_index += 1
	}

	fmt.println("ENGINE RUN EXITED")
}

//* ENGINE DESTROY
destroy :: proc() -> bool {
	cleanup_project_settings(project_settings_get())
	fmt.println("")
	fmt.println("========================================")
	fmt.println(" ENGINE DESTROY")
	fmt.println("========================================")

	ENGINE_RUNNING = false

	if GLOBAL_APP_INTERFACE != nil && GLOBAL_APP_INTERFACE.on_shutdown != nil {
		log.info("[Engine] Engine_App_Interface.on_shutdown()")
		GLOBAL_APP_INTERFACE.on_shutdown()
	}

	// Reverse-order teardown.
	component_manager_deactivate_all(&GLOBAL_PLUGIN_MANAGER)
	component_manager_deactivate_all(&GLOBAL_EXTENSION_MANAGER)
	component_manager_deactivate_all(&GLOBAL_MODULE_MANAGER)

	scheduler_shutdown()

	// UNLOAD modules FIRST — drains their services/resources/events
	// out of the global registries and calls each instance's destroy()
	// exactly once.
	component_manager_unload_all(&GLOBAL_MODULE_MANAGER)
	component_manager_unload_all(&GLOBAL_PLUGIN_MANAGER)
	component_manager_unload_all(&GLOBAL_EXTENSION_MANAGER)

	event_registry_destroy(&GLOBAL_EVENT_REGISTRY)
	resource_registry_destroy(&GLOBAL_RESOURCE_REGISTRY)
	service_registry_destroy(&GLOBAL_SERVICE_REGISTRY)

	component_manager_destroy(&GLOBAL_MODULE_MANAGER)
	component_manager_destroy(&GLOBAL_EXTENSION_MANAGER)
	component_manager_destroy(&GLOBAL_PLUGIN_MANAGER)

	engine_world_handle = {}
	engine_self_handle = {}
	delete(GLOBAL_QUIT_PROVIDERS)
	GLOBAL_APP_INTERFACE = nil

	engine_state_destroy()

	log.destroy_console_logger(context.logger)
	return true
}

// =============================================================================
//* SCHEDULER WIRING

GLOBAL_SCHEDULER_SERVICE: ^Scheduler_Service

SCHEDULER_SERVICE_NAME_INTERNAL :: "BF_DAG.Scheduler"

@(private)
engine_world_handle: World_Handle
@(private)
engine_self_handle: Engine_Handle

scheduler_build :: proc() -> bool {
	handle, ok := service_find(&GLOBAL_SERVICE_REGISTRY, SCHEDULER_SERVICE_NAME_INTERNAL)
	if !ok {
		log.warn("[Scheduler] BF_DAG.Scheduler service not registered — running without a scheduler.")
		return true
	}

	instance := service_get(&GLOBAL_SERVICE_REGISTRY, handle)
	if instance == nil {
		log.error("[Scheduler] BF_DAG.Scheduler service instance is nil.")
		return false
	}

	service := cast(^Scheduler_Service)instance
	GLOBAL_SCHEDULER_SERVICE = service

	game_registry_init_if_needed()
	game_systems := GLOBAL_GAME_SYSTEMS[:]
	game_total := len(game_systems)

	module_total := 0
	registry := &GLOBAL_MODULE_MANAGER.registry
	it_count := hm.dynamic_iterator_make(&registry.slots)
	for module, _ in hm.iterate(&it_count) {
		module_total += len(module.registration.systems)
	}

	total := game_total + module_total
	if total == 0 {
		log.info("[Scheduler] No systems registered.")
		return true
	}

	next_id: u32 = 1

	// Combined view of every system (game + module). Both contribute
	// to the same DAG so cross-source deps resolve by name.
	combined := make([dynamic]System_Entry, total, context.allocator)
	defer delete(combined)

	// Track name -> index in `combined` for dep resolution below.
	name_index := make(map[string]int, total, context.allocator)
	defer delete(name_index)

	// Game systems first.
	for &sys, _ in game_systems {
		sys.id = System_ID(next_id)
		combined[next_id - 1] = sys
		name_index[sys.name] = int(next_id - 1)
		next_id += 1
	}

	// Module systems. Thread the module-supplied System_Info through;
	// default the stage to .Update if the module didn't specify one.
	it_collect := hm.dynamic_iterator_make(&registry.slots)
	for module, _ in hm.iterate(&it_collect) {
		for reg_sys in module.registration.systems {
			id := System_ID(next_id)
			info := reg_sys.info
			entry := System_Entry {
				name     = reg_sys.name,
				callback = reg_sys.execute,
				info     = info,
				id       = id,
			}
			combined[next_id - 1] = entry
			name_index[reg_sys.name] = int(next_id - 1)
			next_id += 1
		}
	}

	// Game-side deps + any module-side deps registered through
	// module dependencies array (extensions of System_Info to come).
	deps := make([dynamic]System_Dependency, len(GLOBAL_GAME_DEPENDENCIES), context.allocator)
	defer delete(deps)

	for dep in GLOBAL_GAME_DEPENDENCIES {
		before_idx, ok1 := name_index[dep.before_name]
		after_idx,  ok2 := name_index[dep.after_name]
		if !ok1 || !ok2 {
			log.warnf(
				"[Scheduler] dropping unresolved dependency '%s' -> '%s'",
				dep.before_name,
				dep.after_name,
			)
			continue
		}
		append(&deps, System_Dependency{
			before = combined[before_idx].id,
			after  = combined[after_idx].id,
		})
	}

	systems_ptr := rawptr(&combined[0]) if len(combined) > 0 else nil
	deps_ptr    := rawptr(&deps[0])    if len(deps)    > 0 else nil

	ok_build := service.build(
		service,
		systems_ptr,
		len(combined),
		deps_ptr,
		len(deps),
		context.allocator,
	)

	if !ok_build {
		log.error("[Scheduler] BF_DAG build failed.")
		return false
	}

	log.infof(
		"[Scheduler] BF_DAG compiled %d systems (%d game + %d module).",
		total, game_total, module_total,
	)
	return true
}

scheduler_start_workers :: proc() -> bool {
	if GLOBAL_SCHEDULER_SERVICE == nil do return true
	GLOBAL_SCHEDULER_SERVICE.start_workers(GLOBAL_SCHEDULER_SERVICE)
	return true
}

scheduler_shutdown :: proc() {
	if GLOBAL_SCHEDULER_SERVICE == nil do return
	GLOBAL_SCHEDULER_SERVICE = nil
}

engine_scheduler_get :: proc() -> ^Scheduler_Service {
	return GLOBAL_SCHEDULER_SERVICE
}

engine_get_ecs_world :: proc() -> rawptr {
	handle, ok := service_find(&GLOBAL_SERVICE_REGISTRY, "BF_ECS.World")
	if !ok do return nil
	return service_get(&GLOBAL_SERVICE_REGISTRY, handle)
}