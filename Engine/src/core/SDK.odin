// Engine\src\Core\SDK.odin
package Core

import "core:log"
import mth "BF_Math"
import hm "core:container/handle_map"

// **SDK - Public engine API.
//
// Game code, modules, and plugins should use SDK procedures rather than
// reaching directly into engine implementation details. The SDK deliberately
// accepts `^Module_Registry`, `^Extension_Registry`, `^Service_Registry` so it
// can be tested with isolated registries; the engine passes its globals
// through these entry points.
//
// Forward-declared procedures (e.g. emit_event, asset_load) are
// intentionally only signatures here — their implementations live in the
// modules that own each subsystem. They log a warning if called before
// the corresponding module is loaded so missing-module bugs are loud.
// ============================================================================

//* ENGINE
engine_is_editor  :: proc() -> bool { return RUN_EDITOR }
engine_is_running :: proc() -> bool { return ENGINE_RUNNING }
engine_delta_time :: proc() -> f32 {
	// No historical dt storage on the engine side; modules track their
	// own. Return 0 for v1; future code can plumb a last_dt in.
	return 0
}

//* EXTENSIONS
extension_find :: proc(registry: ^Extension_Registry, name: string) -> (ExtensionHandle, bool) {
	if registry == nil do return INVALID_EXTENSION_HANDLE, false
	return component_lookup_by_name(registry, name)
}
extension_is_loaded :: proc(registry: ^Extension_Registry, handle: ExtensionHandle) -> bool {
	if registry == nil do return false
	return component_is_loaded(registry, handle)
}
extension_is_active :: proc(registry: ^Extension_Registry, handle: ExtensionHandle) -> bool {
	if registry == nil do return false
	return component_is_active(registry, handle)
}
extension_version :: proc(registry: ^Extension_Registry, handle: ExtensionHandle) -> Version {
	ext, ok := component_registry_get(registry, handle)
	if !ok do return Version{}
	return ext.descriptor.version
}

//* SERVICES
service_find :: proc(registry: ^Service_Registry, name: string) -> (ServiceHandle, bool) {
	if registry == nil || !registry.initialized do return INVALID_SERVICE_HANDLE, false
	if len(name) == 0 do return INVALID_SERVICE_HANDLE, false
	handle, found := registry.by_name[name]
	if !found do return INVALID_SERVICE_HANDLE, false
	if _, valid := service_registry_get(registry, handle); !valid do return INVALID_SERVICE_HANDLE, false
	return handle, true
}
// service_get returns the service instance for the given handle.
service_get :: proc(registry: ^Service_Registry, handle: ServiceHandle) -> rawptr {
	service, ok := service_registry_get(registry, handle)
	if !ok do return nil
	return service.instance
}

//* RESOURCES
resource_find :: proc(registry: ^Resource_Registry, name: string) -> (ResourceHandle, bool) {
	if registry == nil || !registry.initialized do return INVALID_RESOURCE_HANDLE, false
	if len(name) == 0 do return INVALID_RESOURCE_HANDLE, false
	handle, found := registry.by_name[name]
	if !found do return INVALID_RESOURCE_HANDLE, false
	if _, valid := resource_registry_get(registry, handle); !valid do return INVALID_RESOURCE_HANDLE, false
	return handle, true
}

resource_get :: proc(registry: ^Resource_Registry, handle: ResourceHandle) -> rawptr {
	resource, ok := resource_registry_get(registry, handle)
	if !ok do return nil
	return resource.instance
}

//* EVENTS
event_find :: proc(registry: ^Event_Registry, name: string) -> (EventHandle, bool) {
	if registry == nil || !registry.initialized do return INVALID_EVENT_HANDLE, false
	if len(name) == 0 do return INVALID_EVENT_HANDLE, false
	handle, found := registry.by_name[name]
	if !found do return INVALID_EVENT_HANDLE, false
	if _, valid := event_registry_get(registry, handle); !valid do return INVALID_EVENT_HANDLE, false
	return handle, true
}

// emit_event pushes an event payload onto the engine's event bus. The
// bus itself is owned by a future module; until then this is a stub
// that warns so missing-module bugs are obvious during development.
emit_event :: proc(event: rawptr) {
	_ = event
	log.warn("[SDK] emit_event: event bus not implemented yet; event dropped.")
}

//* ASSETS
asset_load   :: proc(path: string) -> rawptr {
	_ = path
	log.warn("[SDK] asset_load: asset subsystem not implemented yet.")
	return nil
}
asset_unload :: proc(asset: rawptr) {
	_ = asset
	log.warn("[SDK] asset_unload: asset subsystem not implemented yet.")
}

//* GAME-SIDE SYSTEM REGISTRATION
//
// Game code (i.e. the application embedding the engine) registers systems
// here during Engine_App_Interface.on_init. Modules register theirs through
// their own `module_registration.add_system` path; the engine merges both
// sources during scheduler_build.
//
// Game code MUST go through this SDK and MUST NOT import any module
// package (BF_DAG, BF_ECS, Bifrost_Renderer, ...) directly. Module choice
// for "the scheduler", "the ECS World", etc. is the engine's decision;
// concrete services are still looked up by stable name by Core helpers
// (e.g. engine_get_ecs_world) rather than by the application importing
// BF_ECS.

@(private)
GLOBAL_GAME_SYSTEMS: [dynamic]System_Entry

// Game-side dependency edges between named systems. Resolved to
// System_Dependency (with numeric IDs) by scheduler_build.
Game_System_Dependency :: struct {
	before_name: string,
	after_name:  string,
}
@(private)
GLOBAL_GAME_DEPENDENCIES: [dynamic]Game_System_Dependency
@(private)
GLOBAL_GAME_REGISTRY_INITIALIZED: bool

@(private)
game_registry_init_if_needed :: proc() {
	if GLOBAL_GAME_REGISTRY_INITIALIZED do return
	GLOBAL_GAME_SYSTEMS = make([dynamic]System_Entry, context.allocator)
	GLOBAL_GAME_DEPENDENCIES = make(
		[dynamic]Game_System_Dependency,
		context.allocator,
	)
	GLOBAL_GAME_REGISTRY_INITIALIZED = true
}

// engine_register_system adds a system to the game-side registry. The
// engine merges this list into the Frame_DAG during scheduler_build.
//
// Returns false on duplicate name or nil callback. Game code is expected
// to register all systems during Engine_App_Interface.on_init; runtime
// registration (or recompilation of the DAG) is not supported in v1.
engine_register_system :: proc(
	name: string,
	execute: proc(rawptr),
	info: System_Info = {}, // defaults: stage=.Update, empty masks
) -> bool {
	game_registry_init_if_needed()
	if execute == nil do return false
	if len(name) == 0 do return false

	// Reject duplicate game names so we get a clean DAG.
	for s in GLOBAL_GAME_SYSTEMS {
		if s.name == name {
			log.warn("[SDK] engine_register_system: duplicate name '%s'", name)
			return false
		}
	}

	entry := System_Entry {
		name     = name,
		callback = execute,
		info     = info,
		id       = System_ID(u32(len(GLOBAL_GAME_SYSTEMS)) + 1),
	}
	append(&GLOBAL_GAME_SYSTEMS, entry)
	return true
}

// engine_register_system_dependency adds an explicit before/after edge
// between two game-registered systems. The IDs come back from
// engine_register_system and are reassigned by the engine during the DAG
// build; the engine resolves them by name at build time so callers don't
// have to track the internal ID space.
//
// Module-side systems are not reachable from this entry point; modules
// expose their own dependency mechanism via System_Info masks.
engine_register_system_dependency :: proc(before_name, after_name: string) -> bool {
	game_registry_init_if_needed()
	dep := Game_System_Dependency{before_name = before_name, after_name = after_name}
	append(&GLOBAL_GAME_DEPENDENCIES, dep)
	return true
}

//* ECS
//
// entity_create / entity_destroy are owned by the BF_ECS module. Until
// that module is loaded these stubs warn and return nil so a missing
// dependency is obvious during development.
entity_create :: proc() -> rawptr {
	log.warn("[SDK] entity_create: BF_ECS not loaded.")
	return nil
}
entity_destroy :: proc(entity: rawptr) {
	_ = entity
	log.warn("[SDK] entity_destroy: BF_ECS not loaded.")
}

//* RENDERING
//
// Renderers register Submit / Present as DAG systems with stage
// .Render / .PostRender rather than going through these procs. These
// stubs remain so legacy code keeps linking; new code should register
// systems via engine_register_system instead.
renderer_begin_frame :: proc() {
	log.warn("[SDK] renderer_begin_frame: deprecated. Register a .PreRender system instead.")
}
renderer_end_frame :: proc() {
	log.warn("[SDK] renderer_end_frame: deprecated. Register a .PostRender system instead.")
}

//* AUDIO
audio_play :: proc(sound: rawptr) {
	_ = sound
	log.warn("[SDK] audio_play: audio module not loaded.")
}

//* PHYSICS
physics_raycast :: proc() -> bool {
	log.warn("[SDK] physics_raycast: physics module not loaded.")
	return false
}

//* SHARED TYPES
Asset_ID :: distinct u32 
ASSET_INVALID :: Asset_ID(0)
Scene_ID :: hm.Handle16

Asset_Ref :: struct {
	id: Asset_ID, 
	type: Asset_Type,
}

Asset_Type :: enum u8 {
	Unknown,
	Model,
	Mesh,
	Material,
	Texture,
	Shader,
	Skeleton,
	Animation,
	Particle,
	Audio,
	Physics_Shape,
	World,
}

Render_Flags :: bit_set[Render_Flag]
Render_Flag :: enum u8 {
	None,
}

Material_Override :: struct {
	// TBD: reference to override data/table
}