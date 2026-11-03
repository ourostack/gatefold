import Testing
@testable import GatefoldCore

/// Sign-in looks at the email before sending it anywhere, so a typo gets a gentle word instead of a spinner.
@Suite("A typed email is checked kindly, not strictly")
struct EmailCheckTests {
    @Test(arguments: ["ari@mendelow.me", "reader@example.com", "first.last+books@mail.co.uk", "  padded@example.com  ", "a@b.c", "UPPER@EXAMPLE.COM"])
    func plausibleAddressesPass(_ email: String) {
        #expect(EmailCheck.isPlausible(email))
    }

    @Test func arisTypoIsCaught() {
        #expect(EmailCheck.problem("ari@mendelow@me") == .tooManyAts)
    }

    @Test(arguments: [
        ("ari mendelow@me.com", EmailCheck.Problem.space),
        ("ari@mendelow .me", .space),
        ("arimendelow.me", .missingAt),
        ("", .missingAt),
        ("ari@@mendelow.me", .tooManyAts),
        ("@mendelow.me", .missingName),
        ("ari@", .missingDomain),
        ("ari@mendelow", .missingDot),
        ("ari@mendelow.", .missingDot),
        ("ari@.me", .missingDot),
        ("ari@mendelow..me", .missingDot),
    ])
    func eachSlipIsNamed(_ email: String, _ problem: EmailCheck.Problem) {
        #expect(EmailCheck.problem(email) == problem)
    }
}
