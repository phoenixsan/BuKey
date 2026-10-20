import XCTest
@testable import BuKey

final class TokenPolicyTests: XCTestCase {
    func testRejectsUnsafeAutomaticTokens() {
        for token in ["ab", "42", "me@example.com", "https://x.com", "foo_bar", "let()", "a.b", "path/to", "x\\y", "foo{bar}"] {
            XCTAssertFalse(TokenPolicy.isEligibleForAutomaticCorrection(token), token)
        }
    }

    func testAcceptsOrdinaryMistypedWord() {
        XCTAssertTrue(TokenPolicy.isEligibleForAutomaticCorrection("ghbdtn"))
    }

    func testRejectsAnyLeadingURIScheme() {
        for token in ["mailto:ghbdtn", "custom:ghbdtn", "x+v1.thing:ghbdtn"] {
            XCTAssertFalse(TokenPolicy.isEligibleForAutomaticCorrection(token), token)
        }
    }
}
