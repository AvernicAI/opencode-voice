# Test harness for the JSONC config-registration helpers inside setup.ps1.
# Extracts the helper block, dot-sources it under Windows PowerShell 5.1 and
# runs scenario tests. Exit code 0 = all pass.
$ErrorActionPreference = 'Stop'

$repo      = Split-Path -Parent $PSScriptRoot
$workRoot  = Join-Path $env:LOCALAPPDATA 'Temp\opencode\cfgtests'
$bun       = Join-Path $env:USERPROFILE '.bun\bin\bun.exe'
$validator = Join-Path $PSScriptRoot 'jsonc-validate.ts'
$url       = 'file:///B:/opencode-voice'

if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

# --- extract and load the helpers -----------------------------------------
$setupText = [System.IO.File]::ReadAllText((Join-Path $repo 'setup.ps1'))
$match = [regex]::Match($setupText, '(?s)# >>> BEGIN CONFIG HELPERS.*?# <<< END CONFIG HELPERS')
if (-not $match.Success) { throw 'helper block markers not found in setup.ps1' }
$helperFile = Join-Path $workRoot 'helpers.ps1'
[System.IO.File]::WriteAllText($helperFile, $match.Value)
. $helperFile

# --- assertions ------------------------------------------------------------
$script:pass = 0
$script:fail = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message"
    } else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

function Assert-ValidJsonc {
    param([string]$File, [string]$Label)
    $out = & $bun $validator $File 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) "$Label is valid JSONC ($($out.Trim()))"
}

function New-Case {
    param([string]$Name, $Content)
    $dir = Join-Path $workRoot $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir 'opencode.jsonc'
    if ($null -ne $Content) {
        [System.IO.File]::WriteAllText($file, $Content, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $file
}

function Add-Entry {
    param([string]$File)
    return Add-PluginToConfig -Path $File -PluginUrl $url
}

Write-Host '== 1. missing config -> created =='
$f = New-Case 'fresh' $null
Assert (-not (Test-Path $f)) 'precondition: config file does not exist'
$r = Add-Entry $f
Assert ($r.Status -eq 'created') "status is created (got $($r.Status))"
Assert-ValidJsonc $f 'new config'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('"$schema"')) 'new config keeps $schema'
Assert ($t.Contains($url)) 'new config contains plugin url'

Write-Host '== 1b. existing but empty config -> created =='
$f = New-Case 'empty-file' ''
Assert (Test-Path $f) 'precondition: empty config file exists'
$r = Add-Entry $f
Assert ($r.Status -eq 'created') "status is created (got $($r.Status))"
Assert-ValidJsonc $f 'empty-file'
Assert ([System.IO.File]::ReadAllText($f).Contains($url)) 'url present in regenerated config'

Write-Host '== 2. jsonc with comments, no plugins key =='
$jsoncComments = @'
{
  // Active OpenCode config for BRODUER
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-5", // default model
  "mcp": {
    "servers": {
      "playwright": { "type": "local", "command": ["npx", "@playwright/mcp"] }
    }
  }
  /* trailing note */
}
'@
$f = New-Case 'comments' $jsoncComments
$r = Add-Entry $f
Assert ($r.Status -eq 'added' -and $r.Detail -eq 'plugins') "added via plugins (got $($r.Status)/$($r.Detail))"
Assert-ValidJsonc $f 'jsonc+comments'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('// Active OpenCode config for BRODUER')) 'line comment preserved'
Assert ($t.Contains('// default model')) 'trailing line comment preserved'
Assert ($t.Contains('/* trailing note */')) 'block comment preserved'
Assert ($t.Contains($url)) 'plugin url added'
Assert ($t.Contains('"playwright"')) 'mcp servers untouched'
$usesPlugins = [regex]::Matches($t, '(?m)^\s*"plugins"\s*:')
Assert ($usesPlugins.Count -eq 1) 'exactly one real plugins key at line start'

Write-Host '== 3. inline empty plugins array =='
$f = New-Case 'empty-inline' "{ `"plugins`": [] }"
$r = Add-Entry $f
Assert ($r.Status -eq 'added') "added (got $($r.Status))"
Assert ([System.IO.File]::ReadAllText($f).Contains('["' + $url + '"]')) 'array now holds exactly the url'
Assert-ValidJsonc $f 'empty-inline'

Write-Host '== 4. multiline array, two string entries (comma needed) =='
$multiline = @'
{
  "plugins": [
    "some-plugin",
    "@scope/other"
  ],
  "model": "x/y"
}
'@
$f = New-Case 'multiline' $multiline
$r = Add-Entry $f
Assert ($r.Status -eq 'added') "added (got $($r.Status))"
Assert-ValidJsonc $f 'multiline'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('"@scope/other",')) 'comma added after previous last entry'
Assert ($t.Contains($url)) 'url appended'
$idxOther = $t.IndexOf('"@scope/other"')
$idxUrl = $t.IndexOf($url)
Assert ($idxUrl -gt $idxOther) 'url comes after existing entries'
Assert ($t.Contains('"model": "x/y"')) 'sibling keys untouched'

Write-Host '== 5. object entry + trailing comma + comment inside array =='
$objects = @'
{
  "plugins": [
    "a-plugin",
    {
      "package": "./local",
      "options": { "enabled": true }
    }, // keep local enabled
  ],
  "tools": { "websearch": false }
}
'@
$f = New-Case 'objects' $objects
$r = Add-Entry $f
Assert ($r.Status -eq 'added') "added (got $($r.Status))"
Assert-ValidJsonc $f 'objects'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('// keep local enabled')) 'comment inside array preserved'
Assert ($t.Contains('"options": { "enabled": true }')) 'nested object untouched'
Assert ($t.Contains($url)) 'url appended after object entry'

Write-Host '== 6. legacy V1 plugin array only =='
$legacy = @'
{
  "plugin": [
    "legacy-plugin"
  ]
}
'@
$f = New-Case 'legacy' $legacy
$r = Add-Entry $f
Assert ($r.Status -eq 'added' -and $r.Detail -eq 'plugin') "added via legacy plugin (got $($r.Status)/$($r.Detail))"
Assert-ValidJsonc $f 'legacy'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('"legacy-plugin",')) 'comma added to legacy entry'
Assert ($t.Contains($url)) 'url added to legacy array'

Write-Host '== 7. both plugins and plugin keys -> uses plugins =='
$both = "{ `"plugins`": [`"a`"], `"plugin`": [`"b`"] }"
$f = New-Case 'both' $both
$r = Add-Entry $f
Assert ($r.Status -eq 'added' -and $r.Detail -eq 'plugins') "added to plugins (got $($r.Status)/$($r.Detail))"
Assert-ValidJsonc $f 'both'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('["a", "' + $url + '"]')) 'url in plugins array'
Assert ($t.Contains('"plugin": ["b"]')) 'legacy array untouched'

Write-Host '== 8. idempotent: second run changes nothing =='
$f = New-Case 'idempotent' $jsoncComments
$null = Add-Entry $f
$before = [System.IO.File]::ReadAllText($f)
$r = Add-Entry $f
$after = [System.IO.File]::ReadAllText($f)
Assert ($r.Status -eq 'exists') "second run reports exists (got $($r.Status))"
Assert ($before -eq $after) 'file bytes unchanged on second run'
Assert ([regex]::Matches($after, [regex]::Escape($url)).Count -eq 1) 'url appears exactly once'

Write-Host '== 9. registered under a different opencode-voice path =='
$otherPath = "{ `"plugins`": [`"file:///C:/Users/x/dev/opencode-voice`"] }"
$f = New-Case 'elsewhere' $otherPath
$before = [System.IO.File]::ReadAllText($f)
$r = Add-Entry $f
$after = [System.IO.File]::ReadAllText($f)
Assert ($r.Status -eq 'exists-elsewhere') "status exists-elsewhere (got $($r.Status))"
Assert ($r.Detail -eq 'file:///C:/Users/x/dev/opencode-voice') "detail is old path (got $($r.Detail))"
Assert ($before -eq $after) 'no second entry added'

Write-Host '== 10. strict JSON file stays strict-JSON valid =='
$strict = @'
{
  "model": "anthropic/claude-sonnet-4-5",
  "plugins": ["pkg-a"]
}
'@
$f = New-Case 'strict' $strict
$r = Add-Entry $f
Assert ($r.Status -eq 'added') "added (got $($r.Status))"
$parseOk = $true
try { $null = [System.IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $parseOk = $false }
Assert $parseOk 'result parses with strict ConvertFrom-Json (no comments/trailing commas introduced)'
Assert-ValidJsonc $f 'strict'

Write-Host '== 11. plugins key present but not an array -> manual, untouched =='
$notArray = "{ `"plugins`": `"oops`", `"model`": `"x/y`" }"
$f = New-Case 'notarray' $notArray
$before = [System.IO.File]::ReadAllText($f)
$r = Add-Entry $f
$after = [System.IO.File]::ReadAllText($f)
Assert ($r.Status -eq 'manual') "status manual (got $($r.Status))"
Assert ($before -eq $after) 'file untouched'

Write-Host '== 12. CRLF + 4-space indent, new root property =='
$crlf = ("{`n    `"`$schema`": `"https://opencode.ai/config.json`",`n    `"model`": `"x/y`"`n}" -replace "`n", "`r`n")
$f = New-Case 'crlf4' $crlf
$r = Add-Entry $f
Assert ($r.Status -eq 'added') "added (got $($r.Status))"
Assert-ValidJsonc $f 'crlf4'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains("`r`n    `"plugins`": [`r`n")) 'uses CRLF and detected 4-space indent'
Assert ($t.Contains($url)) 'url added'

Write-Host '== 13. commented-out plugins key is ignored =='
$commented = @'
{
  // "plugins": ["old-entry"],
  "model": "x/y"
}
'@
$f = New-Case 'commented-key' $commented
$r = Add-Entry $f
Assert ($r.Status -eq 'added' -and $r.Detail -eq 'plugins') "added at root (got $($r.Status)/$($r.Detail))"
Assert-ValidJsonc $f 'commented-key'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('// "plugins": ["old-entry"],')) 'commented line preserved verbatim'
Assert ($t.Contains($url)) 'url added to a real plugins array'
$realKeys = [regex]::Matches($t, '(?m)^\s*"plugins"\s*:')
Assert ($realKeys.Count -eq 1) 'exactly one real plugins key'

Write-Host '== 14. nested key with plugins-like name is not hijacked =='
$nested = @'
{
  "mcp": { "servers": { "plugins": [] } },
  "model": "x/y"
}
'@
$f = New-Case 'nested-name' $nested
$r = Add-Entry $f
Assert ($r.Status -eq 'added' -and $r.Detail -eq 'plugins') "added at root, not nested (got $($r.Status)/$($r.Detail))"
Assert-ValidJsonc $f 'nested-name'
$t = [System.IO.File]::ReadAllText($f)
Assert ($t.Contains('"servers": { "plugins": [] }')) 'nested array untouched'
Assert ([regex]::Matches($t, [regex]::Escape($url)).Count -eq 1) 'url appears once'

Write-Host '== 15. UTF-8 BOM input -> output parses =='
$bomFile = New-Case 'bom' $null
$bomText = "{`r`n  `"model`": `"x/y`"`r`n}`r`n"
[System.IO.File]::WriteAllText($bomFile, $bomText, (New-Object System.Text.UTF8Encoding($true)))
$r = Add-Entry $bomFile
Assert ($r.Status -eq 'added') "added to BOM file (got $($r.Status))"
Assert-ValidJsonc $bomFile 'bom'

Write-Host ''
Write-Host "passed=$script:pass failed=$script:fail"
if ($script:fail -gt 0) { exit 1 }
exit 0
