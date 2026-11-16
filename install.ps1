<#
.SYNOPSIS
    Installs Dark Notepad for the current user (no admin rights needed).
.DESCRIPTION
    Copies the app to %LOCALAPPDATA%\DarkNotepad and adds a Start Menu shortcut.
    Run from a cloned repo/extracted release, or one-line from the web:
      irm https://raw.githubusercontent.com/248Tech/DarkNotepad/main/install.ps1 | iex
.PARAMETER Desktop
    Also create a Desktop shortcut.
.PARAMETER Uninstall
    Remove the app and shortcuts.
#>
[CmdletBinding()]
param([switch]$Desktop, [switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$repo    = '248Tech/DarkNotepad'
$target  = Join-Path $env:LOCALAPPDATA 'DarkNotepad'
$startLn = Join-Path ([Environment]::GetFolderPath('Programs')) 'Dark Notepad.lnk'
$deskLn  = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Dark Notepad.lnk'

if ($Uninstall) {
    Remove-Item $target, $startLn, $deskLn -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Dark Notepad removed.' -ForegroundColor Green
    return
}

$files = 'DarkNotepad.ps1', 'DarkNotepad.vbs'
$src = $PSScriptRoot
if (-not $src -or -not (Test-Path (Join-Path $src 'DarkNotepad.ps1'))) {
    # Running via irm | iex: fetch the latest release asset
    Write-Host 'Downloading latest release...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $rel = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'DarkNotepad-installer' }
    $asset = $rel.assets | Where-Object name -like 'DarkNotepad-*.zip' | Select-Object -First 1
    if (-not $asset) { throw 'No release asset found.' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("DarkNotepad-" + [guid]::NewGuid())
    New-Item -ItemType Directory $tmp | Out-Null
    $zip = Join-Path $tmp 'dn.zip'
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $tmp -Force
    $src = $tmp
}

New-Item -ItemType Directory -Force $target | Out-Null
foreach ($f in $files) { Copy-Item (Join-Path $src $f) $target -Force; Unblock-File (Join-Path $target $f) }

function New-Shortcut($path) {
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $s.Arguments = "`"$target\DarkNotepad.vbs`""
    $s.WorkingDirectory = $target
    $s.IconLocation = Join-Path $env:WINDIR 'System32\shell32.dll,70'
    $s.Description = 'Dark Notepad - a dark-mode Notepad clone'
    $s.Save()
}
New-Shortcut $startLn
if ($Desktop) { New-Shortcut $deskLn }

Write-Host "Dark Notepad installed to $target" -ForegroundColor Green
Write-Host 'Find it in the Start Menu: "Dark Notepad".'
