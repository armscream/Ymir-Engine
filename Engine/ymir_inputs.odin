package ye

import "core:encoding/json"
import "core:fmt"
import "core:os"

default_keybinds_path :: "Config/keybindings.json"

KeyCode :: distinct i32

KeyCategory :: enum i32 {
    Unknown = 0,
    Keyboard = 1,
    Mouse = 2,
    Gamepad = 3,
    Hotas = 4,
    Android = 5,
    Platform = 6,
    Touch = 7,
}

make_key_code :: #force_inline proc "contextless" (category: KeyCategory, value: i32) -> KeyCode {
    return KeyCode((i32(category) << 16) | (value & 0xFFFF))
}

key_code_category :: #force_inline proc(code: KeyCode) -> KeyCategory {
    return KeyCategory((i32(code) >> 16) & 0xFFFF)
}

key_code_value :: #force_inline proc(code: KeyCode) -> i32 {
    return i32(code) & 0xFFFF
}

// Keyboard
KEYBOARD_ESCAPE      := make_key_code(.Keyboard, 1)
KEYBOARD_TAB         := make_key_code(.Keyboard, 2)
KEYBOARD_CAPS_LOCK   := make_key_code(.Keyboard, 3)
KEYBOARD_LEFT_SHIFT  := make_key_code(.Keyboard, 4)
KEYBOARD_RIGHT_SHIFT := make_key_code(.Keyboard, 5)
KEYBOARD_LEFT_CTRL   := make_key_code(.Keyboard, 6)
KEYBOARD_RIGHT_CTRL  := make_key_code(.Keyboard, 7)
KEYBOARD_LEFT_ALT    := make_key_code(.Keyboard, 8)
KEYBOARD_RIGHT_ALT   := make_key_code(.Keyboard, 9)
KEYBOARD_LEFT_GUI    := make_key_code(.Keyboard, 10)
KEYBOARD_RIGHT_GUI   := make_key_code(.Keyboard, 11)
KEYBOARD_ENTER       := make_key_code(.Keyboard, 12)
KEYBOARD_SPACE       := make_key_code(.Keyboard, 13)
KEYBOARD_BACKSPACE   := make_key_code(.Keyboard, 14)
KEYBOARD_DELETE      := make_key_code(.Keyboard, 15)
KEYBOARD_INSERT      := make_key_code(.Keyboard, 16)
KEYBOARD_HOME        := make_key_code(.Keyboard, 17)
KEYBOARD_END         := make_key_code(.Keyboard, 18)
KEYBOARD_PAGE_UP     := make_key_code(.Keyboard, 19)
KEYBOARD_PAGE_DOWN   := make_key_code(.Keyboard, 20)
KEYBOARD_UP          := make_key_code(.Keyboard, 21)
KEYBOARD_DOWN        := make_key_code(.Keyboard, 22)
KEYBOARD_LEFT        := make_key_code(.Keyboard, 23)
KEYBOARD_RIGHT       := make_key_code(.Keyboard, 24)
KEYBOARD_PRINT_SCREEN := make_key_code(.Keyboard, 25)
KEYBOARD_SCROLL_LOCK := make_key_code(.Keyboard, 26)
KEYBOARD_PAUSE       := make_key_code(.Keyboard, 27)

KEYBOARD_A := make_key_code(.Keyboard, 30)
KEYBOARD_B := make_key_code(.Keyboard, 31)
KEYBOARD_C := make_key_code(.Keyboard, 32)
KEYBOARD_D := make_key_code(.Keyboard, 33)
KEYBOARD_E := make_key_code(.Keyboard, 34)
KEYBOARD_F := make_key_code(.Keyboard, 35)
KEYBOARD_G := make_key_code(.Keyboard, 36)
KEYBOARD_H := make_key_code(.Keyboard, 37)
KEYBOARD_I := make_key_code(.Keyboard, 38)
KEYBOARD_J := make_key_code(.Keyboard, 39)
KEYBOARD_K := make_key_code(.Keyboard, 40)
KEYBOARD_L := make_key_code(.Keyboard, 41)
KEYBOARD_M := make_key_code(.Keyboard, 42)
KEYBOARD_N := make_key_code(.Keyboard, 43)
KEYBOARD_O := make_key_code(.Keyboard, 44)
KEYBOARD_P := make_key_code(.Keyboard, 45)
KEYBOARD_Q := make_key_code(.Keyboard, 46)
KEYBOARD_R := make_key_code(.Keyboard, 47)
KEYBOARD_S := make_key_code(.Keyboard, 48)
KEYBOARD_T := make_key_code(.Keyboard, 49)
KEYBOARD_U := make_key_code(.Keyboard, 50)
KEYBOARD_V := make_key_code(.Keyboard, 51)
KEYBOARD_W := make_key_code(.Keyboard, 52)
KEYBOARD_X := make_key_code(.Keyboard, 53)
KEYBOARD_Y := make_key_code(.Keyboard, 54)
KEYBOARD_Z := make_key_code(.Keyboard, 55)

KEYBOARD_0 := make_key_code(.Keyboard, 60)
KEYBOARD_1 := make_key_code(.Keyboard, 61)
KEYBOARD_2 := make_key_code(.Keyboard, 62)
KEYBOARD_3 := make_key_code(.Keyboard, 63)
KEYBOARD_4 := make_key_code(.Keyboard, 64)
KEYBOARD_5 := make_key_code(.Keyboard, 65)
KEYBOARD_6 := make_key_code(.Keyboard, 66)
KEYBOARD_7 := make_key_code(.Keyboard, 67)
KEYBOARD_8 := make_key_code(.Keyboard, 68)
KEYBOARD_9 := make_key_code(.Keyboard, 69)

KEYBOARD_F1  := make_key_code(.Keyboard, 80)
KEYBOARD_F2  := make_key_code(.Keyboard, 81)
KEYBOARD_F3  := make_key_code(.Keyboard, 82)
KEYBOARD_F4  := make_key_code(.Keyboard, 83)
KEYBOARD_F5  := make_key_code(.Keyboard, 84)
KEYBOARD_F6  := make_key_code(.Keyboard, 85)
KEYBOARD_F7  := make_key_code(.Keyboard, 86)
KEYBOARD_F8  := make_key_code(.Keyboard, 87)
KEYBOARD_F9  := make_key_code(.Keyboard, 88)
KEYBOARD_F10 := make_key_code(.Keyboard, 89)
KEYBOARD_F11 := make_key_code(.Keyboard, 90)
KEYBOARD_F12 := make_key_code(.Keyboard, 91)
KEYBOARD_F13 := make_key_code(.Keyboard, 92)
KEYBOARD_F14 := make_key_code(.Keyboard, 93)
KEYBOARD_F15 := make_key_code(.Keyboard, 94)
KEYBOARD_F16 := make_key_code(.Keyboard, 95)
KEYBOARD_F17 := make_key_code(.Keyboard, 96)
KEYBOARD_F18 := make_key_code(.Keyboard, 97)
KEYBOARD_F19 := make_key_code(.Keyboard, 98)
KEYBOARD_F20 := make_key_code(.Keyboard, 99)
KEYBOARD_F21 := make_key_code(.Keyboard, 100)
KEYBOARD_F22 := make_key_code(.Keyboard, 101)
KEYBOARD_F23 := make_key_code(.Keyboard, 102)
KEYBOARD_F24 := make_key_code(.Keyboard, 103)

KEYBOARD_GRAVE       := make_key_code(.Keyboard, 110)
KEYBOARD_MINUS       := make_key_code(.Keyboard, 111)
KEYBOARD_EQUALS      := make_key_code(.Keyboard, 112)
KEYBOARD_LEFT_BRACKET := make_key_code(.Keyboard, 113)
KEYBOARD_RIGHT_BRACKET := make_key_code(.Keyboard, 114)
KEYBOARD_BACKSLASH   := make_key_code(.Keyboard, 115)
KEYBOARD_SEMICOLON   := make_key_code(.Keyboard, 116)
KEYBOARD_APOSTROPHE  := make_key_code(.Keyboard, 117)
KEYBOARD_COMMA       := make_key_code(.Keyboard, 118)
KEYBOARD_PERIOD      := make_key_code(.Keyboard, 119)
KEYBOARD_SLASH       := make_key_code(.Keyboard, 120)

KEYBOARD_NUMPAD_0       := make_key_code(.Keyboard, 130)
KEYBOARD_NUMPAD_1       := make_key_code(.Keyboard, 131)
KEYBOARD_NUMPAD_2       := make_key_code(.Keyboard, 132)
KEYBOARD_NUMPAD_3       := make_key_code(.Keyboard, 133)
KEYBOARD_NUMPAD_4       := make_key_code(.Keyboard, 134)
KEYBOARD_NUMPAD_5       := make_key_code(.Keyboard, 135)
KEYBOARD_NUMPAD_6       := make_key_code(.Keyboard, 136)
KEYBOARD_NUMPAD_7       := make_key_code(.Keyboard, 137)
KEYBOARD_NUMPAD_8       := make_key_code(.Keyboard, 138)
KEYBOARD_NUMPAD_9       := make_key_code(.Keyboard, 139)
KEYBOARD_NUMPAD_ADD     := make_key_code(.Keyboard, 140)
KEYBOARD_NUMPAD_SUBTRACT := make_key_code(.Keyboard, 141)
KEYBOARD_NUMPAD_MULTIPLY := make_key_code(.Keyboard, 142)
KEYBOARD_NUMPAD_DIVIDE  := make_key_code(.Keyboard, 143)
KEYBOARD_NUMPAD_DECIMAL := make_key_code(.Keyboard, 144)
KEYBOARD_NUMPAD_ENTER   := make_key_code(.Keyboard, 145)

// Mouse
MOUSE_LEFT       := make_key_code(.Mouse, 1)
MOUSE_RIGHT      := make_key_code(.Mouse, 2)
MOUSE_MIDDLE     := make_key_code(.Mouse, 3)
MOUSE_X1         := make_key_code(.Mouse, 4)
MOUSE_X2         := make_key_code(.Mouse, 5)
MOUSE_WHEEL_UP   := make_key_code(.Mouse, 6)
MOUSE_WHEEL_DOWN := make_key_code(.Mouse, 7)
MOUSE_WHEEL_LEFT := make_key_code(.Mouse, 8)
MOUSE_WHEEL_RIGHT := make_key_code(.Mouse, 9)
MOUSE_MOVE_X     := make_key_code(.Mouse, 10)
MOUSE_MOVE_Y     := make_key_code(.Mouse, 11)

// Gamepad
GAMEPAD_A             := make_key_code(.Gamepad, 1)
GAMEPAD_B             := make_key_code(.Gamepad, 2)
GAMEPAD_X             := make_key_code(.Gamepad, 3)
GAMEPAD_Y             := make_key_code(.Gamepad, 4)
GAMEPAD_BACK          := make_key_code(.Gamepad, 5)
GAMEPAD_GUIDE         := make_key_code(.Gamepad, 6)
GAMEPAD_START         := make_key_code(.Gamepad, 7)
GAMEPAD_LEFT_STICK    := make_key_code(.Gamepad, 8)
GAMEPAD_RIGHT_STICK   := make_key_code(.Gamepad, 9)
GAMEPAD_LEFT_SHOULDER := make_key_code(.Gamepad, 10)
GAMEPAD_RIGHT_SHOULDER := make_key_code(.Gamepad, 11)
GAMEPAD_DPAD_UP       := make_key_code(.Gamepad, 12)
GAMEPAD_DPAD_DOWN     := make_key_code(.Gamepad, 13)
GAMEPAD_DPAD_LEFT     := make_key_code(.Gamepad, 14)
GAMEPAD_DPAD_RIGHT    := make_key_code(.Gamepad, 15)
GAMEPAD_LEFT_TRIGGER  := make_key_code(.Gamepad, 16)
GAMEPAD_RIGHT_TRIGGER := make_key_code(.Gamepad, 17)
GAMEPAD_LEFT_X        := make_key_code(.Gamepad, 18)
GAMEPAD_LEFT_Y        := make_key_code(.Gamepad, 19)
GAMEPAD_RIGHT_X       := make_key_code(.Gamepad, 20)
GAMEPAD_RIGHT_Y       := make_key_code(.Gamepad, 21)

// HOTAS / Joystick
HOTAS_TRIGGER   := make_key_code(.Hotas, 1)
HOTAS_THUMB     := make_key_code(.Hotas, 2)
HOTAS_TOP       := make_key_code(.Hotas, 3)
HOTAS_PINKIE    := make_key_code(.Hotas, 4)
HOTAS_BUTTON_1  := make_key_code(.Hotas, 10)
HOTAS_BUTTON_2  := make_key_code(.Hotas, 11)
HOTAS_BUTTON_3  := make_key_code(.Hotas, 12)
HOTAS_BUTTON_4  := make_key_code(.Hotas, 13)
HOTAS_BUTTON_5  := make_key_code(.Hotas, 14)
HOTAS_BUTTON_6  := make_key_code(.Hotas, 15)
HOTAS_BUTTON_7  := make_key_code(.Hotas, 16)
HOTAS_BUTTON_8  := make_key_code(.Hotas, 17)
HOTAS_BUTTON_9  := make_key_code(.Hotas, 18)
HOTAS_BUTTON_10 := make_key_code(.Hotas, 19)
HOTAS_BUTTON_11 := make_key_code(.Hotas, 20)
HOTAS_BUTTON_12 := make_key_code(.Hotas, 21)
HOTAS_BUTTON_13 := make_key_code(.Hotas, 22)
HOTAS_BUTTON_14 := make_key_code(.Hotas, 23)
HOTAS_BUTTON_15 := make_key_code(.Hotas, 24)
HOTAS_BUTTON_16 := make_key_code(.Hotas, 25)
HOTAS_BUTTON_17 := make_key_code(.Hotas, 26)
HOTAS_BUTTON_18 := make_key_code(.Hotas, 27)
HOTAS_BUTTON_19 := make_key_code(.Hotas, 28)
HOTAS_BUTTON_20 := make_key_code(.Hotas, 29)
HOTAS_BUTTON_21 := make_key_code(.Hotas, 30)
HOTAS_BUTTON_22 := make_key_code(.Hotas, 31)
HOTAS_BUTTON_23 := make_key_code(.Hotas, 32)
HOTAS_BUTTON_24 := make_key_code(.Hotas, 33)
HOTAS_BUTTON_25 := make_key_code(.Hotas, 34)
HOTAS_BUTTON_26 := make_key_code(.Hotas, 35)
HOTAS_BUTTON_27 := make_key_code(.Hotas, 36)
HOTAS_BUTTON_28 := make_key_code(.Hotas, 37)
HOTAS_BUTTON_29 := make_key_code(.Hotas, 38)
HOTAS_BUTTON_30 := make_key_code(.Hotas, 39)
HOTAS_BUTTON_31 := make_key_code(.Hotas, 40)
HOTAS_BUTTON_32 := make_key_code(.Hotas, 41)
HOTAS_HAT_UP    := make_key_code(.Hotas, 50)
HOTAS_HAT_DOWN  := make_key_code(.Hotas, 51)
HOTAS_HAT_LEFT  := make_key_code(.Hotas, 52)
HOTAS_HAT_RIGHT := make_key_code(.Hotas, 53)
HOTAS_AXIS_X    := make_key_code(.Hotas, 60)
HOTAS_AXIS_Y    := make_key_code(.Hotas, 61)
HOTAS_AXIS_Z    := make_key_code(.Hotas, 62)
HOTAS_AXIS_RX   := make_key_code(.Hotas, 63)
HOTAS_AXIS_RY   := make_key_code(.Hotas, 64)
HOTAS_AXIS_RZ   := make_key_code(.Hotas, 65)
HOTAS_THROTTLE  := make_key_code(.Hotas, 66)
HOTAS_RUDDER    := make_key_code(.Hotas, 67)
HOTAS_SLIDER_1  := make_key_code(.Hotas, 68)
HOTAS_SLIDER_2  := make_key_code(.Hotas, 69)

// Android
ANDROID_BACK          := make_key_code(.Android, 1)
ANDROID_HOME          := make_key_code(.Android, 2)
ANDROID_MENU          := make_key_code(.Android, 3)
ANDROID_SEARCH        := make_key_code(.Android, 4)
ANDROID_VOLUME_UP     := make_key_code(.Android, 5)
ANDROID_VOLUME_DOWN   := make_key_code(.Android, 6)
ANDROID_CAMERA        := make_key_code(.Android, 7)
ANDROID_POWER         := make_key_code(.Android, 8)
ANDROID_APP_SWITCH    := make_key_code(.Android, 9)
ANDROID_NOTIFICATION  := make_key_code(.Android, 10)
ANDROID_DPAD_UP       := make_key_code(.Android, 11)
ANDROID_DPAD_DOWN     := make_key_code(.Android, 12)
ANDROID_DPAD_LEFT     := make_key_code(.Android, 13)
ANDROID_DPAD_RIGHT    := make_key_code(.Android, 14)
ANDROID_DPAD_CENTER   := make_key_code(.Android, 15)

// Platform / system actions
PLATFORM_QUIT             := make_key_code(.Platform, 1)
PLATFORM_FOCUS_GAINED     := make_key_code(.Platform, 2)
PLATFORM_FOCUS_LOST       := make_key_code(.Platform, 3)
PLATFORM_WINDOW_RESIZED   := make_key_code(.Platform, 4)
PLATFORM_SUSPEND          := make_key_code(.Platform, 5)
PLATFORM_RESUME           := make_key_code(.Platform, 6)
PLATFORM_SCREENSHOT       := make_key_code(.Platform, 7)
PLATFORM_DEBUG_CONSOLE    := make_key_code(.Platform, 8)
PLATFORM_COPY             := make_key_code(.Platform, 9)
PLATFORM_PASTE            := make_key_code(.Platform, 10)

// Touch / pen style inputs
TOUCH_PRIMARY_DOWN    := make_key_code(.Touch, 1)
TOUCH_PRIMARY_UP      := make_key_code(.Touch, 2)
TOUCH_PRIMARY_MOVE    := make_key_code(.Touch, 3)
TOUCH_SECONDARY_DOWN  := make_key_code(.Touch, 4)
TOUCH_SECONDARY_UP    := make_key_code(.Touch, 5)
TOUCH_SECONDARY_MOVE  := make_key_code(.Touch, 6)
TOUCH_PINCH_IN        := make_key_code(.Touch, 7)
TOUCH_PINCH_OUT       := make_key_code(.Touch, 8)
TOUCH_ROTATE_CW       := make_key_code(.Touch, 9)
TOUCH_ROTATE_CCW      := make_key_code(.Touch, 10)

Keybinds :: struct {
    move_forward:  KeyCode,
    move_backward: KeyCode,
    move_left:     KeyCode,
    move_right:    KeyCode,
    move_up:       KeyCode,
    move_down:     KeyCode,
    sprint:        KeyCode,
    escape:        KeyCode,
    console:       KeyCode,
}

default_keybinds :: proc() -> Keybinds {
    return Keybinds{
        move_forward = KEYBOARD_W,
        move_backward = KEYBOARD_S,
        move_left = KEYBOARD_A,
        move_right = KEYBOARD_D,
        move_up = KEYBOARD_SPACE,
        move_down = KEYBOARD_C,
        sprint = KEYBOARD_L,
        escape = KEYBOARD_ESCAPE,
        console = KEYBOARD_GRAVE,
    }
}

load_keybinds :: proc(path: string) -> (Keybinds, bool) {
    loaded := default_keybinds()

    if path == "" {
        return loaded, false
    }

    raw, read_err := os.read_entire_file(path, context.allocator)
    if read_err != nil {
        fmt.eprintln("Failed to read keybinds:", read_err)
        return loaded, false
    }
    defer delete(raw)

    if len(raw) == 0 {
        return loaded, false
    }

    if unmarshal_err := json.unmarshal(raw, &loaded); unmarshal_err != nil {
        fmt.eprintln("Failed to parse keybinds:", unmarshal_err)
        return loaded, false
    }

    return loaded, true
}

save_keybinds :: proc(path: string, keybinds: Keybinds) -> bool {
    if path == "" {
        return false
    }

    out, marshal_err := json.marshal(keybinds, allocator = context.temp_allocator)
    if marshal_err != nil {
        fmt.eprintln("Failed to serialize keybinds:", marshal_err)
        return false
    }

    if write_err := os.write_entire_file(
        path,
        out,
        os.Permissions_Read_All + {.Write_User},
        true,
    ); write_err != nil {
        fmt.eprintln("Failed to write keybinds:", write_err)
        return false
    }

    return true
}

