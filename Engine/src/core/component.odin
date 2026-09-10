// Engine/src/Core/component.odin
//
// Unified Component Manager. Replaces the three near-identical managers
// (Module, Extension, Plugin) that lived in module_interface.odin,
// extensions.odin, and plugins.odin with a single generic over the
// per-component "Loaded" struct.
//
// Design notes:
//
//   * Every component (Module / Extension / Plugin) exports the same
//     bifrost_lib_get_api -> ^LIB_API entry point and uses Lib_Context.
//     The descriptor's `component_kind` field discriminates. The
//     parallel Extension_API / Plugin_API types are gone.
//
//   * ComponentHandle replaces ModuleHandle / ExtensionHandle /
//     PluginHandle. The three were bit-identical; collapsing them
//     means a single map[string]ComponentHandle covers all lookups.
//
//   * The manager is generic over the Loaded_Component type so each
//     component kind can extend it with kind-specific fields (e.g.
//     extension target lists) without forcing every other kind to
//     carry those fields.
//
//   * Component_Registration carries everything a component may
//     register (services, systems, resources, events, targets).
//     Modules populate the first four; extensions add to targets in
//     addition; plugins populate whatever they need.
//
// Lifecycle ownership:
//   * Engine.init:    manager_init -> load_project -> resolve -> activate_all
//   * Engine.destroy: deactivate_all -> unload_all -> manager_destroy
//   * Loaded slot lifecycle is owned by the manager; DLL lifecycle is
//     owned by Loaded_Lib inside the slot.
package Core

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import hm "core:container/handle_map"

// ============================================================================
// HANDLE
// ============================================================================

// ComponentHandle is the unified handle for any loaded component.
// Layout is bit-identical to the legacy ModuleHandle / ExtensionHandle
// / PluginHandle; only the type name differs.
ComponentHandle :: struct {
	idx: u32,
	gen: u32,
}

INVALID_COMPONENT_HANDLE :: ComponentHandle{idx = 0, gen = 0}

// Type aliases keep existing call sites that referenced the old names
// compiling. New code should use ComponentHandle directly.
ModuleHandle    :: ComponentHandle
ExtensionHandle :: ComponentHandle
PluginHandle    :: ComponentHandle

INVALID_MODULE_HANDLE    :: INVALID_COMPONENT_HANDLE
INVALID_EXTENSION_HANDLE :: INVALID_COMPONENT_HANDLE
INVALID_PLUGIN_HANDLE    :: INVALID_COMPONENT_HANDLE

// ============================================================================
// COMPONENT CONTEXT (handed to the component during lifecycle callbacks)
// ============================================================================

// Component_Context is the per-component gateway into Core. Components
// reach the manager / registry / scheduler pointers through this struct
// rather than going through lib_context_query. The `kind` field tells
// the component which kind it is so it can branch on behaviour.
//
// Note: this is the *engine-side* view. Components receive a Lib_Context
// in their lifecycle callbacks (the ABI struct); they call
// lib_context_query(ctx, "component_context") to get the ^Component_Context.
Component_Context :: struct {
	kind:               Component_Kind,
	registry:           rawptr, // ^Component_Registry(Loaded_Component)
	handle:             ComponentHandle,
	registration:       ^Component_Registration,
	module_registry:    ^Module_Registry,
	service_registry:   ^Service_Registry,
	resource_registry:  ^Resource_Registry,
	event_registry:     ^Event_Registry,
	scheduler:          rawptr, // ^Scheduler_Service, populated once BF_DAG registers.
}

// ============================================================================
// REGISTRATION BUCKET (owned by each component)
// ============================================================================

// Component_Registration collects everything a component intends to
// contribute. Module-side: services/systems/resources/events. Extension
// side: targets + the same four. Plugin side: whatever they want.
Component_Registration :: struct {
	services:  [dynamic]Service_Registration,
	systems:   [dynamic]System_Registration,
	resources: [dynamic]Resource_Registration,
	events:    [dynamic]Event_Registration,
	// targets is only populated by Extension-kind components. Module /
	// plugin instances leave this empty.
	targets:   [dynamic]Extension_Target,
}

// ============================================================================
// LOADED COMPONENT (slot in the handle map)
// ============================================================================

// Loaded_Component is the per-slot record stored in the handle map.
// Every loaded component (module, extension, plugin) is represented by
// one of these; the manager's generic parameter is this struct.
//
// Field ownership:
//   - lib / descriptor / api: physical DLL state, owned by Loaded_Lib.
//   - id_name: Odin-managed copy of the descriptor's name. Used after
//     DLL unload for log messages.
//   - ctx: per-component context. Lifetime equals the slot.
//   - state: lifecycle state machine.
//   - registration: component-side bucket; promoted into the global
//     registries on activation, drained on unload.
Loaded_Component :: struct {
	handle:       ComponentHandle,
	lib:          Loaded_Lib,
	descriptor:   Lib_Descriptor,
	id_name:      string,
	ctx:          Component_Context,
	state:        Component_State,
	registration: Component_Registration,
	// Core_Lib_Context owns the user_data pointer handed to the DLL.
	// Back-pointer for clean teardown.
	core_context: ^Core_Lib_Context,
}

// ============================================================================
// REGISTRY (generic over Loaded type)
// ============================================================================

// Lib_Visit_State drives the DFS cycle detector in dependency
// resolution. Lifted out of the legacy module_interface.odin so all
// callers (registry.dependency_state, registry.visit_state) see the
// same definition.
Lib_Visit_State :: enum {
	Unvisited, // component has not been examined.
	Visiting,  // currently somewhere in the DFS stack.
	Visited,   // completely resolved.
}

// Component_Registry is the per-kind component registry. One instance
// per manager; the manager wraps it with allocator + initialized flag.
Component_Registry :: struct {
	allocator:        mem.Allocator,
	// handle_map is generic over the loaded type. Every kind uses
	// ComponentHandle so lookups are uniform.
	slots:            hm.Dynamic_Handle_Map(Loaded_Component, ComponentHandle),
	by_name:          map[string]ComponentHandle,
	// dependency_order is a flat array of handles in topological order
	// (dependencies first). Populated by resolve_dependencies and
	// consumed by activate_all / deactivate_all / unload_all.
	dependency_order: [dynamic]ComponentHandle,
	// visit_state scratch for the dependency DFS. Indexed by handle.idx.
	visit_state:      [dynamic]Lib_Visit_State,
	// by_type is populated by Module/Plugin managers; Extension managers
	// leave it empty (extensions don't have a Lib_Type in the meaningful
	// sense — they're addressed by name and target).
	by_type:          [Lib_Type][dynamic]ComponentHandle,
	initialized:      bool,
	// kind is the discriminant this registry serves. Read by helpers
	// to dispatch kind-specific behaviour (e.g. extension target
	// validation).
	kind:             Component_Kind,
}

// ============================================================================
// MANAGER (generic, wraps the registry)
// ============================================================================

// Component_Manager is the public surface the engine drives. All three
// legacy managers (Module_Manager, Extension_Manager, Plugin_Manager)
// are now type aliases to this.
Component_Manager :: struct {
	allocator:   mem.Allocator,
	registry:    Component_Registry,
	initialized: bool,
}

// ============================================================================
// TYPE ALIASES (preserve old call sites that named the manager)
// ============================================================================

Module_Manager    :: Component_Manager
Extension_Manager :: Component_Manager
Plugin_Manager    :: Component_Manager

// Extension_Registry / Plugin_Registry are compatibility views over
// Component_Registry. The fields map 1:1; the SDK helpers forward
// through casts.
Extension_Registry :: Component_Registry
Plugin_Registry    :: Component_Registry

// ============================================================================
// REGISTRY LIFECYCLE
// ============================================================================

@(private)
component_registry_init :: proc(
	registry: ^Component_Registry,
	allocator: mem.Allocator,
	kind: Component_Kind,
) -> bool {
	if registry == nil do return false
	if registry.initialized {
		log.warn("Component registry already initialized.")
		return false
	}

	registry.allocator = allocator
	registry.kind = kind

	hm.dynamic_init(&registry.slots, allocator)
	registry.by_name = make(map[string]ComponentHandle, allocator)
	registry.dependency_order = make([dynamic]ComponentHandle, 0, allocator)
	registry.visit_state = make([dynamic]Lib_Visit_State, 0, allocator)

	// by_type is meaningful for Module and Plugin (Lib_Type is a real
	// category); extensions skip it. Keep the array allocated either
	// way so the lookups don't need a kind branch.
	for lib_type in Lib_Type {
		registry.by_type[lib_type] = make([dynamic]ComponentHandle, 0, allocator)
	}

	registry.initialized = true
	log.infof("%s registry initialized.", component_kind_name(kind))
	return true
}

@(private)
component_registry_destroy :: proc(registry: ^Component_Registry) {
	if registry == nil || !registry.initialized do return

	// Drain any residual registrations (defensive — engine.destroy
	// should have already done this).
	it := hm.dynamic_iterator_make(&registry.slots)
	for comp, _ in hm.iterate(&it) {
		if comp.state != .Unloaded && comp.state != .Failed {
			delete(comp.registration.services)
			delete(comp.registration.systems)
			delete(comp.registration.resources)
			delete(comp.registration.events)
			delete(comp.registration.targets)
			comp.registration = {}
		}

		if len(comp.id_name) > 0 {
			delete(comp.id_name, registry.allocator)
			comp.id_name = ""
		}
	}

	delete(registry.by_name)
	delete(registry.dependency_order)
	delete(registry.visit_state)
	for lib_type in Lib_Type {
		delete(registry.by_type[lib_type])
	}
	hm.dynamic_destroy(&registry.slots)

	registry.allocator = {}
	registry.initialized = false
}

// ============================================================================
// REGISTRY HELPERS
// ============================================================================

// component_registry_get is the canonical handle -> slot lookup. All
// SDK-facing helpers funnel through it.
component_registry_get :: proc(
	registry: ^Component_Registry,
	handle: ComponentHandle,
) -> (^Loaded_Component, bool) {
	if registry == nil || !registry.initialized do return nil, false
	if handle == INVALID_COMPONENT_HANDLE do return nil, false
	return hm.get(&registry.slots, handle)
}

// component_is_valid reports whether the slot is currently valid.
component_is_valid :: proc(registry: ^Component_Registry, handle: ComponentHandle) -> bool {
	_, ok := component_registry_get(registry, handle)
	return ok
}

// component_is_loaded covers Loaded, Registered, and Active (i.e.
// the slot exists and isn't Unloaded/Failed).
component_is_loaded :: proc(registry: ^Component_Registry, handle: ComponentHandle) -> bool {
	comp, ok := component_registry_get(registry, handle)
	if !ok do return false
	switch comp.state {
	case .Loaded, .Registered, .Active: return true
	case .Unloaded, .Failed:           return false
	}
	return false
}

component_is_active :: proc(registry: ^Component_Registry, handle: ComponentHandle) -> bool {
	comp, ok := component_registry_get(registry, handle)
	if !ok do return false
	return comp.state == .Active
}

// component_lookup_by_name returns the handle for a component by its
// descriptor name. Validates that the entry isn't stale.
@(private)
component_lookup_by_name :: proc(
	registry: ^Component_Registry,
	name: string,
) -> (ComponentHandle, bool) {
	if registry == nil || !registry.initialized do return INVALID_COMPONENT_HANDLE, false
	if len(name) == 0 do return INVALID_COMPONENT_HANDLE, false
	handle, found := registry.by_name[name]
	if !found do return INVALID_COMPONENT_HANDLE, false
	if !component_is_valid(registry, handle) {
		delete_key(&registry.by_name, name)
		return INVALID_COMPONENT_HANDLE, false
	}
	return handle, true
}

// ============================================================================
// MANAGER API (public surface)
// ============================================================================

component_manager_init :: proc(
	manager: ^Component_Manager,
	allocator: mem.Allocator,
	kind: Component_Kind,
) -> bool {
	if manager == nil do return false
	if manager.initialized {
		log.warnf("%s manager already initialized.", component_kind_name(kind))
		return false
	}
	manager.allocator = allocator
	if !component_registry_init(&manager.registry, allocator, kind) {
		log.warnf("Failed to initialize %s registry.", component_kind_name(kind))
		return false
	}
	manager.initialized = true
	log.infof("%s manager initialized.", component_kind_name(kind))
	return true
}

component_manager_destroy :: proc(manager: ^Component_Manager) {
	if manager == nil || !manager.initialized do return
	component_manager_unload_all(manager)
	component_registry_destroy(&manager.registry)
	manager.allocator = {}
	manager.initialized = false
}

// ============================================================================
// LOAD-ONE (the meat)
// ============================================================================

// component_load_one opens a DLL, validates descriptor, drives
// load()+register() against the DLL, and parks the slot. Used by
// component_manager_load_project (and by future hot-reload paths).
//
// This is the single entry point for every component kind. Kind-specific
// behaviour (e.g. extension target validation) happens after register()
// via component_kind_post_register.
component_load_one :: proc(
	manager: ^Component_Manager,
	path: string,
) -> (ComponentHandle, bool) {
	if manager == nil || !manager.initialized do return INVALID_COMPONENT_HANDLE, false
	registry := &manager.registry

	// Build a Loaded_Component on the stack first; copy it into the
	// handle map once we have a handle.
	comp := Loaded_Component{}
	comp.state = .Loaded

	// Initialize the registration bucket on the engine allocator so
	// it survives DLL unload.
	component_registration_init(&comp.registration, manager.allocator)

	comp.ctx = Component_Context{
		kind             = registry.kind,
		registry         = rawptr(registry),
		handle           = INVALID_COMPONENT_HANDLE,
		registration     = &comp.registration,
		module_registry  = cast(^Module_Registry)&GLOBAL_MODULE_MANAGER.registry,
		service_registry = &GLOBAL_SERVICE_REGISTRY,
		resource_registry = &GLOBAL_RESOURCE_REGISTRY,
		event_registry    = &GLOBAL_EVENT_REGISTRY,
	}

	// Allocate the Core_Lib_Context so the DLL can call
	// lib_context_query("component_context"). The pointer must outlive
	// the DLL.
	core_context := new(Core_Lib_Context, manager.allocator)
	core_context.manager          = rawptr(manager)
	core_context.module_context   = nil
	core_context.project_settings = &GLOBAL_PROJECT_SETTINGS
	core_context.component_context = &comp.ctx
	core_context.engine_state      = engine_state_get()
	comp.core_context = core_context

	lib_context := Lib_Context {
		api       = &CORE_LIB_CONTEXT_API,
		user_data = rawptr(core_context),
	}

	if !loaded_lib_load(&comp.lib, &lib_context, path) {
		log.errorf("[%s] Failed to load library: %s", component_kind_name(registry.kind), path)
		free(core_context, manager.allocator)
		return INVALID_COMPONENT_HANDLE, false
	}

	descriptor := loaded_lib_get_descriptor(&comp.lib)
	if descriptor == nil {
		log.errorf("[%s] Library has no descriptor: %s", component_kind_name(registry.kind), path)
		loaded_lib_shutdown(&comp.lib, &lib_context)
		free(core_context, manager.allocator)
		return INVALID_COMPONENT_HANDLE, false
	}

	// Reject descriptors that don't match the kind this manager serves.
	if descriptor.component_kind != registry.kind {
		log.errorf(
			"[%s] Library '%s' declares component_kind=%s, expected %s.",
			component_kind_name(registry.kind),
			path,
			component_kind_name(descriptor.component_kind),
			component_kind_name(registry.kind),
		)
		loaded_lib_shutdown(&comp.lib, &lib_context)
		free(core_context, manager.allocator)
		return INVALID_COMPONENT_HANDLE, false
	}

	comp.descriptor = descriptor^

	// Clone the name so it survives DLL unload. The descriptor's
	// `name` field points into DLL static memory.
	if descriptor.name != nil {
		comp.id_name = strings.clone(string(descriptor.name), manager.allocator)
	}

	// Drive register(). Some kinds (extensions) need post-register
	// validation against the module registry.
	if !loaded_lib_register(&comp.lib, &lib_context) {
		log.errorf("[%s] Library register() failed: %s", component_kind_name(registry.kind), comp.id_name)
		loaded_lib_shutdown(&comp.lib, &lib_context)
		delete(comp.id_name, manager.allocator)
		component_registration_destroy(&comp.registration)
		free(core_context, manager.allocator)
		return INVALID_COMPONENT_HANDLE, false
	}
	comp.state = .Registered

	// Kind-specific post-register validation. Extension validates its
	// declared targets; Module/Plugin have nothing to check here.
	if !component_kind_post_register(registry, &comp) {
		log.errorf("[%s] post-register validation failed: %s", component_kind_name(registry.kind), comp.id_name)
		loaded_lib_shutdown(&comp.lib, &lib_context)
		delete(comp.id_name, manager.allocator)
		component_registration_destroy(&comp.registration)
		free(core_context, manager.allocator)
		return INVALID_COMPONENT_HANDLE, false
	}

	// Reject duplicate names against currently-valid components.
	if existing, found := registry.by_name[comp.id_name]; found {
		if component_is_valid(registry, existing) {
			log.errorf(
				"[%s] A component named '%s' is already loaded.",
				component_kind_name(registry.kind),
				comp.id_name,
			)
			loaded_lib_shutdown(&comp.lib, &lib_context)
			delete(comp.id_name, manager.allocator)
			component_registration_destroy(&comp.registration)
			free(core_context, manager.allocator)
			return INVALID_COMPONENT_HANDLE, false
		}
		delete_key(&registry.by_name, comp.id_name)
	}

	handle, alloc_err := hm.add(&registry.slots, comp)
	if alloc_err != nil {
		log.errorf(
			"[%s] Failed to allocate slot for '%s': %v",
			component_kind_name(registry.kind),
			comp.id_name,
			alloc_err,
		)
		loaded_lib_shutdown(&comp.lib, &lib_context)
		delete(comp.id_name, manager.allocator)
		component_registration_destroy(&comp.registration)
		free(core_context, manager.allocator)
		return INVALID_COMPONENT_HANDLE, false
	}

	// Patch the handle into the resident slot; the handle_map only
	// copies the Loaded_Component by value, so handle.idx/gen on the
	// stack copy are still 0.
	resident, found := hm.get(&registry.slots, handle)
	if !found {
		log.errorf("[%s] Slot vanished after add for '%s'.", component_kind_name(registry.kind), comp.id_name)
		return INVALID_COMPONENT_HANDLE, false
	}
	resident.handle = handle
	resident.ctx.handle = handle
	resident.lib.state = .Registered
	registry.by_name[resident.id_name] = handle

	// by_type: only meaningful for Module/Plugin (Lib_Type is a real
	// category). Extensions skip.
	if registry.kind != .Extension {
		lib_type := descriptor.type
		append(&registry.by_type[lib_type], handle)
	}

	// Promote services/resources/events into the global registries.
	// (Only Module kind actually uses services/resources/events today;
	// other kinds will too once they're fleshed out.)
	if !component_promote_registrations(
		&manager.registry,
		handle,
		&GLOBAL_SERVICE_REGISTRY,
		&GLOBAL_RESOURCE_REGISTRY,
		&GLOBAL_EVENT_REGISTRY,
	) {
		log.errorf(
			"[%s] Failed to promote registrations for '%s'.",
			component_kind_name(registry.kind),
			resident.id_name,
		)
		component_unpromote_registrations(
			&manager.registry,
			handle,
			&GLOBAL_SERVICE_REGISTRY,
			&GLOBAL_RESOURCE_REGISTRY,
			&GLOBAL_EVENT_REGISTRY,
		)
		loaded_lib_shutdown(&resident.lib, &lib_context)
		delete(resident.id_name, manager.allocator)
		component_registration_destroy(&resident.registration)
		free(core_context, manager.allocator)
		_, _ = hm.remove(&registry.slots, handle)
		return INVALID_COMPONENT_HANDLE, false
	}

	log.infof(
		"[%s] Loaded '%s' [%d:%d].",
		component_kind_name(registry.kind),
		resident.id_name,
		handle.idx,
		handle.gen,
	)

	return handle, true
}

// ============================================================================
// LOAD PROJECT (project.toml-driven discovery)
// ============================================================================

component_manager_load_project :: proc(manager: ^Component_Manager, entries: [dynamic]Component_Project_Entry) -> bool {
	if manager == nil || !manager.initialized do return false

	bin_dir, derr := os.get_executable_directory(context.allocator)
	if derr != nil {
		log.errorf("[%s] Failed to get executable directory: %v", component_kind_name(manager.registry.kind), derr)
		return false
	}
	defer delete(bin_dir)

	loaded_count := 0
	loaded_failed_required := false
	for entry in entries {
		if !entry.enabled do continue

		dll_name := fmt.tprintf("%s.dll", entry.name)
		rel_path, jerr := filepath.join({bin_dir, dll_name}, context.allocator)
		if jerr != nil {
			log.errorf("[%s] Failed to join DLL path for '%s': %v", component_kind_name(manager.registry.kind), entry.name, jerr)
			if entry.required do loaded_failed_required = true
			continue
		}

		if !os.exists(rel_path) {
			if entry.required {
				log.errorf(
					"[%s] Required DLL not found: %s (path=%s)",
					component_kind_name(manager.registry.kind),
					entry.name,
					rel_path,
				)
				loaded_failed_required = true
			} else {
				log.warnf("[%s] DLL not found, skipping: %s", component_kind_name(manager.registry.kind), rel_path)
			}
			delete(rel_path)
			continue
		}

		handle, ok := component_load_one(manager, rel_path)
		delete(rel_path)
		if !ok {
			log.errorf("[%s] Failed to load: %s", component_kind_name(manager.registry.kind), entry.name)
			if entry.required do loaded_failed_required = true
			continue
		}
		loaded_count += 1
		_ = handle
	}

	if loaded_failed_required {
		component_manager_unload_all(manager)
		return false
	}
	log.infof("[%s] Loaded %d DLLs.", component_kind_name(manager.registry.kind), loaded_count)
	return true
}

// ============================================================================
// DEPENDENCY RESOLUTION (DFS post-order)
// ============================================================================

component_manager_resolve :: proc(
	manager: ^Component_Manager,
	extra_module_lookup: proc(name: string) -> (ComponentHandle, bool) = nil,
) -> bool {
	if manager == nil || !manager.initialized do return false
	registry := &manager.registry

	resize(&registry.dependency_order, 0)

	required_state_count := registry.slots.items.len
	if len(registry.visit_state) != required_state_count {
		resize(&registry.visit_state, required_state_count)
	}
	for i in 0 ..< len(registry.visit_state) {
		registry.visit_state[i] = .Unvisited
	}

	it := hm.dynamic_iterator_make(&registry.slots)
	for comp, handle in hm.iterate(&it) {
		if comp.state == .Unloaded || comp.state == .Failed do continue
		if !component_resolve_visit(registry, handle, extra_module_lookup) {
			resize(&registry.dependency_order, 0)
			log.errorf("%s dependency resolution failed.", component_kind_name(registry.kind))
			return false
		}
	}

	log.infof(
		"%s dependency resolution complete. %d components in load order.",
		component_kind_name(registry.kind),
		len(registry.dependency_order),
	)
	return true
}

@(private)
component_resolve_visit :: proc(
	registry: ^Component_Registry,
	handle: ComponentHandle,
	extra_module_lookup: proc(name: string) -> (ComponentHandle, bool),
) -> bool {
	if registry == nil do return false
	comp, ok := component_registry_get(registry, handle)
	if !ok do return false

	if int(handle.idx) >= len(registry.visit_state) {
		log.errorf("%s handle [%d:%d] index out of range for visit state.", component_kind_name(registry.kind), handle.idx, handle.gen)
		return false
	}

	switch registry.visit_state[handle.idx] {
	case .Visited:
		return true
	case .Visiting:
		log.errorf("Cyclic %s dependency detected at '%s'.", component_kind_name(registry.kind), comp.id_name)
		return false
	case .Unvisited:
	}

	registry.visit_state[handle.idx] = .Visiting

	dep_count := comp.descriptor.dependency_count
	if dep_count > 0 && comp.descriptor.dependencies == nil {
		log.errorf(
			"%s '%s' reports %d dependencies but has a null dependency array.",
			component_kind_name(registry.kind),
			comp.id_name,
			dep_count,
		)
		registry.visit_state[handle.idx] = .Unvisited
		return false
	}

	for i: u32 = 0; i < dep_count; i += 1 {
		dep := comp.descriptor.dependencies[i]
		dep_name := string(dep.name)

		// Try the same-kind registry first (extensions depend on
		// other extensions, plugins on other plugins).
		if dep_handle, found := component_lookup_by_name(registry, dep_name); found {
			dep_comp, valid := component_registry_get(registry, dep_handle)
			if !valid {
				log.errorf("%s '%s': dependency '%s' has an invalid handle.", component_kind_name(registry.kind), comp.id_name, dep_name)
				registry.visit_state[handle.idx] = .Unvisited
				return false
			}
			if !version_satisfies(dep_comp.descriptor.version, dep) {
				if dep.optional {
					log.warnf("%s '%s': optional dependency '%s' version mismatch.", component_kind_name(registry.kind), comp.id_name, dep_name)
					continue
				}
				log.errorf("%s '%s': dependency '%s' version mismatch.", component_kind_name(registry.kind), comp.id_name, dep_name)
				registry.visit_state[handle.idx] = .Unvisited
				return false
			}
			if !component_resolve_visit(registry, dep_handle, extra_module_lookup) {
				registry.visit_state[handle.idx] = .Unvisited
				return false
			}
			continue
		}

		// Try module registry next (extensions / plugins can depend
		// on modules). If a caller passed extra_module_lookup, that
		// takes precedence (e.g. when resolving extensions, prefer
		// the engine's module registry).
		if extra_module_lookup != nil {
			if mod_handle, found := extra_module_lookup(dep_name); found {
				mod_comp, valid := module_registry_get(cast(^Module_Registry)&GLOBAL_MODULE_MANAGER.registry, mod_handle)
				if !valid || !version_satisfies(mod_comp.descriptor.version, dep) {
					if dep.optional {
						log.warnf("%s '%s': optional module dependency '%s' unsatisfied.", component_kind_name(registry.kind), comp.id_name, dep_name)
						continue
					}
					log.errorf("%s '%s': module dependency '%s' unsatisfied.", component_kind_name(registry.kind), comp.id_name, dep_name)
					registry.visit_state[handle.idx] = .Unvisited
					return false
				}
				continue
			}
		} else if mod_handle, found := module_find(cast(^Module_Registry)&GLOBAL_MODULE_MANAGER.registry, dep_name); found {
			mod_comp, valid := module_registry_get(cast(^Module_Registry)&GLOBAL_MODULE_MANAGER.registry, mod_handle)
			if !valid || !version_satisfies(mod_comp.descriptor.version, dep) {
				if dep.optional {
					log.warnf("%s '%s': optional module dependency '%s' unsatisfied.", component_kind_name(registry.kind), comp.id_name, dep_name)
					continue
				}
				log.errorf("%s '%s': module dependency '%s' unsatisfied.", component_kind_name(registry.kind), comp.id_name, dep_name)
				registry.visit_state[handle.idx] = .Unvisited
				return false
			}
			continue
		}

		// Unresolved.
		if dep.optional {
			log.warnf("%s '%s': optional dependency '%s' not loaded.", component_kind_name(registry.kind), comp.id_name, dep_name)
			continue
		}
		log.errorf("%s '%s' requires dependency '%s' (not found).", component_kind_name(registry.kind), comp.id_name, dep_name)
		registry.visit_state[handle.idx] = .Unvisited
		return false
	}

	registry.visit_state[handle.idx] = .Visited
	append(&registry.dependency_order, handle)
	return true
}

// ============================================================================
// ACTIVATE / DEACTIVATE / UNLOAD
// ============================================================================

component_manager_activate_all :: proc(manager: ^Component_Manager) -> bool {
	if manager == nil || !manager.initialized do return false
	registry := &manager.registry

	order := registry.dependency_order[:]
	for handle in order {
		comp, ok := component_registry_get(registry, handle)
		if !ok do continue
		if comp.state != .Registered do continue

		log.infof("Activating %s: %s", component_kind_name(registry.kind), comp.id_name)

		lib_ctx := Lib_Context {
			api       = &CORE_LIB_CONTEXT_API,
			user_data = rawptr(comp.core_context),
		}
		if !loaded_lib_activate(&comp.lib, &lib_ctx) {
			log.errorf("Failed to activate %s '%s'.", component_kind_name(registry.kind), comp.id_name)
			component_manager_deactivate_all(manager)
			return false
		}
		comp.state = .Active
	}
	return true
}

component_manager_deactivate_all :: proc(manager: ^Component_Manager) {
	if manager == nil || !manager.initialized do return
	registry := &manager.registry

	order := registry.dependency_order[:]
	for i := len(order) - 1; i >= 0; i -= 1 {
		handle := order[i]
		comp, ok := component_registry_get(registry, handle)
		if !ok do continue
		if comp.state != .Active do continue

		lib_ctx := Lib_Context {
			api       = &CORE_LIB_CONTEXT_API,
			user_data = rawptr(comp.core_context),
		}
		loaded_lib_deactivate(&comp.lib, &lib_ctx)
		comp.state = .Registered
	}
}

component_manager_unload_all :: proc(manager: ^Component_Manager) {
	if manager == nil || !manager.initialized do return
	registry := &manager.registry

	component_manager_deactivate_all(manager)

	order := registry.dependency_order[:]
	for i := len(order) - 1; i >= 0; i -= 1 {
		handle := order[i]
		comp, ok := component_registry_get(registry, handle)
		if !ok do continue

		// Pull registrations out of the global registries first so
		// the registry's defensive destroy() doesn't double-free.
		component_unpromote_registrations(
			registry,
			handle,
			&GLOBAL_SERVICE_REGISTRY,
			&GLOBAL_RESOURCE_REGISTRY,
			&GLOBAL_EVENT_REGISTRY,
		)

		lib_ctx := Lib_Context {
			api       = &CORE_LIB_CONTEXT_API,
			user_data = rawptr(comp.core_context),
		}
		if comp.state == .Registered || comp.state == .Loaded {
			loaded_lib_shutdown(&comp.lib, &lib_ctx)
			comp.state = .Unloaded
		}

		// Drop by_type entry.
		if registry.kind != .Extension {
			lib_type := comp.descriptor.type
			handles := &registry.by_type[lib_type]
			for j := 0; j < len(handles^); j += 1 {
				if handles[j] == handle {
					unordered_remove(handles, j)
					break
				}
			}
		}

		// Drop by_name entry.
		if existing, found := registry.by_name[comp.id_name]; found {
			if existing == handle {
				delete_key(&registry.by_name, comp.id_name)
			}
		}

		component_registration_destroy(&comp.registration)

		if comp.core_context != nil {
			free(comp.core_context, manager.allocator)
			comp.core_context = nil
		}

		if len(comp.id_name) > 0 {
			delete(comp.id_name, manager.allocator)
			comp.id_name = ""
		}

		_, _ = hm.remove(&registry.slots, handle)
	}
	resize(&registry.dependency_order, 0)
}

// ============================================================================
// REGISTRATION BUCKET HELPERS
// ============================================================================

@(private)
component_registration_init :: proc(reg: ^Component_Registration, allocator: mem.Allocator) {
	if reg == nil do return
	reg.services  = make([dynamic]Service_Registration, 0, allocator)
	reg.systems   = make([dynamic]System_Registration, 0, allocator)
	reg.resources = make([dynamic]Resource_Registration, 0, allocator)
	reg.events    = make([dynamic]Event_Registration, 0, allocator)
	reg.targets   = make([dynamic]Extension_Target, 0, allocator)
}

@(private)
component_registration_destroy :: proc(reg: ^Component_Registration) {
	if reg == nil do return
	delete(reg.services)
	delete(reg.systems)
	delete(reg.resources)
	delete(reg.events)
	delete(reg.targets)
	reg^ = {}
}

@(private)
component_promote_registrations :: proc(
	registry: ^Component_Registry,
	handle: ComponentHandle,
	service_registry: ^Service_Registry,
	resource_registry: ^Resource_Registry,
	event_registry: ^Event_Registry,
) -> bool {
	if registry == nil || !registry.initialized do return false
	comp, ok := component_registry_get(registry, handle)
	if !ok do return false

	for &s in comp.registration.services {
		s_handle, s_ok := service_register(service_registry, handle, s)
		if !s_ok do return false
		_ = s_handle
	}
	for &r in comp.registration.resources {
		r_handle, r_ok := resource_register(resource_registry, handle, r)
		if !r_ok do return false
		_ = r_handle
	}
	for &e in comp.registration.events {
		e_handle, e_ok := event_register(event_registry, handle, e)
		if !e_ok do return false
		_ = e_handle
	}
	return true
}

@(private)
component_unpromote_registrations :: proc(
	registry: ^Component_Registry,
	handle: ComponentHandle,
	service_registry: ^Service_Registry,
	resource_registry: ^Resource_Registry,
	event_registry: ^Event_Registry,
) -> int {
	if registry == nil || !registry.initialized do return 0
	comp, ok := component_registry_get(registry, handle)
	if !ok do return 0

	count := 0
	if service_registry != nil {
		count += service_unregister_all_owned(service_registry, handle)
	}
	if resource_registry != nil {
		count += resource_unregister_all_owned(resource_registry, handle)
	}
	if event_registry != nil {
		count += event_unregister_all_owned(event_registry, handle)
	}

	clear(&comp.registration.services)
	clear(&comp.registration.resources)
	clear(&comp.registration.events)
	return count
}

// ============================================================================
// KIND-SPECIFIC POST-REGISTER (extension target validation)
// ============================================================================

// Extension_Target identifies a module an extension augments.
Extension_Target :: struct {
	module:      ComponentHandle,
	min_version: Version,
	max_version: Version,
}

@(private)
component_kind_post_register :: proc(
	registry: ^Component_Registry,
	comp: ^Loaded_Component,
) -> bool {
	if registry == nil || comp == nil do return false

	switch registry.kind {
	case .Extension:
		// Extensions must declare at least one target and every
		// target must point at a valid, in-range module.
		if len(comp.registration.targets) == 0 {
			log.errorf("Extension '%s' has no target modules.", comp.id_name)
			return false
		}
		for target in comp.registration.targets {
			mod, found := module_registry_get(cast(^Module_Registry)&GLOBAL_MODULE_MANAGER.registry, target.module)
			if !found {
				log.errorf("Extension '%s' targets an invalid module handle.", comp.id_name)
				return false
			}
			actual := mod.descriptor.version
			if !version_in_range(actual, target.min_version, target.max_version) {
				log.errorf(
					"Extension '%s' target module '%s' has incompatible version %d.%d.%d.",
					comp.id_name,
					mod.descriptor.name,
					actual.major, actual.minor, actual.patch,
				)
				return false
			}
		}
	case .Module, .Plugin:
		// Nothing to validate beyond the descriptor checks done
		// during load.
	}
	return true
}

// ============================================================================
// COLLECT-BY-TYPE
// ============================================================================

component_collect_by_type :: proc(
	registry: ^Component_Registry,
	lib_type: Lib_Type,
	allocator: mem.Allocator,
) -> [dynamic]ComponentHandle {
	result := make([dynamic]ComponentHandle, 0, allocator)
	if registry == nil || !registry.initialized do return result
	for handle in registry.by_type[lib_type] {
		if component_is_valid(registry, handle) {
			append(&result, handle)
		}
	}
	return result
}

// ============================================================================
// HELPERS
// ============================================================================

component_kind_name :: proc(kind: Component_Kind) -> string {
	switch kind {
	case .Module:    return "Module"
	case .Extension: return "Extension"
	case .Plugin:    return "Plugin"
	}
	return "Component"
}

// Component_Project_Entry is the per-component slice of project.toml.
// Project_Settings holds three of these (modules / extensions / plugins)
// via these structs.
Component_Project_Entry :: struct {
	name:     string,
	version:  Version,
	enabled:  bool,
	required: bool,
}
