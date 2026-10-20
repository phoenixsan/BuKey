import Carbon
import CoreGraphics
import Foundation

enum KeyboardDiagnosticLog {
    static let url = URL(fileURLWithPath: "/private/tmp/buSwitcher-keyboard.log")

    static func write(_ message: String) {
        // Intentionally disabled outside a focused diagnostic build. Logging
        // every accessibility poll can otherwise grow this file very quickly.
    }
}

struct InputEventContext: Equatable, Sendable {
    let target: InputTargetIdentity
    let generation: UInt64
    let selectionRange: TextSelectionRange
}

struct KeyboardCommandRequest: Equatable, Sendable {
    let command: HotkeyCommand
    let snapshot: WordSnapshot?
    let context: InputEventContext
}

struct WordTerminationRequest: Equatable, Sendable {
    let snapshot: WordSnapshot
    let context: InputEventContext
}

struct DirectCorrectionRequest: Equatable, Sendable {
    let snapshot: WordSnapshot
    let generation: UInt64
}

struct DirectTypingProcessingResult: Equatable, Sendable {
    let request: DirectCorrectionRequest?
    let recognizedDoubleCaps: Bool
}

enum KeyboardMonitorEvent: Equatable, Sendable {
    case command(KeyboardCommandRequest)
    case directCorrection(DirectCorrectionRequest)
    case wordTerminated(WordTerminationRequest)
    case diagnostic(String)
}

struct DirectTypingProcessor {
    private var buffer = WordBuffer()
    private var hotkeys = HotkeyManager()
    private(set) var generation: UInt64 = 0

    mutating func process(
        _ event: KeyboardEvent,
        secureInputEnabled: Bool,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> DirectTypingProcessingResult {
        generation &+= 1
        guard !secureInputEnabled else {
            invalidateBuffer()
            return DirectTypingProcessingResult(request: nil, recognizedDoubleCaps: false)
        }

        if hotkeys.command(for: event, now: now) == .correctLastWord {
            defer { _ = buffer.consume(.focusChanged) }
            let request = buffer.recentTextSnapshot.map {
                DirectCorrectionRequest(snapshot: $0, generation: generation)
            }
            return DirectTypingProcessingResult(request: request, recognizedDoubleCaps: true)
        }

        _ = buffer.consume(event)
        return DirectTypingProcessingResult(request: nil, recognizedDoubleCaps: false)
    }

    mutating func invalidate() {
        generation &+= 1
        invalidateBuffer()
    }

    func isCurrent(generation expected: UInt64) -> Bool {
        generation == expected
    }

    private mutating func invalidateBuffer() {
        _ = buffer.consume(.focusChanged)
        hotkeys.reset()
    }
}

enum KeyboardMonitorError: Error, Equatable {
    case eventTapCreationFailed
    // Retained for the legacy diagnostic registration code, which is no longer started.
    case hotkeyRegistrationFailed
}

enum InputContextValidation: Equatable, Sendable {
    case exactSelection
    case targetOnly
}

struct KeyboardEventProcessingResult: Equatable {
    let callbacks: [KeyboardMonitorEvent]
    let suppressesOriginalEvent: Bool
    let nextSelectionRange: TextSelectionRange?
    let invalidatesContext: Bool
}

struct KeyboardEventProcessor {
    private var buffer = WordBuffer()
    private var hotkeys = HotkeyManager()
    private var generation: UInt64 = 0
    private var target: InputTargetIdentity?
    private var expectedSelectionRange: TextSelectionRange?

    var latestWordSnapshot: WordSnapshot? {
        buffer.currentWord ?? buffer.previousWord
    }

    mutating func process(_ event: KeyboardEvent, input: FocusedInputAssessment) -> KeyboardEventProcessingResult {
        let generation = beginInputEvent()
        return process(event, input: input, generation: generation, now: ProcessInfo.processInfo.systemUptime)
    }

    mutating func beginInputEvent() -> UInt64 {
        advanceGeneration()
        return generation
    }

    mutating func process(
        _ event: KeyboardEvent,
        input: FocusedInputAssessment,
        generation eventGeneration: UInt64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> KeyboardEventProcessingResult {
        guard generation == eventGeneration else {
            resetBufferAndTarget()
            return KeyboardEventProcessingResult(callbacks: [], suppressesOriginalEvent: false, nextSelectionRange: nil, invalidatesContext: true)
        }
        guard case let .editable(context) = input else {
            resetBufferAndTarget()
            return KeyboardEventProcessingResult(callbacks: [], suppressesOriginalEvent: false, nextSelectionRange: nil, invalidatesContext: true)
        }

        let hadUnexpectedContext = (target != nil && target != context.target) || expectedSelectionRange.map({ $0 != context.selectionRange }) == true
        if hadUnexpectedContext {
            resetBufferAndTarget()
            target = context.target
            expectedSelectionRange = context.selectionRange
        }
        if target == nil { target = context.target }

        if let command = hotkeys.command(for: event, now: now) {
            if context.selectionRange.length > 0 {
                _ = buffer.consume(.focusChanged)
            }
            expectedSelectionRange = context.selectionRange
            let eventContext = InputEventContext(
                target: context.target,
                generation: generation,
                selectionRange: context.selectionRange
            )
            let request = KeyboardCommandRequest(
                command: command,
                snapshot: command == .correctLastWord ? buffer.recentTextSnapshot : nil,
                context: eventContext
            )
            if command == .correctLastWord { _ = buffer.consume(.focusChanged) }
            return KeyboardEventProcessingResult(callbacks: [.command(request)], suppressesOriginalEvent: true, nextSelectionRange: nil, invalidatesContext: hadUnexpectedContext)
        }

        if hadUnexpectedContext {
            resetBufferAndTarget()
            return KeyboardEventProcessingResult(callbacks: [], suppressesOriginalEvent: false, nextSelectionRange: nil, invalidatesContext: true)
        }

        let callbacks: [KeyboardMonitorEvent]
        if context.selectionRange.length > 0 {
            _ = buffer.consume(.focusChanged)
        }
        let resultingSelectionRange = Self.selectionRange(after: event, from: context.selectionRange)
        if case let .wordTerminated(snapshot) = buffer.consume(event) {
            guard let resultingSelectionRange else {
                resetBufferAndTarget()
                return KeyboardEventProcessingResult(callbacks: [], suppressesOriginalEvent: false, nextSelectionRange: nil, invalidatesContext: true)
            }
            let eventContext = InputEventContext(
                target: context.target,
                generation: generation,
                selectionRange: resultingSelectionRange
            )
            callbacks = [.wordTerminated(WordTerminationRequest(snapshot: snapshot, context: eventContext))]
        } else {
            callbacks = []
        }
        expectedSelectionRange = resultingSelectionRange
        return KeyboardEventProcessingResult(callbacks: callbacks, suppressesOriginalEvent: false, nextSelectionRange: resultingSelectionRange, invalidatesContext: false)
    }

    mutating func processRegisteredCommand(
        _ command: HotkeyCommand,
        input: FocusedInputAssessment
    ) -> KeyboardEventProcessingResult {
        let eventGeneration = beginInputEvent()
        guard case let .editable(context) = input else {
            resetBufferAndTarget()
            return KeyboardEventProcessingResult(callbacks: [], suppressesOriginalEvent: false, nextSelectionRange: nil, invalidatesContext: true)
        }

        if target != nil && target != context.target { resetBufferAndTarget() }
        if target == nil { target = context.target }
        if context.selectionRange.length > 0 { _ = buffer.consume(.focusChanged) }
        expectedSelectionRange = context.selectionRange
        let eventContext = InputEventContext(
            target: context.target,
            generation: eventGeneration,
            selectionRange: context.selectionRange
        )
        let request = KeyboardCommandRequest(
            command: command,
            snapshot: command == .correctLastWord ? buffer.recentTextSnapshot : nil,
            context: eventContext
        )
        return KeyboardEventProcessingResult(
            callbacks: [.command(request)],
            suppressesOriginalEvent: false,
            nextSelectionRange: nil,
            invalidatesContext: false
        )
    }

    func isCurrent(_ context: InputEventContext) -> Bool {
        generation == context.generation && target == context.target
    }

    mutating func invalidate() {
        advanceGeneration()
        resetBufferAndTarget()
    }

    mutating func rejectInputEvent(generation eventGeneration: UInt64) {
        guard generation == eventGeneration else { return }
        resetBufferAndTarget()
    }

    private mutating func advanceGeneration() {
        generation &+= 1
    }

    private mutating func resetBufferAndTarget() {
        _ = buffer.consume(.focusChanged)
        target = nil
        expectedSelectionRange = nil
    }

    private static func selectionRange(after event: KeyboardEvent, from range: TextSelectionRange) -> TextSelectionRange? {
        switch event {
        case let .keyDown(.character(character), modifiers) where modifiers.isEmpty:
            return TextSelectionRange(location: range.location + String(character).utf16.count, length: 0)
        case let .keyDown(.space, modifiers) where modifiers.isEmpty:
            return TextSelectionRange(location: range.location + 1, length: 0)
        case let .keyDown(.backspace, modifiers) where modifiers.isEmpty:
            let location = range.length > 0 ? range.location : max(range.location - 1, 0)
            return TextSelectionRange(location: location, length: 0)
        default:
            return nil
        }
    }
}

protocol EventMonitoring: AnyObject {
    var isRunning: Bool { get }
    func start(handler: @escaping @MainActor @Sendable (KeyboardMonitorEvent) -> Void) throws
    func stop()
    @MainActor
    func performIfCurrent(_ context: InputEventContext, validation: InputContextValidation, operation: () throws -> Void) rethrows -> Bool
    @MainActor
    func performIfDirectCommandCurrent(generation: UInt64, operation: () throws -> Void) rethrows -> Bool
}

final class KeyboardMonitor: EventMonitoring, @unchecked Sendable {
    private static let outOfBandRefreshDelay: TimeInterval = 0.02
    private let condition = NSCondition()
    private let contextCoordinator: any FocusedInputContextCoordinating
    private var processor = KeyboardEventProcessor()
    private var directTypingProcessor = DirectTypingProcessor()
    private var handler: (@MainActor @Sendable (KeyboardMonitorEvent) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventLoop: CFRunLoop?
    private var globalHotkeyHandler: EventHandlerRef?
    private var globalHotkeys: [EventHotKeyRef] = []
    private var running = false

    init(contextCoordinator: any FocusedInputContextCoordinating = AccessibilityFocusedInputContextCoordinator()) {
        self.contextCoordinator = contextCoordinator
    }

    var isRunning: Bool {
        condition.withLock { running }
    }

    func start(handler: @escaping @MainActor @Sendable (KeyboardMonitorEvent) -> Void) throws {
        condition.lock()
        defer { condition.unlock() }
        guard !running else { return }

        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw KeyboardMonitorError.eventTapCreationFailed
        }

        self.handler = handler
        eventTap = tap
        runLoopSource = source
        processor = KeyboardEventProcessor()
        directTypingProcessor = DirectTypingProcessor()
        running = true
        contextCoordinator.start()

        let thread = Thread { [weak self] in self?.runEventLoop() }
        thread.name = "BuKey.KeyboardMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()

        while running && eventLoop == nil {
            condition.wait()
        }
    }

    func stop() {
        condition.lock()
        let tap = eventTap
        let loop = eventLoop
        running = false
        handler = nil
        eventTap = nil
        runLoopSource = nil
        processor.invalidate()
        directTypingProcessor.invalidate()
        condition.broadcast()
        condition.unlock()

        contextCoordinator.stop()

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    @MainActor
    func performIfCurrent(_ context: InputEventContext, validation: InputContextValidation, operation: () throws -> Void) rethrows -> Bool {
        condition.lock()
        guard running, processor.isCurrent(context) else {
            condition.unlock()
            return false
        }
        guard case let .editable(current) = contextCoordinator.currentAssessment(),
              current.target == context.target,
              validation == .targetOnly || current.selectionRange == context.selectionRange else {
            processor.invalidate()
            condition.unlock()
            return false
        }

        defer {
            processor.invalidate()
            condition.unlock()
        }
        try operation()
        return true
    }

    @MainActor
    func performIfDirectCommandCurrent(generation: UInt64, operation: () throws -> Void) rethrows -> Bool {
        condition.lock()
        guard running, directTypingProcessor.isCurrent(generation: generation) else {
            condition.unlock()
            return false
        }
        defer {
            directTypingProcessor.invalidate()
            condition.unlock()
        }
        try operation()
        return true
    }

    deinit {
        stop()
    }

    private func runEventLoop() {
        condition.lock()
        guard running, let source = runLoopSource, let tap = eventTap else {
            condition.broadcast()
            condition.unlock()
            return
        }
        guard let loop = CFRunLoopGetCurrent() else {
            condition.broadcast()
            condition.unlock()
            return
        }
        eventLoop = loop
        condition.broadcast()
        condition.unlock()

        contextCoordinator.attach(to: loop)

        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
        CFRunLoopRemoveSource(loop, source, .commonModes)

        condition.withLock {
            if eventLoop === loop { eventLoop = nil }
        }
    }

    private func registerGlobalHotkeys() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                KeyboardDiagnosticLog.write("carbon callback entered")
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                var actualSize = 0
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    &actualSize,
                    &hotkeyID
                )
                guard readStatus == noErr else { return readStatus }
                KeyboardDiagnosticLog.write("carbon callback id=\(hotkeyID.id)")
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userData).takeUnretainedValue()
                monitor.handleGlobalHotkey(id: hotkeyID.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard status == noErr, let installedHandler else {
            KeyboardDiagnosticLog.write("handler registration failed status=\(status)")
            throw KeyboardMonitorError.hotkeyRegistrationFailed
        }
        KeyboardDiagnosticLog.write("handler registration succeeded")

        let signature: OSType = 0x62755357 // "buSW"
        let definitions: [(id: UInt32, modifiers: UInt32)] = [
            (1, UInt32(controlKey | optionKey)),
            (2, UInt32(shiftKey | controlKey | optionKey))
        ]
        var registered: [EventHotKeyRef] = []
        for definition in definitions {
            var hotkey: EventHotKeyRef?
            let registerStatus = RegisterEventHotKey(
                UInt32(kVK_ANSI_K),
                definition.modifiers,
                EventHotKeyID(signature: signature, id: definition.id),
                GetApplicationEventTarget(),
                0,
                &hotkey
            )
            guard registerStatus == noErr, let hotkey else {
                KeyboardDiagnosticLog.write("hotkey id=\(definition.id) failed status=\(registerStatus)")
                for existing in registered { UnregisterEventHotKey(existing) }
                RemoveEventHandler(installedHandler)
                throw KeyboardMonitorError.hotkeyRegistrationFailed
            }
            KeyboardDiagnosticLog.write("hotkey id=\(definition.id) registered")
            registered.append(hotkey)
        }
        globalHotkeyHandler = installedHandler
        globalHotkeys = registered
    }

    private func handleGlobalHotkey(id: UInt32) {
        KeyboardDiagnosticLog.write("handleGlobalHotkey id=\(id)")
        let command: HotkeyCommand
        switch id {
        case 1:
            command = .correctLastWord
        case 2:
            command = .convertSelection
        default:
            return
        }

        let assessment = contextCoordinator.currentAssessment()
        guard case .editable = assessment else {
            KeyboardDiagnosticLog.write("hotkey id=\(id) active field unavailable")
            dispatch(.diagnostic("Горячая клавиша получена, но активное поле недоступно."))
            return
        }
        let result = condition.withLock { () -> KeyboardEventProcessingResult in
            processor.processRegisteredCommand(command, input: assessment)
        }
        guard let callback = result.callbacks.first else {
            KeyboardDiagnosticLog.write("hotkey id=\(id) command not prepared")
            dispatch(.diagnostic("Горячая клавиша получена, но команда не подготовлена."))
            return
        }
        KeyboardDiagnosticLog.write("hotkey id=\(id) command dispatched")
        dispatch(callback)
    }

    private func dispatch(_ event: KeyboardMonitorEvent) {
        guard let handler = condition.withLock({ handler }) else { return }
        Task { @MainActor in handler(event) }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let tap = condition.withLock {
                processor.invalidate()
                return eventTap
            }
            contextCoordinator.invalidateAndRefresh(after: 0)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEventMarker.value else {
            return Unmanaged.passUnretained(event)
        }

        let normalized = Self.keyboardEvent(from: event, type: type)
        guard let normalized else {
            // Ordinary modifier transitions do not change the focused text or
            // caret. Invalidating here races the command dispatched by the
            // preceding keyDown when the user releases its modifiers.
            if type == .flagsChanged { return Unmanaged.passUnretained(event) }
            condition.withLock { processor.invalidate() }
            contextCoordinator.invalidateAndRefresh(after: Self.outOfBandRefreshDelay)
            return Unmanaged.passUnretained(event)
        }


        if case .keyDown(.capsLock, modifiers: _) = normalized {
            let protectedByAccessibility: Bool
            if case .protected? = contextCoordinator.cachedSnapshot()?.assessment {
                protectedByAccessibility = true
            } else {
                protectedByAccessibility = false
            }
            let directResult = condition.withLock {
                directTypingProcessor.process(
                    normalized,
                    secureInputEnabled: IsSecureEventInputEnabled() || protectedByAccessibility
                )
            }
            if let request = directResult.request {
                dispatch(.directCorrection(request))
            } else if directResult.recognizedDoubleCaps {
                dispatch(.diagnostic("Нет текста для исправления."))
            }
            return directResult.recognizedDoubleCaps ? nil : Unmanaged.passUnretained(event)
        }

        if Self.isRegisteredHotkeyKeystroke(normalized) {
            KeyboardDiagnosticLog.write("event tap saw reserved K keystroke")
            return Unmanaged.passUnretained(event)
        }
        guard Self.isModelable(normalized) else {
            condition.withLock {
                processor.invalidate()
                directTypingProcessor.invalidate()
            }
            contextCoordinator.invalidateAndRefresh(after: Self.outOfBandRefreshDelay)
            return Unmanaged.passUnretained(event)
        }


        let protectedByAccessibility: Bool
        if case .protected? = contextCoordinator.cachedSnapshot()?.assessment {
            protectedByAccessibility = true
        } else {
            protectedByAccessibility = false
        }
        condition.withLock {
            _ = directTypingProcessor.process(
                normalized,
                secureInputEnabled: IsSecureEventInputEnabled() || protectedByAccessibility
            )
        }

        let eventGeneration = condition.withLock { processor.beginInputEvent() }
        let assessment: FocusedInputAssessment
        if let cached = contextCoordinator.cachedSnapshot(), case .editable = cached.assessment {
            assessment = cached.assessment
        } else if Self.isHotkeyCandidate(normalized) {
            let live = contextCoordinator.currentAssessment()
            guard case .editable = live else {
                condition.withLock { processor.rejectInputEvent(generation: eventGeneration) }
                contextCoordinator.invalidateAndRefresh(after: 0)
                return Unmanaged.passUnretained(event)
            }
            assessment = live
        } else {
            condition.withLock { processor.rejectInputEvent(generation: eventGeneration) }
            contextCoordinator.invalidateAndRefresh(after: 0)
            return Unmanaged.passUnretained(event)
        }
        let resultAndHandler = condition.withLock { () -> (KeyboardEventProcessingResult, (@MainActor @Sendable (KeyboardMonitorEvent) -> Void)?) in
            (processor.process(normalized, input: assessment, generation: eventGeneration), handler)
        }
        var result = resultAndHandler.0
        if result.invalidatesContext {
            condition.withLock { processor.invalidate() }
            contextCoordinator.invalidateAndRefresh(after: Self.outOfBandRefreshDelay)
            return Unmanaged.passUnretained(event)
        }
        if let nextRange = result.nextSelectionRange,
           case let .editable(context) = assessment,
           !contextCoordinator.advanceCachedSelection(for: context.target, from: context.selectionRange, to: nextRange) {
            condition.withLock { processor.invalidate() }
            contextCoordinator.invalidateAndRefresh(after: Self.outOfBandRefreshDelay)
            result = KeyboardEventProcessingResult(callbacks: [], suppressesOriginalEvent: false, nextSelectionRange: nil, invalidatesContext: true)
        }
        if let handler = resultAndHandler.1 {
            for callback in result.callbacks {
                Task { @MainActor in handler(callback) }
            }
        }
        return result.suppressesOriginalEvent ? nil : Unmanaged.passUnretained(event)
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        .flagsChanged,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .leftMouseUp,
        .rightMouseUp,
        .otherMouseUp
    ].reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }

    private static func keyboardEvent(from event: CGEvent, type: CGEventType) -> KeyboardEvent? {
        if type == .flagsChanged {
            let modifiers = keyboardModifiers(from: event.flags)
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 57 || modifiers == [.shift, .option, .command, .control] {
                return .keyDown(.capsLock, modifiers: modifiers)
            }
            return nil
        }
        guard type == .keyDown else {
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { return .mouseDown }
            if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) { return .mouseUp }
            return nil
        }

        let modifiers = keyboardModifiers(from: event.flags)
        switch CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) {
        case 57: return .keyDown(.capsLock, modifiers: modifiers)
        case 40: return .keyDown(.diagnosticK, modifiers: modifiers)
        case 49: return .keyDown(.space, modifiers: modifiers)
        case 51: return .keyDown(.backspace, modifiers: modifiers)
        case 117: return .keyDown(.deleteForward, modifiers: modifiers)
        case 36, 76: return .keyDown(.returnKey, modifiers: modifiers)
        case 48: return .keyDown(.tab, modifiers: modifiers)
        case 53: return .keyDown(.escape, modifiers: modifiers)
        case 123: return .keyDown(.left, modifiers: modifiers)
        case 124: return .keyDown(.right, modifiers: modifiers)
        case 125: return .keyDown(.down, modifiers: modifiers)
        case 126: return .keyDown(.up, modifiers: modifiers)
        case 115: return .keyDown(.home, modifiers: modifiers)
        case 119: return .keyDown(.end, modifiers: modifiers)
        case 116: return .keyDown(.pageUp, modifiers: modifiers)
        case 121: return .keyDown(.pageDown, modifiers: modifiers)
        default:
            var actualLength = 0
            var characters = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(
                maxStringLength: characters.count,
                actualStringLength: &actualLength,
                unicodeString: &characters
            )
            guard actualLength > 0 else { return nil }
            let text = String(utf16CodeUnits: characters, count: actualLength)
            guard text.count == 1, let character = text.first else { return nil }
            return .keyDown(.character(character), modifiers: modifiers.subtracting(.shift))
        }
    }

    private static func isModelable(_ event: KeyboardEvent) -> Bool {
        switch event {
        case .keyDown(.capsLock, modifiers: _):
            return true
        case .keyDown(.diagnosticK, modifiers: _):
            return true
        case .keyDown(.space, modifiers: _):
            return true
        case let .keyDown(.character(character), modifiers: []) where character.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }):
            return true
        case .keyDown(.space, modifiers: []), .keyDown(.backspace, modifiers: []):
            return true
        default:
            return false
        }
    }

    private static func isHotkeyCandidate(_ event: KeyboardEvent) -> Bool {
        switch event {
        case .keyDown(.capsLock, modifiers: _):
            return true
        case .keyDown(.diagnosticK, modifiers: [.control, .option]),
             .keyDown(.diagnosticK, modifiers: [.shift, .control, .option]),
             .keyDown(.space, modifiers: [.shift, .option]):
            return true
        default:
            return false
        }
    }

    private static func isRegisteredHotkeyKeystroke(_ event: KeyboardEvent) -> Bool {
        switch event {
        case .keyDown(.diagnosticK, modifiers: [.control, .option]),
             .keyDown(.diagnosticK, modifiers: [.shift, .control, .option]):
            return true
        default:
            return false
        }
    }

    private static func keyboardModifiers(from flags: CGEventFlags) -> KeyboardModifiers {
        var result: KeyboardModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result
    }
}

private extension NSCondition {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
