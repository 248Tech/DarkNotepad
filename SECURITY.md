# Security Policy

## Supported versions
Only the latest release receives fixes.

## Reporting a vulnerability
Please **do not** open a public issue. Use GitHub's private
[security advisory form](https://github.com/248Tech/DarkNotepad/security/advisories/new).
Expect an acknowledgement within a few days.

## Notes for users
- Dark Notepad is an unsigned PowerShell script. Windows SmartScreen or Defender may show a warning the first time; the full source is in this repository for you to read.
- The app makes **no network connections** and collects no telemetry. Only `install.ps1`, when run via `irm | iex`, contacts GitHub to download the latest release.
- Prefer downloading from the [Releases](https://github.com/248Tech/DarkNotepad/releases) page and verifying the published SHA-256 checksum.
