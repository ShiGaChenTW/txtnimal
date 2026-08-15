import XCTest
@testable import txtnimalCore

final class UndoStackTests: XCTestCase {

    // MARK: - Scenario: push 後 undo 取回前一版

    func testUndoReturnsPreviousSnapshotAndEnablesRedo() {
        var stack = UndoStack()
        stack.push("A")
        stack.push("B")

        XCTAssertEqual(stack.undo(), "A")
        XCTAssertTrue(stack.canRedo)
        XCTAssertFalse(stack.canUndo)
    }

    // MARK: - Scenario: redo 取回被 undo 的版本

    func testRedoReturnsUndoneSnapshot() {
        var stack = UndoStack()
        stack.push("A")
        stack.push("B")
        XCTAssertEqual(stack.undo(), "A")

        XCTAssertEqual(stack.redo(), "B")
        XCTAssertFalse(stack.canRedo)
        XCTAssertTrue(stack.canUndo)
    }

    // MARK: - Scenario: 新操作切斷 redo 分支

    func testPushAfterUndoCutsRedoBranch() {
        var stack = UndoStack()
        stack.push("A")
        stack.push("B")
        XCTAssertEqual(stack.undo(), "A")

        stack.push("C")

        XCTAssertFalse(stack.canRedo)
        XCTAssertNil(stack.redo())
        XCTAssertEqual(stack.undo(), "A")
    }

    // MARK: - Scenario: 深度上界

    func testPushBeyondCapacityDropsOldestAndDoesNotCrash() {
        var stack = UndoStack(capacity: 3)
        stack.push("1")
        stack.push("2")
        stack.push("3")
        stack.push("4")
        stack.push("5")

        XCTAssertEqual(stack.undo(), "4")
        XCTAssertEqual(stack.undo(), "3")
        XCTAssertNil(stack.undo(), "oldest snapshots 1 and 2 must have been dropped")
        XCTAssertTrue(stack.canRedo)
    }

    // MARK: - Scenario: 空堆疊安全

    func testEmptyStackUndoAndRedoReturnNil() {
        var stack = UndoStack()
        XCTAssertNil(stack.undo())
        XCTAssertNil(stack.redo())
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)

        stack.push("only")
        XCTAssertNil(stack.undo(), "a single snapshot has no previous version")
        XCTAssertNil(stack.redo())
    }

    func testClearEmptiesUndoAndRedo() {
        var stack = UndoStack()
        stack.push("A")
        stack.push("B")
        _ = stack.undo()
        stack.clear()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertNil(stack.undo())
        XCTAssertNil(stack.redo())
    }
}
