#+build windows
//Engine/src/Core/Platform_Windows.odin

package Core

import "core:fmt"
import "core:log"
import "core:strings"
import "core:sys/windows"
import "core:unicode/utf16"

dynamic_library_open :: proc(path: string) -> (Dynamic_Library, bool) {
	buf := make([dynamic]u16, len(path) + 1)
	defer delete(buf)
	utf16.encode_string(buf[:], path)
	handle := windows.LoadLibraryW(cstring16(raw_data(buf[:])))

	if handle == nil {
		// Surface GetLastError so missing-dependency failures (e.g. a
		// module built against vendor:sdl3 but SDL3.dll not deployed
		// next to the engine binary) are obvious in logs.
		err := windows.GetLastError()
		log.errorf("Bifrost LIB: failed to load %s (Win32 error %d)", path, err)
		fmt.eprintf("  hint: if Win32 error is 126 (ERROR_MOD_NOT_FOUND), a transitive DLL dependency is missing.\n")
		return Dynamic_Library{}, false
	}

	return Dynamic_Library{handle = cast(rawptr)handle, path = path, loaded = true}, true
}

dynamic_library_close :: proc(library: ^Dynamic_Library) {
	if library == nil do return
	if !library.loaded do return
	if library.handle == nil do return

	windows.FreeLibrary(cast(windows.HMODULE)library.handle)

	library.handle = nil
	library.loaded = false
}

dynamic_library_symbol :: proc(library: ^Dynamic_Library, name: string) -> rawptr {
	if library == nil || !library.loaded do return nil
	if library.handle == nil do return nil
	name_c := strings.clone_to_cstring(name)

	return windows.GetProcAddress(cast(windows.HMODULE)library.handle, name_c)
}
