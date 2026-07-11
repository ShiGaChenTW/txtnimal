# taskstxt.app UI/UX 設計研究報告

**建立時間：** 2026-07-12 01:55
**最後更新：** 2026-07-12 02:20
**狀態：** 已完成

## 目標
深入研究 taskstxt.app（本專案重製對象）的 UI 與 UX 設計，產出研究結果報告，作為後續 Figma 設計修改的依據。

## Plan Steps
- [x] Step 1 — 抓取 taskstxt.app 官網全部內容（403 擋 bot → curl + 瀏覽器 UA 成功；含 CSS 色票原始碼）
- [x] Step 2 — 彙整既有內部資料（SPEC.md、rebuild-spec 差異分析）
- [x] Step 3 — 平行研究：外部評價/社群討論 + 設計脈絡（2 個背景 agents，皆完成）
- [x] Step 4 — 分析：官方 demo.mp4 抽 6 幀逐幀分析 + 設計語言/互動模型/資訊架構/UX 哲學
- [x] Step 5 — 撰寫研究報告 `docs/taskstxt-app-uiux-research.md` 並摘要交付

## 決策紀錄
- 01:55 — 研究對象鎖定官網 + demo 影片 + 外部社群訊號；無法安裝原 app
- 01:57 — Interceptor CLI 未安裝、Chrome extension 未連線 → curl + UA 降級成功（待辦：重裝 Interceptor）
- 02:00 — 重大發現：App 本體是現代柔和 dark UI（系統字體、violet accent），非官網行銷的終端風

## 阻塞 / 待決議
無（Interceptor 重裝為環境待辦，不擋本任務）

## 結束摘要
報告完成：`docs/taskstxt-app-uiux-research.md`（九章 + 12 條來源）。
關鍵發現：(1) 官網終端風 vs App 現代 dark UI 的形象落差 —— 我們的 TUI 重製版正好補位；
(2) Done 置頂 + 晨間清空的 done-list 心理學；(3) 刻意缺席（無日期/優先級/通知/設定）繞開愧疚迴圈；
(4) 明確空缺 = 全域捕捉、快捷鍵可發現性、時間軸 —— 皆為本專案已建的差異化功能；
(5) 可借鑑：checkbox 形狀編碼區段語意、外部編輯衝突策略需明確化。
產品情報：開發者 Yevhen、2026-07-04 上架、免費、992KB native Swift、PH #10/155 votes、樣本僅一週極小。
