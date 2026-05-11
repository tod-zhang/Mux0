import Foundation
import Observation

/// Single source of truth for the auto-update flow. Lives in the SwiftUI
/// environment; read by SidebarView (red-dot visibility) and
/// UpdateSectionView (main UI). All mutations happen here — the Sparkle
/// UserDriver calls these helpers; views never mutate state directly.
@Observable
@MainActor
final class UpdateStore {
    /// Current app version (MARKETING_VERSION). Read once at init.
    let currentVersion: String

    /// Legacy Sparkle state machine. Kept around because SparkleBridge +
    /// UpdateUserDriver still mutate it; the live UI no longer reads from
    /// these (the active update flow goes through `ReleaseChecker` →
    /// `latestAvailableVersion`). When Sparkle is fully removed these
    /// helpers can go with it.
    var state: UpdateState = .idle

    var hasUpdate: Bool {
        switch state {
        case .updateAvailable, .downloading, .readyToInstall:
            return true
        default:
            return false
        }
    }

    /// Most recent GitHub release version known to the app (set by
    /// `ReleaseChecker` after a successful fetch). Persisted by
    /// ReleaseChecker in UserDefaults so the value survives launches even
    /// without network. Nil → we've never checked successfully.
    var latestAvailableVersion: String?

    init(currentVersion: String) {
        self.currentVersion = currentVersion
        self.latestAvailableVersion = ReleaseChecker.shared.latestVersion
    }

    // Legacy Sparkle-driven mutations — left as-is so SparkleBridge /
    // UpdateUserDriver continue to compile. New code should use the
    // ReleaseChecker path.
    func setChecking() { state = .checking }
    func setUpToDate() { state = .upToDate }
    func setUpdateAvailable(version: String, releaseNotes: String?) {
        state = .updateAvailable(version: version, releaseNotes: releaseNotes)
    }
    func setDownloading(progress: Double) { state = .downloading(progress: progress) }
    func setReadyToInstall() { state = .readyToInstall }
    func setError(_ message: String) { state = .error(message) }
    func resetToIdle() { state = .idle }
}
