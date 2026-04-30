package game

import ye "../Engine"
import "base:runtime"
import "core:fmt"
import "core:math/linalg"

import "vendor:glfw"


a: ye.Vec3 = {0, 0, 1}
b: ye.Vec3 = {0, 1, 0}

test :: proc() {
	// doing stuff
	fmt.println("doing stuff")
}

run :: proc() {


	test()
}

// deprecated for now