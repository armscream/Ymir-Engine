// Tools/rbs/literal_extractor.odin
//
// Scans .odin source files for the canonical MODULE_IDENTITY (and
// optional TARGETS) blocks used by rbs manifest codegen, parses their
// contents with a strict, frozen literal subset, and produces a
// toml.Module_Manifest.
//
// The IDENTITY block is a single Core.Lib_Descriptor literal that
// includes everything the engine needs at load time: identity fields,
// component_kind, lib_type, flags, capabilities, and dependencies (via
// the `dependencies = { ... }` field and `dependency_count`). There is
// no separate DEPENDENCIES block — the descriptor is the single source
// of truth for component metadata.
//
// Marker comments anchor each block:
//
//     // === MODULE_IDENTITY (parsed by rbs) ===
//     IDENTITY :: Core.Lib_Descriptor{ ... }
//     // === END MODULE_IDENTITY ===
//
//     // === TARGETS (parsed by rbs) ===
//     TARGETS := [?]Core.Extension_Target{ ... }
//     // === END TARGETS ===
package rbs

import "core:fmt"
import "core:os"
import "core:strings"

import toml "../../dependencies/toml_serializer"

// ------------------------------------------------------------------------
// Extract_Error
// ------------------------------------------------------------------------

Extract_Error :: struct {
    file:    string,
    line:    int,
    column:  int,
    message: string,
}

mk_extract_error :: proc(file: string, line, col: int, msg: string) -> Extract_Error {
    return Extract_Error{file = file, line = line, column = col, message = msg}
}

// ------------------------------------------------------------------------
// Extracted_Blocks holds the raw text bodies between marker pairs.
// Empty (false) means the corresponding block was not present in source.
// ------------------------------------------------------------------------

Extracted_Blocks :: struct {
	file: string,
	identity: bool,
	identity_body: string,
	targets: bool,
	targets_body: string,
}

// extract_blocks reads source_path and returns the bodies between
// markers. Missing blocks are reported as not present (no error).
extract_blocks :: proc(source_path: string) -> (Extracted_Blocks, Extract_Error) {
    data, err := os.read_entire_file_from_path(source_path, context.allocator)
    if err != nil {
        return {}, mk_extract_error(source_path, 0, 0, "could not read source file")
    }
    defer delete(data)
    // Build a properly null-terminated string view of the file. The
    // `string([]byte)` cast does not null-terminate, which causes Odin
    // string reads to read past the end of the buffer and pick up
    // allocator metadata.
    src_bytes := make([]byte, len(data) + 1, context.allocator)
    for i in 0 ..< len(data) do src_bytes[i] = data[i]
    src_bytes[len(data)] = 0
    // Take a string view that EXCLUDES the null terminator from len.
    text := string(src_bytes[:len(data)])
    // src_bytes is now owned by `text`; do not free it.

    out := Extracted_Blocks{file = source_path}

    if body, ok := _scan_block(text, source_path, "MODULE_IDENTITY"); ok {
        out.identity = true
        out.identity_body = body
    } else if body, ok := _scan_block(text, source_path, "LIB_DESCRIPTOR"); ok {
        // Legacy alias: older sources use the LIB_DESCRIPTOR marker with
        // the same single-block shape.
        out.identity = true
        out.identity_body = body
    }
    if body, ok := _scan_block(text, source_path, "TARGETS"); ok {
        out.targets = true
        out.targets_body = body
    }
    return out, Extract_Error{}
}

// _scan_block finds the start and end markers for `name` and returns the
// trimmed body in between. Returns (body, true) on success.
@(private)
_scan_block :: proc(text, file, name: string) -> (string, bool) {
    start_marker := fmt.tprintf("// === %s (parsed by rbs) ===", name)
    end_marker := fmt.tprintf("// === END %s ===", name)

    start_idx := strings.index(text, start_marker)
    if start_idx < 0 do return "", false

    after_start := start_idx + len(start_marker)
    // skip rest of start-marker line
    nl := strings.index_byte(text[after_start:], '\n')
    if nl < 0 do return "", false
    body_start := after_start + nl + 1

    end_idx := strings.index(text[body_start:], end_marker)
    if end_idx < 0 do return "", false

    body := strings.trim_space(text[body_start:body_start + end_idx])
    return body, true
}

// ------------------------------------------------------------------------
// Build manifest from extracted blocks
// ------------------------------------------------------------------------

// blocks_into_manifest populates m from the extracted blocks. Any block
// not present is silently ignored. Dependencies are pulled from the
// IDENTITY block (Lib_Descriptor.dependencies); there is no separate
// DEPENDENCIES block to parse.
blocks_into_manifest :: proc(m: ^toml.Module_Manifest, blocks: Extracted_Blocks) {
    if blocks.identity {
        if err := parse_identity_block(m, blocks.identity_body); err.message != "" {
            fmt.eprintfln("[extract] %s: %s", blocks.file, err.message)
        }
    }
    if blocks.targets {
        if err := parse_targets_block(m, blocks.targets_body); err.message != "" {
            fmt.eprintfln("[extract] %s: %s", blocks.file, err.message)
        }
    }
}

// _read_array_of_dependencies parses an inline array of struct literals,
// i.e. the body of a `dependencies = { ... }` field where the value is
// `{ <struct>, <struct>, ... }` rather than a bit_set literal.
//
// Returns the parsed dependencies, the new position after the closing
// brace, and any error. The error has zero location info — caller is
// expected to attach one.
@(private)
_read_array_of_dependencies :: proc(body: string, start: int) -> ([dynamic]toml.Dependency, int, Extract_Error) {
    deps: [dynamic]toml.Dependency
    if start >= len(body) || body[start] != '{' {
        return deps, start, mk_extract_error("", 0, start, "expected `{` for inline dependencies array")
    }
    // The opening `{` of the array literal encloses a list of struct
    // literals separated by commas.
    inner, np, err := slice_balanced_braces(body, start)
    if err.message != "" do return deps, np, err

    elems, err2 := split_top_level_brace_items(inner)
    if err2.message != "" do return deps, np, err2

    for elem in elems {
        fields, fpe := parse_struct_fields(elem)
        if fpe.message != "" do return deps, np, fpe
        d := toml.Dependency{}
        for f in fields {
            switch f.key {
            case "name":
                if s, ok := f.value.(string); ok do d.name = s
            case "min_version":
                if v, ok := f.value.(Version_Lit); ok {
                    d.min_version = {u32(v.major), u32(v.minor), u32(v.patch)}
                }
            case "max_version":
                if v, ok := f.value.(Version_Lit); ok {
                    d.max_version = {u32(v.major), u32(v.minor), u32(v.patch)}
                }
            case "has_min_version":
                if b, ok := f.value.(bool); ok do d.has_min_version = b
            case "has_max_version":
                if b, ok := f.value.(bool); ok do d.has_max_version = b
            case "optional":
                if b, ok := f.value.(bool); ok do d.optional = b
            }
        }
        append(&deps, d)
    }
    return deps, np, Extract_Error{}
}

// ------------------------------------------------------------------------
// Identity block
// ------------------------------------------------------------------------

parse_identity_block :: proc(m: ^toml.Module_Manifest, body_src: string) -> Extract_Error {
    body := _safe_clone(body_src)
    brace := strings.index(body, "{")
    if brace < 0 {
        return mk_extract_error("", 0, 0, "identity block missing `{`")
    }
    inner, _, err := slice_balanced_braces(body, brace)
    if err.message != "" {
        return mk_extract_error("", 0, brace, err.message)
    }

    // The new format puts every field including `dependencies = {{...}}`
    // inside the IDENTITY struct literal, so we parse the fields
    // directly. The `dependencies` field needs special handling because
    // it's an inline array of struct literals (not a bit_set).
    fields, err2 := parse_identity_fields(inner, m)
    if err2.message != "" do return err2

    // The old split-block format put name/version/etc. in a separate
    // MODULE_IDENTITY block. When parse_identity_fields sees a `dependencies`
    // key, it reads the inline array. Anything else falls through to
    // parse_struct_fields via _read_value.
    _ = fields
    return Extract_Error{}
}

// parse_identity_fields walks the body of a Core.Lib_Descriptor literal.
// Each recognized key is converted into the manifest's strongly-typed
// fields. Keys that aren't recognized are silently ignored so that
// extensions to the literal don't break older rbs versions.
parse_identity_fields :: proc(body_src: string, m: ^toml.Module_Manifest) -> ([dynamic]Field, Extract_Error) {
    out: [dynamic]Field
    body := _safe_clone(body_src)
    pos := 0
    _skip_ws_comments(&pos, body)

    iter := 0
    for pos < len(body) {
        _skip_ws_comments(&pos, body)
        if pos >= len(body) do break
        iter += 1
        if iter > 64 do break

        key, np := _read_ident(body, pos)
        if np == pos {
            return out, mk_extract_error("", 0, pos, "expected identifier at start of field")
        }
        pos = np
        _skip_ws_comments(&pos, body)

        if pos >= len(body) || body[pos] != '=' {
            return out, mk_extract_error("", 0, pos, "expected `=` after field name")
        }
        pos += 1
        _skip_ws_comments(&pos, body)

        // Special-case the `dependencies` field: it's an inline array of
        // struct literals, not a single value.
        if key == "dependencies" {
            deps, np2, err := _read_array_of_dependencies(body, pos)
            if err.message != "" do return out, err
            for d in deps do append(&m.dependencies, d)
            pos = np2
            _skip_ws_comments(&pos, body)
            if pos < len(body) && body[pos] == ',' do pos += 1
            continue
        }

        val, np2, err := _read_value(body, pos)
        if err.message != "" do return out, err
        pos = np2
        _skip_ws_comments(&pos, body)

        if pos < len(body) && body[pos] == ',' do pos += 1
        _skip_ws_comments(&pos, body)

        _apply_field(m, key, val)
        append(&out, Field{key = key, value = val})
    }
    return out, Extract_Error{}
}

// _apply_field routes a single (key, value) from the IDENTITY body into
// the strongly-typed manifest fields. Unknown keys are ignored.
@(private)
_apply_field :: proc(m: ^toml.Module_Manifest, key: string, val: Value_Lit) {
    switch key {
    case "api_version":
        n, ok := val.(int)
        if !ok do return
        m.api_version = u32(n)
    case "name":
        s, ok := val.(string)
        if !ok do return
        m.name = s
    case "author":
        s, ok := val.(string)
        if !ok do return
        m.author = s
    case "description":
        s, ok := val.(string)
        if !ok do return
        m.description = s
    case "version":
        v, ok := val.(Version_Lit)
        if !ok do return
        m.version = {u32(v.major), u32(v.minor), u32(v.patch)}
    case "component_type", "component_kind":
        id, ok := val.(Ident_Lit)
        if !ok do return
        m.component_kind = component_kind_from_ident(id.text)
    case "type":
        // Sub-classification (Renderer/Input/ECS/...) stored as a string
        // identifier; the host resolves it to a Lib_Type enum value at
        // load time.
        id, ok := val.(Ident_Lit)
        if !ok do return
        m.lib_type_name = id.text
    case "flags":
        bs, ok := val.(Bit_Set_Lit)
        if !ok do return
        for id in bs.idents do append(&m.flags, id)
    case "capabilities":
        bs, ok := val.(Bit_Set_Lit)
        if !ok do return
        for id in bs.idents do append(&m.capabilities, id)
    case "dependency_count":
        n, ok := val.(int)
        if !ok do return
        m.dependency_count = u32(n)
    }
}

// ------------------------------------------------------------------------
// Targets (arrays of struct)
// ------------------------------------------------------------------------

parse_targets_block :: proc(m: ^toml.Module_Manifest, body: string) -> Extract_Error {
    return _parse_tgt_array(m, body)
}

// Specialized target array. (Dependencies are parsed inline as part of
// the IDENTITY block; they have no standalone block.)
@(private)
_parse_tgt_array :: proc(m: ^toml.Module_Manifest, body: string) -> Extract_Error {
    return _parse_array_of_dependency_or_target(m, body, true)
}

// _parse_array_of_dependency_or_target handles bodies of the form
//
//     DEPENDENCIES := [?]Core.DLL_Dependency{ { ... }, { ... }, ... }
//
// where `is_target` selects between Dependency and Target field parsing.
//
// The body returned by _scan_block is the entire content between the
// start and end markers, including the LHS assignment. We skip over
// `LHS := ` first.
@(private)
_parse_array_of_dependency_or_target :: proc(
    m: ^toml.Module_Manifest, body_src: string, is_target: bool,
) -> Extract_Error {
    body := _safe_clone(body_src)
    pos := 0
    _skip_ws_comments(&pos, body)

    // Skip LHS identifier (e.g. `DEPENDENCIES`) and `::=` / `:=` and any
    // type prefix until we hit the array literal `[`.
    if pos >= len(body) {
        return mk_extract_error("", 0, pos, "empty body")
    }
    // Skip identifiers and dots until we reach `[`.
    for pos < len(body) && body[pos] != '[' {
        c := body[pos]
        if c == ':' || c == '=' || _is_ident_cont(c) || c == '?' || c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            pos += 1
        } else {
            return mk_extract_error("", 0, pos,
                fmt.tprintf("unexpected char %q while scanning to `[`", rune(c)))
        }
    }
    if pos >= len(body) || body[pos] != '[' {
        return mk_extract_error("", 0, pos, "expected `[` for array literal")
    }

    // Walk past `[...]Type{`.
    pos += 1
    // Skip until matching `]`.
    depth := 1
    for pos < len(body) && depth > 0 {
        c := body[pos]
        if c == '[' do depth += 1
        if c == ']' do depth -= 1
        pos += 1
    }
    if depth != 0 {
        return mk_extract_error("", 0, pos, "unbalanced []")
    }
    _skip_ws_comments(&pos, body)
    // Skip the qualified type identifier (`Core.DLL_Dependency`).
    for pos < len(body) && (_is_ident_cont(body[pos]) || body[pos] == '.') do pos += 1
    _skip_ws_comments(&pos, body)
    // Expect `{`.
    if pos >= len(body) || body[pos] != '{' {
        return mk_extract_error("", 0, pos, "expected `{` after type")
    }

    inner, np, err := slice_balanced_braces(body, pos)
    if err.message != "" do return mk_extract_error("", 0, pos, err.message)
    _ = np

    // Split into top-level brace items (each is a Dependency or Target).
    elems, err2 := split_top_level_brace_items(inner)
    if err2.message != "" do return err2

    for elem in elems {
        fields, fpe := parse_struct_fields(elem)
        if fpe.message != "" do return fpe
        if is_target {
            t := toml.Target{}
            for f in fields {
                switch f.key {
                case "module":
                    if s, ok := f.value.(string); ok do t.module = s
                case "min_version":
                    if v, ok := f.value.(Version_Lit); ok {
                        t.min_version = {u32(v.major), u32(v.minor), u32(v.patch)}
                    }
                case "max_version":
                    if v, ok := f.value.(Version_Lit); ok {
                        t.max_version = {u32(v.major), u32(v.minor), u32(v.patch)}
                    }
                case "has_min_version":
                    if b, ok := f.value.(bool); ok do t.has_min_version = b
                case "has_max_version":
                    if b, ok := f.value.(bool); ok do t.has_max_version = b
                }
            }
            append(&m.targets, t)
        } else {
            d := toml.Dependency{}
            for f in fields {
                switch f.key {
                case "name":
                    if s, ok := f.value.(string); ok do d.name = s
                case "min_version":
                    if v, ok := f.value.(Version_Lit); ok {
                        d.min_version = {u32(v.major), u32(v.minor), u32(v.patch)}
                    }
                case "max_version":
                    if v, ok := f.value.(Version_Lit); ok {
                        d.max_version = {u32(v.major), u32(v.minor), u32(v.patch)}
                    }
                case "has_min_version":
                    if b, ok := f.value.(bool); ok do d.has_min_version = b
                case "has_max_version":
                    if b, ok := f.value.(bool); ok do d.has_max_version = b
                case "optional":
                    if b, ok := f.value.(bool); ok do d.optional = b
                }
            }
            append(&m.dependencies, d)
        }
    }
    return Extract_Error{}
}

// ------------------------------------------------------------------------
// Literal value types
// ------------------------------------------------------------------------

Value_Lit :: union {
    string,
    bool,
    int,
    Version_Lit,
    Ident_Lit,
    Bit_Set_Lit,
}

Version_Lit :: struct {
    major, minor, patch: int,
}

Ident_Lit :: struct {
    text: string,
}

Bit_Set_Lit :: struct {
    idents: [dynamic]string,
}

// Field is a parsed `key = value` from a struct literal body.
Field :: struct {
    key:   string,
    value: Value_Lit,
}

// _safe_clone copies a string with a trailing null terminator so the
// resulting string's backing memory is well-formed. Use this instead of
// `strings.clone` for body strings passed into long-lived parsers — Odin
// strings read past `len` when accessed, and `strings.clone` produces a
// string without a trailing 0 which causes out-of-bounds reads to leak
// allocator metadata into the string's bytes.
@(private)
_safe_clone :: proc(s: string) -> string {
    if len(s) == 0 do return ""
    src := transmute([]u8)s
    buf := make([]byte, len(src) + 1)
    for i in 0 ..< len(src) do buf[i] = src[i]
    buf[len(src)] = 0
    // Slice out the trailing null from the string length.
    return string(buf[:len(src)])
}
// parse_struct_fields parses a comma-separated list of `key = value`
// entries inside the body of a struct literal.
parse_struct_fields :: proc(body_src: string) -> ([dynamic]Field, Extract_Error) {
    body := _safe_clone(body_src)
    out: [dynamic]Field

    pos := 0
    _skip_ws_comments(&pos, body)

    iter := 0
    for pos < len(body) {
        _skip_ws_comments(&pos, body)
        if pos >= len(body) do break
        iter += 1
        if iter > 20 do break // safety

        // Read identifier.
        key, np := _read_ident(body, pos)
        if np == pos {
            before := pos >= 20 ? body[pos-20:pos] : body[0:pos]
            after  := pos+20 <= len(body) ? body[pos:pos+20] : body[pos:len(body)]
            return out, mk_extract_error("", 0, pos, fmt.tprintf("expected identifier at pos=%d body_len=%d iter=%d BEFORE=%q AFTER=%q byte=%v", pos, len(body), iter, before, after, body[pos]))
        }
        pos = np
        _skip_ws_comments(&pos, body)

        if pos >= len(body) || body[pos] != '=' {
            return out, mk_extract_error("", 0, pos, fmt.tprintf("expected `=` at pos=%d body_len=%d iter=%d", pos, len(body), iter))
        }
        pos += 1
        _skip_ws_comments(&pos, body)

        val, np2, err := _read_value(body, pos)
        if err.message != "" do return out, err
        pos = np2
        _skip_ws_comments(&pos, body)

        if pos < len(body) && body[pos] == ',' do pos += 1
        _skip_ws_comments(&pos, body)

        append(&out, Field{key = key, value = val})
    }
    return out, Extract_Error{}
}

split_top_level_brace_items :: proc(body: string) -> ([dynamic]string, Extract_Error) {
    out: [dynamic]string
    pos := 0
    _skip_ws_comments(&pos, body)
    for pos < len(body) {
        _skip_ws_comments(&pos, body)
        if pos >= len(body) do break
        if body[pos] != '{' {
            return out, mk_extract_error("", 0, pos, fmt.tprintf("expected `{`, got %q", rune(body[pos])))
        }
        inner, np, err := _slice_balanced(body, pos, '{', '}')
        if err.message != "" do return out, err
        append(&out, inner)
        pos = np
        _skip_ws_comments(&pos, body)
        if pos < len(body) && body[pos] == ',' do pos += 1
    }
    return out, Extract_Error{}
}

// ------------------------------------------------------------------------
// Brace / bracket slicing
// ------------------------------------------------------------------------

slice_balanced_braces :: proc(body: string, start_pos: int) -> (string, int, Extract_Error) {
    if start_pos >= len(body) || body[start_pos] != '{' {
        return "", start_pos, mk_extract_error("", 0, start_pos, "expected `{`")
    }
    return _slice_balanced(body, start_pos, '{', '}')
}

slice_balanced_brackets :: proc(body: string, start_pos: int) -> (string, int, Extract_Error) {
    if start_pos >= len(body) || body[start_pos] != '[' {
        return "", start_pos, mk_extract_error("", 0, start_pos, "expected `[`")
    }
    return _slice_balanced(body, start_pos, '[', ']')
}

@(private)
_slice_balanced :: proc(body: string, start_pos: int, open: byte, close: byte) -> (string, int, Extract_Error) {
    depth := 1
    in_string := false
    escape := false
    i := start_pos + 1
    for i < len(body) {
        c := body[i]
        if escape {
            escape = false
            i += 1
            continue
        }
        if in_string {
            if c == '\\' {
                escape = true
            } else if c == '"' {
                in_string = false
            }
            i += 1
            continue
        }
        switch c {
        case '"':
            in_string = true
        case open:
            depth += 1
        case close:
            depth -= 1
            if depth == 0 {
                return body[start_pos+1:i], i + 1, Extract_Error{}
            }
        }
        i += 1
    }
    return "", start_pos, mk_extract_error("", 0, start_pos,
        fmt.tprintf("unbalanced %c%c", rune(open), rune(close)))
}

// ------------------------------------------------------------------------
// Primitive readers
// ------------------------------------------------------------------------

@(private)
_skip_ws_comments :: proc(pos: ^int, body: string) {
    for pos^ < len(body) {
        c := body[pos^]
        switch c {
        case ' ', '\t', '\r', '\n':
            pos^ += 1
        case '/':
            if pos^ + 1 < len(body) && body[pos^ + 1] == '/' {
                pos^ += 2
                for pos^ < len(body) && body[pos^] != '\n' do pos^ += 1
            } else if pos^ + 1 < len(body) && body[pos^ + 1] == '*' {
                pos^ += 2
                for pos^ + 1 < len(body) {
                    if body[pos^] == '*' && body[pos^ + 1] == '/' {
                        pos^ += 2
                        break
                    }
                    pos^ += 1
                }
            } else {
                return
            }
        case:
            return
        }
    }
}

@(private)
_read_ident :: proc(body: string, start: int) -> (string, int) {
    if start >= len(body) do return "", start
    c := body[start]
    if !_is_ident_start(c) do return "", start
    i := start + 1
    for i < len(body) && _is_ident_cont(body[i]) do i += 1
    return body[start:i], i
}

@(private)
_is_ident_start :: proc(c: byte) -> bool {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

@(private)
_is_ident_cont :: proc(c: byte) -> bool {
    return _is_ident_start(c) || (c >= '0' && c <= '9') || c == '-' || c == '_'
}

@(private)
_read_value :: proc(body: string, start: int) -> (Value_Lit, int, Extract_Error) {
    if start >= len(body) {
        return nil, start, mk_extract_error("", 0, start, "expected value")
    }
    c := body[start]
    switch c {
    case '"':
        s, np := _read_string(body, start)
        return s, np, Extract_Error{}
    case 't', 'f':
        b, np := _read_bool(body, start)
        return b, np, Extract_Error{}
    case '-', '0'..='9':
        i, np := _read_int(body, start)
        return i, np, Extract_Error{}
    case '.':
        id, np := _read_leading_dot_ident(body, start)
        return id, np, Extract_Error{}
    case '{':
        bs, np, err := _read_bit_set(body, start)
        return bs, np, err
    case 'C', 'c':
        // Qualified identifier (`Core.X`, `package.X`, ...). We don't try
        // to resolve them; the suffix is what callers care about.
        //
        // The one exception: if the qualified identifier ends in `Version`
        // and is immediately followed by `{`, parse it as a Version literal.
        id_end := start
        for id_end < len(body) && (_is_ident_cont(body[id_end]) || body[id_end] == '.') do id_end += 1
        qualified := body[start:id_end]
        if id_end < len(body) && body[id_end] == '{' && strings.has_suffix(qualified, "Version") {
            v, np, err := _read_version(body, id_end)
            return v, np, err
        }
        // Strip the package qualifier(s) so consumers see just the bare
        // identifier name ("Core.API_VERSION" -> "API_VERSION").
        last_dot := strings.last_index(qualified, ".")
        bare := qualified if last_dot < 0 else qualified[last_dot + 1:]
        return Ident_Lit{text = bare}, id_end, Extract_Error{}
    case 'A'..='B', 'D'..='Z', 'a', 'b', 'd'..='z', '_':
        // Plain un-qualified identifier (e.g. `Other`, `api_version`).
        id, np := _read_ident(body, start)
        if np == start {
            return nil, start, mk_extract_error("", 0, start,
                fmt.tprintf("unsupported identifier in literal: %q", body[start:start+1]))
        }
        return Ident_Lit{text = id}, np, Extract_Error{}
    }
    return nil, start, mk_extract_error("", 0, start,
        fmt.tprintf("unsupported value-start character %q", rune(c)))
}

@(private)
_read_string :: proc(body: string, start: int) -> (string, int) {
    i := start + 1
    out: strings.Builder
    strings.builder_init(&out)
    for i < len(body) {
        c := body[i]
        if c == '"' do break
        if c == '\\' {
            if i + 1 >= len(body) {
                strings.write_byte(&out, c)
                i += 1
                continue
            }
            n := body[i + 1]
            switch n {
            case 'n':  strings.write_byte(&out, '\n')
            case 't':  strings.write_byte(&out, '\t')
            case 'r':  strings.write_byte(&out, '\r')
            case '\\': strings.write_byte(&out, '\\')
            case '"':  strings.write_byte(&out, '"')
            case:
                strings.write_byte(&out, c)
                i += 1
                continue
            }
            i += 2
            continue
        }
        strings.write_byte(&out, c)
        i += 1
    }
    return strings.to_string(out), i + 1
}

@(private)
_read_bool :: proc(body: string, start: int) -> (bool, int) {
    if strings.has_prefix(body[start:], "true") do return true, start + 4
    if strings.has_prefix(body[start:], "false") do return false, start + 5
    return false, start
}

@(private)
_read_int :: proc(body: string, start: int) -> (int, int) {
    i := start
    if i < len(body) && body[i] == '-' do i += 1
    for i < len(body) {
        c := body[i]
        if (c >= '0' && c <= '9') || c == '_' {
            i += 1
        } else {
            break
        }
    }
    raw := body[start:i]
    cleaned, _ := strings.replace_all(raw, "_", "")
    v, _ := _atoi(cleaned)
    return v, i
}

@(private)
_atoi :: proc(s: string) -> (int, bool) {
    n := 0
    neg := false
    i := 0
    if len(s) > 0 && s[0] == '-' {
        neg = true
        i = 1
    }
    for i < len(s) {
        c := s[i]
        if c < '0' || c > '9' do return 0, false
        n = n * 10 + int(c - '0')
        i += 1
    }
    if neg do n = -n
    return n, true
}

@(private)
_read_leading_dot_ident :: proc(body: string, start: int) -> (Ident_Lit, int) {
    s, np := _read_ident(body, start + 1)
    return Ident_Lit{text = s}, np
}

@(private)
_read_bit_set :: proc(body: string, start: int) -> (Bit_Set_Lit, int, Extract_Error) {
    inner, np, err := slice_balanced_braces(body, start)
    if err.message != "" do return Bit_Set_Lit{}, start, err
    bs: Bit_Set_Lit
    pos := 0
    _skip_ws_comments(&pos, inner)
    for pos < len(inner) {
        _skip_ws_comments(&pos, inner)
        if pos >= len(inner) do break
        id_start := pos
        if inner[pos] == '.' do id_start = pos + 1
        id, np2 := _read_ident(inner, id_start)
        if np2 == id_start {
            return bs, start, mk_extract_error("", 0, pos,
                fmt.tprintf("expected identifier in bit_set, got %q", rune(inner[pos])))
        }
        append(&bs.idents, id)
        pos = np2
        _skip_ws_comments(&pos, inner)
        if pos < len(inner) && inner[pos] == ',' do pos += 1
    }
    return bs, np, Extract_Error{}
}

@(private)
_read_version :: proc(body: string, start: int) -> (Version_Lit, int, Extract_Error) {
    // Supports BOTH forms:
    //   Core.Version{0, 1, 0}                 (positional)
    //   Core.Version{major = 0, minor = 1, patch = 0}  (named)
    inner, np, err := _slice_balanced(body, start, '{', '}')
    if err.message != "" do return Version_Lit{}, start, err

    // Try positional first: three integers separated by commas.
    pos := 0
    _skip_ws_comments(&pos, inner)
    // Read three integers separated by commas.
    ints: [3]int
    for i in 0 ..< 3 {
        _skip_ws_comments(&pos, inner)
        if pos >= len(inner) {
            return Version_Lit{}, start, mk_extract_error("", 0, start,
                "expected integer in Version literal")
        }
        n, np2 := _read_int(inner, pos)
        ints[i] = n
        pos = np2
        _skip_ws_comments(&pos, inner)
        if i < 2 {
            if pos >= len(inner) || inner[pos] != ',' {
                // Fall back to named form parsing.
                pos = 0
                fields, fpe := parse_struct_fields(inner)
                if fpe.message != "" do return Version_Lit{}, start, fpe
                v := Version_Lit{0, 0, 0}
                for f in fields {
                    n, ok := f.value.(int)
                    if !ok do continue
                    switch f.key {
                    case "major": v.major = n
                    case "minor": v.minor = n
                    case "patch": v.patch = n
                    }
                }
                return v, np, Extract_Error{}
            }
            pos += 1
        }
    }
    return Version_Lit{major = ints[0], minor = ints[1], patch = ints[2]}, np, Extract_Error{}
}

// lib_type_from_ident maps a Component_Kind identifier text (without leading
// dot) to the toml.Component_Kind enum.
component_kind_from_ident :: proc(name: string) -> toml.Component_Kind {
    switch name {
    case "Module":    return .Module
    case "Extension": return .Extension
    case "Plugin":    return .Plugin
    }
    return .Module
}
