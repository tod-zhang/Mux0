import Foundation
import Observation

/// Lightweight GitHub Releases poller. Replaces the Sparkle auto-update flow.
///
/// On app launch, `checkIfDue` runs once every ~24h: hits the GitHub REST
/// API for the fork's latest release, parses `tag_name`, and surfaces the
/// result two ways:
///   1. Sets `latestVersion` on `UpdateStore` so Settings → Update can show
///      "Latest: vX.Y.Z" inline.
///   2. If the fetched version is newer than the running version, calls
///      `onUpdateAvailable(version)` — wired in `ContentView` to
///      `NotificationManager.postReleaseAvailable`, which plays the system
///      alert sound. The user finds the new version in Settings → Update.
///
/// State is persisted to UserDefaults (last-check timestamp + last-known
/// version) so the 24h budget survives restarts and we don't re-fetch on
/// every launch.
@Observable
@MainActor
final class ReleaseChecker {
    static let shared = ReleaseChecker()

    /// Browser destination shown to the user. Hard-coded to the fork so the
    /// UI doesn't depend on Sparkle's `SUFeedURL` anymore (which points at
    /// the no-longer-served appcast.xml).
    static let releasesURL = URL(string: "https://github.com/tod-zhang/Mux0/releases")!

    private static let apiURL = URL(
        string: "https://api.github.com/repos/tod-zhang/Mux0/releases/latest"
    )!

    private static let lastCheckKey = "mux0.releaseCheck.lastCheckedAt"
    private static let latestVersionKey = "mux0.releaseCheck.latestVersion"

    /// Minimum gap between two `checkIfDue` fetches. 24h matches the cadence
    /// users expect from a "check for updates" feature without being chatty
    /// on the GitHub public API (60 req/hr unauthenticated quota).
    private let checkInterval: TimeInterval = 24 * 60 * 60

    /// Closure fired only when a freshly-fetched version is strictly newer
    /// than the running app's version. Suppression for "already seen this
    /// version" is the caller's responsibility — we always fire on a real
    /// version bump so the notification reaches users who dismissed the
    /// previous one.
    var onUpdateAvailable: ((String) -> Void)?

    /// Last version string the API returned (cached across launches). Used
    /// by Settings → Update to render the "Latest: vX.Y.Z" line even when
    /// no network is available this session.
    var latestVersion: String? {
        UserDefaults.standard.string(forKey: Self.latestVersionKey)
    }

    private init() {}

    /// Fetch if we haven't fetched in the last 24h. No-ops otherwise.
    /// Callers (ContentView.onAppear) can call this every launch — the
    /// budget guard makes it cheap.
    func checkIfDue(currentVersion: String) async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < checkInterval { return }
        await check(currentVersion: currentVersion)
    }

    /// Force a fetch regardless of cooldown. Used by the manual "Check
    /// for Updates" button — though we currently route that to "open
    /// releases page" instead, so this is reserved for future / tests.
    func check(currentVersion: String) async {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["tag_name"] as? String else { return }
        let version = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        UserDefaults.standard.set(version, forKey: Self.latestVersionKey)
        if Self.isNewer(candidate: version, than: currentVersion) {
            onUpdateAvailable?(version)
        }
    }

    /// Numeric-segment SemVer compare. Returns true iff `candidate` is
    /// strictly greater than `current`. Falls back to lexicographic when
    /// either side has non-integer segments (defensive — GitHub tags are
    /// authored by humans and could include `-beta.1`, dates, etc.).
    static func isNewer(candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) }
        let b = current.split(separator: ".").map { Int($0) }
        // Any nil → fall back to string compare (rare).
        if a.contains(nil) || b.contains(nil) {
            return candidate.compare(current, options: .numeric) == .orderedDescending
        }
        let ai = a.compactMap { $0 }
        let bi = b.compactMap { $0 }
        for i in 0..<min(ai.count, bi.count) {
            if ai[i] != bi[i] { return ai[i] > bi[i] }
        }
        return ai.count > bi.count
    }
}
