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
        let size = NSFont.systemFontSize
        textField.font = marked ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)

        if backgroundStyle == .emphasized {
            textField.textColor = .alternateSelectedControlTextColor
        } else if marked {
            textField.textColor = .systemRed
        } else {
            textField.textColor = .labelColor
        }
    }
}
