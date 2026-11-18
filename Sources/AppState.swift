// AppState — the small pile of preferences the whole app observes.

import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var armOnLaunch: Bool {
        didSet { UserDefaults.standard.set(armOnLaunch, forKey: "armOnLaunch") }
    }
    @Published var lowBatteryGuard: Bool {
        didSet { UserDefaults.standard.set(lowBatteryGuard, forKey: "lowBatteryGuard") }
    }
    @Published var closeSound: String {
        didSet {
            CloseSoundPlayer.shared.soundName = closeSound
        }
    }
    @Published var closeSoundEnabled: Bool {
        didSet { CloseSoundPlayer.shared.isEnabled = closeSoundEnabled }
    }
    @Published var agentStatusEnabled: Bool {
        didSet {
            UserDefaults.standard.set(agentStatusEnabled, forKey: "agentStatusEnabled")
            AgentMonitor.shared.enabled = agentStatusEnabled
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLoginItem(launchAtLogin) }
    }
    @Published var openAtLoginError: String?
    @Published var armed = false
    @Published var statusLine = "Off"

    private init() {
        let defaults = UserDefaults.standard
        armOnLaunch = defaults.object(forKey: "armOnLaunch") as? Bool ?? true
        lowBatteryGuard = defaults.object(forKey: "lowBatteryGuard") as? Bool ?? true
        closeSound = CloseSoundPlayer.shared.soundName
        closeSoundEnabled = CloseSoundPlayer.shared.isEnabled
        agentStatusEnabled = defaults.object(forKey: "agentStatusEnabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshFromEngine() {
        armed = PowerEngine.shared.isArmed
        statusLine = PowerEngine.shared.statusLine
    }

    private func applyLoginItem(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            openAtLoginError = nil
            Diagnostics.log("launch at login \(on ? "on" : "off")")
        } catch {
            openAtLoginError = error.localizedDescription
            Diagnostics.log("launch at login failed: \(error.localizedDescription)")
        }
    }
}
