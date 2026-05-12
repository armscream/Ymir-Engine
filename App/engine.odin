package game

import ye "../Engine"
import "core:fmt"
import "core:log"
import "core:mem"

startup_mode := ye.Engine_Startup.editor
game_config_path := "Config/game.json"

run_game := bool(true)
run_editor := bool(true)
ODIN_DEBUG :: #config(ODIN_DEBUG, false);

main :: proc() {
	when ODIN_DEBUG {
		context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
	} else {
		context.logger = log.create_console_logger(opt = {.Level})
	}
	defer log.destroy_console_logger(context.logger)

	// Initialize the Ymir Engine //
	when ODIN_DEBUG{
			fmt.println("Starting in debug mode")
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
		runtime.editor_ui_enabled = startup_mode == ye.Engine_Startup.editor
		// Always run full shutdown sequence (save + cleanup), even on early returns.
		defer ye.shutdown_runtime(&runtime)
		// Initialize the game with the specified renderer backend
		init_ok, _ := ye.init_engine(runtime.config, debug = ODIN_DEBUG)
		if !init_ok {
			log.error("Engine initialization failed, exiting.")
			return
		}

		
	switch startup_mode {
	case ye.Engine_Startup.editor:
		{
			fmt.println("Starting in editor mode")
			for run_editor {
				if ye.should_quit(&runtime) {
					run_editor = false
					break
				}
				// Calling editor loop in editor.odin and destroying based off backend
				ye.draw_frame(&runtime)
			}
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
				ye.draw_frame(&runtime) // Calling game loop in game.odin and destroying based off backend
			}
		}
	}
}

