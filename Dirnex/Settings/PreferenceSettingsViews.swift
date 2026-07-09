import SwiftUI

/// The General / Panels / Operations tabs of the Settings window (PLAN.md §M3). Each edits an
/// `AppPreferences` toggle that a single point in the browser reads; the Shortcuts tab lives in
/// its own file. Grouped `Form`s give the native macOS Settings look.

struct GeneralSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Reopen tabs from the previous session", isOn: $preferences.restoreSession)
            } footer: {
                Text("When off, each new window starts at your Home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PanelsSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Show hidden files", isOn: $preferences.showHidden)
            } footer: {
                Text(
                    "Reveals dotfiles like .git and .env in every pane. Also on the toolbar and ⇧⌘."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct OperationsSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Ask before moving items to the Trash", isOn: $preferences.confirmTrash)
            } footer: {
                Text("Permanent delete always asks for confirmation, regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
