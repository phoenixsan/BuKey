import Foundation

struct WordSnapshot: Equatable, Sendable {
    let text: String
    let trailingDelimiterCount: Int
}

enum WordBufferAction: Equatable, Sendable {
    case none
    case wordTerminated(WordSnapshot)
    case reset
}

struct WordBuffer {
    private static let maximumRecentTextLength = 50
    private(set) var currentWord: WordSnapshot?
    private(set) var previousWord: WordSnapshot?
    private(set) var recentText = ""

    var recentTextSnapshot: WordSnapshot? {
        recentText.isEmpty ? nil : WordSnapshot(text: recentText, trailingDelimiterCount: 0)
    }

    mutating func consume(_ event: KeyboardEvent) -> WordBufferAction {
        guard case let .keyDown(key, modifiers) = event else { return reset() }
        if key == .capsLock { return .none }
        guard modifiers.isEmpty else { return reset() }

        switch key {
        case .capsLock:
            return .none
        case .diagnosticK:
            return reset()
        case let .character(character):
            guard character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                return reset()
            }
            let combined = (currentWord?.text ?? "") + String(character)
            let text = String(combined.suffix(Self.maximumRecentTextLength))
            currentWord = WordSnapshot(text: text, trailingDelimiterCount: 0)
            recentText.append(character)
            trimRecentTextIfNeeded()
            return .none
        case .backspace:
            if !recentText.isEmpty { recentText.removeLast() }
            guard let current = currentWord else { return .none }
            let text = String(current.text.dropLast())
            currentWord = text.isEmpty ? nil : WordSnapshot(text: text, trailingDelimiterCount: 0)
            return .none
        case .space:
            if !recentText.isEmpty {
                recentText.append(" ")
                trimRecentTextIfNeeded()
            }
            guard let current = currentWord else {
                if let previous = previousWord {
                    previousWord = WordSnapshot(text: previous.text, trailingDelimiterCount: previous.trailingDelimiterCount + 1)
                }
                return .none
            }
            let terminated = WordSnapshot(text: current.text, trailingDelimiterCount: 1)
            previousWord = terminated
            currentWord = nil
            return .wordTerminated(terminated)
        case .deleteForward, .returnKey, .tab, .escape,
             .left, .right, .up, .down, .home, .end, .pageUp, .pageDown:
            return reset()
        }
    }

    private mutating func reset() -> WordBufferAction {
        currentWord = nil
        previousWord = nil
        recentText = ""
        return .reset
    }

    private mutating func trimRecentTextIfNeeded() {
        let overflow = recentText.count - Self.maximumRecentTextLength
        if overflow > 0 { recentText.removeFirst(overflow) }
    }
}
