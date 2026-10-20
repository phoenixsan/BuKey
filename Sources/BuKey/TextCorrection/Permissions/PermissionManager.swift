import ApplicationServices
import AppKit
import CoreGraphics

struct PermissionStatus: Equatable, Sendable {
    let accessibility: Bool
    let inputMonitoring: Bool

    var isReady: Bool { accessibility && inputMonitoring }
}

@MainActor
protocol PermissionChecking: AnyObject {
    func currentStatus() -> PermissionStatus
    func requestAccessibility()
    func requestInputMonitoring()
    func openAccessibilitySettings()
    func openInputMonitoringSettings()
}

@MainActor
final class PermissionManager: PermissionChecking {
    func currentStatus() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    func openAccessibilitySettings() {
        openSettings(primary: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openSettings(primary: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private func openSettings(primary: String) {
        if let url = URL(string: primary), NSWorkspace.shared.open(url) { return }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }
}
