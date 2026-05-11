import SwiftUI
import AppKit

struct UpdateSectionView: View {
    let theme: AppTheme
    let updateStore: UpdateStore

    @Environment(\.locale) private var locale

    /// Hard-coded — Sparkle's silent path was retired in favor of "open my
    /// fork's Releases page and let the user pick a DMG manually". Keeping it
    /// in a single constant rather than reading SUFeedURL because the feed
    /// URL points at `appcast.xml` and Sparkle/Info.plist are no longer in
    /// the loop.
    private static let releasesURL = URL(string: "https://github.com/tod-zhang/Mux0/releases")!

    /// True iff a fetched release version is strictly newer than the running app.
    /// Drives the "newer / up to date" label next to the latest-version line.
    private var hasNewer: Bool {
        guard let latest = updateStore.latestAvailableVersion else { return false }
        return ReleaseChecker.isNewer(candidate: latest, than: updateStore.currentVersion)
    }

    var body: some View {
        Form {
            LabeledContent(String(localized: L10n.Settings.Update.currentVersion.withLocale(locale))) {
                Text("v\(updateStore.currentVersion)")
                    .font(Font(DT.Font.body).monospacedDigit())
                    .foregroundColor(Color(theme.textSecondary))
            }

            // Surface the last-known release version when ReleaseChecker has
            // ever returned one. Persisted across launches in UserDefaults,
            // so this line shows up even without network this session.
            if let latest = updateStore.latestAvailableVersion {
                LabeledContent(String(localized: L10n.Settings.Update.availableUpdate.withLocale(locale))) {
                    HStack(spacing: DT.Space.xs) {
                        Text("v\(latest)")
                            .font(Font(DT.Font.body).monospacedDigit())
                            .foregroundColor(Color(hasNewer ? theme.accent : theme.textSecondary))
                        if !hasNewer {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color(theme.success))
                        }
                    }
                }
            }

            LabeledContent(String(localized: L10n.Settings.Update.status.withLocale(locale))) {
                Button(String(localized: L10n.Settings.Update.checkForUpdates.withLocale(locale))) {
                    NSWorkspace.shared.open(Self.releasesURL)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
