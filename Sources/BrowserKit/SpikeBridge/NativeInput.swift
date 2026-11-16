// SPIKE (gate G3). Native input: synthesized NSEvents handed straight to the WKWebView, so the page sees
// `isTrusted == true` events with real default actions (focus, selection, form submission, :hover).
// Nothing goes through the window server: no Accessibility or Event-posting permission is needed, and the person's own
// pointer and keyboard are untouched.

import AppKit
import WebKit

@MainActor
enum NativeInput {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    static func flags(_ modifiers: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case "Alt": flags.insert(.option)
            case "Control": flags.insert(.control)
            case "Meta": flags.insert(.command)
            case "Shift": flags.insert(.shift)
            default: break
            }
        }
        return flags
    }

    /// Converts a point in main-frame CSS pixels to window coordinates.
    static func windowPoint(_ webView: WKWebView, css: CGPoint) throws -> (NSWindow, NSPoint) {
        guard let window = webView.window else { throw Unavailable(description: "tab is not in a window") }
        let zoom = webView.pageZoom * webView.magnification
        let local = CGPoint(x: css.x * zoom, y: css.y * zoom)
        guard local.x >= 0, local.y >= 0, local.x < webView.bounds.width, local.y < webView.bounds.height else {
            throw Unavailable(description: "point outside the visible web view")
        }
        let view = webView.isFlipped ? local : CGPoint(x: local.x, y: webView.bounds.height - local.y)
        return (window, webView.convert(view, to: nil))
    }

    private static var eventNumber = 1_000

    private static func mouse(_ type: NSEvent.EventType, _ window: NSWindow, _ point: NSPoint, _ flags: NSEvent.ModifierFlags, clicks: Int) -> NSEvent? {
        eventNumber += 1
        return NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
            pressure: type == .leftMouseUp || type == .rightMouseUp || type == .mouseMoved ? 0 : 1
        )
    }

    static func move(_ webView: WKWebView, css: CGPoint) throws {
        let (window, point) = try windowPoint(webView, css: css)
        // Approach from one pixel away so the page sees a pointer that moved onto the element.
        for target in [NSPoint(x: point.x - 1, y: point.y), point] {
            guard let event = mouse(.mouseMoved, window, target, [], clicks: 0) else { throw Unavailable(description: "could not create event") }
            webView.mouseMoved(with: event)
        }
    }

    /// Left or right click(s). Middle clicks have no NSEvent factory with a button number; callers fall back to script.
    static func click(_ webView: AgentWebView, css: CGPoint, button: String, count: Int, modifiers: [String]) throws {
        let (window, point) = try windowPoint(webView, css: css)
        let flags = flags(modifiers)
        if let moved = mouse(.mouseMoved, window, point, flags, clicks: 0) { webView.mouseMoved(with: moved) }
        if button == "right" { webView.suppressMenusUntil = Date().addingTimeInterval(1) }
        for click in 1...max(1, count) {
            let (downType, upType): (NSEvent.EventType, NSEvent.EventType) = button == "right" ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
            guard let down = mouse(downType, window, point, flags, clicks: click), let up = mouse(upType, window, point, flags, clicks: click) else {
                throw Unavailable(description: "could not create event")
            }
            if button == "right" {
                webView.rightMouseDown(with: down)
                webView.rightMouseUp(with: up)
            } else {
                webView.mouseDown(with: down)
                webView.mouseUp(with: up)
            }
        }
    }

    // MARK: Keyboard

    struct Key {
        var keyCode: UInt16
        var characters: String
        var charactersIgnoringModifiers: String
        var flags: NSEvent.ModifierFlags
    }

    private static let named: [String: (UInt16, String)] = [
        "Enter": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"), "Backspace": (51, "\u{7f}"),
        "Delete": (117, "\u{F728}"), "ArrowUp": (126, "\u{F700}"), "ArrowDown": (125, "\u{F701}"),
        "ArrowLeft": (123, "\u{F702}"), "ArrowRight": (124, "\u{F703}"), "PageUp": (116, "\u{F72C}"),
        "PageDown": (121, "\u{F72D}"), "Home": (115, "\u{F729}"), "End": (119, "\u{F72B}"), "Space": (49, " "),
    ]
    private static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let characterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// Parses `browser.press` chords (`Enter`, `a`, `Control+A`, `Meta+Shift+ArrowLeft`, `F5`) like the reference
    /// desktop does: modifiers Alt, Control, Meta, Shift; named keys; F1-F12; or one character.
    static func parse(_ chord: String) throws -> Key {
        guard !chord.isEmpty else {
            throw BrowserFailure("invalid_key", "A key is required. Use a named key such as Enter or ArrowDown, a single character, or a chord such as Control+A.")
        }
        var parts = (chord.hasSuffix("+") && chord.count > 1 ? String(chord.dropLast()) : chord).split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let key = parts.popLast().flatMap { $0.isEmpty ? "+" : $0 } ?? "+"
        for part in parts where !["Alt", "Control", "Meta", "Shift"].contains(part) {
            throw BrowserFailure("invalid_key", "Unknown key modifier \"\(part)\". Supported modifiers are Alt, Control, Meta, and Shift; for example Control+A. Use Meta for macOS command shortcuts.")
        }
        let modifiers = flags(parts)
        if let (code, characters) = named[key] {
            return Key(keyCode: code, characters: characters, charactersIgnoringModifiers: characters, flags: modifiers)
        }
        if key.count > 1, key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...12).contains(number) {
            let character = String(UnicodeScalar(0xF704 + number - 1)!)
            return Key(keyCode: functionKeys[number - 1], characters: character, charactersIgnoringModifiers: character, flags: modifiers.union(.function))
        }
        guard key.count == 1, let character = key.first else {
            throw BrowserFailure("invalid_key", "Unknown key \"\(key)\". Use Enter, Tab, Escape, Backspace, Delete, ArrowUp/Down/Left/Right, PageUp/Down, Home, End, Space, F1-F12, or one character. Use browser.fill for text.")
        }
        let lower = Character(character.lowercased())
        let shifted = character.isUppercase ? modifiers.union(.shift) : modifiers
        let typed = modifiers.contains(.command) || modifiers.contains(.control) ? String(lower) : String(character)
        return Key(keyCode: characterCodes[lower] ?? 0, characters: typed, charactersIgnoringModifiers: String(lower), flags: shifted)
    }

    static func press(_ webView: WKWebView, _ key: Key) throws {
        guard let window = webView.window else { throw Unavailable(description: "tab is not in a window") }
        if window.firstResponder !== webView { window.makeFirstResponder(webView) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            eventNumber += 1
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers, isARepeat: false, keyCode: key.keyCode
            ) else { throw Unavailable(description: "could not create key event") }
            if type == .keyDown {
                // Command chords travel as key equivalents first, as AppKit does for real input.
                if key.flags.contains(.command), webView.performKeyEquivalent(with: event) { continue }
                webView.keyDown(with: event)
            } else {
                webView.keyUp(with: event)
            }
        }
    }

    /// Text input through the web view's text input client: trusted `beforeinput`/`input` events, like
    /// CDP's `Input.insertText`. The target must already be focused with its contents selected.
    static func insertText(_ webView: WKWebView, _ text: String) throws {
        guard let window = webView.window else { throw Unavailable(description: "tab is not in a window") }
        if window.firstResponder !== webView { window.makeFirstResponder(webView) }
        if text.isEmpty {
            try press(webView, try parse("Backspace"))
        } else {
            webView.insertText(text)
        }
    }
}
