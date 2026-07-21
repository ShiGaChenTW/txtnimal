# Adversarial Consistency Review

Date: 2026-07-21
Result: PASS after corrections

## Attacks attempted

| Attack | Expected defense | Result |
|---|---|---|
| Page button bypasses command validation | Every action re-enters the capability gate | Defended by AD-7 and the mutation sequence. |
| Plugin obtains the task-file URL through import/export | Host performs selection and passes only bounded content | Defended by capability definitions and AD-2. |
| Unknown schema node is silently omitted to alter meaning | Reject the page fail-closed | Defended by AD-5. |
| Plugin update retains old permissions after code changes | Grants bind to identity, signer/source, manifest and entry hash | Defended by AD-9. |
| Public plugin infinite loop freezes the App | Run outside the host with timeout and resource limits | Architecturally defended, but the mechanism must pass the mandatory spike. |
| Plugin injects into Settings and hides its controls | Built-in screens are not extension points | Defended by AD-4. |
| Renderer directly changes `TaskStore` | Renderer emits typed actions through the gate | Defended by AD-7. |
| External text edit is overwritten by stale plugin output | Validate durable file revision before mutation | Required prerequisite; no plugin launch before it exists. |
| Two-file archive operation crashes halfway | Journal and recovery are prerequisites | Required prerequisite; no plugin launch before it exists. |
| Top navigation becomes unbounded | Plugins Hub plus user-controlled pinning | Defended by AD-4 and the UX proposal. |

## Consistency correction

The original JSON example used a top-level `nodes` array while the allowlist required one `page` root. The example now uses one explicit `page` root with `children`.

## Residual decisions owned by the product owner

The six `[ASSUMPTION]` items remain deliberately unresolved. None can silently become an implementation default until the user confirms the report.

No contradiction remains between the report and architecture spine.
