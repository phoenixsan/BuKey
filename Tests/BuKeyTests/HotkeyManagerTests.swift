import XCTest
@testable import BuKey

final class HotkeyManagerTests: XCTestCase {
    func testLegacyOptionSpaceIsDisabled() {
        var manager = HotkeyManager()
        XCTAssertNil(manager.command(for: .keyDown(.space, modifiers: [.option]), now: 1))
    }

    func testRecognizesSelectionShortcut() {
        var manager = HotkeyManager()
        XCTAssertEqual(manager.command(for: .keyDown(.space, modifiers: [.shift, .option]), now: 1), .convertSelection)
    }

    func testRejectsOtherModifiersAndNonKeyEvents() {
        var manager = HotkeyManager()
        XCTAssertNil(manager.command(for: .keyDown(.space, modifiers: [.command]), now: 1))
        XCTAssertNil(manager.command(for: .mouseDown, now: 2))
    }

    func testDoubleCapsLockTriggersLastWordOnlyOnSecondTap() {
        var manager = HotkeyManager()
        XCTAssertNil(manager.command(for: .keyDown(.capsLock), now: 10.0))
        XCTAssertEqual(manager.command(for: .keyDown(.capsLock), now: 10.2), .correctLastWord)
        XCTAssertNil(manager.command(for: .keyDown(.capsLock), now: 10.3))
        XCTAssertEqual(manager.command(for: .keyDown(.capsLock), now: 10.5), .correctLastWord)
    }

    func testCapsLockSingleTapTimesOutAndKarabinerModifiersAreAccepted() {
        var manager = HotkeyManager()
        XCTAssertNil(manager.command(for: .keyDown(.capsLock, modifiers: [.shift, .control, .option, .command]), now: 20.0))
        XCTAssertEqual(manager.command(for: .keyDown(.capsLock, modifiers: [.shift, .control, .option, .command]), now: 20.4), .correctLastWord)
    }
}
