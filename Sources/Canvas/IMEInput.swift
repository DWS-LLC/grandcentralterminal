// Text-input helpers for the canvas's NSTextInputClient implementation,
// ported from Ghostty's macOS app (KeyboardLayout, keyEventText, and the
// surrogate-pair handling Korean IMEs need).

import AppKit
import Carbon

// Current keyboard input source ID; used to detect input-method hijacks
// mid-keyDown (e.g. the IME switching layouts to show a candidate window).
// Must be called on the main thread: TIS APIs are not thread-safe.
enum KeyboardLayout {
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = unsafeBitCast(sourceIdPointer, to: CFString.self)
            return sourceId as String
        }
        return nil
    }
}

extension String {
    var startsWithASCIIControlCharacter: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// The string as the text of a terminal key event, or nil when it is
    /// empty or begins with an ASCII control character.
    ///
    /// Control characters are encoded by ghostty itself so the physical key
    /// and its modifiers stay available to protocols like the Kitty
    /// keyboard protocol.
    var keyEventText: String? {
        guard !isEmpty, !startsWithASCIIControlCharacter else { return nil }
        return self
    }
}

// macOS IMEs (notably Korean) can deliver a surrogate pair to insertText
// as two separate calls: the high half, then the low half. Buffer the lead
// surrogate and combine it when the trail arrives.

struct LeadSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let char = text.character(at: 0)
        guard UTF16.isLeadSurrogate(char) else { return nil }
        self.char = char
    }

    func encode(trail: TrailSurrogate) -> String {
        String(decoding: [char, trail.char], as: UTF16.self)
    }
}

struct TrailSurrogate {
    let char: UTF16Char

    init?(_ text: NSString) {
        guard text.length == 1 else { return nil }
        let char = text.character(at: 0)
        guard UTF16.isTrailSurrogate(char) else { return nil }
        self.char = char
    }
}
