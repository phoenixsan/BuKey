import Combine

enum AppReadiness: Equatable {
    case ready
    case permissionRequired
    case monitorUnavailable
}

enum MonitoringStatus: Equatable {
    case stopped
    case running
    case failed
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var permissionStatus: PermissionStatus
    @Published private(set) var automaticCorrectionEnabled: Bool
    @Published private(set) var statusMessage: String?
    @Published private(set) var monitoringStatus: MonitoringStatus

    var readiness: AppReadiness {
        guard permissionStatus.isReady else { return .permissionRequired }
        return monitoringStatus == .running ? .ready : .monitorUnavailable
    }

    init(
        permissionStatus: PermissionStatus = PermissionStatus(accessibility: false, inputMonitoring: false),
        automaticCorrectionEnabled: Bool = false,
        statusMessage: String? = nil,
        monitoringStatus: MonitoringStatus = .stopped
    ) {
        self.permissionStatus = permissionStatus
        self.automaticCorrectionEnabled = automaticCorrectionEnabled
        self.statusMessage = statusMessage
        self.monitoringStatus = monitoringStatus
    }

    func updatePermissionStatus(_ status: PermissionStatus) {
        permissionStatus = status
    }

    func updateAutomaticCorrectionEnabled(_ enabled: Bool) {
        automaticCorrectionEnabled = enabled
    }

    func updateStatusMessage(_ message: String?) {
        statusMessage = message
    }

    func updateMonitoringStatus(_ status: MonitoringStatus) {
        monitoringStatus = status
    }
}
