import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum Typer {
    /// Types text into the focused field via synthetic key events. Nothing
    /// touches the clipboard. Each event carries the real keycode + modifiers
    /// from the current keyboard layout so keycode-translating apps (terminals)
    /// read it correctly, plus the unicode payload for everything else.
    static func type(_ text: String) {
        let layout = KeyLayout.current()
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            let stroke = layout?.stroke(for: character)
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source, virtualKey: stroke?.keyCode ?? 0, keyDown: keyDown
                ) else { continue }
                event.flags = stroke?.flags ?? []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            usleep(1500)
        }
    }
}

private struct KeyLayout {
    struct Stroke {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private let strokes: [Character: Stroke]

    func stroke(for character: Character) -> Stroke? {
        strokes[character]
    }

    /// Reverse map of the active keyboard layout: character -> (keycode, modifiers),
    /// built by translating every keycode under each modifier set.
    static func current() -> KeyLayout? {
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataRef = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        let combos: [(flags: CGEventFlags, modifiers: UInt32)] = [
            ([], 0),
            (.maskShift, UInt32(shiftKey >> 8) & 0xFF),
            (.maskAlternate, UInt32(optionKey >> 8) & 0xFF),
            ([.maskShift, .maskAlternate], UInt32((shiftKey | optionKey) >> 8) & 0xFF),
        ]

        var strokes: [Character: Stroke] = [:]
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for combo in combos {
                for keyCode in 0 ..< 128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    guard UCKeyTranslate(
                        layout, UInt16(keyCode), UInt16(kUCKeyActionDown), combo.modifiers,
                        keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState, characters.count, &length, &characters
                    ) == noErr, length == 1, let scalar = UnicodeScalar(characters[0]) else { continue }
                    let character = Character(scalar)
                    if strokes[character] == nil {
                        strokes[character] = Stroke(keyCode: CGKeyCode(keyCode), flags: combo.flags)
                    }
                }
            }
        }
        // The return key translates to \r; facts carry \n.
        if let enter = strokes["\r"], strokes["\n"] == nil {
            strokes["\n"] = enter
        }
        return KeyLayout(strokes: strokes)
    }

    private init(strokes: [Character: Stroke]) {
        self.strokes = strokes
    }
}
