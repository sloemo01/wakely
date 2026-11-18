import AppKit
import SwiftUI
import ApplicationServices
import CoreLocation
import UserNotifications

/// App-owned notifications: consent and delivery belong to Wakely, not Script
/// Editor/osascript. Merely posting a notice never raises an authorization prompt.
@MainActor
final class WakelyNotifications {
    static let shared = WakelyNotifications()
    private let center = UNUserNotificationCenter.current()

    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    func request() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(title: String, body: String, sound: Bool) async {
        guard await isAuthorized() else {
            Diagnostics.log("notification not delivered: Wakely notification permission is not enabled")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                       content: content, trigger: nil))
        } catch {
            Diagnostics.log("notification delivery failed: \(error.localizedDescription)")
        }
    }
}

/// Keeps the enable intent separate from the actual engine state. OS Settings
/// opening is never treated as a successful grant, and grants never start a
/// disruptive action such as starting Cleaning Lock.
@MainActor
final class ComponentPermissions: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = ComponentPermissions()
    @Published private(set) var ready: Set<ComponentPermission> = []
    @Published private(set) var message = ""
    @Published private(set) var checking = false
    @Published private(set) var helperReachable = false
    @Published private(set) var componentID: String?
    @Published private(set) var currentPermission: ComponentPermission = .accessibility
    @Published private(set) var reviewOnly = false
    /// The setup surface lives inside the retained glass panel. Window
    /// visibility is deliberately not part of setup identity anymore.
    @Published private(set) var setupPresented = false
    private var pendingEnable: String?
    private var activationObserver: NSObjectProtocol?
    private var locationManager: CLLocationManager?
    private var refreshGeneration = 0
    /// Invalidates every asynchronous enable proposal. Same-component ABA
    /// (on -> off -> on, or close -> reopen) must never resume an older task.
    private var enableIntentGeneration = 0
    /// Identifies one visible setup/review presentation. Delayed work captures
    /// this token so it cannot dismiss a newer window with the same component.
    private(set) var presentationGeneration = 0
    private var autoCloseTask: DispatchWorkItem?
    /// A deliberate System Settings handoff may hide the panel; that must not
    /// be mistaken for the user cancelling setup.
    private var externalHandoff = false

    private override init() {
        super.init()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.externalHandoff = false
                await self?.refresh()
            }
        }
    }

    private var locationAuthorized: Bool {
        let status = locationManager?.authorizationStatus ?? CLLocationManager.authorizationStatus()
        return CLLocationManager.locationServicesEnabled()
            && status == .authorizedAlways
    }

    /// Synchronous OS checks are safe at the engine boundary. Notification
    /// authorization needs an asynchronous read, so an unknown result stays off.
    func interceptEnable(_ id: String, on: Bool) -> Bool {
        enableIntentGeneration &+= 1
        if !on {
            if pendingEnable == id { pendingEnable = nil }
            return false
        }
        let intent = enableIntentGeneration
        refreshSynchronous()
        // Notification status is async. Check it before showing a setup window
        // so an already-authorized user can simply flip the switch.
        if ComponentPermissionPolicy.requirements(for: id).contains(where: { $0.permission == .notifications }),
           !ready.contains(.notifications) {
            pendingEnable = id
            Task {
                let authorized = await WakelyNotifications.shared.isAuthorized()
                guard pendingEnable == id, enableIntentGeneration == intent else { return }
                if authorized {
                    ready.insert(.notifications)
                    await refresh()
                } else {
                    show(id, permission: .notifications, automaticallyOpenSettings: false)
                }
            }
            return true
        }
        // Registration is not reachability: a helper left by a previous
        // build can be registered but rejected by XPC. Check before declaring
        // it ready or opening the wrong pane.
        if ComponentPermissionPolicy.requirements(for: id).contains(where: { $0.permission == .helper }),
           case .installed = HelperClient.shared.installState {
            pendingEnable = id
            Task {
                let reachable = await HelperClient.shared.isReachable()
                guard pendingEnable == id, enableIntentGeneration == intent else { return }
                helperReachable = reachable
                if reachable {
                    ready.insert(.helper)
                    await refresh()
                } else {
                    ready.remove(.helper)
                    show(id, permission: .helper, automaticallyOpenSettings: false)
                }
            }
            return true
        }
        guard let missing = ComponentPermissionPolicy.missingRequired(for: id, ready: ready).first else {
            return false
        }
        pendingEnable = id
        show(id, permission: missing, automaticallyOpenSettings: missing == .accessibility)
        return true
    }

    func isSettingUp(_ id: String) -> Bool {
        setupPresented && componentID == id
    }

    var allRequiredReady: Bool {
        guard let id = componentID else { return false }
        return ComponentPermissionPolicy.missingRequired(for: id, ready: ready).isEmpty
    }

    var helperInstalled: Bool {
        if case .installed = HelperClient.shared.installState { return true }
        return false
    }

    var helperNeedsApproval: Bool {
        if case .requiresApproval = HelperClient.shared.installState { return true }
        return false
    }

    func showRequirements(for id: String) {
        Task { @MainActor in
            await refresh()
            guard SettingsModel.shared.detailComponent?.id == id else { return }
            let requirements = ComponentPermissionPolicy.requirements(for: id)
            guard let first = requirements.first else { return }
            if let missing = ComponentPermissionPolicy.missingRequired(for: id, ready: ready).first {
                pendingEnable = nil
                enableIntentGeneration &+= 1
                show(id, permission: missing, automaticallyOpenSettings: false, reviewOnly: false)
            } else {
                show(id, permission: first.permission, automaticallyOpenSettings: false, reviewOnly: true)
                message = "Everything this component needs is ready. Choose Done to close setup."
            }
        }
    }

    /// Called only after a real detail route settles. The closure is the route
    /// authority: same-ID close/reopen and URL entry must not let an older async
    /// permission result mutate a newer page.
    func presentRequirementsIfNeeded(
        for id: String,
        route: UUID,
        isRouteCurrent: @escaping @MainActor () -> Bool
    ) {
        Task { @MainActor in
            guard isRouteCurrent() else { return }
            await refresh()
            guard isRouteCurrent(), let missing = ComponentPermissionPolicy.missingRequired(
                for: id, ready: ready
            ).first else { return }
            // Keep the route token in the diagnostic identity of the setup
            // window guard. A stale route has already returned above.
            _ = route
            show(id, permission: missing, automaticallyOpenSettings: false, reviewOnly: false)
        }
    }

    /// Used on explicit Lock Now too, covering permission revoked after enable.
    func requireAccessibility(for id: String) -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        pendingEnable = nil
        show(id, permission: .accessibility, automaticallyOpenSettings: true)
        return false
    }

    private func refreshSynchronous() {
        if AXIsProcessTrusted() { ready.insert(.accessibility) } else { ready.remove(.accessibility) }
        if locationAuthorized { ready.insert(.location) } else { ready.remove(.location) }
        HelperClient.shared.refreshInstallState()
        if case .installed = HelperClient.shared.installState { ready.insert(.helper) }
        else { ready.remove(.helper) }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let presentation = presentationGeneration
        refreshSynchronous()
        let authorized = await WakelyNotifications.shared.isAuthorized()
        guard generation == refreshGeneration, presentation == presentationGeneration else { return }
        if authorized { ready.insert(.notifications) } else { ready.remove(.notifications) }
        if case .installed = HelperClient.shared.installState {
            let reachable = await HelperClient.shared.isReachable()
            guard generation == refreshGeneration, presentation == presentationGeneration else { return }
            helperReachable = reachable
        } else {
            helperReachable = false
        }
        if helperReachable { ready.insert(.helper) } else { ready.remove(.helper) }
        // If the window was only waiting for a grant that has now arrived,
        // close it instead of leaving a dead install panel behind.
        if !reviewOnly, let shownID = componentID, pendingEnable == nil,
           ComponentPermissionPolicy.missingRequired(for: shownID, ready: ready).isEmpty,
           setupPresented {
            if shownID == "cleaningLock" {
                let note = "Accessibility is ready. Turn Cleaning Lock on when you are ready to lock input."
                SettingsModel.shared.cleaningLockMessage = note
                SettingsModel.shared.enablementNotice = note
            }
            hidePresentation()
        }
        guard let id = pendingEnable else { return }
        let missing = ComponentPermissionPolicy.missingRequired(for: id, ready: ready)
        guard missing.isEmpty else {
            currentPermission = missing[0]
            message = "Not enabled yet. Complete the step above, then choose Check Again."
            return
        }
        let intent = enableIntentGeneration
        pendingEnable = nil
        if !ComponentPermissionPolicy.resumesEnableAfterGrant(id) {
            message = "Accessibility is ready. Turn Cleaning Lock on when you are ready to lock input."
            SettingsModel.shared.cleaningLockMessage = message
            SettingsModel.shared.enablementNotice = message
            hidePresentation()
            return
        }
        await ComponentEngine.shared.enableAfterPermissionGrant(id)
        guard generation == refreshGeneration,
              presentation == presentationGeneration,
              enableIntentGeneration == intent else { return }
        SettingsModel.shared.refresh()
        if ComponentEngine.shared.isEnabled(id) {
            message = "Ready. \(ComponentCatalog.definition(for: id)?.name ?? id) is enabled."
            reviewOnly = false
            hidePresentation()
        } else {
            let reason = ComponentEngine.shared.enablementReason(for: id)
                ?? "macOS or this Mac does not support this operation. The component stays off."
            message = reason
            SettingsModel.shared.enablementNotice = reason
            reviewOnly = false
            hidePresentation()
        }
    }

    private func show(_ id: String, permission: ComponentPermission,
                      automaticallyOpenSettings: Bool, reviewOnly: Bool = false) {
        presentationGeneration &+= 1
        refreshGeneration &+= 1
        autoCloseTask?.cancel()
        autoCloseTask = nil
        SettingsModel.shared.showMakeYourOwn = false
        componentID = id
        currentPermission = permission
        self.reviewOnly = reviewOnly
        message = ""
        setupPresented = true
        // The glass host is retained for the whole app lifetime. Explicit
        // setup requests may reveal it; passive refreshes never call show().
        if FluidOpen.shared.debugPanelWindow?.isVisible != true {
            let tab = ComponentCatalog.definition(for: id) == nil ? "general" : "components"
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow(tab: tab)
        }
        if automaticallyOpenSettings { openSettings(for: permission) }
    }

    func openSettings(for permission: ComponentPermission? = nil) {
        let target = permission ?? currentPermission
        externalHandoff = true
        if !NSWorkspace.shared.open(target.settingsURL) {
            message = "Could not open System Settings. Open it manually and follow the instructions above."
        }
    }

    /// One installation shared by every helper-backed component. The UI calls
    /// this once from General or from any helper setup window; it never asks
    /// per component.
    func installHelperForAll() {
        guard !checking else { return }
        checking = true
        Task {
            let result = await HelperClient.shared.install()
            switch result {
            case .success:
                message = "Helper installed. Checking the connection…"
            case .failure(let error):
                message = error.localizedDescription
            }
            await refresh()
            if helperReachable {
                ready.insert(.helper)
                message = "Helper is installed and reachable."
            }
            checking = false
            SettingsModel.shared.refresh()
        }
    }

    func installHelperWithAdministrator() {
        guard !checking else { return }
        checking = true
        Task {
            let result = await HelperClient.shared.installWithAdministratorPrompt()
            switch result {
            case .success:
                message = "Helper installed. Checking the connection…"
            case .failure(let error):
                message = error.localizedDescription
            }
            await refresh()
            if helperReachable {
                ready.insert(.helper)
                message = "Helper is installed and reachable."
            }
            checking = false
        }
    }

    func requestCurrent() {
        guard !checking else { return }
        checking = true
        let permission = currentPermission
        let presentation = presentationGeneration
        Task {
            defer { checking = false }
            switch permission {
            case .accessibility:
                // The user must flip the switch themselves. No repeated TCC prompt.
                openSettings(for: permission)
            case .location:
                if locationManager == nil {
                    let manager = CLLocationManager()
                    manager.delegate = self
                    locationManager = manager
                }
                if locationManager?.authorizationStatus == .notDetermined {
                    locationManager?.requestWhenInUseAuthorization()
                } else { openSettings(for: permission) }
            case .notifications:
                do {
                    let granted = try await WakelyNotifications.shared.request()
                    if !granted { openSettings(for: permission) }
                } catch { message = error.localizedDescription }
            case .helper:
                if helperReachable, ready.contains(.helper) {
                    cancel()
                    return
                }
                if helperNeedsApproval {
                    openSettings(for: .helper)
                    return
                }
                let result = await HelperClient.shared.install()
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            guard presentation == presentationGeneration else { return }
            await refresh()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in await self.refresh() }
    }

    /// Clears presentation and all deferred enable work. The permission and
    /// helper installation facts remain global; only this session is gone.
    private func hidePresentation() {
        setupPresented = false
        componentID = nil
        reviewOnly = false
        autoCloseTask?.cancel()
        autoCloseTask = nil
        refreshGeneration &+= 1
        presentationGeneration &+= 1
        enableIntentGeneration &+= 1
    }

    /// One owned close request for a ready review/setup window. The token makes
    /// a delayed close harmless if a newer presentation appears first.
    func scheduleAutoClose(after delay: TimeInterval) {
        guard !reviewOnly, allRequiredReady else { return }
        autoCloseTask?.cancel()
        let token = presentationGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationGeneration == token,
                      self.allRequiredReady, !self.reviewOnly else { return }
                self.cancel()
            }
        }
        autoCloseTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cancel() {
        pendingEnable = nil
        externalHandoff = false
        hidePresentation()
    }

    /// Called when the user deliberately hides the whole panel. An active
    /// System Settings handoff is allowed to remain resumable; any other hide
    /// cancels the setup intent instead of leaving a hidden enable request.
    func panelWillHide() {
        guard setupPresented, !externalHandoff else { return }
        cancel()
    }

    /// QA only: render the real permission window without prompting, registering
    /// helpers, or touching System Settings. Used by --render-permission-preview.
    @MainActor
    static func previewView(componentID: String, permission: ComponentPermission) -> NSView {
        let coordinator = ComponentPermissions()
        coordinator.componentID = componentID
        coordinator.currentPermission = permission
        coordinator.ready = []
        coordinator.reviewOnly = false
        let host = NSHostingView(rootView: ComponentSetupContent(coordinator: coordinator))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 470)
        return host
    }

    /// QA-only: show the in-panel setup surface without prompting, installing,
    /// enabling, or opening System Settings.
    func previewInPanel(componentID previewID: String, permission: ComponentPermission) {
        componentID = previewID
        currentPermission = permission
        ready = []
        reviewOnly = false
        setupPresented = true
    }
}

@MainActor
struct ComponentSetupContent: View {
    @ObservedObject var coordinator: ComponentPermissions
    @AccessibilityFocusState private var headingFocused: Bool

    private var componentName: String {
        coordinator.componentID.flatMap { ComponentCatalog.definition(for: $0)?.name } ?? "Wakely"
    }

    private var helperNeedsRepair: Bool {
        coordinator.currentPermission == .helper
            && coordinator.helperInstalled
            && !coordinator.helperReachable
            && !coordinator.helperNeedsApproval
    }

    private var requirements: [ComponentPermissionRequirement] {
        guard let id = coordinator.componentID else { return [] }
        return ComponentPermissionPolicy.requirements(for: id)
    }

    private var instructionText: String {
        if helperNeedsRepair {
            return "The helper is installed but is not answering. Choose Repair Helper to reinstall it once. Every helper component shares this installation, so later components will not ask again."
        }
        if coordinator.helperNeedsApproval {
            return "Approve Wakely in Login Items & Extensions, then choose Check Again. No administrator password is needed for this build."
        }
        return coordinator.currentPermission.instructions
    }

    private var isDone: Bool {
        coordinator.reviewOnly || coordinator.allRequiredReady
    }

    private var primaryTitle: String {
        if isDone { return "Done" }
        switch coordinator.currentPermission {
        case .accessibility: return "Open Accessibility"
        case .location: return "Allow Location"
        case .notifications: return "Allow Notifications"
        case .helper:
            if coordinator.helperNeedsApproval { return "Open Login Items" }
            return helperNeedsRepair ? "Repair Helper" : "Install Helper"
        }
    }

    private var status: (text: String, symbol: String, color: Color) {
        if coordinator.checking { return ("Checking this Mac…", "arrow.triangle.2.circlepath", Theme.goldSoft) }
        if isDone { return ("Ready", "checkmark.circle.fill", .green) }
        if coordinator.helperNeedsApproval { return ("Waiting for approval", "clock.fill", .orange) }
        if helperNeedsRepair { return ("Helper needs repair", "exclamationmark.triangle.fill", .orange) }
        return ("Action needed", "info.circle.fill", Theme.goldSoft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(componentName)
                        .font(.title2.bold())
                        .accessibilityFocused($headingFocused)
                    Text(coordinator.currentPermission == .helper ? "Privileged helper" : coordinator.currentPermission.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Label(status.text, systemImage: status.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(status.color.opacity(0.12), in: Capsule())
            }
            .padding(.bottom, 18)

            Divider().opacity(0.35)

            EdgeScrollView(topFade: 24, bottomFade: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    if isDone {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Permission granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            if requirements.contains(where: { $0.permission == .helper }) {
                                Label("Helper reachable", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            Label("This Mac's support is checked automatically when you turn the component on.",
                                  systemImage: "info.circle")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .font(.callout)
                    } else {
                        Text(instructionText)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if !isDone && coordinator.currentPermission.supportsAppDrag {
                        HStack(spacing: 14) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                                .resizable().frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Drag Wakely into Accessibility").fontWeight(.semibold)
                                Text("This is the app you are running.").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                        Button("Show Wakely in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(.link)
                    }

                    if !coordinator.message.isEmpty {
                        Text(coordinator.message)
                            .font(.callout)
                            .foregroundStyle(Theme.goldSoft)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Button("Close") { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !isDone && !coordinator.checking && !helperNeedsRepair {
                    Button("Check Again") { Task { await coordinator.refresh() } }
                }
                Button(primaryTitle) {
                    if isDone {
                        coordinator.cancel()
                    } else if coordinator.helperNeedsApproval {
                        coordinator.openSettings()
                    } else {
                        coordinator.requestCurrent()
                    }
                }
                .disabled(coordinator.checking)
                .buttonStyle(PixelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)

            if coordinator.currentPermission != .helper && !isDone {
                Button("Open System Settings") { coordinator.openSettings() }
                    .buttonStyle(.link)
                    .font(ClamType.body(11.5))
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .foregroundStyle(Theme.ink)
        .tint(Theme.gold)
        .modifier(AppAppearanceModifier())
        .onAppear { headingFocused = true }
    }
}

@MainActor
struct ComponentPermissionStatusView: View {
    let componentID: String
    @ObservedObject private var coordinator = ComponentPermissions.shared

    var body: some View {
        let requirements = ComponentPermissionPolicy.requirements(for: componentID)
        if !requirements.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(requirements, id: \.permission) { requirement in
                    let registered = coordinator.ready.contains(requirement.permission)
                    let allowed = requirement.permission == .helper
                        ? coordinator.helperReachable && registered
                        : registered
                    let status = requirement.permission == .helper && registered && !allowed
                        ? "installed — not reachable yet"
                        : (allowed ? "ready" : (requirement.required ? "setup required" : "optional typing protection"))
                    HStack {
                        Image(systemName: allowed ? "checkmark.circle" : "info.circle")
                        Text("\(requirement.permission.title) — \(status)")
                        Spacer()
                        if !allowed {
                            Button("Set Up") {
                                coordinator.showRequirements(for: componentID)
                            }
                        }
                    }
                }
                if componentID == "cleaningLock" {
                    Text("Granting access never starts a lock. Turn the switch on again when you are ready to lock input.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .task { await coordinator.refresh() }
        }
    }
}
