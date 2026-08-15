# Changelog

All notable changes to txtnimal are documented in this file.

## [0.3.0] - 2026-08-15

Covers everything since 0.1.0; the interim 0.2.0 version bump was never released or tagged.

### Added

- Undo and redo (`⌘Z` / `⇧⌘Z`) for task edits, built on whole-document text snapshots. Undo never crosses an external edit — the history is discarded whenever the file changes underneath the app, so redoing your own work can't silently overwrite someone else's.
- Recurring tasks are now visible and editable: a `↻` badge on any task with a valid `rec:` value, a recurrence field in the `⌘E` editor, `rec:` autocomplete in global capture, and a confirmation showing the next occurrence's due date when you complete one.
- The `⌘K` command palette is now assembled from the app's live command set instead of a hand-written list: it filters to what the current page and selection can actually run, shows shortcuts derived from the real key bindings, and includes installed command plugins.
- Open the scratchpad from the command palette.
- External edits are first-class: the app reloads automatically when the file changes and nothing is unsaved, and offers an explicit reload-or-overwrite choice when a write would otherwise clobber someone else's changes. A `touch` that leaves content unchanged is ignored entirely.
- Plugin ecosystem: a unified registry for bundled and installed plugins, a generic plugin page host, and a gallery for managing, placing, and disabling them.
- Plugins for reports, reviews, analytics, methodology views, habit tracking, brain dump, smart triage, natural-language reports, export packs, and importers.
- Host capabilities available to plugins: key-value storage, agent query brokering, export write, and import read.
- Agent chat with streaming responses and task mutation tools (complete, delete, retitle).
- Right-click context menu on tasks, with archive and delete confirmation.

### Security

- Installed plugins run through a rate-limited XPC transport, isolating plugin execution from the app process.
- Plugin entry files resolve through a single containment guard that follows symlinks and rejects anything escaping the package root.
- Chat streaming enforces a payload size bound before parsing and a stream deadline.
- Agent endpoints are validated as HTTPS when saved.

### Fixed

- Menu shortcuts now agree with the app's own key handling: `⌘2` opens the quadrant view and `⌘4` opens statistics from both paths. Previously the menu opened the quadrant view for `⌘4`, contradicting the in-app binding.
- All twelve bundled plugin fixtures reach the app bundle; two were silently missing.
- Plugin surfaces agree with the gallery about where a plugin is placed.
- Documented shortcuts match the actual bindings.

## [0.1.0] - 2026-07-22

### Added

- Capture tasks from any app with a configurable global keyboard shortcut or the menu bar.
- Autocomplete existing Lists and Tags by typing `+` or `@`, with keyboard navigation and live filtering.
- Choose common due dates from `due:` suggestions, including today, tomorrow, relative days, and weekdays.
- Review parsed metadata as removable chips before saving a captured task.
- Use the `/` command composer to add due dates, Lists, Tags, and notes without memorizing syntax.
- Accept conservative Traditional Chinese date suggestions such as「明天」、「後天」and weekdays.
- Manage plain-text tasks across list, quadrant, scratchpad, focus, and statistics views.
- Customize language, appearance, typography, spacing, app icon, global shortcut, and task-file location.

### Reliability

- Keep global capture available during menu-bar-only launches, even before the main window is created.
- Preserve ordinary typing and input-method composition while autocomplete owns navigation keys.
- Normalize supported due-date shortcuts to ISO dates without rewriting unknown task metadata.

### Distribution notes

- Requires macOS 13 Ventura or later on Apple Silicon or Intel Macs.
- Includes a repeatable script that packages an ad-hoc signed Universal app, DMG, and SHA-256 checksum for self-use distribution.
- This local portfolio build is not notarized for public distribution unless packaged with a Developer ID certificate.
