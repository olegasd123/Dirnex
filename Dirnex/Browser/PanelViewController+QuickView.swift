import AppKit
import DirnexCore
import Quartz

/// The embedded Quick View panel (PLAN.md §M4 "Quick view panel"): TC's ⌃Q mode where the
/// *inactive* pane stops showing its file list and instead becomes a live Quick Look preview
/// of the file under the *active* pane's cursor. Distinct from ⌘Y Quick Look, which floats a
/// separate window over the active pane; this replaces the opposite pane in place.
///
/// The window (`BrowserWindowController`) owns the on/off state and decides which pane hosts
/// the preview, since the mode spans both panes and follows the active one. A pane only knows
/// how to (a) surface a preview over its own list and (b) report the file under its cursor.
extension PanelViewController {
    /// ⌃Q / View ▸ Quick View Panel — hand the toggle to the window, which flips the mode and
    /// reconciles both panes.
    @objc func toggleQuickViewPanel(_ sender: Any?) {
        host?.toggleQuickView()
    }

    /// Cover this pane's file list with a live preview of `url` (the file under the *other*
    /// pane's cursor). Lazily builds the overlay on first use. `nil` clears it to a blank
    /// preview — the cursor is on `..` or an empty directory, so there is nothing to show.
    func showQuickViewPreview(of url: URL?) {
        guard let preview = ensureQuickViewPreview() else { return }
        quickViewContainer?.isHidden = false
        guard url != quickViewLoadedURL else { return }
        quickViewLoadedURL = url
        preview.previewItem = url as NSURL?
    }

    /// Uncover the file list, restoring the normal pane. Safe to call when Quick View was
    /// never shown for this pane.
    func hideQuickViewPreview() {
        quickViewLoadedURL = nil
        quickViewContainer?.isHidden = true
        quickViewPreview?.previewItem = nil
    }

    /// The file under this pane's cursor as a URL, for the *other* pane to preview — `nil` on
    /// the `..` row or in an empty directory, where there is nothing meaningful to show.
    var quickViewSourceURL: URL? {
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return nil }
        return entry.path.localURL
    }

    /// Build the preview overlay on first use and pin it over the scroll view. The list under
    /// it stays laid out (only covered), so uncovering it needs no relayout. The container is
    /// opaque so a preview that doesn't fill the pane (a small image, a failed preview) can't
    /// let the table bleed through. `.compact` style drops Quick Look's title/controls chrome,
    /// which suits an always-on embedded pane.
    private func ensureQuickViewPreview() -> QLPreviewView? {
        if let preview = quickViewPreview { return preview }
        guard let preview = QLPreviewView(frame: .zero, style: .compact) else { return nil }
        // Closes automatically when the window goes away; the pane lives as long as the window,
        // so there is nothing to tear down by hand.
        preview.shouldCloseWithWindow = true

        // An NSBox filled with the dynamic `textBackgroundColor` supplies the opaque backing and
        // re-resolves the color on a light/dark switch (a captured `cgColor` would not). The
        // preview becomes its content view, filling it edge to edge.
        let container = NSBox()
        container.boxType = .custom
        container.titlePosition = .noTitle
        container.borderWidth = 0
        container.cornerRadius = 0
        container.contentViewMargins = .zero
        container.fillColor = .textBackgroundColor
        container.contentView = preview
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
        quickViewContainer = container
        quickViewPreview = preview
        return preview
    }
}
