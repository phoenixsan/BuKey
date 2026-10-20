import Combine
import Foundation

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()
    static let automaticCorrectionKey = "automaticCorrectionEnabled"

    let state: AppState
    private let permissionChecker: any PermissionChecking
    private let monitor: any EventMonitoring
    private let detector: any LanguageDetecting
    private let replacer: any TextReplacing
    private let layoutSwitcher: any KeyboardLayoutSwitching
    private let defaults: UserDefaults

    convenience init() {
        self.init(
            permissionChecker: PermissionManager(),
            monitor: KeyboardMonitor(),
            detector: LanguageDetector(),
            replacer: TextReplacer(),
            layoutSwitcher: SystemKeyboardLayoutSwitcher()
        )
    }

    init(
        permissionChecker: any PermissionChecking,
        monitor: any EventMonitoring,
        detector: any LanguageDetecting,
        replacer: any TextReplacing,
        layoutSwitcher: any KeyboardLayoutSwitching,
        defaults: UserDefaults = .standard
    ) {
        self.permissionChecker = permissionChecker
        self.monitor = monitor
        self.detector = detector
        self.replacer = replacer
        self.layoutSwitcher = layoutSwitcher
        self.defaults = defaults
        state = AppState(automaticCorrectionEnabled: defaults.bool(forKey: Self.automaticCorrectionKey))
    }

    func start() {
        refreshPermissionsAndMonitoring()
    }

    func applicationDidBecomeActive() {
        refreshPermissionsAndMonitoring()
    }

    func setAutomaticCorrectionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticCorrectionKey)
        state.updateAutomaticCorrectionEnabled(enabled)
    }

    func requestAccessibility() {
        permissionChecker.requestAccessibility()
        refreshPermissionsAndMonitoring()
    }

    func requestInputMonitoring() {
        permissionChecker.requestInputMonitoring()
        refreshPermissionsAndMonitoring()
    }

    func openAccessibilitySettings() {
        permissionChecker.openAccessibilitySettings()
    }

    func openInputMonitoringSettings() {
        permissionChecker.openInputMonitoringSettings()
    }

    private func refreshPermissionsAndMonitoring() {
        let status = permissionChecker.currentStatus()
        state.updatePermissionStatus(status)

        guard status.isReady else {
            monitor.stop()
            state.updateMonitoringStatus(.stopped)
            state.updateStatusMessage(missingPermissionMessage(for: status))
            return
        }

        if monitor.isRunning {
            state.updateMonitoringStatus(.running)
            state.updateStatusMessage(nil)
            return
        }
        do {
            try monitor.start { [weak self] event in
                self?.handle(event)
            }
            guard monitor.isRunning else {
                state.updateMonitoringStatus(.failed)
                state.updateStatusMessage("Не удалось запустить отслеживание клавиатуры.")
                return
            }
            state.updateMonitoringStatus(.running)
            state.updateStatusMessage(nil)
        } catch {
            state.updateMonitoringStatus(.failed)
            state.updateStatusMessage("Не удалось запустить отслеживание клавиатуры.")
        }
    }

    private func handle(_ event: KeyboardMonitorEvent) {
        switch event {
        case let .diagnostic(message):
            showTransientStatus(message)
        case let .wordTerminated(request):
            guard state.automaticCorrectionEnabled,
                  let candidate = detector.correction(for: request.snapshot.text) else { return }
            scheduleAutomaticReplacement(
                request: request,
                replacement: candidate,
                targetLayout: LayoutConverter.dominantLayout(in: candidate)
            )
        case let .directCorrection(request):
            let replacement = LayoutConverter.convertToOppositeLayout(request.snapshot.text)
            guard replacement != request.snapshot.text else {
                showTransientStatus("Не удалось определить раскладку.")
                return
            }
            do {
                guard try monitor.performIfDirectCommandCurrent(generation: request.generation, operation: {
                    try replacer.replaceRecentlyTyped(snapshot: request.snapshot, with: replacement)
                    if let layout = LayoutConverter.dominantLayout(in: replacement) {
                        layoutSwitcher.select(layout)
                    }
                }) else {
                    showTransientStatus("После команды ввод уже изменился.")
                    return
                }
            } catch {
                showReplacementError(error)
            }
        case let .command(request) where request.command == .correctLastWord:
            guard let snapshot = request.snapshot else {
                showTransientStatus("Нет текста для исправления.")
                return
            }
            let replacement = LayoutConverter.convertToOppositeLayout(snapshot.text)
            guard replacement != snapshot.text else {
                showTransientStatus("Не удалось определить раскладку.")
                return
            }
            performReplacement(
                request: WordTerminationRequest(snapshot: snapshot, context: request.context),
                replacement: replacement,
                targetLayout: LayoutConverter.dominantLayout(in: replacement)
            )
        case let .command(request):
            performIfCurrent(request.context, validation: .targetOnly, successMessage: "Выделение преобразовано.") {
                var targetLayout: KeyboardLayout?
                try replacer.convertSelection(
                    context: request.context,
                    using: { text in
                        let replacement = LayoutConverter.convertToOppositeLayout(text)
                        targetLayout = LayoutConverter.dominantLayout(in: replacement)
                        return replacement
                    }
                )
                if let targetLayout { layoutSwitcher.select(targetLayout) }
            }
        }
    }

    private func scheduleAutomaticReplacement(
        request: WordTerminationRequest,
        replacement: String,
        targetLayout: KeyboardLayout?
    ) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.performReplacement(request: request, replacement: replacement, targetLayout: targetLayout)
        }
    }

    private func performReplacement(
        request: WordTerminationRequest,
        replacement: String,
        targetLayout: KeyboardLayout?
    ) {
        performIfCurrent(request.context, validation: .exactSelection) {
            try replacer.replaceLastWord(
                snapshot: request.snapshot,
                with: replacement,
                context: request.context
            )
            if let targetLayout { layoutSwitcher.select(targetLayout) }
        }
    }

    private func performIfCurrent(
        _ context: InputEventContext,
        validation: InputContextValidation,
        successMessage: String? = nil,
        operation: () throws -> Void
    ) {
        do {
            guard try monitor.performIfCurrent(context, validation: validation, operation: operation) else {
                showTransientStatus("Контекст ввода изменился.")
                return
            }
            if let successMessage { showTransientStatus(successMessage) }
        } catch {
            showReplacementError(error)
        }
    }

    private func showReplacementError(_ error: Error) {
        let message: String
        switch error as? TextReplacementError {
        case .noSelection: message = "Нет выделенного текста."
        case .protectedField: message = "Защищённое поле недоступно."
        case .unsupportedControl: message = "Это поле не поддерживает замену."
        case .eventCreationFailed, .none: message = "Не удалось заменить текст."
        }
        showTransientStatus(message)
    }

    private func showTransientStatus(_ message: String) {
        state.updateStatusMessage(message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard self?.state.statusMessage == message else { return }
            self?.state.updateStatusMessage(nil)
        }
    }

    private func missingPermissionMessage(for status: PermissionStatus) -> String {
        switch (status.accessibility, status.inputMonitoring) {
        case (false, true): return "Нужно разрешение Accessibility."
        case (true, false): return "Нужно разрешение Input Monitoring."
        case (false, false): return "Нужны разрешения Accessibility и Input Monitoring."
        case (true, true): return ""
        }
    }
}
