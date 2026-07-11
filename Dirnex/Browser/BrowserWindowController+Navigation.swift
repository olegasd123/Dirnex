import AppKit
import DirnexCore

/// The leading titlebar Back/Forward control, sitting just right of the sidebar toggle: the
/// ⌘[ / ⌘] history commands (View ▸ Go) as a two-segment pill, the same control Finder and
/// Safari put in their toolbars. A momentary segmented control so each half presses like a
/// button rather than latching. The click routes through the responder chain (like the Go menu
/// items) so it steps *the focused* pane's per-tab trail; each segment's enabled state mirrors
/// that pane's `canGoBack`/`canGoForward`, refreshed on every navigation, tab switch, and focus
/// change (`updateNavigationButtons`).
extension BrowserWindowController {
    /// The two segment indices, named so the click handler and the enable/tooltip setup read
    /// clearly rather than juggling bare 0/1.
    private enum NavSegment {
        static let back = 0
        static let forward = 1
    }

    /// Mirror of `installSidebarToggle`, added as a second `.leading` accessory so the pill lands
    /// immediately to the right of the sidebar button.
    func installNavigationButtons() {
        navigationControl.segmentCount = 2
        navigationControl.segmentStyle = .rounded
        navigationControl.trackingMode = .momentary
        navigationControl.setImage(navImage("chevron.backward", "Back"), forSegment: NavSegment.back)
        navigationControl.setImage(
            navImage("chevron.forward", "Forward"),
            forSegment: NavSegment.forward
        )
        navigationControl.setToolTip(navTooltip("Back", "go.back"), forSegment: NavSegment.back)
        navigationControl.setToolTip(
            navTooltip("Forward", "go.forward"),
            forSegment: NavSegment.forward
        )
        navigationControl.target = self
        navigationControl.action = #selector(navigationSegmentPressed(_:))
        navigationControl.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 82, height: 28))

        // The window runs edge-to-edge under the transparent titlebar (`fullSizeContentView`), so
        // the sidebar↕panes split divider is drawn up through this strip and shows through the
        // control's translucent pill bezel. An opaque rounded backing pinned under the pill hides
        // it — `windowBackgroundColor` is a dynamic color, so `NSBox` re-resolves it light/dark.
        let backing = NSBox()
        backing.boxType = .custom
        backing.borderWidth = 0
        backing.cornerRadius = 6
        backing.fillColor = .windowBackgroundColor
        backing.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(backing)
        container.addSubview(navigationControl)
        NSLayoutConstraint.activate([
            navigationControl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            navigationControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            navigationControl.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -8
            ),
            backing.leadingAnchor.constraint(equalTo: navigationControl.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: navigationControl.trailingAnchor),
            backing.topAnchor.constraint(equalTo: navigationControl.topAnchor),
            backing.bottomAnchor.constraint(equalTo: navigationControl.bottomAnchor)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .leading
        window?.addTitlebarAccessoryViewController(accessory)

        updateNavigationButtons()
    }

    /// Enable each half only when the active pane's trail can move that way, so the segments grey
    /// out at its ends exactly as ⌘[ / ⌘] disable in the Go menu (`validateMenuItem`).
    func updateNavigationButtons() {
        navigationControl.setEnabled(focusedPanel.canGoBack, forSegment: NavSegment.back)
        navigationControl.setEnabled(focusedPanel.canGoForward, forSegment: NavSegment.forward)
    }

    /// Dispatch the pressed half through the responder chain to the focused pane — the same path
    /// the ⌘[ / ⌘] menu items take, so archive/results panes and history bounds behave identically.
    @objc private func navigationSegmentPressed(_ sender: NSSegmentedControl) {
        let selector = sender.selectedSegment == NavSegment.forward
            ? #selector(PanelViewController.goForward(_:))
            : #selector(PanelViewController.goBack(_:))
        NSApp.sendAction(selector, to: nil, from: sender)
    }

    private func navImage(_ symbol: String, _ label: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        return image
    }

    private func navTooltip(_ label: String, _ commandID: String) -> String {
        if let hint = KeyBindingStore.shared.shortcut(for: commandID)?.display {
            return "\(label) (\(hint))"
        }
        return label
    }
}
