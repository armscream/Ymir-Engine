// Engine/src/Core/Library_Interface.odin
package Core

import "core:log"

// ============================================================================
// BIFROST DYNAMIC LIBRARY ABI
// ============================================================================
//
// This file defines the ABI shared between the Bifrost executable and
// dynamically loaded modules, extensions, and plugins.
//
// IMPORTANT:
//   - Keep this boundary C-compatible.
//   - Do not place Odin strings, dynamic arrays, maps, allocators, or other
//     runtime-owned structures directly into the ABI.
//   - Anything not marked @(private) below is part of the public ABI and
//     may be referenced by modules/extensions/plugins or by the SDK.
// ============================================================================

LIB_API_VERSION      :: u32(1)
LIB_CONTEXT_API_VERSION :: u32(1)
LIB_ENTRY_POINT_NAME :: "bifrost_lib_get_api"

// ============================================================================
// COMPONENT CATEGORIES
// ============================================================================

Component_Kind :: enum u32 {
	Module    = 0,
	Extension = 1,
	Plugin    = 2,
}

// ============================================================================
// LIFECYCLE PROCEDURES (used inside LIB_API, callable from Core)
// ============================================================================

Lib_Load_Proc      :: proc(ctx: ^Lib_Context) -> bool
Lib_Register_Proc  :: proc(ctx: ^Lib_Context) -> bool
Lib_Activate_Proc  :: proc(ctx: ^Lib_Context) -> bool
Lib_Deactivate_Proc:: proc(ctx: ^Lib_Context)
Lib_Unload_Proc    :: proc(ctx: ^Lib_Context)

LIB_API :: struct {
	descriptor: Lib_Descriptor,
	load:       Lib_Load_Proc,
	register:   Lib_Register_Proc,
	activate:   Lib_Activate_Proc,
	deactivate: Lib_Deactivate_Proc,
	unload:     Lib_Unload_Proc,
}

// Every Bifrost LIB must export:
//
//     bifrost_lib_get_api
//
// which returns a pointer to its static LIB_API.
Lib_Get_API_Proc :: proc() -> ^LIB_API

// ============================================================================
// LIFECYCLE STATE
// ============================================================================
//
// Component_State is shared across Module / Extension / Plugin / and the
// physical Loaded_Lib itself. The Failed arm is only meaningful at the
// component level (a misbehaving module/extension/plugin); for a bare
// Loaded_Lib it can never be reached because Core controls that transition.
Component_State :: enum u32 {
	Unloaded,
	Loaded,
	Registered,
	Active,
	Failed,
}

// ============================================================================
// LIB TYPE / FLAGS / CAPABILITIES (in the descriptor — ABI)
// ============================================================================

Lib_Type :: enum u32 {
	Engine,
	Renderer,
	Scheduler,
	Input,
	ECS,
	Physics,
	Audio,
	UI,
	Scripting,
	Replication,
	Editor,
	Debug,
	Renderer_Extension,
	Other,
}

Lib_Flags :: bit_set[Lib_Flag]

Lib_Flag :: enum u32 {
	None,
	Editor_Only,
	Runtime,
	Optional,
	// TODO(hot-reload): Hot_Reloadable is declared but unimplemented.
	// Implementation plan (v1.1+):
	//   1. module_unload_one already calls deactivate → unpromote → DLL
	//      free → slot release in reverse dependency order.
	//   2. Add module_reload_one(manager, handle, path) that:
	//        a) snapshots the module's manifest (descriptor + registrations)
	//        b) calls module_unload_one
	//        c) calls module_manager_load with the same path
	//        d) re-runs dependency resolution on the affected subgraph
	//        e) re-activates dependents in topo order, calling their
	//           "rebind" notification (new Module_Context.api field:
	//           proc(ctx, kind, name, instance)).
	//   3. Respect Hot_Reloadable at register time: a module that did
	//      not declare it should refuse reload with a clear error.
	//   4. Locking: a single global RW lock on the manager during
	//      reload; modules being reloaded are marked Reloading and
	//      other modules' systems skip them for one frame.
	Hot_Reloadable,
	Provides_Service,
	Provides_Systems,
}

Component_Capabilities :: bit_set[Component_Capability]

Component_Capability :: enum u32 {
	Renderer,
	Input,
	ECS,
	Physics,
	Audio,
	UI,
	Scripting,
	Replication,
	Editor,
	Debug,
	Networking,
	GPU,
	Materials,
	Textures,
	Animation,
	Particles,
	Navigation,
	Custom,
}

// ============================================================================
// DESCRIPTOR / DEPENDENCY (ABI)
// ============================================================================

Lib_Descriptor :: struct {
	api_version:      u32,
	name:             cstring,
	version:          Version,
	author:           cstring,
	description:      cstring,
	component_kind:   Component_Kind,
	type:             Lib_Type,
	flags:            Lib_Flags,
	capabilities:     Component_Capabilities,
	dependencies:     []Lib_Dependency,
	dependency_count: u32,
	metadata:         rawptr,
}

Lib_Dependency :: struct {
	name:            cstring,
	min_version:     Version,
	max_version:     Version,
	has_min_version: bool,
	has_max_version: bool,
	optional:        bool,
}

// ============================================================================
// LIB CONTEXT (ABI)
// ============================================================================
//
// The LIB receives this context and uses lib_context_query() to obtain typed
// interfaces (e.g. module_registration). The context itself is intentionally
// component-type agnostic.
//
// Conservative ABI:
//   - rawptr
//   - cstring
//   - fixed-width integers
//   - function pointers
//
// Avoid in the ABI:
//   - string
//   - [dynamic]T
//   - map
//   - mem.Allocator
//   - Odin-specific containers
// ============================================================================

Lib_Context :: struct {
	api:       ^Lib_Context_API,
	user_data: rawptr,
}

Lib_Context_API :: struct {
	api_version: u32,
	// query_interface is intentionally component-type agnostic.
	// A library asks for a typed interface by cstring id (e.g. "module_registration")
	// and the host returns a pointer to that interface or nil.
	query_interface: proc(user_data: rawptr, interface_id: cstring, version: u32) -> rawptr,
}

// lib_context_is_valid: validates that a context supplied by a LIB points at
// a Core-installed Lib_Context_API with the matching version.
lib_context_is_valid :: proc(ctx: ^Lib_Context) -> bool {
	if ctx == nil || ctx.api == nil do return false
	if ctx.api.api_version != LIB_CONTEXT_API_VERSION do return false
	return true
}

// lib_context_query: returns nil if not available.
lib_context_query :: proc(ctx: ^Lib_Context, interface_id: cstring, version: u32) -> rawptr {
	if !lib_context_is_valid(ctx) do return nil
	if ctx.api.query_interface == nil do return nil
	return ctx.api.query_interface(ctx.user_data, interface_id, version)
}

// ============================================================================
// HOST QUERY IMPLEMENTATION (Core-internal)
// ============================================================================
//
// This is the only place in Core that knows how to map an interface_id to a
// concrete typed API. The dispatch is on (interface_id, version); both must
// match for a non-nil pointer to come back. Mismatched versions return nil
// rather than risk an ABI mismatch silently working.
// ============================================================================

CORE_LIB_INTERFACE_COMPONENT_REGISTRATION :: "component_registration"
CORE_LIB_INTERFACE_COMPONENT_CONTEXT       :: "component_context"
CORE_LIB_INTERFACE_MODULE_CONTEXT          :: "module_context" // legacy
CORE_LIB_INTERFACE_SERVICE_REGISTRY        :: "service_registry"
CORE_LIB_INTERFACE_RESOURCE_REGISTRY       :: "resource_registry"
CORE_LIB_INTERFACE_EVENT_REGISTRY          :: "event_registry"
CORE_LIB_INTERFACE_PROJECT_SETTINGS        :: "project_settings"

COMPONENT_REGISTRATION_API_VERSION :: u32(1)
COMPONENT_CONTEXT_API_VERSION      :: u32(1)
MODULE_CONTEXT_API_VERSION         :: u32(1)
SERVICE_REGISTRY_API_VERSION       :: u32(1)
RESOURCE_REGISTRY_API_VERSION      :: u32(1)
EVENT_REGISTRY_API_VERSION         :: u32(1)
PROJECT_SETTINGS_API_VERSION       :: u32(1)

// Core_Lib_Context is the host-side user_data handed to every loaded component.
// Components must call lib_context_query() to obtain typed interfaces.
//
// project_settings points at the *engine's* GLOBAL_PROJECT_SETTINGS (NOT
// the DLL's per-package copy). Core globals are duplicated into every DLL
// when a package is imported, so a DLL calling `Core.project_settings_get()`
// directly would only read its own zero-valued copy. Going through
// lib_context_query routes the lookup to engine memory via this pointer,
// so DLLs see the same data the engine sees.
//
// component_context points at the per-component Component_Context. Every
// DLL (module / extension / plugin) receives one; the engine allocates
// it during component_load_one and frees it during unload. Modules can
// also read the legacy `module_context` pointer (kept for backward
// compat with code that hasn't migrated yet).
@(private)
Core_Lib_Context :: struct {
	manager:           rawptr, // ^Component_Manager
	module_context:    ^Module_Context,   // legacy; nil for non-module components
	component_context: ^Component_Context, // unified; populated for every component kind
	project_settings:  ^Project_Settings,
}

@(private)
core_lib_query_interface :: proc(
	user_data: rawptr,
	interface_id: cstring,
	version: u32,
) -> rawptr {
	if interface_id == nil do return nil

	// project_settings is special: it lives in the host's address space
	// (passed via user_data) and the same pointer is handed back to any
	// DLL that asks for it. The handle-map-backed registries are still
	// safe to hand out as rawptrs because the registry's internal
	// dynamic arrays are *also* engine-owned — the DLL's globals are
	// never consulted when servicing a query for one of those.
	switch interface_id {
	case CORE_LIB_INTERFACE_PROJECT_SETTINGS:
		if version != PROJECT_SETTINGS_API_VERSION do return nil
		if user_data == nil do return nil
		core_ctx := cast(^Core_Lib_Context)user_data
		if core_ctx.project_settings == nil do return nil
		return cast(rawptr)core_ctx.project_settings

	case CORE_LIB_INTERFACE_COMPONENT_REGISTRATION:
		if version != COMPONENT_REGISTRATION_API_VERSION do return nil
		return cast(rawptr)&GLOBAL_COMPONENT_REGISTRATION_API

	case CORE_LIB_INTERFACE_COMPONENT_CONTEXT:
		if version != COMPONENT_CONTEXT_API_VERSION do return nil
		if user_data == nil do return nil
		core_ctx := cast(^Core_Lib_Context)user_data
		if core_ctx.component_context == nil do return nil
		return cast(rawptr)core_ctx.component_context

	case CORE_LIB_INTERFACE_MODULE_CONTEXT:
		if version != MODULE_CONTEXT_API_VERSION do return nil
		if user_data == nil do return nil
		core_ctx := cast(^Core_Lib_Context)user_data
		if core_ctx.module_context == nil do return nil
		return cast(rawptr)core_ctx.module_context

	case CORE_LIB_INTERFACE_SERVICE_REGISTRY:
		if version != SERVICE_REGISTRY_API_VERSION do return nil
		return cast(rawptr)&GLOBAL_SERVICE_REGISTRY
	case CORE_LIB_INTERFACE_RESOURCE_REGISTRY:
		if version != RESOURCE_REGISTRY_API_VERSION do return nil
		return cast(rawptr)&GLOBAL_RESOURCE_REGISTRY
	case CORE_LIB_INTERFACE_EVENT_REGISTRY:
		if version != EVENT_REGISTRY_API_VERSION do return nil
		return cast(rawptr)&GLOBAL_EVENT_REGISTRY
	}
	return nil
}

@(private)
CORE_LIB_CONTEXT_API: Lib_Context_API = {
	api_version     = LIB_CONTEXT_API_VERSION,
	query_interface = core_lib_query_interface,
}

// ============================================================================
// DYNAMIC LIBRARY HANDLE (Core-internal)
// ============================================================================
//
// Wraps an OS-level shared-library handle. Lives entirely inside Core; the
// platform files (Platform_*.odin) supply the open/close/symbol procs.
// ============================================================================

@(private)
Dynamic_Library :: struct {
	handle: rawptr,
	path:   string,
	loaded: bool,
}

// ============================================================================
// LIB LOADER (Core-internal)
// ============================================================================
//
// Drives the physical DLL load, finds bifrost_lib_get_api, validates the ABI
// version, and produces a Loaded_Lib.
// ============================================================================

@(private)
Lib_Loader :: struct {
	library: Dynamic_Library,
	api:     ^LIB_API,
}

@(private)
Loaded_Lib :: struct {
	loader: Lib_Loader,
	state:  Component_State,
}

// ============================================================================
// DYNAMIC LIBRARY PROCS (Core-internal; supplied by Platform_*.odin)
// ============================================================================
//
// Each Platform_*.odin file is expected to define:
//
//   dynamic_library_open   :: proc(path: string) -> (Dynamic_Library, bool)
//   dynamic_library_close  :: proc(library: ^Dynamic_Library)
//   dynamic_library_symbol :: proc(library: ^Dynamic_Library, name: string) -> rawptr
//
// All three are package-internal (marked @(private) in each Platform_*.odin
// file). Until Platform_Darwin.odin is implemented, building on macOS will
// fail to link — that is intentional.
// ============================================================================

// ============================================================================
// LIB LOADER PROCS
// ============================================================================

@(private)
lib_loader_load :: proc(loader: ^Lib_Loader, path: string) -> bool {
	if loader == nil do return false
	if loader.library.loaded do return false
	loader.api = nil

	// Open the dynamic library.
	library, ok := dynamic_library_open(path)
	if !ok {
		log.error("Bifrost LIB: failed to load:", path)
		return false
	}
	loader.library = library

	// Locate the common Bifrost entry point.
	symbol := dynamic_library_symbol(&loader.library, LIB_ENTRY_POINT_NAME)
	if symbol == nil {
		log.error("Bifrost LIB: failed to locate entry point:", LIB_ENTRY_POINT_NAME)
		dynamic_library_close(&loader.library)
		return false
	}

	// Convert the raw function pointer into the expected proc type.
	get_api := cast(Lib_Get_API_Proc)symbol
	api := get_api()
	if api == nil {
		log.error("Bifrost LIB: entry point returned nil API:", path)
		dynamic_library_close(&loader.library)
		return false
	}

	// Validate ABI version before doing anything else.
	if api.descriptor.api_version != LIB_API_VERSION {
		log.error(
			"Bifrost LIB: Incompatible ABI version:",
			api.descriptor.api_version,
			"expected:",
			LIB_API_VERSION,
		)
		dynamic_library_close(&loader.library)
		return false
	}

	// Validate required proc pointers.
	if api.load == nil ||
	   api.register == nil ||
	   api.activate == nil ||
	   api.deactivate == nil ||
	   api.unload == nil {
		log.error("Bifrost LIB: Missing required proc pointer, check the LIB API.")
		dynamic_library_close(&loader.library)
		return false
	}

	loader.api = api
	log.info("[LIB] Loaded:", path)
	return true
}

@(private)
lib_loader_unload :: proc(loader: ^Lib_Loader) {
	if loader == nil || !loader.library.loaded do return
	// Library's unload callback is called by Mod/Ext/Plugin manager who owns lifecycle.
	loader.api = nil
	// This only releases the dyn lib itself.
	dynamic_library_close(&loader.library)
}

@(private)
lib_loader_get_api :: proc(loader: ^Lib_Loader) -> ^LIB_API {
	if loader == nil do return nil
	return loader.api
}

@(private)
lib_loader_get_descriptor :: proc(loader: ^Lib_Loader) -> ^Lib_Descriptor {
	if loader == nil || loader.api == nil do return nil
	return &loader.api.descriptor
}

@(private)
lib_loader_is_loaded :: proc(loader: ^Lib_Loader) -> bool {
	if loader == nil do return false
	return loader.library.loaded
}

// ============================================================================
// LOADED_LIB PROCS
// ============================================================================

@(private)
loaded_lib_load :: proc(lib: ^Loaded_Lib, ctx: ^Lib_Context, path: string) -> bool {
	if lib == nil || ctx == nil do return false
	// Must start unloaded.
	if lib.state != .Unloaded do return false

	if !lib_context_is_valid(ctx) {
		log.error("Bifrost LIB: '%s' invalid context.", path)
		return false
	}
	if !lib_loader_load(&lib.loader, path) do return false

	api := lib.loader.api
	if api == nil {
		lib_loader_unload(&lib.loader)
		return false
	}
	if !api.load(ctx) {
		lib_loader_unload(&lib.loader)
		return false
	}

	lib.state = .Loaded
	return true
}

@(private)
loaded_lib_register :: proc(lib: ^Loaded_Lib, ctx: ^Lib_Context) -> bool {
	if lib == nil do return false
	if lib.loader.api == nil do return false
	if lib.state != .Loaded || ctx == nil do return false
	if !lib.loader.api.register(ctx) do return false

	lib.state = .Registered
	return true
}

@(private)
loaded_lib_activate :: proc(lib: ^Loaded_Lib, ctx: ^Lib_Context) -> bool {
	if lib == nil || lib.loader.api == nil do return false
	if lib.state != .Registered || ctx == nil do return false
	if !lib.loader.api.activate(ctx) do return false

	lib.state = .Active
	return true
}

@(private)
loaded_lib_deactivate :: proc(lib: ^Loaded_Lib, ctx: ^Lib_Context) -> bool {
	if lib == nil || lib.loader.api == nil do return false
	if lib.state != .Active || ctx == nil do return false
	lib.loader.api.deactivate(ctx)

	lib.state = .Registered
	return true
}

@(private)
loaded_lib_unload :: proc(lib: ^Loaded_Lib, ctx: ^Lib_Context) -> bool {
	if lib == nil || lib.loader.api == nil do return false
	if lib.state == .Active || ctx == nil do return false
	if lib.state != .Registered && lib.state != .Loaded do return false
	// If the lib was registered, give it its unload callback.
	if lib.state == .Registered do lib.loader.api.unload(ctx)

	lib_loader_unload(&lib.loader)
	lib.state = .Unloaded
	return true
}

// loaded_lib_shutdown is a convenience proc that drives a lib through
// deactivate -> unload in order. Safe to call from any state.
@(private)
loaded_lib_shutdown :: proc(lib: ^Loaded_Lib, ctx: ^Lib_Context) {
	if lib == nil do return
	if lib.state == .Active do loaded_lib_deactivate(lib, ctx)
	if lib.state == .Registered || lib.state == .Loaded do loaded_lib_unload(lib, ctx)
}

// State helpers
@(private)
loaded_lib_is_loaded :: proc(lib: ^Loaded_Lib) -> bool {
	if lib == nil do return false
	return lib.state != .Unloaded
}

@(private)
loaded_lib_is_registered :: proc(lib: ^Loaded_Lib) -> bool {
	if lib == nil do return false
	return lib.state == .Registered || lib.state == .Active
}

@(private)
loaded_lib_is_active :: proc(lib: ^Loaded_Lib) -> bool {
	if lib == nil do return false
	return lib.state == .Active
}

@(private)
loaded_lib_get_api :: proc(lib: ^Loaded_Lib) -> ^LIB_API {
	if lib == nil do return nil
	return lib.loader.api
}

@(private)
loaded_lib_get_descriptor :: proc(lib: ^Loaded_Lib) -> ^Lib_Descriptor {
	if lib == nil do return nil
	return lib_loader_get_descriptor(&lib.loader)
}