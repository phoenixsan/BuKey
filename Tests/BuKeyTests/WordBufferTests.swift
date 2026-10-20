import XCTest
@testable import BuKey

final class WordBufferTests: XCTestCase {
    func testTerminatesCurrentWordOnPlainSpace() {
        var buffer = WordBuffer()
        for letter in "ghbdtn" { XCTAssertEqual(buffer.consume(.keyDown(.character(letter))), .none) }
        XCTAssertEqual(buffer.consume(.keyDown(.space)), .wordTerminated(WordSnapshot(text: "ghbdtn", trailingDelimiterCount: 1)))
    }

    func testBackspaceEditsOnlyCurrentWord() {
        var buffer = WordBuffer()
        _ = buffer.consume(.keyDown(.character("a")))
        _ = buffer.consume(.keyDown(.character("b")))
        _ = buffer.consume(.keyDown(.backspace))
        XCTAssertEqual(buffer.consume(.keyDown(.space)), .wordTerminated(WordSnapshot(text: "a", trailingDelimiterCount: 1)))
    }

    func testCountsRepeatedPlainSpacesAfterTerminatedWord() {
        var buffer = WordBuffer()
        for letter in "word" { _ = buffer.consume(.keyDown(.character(letter))) }
        _ = buffer.consume(.keyDown(.space))
        XCTAssertEqual(buffer.consume(.keyDown(.space)), .none)
        XCTAssertEqual(buffer.consume(.keyDown(.space)), .none)
        XCTAssertEqual(buffer.previousWord, WordSnapshot(text: "word", trailingDelimiterCount: 3))
        XCTAssertNil(buffer.currentWord)
    }

    func testKeepsOnlyImmediatelyPrecedingWord() {
        var buffer = WordBuffer()
        for letter in "one" { _ = buffer.consume(.keyDown(.character(letter))) }
        _ = buffer.consume(.keyDown(.space))
        for letter in "two" { _ = buffer.consume(.keyDown(.character(letter))) }
        _ = buffer.consume(.keyDown(.space))
        XCTAssertEqual(buffer.previousWord, WordSnapshot(text: "two", trailingDelimiterCount: 1))
        XCTAssertNil(buffer.currentWord)
    }

    func testNavigationAndFocusChangingShortcutsResetState() {
        var buffer = WordBuffer()
        _ = buffer.consume(.keyDown(.character("a")))
        XCTAssertEqual(buffer.consume(.keyDown(.left)), .reset)
        XCTAssertNil(buffer.currentWord)
        _ = buffer.consume(.keyDown(.character("b")))
        XCTAssertEqual(buffer.consume(.keyDown(.character("c"), modifiers: [.command])), .reset)
        XCTAssertNil(buffer.currentWord)
    }

    func testKarabinerHyperCapsDoesNotEraseCurrentWord() {
        var buffer = WordBuffer()
        for letter in "руддщ" { _ = buffer.consume(.keyDown(.character(letter))) }

        XCTAssertEqual(
            buffer.consume(.keyDown(.capsLock, modifiers: [.shift, .control, .option, .command])),
            .none
        )
        XCTAssertEqual(buffer.currentWord, WordSnapshot(text: "руддщ", trailingDelimiterCount: 0))
    }

    func testRecentTextTracksEntireContinuousPhrase() {
        var buffer = WordBuffer()
        for character in "руддщ цщкдв" {
            _ = buffer.consume(character == " " ? .keyDown(.space) : .keyDown(.character(character)))
        }

        XCTAssertEqual(buffer.recentTextSnapshot, WordSnapshot(text: "руддщ цщкдв", trailingDelimiterCount: 0))
    }

    func testRecentTextKeepsOnlyLastFiftyCharacters() {
        var buffer = WordBuffer()
        let text = String(repeating: "a", count: 60)
        for character in text { _ = buffer.consume(.keyDown(.character(character))) }

        XCTAssertEqual(buffer.recentTextSnapshot?.text.count, 50)
        XCTAssertEqual(buffer.currentWord?.text.count, 50)
    }

    func testNonPrintingBoundaryKeysResetInsteadOfBecomingWordCharacters() {
        for boundary in [KeyboardKey.returnKey, .tab, .escape, .deleteForward] {
            var buffer = WordBuffer()
            _ = buffer.consume(.keyDown(.character("a")))

            XCTAssertEqual(buffer.consume(.keyDown(boundary)), .reset)
            XCTAssertNil(buffer.currentWord)
            XCTAssertNil(buffer.previousWord)
        }
    }

    func testControlCharactersResetInsteadOfBecomingWordCharacters() {
        for character in [Character("\n"), Character("\t"), Character("\u{1b}")] {
            var buffer = WordBuffer()
            _ = buffer.consume(.keyDown(.character("a")))

            XCTAssertEqual(buffer.consume(.keyDown(.character(character))), .reset)
            XCTAssertNil(buffer.currentWord)
            XCTAssertNil(buffer.previousWord)
        }
    }
}
