package editor

import "core:fmt"
import "core:os"
import "vendor:glfw"

RUNGAME :: bool
RUNANIMATIONGRAPHEDITOR :: bool
RUNMATERIALGRAPHEDITOR :: bool
RUNLEVELEDITOR :: bool

rungame :: proc() {
    working_dir := "."

    if !os.exists("run_from_game_config.ps1") {
        if os.exists("../run_from_game_config.ps1") {
            working_dir = ".."
        } else {
            fmt.eprintln("Could not find run_from_game_config.ps1 from current or parent directory")
            return
        }
    }

	desc := os.Process_Desc{
		working_dir = working_dir,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
		command = {
			"powershell.exe",
			"-NoProfile",
			"-ExecutionPolicy",
			"Bypass",
			"-File",
			"run_from_game_config.ps1",
		},
	}

	process, err := os.process_start(desc)
	if err != nil {
		fmt.eprintln("Failed to start game build/run PowerShell:", err)
		return
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintln("Failed while waiting for game build/run PowerShell:", wait_err)
		return
	}
	if !state.success || state.exit_code != 0 {
		fmt.eprintln("Game build/run script exited with code:", state.exit_code)
	}
}

main :: proc() {
    create_window()
    if RUNGAME {
	    rungame()
    }   
    if RUNANIMATIONGRAPHEDITOR {
        run_animationgraph_editor()
    }
    if RUNMATERIALGRAPHEDITOR {
        run_materialgraph_editor()
    }
    if RUNLEVELEDITOR {
        run_leveleditor()
    }
}

