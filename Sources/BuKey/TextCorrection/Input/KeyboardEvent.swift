import Foundation

struct KeyboardModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt

    static let shift = KeyboardModifiers(rawValue: 1 << 0)
    static let option = KeyboardModifiers(rawValue: 1 << 1)
    static let command = KeyboardModifiers(rawValue: 1 << 2)
    static let control = KeyboardModifiers(rawValue: 1 << 3)
}

enum KeyboardKey: Equatable, Sendable {
    case character(Character)
    case capsLock
    case diagnosticK
    case space
    case backspace
    case deleteForward
    case returnKey
    case tab
    case escape
    case left, right, up, down, home, end
    case pageUp, pageDown
}

enum KeyboardEvent: Equatable, Sendable {
    case keyDown(KeyboardKey, modifiers: KeyboardModifiers = [])
    case mouseDown
    case mouseUp
    case focusChanged
    case paste
}

enum SyntheticEventMarker {
    static let value: Int64 = 0x6275537769746368
}
