import AppKit
import DirnexCore

/// The modal progress sheet shown while a copy/move runs (PLAN.md §M2 "Progress UI").
///
/// A deliberately small first cut: a title, a determinate bar, the current file, a
/// byte/item readout, and a Cancel button. The full queue bar with an expandable
/// per-job list and pause/resume arrives with the operation-queue pass; this already
/// keeps the window responsive (the copy runs on a background task) and gives the user
/// a way out mid-operation.
@MainActor
final class OperationProgressSheet {
    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private var onCancel: (() -> Void)?

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(kind: FileOperation.Kind) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 130),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.stringValue = kind == .copy ? "Copying…" : "Moving…"

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.stringValue = "Preparing…"

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}" // Esc cancels
        cancelButton.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [NSView(), cancelButton])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40)
        ])
        window.contentView = content
    }

    /// Begin the sheet on `parent`. `onCancel` fires when the user clicks Cancel (or hits
    /// Esc) — the caller cancels the running task; the sheet stays up until the operation
    /// actually stops and the caller calls `dismiss()`.
    func present(in parent: NSWindow?, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        parent?.beginSheet(window)
    }

    func update(_ progress: OperationProgress) {
        bar.doubleValue = progress.fraction
        let done = Self.byteFormatter.string(fromByteCount: progress.completedBytes)
        let total = Self.byteFormatter.string(fromByteCount: progress.totalBytes)
        let name = progress.currentItem?.lastComponent ?? ""
        let counts = "\(done) of \(total) · \(progress.completedItems)/\(progress.totalItems) items"
        detailLabel.stringValue = name.isEmpty ? counts : "\(name) — \(counts)"
    }

    func dismiss() {
        window.sheetParent?.endSheet(window)
    }

    @objc private func cancel() {
        detailLabel.stringValue = "Cancelling…"
        onCancel?()
    }
}
