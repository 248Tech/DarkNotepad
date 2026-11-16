<#
.SYNOPSIS
    Dark Notepad - a lightweight dark-mode Notepad clone for Windows.
.DESCRIPTION
    Light text on dark gray with dark menus, scrollbars and status bar. Find/Replace,
    Go To Line, word wrap, zoom, font picker, drag-and-drop, encoding and line-ending
    preservation, and remembered window/font settings. Pure PowerShell + WinForms:
    no install and no dependencies beyond Windows PowerShell 5.1.
.PARAMETER Path
    Optional file to open on launch.
.EXAMPLE
    .\DarkNotepad.ps1 notes.txt
.LINK
    https://github.com/248Tech/DarkNotepad
.NOTES
    License: MIT
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'UI helpers, not cmdlets')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Script-scoped state is read from WinForms event handlers')]
param([string]$Path)

$script:version = '1.1.0'
$script:appName = 'Dark Notepad'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ---------------------------------------------------------------------------
# Native helpers (small C# classes compiled in memory at startup)
# ---------------------------------------------------------------------------
$nativeSource = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class DarkColors : ProfessionalColorTable {
    static Color bg = Color.FromArgb(43,43,43), hi = Color.FromArgb(70,70,70), bd = Color.FromArgb(80,80,80);
    public override Color ToolStripDropDownBackground { get { return bg; } }
    public override Color MenuItemSelected { get { return hi; } }
    public override Color MenuItemSelectedGradientBegin { get { return hi; } }
    public override Color MenuItemSelectedGradientEnd { get { return hi; } }
    public override Color MenuItemPressedGradientBegin { get { return hi; } }
    public override Color MenuItemPressedGradientEnd { get { return hi; } }
    public override Color MenuItemBorder { get { return bd; } }
    public override Color MenuBorder { get { return bd; } }
    public override Color ImageMarginGradientBegin { get { return bg; } }
    public override Color ImageMarginGradientMiddle { get { return bg; } }
    public override Color ImageMarginGradientEnd { get { return bg; } }
    public override Color MenuStripGradientBegin { get { return bg; } }
    public override Color MenuStripGradientEnd { get { return bg; } }
    public override Color SeparatorDark { get { return bd; } }
    public override Color SeparatorLight { get { return bd; } }
    public override Color StatusStripGradientBegin { get { return bg; } }
    public override Color StatusStripGradientEnd { get { return bg; } }
}

public static class Native {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string app, string idList);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}

public static class TextUtil {
    // Line/column (1-based, logical lines separated by \n) for a character position.
    public static void LineCol(string t, int pos, out int line, out int col) {
        line = 1; int start = 0; int lim = Math.Min(pos, t.Length);
        for (int i = 0; i < lim; i++) if (t[i] == '\n') { line++; start = i + 1; }
        col = lim - start + 1;
    }
    // Character index where a 1-based logical line starts, or -1 if it does not exist.
    public static int LineStart(string t, int line) {
        if (line <= 1) return 0;
        int cur = 1;
        for (int i = 0; i < t.Length; i++) if (t[i] == '\n') { cur++; if (cur == line) return i + 1; }
        return -1;
    }
    public static int LineCount(string t) {
        int n = 1; for (int i = 0; i < t.Length; i++) if (t[i] == '\n') n++; return n;
    }
    // Dominant line ending of a block of text: "\r\n", "\n" or "\r" (CRLF when there are none).
    public static string DetectNewLine(string t) {
        int crlf = 0, lf = 0, cr = 0;
        for (int i = 0; i < t.Length; i++) {
            char c = t[i];
            if (c == '\r') { if (i + 1 < t.Length && t[i + 1] == '\n') { crlf++; i++; } else cr++; }
            else if (c == '\n') lf++;
        }
        if (crlf == 0 && lf == 0 && cr == 0) return "\r\n";
        if (crlf >= lf && crlf >= cr) return "\r\n";
        return lf >= cr ? "\n" : "\r";
    }
    // Normalise every line ending in t to nl in a single pass.
    public static string ConvertNewLines(string t, string nl) {
        StringBuilder sb = new StringBuilder(t.Length + t.Length / 20);
        for (int i = 0; i < t.Length; i++) {
            char c = t[i];
            if (c == '\r') { if (i + 1 < t.Length && t[i + 1] == '\n') i++; sb.Append(nl); }
            else if (c == '\n') sb.Append(nl);
            else sb.Append(c);
        }
        return sb.ToString();
    }
}
'@

$refs = 'System.Windows.Forms', 'System.Drawing'
if ($PSVersionTable.PSVersion.Major -ge 6) { $refs += 'System.Drawing.Primitives', 'System.ComponentModel.Primitives' }
if (-not ('TextUtil' -as [type])) { Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies $refs }

# ---------------------------------------------------------------------------
# File I/O (pure functions: no UI, covered by tests/Run-Tests.ps1)
# ---------------------------------------------------------------------------
function Get-FileData {
    <# Reads a text file, detecting encoding (BOM / UTF-8 / ANSI) and line ending. #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $skip = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = New-Object Text.UTF8Encoding($true); $name = 'UTF-8 with BOM'; $skip = 3
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = New-Object Text.UnicodeEncoding($false, $true); $name = 'UTF-16 LE'; $skip = 2
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = New-Object Text.UnicodeEncoding($true, $true); $name = 'UTF-16 BE'; $skip = 2
    } else {
        try {
            [void](New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)   # strict: throws on invalid UTF-8
            $enc = New-Object Text.UTF8Encoding($false); $name = 'UTF-8'
        } catch {
            $enc = [Text.Encoding]::GetEncoding(1252); $name = 'ANSI'
        }
    }
    $text = $enc.GetString($bytes, $skip, $bytes.Length - $skip)
    [pscustomobject]@{ Text = $text; Encoding = $enc; EncodingName = $name; NewLine = [TextUtil]::DetectNewLine($text) }
}

function Get-NewLineName([string]$NewLine) {
    switch ($NewLine) { "`n" { 'Unix (LF)' } "`r" { 'Mac (CR)' } default { 'Windows (CRLF)' } }
}

function Save-FileData {
    <# Atomically writes text using the given encoding and line ending. Returns the encoding actually used. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][Text.Encoding]$Encoding,
        [string]$EncodingName = 'UTF-8',
        [string]$NewLine = "`r`n"
    )
    $out = [TextUtil]::ConvertNewLines($Text, $NewLine)
    # Never silently lose characters: upgrade an ANSI file to UTF-8 if it can't hold the text.
    if ($EncodingName -eq 'ANSI' -and $Encoding.GetString($Encoding.GetBytes($out)) -ne $out) {
        $Encoding = New-Object Text.UTF8Encoding($false); $EncodingName = 'UTF-8'
    }
    $tmp = "$Path.dn-tmp"
    try {
        [IO.File]::WriteAllText($tmp, $out, $Encoding)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{ Encoding = $Encoding; EncodingName = $EncodingName }
}

# When dot-sourced (by the test suite) stop here: functions are loaded, no UI is started.
if ($MyInvocation.InvocationName -eq '.') { return }

# ---------------------------------------------------------------------------
# Startup: WinForms needs an STA thread. Relaunch hidden if started from an MTA console.
# ---------------------------------------------------------------------------
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argList = @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Path) { $argList += @('-Path', "`"$Path`"") }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argList
    return
}

[void][Native]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Palette, scaling, settings
# ---------------------------------------------------------------------------
$BG    = [Drawing.Color]::FromArgb(30, 30, 30)
$Bar   = [Drawing.Color]::FromArgb(43, 43, 43)
$Fore  = [Drawing.Color]::FromArgb(235, 235, 235)
$Mute  = [Drawing.Color]::FromArgb(160, 160, 160)
$Btn   = [Drawing.Color]::FromArgb(70, 70, 70)
$Line  = [Drawing.Color]::FromArgb(80, 80, 80)

$script:dpi = 1.0
$tmpG = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:dpi = $tmpG.DpiX / 96.0; $tmpG.Dispose()
function ConvertTo-Scaled([int]$n) { [int][Math]::Round($n * $script:dpi) }

$settingsFile = Join-Path $env:APPDATA 'DarkNotepad\settings.json'
function Get-AppSetting {
    try { if (Test-Path $settingsFile) { return Get-Content $settingsFile -Raw | ConvertFrom-Json } } catch { Write-Verbose "settings unreadable: $_" }
    $null
}
function Save-AppSetting {
    try {
        $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
        $s = [ordered]@{
            X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height
            Maximized = ($form.WindowState -eq 'Maximized')
            FontName = $box.Font.Name; FontSize = $box.Font.Size; FontStyle = [int]$box.Font.Style
            Wrap = $box.WordWrap; StatusBar = $status.Visible; Zoom = $box.ZoomFactor
        }
        New-Item -ItemType Directory -Force (Split-Path $settingsFile) | Out-Null
        $s | ConvertTo-Json | Set-Content $settingsFile -Encoding UTF8
    } catch { Write-Verbose "settings not saved: $_" }
}

# ---------------------------------------------------------------------------
# Document state
# ---------------------------------------------------------------------------
$script:file = $null
$script:dirty = $false
$script:loading = $false
$script:enc = New-Object Text.UTF8Encoding($false)
$script:encName = 'UTF-8'
$script:newLine = "`r`n"

function New-AppIcon {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.TextRenderingHint = 'AntiAlias'
    $g.Clear([Drawing.Color]::FromArgb(30, 30, 30))
    $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(232, 17, 35))), 0, 0, 32, 8)
    $f = New-Object Drawing.Font('Consolas', 12, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $g.DrawString('Dn', $f, [Drawing.Brushes]::White, 2, 11)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------
$form = New-Object Windows.Forms.Form
$form.Size = New-Object Drawing.Size((ConvertTo-Scaled 900), (ConvertTo-Scaled 650))
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Bar; $form.ForeColor = $Fore
$form.Icon = New-AppIcon
$form.KeyPreview = $true

$box = New-Object Windows.Forms.RichTextBox
$box.Dock = 'Fill'; $box.BorderStyle = 'None'; $box.AcceptsTab = $true
$box.BackColor = $BG; $box.ForeColor = $Fore
$box.Font = New-Object Drawing.Font('Consolas', 12)
$box.WordWrap = $false; $box.DetectUrls = $false; $box.ScrollBars = 'Both'
$box.HideSelection = $false          # keep the selection visible while Find is focused
$box.EnableAutoDragDrop = $true; $box.AllowDrop = $true
$box.RichTextShortcutsEnabled = $false
$box.Margin = New-Object Windows.Forms.Padding(0)

# Status bar: position | length | encoding | line ending | zoom
$status = New-Object Windows.Forms.StatusStrip
$status.BackColor = $Bar; $status.ForeColor = $Fore; $status.RenderMode = 'Professional'; $status.SizingGrip = $false
function New-StatusLabel([int]$Width, [bool]$Spring) {
    $l = New-Object Windows.Forms.ToolStripStatusLabel
    $l.ForeColor = $Fore; $l.TextAlign = 'MiddleLeft'
    if ($Spring) { $l.Spring = $true } else { $l.AutoSize = $false; $l.Width = ConvertTo-Scaled $Width }
    [void]$status.Items.Add($l); $l
}
$lblPos  = New-StatusLabel 0 $true
$lblLen  = New-StatusLabel 110 $false
$lblEnc  = New-StatusLabel 120 $false
$lblEol  = New-StatusLabel 120 $false
$lblZoom = New-StatusLabel 55 $false

$menu = New-Object Windows.Forms.MenuStrip
$menu.BackColor = $Bar; $menu.ForeColor = $Fore
$renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer((New-Object DarkColors))
$menu.Renderer = $renderer; $status.Renderer = $renderer

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
function New-MenuEntry($text, $keys, $action, $display) {
    $i = New-Object Windows.Forms.ToolStripMenuItem($text)
    $i.ForeColor = $Fore; $i.BackColor = $Bar
    if ($keys) { $i.ShortcutKeys = $keys }
    if ($display) { $i.ShortcutKeyDisplayString = $display }
    if ($action) { $i.Add_Click($action) }
    $i
}
function Add-MenuSeparator($m) { [void]$m.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator)) }
function New-TopMenu($text) { $t = New-Object Windows.Forms.ToolStripMenuItem($text); $t.ForeColor = $Fore; $t }

function New-DarkButton($text, $x, $y, $w) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point((ConvertTo-Scaled $x), (ConvertTo-Scaled $y))
    $b.Size = New-Object Drawing.Size((ConvertTo-Scaled $w), (ConvertTo-Scaled 27))
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = $Line; $b.BackColor = $Btn; $b.ForeColor = $Fore
    $b.UseVisualStyleBackColor = $false
    $b
}
function New-DarkText($x, $y, $w) {
    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point((ConvertTo-Scaled $x), (ConvertTo-Scaled $y))
    $t.Width = ConvertTo-Scaled $w
    $t.BackColor = $BG; $t.ForeColor = $Fore; $t.BorderStyle = 'FixedSingle'
    $t
}
function New-DarkLabel($text, $x, $y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true; $l.ForeColor = $Fore
    $l.Location = New-Object Drawing.Point((ConvertTo-Scaled $x), (ConvertTo-Scaled ($y + 3)))
    $l
}
function New-DarkDialog($title, $w, $h) {
    $f = New-Object Windows.Forms.Form
    $f.Text = $title; $f.ClientSize = New-Object Drawing.Size((ConvertTo-Scaled $w), (ConvertTo-Scaled $h))
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.StartPosition = 'CenterParent'; $f.BackColor = $Bar; $f.ForeColor = $Fore; $f.Icon = $form.Icon
    $f
}
function Show-Message($text, $icon = 'Information', $owner = $form) {
    [void][Windows.Forms.MessageBox]::Show($owner, $text, $script:appName, 'OK', $icon)
}

# ---------------------------------------------------------------------------
# Document logic
# ---------------------------------------------------------------------------
function Update-Title {
    $n = if ($script:file) { Split-Path $script:file -Leaf } else { 'Untitled' }
    $form.Text = "$(if ($script:dirty) { '*' })$n - $script:appName"
}

function Update-Status {
    $pos = $box.SelectionStart
    if ($box.WordWrap) {            # native line index is *visual* when wrapping, so count real lines
        $ln = 0; $col = 0
        [TextUtil]::LineCol($box.Text, $pos, [ref]$ln, [ref]$col)
    } else {
        $ln = $box.GetLineFromCharIndex($pos) + 1
        $col = $pos - $box.GetFirstCharIndexFromLine($ln - 1) + 1
    }
    $lblPos.Text  = "  Ln $ln, Col $col"
    $lblLen.Text  = '{0:N0} chars' -f $box.TextLength
    $lblEnc.Text  = $script:encName
    $lblEol.Text  = Get-NewLineName $script:newLine
    $lblZoom.Text = '{0}%' -f [int][Math]::Round($box.ZoomFactor * 100)
}

# Debounce status refreshes (typing / selection dragging fire many events per second).
$statusTimer = New-Object Windows.Forms.Timer
$statusTimer.Interval = 40
$statusTimer.Add_Tick({ $statusTimer.Stop(); Update-Status })
function Request-Status { $statusTimer.Stop(); $statusTimer.Start() }

function Set-Document([string]$text, $path, $encoding, [string]$encodingName, [string]$newLine) {
    $script:loading = $true
    try { $box.Text = $text; $box.ClearUndo() } finally { $script:loading = $false }
    $script:file = $path; $script:dirty = $false
    $script:enc = $encoding; $script:encName = $encodingName; $script:newLine = $newLine
    Update-Title; Update-Status
}

function Confirm-Save {
    if (-not $script:dirty) { return $true }
    $n = if ($script:file) { $script:file } else { 'Untitled' }
    $r = [Windows.Forms.MessageBox]::Show($form, "Do you want to save changes to $n?", $script:appName, 'YesNoCancel', 'Warning')
    if ($r -eq 'Cancel') { return $false }
    if ($r -eq 'Yes') { return (Save-File) }
    $true
}

function Save-To([string]$p) {
    try {
        $used = Save-FileData -Path $p -Text $box.Text -Encoding $script:enc -EncodingName $script:encName -NewLine $script:newLine
        $script:enc = $used.Encoding; $script:encName = $used.EncodingName
        $script:file = $p; $script:dirty = $false
        Update-Title; Update-Status
        $true
    } catch {
        Show-Message "Could not save the file:`n$($_.Exception.Message)" 'Error'
        $false
    }
}
function Invoke-SaveDialog {
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = 'Text Documents (*.txt)|*.txt|All Files (*.*)|*.*'; $d.OverwritePrompt = $true
    if ($script:file) { $d.FileName = Split-Path $script:file -Leaf; $d.InitialDirectory = Split-Path $script:file }
    if ($d.ShowDialog($form) -eq 'OK') { return (Save-To $d.FileName) }
    $false
}
function Save-File { if ($script:file) { Save-To $script:file } else { Invoke-SaveDialog } }

function Open-Path([string]$p) {
    try {
        $fd = Get-FileData -Path $p
        Set-Document $fd.Text (Resolve-Path -LiteralPath $p).ProviderPath $fd.Encoding $fd.EncodingName $fd.NewLine
    } catch {
        Show-Message "Could not open the file:`n$($_.Exception.Message)" 'Error'
    }
}
function Invoke-New {
    if (Confirm-Save) { Set-Document '' $null (New-Object Text.UTF8Encoding($false)) 'UTF-8' "`r`n" }
}
function Invoke-Open {
    if (-not (Confirm-Save)) { return }
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Filter = 'Text Documents (*.txt)|*.txt|All Files (*.*)|*.*'
    if ($d.ShowDialog($form) -eq 'OK') { Open-Path $d.FileName }
}

function Set-WordWrap([bool]$on) {
    $box.WordWrap = $on; $script:miWrap.Checked = $on; Update-Status
}
function Set-Zoom([double]$z) {
    $box.ZoomFactor = [Math]::Max(0.5, [Math]::Min(5.0, [Math]::Round($z, 1))); Update-Status
}
function Add-PlainText([string]$t) { $box.SelectedText = $t }

# ---------------------------------------------------------------------------
# Find / Replace / Go To
# ---------------------------------------------------------------------------
$script:fd = $null
function New-FindDialog {
    $f = New-DarkDialog 'Find' 430 140
    $d = @{ Form = $f }
    $d.LblQ = New-DarkLabel 'Find what:' 12 12
    $d.Q    = New-DarkText 105 12 200
    $d.LblR = New-DarkLabel 'Replace with:' 12 44
    $d.R    = New-DarkText 105 44 200
    $d.Case = New-Object Windows.Forms.CheckBox
    $d.Case.Text = 'Match case'; $d.Case.AutoSize = $true; $d.Case.ForeColor = $Fore
    $d.Wrap = New-Object Windows.Forms.CheckBox
    $d.Wrap.Text = 'Wrap around'; $d.Wrap.AutoSize = $true; $d.Wrap.ForeColor = $Fore; $d.Wrap.Checked = $true
    $d.Next  = New-DarkButton 'Find Next'   318 10 100
    $d.Rep   = New-DarkButton 'Replace'     318 42 100
    $d.All   = New-DarkButton 'Replace All' 318 74 100
    $d.Close = New-DarkButton 'Close'       318 106 100
    $f.Controls.AddRange(@($d.LblQ, $d.Q, $d.LblR, $d.R, $d.Case, $d.Wrap, $d.Next, $d.Rep, $d.All, $d.Close))
    $f.AcceptButton = $d.Next; $f.CancelButton = $d.Close
    $d.Close.Add_Click({ $script:fd.Form.Hide() })
    $f.Add_FormClosing({ if ($_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $script:fd.Form.Hide() } })
    $d.Next.Add_Click({ [void](Find-Next) })
    $d.Rep.Add_Click({ Invoke-Replace })
    $d.All.Add_Click({ Invoke-ReplaceAll })
    $d
}
function Set-FindMode([bool]$replace) {
    $d = $script:fd
    $d.LblR.Visible = $replace; $d.R.Visible = $replace; $d.Rep.Visible = $replace; $d.All.Visible = $replace
    $y = if ($replace) { 78 } else { 46 }
    $d.Case.Location = New-Object Drawing.Point((ConvertTo-Scaled 12), (ConvertTo-Scaled $y))
    $d.Wrap.Location = New-Object Drawing.Point((ConvertTo-Scaled 12), (ConvertTo-Scaled ($y + 24)))
    $d.Close.Location = New-Object Drawing.Point((ConvertTo-Scaled 318), (ConvertTo-Scaled $(if ($replace) { 106 } else { 42 })))
    $d.Form.ClientSize = New-Object Drawing.Size((ConvertTo-Scaled 430), (ConvertTo-Scaled $(if ($replace) { 142 } else { 110 })))
    $d.Form.Text = if ($replace) { 'Replace' } else { 'Find' }
}
function Show-Find([bool]$replace) {
    if (-not $script:fd) { $script:fd = New-FindDialog }
    Set-FindMode $replace
    $sel = $box.SelectedText
    if ($sel -and $sel.IndexOf("`n") -lt 0) { $script:fd.Q.Text = $sel }
    if (-not $script:fd.Form.Visible) {
        $dlg = $script:fd.Form
        $dlg.StartPosition = 'Manual'
        $dlg.Location = New-Object Drawing.Point(([int]($form.Left + ($form.Width - $dlg.Width) / 2)), ($form.Top + (ConvertTo-Scaled 90)))
        $dlg.Show($form)
    }
    $script:fd.Form.Activate(); $script:fd.Q.Focus(); $script:fd.Q.SelectAll()
}
function Get-Comparison { if ($script:fd -and $script:fd.Case.Checked) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase } }
function Find-Next {
    if (-not $script:fd -or -not $script:fd.Q.Text) { Show-Find $false; return $false }
    $q = $script:fd.Q.Text; $cmp = Get-Comparison
    $t = $box.Text; $start = [Math]::Min($box.SelectionStart + $box.SelectionLength, $t.Length)
    $i = $t.IndexOf($q, $start, $cmp)
    if ($i -lt 0 -and $script:fd.Wrap.Checked) { $i = $t.IndexOf($q, 0, $cmp) }
    if ($i -lt 0) { Show-Message "Cannot find `"$q`"" 'Information' $script:fd.Form; return $false }
    $box.Select($i, $q.Length); $box.ScrollToCaret()
    $true
}
function Invoke-Replace {
    $q = $script:fd.Q.Text
    if ($q -and $box.SelectedText.Equals($q, (Get-Comparison))) { $box.SelectedText = $script:fd.R.Text }
    [void](Find-Next)
}
function Invoke-ReplaceAll {
    $q = $script:fd.Q.Text
    if (-not $q) { return }
    $opts = if ($script:fd.Case.Checked) { 'None' } else { 'IgnoreCase' }
    $re = New-Object Text.RegularExpressions.Regex([Text.RegularExpressions.Regex]::Escape($q), $opts)
    $t = $box.Text
    $count = $re.Matches($t).Count
    if ($count -gt 0) {
        $rep = $script:fd.R.Text
        $new = $re.Replace($t, { $rep })           # literal replacement: no $1 expansion
        $box.SelectAll(); $box.SelectedText = $new           # single undoable edit
        $box.Select(0, 0); $box.ScrollToCaret()
    }
    Show-Message "$count replacement$(if ($count -ne 1) { 's' }) made." 'Information' $script:fd.Form
}
function Show-GoTo {
    $total = [TextUtil]::LineCount($box.Text)
    $ln = 0; $col = 0
    [TextUtil]::LineCol($box.Text, $box.SelectionStart, [ref]$ln, [ref]$col)
    $d = New-DarkDialog 'Go To Line' 280 110
    $lbl = New-DarkLabel "Line number (1-$total):" 12 14
    $tb = New-DarkText 12 40 250; $tb.Text = "$ln"
    $ok = New-DarkButton 'Go To' 100 72 80; $cancel = New-DarkButton 'Cancel' 184 72 80
    $d.Controls.AddRange(@($lbl, $tb, $ok, $cancel)); $d.AcceptButton = $ok; $d.CancelButton = $cancel
    $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
    $d.Add_Shown({ $tb.Focus(); $tb.SelectAll() })
    if ($d.ShowDialog($form) -eq 'OK') {
        $n = 0
        if ([int]::TryParse($tb.Text.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $total) {
            $box.Select([TextUtil]::LineStart($box.Text, $n), 0); $box.ScrollToCaret(); $box.Focus()
        } else {
            Show-Message "The line number must be between 1 and $total."
        }
    }
    $d.Dispose()
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
$mFile = New-TopMenu '&File'
$mFile.DropDownItems.AddRange(@(
    (New-MenuEntry '&New' 'Control, N' { Invoke-New }),
    (New-MenuEntry '&Open...' 'Control, O' { Invoke-Open }),
    (New-MenuEntry '&Save' 'Control, S' { [void](Save-File) }),
    (New-MenuEntry 'Save &As...' 'Control, Shift, S' { [void](Invoke-SaveDialog) })
))
Add-MenuSeparator $mFile
$mFile.DropDownItems.Add((New-MenuEntry 'E&xit' $null { $form.Close() })) | Out-Null

$script:miUndo = New-MenuEntry '&Undo' 'Control, Z' { $box.Undo() }
$script:miRedo = New-MenuEntry '&Redo' 'Control, Y' { $box.Redo() }
$script:miCut  = New-MenuEntry 'Cu&t' 'Control, X' { $box.Cut() }
$script:miCopy = New-MenuEntry '&Copy' 'Control, C' { $box.Copy() }
$script:miPaste = New-MenuEntry '&Paste' 'Control, V' { if ([Windows.Forms.Clipboard]::ContainsText()) { Add-PlainText ([Windows.Forms.Clipboard]::GetText()) } }
$script:miDel  = New-MenuEntry '&Delete' $null { if ($box.SelectionLength -gt 0) { $box.SelectedText = '' } } 'Del'
$mEdit = New-TopMenu '&Edit'
$mEdit.DropDownItems.AddRange(@($script:miUndo, $script:miRedo))
Add-MenuSeparator $mEdit
$mEdit.DropDownItems.AddRange(@($script:miCut, $script:miCopy, $script:miPaste, $script:miDel))
Add-MenuSeparator $mEdit
$mEdit.DropDownItems.AddRange(@(
    (New-MenuEntry '&Find...' 'Control, F' { Show-Find $false }),
    (New-MenuEntry 'Find &Next' 'F3' { [void](Find-Next) }),
    (New-MenuEntry '&Replace...' 'Control, H' { Show-Find $true }),
    (New-MenuEntry '&Go To...' 'Control, G' { Show-GoTo })
))
Add-MenuSeparator $mEdit
$mEdit.DropDownItems.AddRange(@(
    (New-MenuEntry 'Select &All' 'Control, A' { $box.SelectAll() }),
    (New-MenuEntry 'Time/&Date' 'F5' { $now = Get-Date; Add-PlainText ("{0} {1}" -f $now.ToString('t'), $now.ToString('d')) })
))
$mEdit.Add_DropDownOpening({
    $sel = $box.SelectionLength -gt 0
    $script:miUndo.Enabled = $box.CanUndo; $script:miRedo.Enabled = $box.CanRedo
    $script:miCut.Enabled = $sel; $script:miCopy.Enabled = $sel; $script:miDel.Enabled = $sel
    $script:miPaste.Enabled = [Windows.Forms.Clipboard]::ContainsText()
})

$script:miWrap = New-MenuEntry '&Word Wrap' $null $null
$script:miWrap.CheckOnClick = $true
$script:miWrap.Add_Click({ Set-WordWrap $script:miWrap.Checked })
$mFmt = New-TopMenu 'F&ormat'
$mFmt.DropDownItems.Add($script:miWrap) | Out-Null
$mFmt.DropDownItems.Add((New-MenuEntry '&Font...' $null {
    $d = New-Object Windows.Forms.FontDialog; $d.Font = $box.Font; $d.FontMustExist = $true
    if ($d.ShowDialog($form) -eq 'OK') { $box.Font = $d.Font }
})) | Out-Null

$script:miStatus = New-MenuEntry '&Status Bar' $null $null
$script:miStatus.CheckOnClick = $true; $script:miStatus.Checked = $true
$script:miStatus.Add_Click({ $status.Visible = $script:miStatus.Checked })
$mView = New-TopMenu '&View'
$mView.DropDownItems.Add($script:miStatus) | Out-Null
$mView.DropDownItems.Add((New-MenuEntry 'Zoom &In'  'Control, Oemplus'  { Set-Zoom ($box.ZoomFactor + 0.1) } 'Ctrl+Plus')) | Out-Null
$mView.DropDownItems.Add((New-MenuEntry 'Zoom &Out' 'Control, OemMinus' { Set-Zoom ($box.ZoomFactor - 0.1) } 'Ctrl+Minus')) | Out-Null
$mView.DropDownItems.Add((New-MenuEntry 'Restore Default &Zoom' 'Control, D0' { Set-Zoom 1.0 } 'Ctrl+0')) | Out-Null

$mHelp = New-TopMenu '&Help'
$mHelp.DropDownItems.Add((New-MenuEntry '&About Dark Notepad' $null {
    Show-Message "Dark Notepad v$script:version`nMIT License`nhttps://github.com/248Tech/DarkNotepad"
})) | Out-Null

$menu.Items.AddRange(@($mFile, $mEdit, $mFmt, $mView, $mHelp))
foreach ($m in $menu.Items) { foreach ($i in $m.DropDownItems) { $i.ForeColor = $Fore } }

# Right-click menu (plain-text paste, dark)
$ctx = New-Object Windows.Forms.ContextMenuStrip
$ctx.Renderer = $renderer; $ctx.BackColor = $Bar; $ctx.ForeColor = $Fore
$cUndo = New-MenuEntry 'Undo' $null { $box.Undo() }
$cCut = New-MenuEntry 'Cut' $null { $box.Cut() }
$cCopy = New-MenuEntry 'Copy' $null { $box.Copy() }
$cPaste = New-MenuEntry 'Paste' $null { if ([Windows.Forms.Clipboard]::ContainsText()) { Add-PlainText ([Windows.Forms.Clipboard]::GetText()) } }
$cAll = New-MenuEntry 'Select All' $null { $box.SelectAll() }
$ctx.Items.AddRange(@($cUndo, (New-Object Windows.Forms.ToolStripSeparator), $cCut, $cCopy, $cPaste, (New-Object Windows.Forms.ToolStripSeparator), $cAll))
$ctx.Add_Opening({
    $sel = $box.SelectionLength -gt 0
    $cUndo.Enabled = $box.CanUndo; $cCut.Enabled = $sel; $cCopy.Enabled = $sel
    $cPaste.Enabled = [Windows.Forms.Clipboard]::ContainsText()
})
$box.ContextMenuStrip = $ctx

# ---------------------------------------------------------------------------
# Wire up
# ---------------------------------------------------------------------------
$form.Controls.Add($box); $form.Controls.Add($status); $form.Controls.Add($menu)
$form.MainMenuStrip = $menu
$box.BringToFront()

$box.Add_TextChanged({
    if (-not $script:loading -and -not $script:dirty) { $script:dirty = $true; Update-Title }
    Request-Status
})
$box.Add_SelectionChanged({ Request-Status })
$box.Add_MouseWheel({ Request-Status })      # Ctrl+wheel zoom updates the % label
$box.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$box.Add_DragDrop({
    if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $p = @($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop))[0]
        if ((Test-Path -LiteralPath $p -PathType Leaf) -and (Confirm-Save)) { Open-Path $p }
    }
})
$form.Add_FormClosing({ if (-not (Confirm-Save)) { $_.Cancel = $true } else { Save-AppSetting } })
$form.Add_Shown({ [void][Native]::SetWindowTheme($box.Handle, 'DarkMode_Explorer', $null); $box.Focus() })

# Restore remembered window/font settings (validated so a bad file can never break startup)
$s = Get-AppSetting
if ($s) {
    try {
        if ($s.FontName -and $s.FontSize -ge 6 -and $s.FontSize -le 72) {
            $box.Font = New-Object Drawing.Font([string]$s.FontName, [single]$s.FontSize, [Drawing.FontStyle][int]$s.FontStyle)
        }
        if ($s.Wrap) { Set-WordWrap $true }
        if ($s.StatusBar -eq $false) { $status.Visible = $false; $script:miStatus.Checked = $false }
        if ($s.Zoom) { $box.ZoomFactor = [Math]::Max(0.5, [Math]::Min(5.0, [double]$s.Zoom)) }
        $r = New-Object Drawing.Rectangle([int]$s.X, [int]$s.Y, [int]$s.W, [int]$s.H)
        $visible = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($r) }
        if ($visible -and $r.Width -ge 300 -and $r.Height -ge 200) {
            $form.StartPosition = 'Manual'; $form.Bounds = $r
        }
        if ($s.Maximized) { $form.WindowState = 'Maximized' }
    } catch { Write-Verbose "ignoring invalid settings: $_" }
}

if ($Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Open-Path $Path }
    else { Set-Document '' (Join-Path (Get-Location) $Path) (New-Object Text.UTF8Encoding($false)) 'UTF-8' "`r`n" }  # like Notepad: new file at that path
}
Update-Title; Update-Status
[void][Windows.Forms.Application]::Run($form)
