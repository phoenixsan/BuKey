import CoreGraphics
import XCTest
@testable import BuKey

final class KeyboardMonitorTests: XCTestCase {
    private let firstTarget = InputTargetIdentity(processID: 10, retainedElement: "first" as CFString)
    private let secondTarget = InputTargetIdentity(processID: 20, retainedElement: "second" as CFString)

    func testTargetEqualityUsesRetainedElementEqualityRatherThanMatchingHashData() {
        let firstElement = CollidingElementToken(identifier: 1)
        let secondElement = CollidingElementToken(identifier: 2)
        XCTAssertEqual(CFHash(firstElement), CFHash(secondElement))

        let first = InputTargetIdentity(processID: 10, retainedElement: firstElement)
        let second = InputTargetIdentity(processID: 10, retainedElement: secondElement)

        XCTAssertNotEqual(first, second)
    }

    func testInvalidatedAndStaleCacheIsUnavailableUntilMatchingRefreshCompletes() {
        let cache = FocusedInputContextCache(maximumAge: 1)
        let staleRefresh = cache.invalidate()
        let currentRefresh = cache.invalidate()

        XCTAssertFalse(cache.store(editable(firstTarget), for: staleRefresh, capturedAt: 10))
        XCTAssertNil(cache.snapshot(at: 10))
        XCTAssertTrue(cache.store(editable(firstTarget), for: currentRefresh, capturedAt: 10))
        XCTAssertNotNil(cache.snapshot(at: 10.5))
        XCTAssertNil(cache.snapshot(at: 11.1))
    }

    func testDoubleCapsBypassesAccessibilityLookup() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let first = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true),
              let second = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true) else {
            return XCTFail("Expected keyboard event")
        }
        first.flags = .maskAlternate
        second.flags = .maskAlternate

        _ = monitor.handle(type: .keyDown, event: first)
        let returned = monitor.handle(type: .keyDown, event: second)

        XCTAssertNil(returned)
        XCTAssertEqual(coordinator.liveAssessmentCount, 0)
        XCTAssertEqual(coordinator.cachedSnapshotCount, 2)
    }

    func testDirectTypingCorrectionWorksWithoutAccessibleField() {
        var processor = DirectTypingProcessor()
        for (offset, character) in "ghbdtn".enumerated() {
            XCTAssertNil(processor.process(.keyDown(.character(character)), secureInputEnabled: false, now: Double(offset)).request)
        }

        _ = processor.process(.keyDown(.capsLock), secureInputEnabled: false, now: 10)
        let result = processor.process(.keyDown(.capsLock), secureInputEnabled: false, now: 10.4)

        XCTAssertTrue(result.recognizedDoubleCaps)
        XCTAssertEqual(result.request?.snapshot.text, "ghbdtn")
    }

    func testDirectTypingCorrectionForgetsProtectedInput() {
        var processor = DirectTypingProcessor()
        for (offset, character) in "secret".enumerated() {
            _ = processor.process(.keyDown(.character(character)), secureInputEnabled: false, now: Double(offset))
        }
        _ = processor.process(.keyDown(.character("x")), secureInputEnabled: true, now: 10)
        _ = processor.process(.keyDown(.capsLock), secureInputEnabled: false, now: 11)
        let result = processor.process(.keyDown(.capsLock), secureInputEnabled: false, now: 11.4)

        XCTAssertTrue(result.recognizedDoubleCaps)
        XCTAssertNil(result.request)
    }

    func testNativeCapsLockFlagsChangedEventsTriggerDoubleTap() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let first = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true),
              let second = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true) else {
            return XCTFail("Expected keyboard events")
        }

        XCTAssertNotNil(monitor.handle(type: .flagsChanged, event: first))
        XCTAssertNil(monitor.handle(type: .flagsChanged, event: second))
    }

    func testKarabinerHyperFlagsChangedEventsTriggerDoubleTap() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let first = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true),
              let second = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: true) else {
            return XCTFail("Expected keyboard events")
        }
        first.flags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        second.flags = first.flags

        XCTAssertNotNil(monitor.handle(type: .flagsChanged, event: first))
        XCTAssertNil(monitor.handle(type: .flagsChanged, event: second))
    }

    func testOrdinaryModifierFlagsChangedDoesNotInvalidateInputContext() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true) else {
            return XCTFail("Expected modifier event")
        }
        event.flags = .maskAlternate

        XCTAssertNotNil(monitor.handle(type: .flagsChanged, event: event))
        XCTAssertEqual(coordinator.refreshRequestCount, 0)
    }

    func testRapidCharactersAdvanceCachedCaretSoWordCanAccumulate() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)

        for (keyCode, character) in [(0, "g"), (1, "h"), (2, "b"), (3, "d"), (4, "t"), (5, "n")] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) else {
                return XCTFail("Expected keyboard event")
            }
            let units = Array(character.utf16)
            units.withUnsafeBufferPointer { buffer in
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
            }
            XCTAssertNotNil(monitor.handle(type: .keyDown, event: event))
        }

        XCTAssertEqual(coordinator.snapshot?.assessment, editable(firstTarget, location: 6))
    }

    func testStaleHotkeyPassesThroughAndInvalidatesCachedRange() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        coordinator.refuseCaretAdvances = true
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)

        guard let character = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let firstCaps = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true),
              let hotkey = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true) else {
            return XCTFail("Expected keyboard events")
        }
        let units = Array("g".utf16)
        units.withUnsafeBufferPointer { buffer in
            character.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
        }
        _ = monitor.handle(type: .keyDown, event: character)
        firstCaps.flags = .maskAlternate
        hotkey.flags = .maskAlternate

        XCTAssertNotNil(monitor.handle(type: .keyDown, event: hotkey))
        XCTAssertNil(coordinator.snapshot)
        XCTAssertGreaterThanOrEqual(coordinator.refreshRequestCount, 1)
    }

    func testMissingCachedContextPassesHotkeyThroughAndRequestsAsyncRefresh() throws {
        let coordinator = RecordingContextCoordinator(snapshot: nil)
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true) else {
            return XCTFail("Expected keyboard event")
        }
        event.flags = .maskAlternate

        let returned = monitor.handle(type: .keyDown, event: event)

        XCTAssertNotNil(returned)
        XCTAssertEqual(coordinator.liveAssessmentCount, 0)
        XCTAssertEqual(coordinator.refreshRequestCount, 1)
    }

    func testCarbonReservedKeystrokeBypassesEventTapProcessing() throws {
        let coordinator = RecordingContextCoordinator(snapshot: nil)
        coordinator.liveAssessment = editable(firstTarget, location: 2, length: 4)
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: true) else {
            return XCTFail("Expected keyboard event")
        }
        event.flags = [.maskShift, .maskControl, .maskAlternate]

        let returned = monitor.handle(type: .keyDown, event: event)

        XCTAssertNotNil(returned)
        XCTAssertEqual(coordinator.liveAssessmentCount, 0)
        XCTAssertEqual(coordinator.refreshRequestCount, 0)
    }

    func testIdleRefreshKeepsTypingAndHotkeyContextCurrentAfterCacheAge() async throws {
        let checker = MutableContextChecker(assessment: editable(firstTarget))
        let coordinator = AccessibilityFocusedInputContextCoordinator(
            checker: checker,
            maximumAge: 0.02,
            refreshInterval: 0.005
        )
        coordinator.start()
        defer { coordinator.stop() }

        try await Task.sleep(for: .milliseconds(80))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)

        guard let character = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let firstCaps = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true),
              let hotkey = CGEvent(keyboardEventSource: nil, virtualKey: 57, keyDown: true) else {
            return XCTFail("Expected keyboard events")
        }
        let units = Array("g".utf16)
        units.withUnsafeBufferPointer { buffer in
            character.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress!)
        }
        firstCaps.flags = .maskAlternate
        hotkey.flags = .maskAlternate

        XCTAssertNotNil(monitor.handle(type: .keyDown, event: character))
        _ = monitor.handle(type: .keyDown, event: firstCaps)
        XCTAssertNil(monitor.handle(type: .keyDown, event: hotkey))
        XCTAssertGreaterThan(checker.assessmentCount, 1)
    }

    func testMouseDownAndMouseUpRequestOutOfBandSelectionRefreshWithoutLiveAX() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ) else {
            return XCTFail("Expected mouse events")
        }

        _ = monitor.handle(type: .leftMouseDown, event: down)
        _ = monitor.handle(type: .leftMouseUp, event: up)

        XCTAssertEqual(coordinator.refreshRequestCount, 2)
        XCTAssertEqual(coordinator.liveAssessmentCount, 0)
    }

    func testShiftArrowRequestsOutOfBandSelectionRefresh() throws {
        let coordinator = RecordingContextCoordinator(snapshot: CachedFocusedInputSnapshot(
            assessment: editable(firstTarget),
            revision: 1
        ))
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true) else {
            return XCTFail("Expected keyboard event")
        }
        event.flags = .maskShift

        _ = monitor.handle(type: .keyDown, event: event)

        XCTAssertEqual(coordinator.refreshRequestCount, 1)
        XCTAssertEqual(coordinator.liveAssessmentCount, 0)
    }

    func testMouseSelectionRefreshKeepsNonemptySelectionForShiftOptionSpace() async throws {
        let checker = MutableContextChecker(assessment: editable(firstTarget))
        let coordinator = AccessibilityFocusedInputContextCoordinator(
            checker: checker,
            maximumAge: 0.25,
            refreshInterval: 0.1
        )
        coordinator.start()
        defer { coordinator.stop() }
        let monitor = KeyboardMonitor(contextCoordinator: coordinator)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ) else {
            return XCTFail("Expected mouse events")
        }

        _ = monitor.handle(type: .leftMouseDown, event: down)
        checker.update(assessment: editable(firstTarget, location: 2, length: 4))
        _ = monitor.handle(type: .leftMouseUp, event: up)
        try await Task.sleep(for: .milliseconds(60))

        guard case let .editable(context)? = coordinator.cachedSnapshot()?.assessment else {
            return XCTFail("Expected refreshed editable selection")
        }
        XCTAssertEqual(context.selectionRange, TextSelectionRange(location: 2, length: 4))

        var processor = KeyboardEventProcessor()
        let result = processor.process(
            .keyDown(.space, modifiers: [.shift, .option]),
            input: .editable(context)
        )
        guard case let .command(request) = result.callbacks.first else {
            return XCTFail("Expected selection command")
        }
        XCTAssertEqual(request.context.selectionRange.length, 4)
    }

    func testSuppressesOnlyRecognizedHotkeysInKnownEditableContext() {
        var processor = KeyboardEventProcessor()

        let correction = doubleCapsCorrection(&processor, input: editable(firstTarget))
        XCTAssertTrue(correction.suppressesOriginalEvent)
        XCTAssertEqual(correction.callbacks.count, 1)

        let selection = processor.process(.keyDown(.space, modifiers: [.shift, .option]), input: editable(firstTarget))
        XCTAssertTrue(selection.suppressesOriginalEvent)
        XCTAssertEqual(selection.callbacks.count, 1)

        let unrelated = processor.process(.keyDown(.space, modifiers: [.command]), input: editable(firstTarget))
        XCTAssertFalse(unrelated.suppressesOriginalEvent)
        XCTAssertTrue(unrelated.callbacks.isEmpty)
    }

    func testProtectedAndUnknownContextsPassHotkeysThroughAndEraseBufferedText() {
        for unsafeContext in [FocusedInputAssessment.protected, .unsupported] {
            var processor = KeyboardEventProcessor()
            type("secret", into: &processor, target: firstTarget)

            let result = doubleCapsCorrection(&processor, input: unsafeContext)

            XCTAssertFalse(result.suppressesOriginalEvent)
            XCTAssertTrue(result.callbacks.isEmpty)
            XCTAssertNil(processor.latestWordSnapshot)
        }
    }

    func testReportsTerminatedWordWithEventTimeTargetAndGeneration() {
        var processor = KeyboardEventProcessor()
        type("ghbdtn", into: &processor, target: firstTarget)

        let result = processor.process(.keyDown(.space), input: editable(firstTarget, location: 6))
        guard case let .wordTerminated(request) = result.callbacks.first else {
            return XCTFail("Expected immutable word-termination request")
        }

        XCTAssertFalse(result.suppressesOriginalEvent)
        XCTAssertEqual(request.snapshot, WordSnapshot(text: "ghbdtn", trailingDelimiterCount: 1))
        XCTAssertEqual(request.context.target, firstTarget)
        XCTAssertTrue(processor.isCurrent(request.context))
    }

    func testDoubleCapsUsesEntireContinuousPhraseSnapshot() {
        var processor = KeyboardEventProcessor()
        type("руддщ", into: &processor, target: firstTarget)
        _ = processor.process(.keyDown(.space), input: editable(firstTarget, location: 5))
        type("цщкдв", into: &processor, target: firstTarget, startingAt: 6)

        let result = doubleCapsCorrection(&processor, input: editable(firstTarget, location: 11))
        guard case let .command(request) = result.callbacks.first else {
            return XCTFail("Expected phrase conversion command")
        }
        XCTAssertEqual(request.snapshot, WordSnapshot(text: "руддщ цщкдв", trailingDelimiterCount: 0))
    }

    func testRapidCommandsCarryIndependentImmutableSnapshots() {
        var processor = KeyboardEventProcessor()
        type("first", into: &processor, target: firstTarget)
        let first = doubleCapsCorrection(&processor, input: editable(firstTarget, location: 5))
        guard case let .command(firstRequest) = first.callbacks.first else {
            return XCTFail("Expected first command")
        }

        _ = processor.process(.keyDown(.space), input: editable(firstTarget, location: 5))
        type("second", into: &processor, target: firstTarget, startingAt: 6)
        let second = doubleCapsCorrection(&processor, input: editable(firstTarget, location: 12))
        guard case let .command(secondRequest) = second.callbacks.first else {
            return XCTFail("Expected second command")
        }

        XCTAssertEqual(firstRequest.snapshot?.text, "first")
        XCTAssertEqual(secondRequest.snapshot?.text, "second")
        XCTAssertNotEqual(firstRequest.context.generation, secondRequest.context.generation)
        XCTAssertFalse(processor.isCurrent(firstRequest.context))
        XCTAssertTrue(processor.isCurrent(secondRequest.context))
    }

    func testNewInputNavigationMouseAndTargetChangeInvalidatePendingRequest() {
        let invalidatingEvents: [(KeyboardEvent, FocusedInputAssessment)] = [
            (.keyDown(.character("x")), editable(firstTarget)),
            (.keyDown(.left), editable(firstTarget)),
            (.mouseDown, editable(firstTarget)),
            (.keyDown(.character("x")), editable(secondTarget))
        ]

        for (event, assessment) in invalidatingEvents {
            var processor = KeyboardEventProcessor()
            _ = processor.process(.keyDown(.character("a")), input: editable(firstTarget))
            let command = doubleCapsCorrection(&processor, input: editable(firstTarget, location: 1))
            guard case let .command(request) = command.callbacks.first else {
                return XCTFail("Expected command")
            }

            _ = processor.process(event, input: assessment)

            XCTAssertFalse(processor.isCurrent(request.context))
        }
    }

    func testEventArrivalInvalidatesPendingRequestBeforeContextLookup() {
        var processor = KeyboardEventProcessor()
        _ = processor.process(.keyDown(.character("a")), input: editable(firstTarget))
        let command = doubleCapsCorrection(&processor, input: editable(firstTarget, location: 1))
        guard case let .command(request) = command.callbacks.first else {
            return XCTFail("Expected command")
        }

        let incomingGeneration = processor.beginInputEvent()

        XCTAssertFalse(processor.isCurrent(request.context))
        let result = processor.process(
            .keyDown(.character("x")),
            input: editable(firstTarget, location: 1),
            generation: incomingGeneration
        )
        XCTAssertFalse(result.suppressesOriginalEvent)
    }

    func testSelectedRangeCannotBeUsedAsAStaleLastWordSnapshot() {
        var processor = KeyboardEventProcessor()
        type("word", into: &processor, target: firstTarget)
        let selected = FocusedInputAssessment.editable(FocusedInputContext(
            target: firstTarget,
            selectionRange: TextSelectionRange(location: 0, length: 4)
        ))

        let correction = doubleCapsCorrection(&processor, input: selected)
        guard case let .command(request) = correction.callbacks.first else {
            return XCTFail("Expected command")
        }

        XCTAssertNil(request.snapshot)
    }

    func testSelectionCommandKeepsItsNonemptyEventTimeSelection() {
        var processor = KeyboardEventProcessor()
        let selected = FocusedInputAssessment.editable(FocusedInputContext(
            target: firstTarget,
            selectionRange: TextSelectionRange(location: 3, length: 4)
        ))

        let conversion = processor.process(.keyDown(.space, modifiers: [.shift, .option]), input: selected)
        guard case let .command(request) = conversion.callbacks.first else {
            return XCTFail("Expected selection command")
        }

        XCTAssertTrue(conversion.suppressesOriginalEvent)
        XCTAssertEqual(request.context.selectionRange, TextSelectionRange(location: 3, length: 4))
    }

    func testRegisteredSelectionCommandBuildsRequestFromLiveContext() {
        var processor = KeyboardEventProcessor()
        let selected = editable(firstTarget, location: 3, length: 4)

        let result = processor.processRegisteredCommand(.convertSelection, input: selected)

        guard case let .command(request) = result.callbacks.first else {
            return XCTFail("Expected registered hotkey command")
        }
        XCTAssertEqual(request.command, .convertSelection)
        XCTAssertEqual(request.context.selectionRange, TextSelectionRange(location: 3, length: 4))
        XCTAssertTrue(processor.isCurrent(request.context))
    }

    func testUnexpectedCaretMoveErasesBufferedWordBeforeCommand() {
        var processor = KeyboardEventProcessor()
        type("word", into: &processor, target: firstTarget)

        let movedCaret = doubleCapsCorrection(&processor, input: editable(firstTarget, location: 1))
        guard case let .command(request) = movedCaret.callbacks.first else {
            return XCTFail("Expected command")
        }

        XCTAssertNil(request.snapshot)
    }

    private func type(
        _ text: String,
        into processor: inout KeyboardEventProcessor,
        target: InputTargetIdentity,
        startingAt start: Int = 0
    ) {
        for (offset, character) in text.enumerated() {
            _ = processor.process(
                .keyDown(.character(character)),
                input: editable(target, location: start + offset)
            )
        }
    }

    private func doubleCapsCorrection(
        _ processor: inout KeyboardEventProcessor,
        input: FocusedInputAssessment
    ) -> KeyboardEventProcessingResult {
        _ = processor.process(.keyDown(.capsLock), input: input)
        return processor.process(.keyDown(.capsLock), input: input)
    }

    private func editable(
        _ target: InputTargetIdentity,
        location: Int = 0,
        length: Int = 0
    ) -> FocusedInputAssessment {
        .editable(FocusedInputContext(
            target: target,
            selectionRange: TextSelectionRange(location: location, length: length)
        ))
    }
}

private final class CollidingElementToken: NSObject {
    let identifier: Int

    init(identifier: Int) {
        self.identifier = identifier
    }

    override var hash: Int { 42 }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? CollidingElementToken)?.identifier == identifier
    }
}

private final class RecordingContextCoordinator: FocusedInputContextCoordinating, @unchecked Sendable {
    var snapshot: CachedFocusedInputSnapshot?
    var liveAssessment: FocusedInputAssessment = .unsupported
    private(set) var cachedSnapshotCount = 0
    private(set) var liveAssessmentCount = 0
    private(set) var refreshRequestCount = 0
    var refuseCaretAdvances = false

    init(snapshot: CachedFocusedInputSnapshot?) {
        self.snapshot = snapshot
    }

    func start() { }
    func attach(to runLoop: CFRunLoop) { }
    func stop() { }

    func cachedSnapshot() -> CachedFocusedInputSnapshot? {
        cachedSnapshotCount += 1
        return snapshot
    }

    func updateCachedContext(_ context: FocusedInputContext, revision: UInt64) {
        snapshot = CachedFocusedInputSnapshot(assessment: .editable(context), revision: revision)
    }

    func invalidateAndRefresh(after delay: TimeInterval) {
        snapshot = nil
        refreshRequestCount += 1
    }

    func advanceCachedSelection(for target: InputTargetIdentity, from range: TextSelectionRange, to newRange: TextSelectionRange) -> Bool {
        guard !refuseCaretAdvances,
              case let .editable(context)? = snapshot?.assessment,
              context.target == target,
              context.selectionRange == range else { return false }
        snapshot = CachedFocusedInputSnapshot(
            assessment: .editable(FocusedInputContext(target: target, selectionRange: newRange)),
            revision: snapshot?.revision ?? 0,
            capturedAt: snapshot?.capturedAt ?? 0
        )
        return true
    }

    func currentAssessment() -> FocusedInputAssessment {
        liveAssessmentCount += 1
        return liveAssessment
    }
}

private final class MutableContextChecker: FocusedInputContextChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var current: FocusedInputAssessment
    private(set) var assessmentCount = 0

    init(assessment: FocusedInputAssessment) {
        current = assessment
    }

    func update(assessment: FocusedInputAssessment) {
        lock.lock()
        current = assessment
        lock.unlock()
    }

    func currentAssessment() -> FocusedInputAssessment {
        lock.lock()
        defer { lock.unlock() }
        assessmentCount += 1
        return current
    }
}
