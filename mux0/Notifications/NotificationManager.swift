import Foundation
import AppKit

/// Audio-only alert bridge for agent hook events and new GitHub releases.
///
/// Banners were removed deliberately — agent state is already shown by the
/// sidebar / tab status icons, and new-release info is surfaced in
/// Settings → Update. This file exists as a tiny indirection so callers
/// (`ContentView`, `ReleaseChecker`) can keep their existing wiring and the
/// audio policy (which sound, gated by which toggle) is centralised here.
@MainActor
final class NotificationManager {
    /// Master kill switch. Read from `SettingsConfigStore` on every event so
    /// flipping the toggle in Settings → Agents takes effect immediately.
    /// Only gates agent sounds — release-available is always allowed so the
    /// user is told about updates even after silencing per-agent chatter.
    var isEnabled: () -> Bool = { true }

    /// No-op kept for call-site stability. The previous implementation
    /// registered a `UNUserNotificationCenter` delegate here.
    func start() {}

    func postNeedsInput() {
        guard isEnabled() else { return }
        NSSound.beep()
    }

    func postFinished() {
        guard isEnabled() else { return }
        NSSound.beep()
    }

    func postReleaseAvailable() {
        NSSound.beep()
    }
}
