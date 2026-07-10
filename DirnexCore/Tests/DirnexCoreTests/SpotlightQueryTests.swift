import Foundation
import Testing

@testable import DirnexCore

@Suite("SpotlightQuery")
struct SpotlightQueryTests {
    @Test("an all-default query is empty and yields no predicate")
    func emptyQuery() {
        let query = SpotlightQuery()
        #expect(query.isEmpty)
        #expect(query.metadataPredicate() == nil)
        #expect(query.mdfindArguments(scopePath: "/tmp").isEmpty)
    }

    @Test("whitespace-only name/content still counts as empty")
    func whitespaceIsEmpty() {
        let query = SpotlightQuery(nameContains: "   ", contentContains: "\n\t")
        #expect(query.isEmpty)
        #expect(query.metadataPredicate() == nil)
    }

    @Test("a name term builds a case/diacritic-insensitive substring clause")
    func namePredicate() {
        let query = SpotlightQuery(nameContains: "report")
        #expect(!query.isEmpty)
        #expect(query.metadataPredicate() == #"kMDItemFSName == "*report*"cd"#)
    }

    @Test("a name term is trimmed before it is embedded")
    func nameTrimmed() {
        let query = SpotlightQuery(nameContains: "  budget  ")
        #expect(query.metadataPredicate() == #"kMDItemFSName == "*budget*"cd"#)
    }

    @Test("a content term builds a text-content substring clause")
    func contentPredicate() {
        let query = SpotlightQuery(contentContains: "quarterly")
        #expect(query.metadataPredicate() == #"kMDItemTextContent == "*quarterly*"cd"#)
    }

    @Test("name and content clauses AND together in order")
    func nameAndContent() {
        let query = SpotlightQuery(nameContains: "memo", contentContains: "urgent")
        #expect(
            query.metadataPredicate()
                == #"kMDItemFSName == "*memo*"cd && kMDItemTextContent == "*urgent*"cd"#
        )
    }

    @Test("a single kind becomes a parenthesized content-type-tree clause")
    func singleKind() {
        let query = SpotlightQuery(kinds: [.image])
        #expect(query.metadataPredicate() == #"(kMDItemContentTypeTree == "public.image"c)"#)
    }

    @Test("multiple kinds OR together in CaseIterable order regardless of set order")
    func multipleKindsAreOrdered() {
        let query = SpotlightQuery(kinds: [.archive, .folder, .image])
        // Declaration order is folder, image, …, archive — so folder comes first, archive last.
        #expect(
            query.metadataPredicate()
                == #"(kMDItemContentTypeTree == "public.folder"c || "#
                + #"kMDItemContentTypeTree == "public.image"c || "#
                + #"kMDItemContentTypeTree == "public.archive"c)"#
        )
    }

    @Test("a minimum size becomes a byte comparison")
    func minimumSize() {
        let query = SpotlightQuery(minSizeBytes: 1_048_576)
        #expect(query.metadataPredicate() == "kMDItemFSSize >= 1048576")
    }

    @Test("a modified-within window becomes a relative $time.now offset")
    func modifiedWithin() {
        let query = SpotlightQuery(modifiedWithin: .week)
        #expect(
            query.metadataPredicate()
                == "kMDItemFSContentChangeDate >= $time.now(-604800)"
        )
    }

    @Test("every clause ANDs together in the fixed name→content→kind→size→date order")
    func allClausesCombine() {
        let query = SpotlightQuery(
            nameContains: "photo",
            contentContains: "beach",
            kinds: [.image],
            minSizeBytes: 500,
            modifiedWithin: .today
        )
        #expect(
            query.metadataPredicate()
                == #"kMDItemFSName == "*photo*"cd"#
                + #" && kMDItemTextContent == "*beach*"cd"#
                + #" && (kMDItemContentTypeTree == "public.image"c)"#
                + " && kMDItemFSSize >= 500"
                + " && kMDItemFSContentChangeDate >= $time.now(-86400)"
        )
    }

    @Test("a term's quotes and backslashes are escaped so they can't break the literal")
    func escapesQuotesAndBackslashes() {
        let query = SpotlightQuery(nameContains: #"a"b\c"#)
        #expect(query.metadataPredicate() == #"kMDItemFSName == "*a\"b\\c*"cd"#)
    }

    @Test("mdfind arguments prepend -onlyin for a scope and end with the predicate")
    func scopedArguments() {
        let query = SpotlightQuery(nameContains: "todo")
        let arguments = query.mdfindArguments(scopePath: "/Users/me/Docs")
        #expect(arguments == ["-onlyin", "/Users/me/Docs", #"kMDItemFSName == "*todo*"cd"#])
    }

    @Test("mdfind arguments omit -onlyin when the scope is nil or empty")
    func unscopedArguments() {
        let query = SpotlightQuery(nameContains: "todo")
        #expect(query.mdfindArguments(scopePath: nil) == [#"kMDItemFSName == "*todo*"cd"#])
        #expect(query.mdfindArguments(scopePath: "") == [#"kMDItemFSName == "*todo*"cd"#])
    }

    @Test("the summary prefers the name, then content, then a lone kind, then a fallback")
    func summaryPrecedence() {
        #expect(SpotlightQuery(nameContains: "  taxes ").summary == "“taxes”")
        #expect(SpotlightQuery(contentContains: "invoice").summary == "“invoice”")
        #expect(SpotlightQuery(kinds: [.movie]).summary == "Movies")
        #expect(SpotlightQuery(kinds: [.movie, .image]).summary == "Search results")
        #expect(SpotlightQuery(minSizeBytes: 10).summary == "Search results")
    }
}
