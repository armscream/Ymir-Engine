package Project

import "core:fmt"
import Engine "../Engine/src/Core"

RUN_EDITOR :: #config(RUN_EDITOR, false)

main :: proc() {
	fmt.println("========================================")
	fmt.println(" PROJECT START")
	fmt.println("========================================")

	fmt.println("RUN_EDITOR: ", RUN_EDITOR)

	fmt.println("Calling Engine.init()...")

	init_ok := Engine.init(
		&APP,          // ^Engine_App_Interface
		RUN_EDITOR,
	)

	fmt.println("Engine.init() returned: ", init_ok)

	if !init_ok {
		fmt.println("Engine initialization failed.")
		return
	}

	fmt.println("Calling Engine.run()...")

	Engine.run()

	fmt.println("Engine.run() returned.")

	fmt.println("Calling Engine.destroy()...")

	destroy_ok := Engine.destroy()

	fmt.println("Engine.destroy() returned: ", destroy_ok)

	if !destroy_ok {
		fmt.println("Failed to destroy engine properly.")
		return
	}

	fmt.println("========================================")
	fmt.println(" PROJECT EXIT")
	fmt.println("========================================")
}


//* ENGINE_APPLICATION_INTERFACE
// The application fills this struct in once, before Engine.init, and the
// engine calls each hook at the appropriate point in the lifecycle.
//
// The struct is intentionally package-level (not a local in main) so the
// hook procs can capture it without a closure. Hooks are proc literals,
// so we store the necessary state in module-level globals below.
APP: Engine.Engine_App_Interface = Engine.Engine_App_Interface {
	on_init     = on_init,
	on_pre_tick = on_pre_tick,
	on_present  = on_present,
	on_shutdown = on_shutdown,
}

//* APPLICATION STATE
// 
// Game-side state the sample "gameplay" code reaches for. Real games
// would put their own structs here; this is the bare minimum that proves
// the DAG is firing per-frame.
TICK_COUNT:      u64
LAST_FRAME_INDEX: u64
LAST_DT:         f32

// Cached ^World recovered during on_init via engine_get_ecs_world. The
// engine puts the same pointer into every Scheduler_Frame.world.ptr so
// the sample system can reach it without an extra lookup.
ECS_WORLD: rawptr


//* HOOKS
//
on_init :: proc() {
	fmt.println("[App] on_init: registering game systems + fetching ECS world")

	// Game-side dependency: INPUT before PHYSICS. Names are resolved
	// against the engine's system registry at scheduler_build time;
	// each entry requires that BOTH names have already been
	// registered (order between this and the add_system calls
	// doesn't matter — the engine sorts by name).
	ok := Engine.engine_register_system_dependency("Game.Input", "Game.Physics")
	if !ok {
		fmt.println("[App] dependency registration failed")
	}

	// Game system: "Game.Input" — stage PreUpdate, runs before Game.Physics.
	Engine.engine_register_system(
		"Game.Input",
		game_system_input,
		Engine.System_Info{
			stage = .PreUpdate,
		},
	)

	// Game system: "Game.Physics" — stage PreUpdate, runs after Game.Input
	// (via the dependency above). The DAG compiler emits the edge.
	Engine.engine_register_system(
		"Game.Physics",
		game_system_physics,
		Engine.System_Info{
			stage = .PreUpdate,
		},
	)

	// Optional: pull the BF_ECS World if the module is loaded. Game
	// code uses the SDK helper, never imports BF_ECS directly.
	ECS_WORLD = Engine.engine_get_ecs_world()
	fmt.println("[App] ecs world =", ECS_WORLD)
}

on_pre_tick :: proc(dt: f32, frame_index: u64) {
	LAST_DT = dt
	LAST_FRAME_INDEX = frame_index

	// First invocation only: print a one-shot so the loop is visibly running.
	if frame_index == 1 {
		fmt.println("[App] pre_tick fired for the first time")
	}
}

on_present :: proc(dt: f32, frame_index: u64) {
	// Quit after a small number of frames so the demo terminates.
	if frame_index >= 3000000 {
		fmt.println("[App] present reached frame_index 3,000,000 — quitting")
		Engine.engine_quit()
	}
}

on_shutdown :: proc() {
	fmt.println("[App] on_shutdown")
	ECS_WORLD = nil
}

//* SYSTEM CALLBACKS
// Each proc(rawptr) is invoked by the DAG scheduler on whatever worker
// thread claimed the node. The ctx points at a Scheduler_Frame whose
// lifetime is bounded by the Engine.run loop's frame iteration. Don't
// store the pointer past the callback's return.
game_system_input :: proc(ctx: rawptr) {
	frame := cast(^Engine.Scheduler_Frame)ctx
	if frame == nil do return
	// No work — the system's existence is what we are proving here.
}

game_system_physics :: proc(ctx: rawptr) {
	frame := cast(^Engine.Scheduler_Frame)ctx
	if frame == nil do return
	TICK_COUNT += 1
}
