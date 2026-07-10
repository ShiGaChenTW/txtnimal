# tasks.txt GUI 重新開發 — Spec 與建置追蹤

**建立時間：** 2026-07-09 16:16
**最後更新：** 2026-07-10（capture bar 三輪迭代後盤點）
**狀態：** 進行中

## 目標

以 Native SwiftUI 重製 taskstxt.app（純文字任務管理器），並加入三項差異化：
`due` 到期日 + 時間分組主清單、手動拖拉的四象限視圖、單數 Focus。純自用 + 作品集。
設計契約見同 repo 的 `SPEC.md`。

## Plan Steps

- [x] Step 0 — 研究 taskstxt.app、鎖定格式與行為差異
- [x] Step 1 — 與 Scott 確認 11 項設計決策（確認單 artifact）
- [x] Step 2 — 寫 `SPEC.md` 設計契約（格式 / 三視圖 / Focus / 捕捉 / 里程碑）
- [ ] Step 3 — 等 Scott 的自訂日曆設計（due 日期挑選 UI，留白）
- [x] Step 4 — Swift Package `TasksTxtCore` 骨架建立（Package.swift + swift test 可跑）
- [x] Step 5 — 核心：todo.txt 無損 parser（round-trip，保留未知 token）— 12 測試全綠
- [x] Step 6 — 檔案層：原子寫入（write atomically:true）+ 外部編輯監看（DispatchSource，00:50 完成）
- [x] Step 6.5 — 純邏輯全數完成並測試：NL 日期解析 / 清單分組 / 象限分桶 / 捕捉解析（共 20 測試綠）
- [x] Step 6.7 — 外殼改用 XcodeGen(避開本地 package GUI bug):project.yml → TasksTxt.xcodeproj,非 sandbox、ad-hoc 簽章
- [x] Step 6.8 — **xcodebuild 一次過 BUILD SUCCEEDED,app 啟動、建立並解析真實 tasks.txt**(v1 跑通)
- [x] Step 7 — ⌘1 主清單 UI(v1):接上 ListGrouping、相對日期、逾期可折疊、Focus 條
- [x] Step 8 — ⌘4 四象限:鍵盤 1–4 + **拖拉放置**(onDrag/onDrop)+ 四格底色
- [x] Step 9 — Focus 完整四層:頂條/原地/選單列/Focus模式(B變暗)/**置頂迷你浮窗(NSPanel floating)**
- [x] Step 10 — 捕捉完整版:app 內面板 + inline 解析 + **全域熱鍵(⌥Space 預設,設定可重綁)** + 選單列「快速捕捉」+ 非搶焦點浮窗
- [x] Step 11 — ⌘3 便箋 + **每日歸檔(啟動時 + NSCalendarDayChanged,實測搬檔成功)**
- [ ] Step 12 — 待 Scott 視覺確認 UI/鍵盤手感 → 打磨 + 補 v2 清單

## 決策紀錄

- 16:16 — 範圍純自用+作品集 → 不進 App Store sandbox，換得全域熱鍵/選單列常駐/自由檔案路徑
- 16:16 — 格式：+due: +q:1-4 +focus:true，退役 upcoming:true（其餘 todo.txt 欄位保留）
- 16:16 — 主清單順序採 Scott 覆蓋版：今天→即將→逾期→無期限→完成（非逾期置頂）
- 16:16 — 四象限純手動拖拉、不看時間；軸標僅提示
- 16:16 — Focus 單數(0/1)，顯示強度 C（含 always-on-top 迷你浮窗），快捷鍵 ⌘⇧F
- 16:16 — 全域熱鍵可在設定 UI 重綁 → 允許一個小套件（KeyboardShortcuts，MIT），為唯一外部依賴
- 16:16 — due 輸入雙路徑：打字(fri/3d/tomorrow) + Scott 自訂日曆並存
- 16:31 — 四象限命名定案：q1 重要且緊急 / q2 重要但不緊急 / q3 緊急但不重要 / q4 不重要且不緊急
- 16:31 — parser 採「mutate raw、最小改動」策略保無損 round-trip；改 Xcode app 前先以 SPM 純邏輯套件驗證地基
- 20:40 — 四路市場研究完成(視覺/流程/鍵盤終端/到期象限),產出比較報告 artifact
- 20:40 — UI 定稿:TUI 風、逾期紅獨佔、Focus 改 teal、Focus 模式=終端變暗(技法 B)、相對日期、逾期可折疊+R一鍵、象限動詞標籤、⌘K 面板、完成動畫;優先級 shorthand 刻意跳過(與去 priority 決定衝突)
- 20:40 — 互動原型 v2 完成並經 Scott 選定 B;SPEC 已回寫定稿
- 21:10 — 外殼決定 B(Scott 開 Xcode、我填碼);app v1 原始碼寫好於 App/(Theme/TaskStore/TasksTxtApp/ContentView/Views),含 list/quadrant/scratch/Focus模式(技法B)/選單列/捕捉/鍵盤(NSEvent monitor,macOS13 無 onKeyPress)。**尚未編譯**,待 Scott 建 Xcode 專案驗證
- 21:10 — v1 刻意延後:FSEvents 外部監看 · 行內編輯 · 全域熱鍵 · 置頂 HUD · ⌘K · 完成動畫 · 象限拖拉 · 每日歸檔 · 淺色主題 · 日曆
- 23:07 — Scott 授權接手建置;裝 xcodegen、生成 TasksTxt.xcodeproj、xcodebuild 一次過編譯成功並啟動;app 建立/解析真實 tasks.txt。待 Scott 視覺確認
- 00:10 — 間距優化(minimalist-ui 原則):行距三段可調 + 分組留白 sectionTop + 加大內距/視窗;狀態符號改 [ ]/[✓]
- 00:30 — project+context 兩軸:@context 升一等(修 title 漏字)、點擊篩選、底部標籤列、p 快速加 project
- 00:50 — Pass 1:行內編輯(setTitle 保留 metadata)、外部檔案即時重載(DispatchSource)、完成 spring 動畫
- 01:10 — Pass 2:象限拖拉、Focus 置頂浮窗(NSPanel)、深/淺雙主題(動態色 + ⌘⇧T/選單切換)
- 01:40 — 全域熱鍵捕捉:KeyboardShortcuts 套件(唯一外部依賴,照原決策)、⌥Space 預設、Settings 視窗可重綁、KeyablePanel 非搶焦點浮窗
- 09:40 — 收尾:每日歸檔(啟動+換日通知,實測通過)、/ 搜尋(即打即濾,esc 分層清除)、開機自啟(SMAppService 選單開關)。**功能面只剩 due 日曆(等 Scott 設計稿)**
- 之後 — 捕捉改版三輪:popup 改為頂部 inline capture bar(n 滑下、⌘Enter 送出、無按鈕),placeholder 半透明、綠底色塊+accent 邊。build 綠

## 阻塞 / 待決議

- 等 Scott 的 due 日曆自訂設計稿（Step 3，不擋 parser/骨架/清單）

## 結束摘要

（工作結束時補上）
