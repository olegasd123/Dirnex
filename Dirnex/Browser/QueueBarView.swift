import AppKit
import DirnexCore

/// The window-bottom queue bar (PLAN.md §M2 "Progress UI"): a non-blocking readout of the
/// shared `FileOperationQueue`. Unlike the old modal progress sheet, it lets the user keep
/// browsing while a large transfer runs in the background — TC's killer feature.
///
/// A deliberately compact first cut: what's happening, an aggregate determinate bar, a
/// byte/throughput/ETA readout, and pause/resume + cancel-all buttons. The expandable
/// per-job list is the remaining M2 UI work; the bar itself renders from a `QueueSnapshot`
/// and knows nothing about the queue actor — the window controller feeds it and wires the
/// buttons back.
@MainActor
final class QueueBarView: NSView {
    /// The bar's height when shown; the window controller collapses it to zero when idle.
    static let preferredHeight: CGFloat = 42

    /// Fired when the pause/resume button is clicked; the window controller toggles the
    /// queue. The bar doesn't own queue state — it re-renders from the next snapshot.
    var onPauseToggle: (() -> Void)?
    /// Fired when the cancel-all button is clicked.
    var onCancelAll: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let pauseButton = NSButton()
    private let cancelButton = NSButton()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small

        configure(
            pauseButton,
            symbol: "pause.fill",
            accessibility: "Pause",
            action: #selector(pauseClicked)
        )
        configure(
            cancelButton,
            symbol: "xmark.circle.fill",
            accessibility: "Cancel all",
            action: #selector(cancelClicked)
        )

        let stack = NSStackView(views: [statusLabel, bar, detailLabel, pauseButton, cancelButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // A hairline separator divides the bar from the panes above it.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 160)
        ])
    }

    private func configure(
        _ button: NSButton,
        symbol: String,
        accessibility: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .toolbar
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = accessibility
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Rendering

    /// Render the current state of the queue. The window controller decides visibility (it
    /// hides the bar when the queue is idle); this just fills in the content.
    func update(with snapshot: QueueSnapshot) {
        let aggregate = snapshot.aggregate
        bar.doubleValue = aggregate.fraction
        statusLabel.stringValue = statusText(for: snapshot)
        detailLabel.stringValue = detailText(for: aggregate, paused: snapshot.isPaused)

        let symbol = snapshot.isPaused ? "play.fill" : "pause.fill"
        let title = snapshot.isPaused ? "Resume" : "Pause"
        pauseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        pauseButton.toolTip = title
    }

    private func statusText(for snapshot: QueueSnapshot) -> String {
        let active = snapshot.jobs.filter { $0.status == .running || $0.status == .paused }
        let pending = snapshot.jobs.filter { $0.status == .waiting }.count

        var text: String
        if let current = active.first {
            let verb = current.kind == .copy ? "Copying" : "Moving"
            if let name = current.progress?.currentItem?.lastComponent, !name.isEmpty {
                text = "\(verb) \(name)"
            } else {
                text = "\(verb)…"
            }
        } else {
            text = "Preparing…"
        }
        if snapshot.isPaused { text = "Paused — \(text)" }

        let more = max(0, active.count - 1) + pending
        if more > 0 { text += "  (+\(more) more)" }
        return text
    }

    private func detailText(for aggregate: AggregateProgress, paused: Bool) -> String {
        let done = Self.byteFormatter.string(fromByteCount: aggregate.completedBytes)
        let total = Self.byteFormatter.string(fromByteCount: aggregate.totalBytes)
        var parts = ["\(done) of \(total)"]
        if !paused, aggregate.bytesPerSecond > 0 {
            let rate = Self.byteFormatter.string(fromByteCount: Int64(aggregate.bytesPerSecond))
            parts.append("\(rate)/s")
            if let eta = aggregate.estimatedTimeRemaining, let text = Self.etaFormatter.string(
                from: eta
            ) {
                parts.append("\(text) left")
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    @objc private func pauseClicked() { onPauseToggle?() }
    @objc private func cancelClicked() { onCancelAll?() }
}
