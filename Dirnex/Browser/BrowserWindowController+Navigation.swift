import AppKit
import DirnexCore

/// The leading titlebar Back/Forward buttons, sitting just right of the sidebar toggle: the
/// ⌘[ / ⌘] history commands (View ▸ Go) in reach of the mouse. Like the menu items they carry
/// no target — the action rides the responder chain to whichever pane is focused, so each steps
/// *that* pane's per-tab trail (`PanelViewController.goBack`/`goForward`). Their enabled state
/// mirrors the active pane's `canGoBack`/`canGoForward`, refreshed on every navigation, tab
/// switch, and focus change (`updateNavigationButtons`).
extension BrowserWindowController {
    /// Mirror of `installSidebarToggle`, added as a second `.leading` accessory so the pair lands
    /// immediately to the right of the sidebar button.
    func installNavigationButtons() {
        configureNavButton(
            backButton,
            symbol: "chevron.backward",
            action: #selector(PanelViewController.goBack(_:)),
            title: "Back",
            commandID: "go.back"
        )
        configureNavButton(
            forwardButton,
            symbol: "chevron.forward",
            action: #selector(PanelViewController.goForward(_:)),
            title: "Forward",
            commandID: "go.forward"
        )

        let stack = NSStackView(views: [backButton, forwardButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 62, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            stack.heightAnchor.constraint(equalToConstant: 22)
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .leading
        window?.addTitlebarAccessoryViewController(accessory)

        updateNavigationButtons()
    }

    /// Point the buttons at the active pane's trail so they grey out at its ends, exactly as
    /// ⌘[ / ⌘] disable in the Go menu (`validateMenuItem`).
    func updateNavigationButtons() {
        backButton.isEnabled = focusedPanel.canGoBack
        forwardButton.isEnabled = focusedPanel.canGoForward
    }

    private func configureNavButton(
        _ button: NSButton,
        symbol: String,
        action: Selector,
        title: String,
        commandID: String
    ) {
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.image?.isTemplate = true
        button.target = nil // ride the responder chain to the focused pane, like the Go menu items
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true

        if let hint = KeyBindingStore.shared.shortcut(for: commandID)?.display {
            button.toolTip = "\(title) (\(hint))"
        } else {
            button.toolTip = title
        }
    }
}
