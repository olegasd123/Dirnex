import DirnexCore
import SwiftUI

/// The Settings ▸ Shortcuts tab (PLAN.md §M3 "rebindable shortcuts with conflict detection;
/// TC-compatible preset and macOS preset"). Lists every registry command grouped by category
/// with an inline recorder, flags collisions, and applies the built-in presets — all editing
/// the shared `KeyBindingStore`, which the menu bar and palette read live.
struct ShortcutsSettingsView: View {
    @ObservedObject var store: KeyBindingStore
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            Form {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    let commands = filteredCommands(in: category)
                    if !commands.isEmpty {
                        Section(category.title) {
                            ForEach(commands, id: \.id) { command in
                                row(for: command)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Preset", selection: presetSelection) {
                ForEach(KeyBindings.Preset.allCases, id: \.self) { preset in
                    Text(preset.title).tag(PresetChoice.preset(preset))
                }
                Text("Custom").tag(PresetChoice.custom)
            }
            .fixedSize()

            if store.bindings.hasConflicts {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Some shortcuts are assigned to more than one command.")
            }

            Spacer()

            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Button("Restore Defaults") { store.resetAll() }
        }
        .padding(12)
    }

    /// The preset the current bindings match, driving the picker; selecting a preset applies
    /// it, while "Custom" is only ever the reflected state of a hand-edited scheme (a no-op set).
    private var presetSelection: Binding<PresetChoice> {
        Binding(
            get: { store.bindings.matchingPreset.map(PresetChoice.preset) ?? .custom },
            set: { choice in
                if case let .preset(preset) = choice { store.apply(preset: preset) }
            }
        )
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for command: Command) -> some View {
        let conflicts = store.bindings.conflicts(for: command.id)
        HStack(spacing: 8) {
            Text(command.title)
            Spacer(minLength: 8)

            if !conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Also assigned to \(conflictNames(conflicts))")
            }

            if store.bindings.isCustomized(command.id) {
                Button {
                    store.reset(command.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            }

            ShortcutRecorder(
                shortcut: store.bindings.shortcut(for: command.id),
                isConflicting: !conflicts.isEmpty,
                onRecord: { store.setShortcut($0, for: command.id) }
            )
            .frame(width: 148, height: 24)
        }
    }

    // MARK: - Helpers

    private func filteredCommands(in category: CommandCategory) -> [Command] {
        CommandCatalog.all.filter { command in
            guard command.category == category else { return false }
            guard !query.isEmpty else { return true }
            return command.title.localizedCaseInsensitiveContains(query)
                || command.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func conflictNames(_ ids: [String]) -> String {
        ids.compactMap { CommandCatalog.command(for: $0)?.title }
            .joined(separator: ", ")
    }
}

/// The Shortcuts preset picker's selection: a concrete preset, or the "Custom" state a
/// hand-edited scheme reflects. `Hashable` so it can tag `Picker` rows.
enum PresetChoice: Hashable {
    case preset(KeyBindings.Preset)
    case custom
}
