package asset_manager

import "core:log"
import "core:mem"
import "core:os"
import "core:image/jpeg"
import "core:image/png"

Loaded_Texture :: struct {
	pixels:  [^]u8,
	width:   i32,
	height:  i32,
	owned:   bool,
}

Atlas_Bake_Input :: struct {
	color_path:  string,
	dest_x:      i32,
	dest_y:      i32,
	dest_width:  i32,
	dest_height: i32,
}

load_texture_from_file :: proc(file_path: string, allocator := context.allocator) -> (tex: Loaded_Texture, ok: bool) {
	data, read_err := os.read_entire_file(file_path, allocator)
	if read_err != nil {
		log.errorf("Failed to read texture file: %v", file_path)
		return {}, false
	}
	defer delete(data, allocator)

	if png_image, png_err := png.load_from_bytes(data, nil); png_err == nil {
		tex := Loaded_Texture {
			width  = i32(png_image.width),
			height = i32(png_image.height),
			owned  = false,
		}
		tex.pixels = cast([^]u8)raw_data(png_image.pixels.buf[:])
		return tex, true
	}

	if jpeg_image, jpeg_err := jpeg.load_from_bytes(data, nil); jpeg_err == nil {
		tex := Loaded_Texture {
			width  = i32(jpeg_image.width),
			height = i32(jpeg_image.height),
			owned  = true,
		}
		pixel_count := jpeg_image.width * jpeg_image.height
		tex_ptr, alloc_err := mem.alloc(pixel_count * 4, allocator = allocator)
		if alloc_err != nil {
			return {}, false
		}
		tex.pixels = cast([^]u8)tex_ptr
		src := cast([^]u8)raw_data(jpeg_image.pixels.buf[:])
		dst := tex.pixels
		for i := 0; i < pixel_count; i += 1 {
			dst[i*4 + 0] = src[i*3 + 0]
			dst[i*4 + 1] = src[i*3 + 1]
			dst[i*4 + 2] = src[i*3 + 2]
			dst[i*4 + 3] = 255
		}
		return tex, true
	}

	return {}, false
}

free_texture :: proc(tex: Loaded_Texture, allocator := context.allocator) {
	if tex.owned && tex.pixels != nil {
		mem.free(cast(rawptr)tex.pixels, allocator = allocator)
	}
}

sample_texture :: proc(tex: Loaded_Texture, u, v: f32) -> [4]u8 {
	if tex.pixels == nil || tex.width == 0 || tex.height == 0 {
		return {255, 255, 255, 255}
	}
	u_clamped := clamp(u, 0, 0.9999)
	v_clamped := clamp(v, 0, 0.9999)
	x0 := i32(u_clamped * f32(tex.width - 1))
	y0 := i32(v_clamped * f32(tex.height - 1))
	pixel_offset := (y0 * tex.width + x0) * 4
	return {
		tex.pixels[pixel_offset + 0],
		tex.pixels[pixel_offset + 1],
		tex.pixels[pixel_offset + 2],
		tex.pixels[pixel_offset + 3],
	}
}

bake_texture_into_atlas :: proc(
	src: Loaded_Texture,
	dst: [^]u8,
	dst_width, dst_height: i32,
	dest_x, dest_y: i32,
	dest_width, dest_height: i32,
) {
	if src.pixels == nil {
		return
	}
	for y_idx := i32(0); y_idx < dest_height; y_idx += 1 {
		for x_idx := i32(0); x_idx < dest_width; x_idx += 1 {
			u := f32(x_idx) / f32(dest_width)
			v := f32(y_idx) / f32(dest_height)
			color := sample_texture(src, u, v)
			dst_x_abs := dest_x + x_idx
			dst_y_abs := dest_y + y_idx
			if dst_x_abs >= 0 && dst_x_abs < dst_width && dst_y_abs >= 0 && dst_y_abs < dst_height {
				pixel_offset := (dst_y_abs * dst_width + dst_x_abs) * 4
				dst[pixel_offset + 0] = color[0]
				dst[pixel_offset + 1] = color[1]
				dst[pixel_offset + 2] = color[2]
				dst[pixel_offset + 3] = color[3]
			}
		}
	}
}

bake_atlas_page :: proc(
	inputs: []Atlas_Bake_Input,
	page_width, page_height: i32,
	allocator := context.allocator,
) -> (pixels: [^]u8, ok: bool) {
	pixel_count := int(page_width * page_height)
	buffer_size := pixel_count * 4
	pixels_ptr, alloc_err := mem.alloc(buffer_size, allocator = allocator)
	if alloc_err != nil {
		return nil, false
	}
	pixels = cast([^]u8)pixels_ptr
	for i := 0; i < buffer_size; i += 4 {
		pixels[i + 0] = 255
		pixels[i + 1] = 255
		pixels[i + 2] = 255
		pixels[i + 3] = 255
	}
	for input in inputs {
		tex, load_ok := load_texture_from_file(input.color_path, allocator)
		if !load_ok {
			log.warnf("Failed to load color texture: %v", input.color_path)
			continue
		}
		defer free_texture(tex, allocator)

		bake_texture_into_atlas(
			tex,
			pixels,
			page_width, page_height,
			input.dest_x, input.dest_y,
			input.dest_width, input.dest_height,
		)
	}
	return pixels, true
}