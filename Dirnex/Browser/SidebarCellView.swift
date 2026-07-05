import AppKit

/// One item row in the places/volumes sidebar: an icon, a name, and — for ejectable
/// volumes only — a trailing eject button. Headers use `SidebarHeaderView` instead.
///
/// The eject button routes through a stored closure rather than target/action so the
/// controller can hand each reused cell the right volume without subclass bookkeeping.
final class SidebarCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarItemCell")

    /// Invoked when the eject button is clicked; `nil` hides the button.
    var onEject: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = SidebarCellView.identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        imageView = icon

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        textField = label

        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        ejectButton.isBordered = false
        ejectButton.bezelStyle = .accessoryBarAction
        ejectButton.imagePosition = .imageOnly
        ejectButton.image = NSImage(
            systemSymbolName: "eject.fill",
            accessibilityDescription: "Eject"
        )
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.target = self
        ejectButton.action = #selector(eject)
        ejectButton.toolTip = "Eject"
        addSubview(ejectButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            ejectButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor,
                constant: 4
            ),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, image: NSImage, canEject: Bool, tooltip: String?) {
        label.stringValue = name
        image.size = NSSize(width: 18, height: 18)
        icon.image = image
        ejectButton.isHidden = !canEject
        toolTip = tooltip
    }

    @objc private func eject() {
        onEject?()
    }
}

/// A section header ("Favorites", "Volumes") in the sidebar. A source-list group row
/// AppKit already renders with the right vibrancy; this just supplies the label.
final class SidebarHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeaderCell")

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = SidebarHeaderView.identifier

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        label.stringValue = title
    }
}
