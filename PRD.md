---
change_id: plan-v03-roadmap
status: DRAFT
---

# PRD — txtnimal

> 產品需求文件。V0.1/V0.2 已出貨(規格細節見 SPEC.md);本文件記錄產品意圖與當前版本(V0.3)的需求範圍,供 OpenSpec change 開立時對齊。

## 產品是什麼

原生 macOS 任務管理工具。每項任務是 `.txt` 檔裡的一行(todo.txt 相容),使用者在享受 GUI、鍵盤操作、Focus 與統計的同時完全掌握自己的資料。本機運作,無帳號、無雲端、無遙測。

## 目標使用者

重視資料自主權的鍵盤族與開發者:用 Git 管理任務檔、用 `$EDITOR` 直接改檔、期待腳本與自動化能碰同一份資料。

## 產品不變量(所有版本共同)

1. Parse 後直接 serialize 為 byte-identical(無編輯時)。
2. 編輯時未知 token 與未動到的空白原樣保留。
3. 全文件最多一個 `focus:true`。
4. archive 寫入失敗絕不移除 live 任務。
5. 舊 snapshot 的指令絕不改到新 snapshot 的任務。

## 版本歷程

- **V0.1** — 核心任務管理:時間清單、List/Tag、單一 Focus、四象限、便箋、統計。
- **V0.2** — 外掛生態系:registry、XPC transport、security policy、12 個 bundled 外掛。
- **V0.2.x**(進行中)— 審查修復:2026-08-14 已修 6 筆高嚴重度(XPC 驗證反轉、containment 繞過、page intent 接線、archive 寫入順序、setTitle token 保留、double-resume);中低嚴重度收尾中。

## V0.3 需求範圍

主題:**同一份 tasks.txt —— 可查詢、可重複、可復原、可腳本。**

依據:grok × codex 雙顧問獨立提案的彙整,完整分析與依據見 `docs/V0.3-PLAN.md`。三波執行:

1. **信任地基** — 外部編輯衝突處理、快捷鍵契約重整(文件與實際綁定對齊)、App 層測試進 CI。
2. **日常閉環** — rec: 重複任務 UI(core 引擎已存在)、⌘K 指令盤重整(含外掛 command)、⌘Z 完整復原。
3. **查詢與腳本化** — token 查詢＋儲存檢視、本機 CLI、外掛 snapshot 欄位補齊。

貫穿投資:統一變更管線(分期拆 TaskStore)、穩定任務 ID 策略(查詢/CLI 前置)。

## Non-Goals

- 雲端同步、帳號、iCloud 後端——違反本機優先與資料自主權定位。
- 子任務、巢狀大綱、依賴圖——一行一任務是 parser 與 git diff 的品質線。
- 遠端外掛市集——隔離與簽章要先在 V0.2.x 證明成立。
- 自動判定重要性/自動排程——四象限刻意保留人工判斷。
- 行動版/跨平台、App Store sandbox、內建雲端 LLM——理由見 `docs/V0.3-PLAN.md` 不做清單。

## Desired Outcomes

- 三波交付項(9 項)各自以 OpenSpec change 開立並收斂:V0.3 出貨時 `specgate status` 顯示 0 個缺 specs 的 active change。
- 產品不變量 1–5 每一波結束時由自動化測試護住:`swift test` 0 failures,且 App 層測試進 CI(xcodebuild test 在 PR 上必跑)。
- 快捷鍵契約零落差:README/SPEC 列出的每一個快捷鍵在 App 內行為一致,抽查 100% 通過。
- 已安裝第三方外掛全部行程外執行:App 行程內 JSContext 僅剩 bundled 路徑(架構測試守衛),失控外掛不可使 UI 無回應超過逾時上限(10s)。
- 外部編輯不再靜默覆蓋:外部改檔後 GUI 未存編輯 0 遺失(衝突面測試覆蓋)。
