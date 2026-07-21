# Blind Hunter Review Prompt

Invoke the `bmad-review-adversarial-general` skill on the current uncommitted txtnimal changes.

## Review target

Run these commands from `/Users/scottchen/Documents/tasktxt_gui_bmad` to reconstruct the complete diff:

```bash
git diff HEAD
git diff --no-index /dev/null README.md
git diff --no-index /dev/null docs/app-size-report.md
git diff --no-index /dev/null docs/plugin-architecture-evaluation.md
```

Review the implementation adversarially without using prior conversation context. Focus on correctness, regressions, unsafe assumptions, broken resource loading, build configuration errors, and inaccurate documentation. Return findings as a Markdown list with severity, file/line evidence, and a concrete fix.
