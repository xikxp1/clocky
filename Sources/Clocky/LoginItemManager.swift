import AppKit
import Combine
import ServiceManagement

/// The narrow boundary keeps tests from changing the user's real login items.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private final class MainAppLoginItemService: LoginItemService {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// ServiceManagement is the source of truth; no preference silently opts a user in.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    let unavailableReason: String?

    var canConfigure: Bool { unavailableReason == nil }
    // Pending approval is still a request, so switching off must unregister it.
    var isRequested: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    private let service: any LoginItemService
    private let notificationCenter: NotificationCenter
    private var activationObserver: NSObjectProtocol?

    convenience init() {
        self.init(
            service: MainAppLoginItemService(),
            unavailableReason: Self.configurationUnavailableReason(
                bundleURL: Bundle.main.bundleURL,
                executableURL: Bundle.main.executableURL,
                bundleIdentifier: Bundle.main.bundleIdentifier,
                arguments: CommandLine.arguments
            )
        )
    }

    init(
        service: any LoginItemService,
        unavailableReason: String? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.service = service
        self.unavailableReason = unavailableReason
        self.notificationCenter = notificationCenter
        status = service.status
        refresh()
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activationObserver != nil else { return }
                self.refresh()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard canConfigure else { return }
        // Account for changes made in System Settings since the last activation.
        refresh()
        guard enabled != isRequested else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            // Even a failed operation may have changed the actual registration.
            refresh()
            let action = enabled ? "enable" : "disable"
            let detail = errorMessage.map { " \($0)" } ?? ""
            errorMessage = "Could not \(action) Start at Login: \(error.localizedDescription)\(detail)"
        }
    }

    func refresh() {
        status = service.status
        errorMessage = canConfigure && status == .notFound
            ? "macOS could not find Clocky's login service. Keep the packaged app in a stable location and try enabling Start at Login again."
            : nil
    }

    /// Opening System Settings is always an explicit user action, never registration's side effect.
    func openSystemSettings() {
        guard canConfigure else { return }
        service.openSystemSettings()
    }

    /// Stop observing only; quitting must preserve the user's registration.
    func stop() {
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    deinit {
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
    }

    /// Shape checks deliberately allow packaged apps outside /Applications.
    static func configurationUnavailableReason(
        bundleURL: URL,
        executableURL: URL?,
        bundleIdentifier: String?,
        arguments: [String]
    ) -> String? {
        if arguments.contains("--smoke-test") {
            return "Start at Login is disabled during smoke-test diagnostics."
        }
        let executableDirectory = bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard bundleURL.pathExtension.lowercased() == "app",
              let executableURL,
              executableURL.deletingLastPathComponent().standardizedFileURL
                == executableDirectory.standardizedFileURL,
              let bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Start at Login requires the packaged Clocky.app; it is unavailable when running directly with swift run."
        }
        return nil
    }
}
