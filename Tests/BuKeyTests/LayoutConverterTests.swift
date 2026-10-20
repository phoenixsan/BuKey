import XCTest
@testable import BuKey

final class LayoutConverterTests: XCTestCase {
    func testConvertsEnglishKeysToRussian() {
        XCTAssertEqual(LayoutConverter.convert("Ghbdtn, vbh!", to: .russian), "Приветб мир!")
    }

    func testConvertsRussianKeysToEnglish() {
        XCTAssertEqual(LayoutConverter.convert("Руддщ цщкдв", to: .english), "Hello world")
    }

    func testConvertsCompleteUnshiftedPhysicalKeyPairs() {
        XCTAssertEqual(LayoutConverter.convert("`[];',./", to: .russian), "ёхъжэбю.")
        XCTAssertEqual(LayoutConverter.convert("ёхъжэбю.", to: .english), "`[];',./")
    }

    func testConvertsCompleteShiftedPhysicalKeyPairs() {
        XCTAssertEqual(LayoutConverter.convert("~{}:\"<>?", to: .russian), "ЁХЪЖЭБЮ,")
        XCTAssertEqual(LayoutConverter.convert("ЁХЪЖЭБЮ,", to: .english), "~{}:\"<>?")
    }

    func testPreservesMixedWhitespaceAndUnsupportedCharacters() {
        XCTAssertEqual(LayoutConverter.convert("ghbdtn\t123🙂!\n", to: .russian), "привет\t123🙂!\n")
    }

    func testOppositeConversionUsesDominantSupportedAlphabetAndLeavesTieUntouched() {
        XCTAssertEqual(LayoutConverter.convertToOppositeLayout("ghbdtn мир"), "привет мир")
        XCTAssertEqual(LayoutConverter.convertToOppositeLayout("руддщ"), "hello")
        XCTAssertEqual(LayoutConverter.convertToOppositeLayout("aф"), "aф")
    }

    func testCompleteRussianAlphabetDrivesDominanceAndOppositeConversion() {
        XCTAssertEqual(LayoutConverter.dominantLayout(in: "хлеб"), .russian)
        XCTAssertEqual(LayoutConverter.dominantLayout(in: "бюро"), .russian)
        XCTAssertEqual(LayoutConverter.convertToOppositeLayout("хлеб"), "[kt,")
        XCTAssertEqual(LayoutConverter.convertToOppositeLayout("бюро"), ",.hj")
    }
}
