# Changelog

All notable changes to txtnimal are documented in this file.

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
- This local portfolio build is not notarized for public distribution unless packaged with a Developer ID certificate.
