# Handoff → Codex — Plugin 安全修正 + UI 串接深驗

> 建立者:Miles(Claude)· 2026-07-21 · 基準 HEAD `957fd84`
> 背景:針對 `c06f593..957fd84` 這批發行安全 commit 的 code review。多數實作為真,但下列三處為「簽章的形狀、信任鏈是假的」,進正式發行前必須修。Task A 另為一項功能深驗。

---

## Task A(🔴 必修)撤銷清單並未真正簽章

**檔案** `Sources/txtnimalCore/Plugins/PluginRevocationStore.swift:14`

**現況** `isAuthentic()` 只是重算 payload 的 SHA256 再跟自己欄位比對 —— 這是自我校驗和,不是簽章。任何人改了 `revocations.json` 後重算 hash 即可通過。攻擊面:把被撤銷的惡意插件 ID 從清單移除 + 重算 hash → 撤銷失效。

**要求**
- 撤銷清單改為由**可信發行私鑰**簽章;裝置端只保存對應**公鑰(pinned,編譯進 binary 或隨 app 簽章資源派送,不可由清單自帶)**。
- `isAuthentic()`(建議改名 `verifySignature(using trustedKey:)`)用 P256 ECDSA 驗 `version + 排序後 revokedPluginIDs` 的 canonical payload。
- 沿用現有 rollback 保護(`version >= 舊值`)。
- 驗簽失敗須擲錯,呼叫端(`load()`/`update()`)維持現在的 throw 行為。

**驗收**
- 竄改 `revocations.json` 任一欄位後 `load()` 必擲錯(新增測試)。
- 用非可信金鑰簽的清單被拒。
- 既有 `PluginRevocationStoreTests` 仍綠。

---

## Task B(🔴 必修)插件簽章缺信任錨,公鑰可由攻擊者自帶

**檔案** `Sources/txtnimalCore/Plugins/PluginSecurityPolicy.swift:39-49`

**現況** P256 驗簽本身正確,但 `publicKeyBase64` 由插件自己夾帶,`teamID` 只做字串比對(`:34`)。攻擊者可自產金鑰→自簽→夾帶自己的公鑰→teamID 填成要求值→通過。只證明「持私鑰者簽了」,未證明「可信者簽的」。

**要求**
- 建立**可信簽署者公鑰清單**(pinned,綁 `teamID`;來源同 Task A 的信任錨,不可由 signature blob 自帶)。
- `validateSignature` 改為:用**受信任且對應該 teamID 的公鑰**驗簽,而非 signature 自帶的公鑰。自帶公鑰若與 pinned 不符即拒。
- `requiredSignerTeamID != nil` 時,缺簽章/缺可信公鑰一律拒(現行 `:47-48` 已擋缺簽章,但要補「公鑰非可信」這條)。

**驗收**
- 自簽 + 自帶公鑰(不在信任清單)→ 被拒(新增測試)。
- 可信公鑰 + 正確簽章 → 通過。
- teamID 相符但公鑰非該 team 的 pinned 公鑰 → 被拒。

---

## Task C(🟡 硬化)Broker 呼叫端身分用 PID,且只比對 bundle id

**檔案** `PluginRunnerSpike/Service/main.swift`(`BrokerCallerIdentity.isAllowed`)

**現況**
1. 用 `kSecGuestAttributePid`(PID)辨識呼叫端 → PID 重用競態(check 到 use 之間 PID 可被替換)。原註解本要求 audit token,實作卻降級成 PID。
2. 僅比對 `kSecCodeInfoIdentifier`(bundle id 字串),ad-hoc 簽的假 binary 可自稱同一 identifier。

**要求**
- 改用**連線的 `auditToken`**:`kSecGuestAttributeAudit` 搭配 `connection.auditToken`(NSXPCConnection 的 audit_token),取代 PID。
- 身分驗證改用 `SecCodeCheckValidity` + **完整 designated/自訂 requirement**,至少包含 `anchor apple generic and certificate leaf[subject.OU] = "<TEAMID>"` 及 identifier 白名單,而非只比字串。

**驗收**
- 非我方簽章(ad-hoc / 他人 Developer ID)的呼叫端連線被拒。
- requirement 以 teamID + Apple 錨鏈驗證,不再單靠 identifier 字串。

---

## Task D(🟡 一致性)發行閘門接受了非 Developer ID 憑證

**檔案** `scripts/verify-public-release.sh`

**現況** 訊息說「requires Developer ID」,`awk` 卻同時接受 `Apple Development`。`Apple Development` 不是 Developer ID、過不了 notarization,卻能通過閘門。

**要求**
- 只接受 `Developer ID Application`(移除 `Apple Development` 分支)。
- 加一步 `xcrun stapler validate "$app_path"` 或等效,確認 notarization ticket 已 staple(目前只有 `spctl --assess`,無 staple 檢查)。
- `--deep` 已 deprecated,評估改用逐 bundle 驗證(非阻斷,標 TODO 即可)。

**驗收** Apple Development 簽的 build 被閘門拒;Developer ID + 已 notarize + stapled 的 build 通過。

---

## Task E(🔍 深驗,非修改)第 5 項 UI 串接完整性

**範圍** commits `0b0c731`(apply validated plugin intents)、`d530b28`(reschedule mutation flow)、`646df09`(execute installed plugin through broker)。

**要求** 確認「實際插件 fixture 已接成可由 UI 操作的正式插件」是否真的端到端可用,而非只到 broker 層:
- UI 能列出、啟用、觸發 fixture 插件,結果回寫 UI。
- 走的是正式 broker 執行路徑(非 prototype/mock)。
- 錯誤與撤銷狀態有反映到 UI。

**產出** 一份簡短報告:哪些端到端通、哪些仍是 prototype/stub、缺口清單。**先別改 code,先回報缺口**。

---

## 共同約束
- 沿用專案現有風格與 `PluginValidationError` / `PluginExecutionError` 型別。
- 每項附最小測試(專案已有 `Tests/txtnimalCoreTests/`)。
- Task A~D 每項獨立 commit,訊息如實描述(不要再把 hash 當 signature、PID 當 audit token 賣)。
- 信任錨(Task A/B 的 pinned 公鑰)來源請一致,並在 commit 說明金鑰如何派送與輪替。
