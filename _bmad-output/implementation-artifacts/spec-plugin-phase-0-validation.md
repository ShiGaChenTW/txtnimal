---
title: 'Plugin Phase 0 Architecture Validation'
type: 'feature'
created: '2026-07-21'
status: 'done'
review_loop_iteration: 0
baseline_commit: '2754d3ef0a7b84015627298988adb5da7f13c7d3'
context:
  - 'docs/two-layer-plugin-evaluation.md'
  - '_bmad-output/planning-artifacts/architecture/architecture-tasktxt_gui_bmad-2026-07-21/ARCHITECTURE-SPINE.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** txtnimal 尚未用可執行程式證明「命令型插件」與「受控頁面插件」能共用安全邊界，也未驗證公開插件所需的 XPC／Sandbox 拓撲與成本。直接建立正式平台會把高風險假設帶入 Core 與 UI。

**Approach:** 建立不進入正式使用者流程的 Phase 0 垂直原型：共用版本化 manifest、capability、資料快照、action 與 page schema 契約；以「延到明天」命令及「每週回顧」頁面 fixture 證明兩層共用驗證管線；另以最小 XPC service 驗證程序隔離與失敗復原，最後輸出實測報告。

## Boundaries & Constraints

**Always:** 所有輸入先做版本、大小、節點、深度、ID、query、action 與 capability 驗證；未知內容 fail closed。頁面只含資料，SwiftUI 由 Host renderer 建立。插件只能回傳 typed intent，不取得 `TaskStore`、文件 URL 或直接寫檔能力。原型需可由自動測試重現，量測需記錄工具鏈與命令。

**Ask First:** Phase 0 若證明必須修改既有 `TaskWorkspace` 公開 mutation 契約、改用非 JavaScriptCore runtime、開放網路、加入第三方依賴，或無法在現有簽章設定下建立可驗證的 XPC／Sandbox 拓撲，必須停止並回報替代方案。

**Never:** 不建立插件商店、更新服務或公開安裝流程；不載入第三方 SwiftUI／NSView；不允許修改內建頁面；不把 prototype 導覽加入正式五個頁籤；不宣稱 Phase 0 runner 已達公開第三方安全等級；不提前實作 Phase 1 的穩定 task ID、跨檔 journal 或完整權限 UI。

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| 命令原型 | 合法 manifest、task snapshot、延到明天 action | 產生可驗證的 typed command intent，不寫檔 | capability 或 revision 不符即拒絕 |
| 頁面原型 | 合法每週回顧 schema | Host renderer 顯示 allowlist 元件並把按鈕送回同一 action gate | 未知 node/action、超限 payload/depth 整頁拒絕 |
| Runner 故障 | hang、crash、malformed response | Host/harness 保持可用並回報穩定錯誤 | timeout 後終止或失效 worker，不重用污染狀態 |
| Package 逃逸 | `entry` 包含絕對路徑、`..` 或 symlink escape | 不載入 package | 回傳不含敏感路徑的驗證錯誤 |
| 相容性 | 不支援的 API/schema major | 拒絕 plugin/page | 穩定 incompatible-version error |

</frozen-after-approval>

## Code Map

- `Package.swift` -- 加入純 Swift 插件契約／驗證測試可編譯的 Core 來源，不引入第三方 dependency。
- `Sources/TasksTxtCore/Plugins/` -- manifest、capability、snapshot、action、page schema、limits 與 fail-closed validator。
- `App/Plugins/PluginPagePrototypeView.swift` -- 僅供 Phase 0 preview/harness 使用的 allowlist SwiftUI renderer，不接正式導覽。
- `PluginRunnerSpike/` -- 最小 XPC protocol/service/host harness 與 sandbox 實驗設定；與正式 App target 隔離。
- `PluginFixtures/` -- 「延到明天」與「每週回顧」兩個固定 package/schema 案例，以及惡意／錯誤 fixtures。
- `Tests/TasksTxtCoreTests/PluginArchitectureSpikeTests.swift` -- 契約、limit、capability、路徑與 schema edge cases。
- `scripts/measure-plugin-phase0.sh` -- 執行測試、XPC harness、Release size 與時間量測。
- `docs/plugin-phase-0-report.md` -- 記錄證據、成功／失敗、容量、效能、限制與 Phase 1 go/no-go 建議。

## Tasks & Acceptance

**Execution:**

- [x] `Sources/TasksTxtCore/Plugins/`、`PluginFixtures/` -- 建立兩層共用 Codable 契約、限制與 fixtures，保持 domain mutation 由 Host 擁有。
- [x] `Tests/TasksTxtCoreTests/PluginArchitectureSpikeTests.swift` -- 覆蓋矩陣中的合法及拒絕案例，確認未知內容 fail closed。
- [x] `App/Plugins/PluginPagePrototypeView.swift` -- 實作有限元件 renderer prototype，以 Preview/harness 證明頁面可渲染及 action 可回到 gate。
- [x] `PluginRunnerSpike/`、`project.yml` -- 建立隔離 runner 實驗；驗證正常回應、逾時、crash 與 Host 存活，不接觸任務檔案。
- [x] `scripts/measure-plugin-phase0.sh`、`docs/plugin-phase-0-report.md` -- 自動蒐集測試、大小與延遲結果，對每個架構假設給出 go/no-go。

**Acceptance Criteria:**

- Given 兩個核准 fixture，when 執行 Phase 0 harness，then 命令 intent 與頁面 schema 都通過同一 manifest/capability/action 邊界。
- Given renderer prototype，when 載入每週回顧 schema，then 只用 Host allowlist SwiftUI 元件顯示，且未加入正式 App 導覽。
- Given hang 或 crash runner，when harness 執行，then呼叫端可在預算內收到穩定錯誤並繼續下一次健康請求。
- Given 完成量測，when 閱讀報告，then可重現指令、實測數據、殘留風險與 Phase 1 go/no-go 均明確記錄。

## Spec Change Log

## Design Notes

Phase 0 的 production-shaped 部分僅限可重用的 value contracts 與 validators；renderer、runner topology 與 fixtures 都標示為 prototype。若 XPC target 因目前 ad-hoc signing／sandbox 組合無法成立，報告應保留失敗證據並停止，而不是弱化隔離要求。

## Verification

**Commands:**

- `swift test` -- 所有既有與插件契約測試通過。
- `xcodegen generate && xcodebuild -project TasksTxt.xcodeproj -scheme TasksTxt -configuration Debug -derivedDataPath .build/DerivedData build CODE_SIGNING_ALLOWED=NO` -- App 與 prototype renderer 編譯成功。
- `scripts/measure-plugin-phase0.sh` -- 輸出可重現的 runner、容量與延遲證據，失敗時回傳非零狀態。

## Suggested Review Order

**安全邊界與契約**

- 從單一 fail-closed gate 理解 manifest、頁面與 action 的信任邊界。
  [`PluginValidation.swift:34`](../../Sources/TasksTxtCore/Plugins/PluginValidation.swift#L34)

- 版本化純值契約隔開插件程式與正式資料模型。
  [`PluginContracts.swift:32`](../../Sources/TasksTxtCore/Plugins/PluginContracts.swift#L32)

**隔離執行拓撲**

- Broker 限制輸入輸出，並為每次請求建立可拋棄 Worker。
  [`main.swift:7`](../../PluginRunnerSpike/Service/main.swift#L7)

- 沙盒 Worker 執行 JavaScriptCore，僅交換版本化 JSON。
  [`main.swift:55`](../../PluginRunnerSpike/Worker/main.swift#L55)

- Xcode target 關係確保實驗元件不進入正式 App。
  [`project.yml:52`](../../project.yml#L52)

**Host 擁有的頁面與操作**

- SwiftUI allowlist renderer 只送出已驗證的 typed intent。
  [`PluginPagePrototypeView.swift:6`](../../App/Plugins/PluginPagePrototypeView.swift#L6)

- 按鈕操作在 Host 端重新檢查 capability 與 revision。
  [`PluginPagePrototypeView.swift:69`](../../App/Plugins/PluginPagePrototypeView.swift#L69)

**證據與維運**

- 契約測試涵蓋限制、逃逸、未知輸入與 revision 衝突。
  [`PluginArchitectureSpikeTests.swift:5`](../../Tests/TasksTxtCoreTests/PluginArchitectureSpikeTests.swift#L5)

- 可重現腳本比較固定基準，並驗證沙盒與故障復原。
  [`measure-plugin-phase0.sh:7`](../../scripts/measure-plugin-phase0.sh#L7)

- 報告彙整量測結果、限制及 Phase 1 GO 條件。
  [`plugin-phase-0-report.md:1`](../../docs/plugin-phase-0-report.md#L1)
