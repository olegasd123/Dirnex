import AppKit
import DirnexCore

/// The Finder-tags gutter cell: a row of coloured dots (PLAN.md §M6 "Finder tags: column…").
///
/// Custom-drawn rather than an `NSTextField` like `FileCellView`, because the content *is* the
/// colour — there is no text here for a text colour to carry, which is also why this doesn't
/// borrow `FileCellView.accentColor` the way the Git letter does.
final class TagCellView: NSTableCellView {
    /// The row's tags, in stored order. Setting them redraws and re-tooltips.
    var tags: [FinderTag] = [] {
        didSet {
            needsDisplay = true
            // The dots say *how many* and *which colours*; only this says which tags. It also
            // covers the two cases the drawing can't: a fourth tag beyond `maximumDots`, and
            // several tags sharing one colour.
            toolTip = tags.isEmpty ? nil : tags.map(\.name).joined(separator: ", ")
        }
    }

    /// Fades the cell for a hidden (dot) entry, matching `FileCellView` — the whole row dims
    /// together or the gutter would shout over the name it belongs to.
    var dimmed = false {
        didSet { alphaValue = dimmed ? 0.5 : 1 }
    }

    /// At most three dots. A file with more is real but rare, and four 8 pt dots do not read as a
    /// count any better than three do — past that the eye gives up and the tooltip is the honest
    /// answer. The first three in stored order, which is the order Get Info lists them in.
    private let maximumDots = 3
    private let dotDiameter: CGFloat = 8
    private let dotGap: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The row view sets this when the cursor lands, and the dots have to answer for themselves: a
    /// blue tag on the selection's blue background is invisible.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let drawn = Array(tags.prefix(maximumDots))
        guard !drawn.isEmpty else { return }

        let totalWidth = CGFloat(drawn.count) * dotDiameter + CGFloat(drawn.count - 1) * dotGap
        var x = (bounds.width - totalWidth) / 2
        let y = (bounds.height - dotDiameter) / 2
        for tag in drawn {
            draw(tag, in: NSRect(x: x, y: y, width: dotDiameter, height: dotDiameter))
            x += dotDiameter + dotGap
        }
    }

    private func draw(_ tag: FinderTag, in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        circle.lineWidth = 1

        if let fill = TagDotStyle.color(for: tag.color) {
            fill.setFill()
            circle.fill()
        } else {
            // A colourless tag (`Work` with no colour) gets a hollow ring. Finder draws *nothing*
            // for one, which it can afford to: its dots sit beside the name, so their absence just
            // means "no colour here". In a column of its own, drawing nothing says "untagged" —
            // a lie about a file the user did tag, and one they'd have no way to catch.
            TagDotStyle.colorlessStroke.setStroke()
            circle.stroke()
        }

        // On the cursor's emphasized background, ring each dot in the selection's text colour:
        // otherwise a blue tag vanishes into blue, and a grey one into grey.
        if backgroundStyle == .emphasized {
            NSColor.alternateSelectedControlTextColor.setStroke()
            circle.stroke()
        }
    }
}

/// How a tag colour is painted. The eight indices are Apple's (`FinderTagColor` in the core, which
/// picks the *index*); these are the system colours that match what Finder shows for each — the
/// same core-decides-meaning / app-decides-pixels split as `GitStatusStyle`.
enum TagDotStyle {
    /// The fill for a tag's dot, or `nil` for `.none` — which has no colour to draw and is rendered
    /// as a ring instead. System colours throughout, so the dots track the user's appearance and
    /// accessibility settings rather than freezing eight literals.
    static func color(for color: FinderTagColor) -> NSColor? {
        switch color {
        case .none: nil
        case .grey: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }

    /// The ring for a colourless tag — present, but deliberately quiet: it marks the file as tagged
    /// without competing with the tags that chose a colour.
    static let colorlessStroke: NSColor = .tertiaryLabelColor

    /// A dot as a menu-item image, for the tag editor's items. Same geometry as the column's, so a
    /// colour reads identically in both places.
    static func menuImage(for color: FinderTagColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            circle.lineWidth = 1
            if let fill = Self.color(for: color) {
                fill.setFill()
                circle.fill()
            } else {
                Self.colorlessStroke.setStroke()
                circle.stroke()
            }
            return true
        }
    }
}
