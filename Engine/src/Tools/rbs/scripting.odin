package rbs

import "core:fmt"
import "core:strings"
import "core:os"

run_script :: proc(script: string) -> Error {
    return run_argv(strings.split(script, " "), script)
}

// run_argv executes `argv` directly without shell parsing. Preferred over
// `run_script` when arguments may contain spaces (e.g. `-out:` paths whose
// final filename embeds the project name).
//
// Implementation note: we do NOT capture stdout/stderr via pipes. The child
// inherits the parent's stdio so all output (including glslc errors and
// odin diagnostics) goes straight to the console. A previous version piped
// output into a background reader thread, which intermittently lost the
// tail of the child's output because the reader's `pipe_has_data` poll
// could not reliably detect EOF before the read ends were closed.
run_argv :: proc(argv: []string, display: string) -> Error {
    cmds: []string
    if ODIN_OS == .Linux {
        // On Linux, route through bash so PATH/env resolution behaves the
        // same as a user-typed command. On Windows we use argv directly via
        // os.process_start, which preserves arguments with spaces verbatim.
        joined := strings.join(argv, " ", context.allocator)
        defer delete(joined)
        cmds = { "bash", "-i", "-c", joined }
    } else {
        cmds = argv
    }

    p, start_err := os.process_start({
        command = cmds,
    })
    if start_err != nil {
        fmt.eprintfln("Script %s failed to start: %v", display, start_err)
        return .Script_Error
    }

    state, process_err := os.process_wait(p)

    if process_err != nil {
        fmt.eprintfln("Script %s failed with %s", display, process_err)
        return .Script_Error
    }

    if state.exit_code != 0 {
        fmt.eprintfln("Script exited with code: %d", state.exit_code)
        return .Script_Error
    }

    return nil
}