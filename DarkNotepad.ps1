<#
.SYNOPSIS
    Dark Notepad - a lightweight dark-mode Notepad clone for Windows.
.DESCRIPTION
    Light text on a dark gray background, dark menus and scrollbars, find, word wrap,
    zoom, font picker and a status bar. Pure PowerShell + WinForms: no install, no
    dependencies beyond Windows PowerShell 5.1.
.PARAMETER Path
    Optional file to open on launch.
.EXAMPLE
    .\DarkNotepad.ps1 notes.txt
.LINK
    https://github.com/248Tech/DarkNotepad
.NOTES
    License: MIT
#>
param([string]$Path)

$script:version = '1.0.0'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
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
public class DarkScroll {
    [System.Runtime.InteropServices.DllImport("uxtheme.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hWnd, string app, string idList);
}
'@

$BG   = [Drawing.Color]::FromArgb(30,30,30)
$Bar  = [Drawing.Color]::FromArgb(43,43,43)
$Fore = [Drawing.Color]::FromArgb(235,235,235)

$script:file = $null
$script:dirty = $false
$script:appName = 'Dark Notepad'

# ---- Form & controls ----
$form = New-Object Windows.Forms.Form
$form.Size = '900,650'; $form.StartPosition = 'CenterScreen'
$form.BackColor = $Bar; $form.ForeColor = $Fore

$box = New-Object Windows.Forms.RichTextBox
$box.Dock = 'Fill'; $box.BorderStyle = 'None'; $box.AcceptsTab = $true
$box.BackColor = $BG; $box.ForeColor = $Fore
$box.Font = New-Object Drawing.Font('Consolas', 12)
$box.WordWrap = $false; $box.DetectUrls = $false; $box.ScrollBars = 'Both'
$box.EnableAutoDragDrop = $true

$status = New-Object Windows.Forms.StatusStrip
$status.BackColor = $Bar; $status.ForeColor = $Fore; $status.RenderMode = 'Professional'
$lbl = New-Object Windows.Forms.ToolStripStatusLabel; $lbl.ForeColor = $Fore
[void]$status.Items.Add($lbl)

$menu = New-Object Windows.Forms.MenuStrip
$menu.BackColor = $Bar; $menu.ForeColor = $Fore
$menu.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer((New-Object DarkColors))
$status.Renderer = $menu.Renderer

function New-Item2($text, $keys, $action) {
    $i = New-Object Windows.Forms.ToolStripMenuItem($text)
    $i.ForeColor = $Fore; $i.BackColor = $Bar
    if ($keys) { $i.ShortcutKeys = $keys }
    if ($action) { $i.Add_Click($action) }
    $i
}
function Add-Sep($m) { $s = New-Object Windows.Forms.ToolStripSeparator; $m.DropDownItems.Add($s) | Out-Null }
function New-Top($text) { $t = New-Object Windows.Forms.ToolStripMenuItem($text); $t.ForeColor = $Fore; $t }

# ---- Helpers ----
function Update-Title {
    $n = if ($script:file) { Split-Path $script:file -Leaf } else { 'Untitled' }
    $form.Text = "$(if ($script:dirty) {'*'})$n - $script:appName"
}
function Update-Status {
    $pos = $box.SelectionStart
    $line = $box.GetLineFromCharIndex($pos)
    $col = $pos - $box.GetFirstCharIndexFromLine($line)
    $lbl.Text = "Ln $($line+1), Col $($col+1)    $($box.TextLength) chars"
}
function Confirm-Save {
    if (-not $script:dirty) { return $true }
    $n = if ($script:file) { $script:file } else { 'Untitled' }
    $r = [Windows.Forms.MessageBox]::Show("Do you want to save changes to $n?", $script:appName, 'YesNoCancel', 'Warning')
    if ($r -eq 'Cancel') { return $false }
    if ($r -eq 'Yes') { return (Save-File) }
    $true
}
function Save-To($p) {
    [IO.File]::WriteAllText($p, $box.Text, (New-Object Text.UTF8Encoding($false)))
    $script:file = $p; $script:dirty = $false; Update-Title
}
function Save-As {
    $d = New-Object Windows.Forms.SaveFileDialog
    $d.Filter = 'Text Documents (*.txt)|*.txt|All Files (*.*)|*.*'
    if ($d.ShowDialog() -eq 'OK') { Save-To $d.FileName; return $true }
    $false
}
function Save-File { if ($script:file) { Save-To $script:file; $true } else { Save-As } }
function Open-Path($p) {
    $box.Text = [IO.File]::ReadAllText($p)
    $script:file = $p; $script:dirty = $false; Update-Title; Update-Status
}
function Show-Find {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Find'; $f.Size = '380,130'; $f.FormBorderStyle = 'FixedToolWindow'
    $f.StartPosition = 'CenterParent'; $f.BackColor = $Bar; $f.ForeColor = $Fore; $f.TopMost = $true
    $l = New-Object Windows.Forms.Label; $l.Text = 'Find what:'; $l.Location = '10,15'; $l.AutoSize = $true
    $t = New-Object Windows.Forms.TextBox; $t.Location = '80,12'; $t.Width = 190
    $t.BackColor = $BG; $t.ForeColor = $Fore; $t.BorderStyle = 'FixedSingle'; $t.Text = $box.SelectedText
    $b = New-Object Windows.Forms.Button; $b.Text = 'Find Next'; $b.Location = '280,10'; $b.Size = '75,26'
    $b.FlatStyle = 'Flat'; $b.BackColor = [Drawing.Color]::FromArgb(70,70,70); $b.ForeColor = $Fore
    $c = New-Object Windows.Forms.CheckBox; $c.Text = 'Match case'; $c.Location = '80,45'; $c.AutoSize = $true
    $b.Add_Click({
        if (-not $t.Text) { return }
        $cmp = if ($c.Checked) { 'Ordinal' } else { 'OrdinalIgnoreCase' }
        $i = $box.Text.IndexOf($t.Text, [Math]::Min($box.SelectionStart + $box.SelectionLength, $box.TextLength), [StringComparison]$cmp)
        if ($i -lt 0) { $i = $box.Text.IndexOf($t.Text, 0, [StringComparison]$cmp) }
        if ($i -ge 0) { $box.Select($i, $t.Text.Length); $box.ScrollToCaret() }
        else { [Windows.Forms.MessageBox]::Show("Cannot find `"$($t.Text)`"", 'Find') | Out-Null }
    }.GetNewClosure())
    $f.AcceptButton = $b
    $f.Controls.AddRange(@($l, $t, $b, $c)); $f.Show($form)
}

# ---- File menu ----
$mFile = New-Top '&File'
$mFile.DropDownItems.AddRange(@(
    (New-Item2 '&New' 'Control, N' { if (Confirm-Save) { $box.Clear(); $script:file = $null; $script:dirty = $false; Update-Title } }),
    (New-Item2 '&Open...' 'Control, O' {
        if (Confirm-Save) {
            $d = New-Object Windows.Forms.OpenFileDialog
            $d.Filter = 'Text Documents (*.txt)|*.txt|All Files (*.*)|*.*'
            if ($d.ShowDialog() -eq 'OK') { Open-Path $d.FileName }
        } }),
    (New-Item2 '&Save' 'Control, S' { Save-File | Out-Null }),
    (New-Item2 'Save &As...' 'Control, Shift, S' { Save-As | Out-Null })
))
Add-Sep $mFile
$mFile.DropDownItems.Add((New-Item2 'E&xit' $null { $form.Close() })) | Out-Null

# ---- Edit menu ----
$mEdit = New-Top '&Edit'
$mEdit.DropDownItems.AddRange(@(
    (New-Item2 '&Undo' 'Control, Z' { $box.Undo() }),
    (New-Item2 '&Redo' 'Control, Y' { $box.Redo() })
))
Add-Sep $mEdit
$mEdit.DropDownItems.AddRange(@(
    (New-Item2 'Cu&t' 'Control, X' { $box.Cut() }),
    (New-Item2 '&Copy' 'Control, C' { $box.Copy() }),
    (New-Item2 '&Paste' 'Control, V' { $box.Paste([Windows.Forms.DataFormats]::GetFormat('Text')) })
))
Add-Sep $mEdit
$mEdit.DropDownItems.AddRange(@(
    (New-Item2 '&Find...' 'Control, F' { Show-Find }),
    (New-Item2 'Select &All' 'Control, A' { $box.SelectAll() }),
    (New-Item2 'Time/&Date' 'F5' { $box.SelectedText = (Get-Date).ToString('h:mm tt M/d/yyyy') })
))

# ---- Format / View ----
$mFmt = New-Top 'F&ormat'
$wrap = New-Item2 '&Word Wrap' $null $null
$wrap.CheckOnClick = $true
$wrap.Add_Click({ $box.WordWrap = $wrap.Checked })
$mFmt.DropDownItems.Add($wrap) | Out-Null
$mFmt.DropDownItems.Add((New-Item2 '&Font...' $null {
    $d = New-Object Windows.Forms.FontDialog; $d.Font = $box.Font
    if ($d.ShowDialog() -eq 'OK') { $box.Font = $d.Font } })) | Out-Null

$mView = New-Top '&View'
$sb = New-Item2 '&Status Bar' $null $null
$sb.CheckOnClick = $true; $sb.Checked = $true
$sb.Add_Click({ $status.Visible = $sb.Checked })
$mView.DropDownItems.Add($sb) | Out-Null
$mView.DropDownItems.Add((New-Item2 'Zoom &In' 'Control, Oemplus' { $box.ZoomFactor = [Math]::Min(5, $box.ZoomFactor + 0.1) })) | Out-Null
$mView.DropDownItems.Add((New-Item2 'Zoom &Out' 'Control, OemMinus' { $box.ZoomFactor = [Math]::Max(0.5, $box.ZoomFactor - 0.1) })) | Out-Null

$mHelp = New-Top '&Help'
$mHelp.DropDownItems.Add((New-Item2 '&About Dark Notepad' $null {
    [Windows.Forms.MessageBox]::Show("Dark Notepad v$script:version`nMIT License`nhttps://github.com/248Tech/DarkNotepad", 'About', 'OK', 'Information') | Out-Null
})) | Out-Null

$menu.Items.AddRange(@($mFile, $mEdit, $mFmt, $mView, $mHelp))
foreach ($m in $menu.Items) { foreach ($i in $m.DropDownItems) { $i.ForeColor = $Fore } }

# ---- Wire up ----
$form.Controls.Add($box); $form.Controls.Add($status); $form.Controls.Add($menu)
$form.MainMenuStrip = $menu
$box.Add_TextChanged({ if (-not $script:dirty) { $script:dirty = $true; Update-Title }; Update-Status })
$box.Add_SelectionChanged({ Update-Status })
$form.Add_FormClosing({ if (-not (Confirm-Save)) { $_.Cancel = $true } })
$form.Add_Shown({ [void][DarkScroll]::SetWindowTheme($box.Handle, 'DarkMode_Explorer', $null) })

if ($Path -and (Test-Path $Path)) { Open-Path (Resolve-Path $Path).Path }
$script:dirty = $false
Update-Title; Update-Status
[void][Windows.Forms.Application]::Run($form)
