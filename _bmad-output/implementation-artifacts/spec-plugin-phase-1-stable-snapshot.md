---
title: 'Plugin Phase 1 Stable Task Snapshot'
type: 'feature'
created: '2026-07-21'
status: 'done'
review_loop_iteration: 0
baseline_commit: '05c60e8'
context:
  - 'docs/plugin-phase-0-report.md'
  - 'Sources/TasksTxtCore/TaskDocumentStore.swift'
  - 'Sources/TasksTxtCore/TaskLine.swift'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Phase 0 插件契約中的 task snapshot 仍依賴外部傳入 revision，正式 Core 也只有短生命週期的 generation／index handle。插件若保存資料後再回傳操作，無法穩定辨識同一筆 task，也無法可靠判斷文件是否在外部變更。

**Approach:** 在 TasksTxtCore 建立可序列化的穩定 task identity、文件 revision 與插件 snapshot builder；保留既有 tasks.txt 無損 round-trip，並讓 snapshot 以明確版本與 deterministic revision 提供給插件驗證層使用。

## Boundaries & Constraints

**Always:** 穩定 ID 必須由 task 內容以外的持久化 metadata 產生並跨載入保存；既有沒有 ID 的 tasks.txt 必須可讀取；snapshot 必須 Codable、版本化且 deterministic；revision 變更時必須能被偵測；既有 TaskWorkspace generation／index API 維持相容。

**Ask First:** 若要修改 tasks.txt 的可見格式、加入額外 sidecar 檔案、或要求既有使用者資料自動寫入 metadata 以外的新欄位，先停止並取得確認。

**Never:** 不以 task 標題、陣列 index 或 hash 單獨作為永久 ID；不直接改寫既有未知 token；不在本切片加入 journal、插件安裝 UI、正式插件商店或跨檔案 transaction。

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Existing metadata | tasks.txt task has stable ID metadata | Load preserves ID and snapshot emits same ID | Malformed ID is treated as missing and receives a new ID only when explicitly persisted |
| Legacy task | task has no stable ID | Read model exposes deterministic in-memory identity for this load | Do not mutate file during read-only snapshot creation |
| Snapshot encoding | Same document loaded twice without changes | Codable snapshot and document revision are byte-stable | Encoding failure is surfaced; no partial plugin request |
| External change | File content changes after snapshot | New load has a different document revision | Host rejects stale action with a typed conflict error |
| Duplicate identity | Two persisted tasks claim same ID | Load fails closed rather than silently merging tasks | Return duplicate-identity error with no write |

</frozen-after-approval>

## Code Map

- `Sources/TasksTxtCore/TaskLine.swift` -- lossless task line model and metadata token handling.
- `Sources/TasksTxtCore/TaskDocumentStore.swift` -- document load/save generation boundary.
- `Sources/TasksTxtCore/Plugins/PluginContracts.swift` -- versioned plugin task snapshot contract.
- `Sources/TasksTxtCore/Plugins/PluginSnapshotBuilder.swift` -- stable IDs, deterministic revision, and snapshot projection.
- `Tests/TasksTxtCoreTests/PluginSnapshotTests.swift` -- legacy, duplicate, encoding, and stale revision coverage.

## Tasks & Acceptance

**Execution:**

- [x] `Sources/TasksTxtCore/TaskLine.swift` -- add lossless stable-ID metadata accessors and targeted mutation -- preserve existing tasks.txt round-trip behavior.
- [x] `Sources/TasksTxtCore/TaskDocumentStore.swift` -- expose document bytes/revision inputs without breaking generation-based callers -- let snapshot creation detect external changes.
- [x] `Sources/TasksTxtCore/Plugins/PluginContracts.swift` -- version the task/document snapshot fields -- make plugin input Codable and explicit.
- [x] `Sources/TasksTxtCore/Plugins/PluginSnapshotBuilder.swift` -- build stable IDs, deterministic revision, and bounded plugin snapshots -- centralize projection rules.
- [x] `Tests/TasksTxtCoreTests/PluginSnapshotTests.swift` -- cover all matrix scenarios -- prevent identity collisions and stale writes.

**Acceptance Criteria:**

- Given a legacy task without an ID, when creating a read-only snapshot, then the task is represented without mutating tasks.txt.
- Given a task with persisted ID metadata, when loading and re-encoding its snapshot, then the ID remains unchanged and Codable output is deterministic.
- Given duplicate persisted IDs, when building a snapshot, then the builder fails closed with a typed duplicate-identity error.
- Given identical document bytes, when building snapshots twice, then the document revision is identical; changed bytes produce a different revision.
- Given a snapshot revision older than the current document revision, when validating a plugin action, then the Host returns a typed stale-document conflict and performs no mutation.

## Verification

**Commands:**

- `swift test` -- expected: all existing and new Core tests pass.
- `xcodegen generate && xcodebuild -project TasksTxt.xcodeproj -scheme TasksTxt -configuration Debug -derivedDataPath .build/DerivedData-phase1 build CODE_SIGNING_ALLOWED=NO` -- expected: App and Core compile without changing production navigation.
- `git diff --check` -- expected: no whitespace errors.

## Suggested Review Order

**Snapshot identity and revision**

- Centralize projection from Core documents into versioned plugin data.
  [`PluginSnapshotBuilder.swift:15`](../../Sources/TasksTxtCore/Plugins/PluginSnapshotBuilder.swift#L15)

- Compute document revisions from exact task-file bytes, preventing caller-supplied hashes.
  [`TaskDocumentStore.swift:4`](../../Sources/TasksTxtCore/TaskDocumentStore.swift#L4)

- Persist stable identity without changing existing task line structure beyond metadata.
  [`TaskLine.swift:20`](../../Sources/TasksTxtCore/TaskLine.swift#L20)

**Stale action protection**

- Reject missing or mismatched current document revisions before host mutations.
  [`PluginValidation.swift:103`](../../Sources/TasksTxtCore/Plugins/PluginValidation.swift#L103)

- Keep snapshot payload explicitly versioned and Codable for future plugin transport.
  [`PluginContracts.swift:65`](../../Sources/TasksTxtCore/Plugins/PluginContracts.swift#L65)

**Regression evidence**

- Exercise legacy IDs, duplicate identities, deterministic revisions, encoding, and stale actions.
  [`PluginSnapshotTests.swift:4`](../../Tests/TasksTxtCoreTests/PluginSnapshotTests.swift#L4)
