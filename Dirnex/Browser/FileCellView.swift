import AppKit

/// One cell in a file pane.
///
/// The panel distinguishes two independent states the way Total Commander does
/// (PLAN.md §1 "selection is independent of the cursor"):
/// - the **cursor** is the table's own row selection (blue when the pane is active),
/// - a **mark** is drawn as bold, accent-red text.
///
/// When a row is both marked *and* the cursor, the emphasized (blue) background wins
/// for legibility and we keep the bold weight so the mark is still visible.
final class FileCellView: NSTableCellView {
    var marked = false
    /// Fades the whole cell — icon and text alike — for a hidden (dot) entry, the way
    /// Finder greys out invisibles once you reveal them. Set per render alongside `marked`.
    var dimmed = false
    /// A colour this cell's text carries in its own right — the Git status letter (PLAN.md §M6),
    /// where the colour *is* the information and the default label colour would throw it away.
    /// Outranks the mark's red (a marked modified file still shows an orange `M`) but yields to
    /// the cursor's emphasized background, which needs its own contrast. `nil` for ordinary cells.
    var accentColor: NSColor?

    init(showsImage: Bool, identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.lineBreakMode = .byTruncatingTail
        text.cell?.usesSingleLineMode = true
        addSubview(text)
        textField = text

        if showsImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            addSubview(image)
            imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    func applyStyle() {
        guard let textField else { return }
        // Dim the whole item (icon + every column) for a hidden entry. The row's selection
        // highlight is drawn behind the cell by `NSTableRowView`, so a dimmed hidden row still
        // shows a full-strength cursor background — only its content fades, as in Finder.
        alphaValue = dimmed ? 0.5 : 1
        let size = NSFont.systemFontSize
        textField.font = marked ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)

        if backgroundStyle == .emphasized {
            textField.textColor = .alternateSelectedControlTextColor
        } else if let accentColor {
            textField.textColor = accentColor
        } else if marked {
            textField.textColor = .systemRed
        } else {
            textField.textColor = .labelColor
        }
    }

    // MARK: - Inline rename

    /// Turn the name label into an editable field for an in-place rename (F2). Runs after
    /// `applyStyle`, so it overrides the mark's bold-red styling with a plain editable box
    /// sized to the same text area beside the icon. `delegate` receives the edit lifecycle.
    func beginNameEditing(delegate: NSTextFieldDelegate) {
        guard let textField else { return }
        // Editing a hidden file — show the field at full opacity so the text stays legible;
        // the next render pass reapplies the dim once editing ends.
        alphaValue = 1
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.textColor = .labelColor
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.focusRingType = .default
        textField.delegate = delegate
    }

    /// Revert a (possibly reused) cell back to a plain, non-editable label. Idempotent —
    /// only touches a field that had been made editable — so the normal render path can
    /// call it unconditionally.
    func endNameEditing() {
        guard let textField, textField.isEditable else { return }
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.delegate = nil
    }
}
