import XCTest
@testable import BuKey

final class LanguageDetectorTests: XCTestCase {
    func testReturnsHighConfidenceCandidate() {
        let scorer = StubScorer(scores: ["ghbdtn": -20, "привет": -2])
        XCTAssertEqual(LanguageDetector(scorer: scorer, minimumGain: 8).correction(for: "ghbdtn"), "привет")
    }

    func testLeavesAmbiguousTokenAlone() {
        let scorer = StubScorer(scores: ["coca": -4, "соса": -5])
        XCTAssertNil(LanguageDetector(scorer: scorer, minimumGain: 8).correction(for: "coca"))
    }

    func testBundledScoringRecognizesBothMistypedLayouts() {
        let detector = LanguageDetector()
        XCTAssertEqual(detector.correction(for: "ghbdtn"), "привет")
        XCTAssertEqual(detector.correction(for: "руддщ"), "hello")
    }

    func testDoesNotCorrectIneligibleTokens() {
        let detector = LanguageDetector()
        XCTAssertNil(detector.correction(for: "https://ghbdtn.com"))
    }
}

private struct StubScorer: WordScoring {
    let scores: [String: Double]

    func score(_ word: String, layout: KeyboardLayout) -> Double {
        scores[word, default: -100]
    }
}
