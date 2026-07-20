---
title: tasks.txt GUI PRD
status: draft
created: 2026-07-12
updated: 2026-07-20
---

# tasks.txt GUI — 產品需求文件（PRD）

## 1. 概述與願景

**一句話**：一個原生 macOS 的純文字任務管理器 —— 快到像開文字檔、鍵盤流到不用碰滑鼠，並且能把成組的任務直接派工給 coding agent。

原版 taskstxt.app 證明了「檔案由你擁有 + 原生 UI + 零設定」的市場縫隙成立（上架一週 PH #10）。本產品在同一哲學上補齊它刻意留下的三個空缺，再加上一個它沒想到的方向：

| 差異化 | 回答的問題 | 原版狀態 |
|---|---|---|
| `due:` 時間分組 | 什麼時候做 | 完全沒有時間概念 |
| `q:` 手動四象限 | 哪個重要 | 沒有重要性軸 |
| `focus:true` 單數 Focus | 現在做哪一個 | 沒有此概念 |
| 統計視圖（唯讀） | 做得如何 | 沒有此概念 |
| **Agent 派工** | 誰去做 | 沒有此概念 |

視圖與快捷鍵定案：`⌘1 清單 · ⌘2 象限 · ⌘3 便箋 · ⌘4 統計`（Focus 為 ⌘⇧F 疊加狀態，非分頁）。

視覺定位：真 TUI 美學（等寬字、盒線、終端色票）——「做到原版官網宣傳了但 App 沒做的事」。

**發布形式**：免費、開源（GitHub）、notarized DMG 直接下載。不進 Mac App Store（保全域熱鍵、自由檔案路徑、開機自啟）。

## 2. 目標使用者

- **主要**：鍵盤優先的開發者/技術工作者，任務放純文字檔、用 git 版控、活在終端機裡的人。其中用 Claude Code 等 coding agent 開發的人是派工功能的核心受眾。
- **次要**：todo.txt 生態既有使用者（SwiftoDo / TodoTxtMac 使用者），想要現代原生 UI。
- **第一使用者**：Scott 本人 —— dogfood 是品質門檻（見 §4 成功指標）。

## 3. 使用旅程

> [ASSUMPTION] 三條旅程由既有素材與 Scott 的口述動機推導，未逐條驗證。

**UJ-1 晨間規劃（Scott）**：早上開機，⌘1 看主清單 —— Overdue 紅區摺疊展開，按 `R` 把三個逾期改到今天；⌘2 進四象限，把未歸位池兩個新任務指到 q2；回到清單選定第一件事按 `f` —— 選單列出現 `▶ 任務名`，開始工作。全程零滑鼠（拖拉除外）、少於一分鐘。

**UJ-2 開發派工（Scott）**：下午開發 side project，`+tasktxt` 專案下有四個實作任務。多選這四行，按 `d` 派工 —— 面板顯示組好的 prompt（任務行 + note 內容），Scott 補兩句 context，確認後 app 在該專案 repo 目錄啟動 Claude Code session。四行任務標上 `status:dispatched`。Agent 跑完，Scott review diff，滿意後回到清單逐行 ⌘↩ 完成。

**UJ-3 新使用者首啟（發布後）**：下載 DMG、拖進 Applications、開啟 —— app 自動建立 `~/Documents/tasks-txt/tasks.txt`，底部 keybind 提示列常駐，⌘K 打開指令面板看到全部指令與快捷鍵。五分鐘內完成第一次全域熱鍵捕捉。沒有帳號、沒有教學精靈、沒有雲。

## 4. 目標與成功指標

**產品目標**
1. 取代 Scott 自己的任務管理流程（dogfood 存活 = 最低品質線）
2. 成為作品集裡「能公開展示的顧問作品」（對應 Scott 的 G0）
3. 驗證「純文字任務 → agent 派工」這條產品路線

**成功指標**（發布後 90 天，數字為初始標定，[ASSUMPTION] 待校準）
- Scott 連續 30 天日用不回退到其他工具
- GitHub ≥ 200 stars、下載 ≥ 1,000 次
- 派工功能：Scott 每週實際派工 ≥ 3 次
- 零資料遺失回報（issue tracker 上 data-loss 標籤 = 0）

**反指標**（防止成功指標把產品帶歪）
- 設定項永遠 ≤ 2（全域熱鍵、檔案位置）—— 功能請求不得以新設定項回應
- 外部依賴永遠 ≤ 1（`KeyboardShortcuts`）
- 冷啟動時間不因功能增加而退化（見 NFR-01）
- tasks.txt 與外部編輯器/git/原版格式的相容性不破壞（round-trip 測試常綠）

## 5. 範圍

**In scope（v1）**：四視圖（清單/象限/便箋/統計）+ Focus、全域捕捉、⌘K 指令面板、每日歸檔、檔案監看與衝突處理、agent 派工（CLI 模式）、雙主題、完成動畫、開源發布配套（簽章、公證、README）。

**Out of scope（§SPEC 9 沿用 + 本輪新增）**：
- 重複任務、子任務、雲同步、多檔、iOS/跨裝置
- 優先級 `(A)`（重要性由象限手動表達，刻意跳過）
- MCP server 派工模式（v2 候補，檔案契約已預留）
- Agent 自動回寫狀態、autopilot 自主迴圈（人 review 後手動完成，v1 不自動標 `x`）
- App 內 archive 檢視視圖（archive 是純文字檔，用編輯器看）[ASSUMPTION]
- 自動更新機制（Sparkle 會破壞單一依賴反指標；選單「Check for Updates」連到 GitHub Releases）[ASSUMPTION]

## 6. 功能需求

### F1 資料層與檔案格式契約

一行一任務，預設 `~/Documents/tasks-txt/tasks.txt`，todo.txt 擴充。

| 欄位 | 語意 | 來源 |
|---|---|---|
| `x ` 前綴 | 已完成 | 沿用 |
| `created:` / `done:` | 建立日 / 完成日 | 沿用 |
| `+project` | 專案標籤（可篩選、可對映派工 repo） | 沿用 |
| `note:"..."` | 行內備註（派工時併入 prompt） | 沿用 |
| `@context` | 情境標籤（可篩選） | 沿用（todo.txt 標準，實作時補入） |
| `due:YYYY-MM-DD` | 到期日，驅動主清單分組 | 新增 |
| `q:1`–`q:4` | 手動象限 | 新增 |
| `focus:true` | 當前焦點，全檔至多一個 | 新增 |
| `agent:<name>` | 派工對象（v1 恆為 `claude`） | 新增（本 PRD） |
| `status:dispatched` | 已派工、進行中 | 新增（本 PRD） |

- **FR-001** Parser 無損 round-trip：未知 token 與原始順序完整保留，只改動到的欄位（git diff 最小化）。
- **FR-002** 冪等序列化：同 model 連存兩次位元組相同。
- **FR-003** 寬容策略：無法解析的 token 原封保留、不噴錯。
- **FR-004** 原子寫入 + FSEvents/DispatchSource 監看外部改動。
- **FR-005** 衝突策略：app 無未存變更 → 外部改動靜默 reload；有未存變更撞上外部改動 → 提示使用者選邊（保留我的 / 載入外部）。agent 寫檔走同一路徑。
- **FR-006** 髒資料的視圖層行為：多個 `focus:true` → 檔案順序第一個生效，其餘保留不動；無效 `q:`（如 `q:7`）→ 視同無象限、token 保留；格式錯誤 `due:` → 落無期限組、token 保留。[ASSUMPTION]
- **FR-007** 首次啟動：目錄/檔案不存在自動建立；不做教學精靈，靠底部 keybind 列 + ⌘K 自我揭示。[ASSUMPTION]

### F2 主清單（⌘1）— 回答「什麼時候」

- **FR-010** 分組固定順序:Today → Overdue（紅、可摺疊、預設展開）→ Upcoming（due 昇冪）→ 無期限（手動順序）→ Done（底部、當日可見、隔日歸檔）。
- **FR-011** `R` 一鍵把全部 Overdue 改到今天（逾期不羞辱：紅色僅此一處、無計數轟炸）。
- **FR-012** 相對日期標籤（Today / Tomorrow / `3d ago` / 週幾 / `M/D`），儲存永遠是 ISO。
- **FR-013** 組內排序 ⌘↑/⌘↓ 或拖拉；Done 隔日啟動時偵測換日、移入 archive 檔。
- **FR-014** due 輸入雙路徑：打字 `due:tomorrow|fri|3d|2026-07-15` 正規化為 ISO（主路徑）；自訂日曆選配（設計稿 TBD，接縫留「設定 due」動作）。

### F3 四象限（⌘2）— 回答「哪個重要」

- **FR-020** 2×2 手動指派（鍵盤 `1–4` 指定、`0` 回池、拖拉並行），app 不做任何自動判斷；格標籤 q1 Do / q2 Schedule / q3 Delegate / q4 Delete。
- **FR-021** 未歸位池 = 無 `q:` 任務；指派寫 `q:N`、移除清 `q:`；格內順序 = 檔案順序。
- **FR-022** 完成任務自動清 `q:` 離開象限；`due` badge 照顯示但不影響落點。
- **FR-023** 版面 50/50：上半固定為 2×2 象限、下半為未歸位池，各自內部捲動（人工測試後定案）。

### F4 Focus（⌘⇧F）— 回答「現在做哪一個」

- **FR-030** 單數約束：`focus:true` 全檔至多一個；設新自動清舊；完成/刪除自動卸下；焦點寫進檔案（重開 app、外部編輯、git 皆可見）。
- **FR-031** 日常顯示四層全 teal：視窗頂 Focus 條、該行原位 highlight、選單列 `▶ 任務名`、always-on-top 迷你浮窗。
- **FR-032** 禪模式 `z`：其他區塊壓暗不模糊，焦點卡片全亮置中（title/due/note）；`z`/`Esc` 離開；reduce-motion 提供無動畫版。

### F5 全域捕捉與選單列

- **FR-040** 全域熱鍵（預設 ⌥Space [ASSUMPTION]，可重綁）→ 輕量 NSPanel 一行輸入；Enter 追加 + 自動蓋 `created:`、Esc 關閉。開窗到能打字 < 150ms（NFR-01）。
- **FR-041** 輸入即時解析：邊打邊高亮 `due:` / `+project` token 並從標題剝除，完全離線。
- **FR-042** MenuBarExtra icon 開同一面板；`SMAppService` 開機自啟。

### F6 便箋（⌘3）與歸檔

- **FR-050** `scratch.txt` 純文字便箋，同資料夾 —— 非任務雜訊的吸收層。
- **FR-051** archive 檔為同資料夾純文字檔，格式與 tasks.txt 相同。[ASSUMPTION]

### F7 鍵盤系統與可發現性

- **FR-060** 高頻單鍵動詞：`x` 完成、`e` 編輯、`f` Focus、`z` 禪模式、`n` 捕捉、`R` 逾期改今天、`d` 派工、`1-4` 設象限；vim `j/k` 選配。
- **FR-061** ⌘K 指令面板：模糊搜尋全部指令、面板內顯示快捷鍵（Superhuman 式教學）—— 長尾功能唯一入口。
- **FR-062** 每個鍵盤動作有滑鼠等價路徑（雙軌原則，沿用原版）。[ASSUMPTION]
- **FR-063** `e` 行內編輯，token 即時解析比照捕捉面板；↩ 確認、Esc 取消。[ASSUMPTION]
- **FR-066** app 內新增（`n`）為**底部命令列**：與狀態列同槽互換（vim 式、零高度跳動），單行輸入、`due:`/`+`/`@` token 直接在輸入行上色（`due:` 僅可解析時變藍 = 即時驗證）、`⏎` 送出 `esc` 取消 —— 人工測試「輸入不直覺、不夠優雅」回饋後重設計定案；輸入一律在畫面底部（終端隱喻）。
- **FR-064** 點 `+project` 膠囊篩選該專案；⌘F 全文搜尋過濾當前視圖。[ASSUMPTION]
- **FR-065** 完成動畫：`x` 打勾彈跳 + 綠光一閃（招牌時刻）；reduce-motion 停用。

### F8 Agent 派工 — 回答「誰去做」（v1 = CLI 模式）

派工哲學：**app 是派工台，不是自動工廠**。任務太薄就補、送出前必過目、完成必經人審 —— 三個市場共同回報的坑各對一條 FR。

- **FR-070** 多選任務（或選一個 `+project` 群組）→ `d` 或 ⌘K「Dispatch to Agent」發起派工。
- **FR-071** 派工面板顯示組好的 prompt（任務行 + `note:` 內容 + 可編輯的補充 context 區），使用者可修改後送出 —— 對抗「一行任務太薄」。
- **FR-072** 執行：在指定工作目錄啟動 agent —— 預設開新終端視窗跑互動 Claude Code session；headless `claude -p` 為選配。[ASSUMPTION]
- **FR-073** `+project` → repo 工作目錄的對映：首次派工該專案時詢問，記在 app 偏好（不寫進 txt，維持檔案格式純淨）。[ASSUMPTION]
- **FR-074** 送出後任務行寫入 `agent:claude status:dispatched`，清單以 badge 顯示派工中狀態。
- **FR-075** Review gate：agent 完成不自動標 `x`；人 review 後手動完成，完成時清除 `agent:`/`status:`。
- **FR-076** 同一 repo 同時僅允許一個進行中派工，再派提示（迴避 worktree/檔案衝突；多 worktree 並行留 v2）。[ASSUMPTION]
- **FR-077** 派工永不自動觸發 —— 只由使用者顯式發起（安全邊界，見 NFR-05）。

### F9 主題與視覺

- **FR-080** TUI 美學：等寬字、盒線、底部常駐 keybind 提示列；深色為主 + 淺色「紙終端」，⌘⇧T 切換。[ASSUMPTION: 快捷鍵沿用原版]
- **FR-081** 色彩紀律：近黑底 + 紙白字；紅=逾期（獨佔）、teal=Focus、洋紅=`+project`、青=`@context`、綠=完成、灰=次要資訊。單一軸用色，不疊色。

### F10 統計視圖（⌘4）— 回答「做得如何」

> **與極簡定位的張力**：第四個視圖是對「三視圖互補不重疊」原則的一次擴張。守住的方式：**唯讀、一鍵進出、零設定、不推播、不打分** —— 它只回答問題，不製造義務。市場研究定調走 Taskwarrior / todo.txt-graph 的描述性路線 + GitHub 熱力圖形式；刻意排除 Karma 計分、等級、相對排名、逾期懲罰、歸零 streak（皆為市場驗證的反模式；Todoist 官方甚至提供關閉 Karma 的開關）。

- **FR-090** 唯讀視圖：`⌘4` 進入、`esc`/`⌘1` 離開；視圖內單鍵動詞全數屏蔽（不得作用於不可見游標）。
- **FR-091** 資料源 = `done:` 日期（archive 檔歷史 + 當前檔），進視圖時即時重算；無資料庫、無快取。
- **FR-092** 摘要行：待辦 / 本週完成 / 上週 / 近 30 天 —— 純事實陳述，無合成分數。
- **FR-093** 完成趨勢：12 週 × 7 天熱力圖（GitHub 式、綠色四階濃淡、無描邊）+ 近 14 天單行 sparkline（`▁▂▃▅▇` 字元）。
- **FR-094** 分佈圖：近 30 天完成按 `+project`、未完成按象限 —— `█░` 字元長條，長條一律中性色、身分色只上標籤（色彩紀律延伸）。

## 7. 非功能需求

- **NFR-01 效能**（數字為初始標定 [ASSUMPTION]）：冷啟動 < 1s；捕捉面板出現到可打字 < 150ms；2,000 行任務清單捲動不掉幀；派工面板組 prompt < 500ms。
- **NFR-02 資料完整性**：原子寫入；FR-001/002/003 以測試護欄鎖死（round-trip corpus 測試常綠為 CI 門檻）；任何情境不得遺失使用者輸入。
- **NFR-03 相容性**：macOS 13 Ventura+；SwiftUI 原生非 Electron；與外部編輯器/git/todo.txt 工具鏈共存；與原版 taskstxt.app 的共通欄位（`x`、`created:`、`done:`、`+project`、`note:`）語意一致。
- **NFR-04 可及性**：reduce-motion 全動畫有無動畫版；核心操作提供 VoiceOver 標籤。[ASSUMPTION: TUI 自繪風格下 VoiceOver 支援範圍待架構評估]
- **NFR-05 隱私與安全**：無帳號、無雲、無 telemetry、無網路請求（「Check for Updates」除外）；agent 派工只執行使用者顯式確認的指令、以使用者權限跑在本機；app 本體不代管任何 API key。
- **NFR-06 發布品質**：Developer ID 簽章 + notarization；開源 repo 含 README（含與原版的關係聲明）、LICENSE、格式規格文件。
- **NFR-07 UI 語言**：v1 英文 UI（發布受眾），文件雙語。[ASSUMPTION]

## 8. 發布與通路

- GitHub 開源（License TBD，傾向 MIT [ASSUMPTION]）+ Releases 發 notarized DMG；Homebrew cask 提交。[ASSUMPTION]
- **命名與定位聲明**：發布把「重製」從私人練習變成公開競品 —— 產品必須有自己的名字（不得沿用 tasks.txt / taskstxt），README 明確致敬原版並聲明格式相容範圍與差異。名字待定（Open Question OQ-1）。
- 發布敘事即作品集敘事：「原版證明了縫隙，我補上時間、重要性、焦點、派工四個軸」。

## 9. 開放問題

| # | 問題 | 影響 | 負責 |
|---|---|---|---|
| OQ-1 | 產品命名（不得與 taskstxt.app 混淆） | 發布敘事、repo 名、DMG 名 | Scott |
| OQ-2 | due 自訂日曆設計稿（SPEC 既有 TBD） | FR-014 選配路徑 | Scott |
| OQ-3 | 成功指標數字校準（stars/下載/派工頻率） | §4 | Scott |
| OQ-4 | VoiceOver 支援深度（TUI 自繪的可及性成本） | NFR-04 | 架構階段 |
| OQ-5 | 派工 prompt 模板是否可自訂（vs 反指標「設定 ≤ 2」的張力） | FR-071 | 觀察 dogfood 後決定 |

## 10. 附錄

技術選型、模組拆解、派工整合模式的完整比較（CLI vs MCP vs 檔案慣例）、被拒方案理由、市場研究摘要 —— 見同目錄 `addendum.md`。里程碑關鍵路徑沿用 SPEC §10 並補統計：骨架 → 無損 parser → 檔案監看 → 清單 → 象限 → Focus → 全域捕捉 → 便箋/歸檔 → 統計 → **派工** → 手感打磨。

**實作進度快照（2026-07-20）**：F1–F7、F9、F10 已有可跑雛形並經人工測試迭代（捕捉命令列與象限 50/50 版面即測試回饋的產物）；**F8 派工尚未實作** —— 它是差異化的最後一塊，也是「架構值不值得繼續」問題的關鍵驗證點。
