import SwiftUI

struct TerminalSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static let managedKeys = [
        "scrollback-limit",
        "copy-on-select",
        "mouse-hide-while-typing",
        "confirm-close-surface",
        "mux0-right-click-paste",
    ]

    var body: some View {
        Form {
            BoundStepper(
                settings: settings,
                key: "scrollback-limit",
                defaultValue: 10_000_000,
                range: 0...100_000_000,
                label: L10n.Settings.Terminal.scrollbackLimit
            )

            BoundSegmented(
                settings: settings,
                key: "copy-on-select",
                options: ["false", "true", "clipboard"],
                label: L10n.Settings.Terminal.copyOnSelect
            )

            BoundToggle(
                settings: settings,
                key: "mouse-hide-while-typing",
                defaultValue: false,
                label: L10n.Settings.Terminal.hideMouseWhileTyping
            )

            BoundToggle(
                settings: settings,
                key: "mux0-right-click-paste",
                defaultValue: true,
                label: L10n.Settings.Terminal.rightClickPaste
            )

            BoundSegmented(
                settings: settings,
                key: "confirm-close-surface",
                // "false" leads — Reset Defaults and a fresh install both
                // land on "close without confirming". The right-click → close
                // path in TabContentView honors this same key.
                options: ["false", "true", "always"],
                label: L10n.Settings.Terminal.confirmClose
            )

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
