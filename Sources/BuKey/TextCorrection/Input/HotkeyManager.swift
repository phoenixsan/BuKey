import Foundation

enum HotkeyCommand: Equatable, Sendable {
    case correctLastWord
    case convertSelection
}

struct HotkeyManager {
    static let capsLockDoubleTapInterval: TimeInterval = 0.5
    private var lastCapsLockTimestamp: TimeInterval?

    mutating func command(for event: KeyboardEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> HotkeyCommand? {
        if case .keyDown(.capsLock, _) = event {
            if let previous = lastCapsLockTimestamp,
               now >= previous,
               now - previous <= Self.capsLockDoubleTapInterval {
                lastCapsLockTimestamp = nil
                return .correctLastWord
            }
            lastCapsLockTimestamp = now
            return nil
        }
        guard case let .keyDown(.space, modifiers) = event else { return nil }
        switch modifiers {
        case [.option]: return nil
        case [.shift, .option]: return .convertSelection
        default: return nil
        }
    }

    mutating func reset() {
        lastCapsLockTimestamp = nil
    }
}
