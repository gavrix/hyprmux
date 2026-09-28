import AppKit
import GhosttyKit

// Input translation between AppKit and libghostty.
// Ported from Ghostty's macOS app (MIT): Ghostty.Input.swift, NSEvent+Extension.swift.

enum GhosttyInput {
    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    static func mouseButton(_ n: Int) -> ghostty_input_mouse_button_e {
        switch n {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        case 5: return GHOSTTY_MOUSE_SIX
        case 6: return GHOSTTY_MOUSE_SEVEN
        case 7: return GHOSTTY_MOUSE_EIGHT
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Packed scroll mods: bit 0 = precision, bits 1-3 = momentum phase.
    static func scrollMods(precision: Bool, momentum: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        var v: Int32 = precision ? 1 : 0
        let m: ghostty_input_mouse_momentum_e
        switch momentum {
        case .began: m = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: m = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: m = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: m = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: m = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: m = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: m = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        v |= Int32(m.rawValue) << 1
        return ghostty_input_scroll_mods_t(v)
    }
}

extension NSEvent {
    /// Builds a key event. `text` and `composing` are left for the caller
    /// because the C string must outlive the call.
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = GhosttyInput.mods(modifierFlags)
        // Heuristic from Ghostty: control and command never contribute to text translation.
        ev.consumed_mods = GhosttyInput.mods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let chars = characters(byApplyingModifiers: []),
           let cp = chars.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    /// Text for a key event, with control characters and function-key PUA values removed.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control)) }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }
}

extension String {
    var startsWithASCIIControl: Bool {
        guard let s = unicodeScalars.first else { return false }
        return s.value < 0x20 || s.value == 0x7F
    }
}
