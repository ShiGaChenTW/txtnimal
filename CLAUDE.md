# txtnimal — project rules

## Gitignored local docs (`openspec/`, `plans/`) don't survive a worktree

`openspec/` and `plans/` are gitignored (public repo — see `.gitignore` line 43's note,
same rule as `docs/`). Git worktrees each get their own working copy of gitignored
paths, and that copy is **not** touched by `git merge` — it only lives on disk in that
worktree. So a change doc an agent creates under `openspec/changes/...` inside its
worktree is invisible to `git diff`/`git merge` and is silently deleted the moment the
worktree is removed. This already happened once (2026-08-21, G-snap round: the agent's
commit message said "Opens openspec/changes/add-plugin-snapshot-fields", but the
directory was gone by the time PM reviewed the diff — reconstructed after the fact from
the commit itself).

`.worktreeinclude` (repo root) copies the *current* `openspec/`/`plans/` into every new
worktree at creation time, so a dispatched agent can at least read existing change docs
and handoff plans for context. That only fixes the read side.

**The write side is a process rule, not infra: openspec change docs are the PM's job,
written directly on `main`, never left for the dispatched agent's worktree copy to
carry.** Either brief the change doc into `openspec/changes/<name>/` on `main` before
dispatch, or write it from the reviewed diff after the agent reports done and before
`git worktree remove`. Never assume a change doc an agent says it "opened" survived —
check `openspec/changes/` on `main` after merge, not just the git diff.

## PM does not implement directly

Orchestrate + delegate code changes to a sub-agent (`Engineer`/`Bellows`/`Relay` per the
routing switch in `~/.claude/CLAUDE.md`), then verify the diff yourself before merging.
See `plans/handoff__2026-08-21-1230.md` for the merge workflow this session established
(merge `main` into the worktree branch before merging the worktree into `main`; push
only after asking).
