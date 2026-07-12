import AppKit
import DirnexCore

/// The Synchronize Directories sheet (PLAN.md §M5 "Synchronize directories: two-panel diff view
/// … selective sync actions through the queue"). It compares the two panes' folders through the
/// headless `DirectorySync` engine and lists every difference, one row per item, with a default
/// action derived from the chosen direction. The user picks a direction (mirror either way, or
/// both) and a comparison method (size+date or exact content), un-checks any row to leave it
/// alone, and commits — the panel then runs the checked actions through the M2 queue (copies)
/// and Trash (deletes).
///
/// Presented via `presentAsSheet`, which retains it for its on-screen lifetime. All comparison
/// is pure `DirnexCore`; this file is the AppKit shell that binds the controls to a scan and
/// renders the diff. The scan runs off the main thread (content mode reads bytes).
@MainActor
final class SyncDirectoriesController: NSViewController {
    /// One committed choice handed back to the panel: an entry and the action to perform on it.
    struct Decision {
        let entry: SyncEntry
        let action: SyncAction
    }

    private let leftDir: VFSPath
    private let rightDir: VFSPath
    private let backend: any VFSBackend
    /// Handed the checked, actionable decisions when the user commits.
    var onApply: (([Decision]) -> Void)?

    private var direction: SyncDirection = .leftToRight
    private var comparison: SyncComparison = .sizeAndDate
    private var rows: [Row] = []
    private var isScanning = false
    private var scanError: String?

    /// One diff row: the comparison entry, its current action under the chosen direction, and
    /// whether the user has it checked for the run.
    fileprivate struct Row {
        let entry: SyncEntry
        var action: SyncAction
        var included: Bool
    }

    // Controls
    private let headerLabel = NSTextField(labelWithString: "")
    private let directionControl = NSSegmentedControl()
    private let comparisonControl = NSSegmentedControl()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let syncButton = NSButton()

    init(leftDir: VFSPath, rightDir: VFSPath, backend: any VFSBackend) {
        self.leftDir = leftDir
        self.rightDir = rightDir
        self.backend = backend
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        let stack = NSStackView(views: [makeHeader(), makeControls(), makeTable(), makeFooter()])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 720),
            container.heightAnchor.constraint(equalToConstant: 520)
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        startScan()
    }

    // MARK: - Scan

    /// Run the comparison off the main thread (content mode reads bytes), then rebuild the rows.
    /// Called on load and whenever the comparison method changes; a direction change only
    /// re-derives actions in memory (`recomputeActions`) without re-reading the folders.
    private func startScan() {
        isScanning = true
        scanError = nil
        spinner.startAnimation(nil)
        updateChrome()
        let backend = backend
        let left = leftDir
        let right = rightDir
        let comparison = comparison
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<
                [SyncEntry],
                any Error
            > in
                do {
                    return .success(try DirectorySync.compare(
                        left: left, right: right,
                        leftBackend: backend, rightBackend: backend,
                        comparison: comparison
                    ))
                } catch {
                    return .failure(error)
                }
            }.value
            finishScan(outcome)
        }
    }

    private func finishScan(_ outcome: Result<[SyncEntry], any Error>) {
        isScanning = false
        spinner.stopAnimation(nil)
        switch outcome {
        case let .success(entries):
            rows = entries.map { entry in
                let action = DirectorySync.defaultAction(for: entry.status, direction: direction)
                return Row(entry: entry, action: action, included: isActionable(action))
            }
        case let .failure(error):
            rows = []
            scanError = (error as? VFSError).map(describe) ?? "The folders couldn’t be compared."
        }
        tableView.reloadData()
        updateChrome()
    }

    // MARK: - Actions

    @objc private func directionChanged(_ sender: NSSegmentedControl) {
        direction = [.leftToRight, .bidirectional, .rightToLeft][max(0, sender.selectedSegment)]
        recomputeActions()
    }

    @objc private func comparisonChanged(_ sender: NSSegmentedControl) {
        comparison = sender.selectedSegment == 1 ? .content : .sizeAndDate
        startScan()
    }

    /// Re-derive every row's action for the new direction and reset the check state to that
    /// action's default (a direction flip changes what each row *means*, so a fresh default is
    /// less surprising than preserving stale checks).
    private func recomputeActions() {
        rows = rows.map { row in
            let action = DirectorySync.defaultAction(for: row.entry.status, direction: direction)
            return Row(entry: row.entry, action: action, included: isActionable(action))
        }
        tableView.reloadData()
        updateChrome()
    }

    @objc private func toggleInclude(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].included = sender.state == .on
        updateChrome()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(sender)
    }

    @objc private func apply(_ sender: Any?) {
        let decisions = rows
            .filter { $0.included && isActionable($0.action) }
            .map { Decision(entry: $0.entry, action: $0.action) }
        guard !decisions.isEmpty else { return }
        onApply?(decisions)
        dismiss(sender)
    }

    // MARK: - Chrome

    private func updateChrome() {
        directionControl.isEnabled = !isScanning
        comparisonControl.isEnabled = !isScanning
        if isScanning {
            setStatus("Comparing folders…", isError: false)
            syncButton.isEnabled = false
            return
        }
        if let scanError {
            setStatus(scanError, isError: true)
            syncButton.isEnabled = false
            return
        }
        if rows.isEmpty {
            setStatus("The folders are already in sync.", isError: false)
            syncButton.isEnabled = false
            return
        }
        let checked = rows.filter { $0.included && isActionable($0.action) }
        let copies = checked.filter { isCopy($0.action) }.count
        let deletes = checked.count - copies
        let conflicts = rows.filter { $0.action == .conflict }.count
        var text = "\(copies) to copy, \(deletes) to delete"
        if conflicts > 0 { text += " · \(conflicts) conflict\(conflicts == 1 ? "" : "s") skipped" }
        setStatus(text, isError: false)
        syncButton.isEnabled = !checked.isEmpty
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Row model access (for the table extension)

    fileprivate var rowCount: Int { rows.count }

    fileprivate func row(at index: Int) -> Row? {
        rows.indices.contains(index) ? rows[index] : nil
    }

    // MARK: - Helpers

    private func isActionable(_ action: SyncAction) -> Bool {
        action != .none && action != .conflict
    }

    private func isCopy(_ action: SyncAction) -> Bool {
        action == .copyToRight || action == .copyToLeft
    }

    private func abbreviate(_ path: VFSPath) -> String {
        (path.path as NSString).abbreviatingWithTildeInPath
    }

    private func describe(_ error: VFSError) -> String {
        switch error {
        case .notFound: return "One of the folders no longer exists."
        case .permissionDenied: return "Permission was denied reading one of the folders."
        default: return "The folders couldn’t be compared."
        }
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        if width > 0 {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return view
    }
}

// MARK: - View construction

private extension SyncDirectoriesController {
    func makeHeader() -> NSView {
        headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.stringValue = "\(abbreviate(leftDir))   ⟷   \(abbreviate(rightDir))"
        headerLabel.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return headerLabel
    }

    func makeControls() -> NSView {
        for (index, title) in ["Left → Right", "Both Directions", "Right → Left"].enumerated() {
            directionControl.segmentCount = 3
            directionControl.setLabel(title, forSegment: index)
        }
        directionControl.selectedSegment = 0
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))

        for (index, title) in ["Size & Date", "Content"].enumerated() {
            comparisonControl.segmentCount = 2
            comparisonControl.setLabel(title, forSegment: index)
        }
        comparisonControl.selectedSegment = 0
        comparisonControl.target = self
        comparisonControl.action = #selector(comparisonChanged(_:))

        let row = NSStackView(views: [
            label("Direction:"), directionControl,
            spacer(width: 16),
            label("Compare by:"), comparisonControl
        ])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    func makeTable() -> NSView {
        addColumn("include", title: "", width: 26)
        addColumn("name", title: "Item", width: 300)
        addColumn("left", title: leftDir.lastComponent, width: 130)
        addColumn("action", title: "", width: 60)
        addColumn("right", title: rightDir.lastComponent, width: 130)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 680).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
        return scrollView
    }

    func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    func makeFooter() -> NSView {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc

        syncButton.title = "Synchronize"
        syncButton.bezelStyle = .rounded
        syncButton.keyEquivalent = "\r"
        syncButton.target = self
        syncButton.action = #selector(apply(_:))

        let footer = NSStackView(views: [statusLabel, spacer(width: 0), cancelButton, syncButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return footer
    }
}

// MARK: - Diff table

extension SyncDirectoriesController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
}

extension SyncDirectoriesController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let data = self.row(at: row) else { return nil }
        switch column.identifier.rawValue {
        case "include": return includeCheckbox(
                included: data.included,
                action: data.action,
                row: row
            )
        case "name": return nameCell(for: data.entry)
        case "left": return detailCell(for: data.entry.left)
        case "action": return actionCell(for: data.action)
        case "right": return detailCell(for: data.entry.right)
        default: return nil
        }
    }

    private func includeCheckbox(included: Bool, action: SyncAction, row: Int) -> NSView {
        let button = NSButton(
            checkboxWithTitle: "",
            target: self,
            action: #selector(toggleInclude(_:))
        )
        button.tag = row
        button.state = included ? .on : .off
        button.isEnabled = isActionable(action)
        return button
    }

    private func nameCell(for entry: SyncEntry) -> NSView {
        let name = entry.isDirectory ? entry.relativePath + "/" : entry.relativePath
        let field = NSTextField(labelWithString: name)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = entry.relativePath
        return field
    }

    private func detailCell(for entry: FileEntry?) -> NSView {
        guard let entry else {
            let dash = NSTextField(labelWithString: "—")
            dash.textColor = .tertiaryLabelColor
            return dash
        }
        let size = entry.isDirectory ? "folder" : FileFormatting.sizeString(for: entry)
        let field = NSTextField(
            labelWithString: size + " · " + FileFormatting.dateString(for: entry)
        )
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = field.stringValue
        return field
    }

    private func actionCell(for action: SyncAction) -> NSView {
        let display = actionDisplay(action)
        let field = NSTextField(labelWithString: display.glyph)
        field.alignment = .center
        field.textColor = display.color
        field.toolTip = display.tip
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    /// Glyph, colour, and tooltip for an action's cell — an arrow toward the side that changes
    /// for a copy, a red ✕ for a delete (which side is clear from the populated detail column),
    /// and a warning for a conflict the run skips.
    private func actionDisplay(_ action: SyncAction) -> ActionStyle {
        switch action {
        case .copyToRight: return ActionStyle("→", .systemGreen, "Copy to \(rightDir.lastComponent)")
        case .copyToLeft: return ActionStyle("←", .systemGreen, "Copy to \(leftDir.lastComponent)")
        case .deleteRight: return ActionStyle(
                "✕",
                .systemRed,
                "Delete from \(rightDir.lastComponent)"
            )
        case .deleteLeft: return ActionStyle("✕", .systemRed, "Delete from \(leftDir.lastComponent)")
        case .conflict: return ActionStyle("⚠", .systemOrange, "Conflict — left unchanged")
        case .none: return ActionStyle("=", .tertiaryLabelColor, "Identical")
        }
    }
}

/// The rendered appearance of one row's action, in the diff table's action column.
private struct ActionStyle {
    let glyph: String
    let color: NSColor
    let tip: String

    init(_ glyph: String, _ color: NSColor, _ tip: String) {
        self.glyph = glyph
        self.color = color
        self.tip = tip
    }
}
