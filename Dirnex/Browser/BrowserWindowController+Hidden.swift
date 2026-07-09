import AppKit
import DirnexCore

/// The trailing titlebar button that shows or hides hidden (dot) files across the whole app —
/// the same effect as ⇧⌘. or View ▸ Show Hidden Files, in reach of the mouse. It only drives
/// `AppPreferences.showHidden`; the panes re-filter themselves off `showHiddenDidChange`, which
/// also restyles the button so its eye/eye-slash glyph always tracks the current state.
extension BrowserWindowController {
    /// Mirror of `installSidebarToggle`, on the trailing side: an eye button in the otherwise
    /// empty transparent title bar. Restyled immediately to the current state, and again on
    /// every `showHiddenDidChange`.
    func installHiddenToggle() {
        hiddenToggleButton.bezelStyle = .toolbar
        hiddenToggleButton.isBordered = false
        hiddenToggleButton.imagePosition = .imageOnly
        hiddenToggleButton.target = self
        hiddenToggleButton.action = #selector(toggleHiddenFilesFromButton)
        hiddenToggleButton.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        container.addSubview(hiddenToggleButton)
        NSLayoutConstraint.activate([
            hiddenToggleButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            hiddenToggleButton.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: 8
            ),
            hiddenToggleButton.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -8
            ),
            hiddenToggleButton.heightAnchor.constraint(equalToConstant: 22)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hiddenStateChanged),
            name: AppPreferences.showHiddenDidChange,
            object: nil
        )
        updateHiddenToggleButton()
    }

    @objc private func toggleHiddenFilesFromButton() {
        AppPreferences.shared.toggleShowHidden()
    }

    @objc private func hiddenStateChanged() {
        updateHiddenToggleButton()
    }

    /// Point the glyph at the current state: an accented open eye when hidden files are showing,
    /// a plain eye-slash when they're not. The tooltip names the action and its shortcut.
    private func updateHiddenToggleButton() {
        let showing = AppPreferences.shared.showHidden
        let symbol = showing ? "eye" : "eye.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Show hidden files")
        image?.isTemplate = true
        hiddenToggleButton.image = image
        hiddenToggleButton.contentTintColor = showing ? .controlAccentColor : nil

        let action = showing ? "Hide hidden files" : "Show hidden files"
        if let hint = KeyBindingStore.shared.shortcut(for: "view.toggleHidden")?.display {
            hiddenToggleButton.toolTip = "\(action) (\(hint))"
        } else {
            hiddenToggleButton.toolTip = action
        }
    }
}
