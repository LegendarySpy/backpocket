import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum Typer {
    private static let queue = DispatchQueue(label: "com.backpocket.typing", qos: .userInitiated)

    /// Presses ⌘V with the keycode that types "v" while Command is held on the
    /// active layout. That differs from the plain "v" key on layouts like
    /// Dvorak - QWERTY ⌘, where the plain key would send ⌘. instead.
    static func pressCommandV() {
        let keyCode = KeyLayout.current()?.commandKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
        queue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            var modifiers = HeldModifiers(source: source)
            modifiers.hold(.maskCommand)
            post(keyCode, flags: .maskCommand, from: source)
            modifiers.hold([])
        }
    }

    /// Types text into the focused field via synthetic key events. Reserved for
    /// values that must not transit the pasteboard, and for pastes nothing read.
    /// Each event carries the real keycode + modifiers from the current keyboard
    /// layout so keycode-translating apps (terminals) read it correctly, plus the
    /// unicode payload for everything else.
    /// The layout is read on the caller's thread; the paced posting is not, so a
    /// long value never stalls the UI.
    static func type(_ text: String) {
        let layout = KeyLayout.current()
        queue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            var modifiers = HeldModifiers(source: source)
            for character in text {
                let stroke = layout?.stroke(for: character)
                let flags = stroke?.flags ?? []
                modifiers.hold(flags)
                post(stroke?.keyCode ?? 0, flags: flags, unicode: Array(String(character).utf16), from: source)
                usleep(1500)
            }
            modifiers.hold([])
        }
    }

    private static func post(_ keyCode: CGKeyCode, flags: CGEventFlags, unicode: [UniChar]? = nil, from source: CGEventSource?) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            if let unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Real key events for the modifiers a synthetic keystroke needs. A flag on the
/// event alone isn't enough: macOS takes it as the new modifier state and keeps
/// it afterwards, so a ⌘V without a Command key up left every app seeing Command
/// held until the user pressed it. Everything pressed here is released here.
private struct HeldModifiers {
    let source: CGEventSource?
    private var held: CGEventFlags = []

    private static let keys: [(flag: CGEventFlags, keyCode: Int)] = [
        (.maskShift, kVK_Shift), (.maskAlternate, kVK_Option), (.maskCommand, kVK_Command)
    ]

    init(source: CGEventSource?) {
        self.source = source
    }

    mutating func hold(_ flags: CGEventFlags) {
        for key in Self.keys where held.contains(key.flag) != flags.contains(key.flag) {
            let keyDown = flags.contains(key.flag)
            if keyDown { held.insert(key.flag) } else { held.remove(key.flag) }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.keyCode), keyDown: keyDown) else { continue }
            event.flags = held
            event.post(tap: .cghidEventTap)
        }
    }
}

private struct KeyLayout {
    struct Stroke {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private let strokes: [Character: Stroke]
    private let commandKeyCodes: [Character: CGKeyCode]

    func stroke(for character: Character) -> Stroke? {
        strokes[character]
    }

    func commandKeyCode(for character: Character) -> CGKeyCode? {
        commandKeyCodes[character]
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
        let command = UInt32(cmdKey >> 8) & 0xFF
        let combos: [(flags: CGEventFlags, modifiers: UInt32)] = [
            ([], 0),
            (.maskShift, UInt32(shiftKey >> 8) & 0xFF),
            (.maskAlternate, UInt32(optionKey >> 8) & 0xFF),
            ([.maskShift, .maskAlternate], UInt32((shiftKey | optionKey) >> 8) & 0xFF),
        ]

        var strokes: [Character: Stroke] = [:]
        var commandKeyCodes: [Character: CGKeyCode] = [:]
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            func character(for keyCode: Int, modifiers: UInt32) -> Character? {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                guard UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifiers,
                    keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, characters.count, &length, &characters
                ) == noErr, length == 1, let scalar = UnicodeScalar(characters[0]) else { return nil }
                return Character(scalar)
            }
            for combo in combos {
                for keyCode in 0 ..< 128 {
                    guard let character = character(for: keyCode, modifiers: combo.modifiers),
                          strokes[character] == nil else { continue }
                    strokes[character] = Stroke(keyCode: CGKeyCode(keyCode), flags: combo.flags)
                }
            }
            for keyCode in 0 ..< 128 {
                guard let character = character(for: keyCode, modifiers: command),
                      commandKeyCodes[character] == nil else { continue }
                commandKeyCodes[character] = CGKeyCode(keyCode)
            }
        }
        // The return key translates to \r; facts carry \n.
        if let enter = strokes["\r"], strokes["\n"] == nil {
            strokes["\n"] = enter
        }
        return KeyLayout(strokes: strokes, commandKeyCodes: commandKeyCodes)
    }

    private init(strokes: [Character: Stroke], commandKeyCodes: [Character: CGKeyCode]) {
        self.strokes = strokes
        self.commandKeyCodes = commandKeyCodes
    }
}
