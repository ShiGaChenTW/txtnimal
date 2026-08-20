import Foundation

/// Pages the command palette can filter against. Mirrors App-layer views without importing SwiftUI.
public enum CommandPalettePage: String, Equatable, Sendable, CaseIterable {
    case list, grid, agent, dash, settings, trash, notes
}

/// Snapshot of UI state the palette (and tests) use to decide what is runnable.
public struct CommandPaletteContext: Equatable, Sendable {
    public var page: CommandPalettePage
    public var hasSelection: Bool

    public init(page: CommandPalettePage, hasSelection: Bool) {
        self.page = page
        self.hasSelection = hasSelection
    }
}

/// When a command may be listed. `pages == nil` means every page.
public struct CommandAvailability: Equatable, Sendable {
    public var pages: Set<CommandPalettePage>?
    public var requiresSelection: Bool

    public static let always = CommandAvailability(pages: nil, requiresSelection: false)
    public static let listGrid = CommandAvailability(pages: [.list, .grid], requiresSelection: false)
    public static let listGridSelection = CommandAvailability(pages: [.list, .grid], requiresSelection: true)
    public static let notes = CommandAvailability(pages: [.notes], requiresSelection: false)
    public static let notesSelection = CommandAvailability(pages: [.notes], requiresSelection: true)

    public init(pages: Set<CommandPalettePage>?, requiresSelection: Bool) {
        self.pages = pages
        self.requiresSelection = requiresSelection
    }

    public func isAvailable(in context: CommandPaletteContext) -> Bool {
        if let pages, !pages.contains(context.page) { return false }
        if requiresSelection && !context.hasSelection { return false }
        return true
    }
}

/// One physical binding. The display string is derived here so the palette never hand-writes keys.
public struct CommandKeyBinding: Equatable, Sendable {
    public var character: String
    public var command: Bool
    public var shift: Bool

    public init(_ character: String, command: Bool = false, shift: Bool = false) {
        self.character = character
        self.command = command
        self.shift = shift
    }

    /// Human-facing glyph. Redo uses the macOS ⇧⌘Z convention; everything else is ⌘ then ⇧ then key.
    public var display: String {
        if command && shift && character.lowercased() == "z" { return "⇧⌘Z" }
        var out = ""
        if command { out += "⌘" }
        if shift { out += "⇧" }
        out += Self.glyph(for: character, command: command)
        return out
    }

    private static func glyph(for character: String, command: Bool) -> String {
        switch character {
        case "\r": return "Enter"
        case " ": return "Space"
        default: return command ? character.uppercased() : character
        }
    }
}

public enum BuiltinCommand: String, Equatable, Sendable, CaseIterable {
    case toggleDone
    case editPopup
    case inlineEdit
    case toggleFocus
    case focusMode
    case inlineAdd
    case openCapture
    case addList
    case addTag
    case newList
    case deleteTask
    case quickDue
    case search
    case rescheduleOverdue
    case densityTighter
    case densityLooser
    case toggleListRail
    case viewList
    case viewGrid
    case viewAgent
    case viewDash
    case viewSettings
    case viewTrash
    case viewNotes
    case cycleAppearance
    case openPalette
    case undo
    case redo
    case openScratch
    case inlineAddNote
    case deleteNote
    case editNote
    case addNoteTag
    case openNoteCapture
}

public enum CommandIdentity: Equatable, Sendable {
    case builtin(BuiltinCommand)
    case plugin(pluginID: String, commandID: String)
}

/// Declaration shared by `ContentView.handle` and the ⌘K palette. No closures — actions stay in App.
public struct CommandSpec: Equatable, Identifiable, Sendable {
    public let identity: CommandIdentity
    public let name: String
    public let alias: String
    public let bindings: [CommandKeyBinding]
    public let availability: CommandAvailability
    public let showsInPalette: Bool

    public init(identity: CommandIdentity, name: String, alias: String,
                bindings: [CommandKeyBinding], availability: CommandAvailability,
                showsInPalette: Bool = true) {
        self.identity = identity
        self.name = name
        self.alias = alias
        self.bindings = bindings
        self.availability = availability
        self.showsInPalette = showsInPalette
    }

    public var id: String {
        switch identity {
        case .builtin(let command): return "builtin.\(command.rawValue)"
        case .plugin(let pluginID, let commandID): return "plugin.\(pluginID).\(commandID)"
        }
    }

    /// First binding's derived display. Empty when the command is palette-only (no key).
    public var keyDisplay: String { bindings.first?.display ?? "" }
}

/// Built-in commands plus enabled command plugins. This is the single source of shortcut truth.
public enum CommandCatalog {
    public static let builtIns: [CommandSpec] = [
        spec(.toggleDone, name: "完成 / 取消完成", alias: "done toggle",
             bindings: [.init("x"), .init(" "), .init("\r", command: true)],
             availability: .listGridSelection),
        spec(.editPopup, name: "編輯任務", alias: "edit popup",
             bindings: [.init("e", command: true)],
             availability: .listGridSelection),
        spec(.inlineEdit, name: "行內編輯", alias: "inline edit rename",
             bindings: [.init("e")],
             availability: .listGridSelection),
        spec(.toggleFocus, name: "Focus 這一件", alias: "focus",
             bindings: [.init("f"), .init("f", command: true, shift: true)],
             availability: .listGridSelection),
        spec(.focusMode, name: "專注模式", alias: "zen focus mode",
             bindings: [.init("z")],
             availability: .listGrid),
        spec(.inlineAdd, name: "行內新增", alias: "new add inline",
             bindings: [.init("n"), .init("b", command: true)],
             availability: .listGrid),
        spec(.openCapture, name: "新增捕捉", alias: "new capture add",
             bindings: [],
             availability: .listGrid),
        spec(.addList, name: "加 +List", alias: "project list",
             bindings: [.init("p")],
             availability: .listGridSelection),
        spec(.addTag, name: "加 @Tag", alias: "context tag at",
             bindings: [.init("@")],
             availability: .listGridSelection),
        // 建 list 與任何一筆任務無關,所以不要求選取 — 這是它與 `.addList` 的分野。
        spec(.newList, name: "新增 List", alias: "new list create project",
             bindings: [.init("l")],
             availability: .listGrid),
        spec(.deleteTask, name: "刪除任務", alias: "delete remove task dd",
             bindings: [.init("d")],
             availability: .listGridSelection),
        spec(.quickDue, name: "改到期日", alias: "due date reschedule when time",
             bindings: [.init("t")],
             availability: .listGridSelection),
        spec(.search, name: "搜尋", alias: "search find filter",
             bindings: [.init("/"), .init("f", command: true)],
             availability: .always),
        spec(.rescheduleOverdue, name: "逾期全改今天", alias: "reschedule overdue today",
             bindings: [.init("R")],
             availability: .always),
        spec(.densityTighter, name: "行距更緊", alias: "density compact tighter",
             bindings: [.init("[")],
             availability: .always),
        spec(.densityLooser, name: "行距更鬆", alias: "density relaxed looser",
             bindings: [.init("]")],
             availability: .always),
        spec(.toggleListRail, name: "顯示／隱藏 List 導覽欄", alias: "toggle list rail sidebar nav",
             bindings: [.init("s")],
             availability: .listGrid),
        spec(.viewList, name: "清單視圖", alias: "list view",
             bindings: [.init("1", command: true)],
             availability: .always),
        spec(.viewAgent, name: "Agent", alias: "agent ai reschedule",
             bindings: [.init("3", command: true)],
             availability: .always),
        spec(.viewGrid, name: "象限視圖", alias: "quadrant grid matrix",
             bindings: [.init("2", command: true)],
             availability: .always),
        spec(.viewDash, name: "統計", alias: "stats dashboard charts",
             bindings: [.init("4", command: true)],
             availability: .always),
        spec(.viewSettings, name: "設定", alias: "settings preferences",
             bindings: [.init("5", command: true), .init(",", command: true)],
             availability: .always),
        // ⌘6 — ⌘1–⌘5 are the five original views and stay exactly where they are.
        spec(.viewTrash, name: "垃圾桶", alias: "trash bin deleted recycle restore",
             bindings: [.init("6", command: true)],
             availability: .always),
        // ⌘7 — notes is an independent feature, not a seventh task view.
        spec(.viewNotes, name: "筆記", alias: "notes memo jot",
             bindings: [.init("7", command: true)],
             availability: .always),
        spec(.inlineAddNote, name: "新增筆記", alias: "new add note inline",
             bindings: [.init("n")],
             availability: .notes),
        spec(.deleteNote, name: "刪除筆記", alias: "delete remove note dd",
             bindings: [.init("d")],
             availability: .notesSelection),
        spec(.editNote, name: "編輯筆記", alias: "edit note popup",
             bindings: [.init("e")],
             availability: .notesSelection),
        spec(.addNoteTag, name: "加 #Tag", alias: "note tag hash",
             bindings: [.init("#")],
             availability: .notesSelection),
        spec(.openNoteCapture, name: "捕捉筆記", alias: "note capture quick add",
             bindings: [],
             availability: .always),
        spec(.cycleAppearance, name: "深 / 淺主題", alias: "theme dark light appearance",
             bindings: [.init("t", command: true, shift: true)],
             availability: .always),
        spec(.openPalette, name: "指令面板", alias: "command palette",
             bindings: [.init("k", command: true)],
             availability: .always, showsInPalette: false),
        spec(.undo, name: "復原", alias: "undo",
             bindings: [.init("z", command: true)],
             availability: .always),
        spec(.redo, name: "重做", alias: "redo",
             bindings: [.init("z", command: true, shift: true)],
             availability: .always),
        spec(.openScratch, name: "開啟便箋", alias: "scratch note pad",
             bindings: [],
             availability: .always),
    ]

    public static func builtIn(_ id: BuiltinCommand) -> CommandSpec {
        builtIns.first { $0.identity == .builtin(id) }!
    }

    /// Enabled registry entries that declare `commands`. Unlisted or disabled plugins never appear.
    public static func pluginCommands(from entries: [PluginRegistryEntry]) -> [CommandSpec] {
        entries
            .filter(\.enabled)
            .sorted { $0.manifest.id < $1.manifest.id }
            .flatMap { entry -> [CommandSpec] in
                let availability: CommandAvailability =
                    entry.manifest.capabilities.contains(.tasksSelectedRead)
                    ? .listGridSelection
                    : .always
                return entry.manifest.commands.map { command in
                    CommandSpec(
                        identity: .plugin(pluginID: entry.manifest.id, commandID: command.id),
                        name: command.title,
                        alias: "\(entry.manifest.name) plugin \(command.id)",
                        bindings: [],
                        availability: availability
                    )
                }
            }
    }
}

/// Subsequence fuzzy match used by the palette search box.
public enum CommandFuzzy {
    public static func match(_ query: String, _ target: String) -> Bool {
        var rest = Substring(query.lowercased())
        for ch in target.lowercased() where ch == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }
}

/// Resolve a key event against the catalog. Command keys compare case-insensitively and honor Shift.
///
/// Single-key letters cannot use raw `charactersIgnoringModifiers` equality:
/// Caps Lock turns `n` into `"N"` without setting `.shift`, so every lowercase
/// shortcut died, and `r` quietly became「逾期全改今天」. Lowercase letter
/// bindings match the key ignoring Caps Lock, but not when Shift is held.
/// Uppercase letter bindings (`R`) require Shift — Caps Lock alone must not
/// fire them. Non-letters (`@`, `/`, `[`) still compare the produced character.
public enum CommandKeyMatcher {
    public static func match(character: String, command: Bool, shift: Bool,
                             in commands: [CommandSpec],
                             availableIn context: CommandPaletteContext? = nil) -> CommandSpec? {
        commands.first { spec in
            if let context, !spec.availability.isAvailable(in: context) { return false }
            return spec.bindings.contains { binding in
                keysMatch(binding: binding, character: character, command: command, shift: shift)
            }
        }
    }

    public static func keysMatch(binding: CommandKeyBinding, character: String,
                                 command: Bool, shift: Bool) -> Bool {
        if binding.command {
            return command
                && binding.character.lowercased() == character.lowercased()
                && binding.shift == shift
        }
        guard !command else { return false }
        return singleKeyMatches(bindingCharacter: binding.character, typed: character, shift: shift)
    }

    public static func singleKeyMatches(bindingCharacter: String, typed: String, shift: Bool) -> Bool {
        if isSingleLetter(bindingCharacter), isSingleLetter(typed) {
            guard bindingCharacter.lowercased() == typed.lowercased() else { return false }
            return isUppercaseLetter(bindingCharacter) ? shift : !shift
        }
        return bindingCharacter == typed
    }

    public static func isSingleLetter(_ s: String) -> Bool {
        s.count == 1 && s.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    public static func isUppercaseLetter(_ s: String) -> Bool {
        isSingleLetter(s) && s == s.uppercased()
    }
}

/// Assemble the visible palette: built-ins + enabled command plugins, then page/selection/query filters.
public enum CommandPaletteAssembler {
    public static func assemble(plugins: [PluginRegistryEntry],
                                context: CommandPaletteContext,
                                query: String = "") -> [CommandSpec] {
        let commands = CommandCatalog.builtIns.filter(\.showsInPalette)
            + CommandCatalog.pluginCommands(from: plugins)
        return commands.filter { spec in
            spec.availability.isAvailable(in: context)
                && CommandFuzzy.match(query, spec.name + " " + spec.alias)
        }
    }
}

/// 選單列項目的唯一來源。App 層只負責把它畫成 Button,不再手抄一份快捷鍵。
public enum CommandMenuModel {
    public struct Item: Equatable, Sendable, Identifiable {
        public let identity: CommandIdentity
        public let title: String
        /// `nil` = 這個項目刻意不搶鍵(見 undo/redo 說明)。
        public let key: String?
        public let command: Bool
        public let shift: Bool
        public var id: String {
            let identityID: String
            switch identity {
            case .builtin(let command): identityID = "builtin.\(command.rawValue)"
            case .plugin(let pluginID, let commandID): identityID = "plugin.\(pluginID).\(commandID)"
            }
            return identityID + "|" + (key ?? "-") + (command ? "c" : "") + (shift ? "s" : "")
        }
    }

    /// 系統 Edit 選單已經提供 ⌘Z / ⇧⌘Z（SwiftUI 只換掉 `.newItem`，`.undoRedo` 仍是預設）。
    /// 我們再綁一次會讓同一顆鍵有兩個選單擁有者,且 File 選單排在 Edit 之前會贏 ——
    /// 那會讓「在文字欄位裡按 ⌘Z」變成任務復原而不是復原打字,是退步。
    /// 所以這兩個指令仍然進選單(可點、可被指令盤列出),但不帶鍵。
    public static let keylessIdentities: Set<String> = ["builtin.undo", "builtin.redo"]

    /// 每一個帶 ⌘ 的 catalog 綁定各生一個項目。`.viewSettings` 有 ⌘5 與 ⌘, 兩個綁定,
    /// 就會生出兩個項目 —— 這是刻意的,兩顆鍵都要有選單擁有者。
    public static var items: [Item] {
        CommandCatalog.builtIns.flatMap { spec -> [Item] in
            let cmdBindings = spec.bindings.filter(\.command)
            if cmdBindings.isEmpty { return [] }
            if keylessIdentities.contains(spec.id) {
                return [Item(identity: spec.identity, title: spec.name,
                             key: nil, command: false, shift: false)]
            }
            return cmdBindings.map { binding in
                Item(identity: spec.identity, title: spec.name,
                     key: binding.character, command: true, shift: binding.shift)
            }
        }
    }
}

private func spec(_ id: BuiltinCommand, name: String, alias: String,
                  bindings: [CommandKeyBinding], availability: CommandAvailability,
                  showsInPalette: Bool = true) -> CommandSpec {
    CommandSpec(identity: .builtin(id), name: name, alias: alias,
                bindings: bindings, availability: availability, showsInPalette: showsInPalette)
}
