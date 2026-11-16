<#
.SYNOPSIS  Dependency-free test suite for Dark Notepad's file I/O and text helpers.
.EXAMPLE   powershell -NoProfile -File tests\Run-Tests.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console test runner')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test helper')]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\DarkNotepad.ps1')    # dot-sourced: loads functions only, no UI

$script:pass = 0; $script:fail = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:fail++; Write-Host "  FAIL  $Name`n        $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal($Actual, $Expected, [string]$What = 'value') {
    if ($Actual -cne $Expected) { throw "$What : expected [$Expected] but got [$Actual]" }
}

$dir = Join-Path ([IO.Path]::GetTempPath()) ("dn-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory $dir | Out-Null
function New-TestFile([string]$Name, [byte[]]$Bytes) { $p = Join-Path $dir $Name; [IO.File]::WriteAllBytes($p, $Bytes); $p }
$utf8 = New-Object Text.UTF8Encoding($false)

Write-Host 'Line endings'
Test-Case 'detects CRLF' { Assert-Equal ([TextUtil]::DetectNewLine("a`r`nb`r`nc")) "`r`n" }
Test-Case 'detects LF' { Assert-Equal ([TextUtil]::DetectNewLine("a`nb`nc")) "`n" }
Test-Case 'detects CR' { Assert-Equal ([TextUtil]::DetectNewLine("a`rb`rc")) "`r" }
Test-Case 'defaults to CRLF when there are no line breaks' { Assert-Equal ([TextUtil]::DetectNewLine('abc')) "`r`n" }
Test-Case 'majority wins on mixed endings' { Assert-Equal ([TextUtil]::DetectNewLine("a`nb`nc`r`nd")) "`n" }
Test-Case 'converts mixed endings to CRLF' { Assert-Equal ([TextUtil]::ConvertNewLines("a`nb`r`nc`rd", "`r`n")) "a`r`nb`r`nc`r`nd" }
Test-Case 'converts to LF' { Assert-Equal ([TextUtil]::ConvertNewLines("a`r`nb", "`n")) "a`nb" }

Write-Host 'Line/column helpers'
Test-Case 'LineCol at start' { $l = 0; $c = 0; [TextUtil]::LineCol("ab`ncd", 0, [ref]$l, [ref]$c); Assert-Equal "$l,$c" '1,1' }
Test-Case 'LineCol on second line' { $l = 0; $c = 0; [TextUtil]::LineCol("ab`ncd", 4, [ref]$l, [ref]$c); Assert-Equal "$l,$c" '2,2' }
Test-Case 'LineCol clamps past end' { $l = 0; $c = 0; [TextUtil]::LineCol("ab`ncd", 99, [ref]$l, [ref]$c); Assert-Equal "$l,$c" '2,3' }
Test-Case 'LineStart finds lines' { Assert-Equal ([TextUtil]::LineStart("ab`ncd`nef", 3)) 6 }
Test-Case 'LineStart returns -1 beyond the last line' { Assert-Equal ([TextUtil]::LineStart("ab`ncd", 5)) -1 }
Test-Case 'LineCount' { Assert-Equal ([TextUtil]::LineCount("a`nb`nc")) 3 }

Write-Host 'Reading files'
Test-Case 'plain UTF-8' {
    $f = Get-FileData (New-TestFile 'a.txt' $utf8.GetBytes("h$([char]0xE9)llo`r`nw"))
    Assert-Equal $f.EncodingName 'UTF-8'; Assert-Equal $f.NewLine "`r`n"; Assert-Equal $f.Text "h$([char]0xE9)llo`r`nw"
}
Test-Case 'UTF-8 with BOM' {
    $bytes = @(0xEF, 0xBB, 0xBF) + $utf8.GetBytes('hi')
    $f = Get-FileData (New-TestFile 'bom.txt' ([byte[]]$bytes))
    Assert-Equal $f.EncodingName 'UTF-8 with BOM'; Assert-Equal $f.Text 'hi'
}
Test-Case 'UTF-16 LE with BOM' {
    $bytes = @(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('hi')
    $f = Get-FileData (New-TestFile 'u16.txt' ([byte[]]$bytes))
    Assert-Equal $f.EncodingName 'UTF-16 LE'; Assert-Equal $f.Text 'hi'
}
Test-Case 'UTF-16 BE with BOM' {
    $bytes = @(0xFE, 0xFF) + [Text.Encoding]::BigEndianUnicode.GetBytes('hi')
    $f = Get-FileData (New-TestFile 'u16be.txt' ([byte[]]$bytes))
    Assert-Equal $f.EncodingName 'UTF-16 BE'; Assert-Equal $f.Text 'hi'
}
Test-Case 'invalid UTF-8 falls back to ANSI' {
    $f = Get-FileData (New-TestFile 'ansi.txt' ([byte[]](0x63, 0x61, 0x66, 0xE9)))
    Assert-Equal $f.EncodingName 'ANSI'; Assert-Equal $f.Text "caf$([char]0xE9)"
}
Test-Case 'empty file' {
    $f = Get-FileData (New-TestFile 'empty.txt' ([byte[]]@()))
    Assert-Equal $f.Text ''; Assert-Equal $f.NewLine "`r`n"
}

Write-Host 'Round trips'
foreach ($case in @(
        @{ Name = 'a-crlf.txt'; Bytes = $utf8.GetBytes("one`r`ntwo`r`n") },
        @{ Name = 'a-lf.txt'; Bytes = $utf8.GetBytes("one`ntwo`n") },
        @{ Name = 'a-bom.txt'; Bytes = [byte[]](@(0xEF, 0xBB, 0xBF) + $utf8.GetBytes("one`r`ntwo")) },
        @{ Name = 'a-u16.txt'; Bytes = [byte[]](@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes("one`r`ntwo")) },
        @{ Name = 'a-ansi.txt'; Bytes = [byte[]](0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A) })) {
    Test-Case "open+save is byte-identical: $($case.Name)" {
        $p = New-TestFile $case.Name $case.Bytes
        $f = Get-FileData $p
        # the editor hands back text with bare \n line endings, so simulate that
        $editorText = [TextUtil]::ConvertNewLines($f.Text, "`n")
        [void](Save-FileData -Path $p -Text $editorText -Encoding $f.Encoding -EncodingName $f.EncodingName -NewLine $f.NewLine)
        $after = [IO.File]::ReadAllBytes($p)
        Assert-Equal ($after -join ',') ($case.Bytes -join ',') 'file bytes'
    }
}
Test-Case 'ANSI file is upgraded to UTF-8 instead of losing characters' {
    $p = New-TestFile 'up.txt' ([byte[]](0x63, 0x61, 0x66, 0xE9))
    $f = Get-FileData $p
    $r = Save-FileData -Path $p -Text "caf$([char]0xE9) $([char]0x4E2D)" -Encoding $f.Encoding -EncodingName $f.EncodingName -NewLine "`r`n"
    Assert-Equal $r.EncodingName 'UTF-8'
    Assert-Equal ([IO.File]::ReadAllText($p, $utf8)) "caf$([char]0xE9) $([char]0x4E2D)"
}
Test-Case 'save creates a new file and leaves no temp file behind' {
    $p = Join-Path $dir 'new.txt'
    [void](Save-FileData -Path $p -Text "x`ny" -Encoding $utf8 -NewLine "`r`n")
    Assert-Equal ([IO.File]::ReadAllText($p)) "x`r`ny"
    Assert-Equal (Test-Path "$p.dn-tmp") $false 'temp file exists'
}

Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
