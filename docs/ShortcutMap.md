# 快捷鍵地圖

> **契約**：本文件的行號對應當下 `App/` 與 `Sources/txtnimalCore/` 的原始碼。
> 改動鍵盤相關程式碼時一併更新行號；行號漂掉的文件比沒有文件更糟。
>
> 最後校對：2026-08-19（鍵盤派送重構後）

## 唯一真相在哪裡

| 東西 | 檔案 | 位置 |
|------|------|------|
| **綁定表**（哪顆鍵對應哪個指令、在哪些頁面可用） | `Sources/txtnimalCore/CommandPalette.swift` | `CommandCatalog.builtIns`，L140 |
| **守門鏈**（某個狀態下這顆鍵會被吃掉、放行、還是執行） | `Sources/txtnimalCore/KeyboardGuardChain.swift` | `KeyboardGuardChain.decide`，L86 |
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

第 2 條存在的理由：Agent 頁、設定頁與「搜尋欄位真的有焦點」這三種狀態下，
守門鏈把整副鍵盤交給欄位，⌘1 這類切頁鍵只能靠選單。
`CommandMenuModel` 保證每個帶 ⌘ 的綁定都有一個選單項目，
`CommandPaletteTests` 直接對它斷言（不是對手抄的字面值）。

## 守門鏈順序

`KeyboardGuardChain.decide`（`KeyboardGuardChain.swift` L86）由上而下：

| # | 條件 | 結果 |
|---|------|------|
| 1 | 指令面板開著 | 放行（面板自己先攔 ↑ ↓ ⏎ esc） |
| 2 | ⌘E 編輯彈窗開著 | 放行（彈窗自己處理 ↓ / esc / Tab） |
| 3 | 捕捉列 / 加 List / 加 Tag / 便箋 / List 編輯視窗 / **行內編輯中** | 放行 |
| 4 | 設定頁 + esc | 回清單 |
| 5 | 行內新增中 / Agent 頁 / 設定頁 / 搜尋欄位有焦點 | 放行 |
| 6 | 帶 ⌘ 且命中 catalog 且該頁可用 | 執行指令 |
| 7 | 專注模式 | `z` 或 esc 離開，**其餘全吞** |
| 8 | 統計 / 設定 / 垃圾桶頁 | esc 回清單，其餘全吞 |
| 9 | ↑ ↓ ⏎ esc | 移動游標 / 行內編輯 / esc 分層清除 |
| 10 | `j` `k` `0`–`4` | 移動游標 / 象限指派（`0`–`4` 只在象限頁） |
| 11 | 命中 catalog 單鍵 | 執行指令 |

第 3 步的「行內編輯中」是 2026-08-19 補的：在改任務名稱時打到 `d` 會跳出刪除確認。

第 5 步的搜尋看的是**欄位是不是真的有焦點**，不是「搜尋列在不在」。
按 ⏎ 之後篩選與搜尋列都還在（`searchActive` 仍為 true，這是刻意的），
但鍵盤流已經交還清單，所有快捷鍵必須恢復作用。

## ⚠️ 專注模式會吞掉所有未修飾單鍵

在專注模式（清單／象限頁按 `z` 進入，`TaskStore.toggleFocusMode()` 於
`App/TaskStore.swift` L1736）底下：

- **只有 `z` 與 `Esc` 有作用**，兩者都是離開專注模式。
- 其他未修飾單鍵（`n` `d` `x` `e` `j` `k` …）**全部被吞掉，沒有任何回饋**。
- 帶 ⌘ 的快捷鍵**仍然有效** —— 守門鏈第 6 步排在第 7 步之前，
  所以 ⌘1 可以直接切頁離開（切頁也會順手把專注模式關掉）。

這是刻意設計：專注模式的重點就是畫面只剩一件事、不要有別的操作。
畫面上唯一的提示是變暗的遮罩（`ContentView.swift` L68 掛載、L402 定義）。
但對忘記自己還在專注模式的使用者來說，這看起來就是「快捷鍵壞了」——
所以寫在這裡，也寫在 README。要離開就按 `z` 或 `Esc`。

## 切頁會清掉的狀態

`ContentView.switchView(to:ensureCursor:)`（L982）。六個切頁指令與兩條
esc-回清單路徑都走它，它會清掉：

- `store.focusMode` —— 否則新頁面繼續吞掉所有單鍵。
- `searchFocused`（`ContentView` 的 `@FocusState`，L181）—— 否則守門鏈第 5 步
  會在新頁面繼續放行，下一顆鍵直接消失。

兩者都不會因為 `store.view` 改變而自動歸零：`ContentView` 從頭到尾沒有被拆掉重建。

## 已知限制：側邊面板模式下選單這條路是斷的

側邊面板（⌥T）是 `[.borderless, .nonactivatingPanel]` 的
`KeyablePanel`（`App/GlobalCapture.swift` L24、L115），
`reveal()`（L202）用 `makeKeyAndOrderFront` 讓它成為 key window，
但**全程沒有呼叫 `NSApp.activate`**。

所以面板拿到鍵盤時，txtnimal 不是最前景 app，選單列屬於別的 app：

- 本地 monitor（路徑 1）照常運作。
- 選單後備（路徑 2）**完全不會觸發**。

也就是說在側邊模式下，凡是守門鏈會放行的狀態（搜尋欄位有焦點、Agent 頁、設定頁），
⌘1 這類切頁鍵沒有任何消費者。修法有兩個方向，都要先決定產品行為，尚未實作：
在 `reveal()` 加 `NSApp.activate`（違背 non-activating 面板的初衷），
或把守門鏈第 6 步移到第 5 步之前（會讓文字欄位裡的 ⌘Z 變成任務復原）。
