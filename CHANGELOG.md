# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-11-16

### Added
- **Find & Replace** dialog (Ctrl+H) with Replace and Replace All (single undoable edit), **Find Next** (F3), wrap-around and match-case.
- **Go To Line** (Ctrl+G).
- Status bar now shows encoding, line-ending style and zoom level.
- Remembers window position/size, font, word wrap, zoom and status-bar visibility between launches.
- Drag-and-drop a file onto the window to open it.
- Dark right-click menu with plain-text paste; Edit menu items enable/disable with context.
- Custom app icon; DPI-aware (sharp on high-DPI displays); Ctrl+0 resets zoom.
- Automated test suite (`tests/Run-Tests.ps1`) run in CI, and stricter lint in CI.

### Fixed
- **Line endings:** files were saved with bare LF; the original line ending (CRLF/LF/CR) is now preserved.
- **Encoding:** UTF-16 and ANSI files were silently converted to UTF-8; the original encoding is now preserved (ANSI is upgraded to UTF-8 only if needed to avoid losing characters).
- Line/column was wrong with Word Wrap on (counted wrapped rows, not lines).
- Pasting no longer brings in rich-text formatting.
- Saves are now atomic (write to a temp file, then replace), so a crash can't truncate your file.
- Launching from a non-STA console no longer breaks dialogs: the app relaunches itself in STA mode.
- Unreadable or invalid settings can never prevent startup; open/save errors show a message instead of failing silently.

### Changed
- Status-bar and selection updates are debounced for smoother typing in large files.

## [1.0.0] - 2026-11-16

### Added
- Dark-mode editor: light text on dark gray, dark menus, dark status bar and dark scrollbars.
- File menu: New, Open, Save, Save As with unsaved-changes prompts (UTF-8, no BOM).
- Edit menu: Undo, Redo, Cut, Copy, Paste, Find (match case), Select All, Time/Date (F5).
- Format menu: Word Wrap and Font picker. View menu: status bar toggle, zoom in/out.
- Status bar with line, column and character count.
- Per-user installer (`install.ps1`) with Start Menu / Desktop shortcut and uninstall.
- Windowless launcher (`DarkNotepad.vbs`) and open-with-file support.
- Live in-browser demo at <https://248tech.github.io/DarkNotepad/>.

