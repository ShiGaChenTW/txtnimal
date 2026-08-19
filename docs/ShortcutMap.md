# 快捷鍵地圖

> **契約**：本文件的行號對應當下 `App/` 與 `Sources/txtnimalCore/` 的原始碼。
> 改動鍵盤相關程式碼時一併更新行號；行號漂掉的文件比沒有文件更糟。
>
> 最後校對：2026-08-19（cmd 分支提前到文字守門之前）

## 唯一真相在哪裡

| 東西 | 檔案 | 位置 |
|------|------|------|
| **綁定表**（哪顆鍵對應哪個指令、在哪些頁面可用） | `Sources/txtnimalCore/CommandPalette.swift` | `CommandCatalog.builtIns`，L140 |
| **守門鏈**（某個狀態下這顆鍵會被吃掉、放行、還是執行） | `Sources/txtnimalCore/KeyboardGuardChain.swift` | `KeyboardGuardChain.decide`，L95 |
| **選單列項目**（每個帶 ⌘ 的綁定的後備入口） | `Sources/txtnimalCore/CommandPalette.swift` | `CommandMenuModel.items`，L324 |
| NSEvent 轉接層 | `App/ContentView.swift` | `handle(_:)`，L1117 |
| 判定 → 對 store 的實際呼叫 | `App/ContentView.swift` | `apply(_:)`，L1033 |
| 指令實作 | `App/ContentView.swift` | `perform(_:)`，L989 |
| 選單列繪製 | `App/txtnimalApp.swift` | `CommandGroup(replacing: .newItem)` L22、`menuButton(_:)` L72 |

新增一顆快捷鍵**只**要改 `CommandCatalog.builtIns`：守門鏈、指令面板與選單列都是從它生出來的。
手抄第二份的下場見 `CHANGELOG.md`（選單與 `handle()` 對 ⌘2／⌘4 各說各話那次）。

## 兩條派送路徑

一顆鍵有兩個可能的消費者，兩條路都通到同一個 `perform()`：

1. **本地 monitor** — `ContentView.installMonitor()`（L1111）裝的 `NSEvent` local monitor。
   絕大多數情況走這條。
2. **選單列** — monitor 放行（`.passThrough`）時，事件會繼續走到 SwiftUI 的主選單。
   選單按鈕呼叫 `TaskStore.requestCommand(_:)`（`App/TaskStore.swift` L329），
   經 `@Published commandRequest`（L326）回到 `ContentView` 的
   `.onChange(of: store.commandRequest)`（L105），再進 `perform()`。

第 2 條仍是每個 ⌘ 綁定的保證後備入口：`CommandMenuModel` 覆蓋它們，
`CommandPaletteTests` 直接對它斷言（不是對手抄的字面值）。
它不再是那些狀態下的**唯一**消費者——cmd 分支已排在文字守門之前，
行內新增 / Agent 頁 / 設定頁 / 搜尋欄位有焦點時，⌘1 這類鍵由 monitor 直接執行。
唯一仍只靠放行的是 ⌘Z / ⇧⌘Z：系統 Edit 選單本來就擁有它們，
放行才能讓聚焦中的文字欄位做「復原打字」。

## 守門鏈順序

`KeyboardGuardChain.decide`（`KeyboardGuardChain.swift` L95）由上而下：

| # | 條件 | 結果 |
|---|------|------|
| 1 | 指令面板開著 | 放行（面板自己先攔 ↑ ↓ ⏎ esc） |
| 2 | ⌘E 編輯彈窗開著 | 放行（彈窗自己處理 ↓ / esc / Tab） |
| 3 | 捕捉列 / 加 List / 加 Tag / 便箋 / List 編輯視窗 / **行內編輯中** | 放行 |
| 4 | 設定頁 + esc | 回清單 |
| 5 | 帶 ⌘ 且命中 catalog 且該頁可用（⌘Z / ⇧⌘Z 除外） | 執行指令 |
| 6 | 行內新增中 / Agent 頁 / 設定頁 / 搜尋欄位有焦點 | 放行 |
| 7 | 專注模式 | `z` 或 esc 離開，**其餘全吞** |
| 8 | 統計 / 設定 / 垃圾桶頁 | esc 回清單，其餘全吞 |
| 9 | ↑ ↓ ⏎ esc | 移動游標 / 行內編輯 / esc 分層清除 |
| 10 | `j` `k` `0`–`4` | 移動游標 / 象限指派（`0`–`4` 只在象限頁） |
| 11 | 命中 catalog 單鍵 | 執行指令 |

第 3 步的「行內編輯中」是 2026-08-19 補的：在改任務名稱時打到 `d` 會跳出刪除確認。

第 5 步的例外是 ⌘Z / ⇧⌘Z：它們刻意不參與「cmd 先於文字守門」，
見 `KeyboardGuardChain.commandsDeferredToTextEntry`（L91）。
過了第 6 步之後，這兩顆鍵仍會走完 cmd 分支，所以清單／專注／統計頁的任務復原不變。

**任何帶 ⌘ 的按鍵都在 cmd 分支結束，不會往下掉。** 沒命中 catalog 的（⌘A / ⌘C / ⌘V …）
一律放行給系統。這條性質在重排時很容易弄丟：讓它們掉進第 7 步或第 8 步就會被吞掉，
統計頁與專注模式下的複製貼上會無聲失效。
`testUnmatchedCommandKeysAlwaysPassThroughToTheSystem` 是它的圍籬。

第 6 步的搜尋看的是**欄位是不是真的有焦點**，不是「搜尋列在不在」。
按 ⏎ 之後篩選與搜尋列都還在（`searchActive` 仍為 true，這是刻意的），
但鍵盤流已經交還清單，單鍵必須全部恢復作用。
走到這一步的只剩下非 cmd 單鍵，以及刻意留給文字欄位的 ⌘Z / ⇧⌘Z。

## ⚠️ 專注模式會吞掉所有未修飾單鍵

在專注模式（清單／象限頁按 `z` 進入，`TaskStore.toggleFocusMode()` 於
`App/TaskStore.swift` L1736）底下：

- **只有 `z` 與 `Esc` 有作用**，兩者都是離開專注模式。
- 其他未修飾單鍵（`n` `d` `x` `e` `j` `k` …）**全部被吞掉，沒有任何回饋**。
- 帶 ⌘ 的快捷鍵**仍然有效** —— 守門鏈第 5 步排在第 7 步之前，
  所以 ⌘1 可以直接切頁離開（切頁也會順手把專注模式關掉）。

這是刻意設計：專注模式的重點就是畫面只剩一件事、不要有別的操作。
畫面上唯一的提示是變暗的遮罩（`ContentView.swift` L68 掛載、L402 定義）。
但對忘記自己還在專注模式的使用者來說，這看起來就是「快捷鍵壞了」——
所以寫在這裡，也寫在 README。要離開就按 `z` 或 `Esc`。

## 切頁會清掉的狀態

`ContentView.switchView(to:ensureCursor:)`（L982）。六個切頁指令與兩條
esc-回清單路徑都走它，它會清掉：

- `store.focusMode` —— 否則新頁面繼續吞掉所有單鍵。
- `searchFocused`（`ContentView` 的 `@FocusState`，L181）—— 否則守門鏈第 6 步
  會在新頁面繼續放行，下一顆單鍵直接消失。

兩者都不會因為 `store.view` 改變而自動歸零：`ContentView` 從頭到尾沒有被拆掉重建。

## 側邊面板模式：cmd 快捷鍵改由 monitor 直接處理

側邊面板（⌥T）是 `[.borderless, .nonactivatingPanel]` 的
`KeyablePanel`（`App/GlobalCapture.swift` L24、L115），
`reveal()`（L202）用 `makeKeyAndOrderFront` 讓它成為 key window，
但**全程沒有呼叫 `NSApp.activate`**。

所以面板拿到鍵盤時，txtnimal 不是最前景 app，選單列屬於別的 app：

- 本地 monitor（路徑 1）照常運作。
- 選單後備（路徑 2）**完全不會觸發**。

已選定並落地第二條路：把 cmd 分支排到文字守門之前（現在的第 5 步）。
行內新增 / Agent 頁 / 設定頁 / 搜尋欄位有焦點時，⌘K / ⌘E / ⌘6 由 monitor 直接執行。
知情的代價是：這些狀態不再把 ⌘ 鍵交給聚焦中的文字欄位。

唯一刻意的例外是 ⌘Z / ⇧⌘Z。系統 Edit 選單本來就擁有它們；
放行才能讓聚焦中的欄位做「復原打字」，而不是把「復原我剛打的字」換成「復原上一個任務動作」。
這和 `KeyboardGuardChain.commandsDeferredToTextEntry`（L91）與
`CommandMenuModel.keylessIdentities`（`CommandPalette.swift` L320）是同一個理由的兩半：
那邊不讓選單搶鍵，這邊不讓 monitor 搶鍵。
