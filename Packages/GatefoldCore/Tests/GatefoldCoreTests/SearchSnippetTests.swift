import GatefoldCore
import Testing

/// A search result shows its match. Readium gives a long run of text before the match, and on the folded Duo three
/// lines of it ran out before the match came (review panel 2026-11-22, duo-*-11). Only the last few words before the
/// match are kept, from a word's start, after an ellipsis.
@Suite struct SearchSnippetTests {
    @Test func aLongLeadKeepsItsLastWordsFromAWordsStart() {
        let before = "afforded her opportunities for the display of the peculiar and incomparable talent to be noticed presently, she has been satisfied here with the perfectly natural occasions provided by the false account of "
        let lead = SearchSnippet.lead(before)
        #expect(lead.count <= SearchSnippet.leadLimit + 1)
        #expect(lead.hasPrefix("…"))
        #expect(before.hasSuffix(String(lead.dropFirst())), "the words are the lead's own, ending where the match starts")
        #expect(lead.dropFirst().first?.isWhitespace == false && before.contains(" " + lead.dropFirst()), "it starts at a word")
    }

    @Test func aShortLeadStaysWhole() {
        #expect(SearchSnippet.lead("Mr. ") == "Mr. ")
        #expect(SearchSnippet.lead("") == "")
    }

    @Test func lineBreaksInTheLeadReadAsSpaces() {
        #expect(SearchSnippet.lead("Chapter 3\n\nMr. ") == "Chapter 3 Mr. ")
    }
}
