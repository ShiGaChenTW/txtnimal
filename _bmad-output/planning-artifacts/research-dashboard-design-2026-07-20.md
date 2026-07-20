# Task App Dashboard 設計做法 — 深度研究報告

> 產出：2026-07-20 · deep-research workflow（105 代理、87 完成、20 條論點三票確認、2 條反駁剔除、22 條未完成驗證）+ 人工綜合
> 證據分級：✅ = 三票對抗驗證通過（附原文引句）；◐ = 有一手來源引句但未完成三票驗證；○ = 單代理調查所得
> 被反駁主張已剔除（例：Monday burndown「綠虛線/藍實線」配色說法 0-3 遭反駁）

## 1. 資訊架構與版面模式

主流 GUI 走「分頁/卡片自組」，理論派主張「單屏一覽」，兩者不衝突 — 取決於產品定位：

- ✅ Todoist Productivity 視圖是**分頁式**：Daily / Weekly / Karma 三個 tab，非單頁滾動（官方 help：「The view includes separate Daily, Weekly, and Karma tabs.」）
- ✅ Linear / Asana 走**模組化卡片網格自組**：每團隊自建 dashboard、widget 任意排布、附模板降低門檻 — 「團隊工具」形態，因不同角色要看的東西不同
- ✅ **檢視頻率決定密度**（Linear 最佳實踐，3-0）：每天/每週看的 dashboard 應更密集、glanceable、為速度最佳化；偶爾看的才需要說明與註解
- ✅ Linear 區分**策略型**（少數長期趨勢、促成對齊）vs **營運型**（較廣指標、突顯異常）— 設計前先決定做哪種
- ◐ Stephen Few 經典定義：dashboard = 單一螢幕、不捲動、一眼監控；捲軸實質降低可用性
- ◐ 資訊架構倒金字塔：頂部狀態數字（are we good?）→ 中段解釋變動的趨勢 → 底部細節
- ◐ Linear 內部數據：中位數 workspace 只建 2 個 dashboard，再多採用率下滑 — 少而精

**結論**：單人高頻使用 = Few 的單屏派 + Linear 的 glanceable 高密度。分頁/卡片自組是多角色團隊工具才需要的複雜度。

## 2. 圖表類型 ↔ 回答的問題

| 圖表 | 回答的問題 | 證據 |
|---|---|---|
| 熱力圖（GitHub 式） | 我有沒有持續出現 — 模式辨識 gap 與連續性 | ○ done-per-day 事實標準，habit tracker 大量複製 |
| 每日/週完成長條、sparkline | 完成多少、節奏如何 | ✅ Todoist 近 7 天完成圖 |
| Burndown / 存量趨勢 | 待辦在收斂還是膨脹；照這速度何時做完 | ✅ Taskwarrior burndown = pending/active/completed 存量隨時間；✅ Monday 定義 = 實際 vs 計畫；◐ Taskwarrior net fix rate 外推預測完成日（官方警告準確度未知） |
| 依專案上色的堆疊/分組圖 | 時間花在哪些專案 | ✅ Todoist 圖表色直接沿用專案色（兩輪 3-0） |
| Streak / 目標線 | 有沒有維持習慣 | ✅ Todoist 達成每日目標才觸發 streak、顯示最長紀錄 |
| 摘要數字卡 | 現在的狀態 | ✅ Asana 六種 widget（column/line/burn-up/donut/number/lollipop）之一 |
| 圓餅/donut | 部分對整體 | ◐ 文獻限 donut 2–3 片、反對多片圓餅 |

- ✅ **數字必須帶比較基準**（Linear 3-0）：每個關鍵指標配本週/上週/歷史高低點的小圖，觀看者不需額外脈絡即可判斷好壞
- ✅ **圖表是 drill-down 入口**（Asana 3-0）：點資料點直接跳到背後的確切任務清單

## 3. 視覺層級與色彩紀律

- ◐ Tufte data-ink ratio：消除非資料像素（3D、陰影、多重格線、裝飾框）、強化資料像素 — 字元長條/sparkline 天然高 data-ink ratio
- ◐ 顏色是訊號不是裝飾：中性色做框架、單一強調色表「注意」、保留一色給警示；色彩須有第二線索備援色盲
- ◐ Few 13 項常見錯誤：濫用色彩、無用視覺雜訊、未突顯重要資料位居前列
- ✅ 產品級色彩做法：Todoist 圖表色綁定使用者專案色 — 色彩承載身分語意

## 4. 使用者褒貶與 gamification 反模式

- ✅ **最強證據**：Todoist 為 gamification 建了完整退出機制 — Vacation Mode 保 streak、目標設 0 停用、Karma 整個可關（3-0）。官方花工程做「關掉它」= 承認計分/streak 造成壓力
- ○ 社群一致方向：streak 斷掉的 dread > 維持的 pride；相對排名（TickTick「你比 X% 用戶更有生產力」）為無行動意義的 vanity metric
- ○ Things 3 十年零統計仍是頂級產品 — 少即是多有市場；第三方 things.sh 存在證明少數 power user 有需求，但官方判斷不值得加複雜度
- ✅ Linear 度量語彙集中在流程效率（cycle time、lead time、issue age）而非完成量 — 團隊視角；個人工具照抄會變自我監控

## 5. 對本專案的可執行建議（對照 ⌘4 統計頁現狀）

**已對齊（不動）**：
- 單屏高密度、唯讀、一鍵進出 ✓（Few 單屏 + Linear glanceable）
- 無計分/排名/streak 懲罰 ✓（Todoist 退出機制反證其為設計債）
- 字元長條/sparkline/去描邊 ✓（data-ink ratio 操作化）
- 本週 vs 上週並列 ✓（數字帶比較基準）

**值得做的三個增量（按價值排序）**：
1. **專案列 drill-down**（✅ Asana 慣例）：統計頁點 `+project` 列 → 跳清單並套用該專案篩選。`toggleTagFilter` 已存在，成本極低
2. **淨流量一行**（✅ Taskwarrior burndown 極簡化）：摘要行加「本週 +新增 / −完成」— 回答目前唯一沒回答的「待辦在收斂還是膨脹」。`created:` 歷史稀疏 → 只算有資料的區間
3. **熱力圖比較脈絡**：sparkline 旁補「週均 N」一個數字，不加圖

**明確不做（研究支持的取捨）**：分頁化（單人高頻=單屏）、streak 顯示（dread>pride）、完成日預測（Taskwarrior 官方自承準確度未知）、圓餅圖、相對排名類任何東西。

## 主要來源

- Todoist Karma／Productivity help（一手）— todoist.com/karma · todoist.com/help/articles/360000410829
- Linear dashboards best practices／Insights（一手）— linear.app/now/dashboards-best-practices · linear.app/insights
- Asana reporting dashboards（一手）— asana.com/features/goals-reporting/reporting-dashboards
- Monday burndown 文件（一手）— support.monday.com/hc/en-us/articles/17003133339410
- Taskwarrior burndown 文件（一手）— taskwarrior.org/docs/commands/burndown/
- Stephen Few《Information Dashboard Design》書評／Perceptual Edge（◐）— uxmatters.com · perceptualedge.com
- DataCamp／Packt dashboard 設計指南（◐）
- todo.txt-graph、taskwarrior-tui GitHub（○）
