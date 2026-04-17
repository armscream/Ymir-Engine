package ye

import "vendor:sdl3"
import "core:fmt"

renderer_backends :: enum {
    undefined,
    SDL3,
    OpenGL,
    Raylib,
    Vulkan,
    Software,
}

init_engine :: proc (renderer_backend: string, game_name: string) {
    fmt.println("Initializing Ymir Engine with renderer backend:", renderer_backend)

    switch renderer_backend {
    case "SDL3":
        fmt.println("Initializing SDL3 Renderer")
        //sdl3.Init(sdl3.INIT_VIDEO)
    
    case "OpenGL":
        fmt.println("OpenGL Renderer not implemented yet")
        // OpenGL initialization code would go here

    case "Raylib":
        fmt.println("Raylib Renderer not implemented yet")
        // Raylib initialization code would go here

    case "Vulkan":
        fmt.println("Vulkan Renderer not implemented yet")
        // Vulkan initialization code would go here

    case "Software":
        fmt.println("Software Renderer not implemented yet")
        // Software renderer initialization code would go here
    
    case "undefined":
        fmt.println("Unknown renderer backend: ", renderer_backend)
    }
    
}