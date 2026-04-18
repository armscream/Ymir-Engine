package game

import "core:fmt"
import ye "../Engine"
import "core:math/linalg"


a: ye.vec3 = {0, 0, 1}
b: ye.vec3 = {0, 1, 0}


run :: proc() {
    c := linalg.cross(a, b)
    fmt.println(" Cross product of", a, "and", b, "is", c)
	
}