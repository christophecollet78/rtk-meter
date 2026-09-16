import Foundation
import Combine
import ServiceManagement
import AppKit

/// User-visible preferences, persisted in the standard defaults domain.
/// Every key is also settable from the command line, which keeps the app
/// scriptable and makes the defaults obvious to anyone reading `defaults read`:
///
///     defaults write local.rtkmeter rtkPath /custom/bin/rtk
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let refreshInterval = "refreshInterval"
        static let rtkPath = "rtkPath"
        static let showPercentage = "showPercentage"
        static let projectScope = "projectScope"
    }

    /// Offered in the popover; any other value set through `defaults` is honoured too.
    static let refreshChoices: [TimeInterval] = [30, 60, 300, 900]

    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// Empty means "discover rtk automatically".
    @Published var rtkPath: String {
        didSet { defaults.set(rtkPath, forKey: Key.rtkPath) }
    }

    @Published var showPercentage: Bool {
        didSet { defaults.set(showPercentage, forKey: Key.showPercentage) }
    }

    /// Mirrors the login-item registration, so the popover can bind straight to it.
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isApplyingLoginItem else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
            // Re-read rather than trust the request: the user can revoke the login
            // item from System Settings behind our back.
            isApplyingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isApplyingLoginItem = false
        }
    }

    private var isApplyingLoginItem = false

    /// Restrict stats to one directory (`rtk gain --project` run from there).
    /// Empty means global stats.
    @Published var projectScope: String {
        didSet { defaults.set(projectScope, forKey: Key.projectScope) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.refreshInterval: 60.0,
            Key.showPercentage: true,
        ])
        refreshInterval = defaults.double(forKey: Key.refreshInterval)
        rtkPath = defaults.string(forKey: Key.rtkPath) ?? ""
        showPercentage = defaults.bool(forKey: Key.showPercentage)
        projectScope = defaults.string(forKey: Key.projectScope) ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var scopeLabel: String {
        projectScope.isEmpty ? "Global" : (projectScope as NSString).lastPathComponent
    }
}
