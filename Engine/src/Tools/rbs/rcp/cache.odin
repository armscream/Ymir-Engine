package rcp

import "core:fmt"
import "core:crypto/hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private="file")
CACHE_DIR :: ".rcp-cache"

check_cache :: proc(path: string, output: string) -> (is_cached: bool) {
    // create cache dir
    if !os.exists(CACHE_DIR) {
        assert(os.make_directory(CACHE_DIR) == nil, "Failed to create rcp cache directory")
    }

    // hash the path
    path_hash := hash.hash_string(.Insecure_MD5, path)
    defer delete(path_hash)
    s_hash := fmt.aprintf("%x", string(path_hash))
    defer delete(s_hash)

    full_hash_path, join_err := filepath.join({ CACHE_DIR, s_hash }, context.allocator)
    if join_err != nil {
        return false
    }
    defer delete(full_hash_path)

    file: ^os.File
    defer os.close(file)
    if !os.exists(full_hash_path) do file, _ = os.create(full_hash_path)
    else do file, _ = os.open(full_hash_path)

    cached_content, some_err := os.read_entire_file_from_file(file, context.allocator)
    defer delete(cached_content)
    assert(some_err == nil, "Failed to load cached content")

    path_content_hash := hash_file_content(path)
    defer delete(path_content_hash)

    // Match either by direct hash (legacy format) or by hash-prefix.
    same_content := len(cached_content) == len(path_content_hash) &&
                     strings.compare(cast(string)cached_content, cast(string)path_content_hash) == 0

    if same_content && os.exists(output) {
        return true
    }

    write_err := os.write_entire_file(full_hash_path, path_content_hash)
    _ = write_err

    return false
}

@(private="package")
hash_file_content :: proc(path: string) -> []byte {
    content, err := os.read_entire_file_from_path(path, context.allocator)
    if err != nil do return {} // return err

    content_hash := hash.hash_bytes(.Insecure_MD5, content)
    return content_hash
}