import Foundation

// Finder tags (PLAN.md §M6 "Finder tags: column, edit from panel, filter chips in search").
//
// This is the pure value half: what a tag *is*, and how it is spelled in the extended attribute
// macOS stores it in. No disk, no AppKit — reading and writing the attribute lives in
// `FinderTagStorage`, and the colour → NSColor mapping lives in the app, exactly as `GitFileStatus`
// picks the letter and the app picks the colour.
//
// The format below was not taken from documentation; it was **probed against real tagged files**
// before any of this was written (the pass-1 `git` lesson, and the pass-7 `SFTPListingParser`
// rework that followed from *assuming* a format). Everything asserted here was observed:
// `com.apple.metadata:_kMDItemUserTags` is a **binary plist array of strings**, each one
// `name\ncolourIndex`.

// MARK: - Colour

/// The colour a tag carries, as macOS indexes them inside the stored attribute.
///
/// The indices are Apple's, and they are **not** the order Finder displays tags in: the
/// `FavoriteTagNames` list in `com.apple.finder` reads Red, Orange, Yellow, Green, Blue, Purple,
/// Grey, which is a *display* order and tempting to mistake for this one. The real mapping was
/// established by letting the system assign each colour itself — writing the bare name `Red`
/// through `URLResourceValues.tagNames` and reading back what index it chose (`Red` → 6).
public enum FinderTagColor: Int, Sendable, Hashable, CaseIterable, Codable {
    /// No colour — the label a custom tag gets when it is not one of the seven system tags.
    /// This is a real stored value (`Zebra\n0`), not the absence of a colour field.
    case none = 0
    case grey = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    /// The user-facing colour name, for a menu item or a swatch tooltip.
    public var title: String {
        switch self {
        case .none: return "No Colour"
        case .grey: return "Grey"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

    /// The name of the stock system tag carrying this colour, or `nil` for `.none`.
    ///
    /// These seven are the tags macOS ships with, and the only names the system itself knows a
    /// colour for (see `FinderTagStorage` on why that lookup is something we must *not* rely on
    /// when writing). Note the spelling: `Grey` resolves to a colour, `Gray` does not — it is
    /// simply an unknown custom name and lands on `.none`.
    ///
    /// Caveat: these are the English names. On a localized system the stock tags are stored under
    /// their localized spellings, so this is a sensible default set to *offer*, not a claim about
    /// what a given file will hold.
    public var systemTagName: String? {
        self == .none ? nil : title
    }

    /// The seven colours in the order Finder *shows* them — which is emphatically not `allCases`.
    ///
    /// `allCases` runs in raw-value order, i.e. Apple's storage indices (Grey 1 … Orange 7), and
    /// that ordering is meaningless to look at: it opens on Grey and buries Red at the end. This is
    /// the order the `FavoriteTagNames` list in `com.apple.finder` carries, and the one the sidebar
    /// and any tag menu should list — it is a rainbow, so it reads as one, and it is what a user's
    /// muscle memory is already trained on.
    ///
    /// `.none` is deliberately absent: it is a real stored *value* (a custom tag that has no
    /// colour), never a colour anyone picks from a list of colours.
    public static let displayOrder: [FinderTagColor] = [
        .red, .orange, .yellow, .green, .blue, .purple, .grey
    ]
}

// MARK: - Tag

/// One Finder tag: a name, and the colour macOS shows it in.
///
/// **Identity is the name, case-insensitively** — the same name-as-identity rule `SavedSearch` and
/// `ServerConnection` follow, and here it is the system's rule too, not a Dirnex convention:
/// writing the tag `red` (lowercase) stores the name verbatim as typed but resolves it to Red's
/// colour 6, so macOS folds case to identify a tag while preserving the user's spelling. A file
/// therefore cannot meaningfully hold both `Work` and `work`, and an editor offering to add one to
/// a file already carrying the other is offering a no-op.
///
/// **A colour belongs to the name, system-wide — not to the file.** Each file stores a copy, which
/// is what this type reads, but the system keeps its own name → colour database and Finder
/// reconciles against it: a tag whose name it already knows in another colour gets *rewritten on
/// disk* to the colour it knows (observed — a purple `Zebra` written here came back as a colourless
/// `Zebra` once Finder had met the name as colourless). A brand-new name is adopted in the colour
/// it arrives with. So an editor may offer a colour when *introducing* a tag, but must not present
/// per-file colour as something the user owns: re-colouring one file's `Work` is not a change macOS
/// will keep.
public struct FinderTag: Sendable, Hashable, Codable {
    /// The tag name as stored, in the user's own spelling. Never empty.
    public let name: String
    /// The colour macOS renders the tag in. A custom tag with no colour is `.none`.
    public let color: FinderTagColor

    public init(name: String, color: FinderTagColor = .none) {
        self.name = name
        self.color = color
    }

    /// The seven tags macOS ships with, in Finder's display order (`FinderTagColor.displayOrder`).
    ///
    /// These are the only tags that exist without anyone having made them, which is what makes them
    /// the right thing to *offer* — in the sidebar's Tags section, or the ⌃T menu — before a single
    /// file has been scanned. Everything past these seven has to be discovered by looking at files.
    public static let systemTags: [FinderTag] = FinderTagColor.displayOrder.compactMap { color in
        color.systemTagName.map { FinderTag(name: $0, color: color) }
    }

    /// Whether this is one of the seven macOS ships with — by name, case-insensitively, since that
    /// is the identity rule `==` already applies.
    ///
    /// The distinction is what makes *deleting* a tag a coherent operation for one kind and not the
    /// other. A custom tag exists only because files carry it, so stripping it from all of them is
    /// deletion. A stock tag exists whether or not anything wears it (`systemTags` is a constant),
    /// so there is nothing there to delete: untag every file on the volume and Red is still offered.
    ///
    /// Carries the same localization caveat as `FinderTagColor.systemTagName` — these are the
    /// English names, so on a localized system a stock tag stored under its localized spelling reads
    /// as custom here.
    public var isSystem: Bool {
        Self.systemTags.contains(self)
    }

    // Name-as-identity, case-insensitive: the colour is deliberately excluded. Two tags spelled
    // the same *are* the same tag — a file holding one twice in different colours is malformed,
    // not two tags — so a `Set<FinderTag>` and `contains` dedupe the way the user expects.
    public static func == (lhs: FinderTag, rhs: FinderTag) -> Bool {
        lhs.name.lowercased() == rhs.name.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name.lowercased())
    }

    // MARK: - The stored spelling

    /// Parse one entry of the stored attribute array, `nil` when it is unusable.
    ///
    /// The format is `name\ncolourIndex`, and both traps here were observed rather than guessed:
    ///
    /// - **The colour field is optional.** A bare `Plainname` with no newline at all round-trips
    ///   through the system's own reader, so it must parse rather than be discarded.
    /// - **There can be a third field.** Passing an already-suffixed string such as `Red\n6` to
    ///   `URLResourceValues.tagNames` makes the system treat the *whole thing* as the name and
    ///   append its own colour lookup, storing `Red\n6\n0`. Files carrying that shape exist in the
    ///   wild wherever a tool made that mistake, and the system reads them back as plain `Red`, so
    ///   fields past the colour are ignored here too rather than failing the row.
    ///
    /// A malformed colour index (non-numeric, or outside 0...7) degrades to `.none` instead of
    /// rejecting the tag: the name is the part that carries meaning, and dropping a real tag
    /// because its colour byte is nonsense would hide the tag entirely.
    public init?(storedString: String) {
        let fields = storedString.components(separatedBy: "\n")
        guard let name = fields.first, !name.isEmpty else { return nil }
        let color = fields.count > 1 ? (
            Int(fields[1]).flatMap(FinderTagColor.init(rawValue:)) ?? .none
        ) : .none
        self.init(name: name, color: color)
    }

    /// How this tag is spelled inside the stored attribute.
    ///
    /// The colour field is written **always, including `\n0`** for a colourless tag, because that
    /// is what the system itself emits (`Zebra` → `Zebra\n0`). Matching its output byte-for-byte
    /// is the cheapest way to stay interoperable with a reader that is stricter than Finder's.
    public var storedString: String {
        "\(name)\n\(color.rawValue)"
    }
}

// MARK: - The stored attribute

/// The `com.apple.metadata:_kMDItemUserTags` payload: a binary plist array of `name\ncolour`
/// strings. Kept separate from the I/O in `FinderTagStorage` so the encoding — the part with the
/// traps in it — is testable without touching a filesystem.
public enum FinderTagPayload {
    /// Decode an attribute payload into tags, discarding entries that are unusable.
    ///
    /// Malformed entries are **skipped, never thrown on**, the same call `GitStatusParser` makes:
    /// a file whose tag list holds one bad row should still show its other tags, whereas throwing
    /// blanks the whole cell. A payload that is not a plist array of strings at all yields `[]` —
    /// the attribute is someone else's data, and there is nothing to show.
    ///
    /// Duplicates are collapsed (first spelling wins). The system does not dedupe on write —
    /// `tagNames = ["Red", "Red"]` stores Red twice — so a file can genuinely arrive holding one
    /// tag repeated, and a column rendering it twice would just look broken.
    public static func decode(_ data: Data) -> [FinderTag] {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let strings = list as? [String]
        else { return [] }

        var seen = Set<FinderTag>()
        return strings.compactMap(FinderTag.init(storedString:)).filter { seen.insert($0).inserted }
    }

    /// Encode tags into an attribute payload, in the binary plist format the system writes.
    ///
    /// Duplicates are collapsed here too, so a caller that appends a tag a file already carries
    /// cannot write the malformed doubled list the system would happily accept.
    public static func encode(_ tags: [FinderTag]) throws -> Data {
        var seen = Set<FinderTag>()
        let strings = tags.filter { seen.insert($0).inserted }.map(\.storedString)
        return try PropertyListSerialization.data(
            fromPropertyList: strings,
            format: .binary,
            options: 0
        )
    }

    /// The legacy Finder label index for a tag list — the colour of the **last tag that has one**,
    /// or 0 when none do.
    ///
    /// This exists because macOS keeps the pre-tags label byte in sync with the tag list, and the
    /// rule is not obvious: given `[Green, Red]` the system stores Red's 6, given `[Red, Orange]`
    /// it stores Orange's 7 — last wins, not lowest, not first — and given `[Zebra, Blue]` it
    /// stores Blue's 4, skipping the colourless tag rather than letting it clear the label. All
    /// four cases were read back off real files; `FinderTagStorage` writes what this returns.
    public static func legacyLabel(for tags: [FinderTag]) -> Int {
        tags.last(where: { $0.color != .none })?.color.rawValue ?? 0
    }
}
