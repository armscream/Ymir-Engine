package rbs

import "core:fmt"
import "core:strings"

Odin_Command :: enum {
    Build,
    Run
}

// Run the project
exec_odin_cmd :: proc(ctx: Context, cmd: Odin_Command, profile: Profile) -> Error {
    output_err := create_output(profile.output)
    if output_err != nil { return output_err }
    
    out := ensure_trailing_slash(profile.output)
    defer delete(out)

    install_dependencies(ctx, profile)

    // run pre build
    for step in ctx.pre_build_steps {
        step(ctx, profile)
    }

    ext, _ := get_extension(profile.os, profile.mode)
    s_cmd := get_cmd_string(cmd)

    argv := build_odin_argv(s_cmd, profile, out, ext)
    defer delete(argv)

    script := strings.join(argv, " ", context.allocator)
    fmt.printfln("%s\n", script)
    defer delete(script)
    
    if err := run_argv(argv, script); err != nil do return err

    // run post build
    for step in ctx.post_build_steps {
        step(ctx, profile)
    }

    return nil
}

// build_odin_argv constructs the argv for `odin <cmd> <entry> -out:<path>
// -target:<plat> <flags>` while preserving spaces in `profile.name` (which
// becomes part of the -out filename).
@(private="file")
build_odin_argv :: proc(s_cmd: string, profile: Profile, out: string, ext: string) -> []string {
    argv := make([dynamic]string, context.allocator)
    append(&argv, "odin")
    append(&argv, s_cmd)
    append(&argv, profile.entry)
    append(&argv, fmt.aprintf("-out:%s%s%s", out, profile.name, ext))
    append(&argv, fmt.aprintf("-target:%s", get_platform(profile.arch, profile.os)))

    flags := strings.split(profile.flags, " ")
    defer delete(flags)
    for f in flags {
        append(&argv, f)
    }

    return argv[:]
}

@(private="file")
get_cmd_string :: proc(cmd: Odin_Command) -> string {
    switch cmd {
        case .Build:
            return "build"
        case .Run:
            return "run"
    }

    return "INVALID"
}