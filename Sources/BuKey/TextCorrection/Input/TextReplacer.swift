import ApplicationServices
import CoreGraphics
import Foundation

struct ReplacementPlan: Equatable, Sendable {
    let deleteCount: Int
    let insertionText: String

    init(deleteCount: Int, insertionText: String) {
        self.deleteCount = deleteCount
        self.insertionText = insertionText
    }

    init?(snapshot: WordSnapshot, replacement: String) {
        guard !snapshot.text.isEmpty else { return nil }
        let delimiterCount = max(snapshot.trailingDelimiterCount, 0)
        deleteCount = snapshot.text.count + delimiterCount
        insertionText = replacement + String(repeating: " ", count: delimiterCount)
    }
}

enum TextReplacementError: Error, Equatable {
    case noSelection
    case protectedField
    case unsupportedControl
    case eventCreationFailed
}

@MainActor
protocol TextReplacing: AnyObject {
    func replaceLastWord(snapshot: WordSnapshot, with replacement: String, context: InputEventContext) throws
    func replaceRecentlyTyped(snapshot: WordSnapshot, with replacement: String) throws
    func convertSelection(context: InputEventContext, using converter: (String) -> String) throws
}

enum CGTextEventFactory {
    static func events(for plan: ReplacementPlan, source: CGEventSource?) throws -> [CGEvent] {
        var events: [CGEvent] = []
        for _ in 0..<plan.deleteCount {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else {
                throw TextReplacementError.eventCreationFailed
            }
            mark(down)
            mark(up)
            events.append(contentsOf: [down, up])
        }

        if !plan.insertionText.isEmpty {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw TextReplacementError.eventCreationFailed
            }
            let unicode = Array(plan.insertionText.utf16)
            down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            mark(down)
            mark(up)
            events.append(contentsOf: [down, up])
        }
        return events
    }

    private static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
    }
}

protocol TextEventPosting {
    func post(_ plan: ReplacementPlan) throws
}

struct CGTextEventPoster: TextEventPosting {
    func post(_ plan: ReplacementPlan) throws {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TextReplacementError.eventCreationFailed
        }
        for event in try CGTextEventFactory.events(for: plan, source: source) {
            event.post(tap: .cgSessionEventTap)
        }
    }
}

@MainActor
final class TextReplacer: TextReplacing {
    private let eventPoster: any TextEventPosting
    private let contextChecker: any FocusedInputContextChecking

    init(
        eventPoster: any TextEventPosting = CGTextEventPoster(),
        contextChecker: any FocusedInputContextChecking = AccessibilityFocusedInputContextChecker()
    ) {
        self.eventPoster = eventPoster
        self.contextChecker = contextChecker
    }

    func replaceLastWord(snapshot: WordSnapshot, with replacement: String, context: InputEventContext) throws {
        try validateContext(context)
        guard let plan = ReplacementPlan(snapshot: snapshot, replacement: replacement) else { return }
        try eventPoster.post(plan)
    }

    func replaceRecentlyTyped(snapshot: WordSnapshot, with replacement: String) throws {
        guard let plan = ReplacementPlan(snapshot: snapshot, replacement: replacement) else { return }
        try eventPoster.post(plan)
    }

    func convertSelection(context: InputEventContext, using converter: (String) -> String) throws {
        // Selection can legitimately change between the key event and the
        // accessibility read (for example, after Shift+Arrow or a mouse
        // drag).  The cached range is still required for last-word edits,
        // but selected-text conversion must validate the live target only and
        // then use the selection returned by AX at the moment of replacement.
        try validateTarget(context)
        let focused = try focusedElement(matching: context.target)

        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        if selectedResult == .attributeUnsupported {
            throw TextReplacementError.unsupportedControl
        }
        guard selectedResult == .success, let selection = selectedValue as? String else {
            throw TextReplacementError.noSelection
        }
        guard !selection.isEmpty else { throw TextReplacementError.noSelection }

        let converted = converter(selection)
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            focused,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue,
           AXUIElementSetAttributeValue(
            focused,
            kAXSelectedTextAttribute as CFString,
            converted as CFTypeRef
           ) == .success {
            return
        }

        // Web-backed controls often expose selected text as read-only even
        // though normal typing correctly replaces their current selection.
        try eventPoster.post(ReplacementPlan(deleteCount: 0, insertionText: converted))
    }

    private func validateContext(_ expected: InputEventContext) throws {
        switch contextChecker.currentAssessment() {
        case .protected:
            throw TextReplacementError.protectedField
        case .unsupported:
            throw TextReplacementError.unsupportedControl
        case let .editable(context):
            guard context.target == expected.target,
                  context.selectionRange == expected.selectionRange else {
                throw TextReplacementError.unsupportedControl
            }
        }
    }

    private func validateTarget(_ expected: InputEventContext) throws {
        switch contextChecker.currentAssessment() {
        case .protected:
            throw TextReplacementError.protectedField
        case .unsupported:
            throw TextReplacementError.unsupportedControl
        case let .editable(context):
            guard context.target == expected.target else {
                throw TextReplacementError.unsupportedControl
            }
        }
    }

    private func focusedElement(matching target: InputTargetIdentity) throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedResult == .success, let focusedValue else {
            throw TextReplacementError.unsupportedControl
        }
        let focused = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var processID: pid_t = 0
        guard AXUIElementGetPid(focused, &processID) == .success,
              target.matches(processID: processID, element: focused) else {
            throw TextReplacementError.unsupportedControl
        }
        return focused
    }
}
