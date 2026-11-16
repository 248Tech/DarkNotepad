# Contributing to Dark Notepad

Thanks for your interest! Bug reports, ideas and pull requests are welcome.

## Getting started
1. Fork and clone the repo.
2. Run the app from source: `powershell -STA -ExecutionPolicy Bypass -File .\DarkNotepad.ps1`
3. Make your change on a feature branch (`feat/find-replace`, `fix/zoom-crash`).

## Guidelines
- Target **Windows PowerShell 5.1** (ships with Windows 10/11); avoid PowerShell 7-only syntax.
- Keep it dependency-free: WinForms and the .NET Framework only.
- Run the linter before pushing:
  ```powershell
  Install-Module PSScriptAnalyzer -Scope CurrentUser
  Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning
  ```
- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`).
- Update `CHANGELOG.md` under **Unreleased** for user-visible changes.

## Pull requests
Describe what changed and why, link related issues, and include a screenshot for UI changes.

By contributing you agree your work is licensed under the [MIT License](LICENSE).
