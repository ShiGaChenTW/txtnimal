# PRD Addendum — tasks.txt GUI

> 屬於下游文件（架構、solution design）的深度內容，PRD 本文不載。

## 1. 技術約束與模組拆解（沿用 SPEC §外殼/模組）

- SwiftUI · macOS 13+ · 非 Electron · 不進 App Store sandbox。
- 唯一外部依賴：`KeyboardShortcuts`（Sindre Sorhus, MIT）。
- 模組：`TaskLine`（raw line + 解析欄位）· `TaskStore: ObservableObject`（load/save/監看/焦點單數約束）· `TodoTxtParser`（冪等 line↔TaskLine）· `ListView` / `QuadrantView` / `ScratchView` / `FocusBar` / `CapturePanel` / `FocusHUD` / `MenuBarExtra`。
- 派工新增模組（建議）：`DispatchPanel`（prompt 組裝與預覽）· `AgentLauncher`（終端 session / `claude -p` 調用）· `ProjectMapping`（+project → repo 路徑，存 UserDefaults）。
- 檔案層：Foundation 原子寫入 + FSEvents/DispatchSource。
- 外殼路線待決（SPEC 既有）：A = XcodeGen 全搭 / B = Scott 開 Xcode、agent 填碼。

## 2. Agent 派工 — 三模式完整比較與決策理由

| 模式 | 機制 | 代表 | 優點 | 坑 |
|---|---|---|---|---|
| **A. CLI 調用（v1 採用）** | 選任務→組 prompt→`claude -p` 或開終端 session | vibe-kanban | 零協定成本、市場驗證最多、agent 無需懂格式 | 並行需 worktree 隔離；無人值守要寬權限；進度回報要自己接 |
| B. MCP server（v2 候補） | app 曝露 3-5 tools 讓 agent 讀寫任務 | task-master、Backlog.md | 狀態自動回寫、格式即真相 | tool 定義 token 成本（task-master 36 tools ≈ 21k tokens 的反面教材）；工具面必須壓在個位數 |
| C. 檔案慣例（隱含免費獲得） | CLAUDE.md 指引 agent 直接讀寫 tasks.txt | Backlog.md 預設模式 | 成本近零、與檔案哲學完全一致 | agent 可能寫壞格式（parser 寬容已擋）；並發寫入（FR-005 已擋) |

決策：v1 = A，C 因 parser 寬容 + 檔案監看免費獲得，B 留 v2 且工具數 ≤ 5。

市場共同教訓（已對映進 FR）：
1. 瓶頸從寫碼移到 review → 強制 review gate（FR-075）
2. 一行任務太薄 → 派工前 prompt 擴寫與預覽（FR-071）
3. 回饋通道要明確（Copilot「assign 後不看 issue 留言」反面教材）→ v1 用終端互動 session 迴避此題

## 3. 被拒方案與理由

- **Done 置頂 + 晨間清空**（原版做法，done-list 心理學）：拒。理由 = 主清單是時間軸視圖，由上而下 = 由急到緩的閱讀順序不可打斷。取 daily reset 的歸檔儀式、不取置頂。
- **Mac App Store**：拒。sandbox 犧牲全域熱鍵、自由檔案路徑、SMAppService 自啟 —— 三者都是核心體驗。
- **Sparkle 自動更新**：拒（v1）。破壞「外部依賴 ≤ 1」反指標；免費工具的更新摩擦可接受。
- **優先級 `(A)`**：拒（SPEC 既有）。重要性由象限手動表達。
- **checkbox 形狀編碼區段語意**（UX 研究 💡 借鑑項）：未採，留給設計階段裁量 —— TUI 字元（`[ ]` vs `( )`）表達語意與極簡紀律的取捨。

## 4. 市場研究摘要（2026-07 掃描）

- 原版 taskstxt.app：Yevhen（PH @localhost_ceo），2026-07-04 上架、免費、992KB native Swift、PH 當日 #10/155 upvotes。哲學=「app 只是檔案上的快捷鍵層」（Steph Ango〈File over app〉）。無 AI/agent 整合。已知痛點：外部編輯衝突未定義、無全域捕捉、無 ⌘K、macOS 需求版本兩處矛盾（13+/14+）。
- 同類：SwiftoDo（嚴格 todo.txt、付費）、TodoTxtMac（開源、舊）、TaskPaper（outline 格式路線）。
- 派工版圖：claude-task-master（~25k stars，PRD→tasks.json，CLI+MCP 雙軌）、Backlog.md（一任務一 md、三檢查點）、vibe-kanban（卡片→worktree+分支，強制 diff review）、Linear Agent SDK(delegate 與 assign 責任分離)、GitHub Copilot coding agent（issue assign→draft PR）。
- 對本產品的縫隙判定：無人做「純文字檔任務 + 原生 GUI + agent 派工」三合一；最接近的 vibe-kanban 是 web/kanban 形態且不持有你的任務格式。

## 5. UX 研究未進 PRD 的細節（設計階段參照）

- 原版視覺細節庫:區段標題小型大寫+灰計數徽章、`+project` 右對齊彩色膠囊、`note:` 壓縮小圓點 hover 展開、底部「+ Add a task...」輸入列。
- 原版快捷鍵全表：↑/↓、↩ 編輯、⌘↩ 完成、⌘↑/⌘↓ 移動、⌘⇧↓ 送 backlog、⌘B 批次貼入、⌘F 搜尋、⌘⇧T 主題。⌘B 批次貼入未進本 PRD（可在 ⌘K 長尾實現）。
- 禪模式「終端變暗」= 降亮度/去飽和、不做毛玻璃 blur（Scott 已選技法 B）。
