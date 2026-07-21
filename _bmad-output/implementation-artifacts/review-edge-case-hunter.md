# Edge Case Hunter Review Prompt

Invoke the `bmad-review-edge-case-hunter` skill on the current uncommitted txtnimal changes.

## Review target

Run these commands from `/Users/scottchen/Documents/tasktxt_gui_bmad` to reconstruct the complete diff:

```bash
git diff HEAD
git diff --no-index /dev/null README.md
git diff --no-index /dev/null docs/app-size-report.md
git diff --no-index /dev/null docs/plugin-architecture-evaluation.md
```

Search specifically for edge cases involving missing or corrupt icon resources, first launch, switching A/B/C icons, Debug versus Release behavior, Intel and Apple Silicon builds, APFS size reporting, archive/install overhead, localization, and generated Xcode project drift. Return findings as a Markdown list with severity, file/line evidence, reproduction conditions, and a concrete fix.
