# 快捷鍵地圖

> **契約**：本文件的行號對應當下 `App/` 與 `Sources/txtnimalCore/` 的原始碼。
> 改動鍵盤相關程式碼時一併更新行號；行號漂掉的文件比沒有文件更糟。
>
> 最後校對：2026-08-21（全篇行號重新對過；行內編輯判定搬進 `InlineEditGate`）

## 唯一真相在哪裡

| 東西 | 檔案 | 位置 |
|------|------|------|
| **綁定表**（哪顆鍵對應哪個指令、在哪些頁面可用） | `Sources/txtnimalCore/CommandPalette.swift` | `CommandCatalog.builtIns`，L148 |
| **守門鏈**（某個狀態下這顆鍵會被吃掉、放行、還是執行） | `Sources/txtnimalCore/KeyboardGuardChain.swift` | `KeyboardGuardChain.decide`，L110 |
| **選單列項目**（每個帶 ⌘ 的綁定的後備入口） | `Sources/txtnimalCore/CommandPalette.swift` | `CommandMenuModel.items`，L381 |
| NSEvent 轉接層 | `App/ContentView.swift` | `handle(_:)`，L1228 |
| 判定 → 對 store 的實際呼叫 | `App/ContentView.swift` | `apply(_:)`，L1124 |
| 指令實作 | `App/ContentView.swift` | `perform(_:)`，L1066 |
| **行內編輯判定**（`e`／⏎ 要編輯哪一個東西） | `Sources/txtnimalCore/InlineEditGate.swift` | `InlineEditGate.route`，L27 |
| **切頁**（唯一入口；會清 focusMode／editingIndex／searchFocused） | `App/TaskStore.swift` | `switchView(to:ensureCursor:)`，L355 |
| 選單列繪製 | `App/txtnimalApp.swift` | `CommandGroup(replacing: .newItem)` L23、`menuButton(_:)` L78 |

新增一顆快捷鍵**只**要改 `CommandCatalog.builtIns`：守門鏈、指令面板與選單列都是從它生出來的。
手抄第二份的下場見 `CHANGELOG.md`（選單與 `handle()` 對 ⌘2／⌘4 各說各話那次）。

## 兩條派送路徑

一顆鍵有兩個可能的消費者，兩條路都通到同一個 `perform()`：

1. **本地 monitor** — `ContentView.installMonitor()`（L1214）裝的 `NSEvent` local monitor。
   絕大多數情況走這條。
2. **選單列** — monitor 放行（`.passThrough`）時，事件會繼續走到 SwiftUI 的主選單。
   選單按鈕呼叫 `TaskStore.requestCommand(_:)`（`App/TaskStore.swift` L347），
   經 `@Published commandRequest`（L344）回到 `ContentView` 的
   `.onChange(of: store.commandRequest)`（L110），再進 `perform()`。

第 2 條仍是每個 ⌘ 綁定的保證後備入口：`CommandMenuModel` 覆蓋它們，
`CommandPaletteTests` 直接對它斷言（不是對手抄的字面值）。
它不再是那些狀態下的**唯一**消費者——cmd 分支已排在文字守門之前，
行內新增 / Agent 頁 / 設定頁 / 搜尋欄位有焦點時，⌘1 這類鍵由 monitor 直接執行。
唯一仍只靠放行的是 ⌘Z / ⇧⌘Z：系統 Edit 選單本來就擁有它們，
放行才能讓聚焦中的文字欄位做「復原打字」。

## 守門鏈順序

`KeyboardGuardChain.decide`（`KeyboardGuardChain.swift` L110）由上而下：

| # | 條件 | 結果 |
|---|------|------|
| 1 | 指令面板開著 | 放行（面板自己先攔 ↑ ↓ ⏎ esc） |
| 2 | ⌘E 編輯彈窗開著 | 放行（彈窗自己處理 ↓ / esc / Tab） |
| 3 | 捕捉列 / sheet / 便箋 / List 編輯視窗 / 系統 alert | 放行 |
| 4 | 設定頁 + esc | 回清單 |
| 5 | 帶 ⌘ 且命中 catalog 且該頁可用（⌘Z / ⇧⌘Z 除外） | 執行指令 |
| 6 | **確認中的文字面**（field editor + 搜尋／新增／改名）／ Agent 頁 / 設定頁 | 放行 |
| 7 | 專注模式 | `z` 或 esc 離開，**其餘全吞** |
| 8 | 統計 / 設定 / 垃圾桶頁 | esc 回清單，其餘全吞 |
| 9 | ↑ ↓ ⏎ esc | 移動游標 / 行內編輯 / esc 分層清除 |
| 10 | `j` `k` `0`–`4` | 移動游標 / 象限指派（`0`–`4` 只在象限頁） |
| 11 | 命中 catalog 單鍵 | 執行指令 |

第 6 步必須 **field editor 與文字面旗標同時成立**。只認 field editor：SwiftUI 常把共用
NSTextView 留成 first responder，`s`／`n` 會被放行到沒人收的地方。只認旗標：旗標過期時同一顆鍵也會死。

單鍵字母比對忽略 Caps Lock（`N` 仍是新增），但 `R`（逾期全改今天）必須真的按 Shift；
只開 Caps Lock 不會觸發。`j`／`k` 同樣忽略 Caps Lock。

第 5 步的例外是 ⌘Z / ⇧⌘Z：它們刻意不參與「cmd 先於文字守門」，
見 `KeyboardGuardChain.commandsDeferredToTextEntry`（L106）。
過了第 6 步之後，這兩顆鍵仍會走完 cmd 分支，所以清單／專注／統計頁的任務復原不變。

**任何帶 ⌘ 的按鍵都在 cmd 分支結束，不會往下掉。** 沒命中 catalog 的（⌘A / ⌘C / ⌘V …）
一律放行給系統。這條性質在重排時很容易弄丟：讓它們掉進第 7 步或第 8 步就會被吞掉，
統計頁與專注模式下的複製貼上會無聲失效。
`testUnmatchedCommandKeysAlwaysPassThroughToTheSystem` 是它的圍籬。

按 ⏎ 之後篩選與搜尋列都還在（`searchActive` 仍為 true，這是刻意的），
但鍵盤流已經交還清單，單鍵必須全部恢復作用。
走到這一步的只剩下非 cmd 單鍵，以及刻意留給文字欄位的 ⌘Z / ⇧⌘Z。

`s` 只聽 `listRailVisible`。沒有 +List 時欄裡仍有 All tasks。側邊面板（⌥T）同樣顯示／隱藏導覽欄；面板太窄時打開會一併拉寬。

## ⚠️ 專注模式會吞掉所有未修飾單鍵

在專注模式（清單／象限頁按 `z` 進入，`TaskStore.toggleFocusMode()` 於
`App/TaskStore.swift` L1771）底下：

- **只有 `z` 與 `Esc` 有作用**，兩者都是離開專注模式。
- 其他未修飾單鍵（`n` `d` `x` `e` `j` `k` …）**全部被吞掉，沒有任何回饋**。
- 帶 ⌘ 的快捷鍵**仍然有效** —— 守門鏈第 5 步排在第 7 步之前，
  所以 ⌘1 可以直接切頁離開（切頁也會順手把專注模式關掉）。

這是刻意設計：專注模式的重點就是畫面只剩一件事、不要有別的操作。
畫面上唯一的提示是變暗的遮罩（`ContentView.swift` L73 掛載、L415 定義）。
但對忘記自己還在專注模式的使用者來說，這看起來就是「快捷鍵壞了」——
所以寫在這裡，也寫在 README（`README.md` 快捷鍵表下方的警告框）。要離開就按 `z` 或 `Esc`。

**這是規格，不是缺陷，所以它有圍籬**：`testFocusModeSwallowsEverythingExceptZAndEscape`
（`Tests/txtnimalCoreTests/KeyboardGuardChainTests.swift` L354）。誰哪天覺得「單鍵在專注模式下
沒反應是 bug」而把第 7 步放行，那個測試會紅。要改這個行為就連同這一節與 README 一起改。

## 切頁會清掉的狀態

**唯一切頁入口**是 `TaskStore.switchView(to:ensureCursor:)`。頁籤點擊、窄版下拉、
統計 drill-down、Agent「前往設定」、`n`／`l`、⌘1–⌘7 都必須走它，`view` 是
`private(set)`。它會：

- 清 `store.focusMode` —— 否則新頁面繼續吞掉所有單鍵。
- 清 `store.editingIndex` —— 否則行內改名的旗標跨頁存活。
- 遞增 `keyboardResetSeq`，ContentView 的 `onChange` 據此把 `@FocusState searchFocused`
  設回 false。

即使目標頁跟現在同一頁也會跑一次，所以在清單上按 ⌘1 仍能離開專注模式。

## 側邊面板模式：cmd 快捷鍵改由 monitor 直接處理

側邊面板（⌥T）是 `[.borderless, .nonactivatingPanel]` 的
`KeyablePanel`（`App/GlobalCapture.swift` L26、L115），
`reveal()`（L204）用 `makeKeyAndOrderFront` 讓它成為 key window，
但**全程沒有呼叫 `NSApp.activate`**。

所以面板拿到鍵盤時，txtnimal 不是最前景 app，選單列屬於別的 app：

- 本地 monitor（路徑 1）照常運作。
- 選單後備（路徑 2）**完全不會觸發**。

已選定並落地第二條路：把 cmd 分支排到文字守門之前（現在的第 5 步）。
行內新增 / Agent 頁 / 設定頁 / 搜尋欄位有焦點時，⌘K / ⌘E / ⌘6 / ⌘7 由 monitor 直接執行。
知情的代價是：這些狀態不再把 ⌘ 鍵交給聚焦中的文字欄位。

唯一刻意的例外是 ⌘Z / ⇧⌘Z。系統 Edit 選單本來就擁有它們；
放行才能讓聚焦中的欄位做「復原打字」，而不是把「復原我剛打的字」換成「復原上一個任務動作」。
這和 `KeyboardGuardChain.commandsDeferredToTextEntry`（L106）與
`CommandMenuModel.keylessIdentities`（`CommandPalette.swift` L377）是同一個理由的兩半：
那邊不讓選單搶鍵，這邊不讓 monitor 搶鍵。

## 獨立筆記（⌘7 / ⌥N）

筆記不是 task 的 `note:"…"`，也不是 `scratch.txt`。資料在同資料夾的 `notes.txt`。

| 鍵 | 行為 |
|---|---|
| `⌘7` | 切到筆記頁 |
| `⌥N`（設定可重綁） | 全域捕捉筆記，與 ⌥Space 任務捕捉分開 |
| `n`（僅筆記頁） | 行內新增 |
| `e` / `Enter`（僅筆記頁） | 編輯選中筆記 |
| `d`（僅筆記頁） | 刪除選中筆記（確認框） |
| `d` `d` | 0.4 秒內連按兩下：直接刪、不跳確認。清單／象限／筆記頁都一樣。單次 `d` 仍確認。實作在 `ContentView.handleTaskDeleteKey` / `handleNoteDeleteKey`，判定在 `RepeatKey.isDoubleTap`。 |
| `#`（僅筆記頁） | 加 tag |
| `s` / `x` / `p` / `@` | 在筆記頁被吞掉，不會打到清單裡看不見的游標 |

捕捉時用前後符號決定呈現：

- `- 牛奶; 雞蛋 -` → 條列
- `"一句話"` 或 `> 一句話 <` → 引言
- `| 整塊 |` → 區塊
- 其餘 → 段落

`#tag` 會從正文剝出來，用來篩選與「依 #Tag 分組」。
