import ApplicationServices
import AppKit
import CoreFoundation
import Foundation

struct InputTargetIdentity: Equatable, @unchecked Sendable {
    let processID: pid_t
    let retainedElement: CFTypeRef

    init<T: AnyObject>(processID: pid_t, retainedElement: T) {
        self.processID = processID
        self.retainedElement = retainedElement as CFTypeRef
    }

    static func == (lhs: InputTargetIdentity, rhs: InputTargetIdentity) -> Bool {
        lhs.processID == rhs.processID && CFEqual(lhs.retainedElement, rhs.retainedElement)
    }

    func matches(processID: pid_t, element: AXUIElement) -> Bool {
        self.processID == processID && CFEqual(retainedElement, element)
    }
}

struct TextSelectionRange: Equatable, Sendable {
    let location: Int
    let length: Int
}

struct FocusedInputContext: Equatable, Sendable {
    let target: InputTargetIdentity
    let selectionRange: TextSelectionRange
}

enum FocusedInputAssessment: Equatable, Sendable {
    case editable(FocusedInputContext)
    case protected
    case unsupported
}

enum KnownSubrole: Equatable, Sendable {
    case known(String?)
    case unknown
}

enum EditableInputSafety: Equatable, Sendable {
    case editable
    case protected
    case unsupported
}

enum EditableInputPolicy {
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    static func assess(role: String?, subrole: KnownSubrole, valueSettable: Bool?) -> EditableInputSafety {
        if role?.localizedCaseInsensitiveContains("secure") == true { return .protected }
        guard let role, editableRoles.contains(role), valueSettable == true else { return .unsupported }
        switch subrole {
        case let .known(subroleValue):
            if subroleValue?.localizedCaseInsensitiveContains("secure") == true { return .protected }
        case .unknown:
            // AXTextArea is intrinsically a multiline editing role. TextEdit may
            // return cannotComplete for AXSubrole even though all required text
            // attributes are available. Keep unknown AXTextField/AXComboBox
            // fail-closed because those roles can represent secure controls.
            guard role == "AXTextArea" else { return .unsupported }
        }
        return .editable
    }
}

protocol FocusedInputContextChecking: Sendable {
    func currentAssessment() -> FocusedInputAssessment
}

struct CachedFocusedInputSnapshot: Sendable {
    let assessment: FocusedInputAssessment
    let revision: UInt64
    let capturedAt: TimeInterval

    init(assessment: FocusedInputAssessment, revision: UInt64, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.assessment = assessment
        self.revision = revision
        self.capturedAt = capturedAt
    }
}

final class FocusedInputContextCache: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumAge: TimeInterval
    private var revision: UInt64 = 0
    private var snapshot: CachedFocusedInputSnapshot?

    init(maximumAge: TimeInterval = 0.25) { self.maximumAge = maximumAge }

    func invalidate() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
        snapshot = nil
        return revision
    }

    @discardableResult
    func store(_ assessment: FocusedInputAssessment, for revision: UInt64, capturedAt: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.revision == revision else { return false }
        snapshot = CachedFocusedInputSnapshot(assessment: assessment, revision: revision, capturedAt: capturedAt)
        return true
    }

    func snapshot(at now: TimeInterval) -> CachedFocusedInputSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot, now - snapshot.capturedAt <= maximumAge else { return nil }
        return snapshot
    }

    func revisionForPeriodicRefresh() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard snapshot != nil else { return nil }
        return revision
    }
}

protocol FocusedInputContextCoordinating: AnyObject, Sendable {
    func start()
    func attach(to runLoop: CFRunLoop)
    func stop()
    func cachedSnapshot() -> CachedFocusedInputSnapshot?
    /// Advances only the cached logical selection; this must never perform AX IPC.
    func advanceCachedSelection(for target: InputTargetIdentity, from range: TextSelectionRange, to newRange: TextSelectionRange) -> Bool
    func invalidateAndRefresh(after delay: TimeInterval)
    func currentAssessment() -> FocusedInputAssessment
}

final class AccessibilityFocusedInputContextCoordinator: FocusedInputContextCoordinating, @unchecked Sendable {
    private let checker: any FocusedInputContextChecking
    private let cache: FocusedInputContextCache
    private let queue = DispatchQueue(label: "buSwitcher.focused-context", qos: .userInteractive)
    private let refreshInterval: TimeInterval
    private var refreshTimer: DispatchSourceTimer?
    private var stopped = false

    init(
        checker: any FocusedInputContextChecking = AccessibilityFocusedInputContextChecker(),
        maximumAge: TimeInterval = 0.25,
        refreshInterval: TimeInterval = 0.1
    ) {
        self.checker = checker
        cache = FocusedInputContextCache(maximumAge: maximumAge)
        self.refreshInterval = refreshInterval
    }

    func start() {
        stopped = false
        startPeriodicRefresh()
        invalidateAndRefresh(after: 0)
    }

    func attach(to runLoop: CFRunLoop) { }

    func stop() {
        stopped = true
        refreshTimer?.setEventHandler {}
        refreshTimer?.cancel()
        refreshTimer = nil
        _ = cache.invalidate()
    }

    func cachedSnapshot() -> CachedFocusedInputSnapshot? {
        cache.snapshot(at: ProcessInfo.processInfo.systemUptime)
    }

    func advanceCachedSelection(for target: InputTargetIdentity, from range: TextSelectionRange, to newRange: TextSelectionRange) -> Bool {
        cache.advanceSelection(for: target, from: range, to: newRange)
    }

    func invalidateAndRefresh(after delay: TimeInterval) {
        let revision = cache.invalidate()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            _ = self.cache.store(self.checker.currentAssessment(), for: revision, capturedAt: ProcessInfo.processInfo.systemUptime)
        }
    }

    func currentAssessment() -> FocusedInputAssessment { checker.currentAssessment() }

    private func startPeriodicRefresh() {
        refreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(refreshInterval, 0.01)
        let intervalValue = DispatchTimeInterval.nanoseconds(Int(interval * 1_000_000_000))
        let leewayValue = DispatchTimeInterval.nanoseconds(Int(min(interval / 4, 0.025) * 1_000_000_000))
        timer.schedule(
            deadline: .now() + intervalValue,
            repeating: intervalValue,
            leeway: leewayValue
        )
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.invalidateAndRefreshOnQueue()
        }
        refreshTimer = timer
        timer.resume()
    }

    private func invalidateAndRefreshOnQueue() {
        guard let revision = cache.revisionForPeriodicRefresh() else { return }
        _ = cache.store(
            checker.currentAssessment(),
            for: revision,
            capturedAt: ProcessInfo.processInfo.systemUptime
        )
    }
}

private extension FocusedInputContextCache {
    func advanceSelection(for target: InputTargetIdentity, from range: TextSelectionRange, to newRange: TextSelectionRange) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let current = snapshot,
              ProcessInfo.processInfo.systemUptime - current.capturedAt <= maximumAge,
              case let .editable(context) = current.assessment,
              context.target == target,
              context.selectionRange == range else { return false }
        snapshot = CachedFocusedInputSnapshot(
            assessment: .editable(FocusedInputContext(target: target, selectionRange: newRange)),
            revision: current.revision
        )
        return true
    }
}

struct AccessibilityFocusedInputContextChecker: FocusedInputContextChecking {
    // Some standard AppKit text views need longer than 50 ms to answer AXSubrole.
    // Keep the fail-closed subrole policy, but allow normal cross-process AX IPC.
    private let messagingTimeout: Float = 0.5

    func currentAssessment() -> FocusedInputAssessment {
        guard let focused = focusedElement() else {
            KeyboardDiagnosticLog.write("AX assessment failed: no focused element")
            return .unsupported
        }
        _ = AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        var processID: pid_t = 0
        let pidResult = AXUIElementGetPid(focused, &processID)
        guard pidResult == .success else {
            KeyboardDiagnosticLog.write("AX assessment failed: pid status=\(pidResult.rawValue)")
            return .unsupported
        }

        let roleResult = attribute("AXRole", from: focused)
        guard roleResult.error == .success, let role = roleResult.value as? String else {
            KeyboardDiagnosticLog.write("AX assessment failed: pid=\(processID) role status=\(roleResult.error.rawValue) type=\(typeName(roleResult.value))")
            return .unsupported
        }

        let subrole: KnownSubrole
        let subroleResult = attribute("AXSubrole", from: focused)
        switch subroleResult.error {
        case .success:
            guard let value = subroleResult.value as? String else {
                KeyboardDiagnosticLog.write("AX assessment failed: pid=\(processID) role=\(role) subrole type=\(typeName(subroleResult.value))")
                return .unsupported
            }
            subrole = .known(value)
        case .noValue:
            subrole = .known(nil)
        default:
            subrole = .unknown
        }

        var valueSettable = DarwinBoolean(false)
        let settableResult = AXUIElementIsAttributeSettable(focused, "AXValue" as CFString, &valueSettable)
        let settable = settableResult == .success ? valueSettable.boolValue : nil
        switch EditableInputPolicy.assess(role: role, subrole: subrole, valueSettable: settable) {
        case .protected:
            KeyboardDiagnosticLog.write("AX assessment result: protected")
            return .protected
        case .unsupported:
            KeyboardDiagnosticLog.write("AX assessment result: unsupported by policy")
            return .unsupported
        case .editable:
            guard let selectionRange = selectionRange(from: focused) else {
                KeyboardDiagnosticLog.write("AX assessment result: selection range unavailable")
                return .unsupported
            }
            return .editable(FocusedInputContext(target: InputTargetIdentity(
                processID: processID,
                retainedElement: focused
            ), selectionRange: selectionRange))
        }
    }

    private func focusedElement() -> AXUIElement? {
        if let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            let application = AXUIElementCreateApplication(processID)
            _ = AXUIElementSetMessagingTimeout(application, messagingTimeout)
            // Electron exposes its web accessibility tree to third-party
            // assistive utilities after this attribute is enabled.
            _ = AXUIElementSetAttributeValue(
                application,
                "AXManualAccessibility" as CFString,
                true as CFTypeRef
            )
            _ = AXUIElementSetAttributeValue(
                application,
                "AXEnhancedUserInterface" as CFString,
                true as CFTypeRef
            )
            var applicationFocusedValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                kAXFocusedUIElementAttribute as CFString,
                &applicationFocusedValue
            ) == .success, let applicationFocusedValue {
                return unsafeDowncast(applicationFocusedValue, to: AXUIElement.self)
            }
        }

        let system = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            system,
            "AXFocusedUIElement" as CFString,
            &value
        )
        guard error == .success, let value else {
            KeyboardDiagnosticLog.write("AX focused element status=\(error.rawValue) type=\(typeName(value))")
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func attribute(_ name: String, from element: AXUIElement) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private func typeName(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        return String(describing: CFGetTypeID(value))
    }

    private func subroleDescription(_ subrole: KnownSubrole) -> String {
        switch subrole {
        case let .known(value): return value ?? "nil"
        case .unknown: return "unknown"
        }
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func selectionRange(from element: AXUIElement) -> TextSelectionRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXSelectedTextRange" as CFString, &value)
        guard error == .success, let value else {
            KeyboardDiagnosticLog.write("AX selected range status=\(error.rawValue) type=\(typeName(value))")
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            KeyboardDiagnosticLog.write("AX selected range has AXValue type=\(AXValueGetType(axValue).rawValue)")
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range), range.location >= 0, range.length >= 0 else {
            KeyboardDiagnosticLog.write("AX selected range could not decode location=\(range.location) length=\(range.length)")
            return nil
        }
        return TextSelectionRange(location: range.location, length: range.length)
    }
}
