# 統計 Dashboard（圖像化）

**建立時間：** 2026-07-19 23:41
**最後更新：** 2026-07-20 01:55
**狀態：** 進行中（等使用者 ⌘2 驗收）

## 目標

為 TasksTxt 增加一個統計 dashboard 視圖：以 TUI 風格圖像化呈現任務完成趨勢與分佈。實作前先研究市場做法（Todoist Karma、TickTick 統計、Taskwarrior burndown、GitHub heatmap 等），再定圖表組合。

## Plan Steps

- [x] Step 1 — 市場研究：任務管理工具的統計/圖表做法（研究子代理）
- [x] Step 2 — 盤點資料源：tasks.txt / archive 檔可統計的欄位（created/done/+project/q:）
- [x] Step 3 — 定設計：四區塊（摘要行、12 週熱力圖、14 天長條、專案/象限分佈），⌘2 進入
- [x] Step 4 — 實作 DashboardView + ContentView/TaskStore 接線，xcodegen 重生專案，build 綠
- [ ] Step 5 — 視覺驗證：自動截圖失敗（視窗在另一 Space + CGWindowList 權限限制），改由使用者 ⌘2 人工驗收
- [x] Step 6 — 記入 PRD 工作區 memlog（範圍變更：新視圖）

## 決策紀錄

- 23:41 — 依 CLAUDE.md 觸發規則建立本追蹤文檔（新建檔案 + 多步驟）
- 23:47 — 圖表組合依研究定調：Taskwarrior/todo.txt-graph 描述性路線 + GitHub 熱力圖；刻意排除 Karma 計分、等級、排名、逾期懲罰、歸零 streak（皆為市場反模式）
- 23:50 — 摘要行只做事實陳述（待辦/本週/上週/近30天），不做合成分數
- 23:52 — ⌘2 指派給統計視圖；header 分頁改為 ⌘1234 數字序；dash 視圖唯讀（單鍵動詞屏蔽,esc 回清單）
- 23:55 — 新檔需 `xcodegen generate` 重生 xcodeproj 才進 target（首次 build fail 的原因）
- 00:15 — 依 tui-design skill 簡化：14 天長條圖改單行 sparkline 字元、專案/象限長條改 █░ 字元條（長條中性色、標籤帶身分色）、熱力圖去描邊、砍逐柱標數 — 顏色從 6 色同屏收斂到「綠=完成+身分色標籤」
- 00:16 — 視圖順序重排定案：⌘1 清單 · ⌘2 象限 · ⌘3 便箋 · ⌘4 統計
- 01:55 — deep-research 報告落地三增量：專案列 drill-down、本週淨流量、sparkline 週均；明確不做：分頁化、streak、完成日預測、圓餅、排名（報告：planning-artifacts/research-dashboard-design-2026-07-20.md）

## 阻塞 / 待決議

無（Step 5 為交接非阻塞）

## 結束摘要

（待使用者驗收後補）
