import Testing
@testable import GatefoldCore

@Suite("Quoting a passage")
struct PassageQuoteTests {
    @Test func plainProseIsQuoted() {
        #expect(PassageQuote.quoted("The kettle sang on the hob.") == "“The kettle sang on the hob.”")
    }

    @Test func dialogueIsNotQuotedTwice() {
        // Curly, straight, low-9 and guillemets, either way round.
        for passage in ["“Not again!” said the cat.", "\"Not again!\" said the cat.", "„Nicht schon wieder!“ sagte die Katze.",
                        "«Pas encore !» dit le chat.", "»Ikke igen!« sagde katten.", "‘Not again,’ said the cat.", "'Not again,' said the cat."] {
            #expect(PassageQuote.quoted(passage) == passage, "\(passage)")
        }
    }

    @Test func aCutPassageEndsInAnEllipsis() {
        #expect(PassageQuote.quoted("The kettle sang", cut: true) == "“The kettle sang…”")
        #expect(PassageQuote.quoted("“Not again!” said", cut: true) == "“Not again!” said…")
        #expect(PassageQuote.quoted("It trailed off…", cut: true) == "“It trailed off…”")
    }

    @Test func leadingSpaceDoesNotHideTheMark() {
        #expect(PassageQuote.quoted("  “Not again!”") == "“Not again!”")
    }
}
