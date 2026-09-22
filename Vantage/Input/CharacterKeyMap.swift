import Foundation
import VantageCore

/// Maps characters typed on the software keyboard to Mac virtual key codes using the US layout,
/// so "Keystrokes" mode can send real key presses (with Shift where needed).
nonisolated enum CharacterKeyMap {
    struct Stroke: Equatable {
        let keyCode: UInt16
        let modifiers: KeyModifiers
    }

    private static let plain: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        " ": 0x31, "\t": 0x30, "\n": 0x24, "\r": 0x24,
    ]

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key press that produces `character` on a US keyboard, or nil if it needs Unicode input.
    static func stroke(for character: Character) -> Stroke? {
        if let code = plain[character] { return Stroke(keyCode: code, modifiers: []) }
        if character.isUppercase, let lower = character.lowercased().first, let code = plain[lower] {
            return Stroke(keyCode: code, modifiers: .shift)
        }
        if let base = shifted[character], let code = plain[base] {
            return Stroke(keyCode: code, modifiers: .shift)
        }
        return nil
    }
}
