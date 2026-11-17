import Foundation
import ServiceManagement

/// Start at login via SMAppService (works with ad-hoc signing; no LaunchAgent).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// A login item has to be a real `.app`; a dev run (`swift run`) would be
    /// opened in Terminal at login, so it is skipped there.
    private static var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                guard isBundledApp else { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error
        }
    }
}
