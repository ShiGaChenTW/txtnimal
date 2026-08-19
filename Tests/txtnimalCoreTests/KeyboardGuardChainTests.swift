import XCTest
@testable import txtnimalCore

final class KeyboardGuardChainTests: XCTestCase {

    private func decide(_ stroke: KeyStroke, _ state: KeyboardGuardState = .init()) -> KeyboardDecision {
        KeyboardGuardChain.decide(stroke, state: state)
    }

    /// catalog 裡「一頁 + 有沒有選取」能讓這個指令合法的狀態。
    private func enablingState(for spec: CommandSpec) -> KeyboardGuardState {
        let page: CommandPalettePage
        if let pages = spec.availability.pages {
            if pages.contains(.list) {
                page = .list
            } else if let first = pages.sorted(by: { $0.rawValue < $1.rawValue }).first {
                page = first
            } else {
                page = .list
            }
        } else {
            page = .list
        }
        return KeyboardGuardState(page: page, hasSelection: true)
    }

    private func stroke(from binding: CommandKeyBinding) -> KeyStroke {
        KeyStroke(characters: binding.character, command: binding.command, shift: binding.shift)
    }

    func testEveryCommandBindingReachesItsCommandInAnEnablingState() {
        for spec in CommandCatalog.builtIns {
            let state = enablingState(for: spec)
            for binding in spec.bindings {
                XCTAssertEqual(
                    decide(stroke(from: binding), state),
                    .act(.command(spec.identity)),
                    "\(spec.id) / \(binding.display)"
                )
            }
        }
    }

    func testEveryCommandBindingIsBlockedWhileAModalTextSurfaceIsOpen() {
        let flags: [(String, (inout KeyboardGuardState) -> Void)] = [
            ("paletteOpen", { $0.paletteOpen = true }),
            ("editPopupOpen", { $0.editPopupOpen = true }),
            ("textEntryOverlayOpen", { $0.textEntryOverlayOpen = true }),
            ("inlineEditActive", { $0.inlineEditActive = true }),
            ("inlineAddActive", { $0.inlineAddActive = true }),
            ("searchFocused", { $0.searchFocused = true }),
        ]
        for spec in CommandCatalog.builtIns {
            for binding in spec.bindings {
                for (flag, apply) in flags {
                    var state = enablingState(for: spec)
                    apply(&state)
                    XCTAssertEqual(
                        decide(stroke(from: binding), state),
                        .passThrough,
                        "\(spec.id) / \(binding.display) blocked by \(flag)"
                    )
                }
            }
        }
    }

    /// item-3 迴歸：⌘E / ⌘⏎ 在統計、垃圾桶頁不得作用到清單裡看不見的游標。
    func testCommandShortcutsAreBlockedOnPagesWhereTheCommandIsUnavailable() {
        let strokes: [KeyStroke] = [
            KeyStroke(characters: "e", command: true),
            KeyStroke(characters: "\r", command: true),
        ]
        for page in [CommandPalettePage.dash, .trash] {
            for stroke in strokes {
                XCTAssertEqual(
                    decide(stroke, KeyboardGuardState(page: page, hasSelection: true)),
                    .passThrough,
                    "\(page) / \(stroke.characters == "\r" ? "⌘⏎" : "⌘E")"
                )
            }
        }
    }

    func testViewSwitchShortcutsStillFireOnReadOnlyPages() {
        let views: [(String, BuiltinCommand)] = [
            ("1", .viewList), ("2", .viewGrid), ("3", .viewAgent),
            ("4", .viewDash), ("5", .viewSettings), ("6", .viewTrash),
        ]
        for page in [CommandPalettePage.dash, .trash] {
            for (ch, id) in views {
                XCTAssertEqual(
                    decide(KeyStroke(characters: ch, command: true),
                           KeyboardGuardState(page: page, hasSelection: true)),
                    .act(.command(.builtin(id))),
                    "\(page) / ⌘\(ch)"
                )
            }
        }
    }

    /// 這是刻意的:agent / 設定兩頁把整副鍵盤交給欄位,所以 catalog 生出來的選單才是消費者,
    /// `CommandMenuModel` 是保證選單入口存在的那一端。
    func testViewSwitchShortcutsPassToTheMenuOnAgentAndSettings() {
        for page in [CommandPalettePage.agent, .settings] {
            XCTAssertEqual(
                decide(KeyStroke(characters: "1", command: true), KeyboardGuardState(page: page)),
                .passThrough,
                "\(page) / ⌘1"
            )
        }
    }

    /// 「d 不得刪掉清單裡看不見的那個游標」契約。
    /// 統計頁與垃圾桶沒有可編輯欄位,所以單鍵動詞一律吞掉 —— 尤其是 `d`,
    /// 它若在這裡生效,刪掉的會是清單頁那個看不見的游標指到的任務。
    ///
    /// 設定頁刻意不在這個清單裡。它有使用者名稱、兩個熱鍵錄製器、agent 端點與模型
    /// 這些可編輯欄位,所以整頁把鍵盤交給欄位(`.passThrough`),而不是吞掉 ——
    /// 這正是它需要另一條 esc 專用出口的原因,見
    /// `testSettingsEscapeLeavesToListEvenThoughSettingsHandsOverTheKeyboard`。
    func testReadOnlyPagesSwallowSingleKeyVerbs() {
        for page in [CommandPalettePage.dash, .trash] {
            for ch in ["d", "x", "e", "n"] {
                XCTAssertEqual(
                    decide(KeyStroke(characters: ch), KeyboardGuardState(page: page, hasSelection: true)),
                    .swallow,
                    "\(page) / \(ch)"
                )
            }
        }
    }

    func testFocusModeSwallowsEverythingExceptZAndEscape() {
        let focused = KeyboardGuardState(focusMode: true)
        XCTAssertEqual(decide(KeyStroke(characters: "z"), focused), .act(.exitFocusMode))
        XCTAssertEqual(decide(KeyStroke(keyCode: KeyCodes.escape), focused), .act(.exitFocusMode))
        for ch in ["n", "d", "j"] {
            XCTAssertEqual(decide(KeyStroke(characters: ch), focused), .swallow, ch)
        }
        // cmd 分支排在專注模式守門之前,⌘1 仍須生效。
        XCTAssertEqual(
            decide(KeyStroke(characters: "1", command: true), focused),
            .act(.command(.builtin(.viewList)))
        )
    }

    func testInlineEditPassesTypingThroughInsteadOfRunningVerbs() {
        let editing = KeyboardGuardState(inlineEditActive: true)
        XCTAssertEqual(decide(KeyStroke(characters: "d"), editing), .passThrough)
        XCTAssertEqual(decide(KeyStroke(characters: "x"), editing), .passThrough)
    }

    func testEscapeClearsSearchThenTagFilterThenFocus() {
        XCTAssertEqual(
            decide(KeyStroke(keyCode: KeyCodes.escape),
                   KeyboardGuardState(searchActive: true, tagFilterActive: true)),
            .act(.clearSearch)
        )
        XCTAssertEqual(
            decide(KeyStroke(keyCode: KeyCodes.escape),
                   KeyboardGuardState(tagFilterActive: true)),
            .act(.clearTagFilter)
        )
        XCTAssertEqual(
            decide(KeyStroke(keyCode: KeyCodes.escape)),
            .act(.clearFocus)
        )
    }

    func testSettingsEscapeLeavesToListEvenThoughSettingsHandsOverTheKeyboard() {
        XCTAssertEqual(
            decide(KeyStroke(keyCode: KeyCodes.escape), KeyboardGuardState(page: .settings)),
            .act(.leaveToList)
        )
        XCTAssertEqual(
            decide(KeyStroke(characters: "n"), KeyboardGuardState(page: .settings)),
            .passThrough
        )
    }

    func testQuadrantDigitsOnlyActOnTheGridPage() {
        XCTAssertEqual(
            decide(KeyStroke(characters: "1"), KeyboardGuardState(page: .grid)),
            .act(.setQuadrant(1))
        )
        XCTAssertEqual(
            decide(KeyStroke(characters: "0"), KeyboardGuardState(page: .grid)),
            .act(.setQuadrant(nil))
        )
        XCTAssertEqual(
            decide(KeyStroke(characters: "1"), KeyboardGuardState(page: .list)),
            .passThrough
        )
    }

    func testArrowsAndVimKeysMoveTheCursor() {
        XCTAssertEqual(decide(KeyStroke(keyCode: KeyCodes.arrowUp)), .act(.moveCursor(-1)))
        XCTAssertEqual(decide(KeyStroke(characters: "k")), .act(.moveCursor(-1)))
        XCTAssertEqual(decide(KeyStroke(keyCode: KeyCodes.arrowDown)), .act(.moveCursor(1)))
        XCTAssertEqual(decide(KeyStroke(characters: "j")), .act(.moveCursor(1)))
        XCTAssertEqual(decide(KeyStroke(keyCode: KeyCodes.returnKey)), .act(.startInlineEdit))
    }
}
