import CoreGraphics
import XCTest
@testable import BuKey

@MainActor
final class TextReplacerPlanningTests: XCTestCase {
    private let target = InputTargetIdentity(processID: 10, retainedElement: "replacement-target" as CFString)
    func testPlansReplacementBeforeDelimiter() {
        XCTAssertEqual(
            ReplacementPlan(snapshot: WordSnapshot(text: "ghbdtn", trailingDelimiterCount: 0), replacement: "привет"),
            ReplacementPlan(deleteCount: 6, insertionText: "привет")
        )
    }

    func testPlansReplacementWhilePreservingExistingDelimiter() {
        XCTAssertEqual(
            ReplacementPlan(snapshot: WordSnapshot(text: "руддщ", trailingDelimiterCount: 1), replacement: "hello"),
            ReplacementPlan(deleteCount: 6, insertionText: "hello ")
        )
    }

    func testEmptyWordProducesNoPlan() {
        XCTAssertNil(ReplacementPlan(snapshot: WordSnapshot(text: "", trailingDelimiterCount: 1), replacement: "hello"))
    }

    func testCreatesUnicodeTypingEventFromTemporarySource() throws {
        let source = CGEventSource(stateID: .privateState)
        let plan = ReplacementPlan(deleteCount: 0, insertionText: "Привет🙂")

        let events = try CGTextEventFactory.events(for: plan, source: source)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(unicodeString(in: events[0]), "Привет🙂")
    }

    func testRequiresKnownEditableTextCapabilityAndKnownProtectionState() {
        XCTAssertEqual(EditableInputPolicy.assess(role: "AXTextField", subrole: .known(nil), valueSettable: true), .editable)
        XCTAssertEqual(EditableInputPolicy.assess(role: "AXTextField", subrole: .known("AXSecureTextField"), valueSettable: true), .protected)
        XCTAssertEqual(EditableInputPolicy.assess(role: nil, subrole: .known(nil), valueSettable: true), .unsupported)
        XCTAssertEqual(EditableInputPolicy.assess(role: "AXTextField", subrole: .unknown, valueSettable: true), .unsupported)
        XCTAssertEqual(EditableInputPolicy.assess(role: "AXTextArea", subrole: .unknown, valueSettable: true), .editable)
        XCTAssertEqual(EditableInputPolicy.assess(role: "AXButton", subrole: .known(nil), valueSettable: true), .unsupported)
        XCTAssertEqual(EditableInputPolicy.assess(role: "AXTextArea", subrole: .known(nil), valueSettable: nil), .unsupported)
    }

    func testProtectedUnknownAndChangedTargetsEmitNoGlobalEdits() {
        let cases: [(FocusedInputAssessment, TextReplacementError)] = [
            (.protected, .protectedField),
            (.unsupported, .unsupportedControl),
            (.editable(FocusedInputContext(
                target: InputTargetIdentity(processID: 11, retainedElement: "changed-target" as CFString),
                selectionRange: TextSelectionRange(location: 0, length: 0)
            )), .unsupportedControl),
            (.editable(FocusedInputContext(
                target: target,
                selectionRange: TextSelectionRange(location: 9, length: 0)
            )), .unsupportedControl)
        ]

        for (assessment, expectedError) in cases {
            let poster = RecordingEventPoster()
            let replacer = TextReplacer(eventPoster: poster, contextChecker: FixedContextChecker(assessment))

            XCTAssertThrowsError(
                try replacer.replaceLastWord(
                    snapshot: WordSnapshot(text: "ghbdtn", trailingDelimiterCount: 0),
                    with: "привет",
                    context: InputEventContext(
                        target: target,
                        generation: 1,
                        selectionRange: TextSelectionRange(location: 6, length: 0)
                    )
                )
            ) { error in
                XCTAssertEqual(error as? TextReplacementError, expectedError)
            }
            XCTAssertTrue(poster.plans.isEmpty)
        }
    }

    private func unicodeString(in event: CGEvent) -> String {
        var actualLength = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &actualLength, unicodeString: nil)
        var buffer = [UniChar](repeating: 0, count: actualLength)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &actualLength, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: actualLength)
    }
}

private final class RecordingEventPoster: TextEventPosting {
    private(set) var plans: [ReplacementPlan] = []

    func post(_ plan: ReplacementPlan) throws {
        plans.append(plan)
    }
}

private struct FixedContextChecker: FocusedInputContextChecking {
    let assessment: FocusedInputAssessment

    init(_ assessment: FocusedInputAssessment) {
        self.assessment = assessment
    }

    func currentAssessment() -> FocusedInputAssessment { assessment }
}
