package game

import ye "../Engine"
import "core:fmt"
import "core:log"
import "core:mem"

startup_mode := ye.Engine_Startup.game
game_config_path := "Config/game.json"

run_game := bool(true)
ODIN_DEBUG :: true

main :: proc() {
	// Initialize the Ymir Engine //
	when ODIN_DEBUG{
			fmt.println("Starting in debug mode")
			context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
			defer log.destroy_console_logger(context.logger)
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			context.allocator = mem.tracking_allocator(&track)

			defer {
				if len(track.allocation_map) > 0 {
					log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
					for _, entry in track.allocation_map {
						log.debugf("%v bytes @ %v", entry.size, entry.location)
					}
				}
				if len(track.bad_free_array) > 0 {
					log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
					for entry in track.bad_free_array {
						log.debugf("%p @ %v", entry.memory, entry.location)
					}
				}
				mem.tracking_allocator_destroy(&track) // End memory tracking
			}
		}
		// Boot the engine runtime and ensure it shuts down properly.
		// This loads config, level data, ECS DB files, and initializes YMIR_ECS handles.
		runtime, ok := ye.boot_runtime(game_config_path)
		if !ok {
			return
		}
		// Always run full shutdown sequence (save + cleanup), even on early returns.
		defer ye.shutdown_runtime(&runtime)
		// Initialize the game with the specified renderer backend
		ye.init_engine(runtime.config, debug = ODIN_DEBUG) 
		
	switch startup_mode {
	case ye.Engine_Startup.editor:
		{
			fmt.println("Starting in editor mode")
			fmt.println("Editor mode not wired yet, you can fire off the editor.exe in the meantime :)")
			/*for run_editor {
				if ye.should_quit(&runtime) {
					run_editor = false
					break
				}
				run_editor() // Calling editor loop in editor.odin and destroying based off backend
				ye.draw_frame(&runtime)
			}*/
		}
	case ye.Engine_Startup.game:
		{
			fmt.println("Starting in game mode")
			 // Main game loop entrypoint is in game.odin, but we call it here to ensure the engine is fully booted first.
			 // The loop will run until the game signals it should quit (e.g. window close, quit event, etc.)
			 // and will call ye.draw_frame() each iteration to render the game.
			// Main gameplay loop entrypoint.
			for run_game {
				if ye.should_quit(&runtime) {
					run_game = false
					break
				}
				run() // Calling game loop in game.odin and destroying based off backend
				ye.draw_frame(&runtime)
			}
		}
	}
}

