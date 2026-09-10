// Engine/src/Tools/rbs/manifest_codegen.odin
//
// `rbs manifest codegen` orchestration: walk package directories, extract
// IDENTITY (and optional TARGETS) blocks from .odin source, write
// <PackageName>.toml next to the source, idempotently. Dependencies live
// inline inside the IDENTITY block; there is no separate DEPENDENCIES
// block to scan.
//
// Usage from rbs.odin:
//
//     rbs.add_command(&ctx, "manifest", proc(c: rbs.Context, p: rbs.Profile) {
//         rbs.manifest_codegen_run(c, p)
//     })
//
// With --check, exit non-zero if any manifest is stale (CI hook).

package rbs

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import toml "../../dependencies/toml_serializer"

manifest_codegen_run :: proc(ctx: Context, profile: Profile) {
    _ = ctx
    _ = profile

    cli := get_cli(os.args)
    defer dispose_cli(cli)

    check_only := false
    target := ""
    for flag, _ in cli.flags {
        if flag == "check" do check_only = true
    }
    for a in cli.args {
        if a == "manifest" || a == "codegen" do continue
        if a == profile.name do continue
        target = a
    }

    if target == "" {
        failures := _codegen_all(check_only)
        if check_only && failures > 0 {
            os.exit(1)
        }
    } else {
        if !_codegen_one(target, check_only) {
            os.exit(1)
        }
    }
}

// manifest_codegen_run_check runs `rbs manifest --check` semantics without
// needing CLI args. Returns the number of failed/stale packages. Used by
// pre_build hooks to fail loudly before doing any compile work.
//
// Returns 0 when every package's on-disk .toml matches what its source
// declares. Non-zero means at least one package is missing a manifest or
// the manifest is stale.

manifest_codegen_run_check :: proc() -> int {
    failures := _codegen_all(true)
    return failures
}

// _codegen_all walks the canonical package dirs and emits (or checks) the
// manifest for every package that contains the right marker block.
//
// rune.exe runs with cwd=Project/, so the engine/extensions roots are
// relative to Project/'s parent, and the plugins root is relative to
// Project/ itself.
@(private)
_codegen_all :: proc(check_only: bool) -> int {
    roots := []string{
        "../../Engine/src/Modules",
        "../../Engine/src/Extensions",
        "../Plugins",
    }
    failures := 0
    for root in roots {
        if !os.exists(root) do continue
        fh, err := os.open(root)
        if err != nil do continue
        defer os.close(fh)

        entries, rerr := os.read_directory(fh, -1, context.allocator)
        if rerr != nil do continue

        for entry in entries {
            if entry.type != .Directory do continue
            pkg_dir := filepath.join({root, entry.name}) or_else ""
            if pkg_dir == "" do continue
            ok, stale := _codegen_package(pkg_dir, check_only)
            if !ok do failures += 1
            if check_only && stale {
                fmt.eprintfln("[codegen] STALE: %s", pkg_dir)
            }
        }
    }
    return failures
}

@(private)
_codegen_one :: proc(pkg_path: string, check_only: bool) -> bool {
    ok, _ := _codegen_package(pkg_path, check_only)
    return ok
}

// _codegen_package finds the entry source file in `pkg_dir`, extracts the
// manifest blocks, and writes (or compares against) <PackageName>.toml.
//
// Returns (true, stale?) — stale=true means a --check run would fail.
@(private)
_codegen_package :: proc(pkg_dir: string, check_only: bool) -> (bool, bool) {
    src_path, ok := _find_entry_source(pkg_dir)
    if !ok {
        fmt.eprintfln("[codegen] no .odin entry source found in %s", pkg_dir)
        return false, false
    }

    blocks, err := extract_blocks(src_path)
    if err.message != "" {
        fmt.eprintfln("[codegen] %s: %s", src_path, err.message)
        return false, false
    }

    m: toml.Module_Manifest
    toml.manifest_init(&m)
    defer toml.manifest_destroy(&m)
    blocks_into_manifest(&m, blocks)

    if m.name == "" {
        fmt.eprintfln("[codegen] %s: identity block missing or empty", src_path)
        return false, false
    }

    out_path := filepath.join({pkg_dir, fmt.tprintf("%s.toml", m.name)}) or_else ""

    expected := toml.write_manifest_string(&m)

    if check_only {
        existing, rerr := os.read_entire_file_from_path(out_path, context.allocator)
        if rerr != nil {
            fmt.eprintfln("[codegen] MISSING: %s", out_path)
            return true, true
        }
        defer delete(existing)
        if string(existing) != expected {
            fmt.eprintfln("[codegen] STALE:  %s", out_path)
            return true, true
        }
        return true, false
    }

    if err := _write_atomic(out_path, expected); err != nil {
        fmt.eprintfln("[codegen] write failed for %s: %v", out_path, err)
        return false, false
    }
    fmt.printfln("[codegen] %s -> %s", src_path, out_path)
    return true, false
}

// _find_entry_source locates the canonical package source file. Convention:
//
//     1. Mod.odin (or mod.odin for case-insensitive filesystems) - the
//        standard module/extension entry source across the engine.
//     2. <PackageName>.odin where PackageName matches the directory name.
//     3. First .odin file in the directory otherwise.
//
// Returns the absolute path or an empty string when none exists.
@(private)
_find_entry_source :: proc(pkg_dir: string) -> (string, bool) {
    fh, err := os.open(pkg_dir)
    if err != nil do return "", false
    defer os.close(fh)

    entries, rerr := os.read_directory(fh, -1, context.allocator)
    if rerr != nil do return "", false

    pkg_name := filepath.base(pkg_dir)
    canonical_pkg := fmt.tprintf("%s.odin", pkg_name)
    // Recognised canonical entry sources, in priority order. Mod.odin
    // is the actual convention used throughout the engine; the
    // package-name variant is kept as a fallback for packages that
    // prefer <Name>.odin over Mod.odin.
    canonical_names := []string{"Mod.odin", "mod.odin", canonical_pkg}
    first_other := ""

    for entry in entries {
        if entry.type != .Regular do continue
        name := entry.name
        if !strings.has_suffix(name, ".odin") do continue
        for c in canonical_names {
            if name == c {
                joined, _ := filepath.join({pkg_dir, name})
                return joined, true
            }
        }
        if first_other == "" {
            joined, _ := filepath.join({pkg_dir, name})
            first_other = joined
        }
    }
    if first_other != "" do return first_other, true
    return "", false
}

// _write_atomic writes `data` to `path`, replacing any existing file.
@(private)
_write_atomic :: proc(path: string, data: string) -> os.Error {
    if os.exists(path) {
        if err := os.remove(path); err != nil do return err
    }
    return os.write_entire_file(path, transmute([]u8)data)
}
