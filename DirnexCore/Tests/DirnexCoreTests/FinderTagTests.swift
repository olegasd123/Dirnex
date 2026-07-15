import Foundation
import Testing

@testable import DirnexCore

@Suite("FinderTagColor")
struct FinderTagColorTests {
    /// The mapping is the whole point of the type and the easiest thing to get subtly wrong, so it
    /// is pinned outright. These indices are not a guess: each was read back off a real file after
    /// letting macOS assign the colour itself from the bare tag name.
    @Test("colour indices are the ones macOS actually assigns")
    func indices() {
        #expect(FinderTagColor.none.rawValue == 0)
        #expect(FinderTagColor.grey.rawValue == 1)
        #expect(FinderTagColor.green.rawValue == 2)
        #expect(FinderTagColor.purple.rawValue == 3)
        #expect(FinderTagColor.blue.rawValue == 4)
        #expect(FinderTagColor.yellow.rawValue == 5)
        #expect(FinderTagColor.red.rawValue == 6)
        #expect(FinderTagColor.orange.rawValue == 7)
    }

    /// Guards against "fixing" these indices into Finder's `FavoriteTagNames` display order, which
    /// runs Red, Orange, Yellow, Green, Blue, Purple, Grey and looks far more like a sensible
    /// enumeration than the real thing does.
    @Test("indices are not Finder's display order")
    func notDisplayOrder() {
        #expect(FinderTagColor.displayOrder.map(\.rawValue) != Array(1...7))
    }

    /// The order itself, pinned: it is what the sidebar and the tag menu list, and the whole reason
    /// it exists is that reaching for `allCases` instead is both easy and wrong.
    @Test("display order is Finder's rainbow, and covers every colour exactly once")
    func displayOrder() {
        #expect(
            FinderTagColor.displayOrder == [.red, .orange, .yellow, .green, .blue, .purple, .grey]
        )
        // Every real colour, none twice, and never `.none` — which is a stored value, not a choice.
        #expect(Set(FinderTagColor.displayOrder).count == FinderTagColor.displayOrder.count)
        #expect(
            Set(FinderTagColor.displayOrder) == Set(FinderTagColor.allCases).subtracting([.none])
        )
    }

    @Test("every colour but none names a stock system tag")
    func systemTagNames() {
        #expect(FinderTagColor.none.systemTagName == nil)
        #expect(FinderTagColor.red.systemTagName == "Red")
        #expect(FinderTagColor.grey.systemTagName == "Grey")
        for color in FinderTagColor.allCases where color != .none {
            #expect(color.systemTagName != nil)
        }
    }
}

@Suite("FinderTag")
struct FinderTagTests {
    // MARK: - The stock tags

    @Test("the stock tags are the seven system ones, in Finder's order, each in its own colour")
    func systemTags() {
        #expect(FinderTag.systemTags.map(\.name) == [
            "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Grey"
        ])
        #expect(FinderTag.systemTags.map(\.color) == FinderTagColor.displayOrder)
        // Each carries the colour it is named after — the property that lets the sidebar draw a
        // swatch from the tag alone.
        for tag in FinderTag.systemTags {
            #expect(tag.color.systemTagName == tag.name)
        }
    }

    // MARK: - Identity

    /// macOS folds case to identify a tag while storing the user's spelling: writing `red` stores
    /// the name `red` but resolves it to Red's colour 6. So case-insensitive identity is the
    /// system's rule, not a convenience.
    @Test("identity is the name, case-insensitively")
    func caseInsensitiveIdentity() {
        #expect(FinderTag(name: "Work") == FinderTag(name: "work"))
        #expect(FinderTag(name: "Work").hashValue == FinderTag(name: "WORK").hashValue)
        #expect(FinderTag(name: "Work") != FinderTag(name: "Works"))
    }

    /// A file holding one name in two colours is malformed, not two tags — so the colour must stay
    /// out of identity, or a `Set` would keep both and the column would render the name twice.
    @Test("colour is not part of identity")
    func colorExcludedFromIdentity() {
        #expect(FinderTag(name: "Work", color: .red) == FinderTag(name: "Work", color: .blue))
        #expect(
            Set([FinderTag(name: "Work", color: .red), FinderTag(name: "work", color: .blue)]).count == 1
        )
    }

    // MARK: - Parsing

    @Test("the ordinary two-field form")
    func parsesNameAndColor() {
        let tag = FinderTag(storedString: "Red\n6")
        #expect(tag?.name == "Red")
        #expect(tag?.color == .red)
    }

    /// The system emits `Zebra\n0` for a colourless tag, but a bare name with no newline at all
    /// round-trips through its own reader, so both must parse.
    @Test("a colourless tag, spelled either way")
    func parsesColorless() {
        #expect(FinderTag(storedString: "Zebra\n0")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Zebra\n0")?.name == "Zebra")
        #expect(FinderTag(storedString: "Plainname")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Plainname")?.name == "Plainname")
    }

    /// The three-field shape is real: passing an already-suffixed `Red\n6` to the system's own
    /// setter makes it treat the whole string as a name and append its lookup, storing `Red\n6\n0`.
    /// The system reads that back as plain `Red`, so this must too.
    @Test("a stray third field is ignored, as the system ignores it")
    func parsesThreeFieldForm() {
        let tag = FinderTag(storedString: "Red\n6\n0")
        #expect(tag?.name == "Red")
        #expect(tag?.color == .red)
    }

    /// The name is what carries meaning; a nonsense colour byte should cost the colour, not the tag.
    @Test("a malformed colour degrades to none rather than dropping the tag")
    func malformedColorDegrades() {
        #expect(FinderTag(storedString: "Work\nrubbish")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Work\nrubbish")?.name == "Work")
        #expect(FinderTag(storedString: "Work\n99")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Work\n-1")?.color == FinderTagColor.none)
        #expect(FinderTag(storedString: "Work\n99")?.name == "Work")
    }

    @Test("an empty name is not a tag")
    func emptyNameRejected() {
        #expect(FinderTag(storedString: "") == nil)
        #expect(FinderTag(storedString: "\n6") == nil)
    }

    // MARK: - Serializing

    /// The colour field is always written, `\n0` included, because that is what the system emits.
    @Test("round-trips through the stored spelling")
    func roundTrips() {
        #expect(FinderTag(name: "Red", color: .red).storedString == "Red\n6")
        #expect(FinderTag(name: "Zebra").storedString == "Zebra\n0")
        for color in FinderTagColor.allCases {
            let tag = FinderTag(name: "Sample", color: color)
            let reparsed = FinderTag(storedString: tag.storedString)
            #expect(reparsed?.name == "Sample")
            #expect(reparsed?.color == color)
        }
    }

    /// Swift's `String` compares and hashes by canonical equivalence, so a decomposed name off the
    /// filesystem matches a precomposed one out of an attribute for free — the same property pass 1
    /// found load-bearing for Git paths, and worth pinning here for the same reason: it would need
    /// explicit normalization in any byte-keyed language.
    @Test("a decomposed name matches its precomposed spelling")
    func unicodeEquivalence() {
        let decomposed = "cafe\u{0301}"
        let precomposed = "café"
        #expect(decomposed.unicodeScalars.count != precomposed.unicodeScalars.count) // genuinely different bytes
        #expect(FinderTag(name: decomposed) == FinderTag(name: precomposed))
        #expect(FinderTag(storedString: "\(decomposed)\n6") == FinderTag(name: precomposed))
    }
}

@Suite("FinderTagPayload")
struct FinderTagPayloadTests {
    private func payload(_ list: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    /// The golden fixture: the exact bytes macOS wrote for a file tagged `Red` plus a custom
    /// colourless `Important`, captured off a real tagged file rather than constructed here. If the
    /// stored format is ever not what this pass measured, this is the test that says so.
    @Test("decodes the real bytes macOS writes")
    func decodesCapturedBytes() throws {
        // bplist00 array of ["Red\n6", "Important\n0"] — the literal bytes macOS 26 wrote for a file
        // tagged Red + Important through URLResourceValues.tagNames, read straight back out.
        let captured = Data(
            base64Encoded: "YnBsaXN0MDCiAQJVUmVkCjZbSW1wb3J0YW50CjAICxEAAAAAAAABAQAAAAAAAAADAAAAAAAAAAAAAAAAAAAAHQ=="
        )
        let tags = FinderTagPayload.decode(try #require(captured))
        #expect(tags == [FinderTag(name: "Red"), FinderTag(name: "Important")])
        #expect(tags.map(\.color) == [.red, FinderTagColor.none])
    }

    @Test("stored order is preserved")
    func preservesOrder() throws {
        let tags = FinderTagPayload.decode(try payload(["Zebra\n3", "Red\n6", "Apple\n2"]))
        #expect(tags.map(\.name) == ["Zebra", "Red", "Apple"])
    }

    /// The system does not dedupe on write — `tagNames = ["Red", "Red"]` genuinely stores Red
    /// twice — so a file can arrive holding a repeat, and a column rendering it twice looks broken.
    @Test("a repeated tag collapses, first spelling winning")
    func dedupesOnDecode() throws {
        let tags = FinderTagPayload.decode(try payload(["Red\n6", "red\n6", "Work\n0"]))
        #expect(tags.map(\.name) == ["Red", "Work"])
    }

    /// One unusable row must not blank the whole cell — the call `GitStatusParser` makes.
    @Test("a malformed entry is skipped, not thrown on")
    func skipsMalformedEntries() throws {
        let tags = FinderTagPayload.decode(try payload(["Red\n6", "", "Work\n0"]))
        #expect(tags.map(\.name) == ["Red", "Work"])
    }

    /// The attribute belonging to someone else is not an error to report, just nothing to show.
    @Test("a payload that isn't a string array yields nothing")
    func foreignPayloadYieldsNothing() throws {
        #expect(FinderTagPayload.decode(Data()).isEmpty)
        #expect(FinderTagPayload.decode(Data("not a plist".utf8)).isEmpty)
        let numbers = try payload([1, 2])
        #expect(FinderTagPayload.decode(numbers).isEmpty)
    }

    @Test("encode round-trips through decode")
    func encodeRoundTrips() throws {
        let tags = [FinderTag(name: "Red", color: .red), FinderTag(name: "my tag", color: .purple)]
        #expect(FinderTagPayload.decode(try FinderTagPayload.encode(tags)) == tags)
    }

    @Test("encode collapses duplicates the system would happily store")
    func encodeDedupes() throws {
        let data = try FinderTagPayload.encode([FinderTag(name: "Red"), FinderTag(name: "RED")])
        #expect(FinderTagPayload.decode(data).count == 1)
    }

    @Test("encode writes the binary plist the system reads")
    func encodeWritesBinaryPlist() throws {
        let data = try FinderTagPayload.encode([FinderTag(name: "Red", color: .red)])
        var format = PropertyListSerialization.PropertyListFormat.xml
        let list = try PropertyListSerialization.propertyList(from: data, format: &format)
        #expect(format == .binary)
        #expect(list as? [String] == ["Red\n6"])
    }

    // MARK: - The legacy label

    /// All four cases were read off real files. The rule is last-coloured-wins, and every plausible
    /// alternative — first, lowest — is wrong on at least one of them.
    @Test("the legacy label is the last coloured tag's index")
    func legacyLabelLastColorWins() {
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Green", color: .green), FinderTag(name: "Red", color: .red)]
            ) == 6
        )
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Red", color: .red), FinderTag(name: "Orange", color: .orange)]
            ) == 7
        )
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Orange", color: .orange), FinderTag(name: "Red", color: .red)]
            ) == 6
        )
    }

    /// A trailing colourless tag must not clear the label — the system skips past it.
    @Test("a colourless tag does not clear the label")
    func legacyLabelSkipsColorless() {
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Blue", color: .blue), FinderTag(name: "Zebra")]
            ) == 4
        )
        #expect(
            FinderTagPayload.legacyLabel(
                for: [FinderTag(name: "Zebra"), FinderTag(name: "Blue", color: .blue)]
            ) == 4
        )
    }

    @Test("no colours anywhere means no label")
    func legacyLabelNone() {
        #expect(FinderTagPayload.legacyLabel(for: []) == 0)
        #expect(
            FinderTagPayload.legacyLabel(for: [FinderTag(name: "Zebra"), FinderTag(name: "Work")]) == 0
        )
    }
}
