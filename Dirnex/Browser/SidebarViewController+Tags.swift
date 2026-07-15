import AppKit
import DirnexCore

/// The sidebar's Tags section (PLAN.md §M6 "Finder tags: … filter chips in search") — Finder's own
/// bottom-of-the-sidebar list of coloured tags, each one a click away from every file carrying it.
/// Split out of `SidebarViewController` so that file stays under the length limit, exactly as the
/// saved-search and server sections are; the main file's `rebuild`, `viewFor` and `rowClicked`
/// dispatch here.
///
/// **A tag row is a search, not a place.** There is no directory of tagged files to navigate to, so
/// a click runs the `SpotlightQuery` that finds them and lands the hits in a virtual results tab —
/// the same machinery a saved search uses, which is why this needed no new panel code at all.
///
/// **Why the section is gated on View ▸ Show Tags.** The preference already means "tags are part of
/// how I work" everywhere else (it installs the dots in the panes, and `PanelViewController+Tags`
/// scans only when it is on). Since the scan is what discovers custom tags, a Tags section shown
/// while the preference is off would be stuck at the stock seven forever — the toggle and the
/// section's usefulness are the same switch, so it gates both.
extension SidebarViewController {
    // MARK: - Rows

    /// The Tags section, or nothing at all when the user has turned tags off.
    ///
    /// The stock seven always show: they exist on every Mac, before anything has been scanned, so
    /// the section is never empty-and-useless the way one built purely from sightings would be.
    /// Custom tags join them once `showsAllTags` is set.
    func tagRows() -> [Row] {
        guard AppPreferences.shared.showTags else {
            renderedTagNames = []
            return []
        }
        let all = FinderTagProvider.shared.knownTags
        renderedTagNames = Set(all.map(\.name))

        var rows: [Row] = [.header("Tags")]
        rows.append(contentsOf: (showsAllTags ? all : FinderTag.systemTags).map(Row.tag))
        // "All Tags…" only when there is something behind it. Finder can always offer it because it
        // knows every tag you own; we know the ones we have seen, so offering to reveal nothing
        // would be a row that does nothing when clicked — worse than no row.
        if !showsAllTags, all.count > FinderTag.systemTags.count {
            rows.append(.allTags)
        }
        return rows
    }

    // MARK: - Cells

    /// A tag row: its colour as a dot where the other sections put an icon, and its name.
    ///
    /// The dot is **not** a template image, unlike every other glyph in the sidebar — those are
    /// tinted to match their label, which for a tag would erase the one thing it has to say. It is
    /// the same `TagDotStyle` the name-cell dots and the ⌃T menu items draw, so a colour reads
    /// identically everywhere; a colourless custom tag gets that style's hollow ring.
    func tagCell(for tag: FinderTag) -> NSView {
        let cell = tagRowCell()
        cell.configure(
            name: tag.name,
            image: TagDotStyle.menuImage(for: tag.color, diameter: 12),
            canEject: false,
            tooltip: "Find files tagged “\(tag.name)”"
        )
        return cell
    }

    /// The "All Tags…" row — reveals the custom tags found while browsing.
    func allTagsCell() -> NSView {
        let cell = tagRowCell()
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = NSImage(
            systemSymbolName: "circle.on.circle",
            accessibilityDescription: "All tags"
        )?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        cell.configure(
            name: "All Tags…",
            image: image ?? NSImage(),
            canEject: false,
            tooltip: "Show every tag found while browsing"
        )
        return cell
    }

    /// A reused item cell with the trailing affordances cleared — a tag row has neither an eject
    /// nor a delete, and a recycled cell would otherwise inherit whichever the row before it had.
    private func tagRowCell() -> SidebarCellView {
        let cell = tableView.makeView(
            withIdentifier: SidebarCellView.identifier,
            owner: self
        ) as? SidebarCellView ?? SidebarCellView()
        cell.onEject = nil
        cell.onDelete = nil
        return cell
    }

    // MARK: - Actions

    /// Expand the section to every tag we know of. One-way on purpose: the row it replaces is the
    /// only thing that would collapse it again, and someone who asked to see their tags is not
    /// looking for a way to hide them again — Finder doesn't offer one either.
    func expandAllTags() {
        showsAllTags = true
        rebuild()
    }

    // MARK: - Live updates

    func observeTagChanges() {
        // The preference: the section appears and disappears with the dots in the panes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showTagsPreferenceChanged),
            name: AppPreferences.showTagsDidChange,
            object: nil
        )
        // A scan: a tag used somewhere we had not looked yet joins the list without a relaunch.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(knownTagsMayHaveChanged),
            name: FinderTagProvider.didChangeNotification,
            object: nil
        )
    }

    @objc private func showTagsPreferenceChanged() {
        rebuild()
    }

    /// Rebuild only when the scan actually turned up a tag we had not rendered.
    ///
    /// This fires for **every** directory scan — which is every directory change, in either pane, on
    /// every tab — and the overwhelming majority discover nothing new. Rebuilding the whole sidebar
    /// each time would drop the user's selection on it for no reason at all; the same "is this a
    /// real change?" gate the server-activity observer applies.
    @objc private func knownTagsMayHaveChanged() {
        guard AppPreferences.shared.showTags,
              FinderTagProvider.shared.knownTagNames != renderedTagNames else { return }
        rebuild()
    }
}
