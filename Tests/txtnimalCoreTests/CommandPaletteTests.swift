import XCTest
@testable import txtnimalCore

final class CommandPaletteTests: XCTestCase {

    // MARK: - fixtures

    private func commandPlugin(id: String = "app.txtnimal.reschedule-tomorrow",
                               commandID: String = "reschedule-tomorrow",
                               title: String = "Reschedule Tomorrow",
                               enabled: Bool = true,
                               selectedRead: Bool = true,
                               extraCommands: [PluginCommandDeclaration] = []) -> PluginRegistryEntry {
        let capabilities: [PluginCapability] = selectedRead
            ? [.tasksSelectedRead, .tasksUpdate]
            : [.tasksAllRead]
        let manifest = PluginManifest(
            id: id, name: title, version: "1.0.0", apiVersion: 1, entry: "main.js",
            capabilities: capabilities,
            commands: [PluginCommandDeclaration(id: commandID, title: title)] + extraCommands
        )
        return PluginRegistryEntry(manifest: manifest, source: .installed,
                                   packageRootURL: URL(fileURLWithPath: "/tmp/\(id)"),
                                   enabled: enabled)
    }

    private func pageOnlyPlugin(id: String = "app.txtnimal.weekly-review",
                                enabled: Bool = true) -> PluginRegistryEntry {
        let manifest = PluginManifest(
            id: id, name: "Weekly Review", version: "1.0.0", apiVersion: 1, entry: "main.js",
            capabilities: [.uiPage, .tasksAllRead],
            commands: []
        )
        return PluginRegistryEntry(manifest: manifest, source: .bundled,
                                   packageRootURL: URL(fileURLWithPath: "/tmp/\(id)"),
                                   enabled: enabled)
    }

    private func assemble(page: CommandPalettePage, hasSelection: Bool,
                          plugins: [PluginRegistryEntry] = [],
                          query: String = "") -> [CommandSpec] {
        CommandPaletteAssembler.assemble(
            plugins: plugins,
            context: CommandPaletteContext(page: page, hasSelection: hasSelection),
            query: query
        )
    }

    private func identities(in specs: [CommandSpec]) -> [CommandIdentity] {
        specs.map(\.identity)
    }

    // MARK: - Scenario: 頁面相關指令過濾

    func testDashHidesInlineEditAndFocusThis() {
        let result = assemble(page: .dash, hasSelection: true)
        XCTAssertFalse(identities(in: result).contains(.builtin(.inlineEdit)))
        XCTAssertFalse(identities(in: result).contains(.builtin(.toggleFocus)))
        XCTAssertTrue(identities(in: result).contains(.builtin(.viewList)))
        XCTAssertTrue(identities(in: result).contains(.builtin(.openScratch)))
    }

    func testListKeepsInlineEditAndFocusThisWhenSelected() {
        let result = assemble(page: .list, hasSelection: true)
        XCTAssertTrue(identities(in: result).contains(.builtin(.inlineEdit)))
        XCTAssertTrue(identities(in: result).contains(.builtin(.toggleFocus)))
    }

    func testGridKeepsListGridVerbs() {
        let result = assemble(page: .grid, hasSelection: true)
        XCTAssertTrue(identities(in: result).contains(.builtin(.inlineEdit)))
        XCTAssertTrue(identities(in: result).contains(.builtin(.focusMode)))
    }

    // MARK: - Scenario: 無選取時不列需選取的指令

    func testNoSelectionHidesAddList() {
        let result = assemble(page: .list, hasSelection: false)
        XCTAssertFalse(identities(in: result).contains(.builtin(.addList)))
        XCTAssertFalse(identities(in: result).contains(.builtin(.toggleDone)))
        XCTAssertFalse(identities(in: result).contains(.builtin(.editPopup)))
        XCTAssertFalse(identities(in: result).contains(.builtin(.inlineEdit)))
        XCTAssertFalse(identities(in: result).contains(.builtin(.toggleFocus)))
    }

    func testSelectionShowsAddList() {
        let result = assemble(page: .list, hasSelection: true)
        XCTAssertTrue(identities(in: result).contains(.builtin(.addList)))
    }

    // MARK: - Scenario: 提示對齊實際綁定

    func testKeyDisplayIsDerivedFromBindings() {
        XCTAssertEqual(CommandCatalog.builtIn(.inlineEdit).keyDisplay, "e")
        XCTAssertEqual(CommandCatalog.builtIn(.inlineAdd).keyDisplay, "n")
        XCTAssertEqual(CommandCatalog.builtIn(.openCapture).keyDisplay, "")
        XCTAssertEqual(CommandCatalog.builtIn(.editPopup).keyDisplay, "⌘E")
        XCTAssertEqual(CommandCatalog.builtIn(.viewList).keyDisplay, "⌘1")
        XCTAssertEqual(CommandCatalog.builtIn(.viewGrid).keyDisplay, "⌘2")
        XCTAssertEqual(CommandCatalog.builtIn(.viewAgent).keyDisplay, "⌘3")
        XCTAssertEqual(CommandCatalog.builtIn(.viewDash).keyDisplay, "⌘4")
        XCTAssertEqual(CommandCatalog.builtIn(.viewSettings).keyDisplay, "⌘5")
        XCTAssertEqual(CommandCatalog.builtIn(.cycleAppearance).keyDisplay, "⌘⇧T")
        XCTAssertEqual(CommandCatalog.builtIn(.undo).keyDisplay, "⌘Z")
        XCTAssertEqual(CommandCatalog.builtIn(.redo).keyDisplay, "⇧⌘Z")
        XCTAssertEqual(CommandCatalog.builtIn(.toggleFocus).keyDisplay, "f")
        XCTAssertEqual(CommandCatalog.builtIn(.search).keyDisplay, "/")
    }

    func testMatcherAgreesWithHandleContract() {
        let cmds = CommandCatalog.builtIns
        func match(_ character: String, command: Bool = false, shift: Bool = false) -> BuiltinCommand? {
            guard case .builtin(let id) = CommandKeyMatcher.match(
                character: character, command: command, shift: shift, in: cmds
            )?.identity else { return nil }
            return id
        }
        XCTAssertEqual(match("1", command: true), .viewList)
        XCTAssertEqual(match("2", command: true), .viewGrid)
        XCTAssertEqual(match("3", command: true), .viewAgent)
        XCTAssertEqual(match("4", command: true), .viewDash)
        XCTAssertEqual(match("5", command: true), .viewSettings)
        XCTAssertEqual(match("6", command: true), .viewTrash)
        XCTAssertEqual(match("7", command: true), .viewNotes)
        XCTAssertEqual(match(",", command: true), .viewSettings)
        XCTAssertEqual(match("n"), .inlineAdd)
        XCTAssertEqual(match("b", command: true), .inlineAdd)
        XCTAssertEqual(match("e"), .inlineEdit)
        XCTAssertEqual(match("e", command: true), .editPopup)
        XCTAssertEqual(match("f"), .toggleFocus)
        XCTAssertEqual(match("f", command: true), .search)
        XCTAssertEqual(match("f", command: true, shift: true), .toggleFocus)
        XCTAssertEqual(match("k", command: true), .openPalette)
        XCTAssertEqual(match("z", command: true), .undo)
        XCTAssertEqual(match("z", command: true, shift: true), .redo)
        XCTAssertEqual(match("t", command: true, shift: true), .cycleAppearance)
        XCTAssertEqual(match("R", shift: true), .rescheduleOverdue)
        XCTAssertNil(match("R"), "Caps Lock + r is not reschedule")
        XCTAssertEqual(match("N"), .inlineAdd)
        XCTAssertNil(match("N", shift: true), "Shift+n is not inline-add")
        XCTAssertNil(match("n", command: true), "⌘N is not inline-add; n alone is")
    }

    func testInlineAddIsNotOpenCapture() {
        XCTAssertEqual(CommandCatalog.builtIn(.inlineAdd).keyDisplay, "n")
        XCTAssertTrue(CommandCatalog.builtIn(.openCapture).bindings.isEmpty)
        XCTAssertNotEqual(CommandCatalog.builtIn(.inlineAdd).identity,
                          CommandCatalog.builtIn(.openCapture).identity)
    }

    func testBuiltinHandleBindingsAreUnique() {
        var owners: [String: CommandSpec] = [:]
        for spec in CommandCatalog.builtIns {
            for binding in spec.bindings {
                let token = "\(binding.command ? "c" : "_")\(binding.shift ? "s" : "_")\(binding.character)"
                if let previous = owners[token] {
                    XCTAssertFalse(availabilityOverlaps(previous.availability, spec.availability),
                                   "duplicate binding \(token) on \(previous.id) and \(spec.id)")
                } else {
                    owners[token] = spec
                }
            }
        }
    }

    private func availabilityOverlaps(_ a: CommandAvailability, _ b: CommandAvailability) -> Bool {
        switch (a.pages, b.pages) {
        case (nil, _), (_, nil): return true
        case let (left?, right?): return !left.isDisjoint(with: right)
        }
    }

    // MARK: - Scenario: d / t / l / @ 四個新單鍵

    func testNewSingleKeyBindingsResolveToTheirCommands() {
        let cmds = CommandCatalog.builtIns
        func match(_ character: String) -> BuiltinCommand? {
            guard case .builtin(let id) = CommandKeyMatcher.match(
                character: character, command: false, shift: false, in: cmds
            )?.identity else { return nil }
            return id
        }
        XCTAssertEqual(match("d"), .deleteTask)
        XCTAssertEqual(match("t"), .quickDue)
        XCTAssertEqual(match("l"), .newList)
        XCTAssertEqual(match("@"), .addTag)
        XCTAssertEqual(match("#"), .addNoteTag)
    }

    func testNewCommandsKeyDisplay() {
        XCTAssertEqual(CommandCatalog.builtIn(.deleteTask).keyDisplay, "d")
        XCTAssertEqual(CommandCatalog.builtIn(.quickDue).keyDisplay, "t")
        XCTAssertEqual(CommandCatalog.builtIn(.newList).keyDisplay, "l")
        XCTAssertEqual(CommandCatalog.builtIn(.addTag).keyDisplay, "@")
        XCTAssertEqual(CommandCatalog.builtIn(.addNoteTag).keyDisplay, "#")
        XCTAssertEqual(CommandCatalog.builtIn(.viewNotes).keyDisplay, "⌘7")
        XCTAssertEqual(CommandCatalog.builtIn(.inlineAddNote).keyDisplay, "n")
        XCTAssertEqual(CommandCatalog.builtIn(.deleteNote).keyDisplay, "d")
    }

    func testNoteCommandsAreListedOnNotesPageOnly() {
        let notes = identities(in: assemble(page: .notes, hasSelection: true))
        XCTAssertTrue(notes.contains(.builtin(.inlineAddNote)))
        XCTAssertTrue(notes.contains(.builtin(.deleteNote)))
        XCTAssertTrue(notes.contains(.builtin(.editNote)))
        XCTAssertTrue(notes.contains(.builtin(.addNoteTag)))
        XCTAssertTrue(notes.contains(.builtin(.openNoteCapture)))
        XCTAssertFalse(notes.contains(.builtin(.inlineAdd)))
        XCTAssertFalse(notes.contains(.builtin(.deleteTask)))
        let list = identities(in: assemble(page: .list, hasSelection: true))
        XCTAssertFalse(list.contains(.builtin(.inlineAddNote)))
        XCTAssertFalse(list.contains(.builtin(.deleteNote)))
        XCTAssertTrue(list.contains(.builtin(.viewNotes)))
    }

    /// `d` 是破壞性操作,`t`/`@` 改的是選中那一筆 — 三者都必須要求選取。
    func testSelectionRequiredCommandsHiddenWithoutSelection() {
        let result = identities(in: assemble(page: .list, hasSelection: false))
        XCTAssertFalse(result.contains(.builtin(.deleteTask)))
        XCTAssertFalse(result.contains(.builtin(.quickDue)))
        XCTAssertFalse(result.contains(.builtin(.addTag)))
    }

    func testSelectionRequiredCommandsShownWithSelection() {
        for page in [CommandPalettePage.list, .grid] {
            let result = identities(in: assemble(page: page, hasSelection: true))
            XCTAssertTrue(result.contains(.builtin(.deleteTask)), "\(page)")
            XCTAssertTrue(result.contains(.builtin(.quickDue)), "\(page)")
            XCTAssertTrue(result.contains(.builtin(.addTag)), "\(page)")
        }
    }

    /// 建 list 與任何任務無關,所以不要求選取;但仍只在清單／象限頁有意義。
    func testNewListNeedsNoSelectionButStaysOnListAndGrid() {
        for page in [CommandPalettePage.list, .grid] {
            XCTAssertTrue(identities(in: assemble(page: page, hasSelection: false))
                .contains(.builtin(.newList)), "\(page)")
        }
        for page in [CommandPalettePage.dash, .settings, .agent] {
            XCTAssertFalse(identities(in: assemble(page: page, hasSelection: true))
                .contains(.builtin(.newList)), "\(page)")
        }
    }

    func testNewCommandsHiddenOnDashAndSettings() {
        for page in [CommandPalettePage.dash, .settings] {
            let result = identities(in: assemble(page: page, hasSelection: true))
            XCTAssertFalse(result.contains(.builtin(.deleteTask)), "\(page)")
            XCTAssertFalse(result.contains(.builtin(.quickDue)), "\(page)")
            XCTAssertFalse(result.contains(.builtin(.addTag)), "\(page)")
        }
    }

    /// `handle` 在 catalog 之前就攔掉這些鍵(vim 移動、象限指派),catalog 綁到它們等於永遠不會觸發。
    /// 這條在 catalog 端把契約釘死,免得下一個人加單鍵時踩到看不見的死鍵。
    func testCatalogAvoidsKeysHardcodedAheadOfItInHandle() {
        let reserved = ["j", "k", "0", "1", "2", "3", "4"]
        for spec in CommandCatalog.builtIns {
            for binding in spec.bindings where !binding.command {
                XCTAssertFalse(reserved.contains(binding.character),
                               "\(spec.id) binds \(binding.character), which `handle` consumes first")
            }
        }
    }

    // MARK: - Scenario: s 切換 List 導覽欄

    func testToggleListRailResolvesFromPlainS() {
        guard case .builtin(let id)? = CommandKeyMatcher.match(
            character: "s", command: false, shift: false, in: CommandCatalog.builtIns
        )?.identity else { return XCTFail("s 沒有解析到任何指令") }
        XCTAssertEqual(id, .toggleListRail)
        XCTAssertEqual(CommandCatalog.builtIn(.toggleListRail).keyDisplay, "s")
    }

    /// `s` 是未修飾單鍵,不該被 ⌘S 誤觸(⌘S 目前無綁定,應原樣放行給系統)。
    func testToggleListRailIsNotBoundToCommandS() {
        XCTAssertNil(CommandKeyMatcher.match(character: "s", command: true, shift: false,
                                             in: CommandCatalog.builtIns))
    }

    /// 切換導覽欄與選了哪一筆任務無關,所以不要求選取;但只在清單／象限頁有意義。
    func testToggleListRailNeedsNoSelectionButStaysOnListAndGrid() {
        for page in [CommandPalettePage.list, .grid] {
            XCTAssertTrue(identities(in: assemble(page: page, hasSelection: false))
                .contains(.builtin(.toggleListRail)), "\(page)")
        }
        for page in [CommandPalettePage.dash, .settings, .agent] {
            XCTAssertFalse(identities(in: assemble(page: page, hasSelection: true))
                .contains(.builtin(.toggleListRail)), "\(page)")
        }
    }

    // MARK: - Scenario: 外掛指令可由指令盤列出 / 未安裝外掛不出現

    func testEnabledInstalledCommandPluginAppearsWhenSelected() {
        let plugin = commandPlugin()
        let result = assemble(page: .list, hasSelection: true, plugins: [plugin])
        XCTAssertTrue(identities(in: result).contains(
            .plugin(pluginID: "app.txtnimal.reschedule-tomorrow", commandID: "reschedule-tomorrow")
        ))
    }

    func testDisabledCommandPluginDoesNotAppear() {
        let plugin = commandPlugin(enabled: false)
        let result = assemble(page: .list, hasSelection: true, plugins: [plugin])
        XCTAssertFalse(identities(in: result).contains {
            if case .plugin = $0 { return true }
            return false
        })
    }

    func testUnlistedPluginDoesNotAppear() {
        let result = assemble(page: .list, hasSelection: true, plugins: [])
        XCTAssertFalse(identities(in: result).contains {
            if case .plugin = $0 { return true }
            return false
        })
    }

    func testPageOnlyPluginWithEmptyCommandsDoesNotAppear() {
        let result = assemble(page: .list, hasSelection: true, plugins: [pageOnlyPlugin()])
        XCTAssertFalse(identities(in: result).contains {
            if case .plugin = $0 { return true }
            return false
        })
    }

    func testSelectionRequiredPluginHiddenWithoutSelection() {
        let plugin = commandPlugin()
        let result = assemble(page: .list, hasSelection: false, plugins: [plugin])
        XCTAssertFalse(identities(in: result).contains(
            .plugin(pluginID: "app.txtnimal.reschedule-tomorrow", commandID: "reschedule-tomorrow")
        ))
    }

    func testSelectionRequiredPluginHiddenOnDash() {
        let plugin = commandPlugin()
        let result = assemble(page: .dash, hasSelection: true, plugins: [plugin])
        XCTAssertFalse(identities(in: result).contains(
            .plugin(pluginID: "app.txtnimal.reschedule-tomorrow", commandID: "reschedule-tomorrow")
        ))
    }

    func testPluginCommandsNeverBindCommandNumberKeys() {
        let plugin = commandPlugin(extraCommands: [
            PluginCommandDeclaration(id: "other", title: "Other")
        ])
        for spec in CommandCatalog.pluginCommands(from: [plugin]) {
            XCTAssertTrue(spec.bindings.isEmpty, "plugin \(spec.id) must not declare a shortcut")
            XCTAssertFalse(["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"].contains(spec.keyDisplay))
        }
    }

    // MARK: - Scenario: 便箋入口不佔 ⌘1–⌘5

    func testScratchIsAlwaysListedAndDoesNotBindNumberKeys() {
        for page in CommandPalettePage.allCases {
            let result = assemble(page: page, hasSelection: false)
            XCTAssertTrue(identities(in: result).contains(.builtin(.openScratch)), "\(page)")
        }
        let scratch = CommandCatalog.builtIn(.openScratch)
        XCTAssertTrue(scratch.bindings.isEmpty)
        XCTAssertEqual(scratch.keyDisplay, "")
        XCTAssertFalse(["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"].contains(scratch.keyDisplay))
        let numberBindings = CommandCatalog.builtIns.flatMap(\.bindings).filter {
            $0.command && ["1", "2", "3", "4", "5"].contains($0.character)
        }
        let owners = numberBindings.compactMap { binding -> BuiltinCommand? in
            CommandCatalog.builtIns.first { $0.bindings.contains(binding) }.flatMap {
                if case .builtin(let id) = $0.identity { return id } else { return nil }
            }
        }
        XCTAssertEqual(Set(owners), [.viewList, .viewGrid, .viewAgent, .viewDash, .viewSettings])
    }

    // MARK: - Scenario: 復原入口

    func testUndoRedoAlwaysListed() {
        let empty = assemble(page: .dash, hasSelection: false)
        XCTAssertTrue(identities(in: empty).contains(.builtin(.undo)))
        XCTAssertTrue(identities(in: empty).contains(.builtin(.redo)))
        XCTAssertEqual(CommandCatalog.builtIn(.undo).keyDisplay, "⌘Z")
        XCTAssertEqual(CommandCatalog.builtIn(.redo).keyDisplay, "⇧⌘Z")
    }

    // MARK: - Scenario: 選單綁定對齊 CommandMenuModel（選單真正的生成來源）

    func testMenuCoversEveryCommandModifierBindingInTheCatalog() {
        for spec in CommandCatalog.builtIns {
            for binding in spec.bindings where binding.command {
                if CommandMenuModel.keylessIdentities.contains(spec.id) {
                    let items = CommandMenuModel.items.filter { $0.identity == spec.identity }
                    XCTAssertEqual(items.count, 1, "\(spec.id) / \(binding.display) keyless")
                    XCTAssertNil(items.first?.key, "\(spec.id) / \(binding.display) keyless")
                } else {
                    XCTAssertTrue(
                        CommandMenuModel.items.contains {
                            $0.identity == spec.identity
                                && $0.key == binding.character
                                && $0.command
                                && $0.shift == binding.shift
                        },
                        "\(spec.id) / \(binding.display)"
                    )
                }
            }
        }
    }

    func testMenuHasNoItemThatTheCatalogDoesNotDeclare() {
        for item in CommandMenuModel.items {
            guard let spec = CommandCatalog.builtIns.first(where: { $0.identity == item.identity }) else {
                XCTFail("menu item \(item.id) has no catalog spec")
                continue
            }
            if CommandMenuModel.keylessIdentities.contains(spec.id) {
                XCTAssertNil(item.key, item.id)
            } else {
                XCTAssertTrue(
                    spec.bindings.contains {
                        $0.command && $0.character == item.key && $0.shift == item.shift
                    },
                    item.id
                )
            }
        }
    }

    func testMenuOmitsCommandsWithNoCommandModifierBinding() {
        for id in [BuiltinCommand.inlineEdit, .newList, .openScratch] {
            XCTAssertFalse(
                CommandMenuModel.items.contains { $0.identity == .builtin(id) },
                "\(id)"
            )
        }
    }

    /// 系統 Edit 選單已經提供 ⌘Z / ⇧⌘Z；File 排在 Edit 之前,
    /// 再綁一次會讓文字欄位裡的 ⌘Z 變成任務復原。
    func testMenuKeepsUndoAndRedoKeyless() {
        for id in [BuiltinCommand.undo, .redo] {
            let items = CommandMenuModel.items.filter { $0.identity == .builtin(id) }
            XCTAssertEqual(items.count, 1, "\(id)")
            XCTAssertNil(items.first?.key, "\(id)")
        }
    }

    func testMenuItemIdsAreUnique() {
        let ids = CommandMenuModel.items.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate menu item id silently drops a ForEach entry")
    }

    func testMenuIncludesThePaletteAndTrashEscapeHatches() {
        XCTAssertTrue(CommandMenuModel.items.contains {
            $0.identity == .builtin(.openPalette) && $0.key == "k" && $0.command && !$0.shift
        }, "⌘K")
        XCTAssertTrue(CommandMenuModel.items.contains {
            $0.identity == .builtin(.viewTrash) && $0.key == "6" && $0.command && !$0.shift
        }, "⌘6")
    }

    func testMenuHasDedicatedItemsForViewSwitchBindings() {
        let expected: [(BuiltinCommand, String)] = [
            (.viewList, "1"), (.viewGrid, "2"), (.viewAgent, "3"),
            (.viewDash, "4"), (.viewSettings, "5"), (.viewSettings, ","),
            (.viewTrash, "6"), (.viewNotes, "7"),
        ]
        for (id, key) in expected {
            XCTAssertTrue(
                CommandMenuModel.items.contains {
                    $0.identity == .builtin(id) && $0.key == key && $0.command
                },
                "\(id) ⌘\(key)"
            )
        }
    }

    // MARK: - fuzzy + query

    func testFuzzySubsequenceAndQueryFilter() {
        XCTAssertTrue(CommandFuzzy.match("lst", "清單視圖 list view"))
        XCTAssertFalse(CommandFuzzy.match("zzz", "清單視圖"))
        let hit = assemble(page: .list, hasSelection: true, query: "便箋")
        XCTAssertEqual(identities(in: hit), [.builtin(.openScratch)])
        let empty = assemble(page: .list, hasSelection: true, query: "zzzz-nope")
        XCTAssertTrue(empty.isEmpty)
    }

    func testOpenPaletteIsNotListed() {
        let result = assemble(page: .list, hasSelection: true)
        XCTAssertFalse(identities(in: result).contains(.builtin(.openPalette)))
    }
}
