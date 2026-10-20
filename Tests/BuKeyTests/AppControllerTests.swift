import XCTest
@testable import BuKey

@MainActor
final class AppControllerTests: XCTestCase {
    private let target = InputTargetIdentity(processID: 10, retainedElement: "controller-target" as CFString)

    func testAutomaticCorrectionDefaultsOffAndPersistsChanges() {
        let defaults = isolatedDefaults()
        let first = makeController(defaults: defaults)
        XCTAssertFalse(first.state.automaticCorrectionEnabled)

        first.setAutomaticCorrectionEnabled(true)

        let second = makeController(defaults: defaults)
        XCTAssertTrue(second.state.automaticCorrectionEnabled)
    }

    func testMissingPermissionMessageNamesOnlyMissingPermissions() {
        let cases: [(PermissionStatus, String)] = [
            (PermissionStatus(accessibility: false, inputMonitoring: true), "Нужно разрешение Accessibility."),
            (PermissionStatus(accessibility: true, inputMonitoring: false), "Нужно разрешение Input Monitoring."),
            (PermissionStatus(accessibility: false, inputMonitoring: false), "Нужны разрешения Accessibility и Input Monitoring.")
        ]

        for (status, expectedMessage) in cases {
            let monitor = FakeMonitor(isRunning: true)
            let controller = makeController(permissions: FakePermissions(status: status), monitor: monitor)

            controller.start()

            XCTAssertFalse(monitor.isRunning)
            XCTAssertEqual(controller.state.monitoringStatus, .stopped)
            XCTAssertEqual(controller.state.readiness, .permissionRequired)
            XCTAssertEqual(controller.state.statusMessage, expectedMessage)
        }
    }

    func testReadyPermissionsStartMonitorOnlyOnceAcrossRefreshes() {
        let monitor = FakeMonitor()
        let controller = makeController(monitor: monitor)

        controller.start()
        controller.applicationDidBecomeActive()

        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(monitor.startCount, 1)
        XCTAssertEqual(controller.state.monitoringStatus, .running)
        XCTAssertEqual(controller.state.readiness, .ready)
        XCTAssertNil(controller.state.statusMessage)
    }

    func testThrownMonitorStartCannotReportReady() {
        let monitor = FakeMonitor(startError: .eventTapCreationFailed)
        let controller = makeController(monitor: monitor)

        controller.start()

        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(controller.state.monitoringStatus, .failed)
        XCTAssertEqual(controller.state.readiness, .monitorUnavailable)
        XCTAssertEqual(controller.state.statusMessage, "Не удалось запустить отслеживание клавиатуры.")
    }

    func testAutomaticCorrectionUsesDetectorOnlyWhenEnabled() async {
        let monitor = FakeMonitor()
        let replacer = FakeReplacer()
        let detector = FakeDetector(candidate: "привет")
        let controller = makeController(monitor: monitor, detector: detector, replacer: replacer)
        controller.start()
        let request = wordRequest("ghbdtn", generation: 1)

        monitor.send(.wordTerminated(request))
        XCTAssertTrue(replacer.replacements.isEmpty)

        controller.setAutomaticCorrectionEnabled(true)
        monitor.send(.wordTerminated(request))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(replacer.replacements, [RecordedReplacement(text: "ghbdtn", replacement: "привет", target: target)])
    }

    func testAutomaticCorrectionRunsAfterTerminatingSpaceTurn() async {
        let monitor = FakeMonitor()
        let replacer = FakeReplacer()
        let controller = makeController(
            monitor: monitor,
            detector: FakeDetector(candidate: "привет"),
            replacer: replacer
        )
        controller.start()
        controller.setAutomaticCorrectionEnabled(true)

        monitor.send(.wordTerminated(wordRequest("ghbdtn", generation: 1)))
        XCTAssertTrue(replacer.replacements.isEmpty)

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(replacer.replacements.count, 1)
    }

    func testLastWordWithoutSnapshotShowsNonBlockingStatus() {
        let monitor = FakeMonitor()
        let controller = makeController(monitor: monitor)
        controller.start()

        monitor.send(.command(KeyboardCommandRequest(
            command: .correctLastWord,
            snapshot: nil,
            context: inputContext(generation: 1)
        )))

        XCTAssertEqual(controller.state.statusMessage, "Нет текста для исправления.")
    }

    func testLastWordWithoutConvertibleDominantLayoutShowsNonBlockingStatus() {
        let monitor = FakeMonitor()
        let controller = makeController(monitor: monitor)
        controller.start()

        monitor.send(.command(KeyboardCommandRequest(
            command: .correctLastWord,
            snapshot: WordSnapshot(text: "123", trailingDelimiterCount: 0),
            context: inputContext(generation: 1)
        )))

        XCTAssertEqual(controller.state.statusMessage, "Не удалось определить раскладку.")
        XCTAssertFalse(controller.state.statusMessage?.contains("123") == true)
    }

    func testManualCommandsUseTheirOwnImmutableSnapshotAndTarget() {
        let monitor = FakeMonitor()
        let replacer = FakeReplacer(selection: "ghbdtn, vbh")
        let layoutSwitcher = FakeLayoutSwitcher()
        let controller = makeController(monitor: monitor, replacer: replacer, layoutSwitcher: layoutSwitcher)
        controller.start()
        let context = inputContext(generation: 2)

        monitor.send(.command(KeyboardCommandRequest(command: .correctLastWord, snapshot: WordSnapshot(text: "руддщ", trailingDelimiterCount: 0), context: context)))
        monitor.send(.command(KeyboardCommandRequest(command: .convertSelection, snapshot: nil, context: context)))

        XCTAssertEqual(replacer.replacements, [RecordedReplacement(text: "руддщ", replacement: "hello", target: target)])
        XCTAssertEqual(replacer.convertedSelection, "приветб мир")
        XCTAssertEqual(layoutSwitcher.selections, [.english, .russian])
        XCTAssertEqual(monitor.validations, [.exactSelection, .targetOnly])
        XCTAssertEqual(controller.state.statusMessage, "Выделение преобразовано.")
    }

    func testDirectCorrectionConvertsWithoutAccessibilityContextAndSwitchesLayout() {
        let monitor = FakeMonitor()
        let replacer = FakeReplacer()
        let layoutSwitcher = FakeLayoutSwitcher()
        let controller = makeController(monitor: monitor, replacer: replacer, layoutSwitcher: layoutSwitcher)
        controller.start()

        monitor.send(.directCorrection(DirectCorrectionRequest(
            snapshot: WordSnapshot(text: "ghbdtn", trailingDelimiterCount: 0),
            generation: 7
        )))

        XCTAssertEqual(replacer.directReplacements, [RecordedDirectReplacement(text: "ghbdtn", replacement: "привет")])
        XCTAssertEqual(layoutSwitcher.selections, [.russian])
    }

    func testStaleGenerationNeverReachesReplacer() async {
        let monitor = FakeMonitor(acceptsContext: false)
        let replacer = FakeReplacer()
        let controller = makeController(monitor: monitor, detector: FakeDetector(candidate: "привет"), replacer: replacer)
        controller.setAutomaticCorrectionEnabled(true)
        controller.start()

        monitor.send(.wordTerminated(wordRequest("ghbdtn", generation: 1)))
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(replacer.replacements.isEmpty)
        XCTAssertEqual(controller.state.statusMessage, "Контекст ввода изменился.")
    }

    func testReplacementErrorsProduceSpecificTextFreeMessages() {
        let cases: [(TextReplacementError, String)] = [
            (.noSelection, "Нет выделенного текста."),
            (.protectedField, "Защищённое поле недоступно."),
            (.unsupportedControl, "Это поле не поддерживает замену."),
            (.eventCreationFailed, "Не удалось заменить текст.")
        ]

        for (error, message) in cases {
            let monitor = FakeMonitor()
            let replacer = FakeReplacer(error: error)
            let controller = makeController(monitor: monitor, replacer: replacer)
            controller.start()
            let context = inputContext(generation: 1)

            monitor.send(.command(KeyboardCommandRequest(command: .convertSelection, snapshot: nil, context: context)))

            XCTAssertEqual(controller.state.statusMessage, message)
            XCTAssertFalse(message.contains("ghbdtn"))
        }
    }

    private func wordRequest(_ text: String, generation: UInt64) -> WordTerminationRequest {
        WordTerminationRequest(
            snapshot: WordSnapshot(text: text, trailingDelimiterCount: 1),
            context: inputContext(generation: generation)
        )
    }

    private func inputContext(generation: UInt64) -> InputEventContext {
        InputEventContext(
            target: target,
            generation: generation,
            selectionRange: TextSelectionRange(location: 6, length: 0)
        )
    }

    private func makeController(
        permissions: FakePermissions = FakePermissions(),
        monitor: FakeMonitor = FakeMonitor(),
        detector: FakeDetector = FakeDetector(candidate: nil),
        replacer: FakeReplacer = FakeReplacer(),
        layoutSwitcher: FakeLayoutSwitcher = FakeLayoutSwitcher(),
        defaults: UserDefaults? = nil
    ) -> AppController {
        AppController(
            permissionChecker: permissions,
            monitor: monitor,
            detector: detector,
            replacer: replacer,
            layoutSwitcher: layoutSwitcher,
            defaults: defaults ?? isolatedDefaults()
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AppControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

@MainActor
private final class FakeLayoutSwitcher: KeyboardLayoutSwitching {
    private(set) var selections: [KeyboardLayout] = []

    func select(_ layout: KeyboardLayout) -> Bool {
        selections.append(layout)
        return true
    }
}

@MainActor
private final class FakePermissions: PermissionChecking {
    var status: PermissionStatus

    init(status: PermissionStatus = PermissionStatus(accessibility: true, inputMonitoring: true)) {
        self.status = status
    }

    func currentStatus() -> PermissionStatus { status }
    func requestAccessibility() { }
    func requestInputMonitoring() { }
    func openAccessibilitySettings() { }
    func openInputMonitoringSettings() { }
}

private final class FakeMonitor: EventMonitoring {
    var isRunning: Bool
    let acceptsContext: Bool
    let startError: KeyboardMonitorError?
    private var handler: (@MainActor @Sendable (KeyboardMonitorEvent) -> Void)?
    private(set) var startCount = 0
    private(set) var validations: [InputContextValidation] = []

    init(isRunning: Bool = false, acceptsContext: Bool = true, startError: KeyboardMonitorError? = nil) {
        self.isRunning = isRunning
        self.acceptsContext = acceptsContext
        self.startError = startError
    }

    func start(handler: @escaping @MainActor @Sendable (KeyboardMonitorEvent) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
        self.handler = handler
    }

    func stop() {
        isRunning = false
        handler = nil
    }

    @MainActor
    func performIfCurrent(_ context: InputEventContext, validation: InputContextValidation, operation: () throws -> Void) rethrows -> Bool {
        validations.append(validation)
        guard acceptsContext else { return false }
        try operation()
        return true
    }

    @MainActor
    func performIfDirectCommandCurrent(generation: UInt64, operation: () throws -> Void) rethrows -> Bool {
        guard acceptsContext else { return false }
        try operation()
        return true
    }

    @MainActor
    func send(_ event: KeyboardMonitorEvent) {
        handler?(event)
    }
}

private struct FakeDetector: LanguageDetecting {
    let candidate: String?

    func correction(for token: String) -> String? { candidate }
}

private struct RecordedReplacement: Equatable {
    let text: String
    let replacement: String
    let target: InputTargetIdentity
}

private struct RecordedDirectReplacement: Equatable {
    let text: String
    let replacement: String
}

@MainActor
private final class FakeReplacer: TextReplacing {
    let selection: String
    let error: TextReplacementError?
    private(set) var replacements: [RecordedReplacement] = []
    private(set) var convertedSelection: String?
    private(set) var directReplacements: [RecordedDirectReplacement] = []

    init(selection: String = "", error: TextReplacementError? = nil) {
        self.selection = selection
        self.error = error
    }

    func replaceLastWord(snapshot: WordSnapshot, with replacement: String, context: InputEventContext) throws {
        if let error { throw error }
        replacements.append(RecordedReplacement(text: snapshot.text, replacement: replacement, target: context.target))
    }

    func replaceRecentlyTyped(snapshot: WordSnapshot, with replacement: String) throws {
        if let error { throw error }
        directReplacements.append(RecordedDirectReplacement(text: snapshot.text, replacement: replacement))
    }

    func convertSelection(context: InputEventContext, using converter: (String) -> String) throws {
        if let error { throw error }
        convertedSelection = converter(selection)
    }
}
