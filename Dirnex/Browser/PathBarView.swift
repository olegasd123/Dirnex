import AppKit
import DirnexCore

/// Owner of a `PathBarView` — the file pane. Navigation and focus decisions stay in
/// the pane (PLAN.md §2 "UI is a thin client"); the bar only reports intent.
@MainActor
protocol PathBarViewDelegate: AnyObject {
    /// A crumb was clicked — navigate straight to this already-real path.
    func pathBar(_ bar: PathBarView, didActivate path: VFSPath)
    /// Edited text was committed with Return. `resolved` is the literal location the text
    /// expands to (tilde/relative resolved); `rawText` is exactly what was typed, so the
    /// pane can fall back to a frecency fuzzy match ("dl" → ~/Downloads) when `resolved`
    /// isn't a real directory (PLAN.md §M3 "path bar accepts fuzzy fragments").
    func pathBar(_ bar: PathBarView, didCommit rawText: String, resolved: VFSPath)
    /// Editing was abandoned (Esc) — the pane should take keyboard focus back.
    func pathBarDidCancel(_ bar: PathBarView)
    /// Text editing began — the pane should become the active one.
    func pathBarDidBeginEditing(_ bar: PathBarView)
    /// Directory names contained directly in `directory`, for path completion. Called
    /// on the main actor; the bar caches the result to answer synchronous completion.
    func pathBar(_ bar: PathBarView, childDirectoriesOf directory: VFSPath) async -> [String]
}

/// The pane's location bar. Two modes over the same footprint:
///
/// - **Breadcrumbs** (default): one clickable button per ancestor, so a click jumps
///   straight to `/Users` or `/Users/oleg` without walking up a level at a time.
/// - **Edit** (Cmd+L): a text field prefilled with the path; Return navigates, Esc
///   reverts, and Tab completes against the child directories of what's typed —
///   shell-style, which is more predictable than a popup on every keystroke.
@MainActor
final class PathBarView: NSView, NSTextFieldDelegate {
    weak var delegate: PathBarViewDelegate?

    /// Bold + accent the current (trailing) crumb when this pane is active.
    var isActive = false {
        didSet { restyleCrumbs() }
    }

    private let crumbStack = NSStackView()
    private let editField = NSTextField()

    private var path: VFSPath?
    private var isEditing = false

    /// The location Cmd+L started from — the base for resolving relative/`~` input.
    private var editBase: VFSPath = .local("/")

    // Completion cache: the directory whose children we last fetched, plus those names.
    private var completionDirectory: VFSPath?
    private var completionChildren: [String] = []
    /// Guards the field editor's `complete(_:)` against re-entrant text-change events.
    private var isCompleting = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 20)
    }

    /// A double-click on the bar's empty area enters text-edit mode — the mouse-driven
    /// equivalent of Cmd+L "Go to Location". Clicks that land on a crumb are consumed by
    /// the button (single-click navigates), so only the gap propagates here; single clicks
    /// still fall through so nothing changes for an ordinary tap.
    override func mouseDown(with event: NSEvent) {
        // A double-click enters text-edit mode, but only for a real (local) location — a virtual
        // results path isn't a directory the user can retype.
        guard !isEditing, event.clickCount == 2, let path, path.backend == .local else {
            super.mouseDown(with: event)
            return
        }
        beginEditing(base: path)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .vertical)

        crumbStack.orientation = .horizontal
        crumbStack.alignment = .centerY
        crumbStack.spacing = 1
        crumbStack.translatesAutoresizingMaskIntoConstraints = false

        editField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editField.isBordered = true
        editField.bezelStyle = .roundedBezel
        editField.focusRingType = .none
        editField.delegate = self
        editField.isHidden = true
        editField.translatesAutoresizingMaskIntoConstraints = false
        editField.usesSingleLineMode = true
        editField.lineBreakMode = .byTruncatingHead

        addSubview(crumbStack)
        addSubview(editField)
        NSLayoutConstraint.activate([
            crumbStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            crumbStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            crumbStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            editField.leadingAnchor.constraint(equalTo: leadingAnchor),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    // MARK: - Breadcrumb mode

    /// Rebuild the crumb row for `path`. A no-op when the path is unchanged, so it's
    /// cheap to call from the pane's per-keystroke chrome refresh — and, crucially, a
    /// background refresh that re-reports the same location never disturbs an open Cmd+L
    /// edit field. A genuine change rebuilds, dropping out of edit mode first if it was
    /// active (the location moved underneath the editor).
    func setPath(_ path: VFSPath, archiveAncestry: [VFSPath] = []) {
        guard self.path != path else { return }
        self.path = path
        if isEditing { endEditing(restoreFocus: false) }
        rebuildContents(for: path, archiveAncestry: archiveAncestry)
    }

    private func rebuildCrumbs(for path: VFSPath) {
        for view in crumbStack.arrangedSubviews {
            crumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let ancestors = path.ancestorsFromRoot
        for (index, ancestor) in ancestors.enumerated() {
            if index > 0 {
                crumbStack.addArrangedSubview(makeSeparator())
            }
            let isLast = index == ancestors.count - 1
            let button = makeCrumb(for: ancestor, isCurrent: isLast)
            // The path bar must never widen the pane — only the user's divider sets pane
            // width (the panes' split items hold at priority 250). So every crumb resists
            // compression *below* 250: a long path truncates within the pane instead of
            // pushing the divider out. Leading crumbs yield first (lowest, graduated so the
            // leftmost/oldest goes first); the current directory (trailing) yields last so
            // it stays legible longest, but it still yields rather than force the pane wider.
            let resistance = isLast
                ? NSLayoutConstraint.Priority(240)
                : NSLayoutConstraint.Priority(Float(100 + min(index, 90)))
            button.setContentCompressionResistancePriority(resistance, for: .horizontal)
            crumbStack.addArrangedSubview(button)
        }

        // A greedy trailing spacer keeps the crumbs packed to the left.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crumbStack.addArrangedSubview(spacer)
    }

    private func makeCrumb(for path: VFSPath, isCurrent: Bool) -> NSButton {
        let title = path.isRoot ? "Macintosh HD" : path.lastComponent
        let button = NSButton(title: title, target: self, action: #selector(crumbClicked(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.setButtonType(.momentaryChange)
        button.controlSize = .small
        button.lineBreakMode = .byTruncatingTail
        button.imagePosition = .noImage
        button.identifier = NSUserInterfaceItemIdentifier(path.path)
        styleCrumb(button, isCurrent: isCurrent)
        return button
    }

    private func styleCrumb(_ button: NSButton, isCurrent: Bool) {
        if isCurrent {
            button.contentTintColor = isActive ? .controlAccentColor : .labelColor
            button.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        } else {
            button.contentTintColor = .secondaryLabelColor
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
    }

    private func restyleCrumbs() {
        let buttons = crumbStack.arrangedSubviews.compactMap { $0 as? NSButton }
        for (index, button) in buttons.enumerated() {
            styleCrumb(button, isCurrent: index == buttons.count - 1)
        }
    }

    private func makeSeparator() -> NSTextField {
        let label = NSTextField(labelWithString: "›")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        // A divider must never be the thing that collapses when the path overflows — a
        // crumb row without its `›`s reads as one run-on name. Resist compression harder
        // than the leading crumbs (which truncate their tails instead), so every visible
        // crumb stays flanked by its separators — but still below 250 so the separators,
        // like the crumbs, never widen the pane past the user's divider.
        label.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(200),
            for: .horizontal
        )
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    @objc private func crumbClicked(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue else { return }
        delegate?.pathBar(
            self,
            didActivate: VFSPath(backend: (path ?? .local("/")).backend, path: identifier)
        )
    }

    // MARK: - Edit mode

    /// Enter Cmd+L text-edit mode, prefilled with `base` and fully selected.
    func beginEditing(base: VFSPath) {
        guard !isEditing else { return }
        isEditing = true
        editBase = base
        completionDirectory = nil
        completionChildren = []

        editField.stringValue = base.path
        crumbStack.isHidden = true
        editField.isHidden = false
        delegate?.pathBarDidBeginEditing(self)
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
    }

    private func endEditing(restoreFocus: Bool) {
        guard isEditing else { return }
        isEditing = false
        editField.isHidden = true
        crumbStack.isHidden = false
        if restoreFocus {
            delegate?.pathBarDidCancel(self)
        }
    }

    private func commit() {
        let raw = editField.stringValue
        let target = resolvedPath(from: raw)
        endEditing(restoreFocus: false)
        delegate?.pathBar(self, didCommit: raw, resolved: target)
    }

    /// Resolve typed text into a location: expand a leading `~`, and treat non-absolute
    /// input as relative to the directory Cmd+L was pressed in.
    private func resolvedPath(from text: String) -> VFSPath {
        var full = (text as NSString).expandingTildeInPath
        if full.isEmpty {
            full = editBase.path
        } else if !full.hasPrefix("/") {
            full = editBase.path + "/" + full
        }
        return VFSPath(backend: editBase.backend, path: full)
    }

    // MARK: - Completion

    /// The directory to complete within and the partial name being typed, derived from
    /// the raw text so a trailing slash (list all children) is distinct from a partial.
    private func completionContext(for text: String) -> (directory: VFSPath, partial: String) {
        let full = (text as NSString).expandingTildeInPath
        let absolute = full.hasPrefix("/") ? full : editBase.path + "/" + full
        if let slash = absolute.range(of: "/", options: .backwards) {
            let directory = VFSPath(
                backend: editBase.backend,
                path: String(absolute[..<slash.lowerBound])
            )
            let partial = String(absolute[slash.upperBound...])
            return (directory, partial)
        }
        return (editBase, absolute)
    }

    private func requestCompletion() {
        let (directory, _) = completionContext(for: editField.stringValue)
        if directory == completionDirectory {
            showCompletions()
            return
        }
        completionDirectory = directory
        Task { [weak self] in
            guard let self else { return }
            let names = await delegate?.pathBar(self, childDirectoriesOf: directory) ?? []
            guard isEditing, completionDirectory == directory else { return }
            completionChildren = names
            showCompletions()
        }
    }

    private func showCompletions() {
        guard isEditing, let editor = editField.currentEditor() else { return }
        isCompleting = true
        editor.complete(nil)
        isCompleting = false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Losing first responder (a click on the table or the other pane) abandons the
        // edit and drops back to breadcrumbs — no commit, no focus grab. Return and Esc
        // reach endEditing through their own paths first, so isEditing is already false
        // by the time this fires for them and it's a no-op.
        endEditing(restoreFocus: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard isEditing, !isCompleting else { return }
        // Warm the completion cache for the directory being typed so Tab is instant,
        // without popping a list on every keystroke.
        let (directory, _) = completionContext(for: editField.stringValue)
        guard directory != completionDirectory else { return }
        completionDirectory = directory
        Task { [weak self] in
            guard let self else { return }
            let names = await delegate?.pathBar(self, childDirectoriesOf: directory) ?? []
            guard isEditing, completionDirectory == directory else { return }
            completionChildren = names
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        let partial = (textView.string as NSString).substring(with: charRange).lowercased()
        return completionChildren.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing(restoreFocus: true)
            return true
        case #selector(NSResponder.insertTab(_:)):
            requestCompletion()
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }
}

// MARK: - Virtual location (search results)

extension PathBarView {
    /// Dispatch the location render by backend: real breadcrumbs for a local directory, a
    /// non-clickable label for a browsed archive or a search-results snapshot. In the
    /// extension so the class body stays under SwiftLint's `type_body_length`.
    func rebuildContents(for path: VFSPath, archiveAncestry: [VFSPath] = []) {
        if path.backend == .local {
            rebuildCrumbs(for: path)
        } else if path.backend.isArchive {
            rebuildArchiveLabel(for: path, ancestry: archiveAncestry)
        } else {
            rebuildVirtualLabel(for: path)
        }
    }

    /// Render a virtual location (Spotlight results) as a single, non-clickable label — there is
    /// no ancestor chain to walk into, so the breadcrumb affordance would only mislead.
    func rebuildVirtualLabel(for path: VFSPath) {
        installVirtualLabel("🔍  Results for \(path.lastComponent)")
    }

    /// Render a browsed archive as a non-clickable "📦  pkg.zip ▸ folder ▸ nested" trail — the
    /// archive's own name (from its backend id) plus the inner path. Non-clickable like the
    /// search label; the `..` row and Backspace walk back up (and out).
    ///
    /// For a nested archive (§M4), `ancestry` carries the enclosing members outermost-first, so
    /// the trail spans the whole chain — "outer.zip ▸ sub ▸ inner.zip ▸ …" — instead of showing
    /// only the innermost archive's (temp) name. Empty for a top-level archive.
    func rebuildArchiveLabel(for path: VFSPath, ancestry: [VFSPath] = []) {
        func components(_ innerPath: String) -> [String] {
            innerPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }
        var segments: [String] = []
        if let outermost = ancestry.first,
           let outerName = (outermost.backend.archivePath as NSString?)?.lastPathComponent {
            // The outermost archive's own name, then each ancestor member's inner path — every
            // ancestor's last component is the next inner archive, so the chain reads naturally.
            segments.append(outerName)
            segments += ancestry.flatMap { components($0.path) }
        } else {
            segments.append((path.backend.archivePath as NSString?)?.lastPathComponent ?? "Archive")
        }
        segments += components(path.path)
        installVirtualLabel("📦  \(segments.joined(separator: "  ▸  "))")
    }

    /// Shared shell for a single non-clickable path-bar label (search results or an archive):
    /// swap the crumb row for one bold, truncating label plus a trailing spacer.
    private func installVirtualLabel(_ text: String) {
        for view in crumbStack.arrangedSubviews {
            crumbStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        // Like the crumb row, the label truncates within the pane rather than widening it
        // past the user's divider — resist below the split items' 250 holding priority.
        label.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(240),
            for: .horizontal
        )
        crumbStack.addArrangedSubview(label)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        crumbStack.addArrangedSubview(spacer)
    }
}
