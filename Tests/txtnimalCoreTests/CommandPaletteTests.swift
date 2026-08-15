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
        XCTAssertEqual(match("R"), .rescheduleOverdue)
        XCTAssertNil(match("n", command: true), "⌘N is not inline-add; n alone is")
    }

    func testInlineAddIsNotOpenCapture() {
        XCTAssertEqual(CommandCatalog.builtIn(.inlineAdd).keyDisplay, "n")
        XCTAssertTrue(CommandCatalog.builtIn(.openCapture).bindings.isEmpty)
        XCTAssertNotEqual(CommandCatalog.builtIn(.inlineAdd).identity,
                          CommandCatalog.builtIn(.openCapture).identity)
    }

    func testBuiltinHandleBindingsAreUnique() {
        var seen = Set<String>()
        for spec in CommandCatalog.builtIns {
            for binding in spec.bindings {
                let token = "\(binding.command ? "c" : "_")\(binding.shift ? "s" : "_")\(binding.character)"
                XCTAssertTrue(seen.insert(token).inserted, "duplicate binding \(token) on \(spec.id)")
            }
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

    // MARK: - Scenario: 選單綁定對齊主契約

    func testViewSwitchBindingsMatchMenuContract() {
        XCTAssertEqual(CommandCatalog.builtIn(.viewList).bindings.map(\.display), ["⌘1"])
        XCTAssertEqual(CommandCatalog.builtIn(.viewGrid).bindings.map(\.display), ["⌘2"])
        XCTAssertEqual(CommandCatalog.builtIn(.viewAgent).bindings.map(\.display), ["⌘3"])
        XCTAssertEqual(CommandCatalog.builtIn(.viewDash).bindings.map(\.display), ["⌘4"])
        XCTAssertEqual(CommandCatalog.builtIn(.viewSettings).bindings.map(\.display), ["⌘5", "⌘,"])
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
