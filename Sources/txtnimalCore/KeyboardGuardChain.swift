import Foundation

/// `handle()` 讀得到的 keyCode 常數,免得測試裡散落魔術數字。
public enum KeyCodes {
    public static let escape: UInt16 = 53
    public static let returnKey: UInt16 = 36
    public static let arrowUp: UInt16 = 126
    public static let arrowDown: UInt16 = 125
}

/// 一次按鍵的物理描述。`characters` 對應 NSEvent.charactersIgnoringModifiers。
public struct KeyStroke: Equatable, Sendable {
    public var characters: String
    public var keyCode: UInt16
    public var command: Bool
    public var shift: Bool

    public init(characters: String = "", keyCode: UInt16 = 0,
                command: Bool = false, shift: Bool = false) {
        self.characters = characters
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
    }
}

/// 按下那一刻的 UI 狀態。每個欄位都對應 `handle()` 裡的一道守門。
public struct KeyboardGuardState: Equatable, Sendable {
    public var paletteOpen: Bool           // ⌘K 面板
    public var editPopupOpen: Bool         // ⌘E 編輯彈窗
    public var textEntryOverlayOpen: Bool  // 捕捉列 / 加 List / 加 Tag / 便箋 / List 編輯視窗
    public var inlineEditActive: Bool      // 行內編輯中(store.editingIndex != nil)
    public var inlineAddActive: Bool
    public var searchFocused: Bool         // 搜尋欄位「真的有焦點」,不是「搜尋列在不在」
    public var focusMode: Bool
    public var searchActive: Bool          // esc 分層清除用
    public var tagFilterActive: Bool       // esc 分層清除用
    public var page: CommandPalettePage
    public var hasSelection: Bool

    public init(paletteOpen: Bool = false, editPopupOpen: Bool = false,
                textEntryOverlayOpen: Bool = false, inlineEditActive: Bool = false,
                inlineAddActive: Bool = false, searchFocused: Bool = false,
                focusMode: Bool = false, searchActive: Bool = false,
                tagFilterActive: Bool = false, page: CommandPalettePage = .list,
                hasSelection: Bool = false) {
        self.paletteOpen = paletteOpen
        self.editPopupOpen = editPopupOpen
        self.textEntryOverlayOpen = textEntryOverlayOpen
        self.inlineEditActive = inlineEditActive
        self.inlineAddActive = inlineAddActive
        self.searchFocused = searchFocused
        self.focusMode = focusMode
        self.searchActive = searchActive
        self.tagFilterActive = tagFilterActive
        self.page = page
        self.hasSelection = hasSelection
    }

    /// 給 `CommandAvailability.isAvailable` 用。
    public var commandContext: CommandPaletteContext {
        CommandPaletteContext(page: page, hasSelection: hasSelection)
    }
}

/// 守門鏈判定要做的事。`handle()` 只負責把它翻成對 store 的呼叫。
public enum KeyboardAction: Equatable, Sendable {
    case command(CommandIdentity)
    case moveCursor(Int)
    case startInlineEdit
    case clearSearch
    case clearTagFilter
    case clearFocus
    case leaveToList        // 唯讀頁 / 設定頁 esc 回清單
    case exitFocusMode
    case setQuadrant(Int?)  // nil = 移回未歸位池
}

public enum KeyboardDecision: Equatable, Sendable {
    case passThrough   // 對應 `return e` —— 交給欄位 / 選單 / 系統
    case swallow       // 對應 `return nil` 但不做事
    case act(KeyboardAction)
}

public enum KeyboardGuardChain {
    /// 這兩個指令刻意不參與「cmd 先於文字守門」那一步。系統 Edit 選單本來就擁有
    /// ⌘Z / ⇧⌘Z，聚焦中的文字欄位靠它拿到標準的「復原打字」；把 undo/redo 也提前，
    /// 等於在文字欄位裡把 ⌘Z 從「復原我剛打的字」換成「復原上一個任務動作」。
    /// 這和 `CommandMenuModel.keylessIdentities`（CommandPalette.swift L320）是同一個
    /// 理由的兩半：那邊不讓選單搶鍵，這邊不讓 monitor 搶鍵。
    public static let commandsDeferredToTextEntry: [CommandIdentity] = [
        .builtin(.undo), .builtin(.redo),
    ]

    public static func decide(_ stroke: KeyStroke, state: KeyboardGuardState,
                              commands: [CommandSpec] = CommandCatalog.builtIns) -> KeyboardDecision {
        // ContentView 自己先攔掉 ↑ ↓ ⏎ esc 四顆導覽鍵,其餘一律給面板的輸入框 ——
        // 所以對守門鏈而言,面板開著時沒有任何 catalog 指令會觸發。
        if state.paletteOpen { return .passThrough }

        // 彈窗自己處理 ↓ / esc / Tab,其餘給欄位。
        if state.editPopupOpen { return .passThrough }

        // 任何正在收文字的浮窗都要先放行,否則使用者打的字會被當成單鍵命令吃掉。
        // `listEditorActive` 是 ListView 的 List 編輯視窗 — `l` 讓它變成一個按鍵就到得了,
        // 沒有這道守門,在裡面打名稱會誤觸 d（刪除確認）等破壞性單鍵。
        //
        // `inlineEditActive` 這一條是新加的。行內編輯的 TextField 有焦點時,`handle()`
        // 仍然先看到按鍵,而 `d`/`x`/`e` 都是 catalog 單鍵 —— 打字打到 `d` 會跳出刪除確認。
        // 原本的守門只擋捕捉列與 List 編輯視窗,漏了行內編輯。
        if state.textEntryOverlayOpen || state.inlineEditActive { return .passThrough }

        // 設定頁整頁放行（見下一條守門）是因為它有可編輯欄位：使用者名稱、兩個熱鍵錄製器、
        // agent 端點與模型。但狀態列白紙黑字寫著「esc / ⌘1 回清單」，而整頁放行讓那句話
        // 變成謊言 —— 這裡只把 esc 這一顆鍵挑出來處理，其餘按鍵維持原樣放行給欄位。
        if state.page == .settings && stroke.keyCode == KeyCodes.escape {
            return .act(.leaveToList)
        }

        // 命中 catalog 的 cmd 綁定先算出來，下面兩個地方共用。
        let commandSpec = stroke.command
            ? CommandKeyMatcher.match(character: stroke.characters, command: true,
                                      shift: stroke.shift, in: commands)
            : nil

        // cmd 分支排在文字守門之前。理由是側邊面板模式（⌥T）：面板是 nonactivating panel，
        // 拿到鍵盤時 app 不是最前景，選單列屬於別的 app，所以「放行給選單」那條後備路徑
        // 完全不會觸發 —— 在那些狀態下放行等於讓 ⌘K / ⌘E / ⌘6 沒有任何消費者。
        // 代價是聚焦中的文字欄位不再吃得到這些鍵；這是知情後選的取捨。
        // 唯一的例外是 ⌘Z / ⇧⌘Z，見 `commandsDeferredToTextEntry`。
        if let spec = commandSpec, !commandsDeferredToTextEntry.contains(spec.identity) {
            guard spec.availability.isAvailable(in: state.commandContext) else { return .passThrough }
            return .act(.command(spec.identity))
        }

        // NSTextField 的 field editor 也是 NSTextView，且切頁後可能短暫保留；只在確實
        // 顯示文字輸入介面時放行，避免它吞掉清單的 n/e/x 等單鍵命令。
        //
        // 搜尋看的是「欄位是不是真的有焦點」，不是「搜尋列在不在」：⏎ 之後篩選與搜尋列
        // 都還在（`store.searchActive` 仍為 true，這是刻意的），但鍵盤流已經交還清單，
        // 此時單鍵必須全部恢復作用。看 `searchActive` 會讓按過 ⏎ 的使用者
        // 卡在一個所有快捷鍵都失效、連 esc 都救不回來的狀態。
        //
        // 走到這裡的只剩下：非 cmd 的單鍵，以及刻意留給文字欄位的 ⌘Z / ⇧⌘Z。
        if state.inlineAddActive || state.page == .agent || state.page == .settings || state.searchFocused {
            return .passThrough
        }

        // 剛剛被放行的 ⌘Z / ⇧⌘Z 在這裡把 cmd 分支走完。這一步仍排在唯讀頁守門之前，
        // 所以必須自己檢查可用性，否則指令會作用到清單裡那個看不見的游標。
        //
        // 這裡刻意用 `if stroke.command` 而不是 `if let spec = commandSpec`：任何帶 ⌘ 的
        // 按鍵都必須在這裡結束，沒命中 catalog 的（⌘A / ⌘C / ⌘V …）要放行給系統。
        // 只看 commandSpec 會讓它們掉進下面的專注模式與唯讀頁守門被 `.swallow` 吃掉，
        // 等於在統計／垃圾桶頁和專注模式下弄壞複製貼上 —— 那是這次重排不該有的副作用。
        if stroke.command {
            guard let spec = commandSpec,
                  spec.availability.isAvailable(in: state.commandContext) else { return .passThrough }
            return .act(.command(spec.identity))
        }

        if state.focusMode {
            if stroke.characters == "z" || stroke.keyCode == KeyCodes.escape {
                return .act(.exitFocusMode)
            }
            return .swallow
        }

        // 統計/設定/垃圾桶唯讀:單鍵動詞不得作用在看不見的游標上;esc 回清單。
        // 垃圾桶特別重要——d(刪除)若在這裡生效,會作用到清單裡看不見的那個游標。
        if state.page == .dash || state.page == .settings || state.page == .trash {
            if stroke.keyCode == KeyCodes.escape { return .act(.leaveToList) }
            return .swallow
        }

        switch stroke.keyCode {
        case KeyCodes.arrowUp: return .act(.moveCursor(-1))
        case KeyCodes.arrowDown: return .act(.moveCursor(1))
        case KeyCodes.returnKey: return .act(.startInlineEdit)
        case KeyCodes.escape:
            // esc：搜尋 → 標籤篩選 → Focus,逐層清
            if state.searchActive { return .act(.clearSearch) }
            if state.tagFilterActive { return .act(.clearTagFilter) }
            return .act(.clearFocus)
        default: break
        }

        switch stroke.characters {
        case "k": return .act(.moveCursor(-1))
        case "j": return .act(.moveCursor(1))
        case "1", "2", "3", "4":
            return state.page == .grid ? .act(.setQuadrant(Int(stroke.characters))) : .passThrough
        case "0":
            return state.page == .grid ? .act(.setQuadrant(nil)) : .passThrough
        default:
            // 這裡不加 availability 檢查。第 8 步已經吞掉唯讀頁;
            // 加上去會改變今天「沒選中那一列」時單鍵動詞仍會觸發的行為。
            if let spec = CommandKeyMatcher.match(character: stroke.characters, command: false,
                                                  shift: false, in: commands) {
                return .act(.command(spec.identity))
            }
            return .passThrough
        }
    }
}
