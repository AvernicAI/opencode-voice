<#
.SYNOPSIS
    opencode-voice setup script for Windows.

.DESCRIPTION
    Downloads and configures the OpenCode voice plugin with ElevenLabs v3 TTS:
      - Clones/updates the repository
      - Installs dependencies with bun
      - Prompts for your ElevenLabs API key
      - Registers the plugin in the active OpenCode config (opencode.jsonc)

.EXAMPLE
    irm https://raw.githubusercontent.com/AvernicAI/opencode-voice/main/setup.ps1 | iex

.NOTES
    To use an existing checkout instead of $HOME\dev\opencode-voice (for
    example B:\opencode-voice), set the directory before running the one-liner:

        $env:OPENCODE_VOICE_DIR = 'B:\opencode-voice'
        irm https://raw.githubusercontent.com/AvernicAI/opencode-voice/main/setup.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

$RepoUrl = 'https://github.com/AvernicAI/opencode-voice.git'

# Existing checkouts (e.g. another drive) can be targeted with OPENCODE_VOICE_DIR.
$InstallDir = if ($env:OPENCODE_VOICE_DIR -and $env:OPENCODE_VOICE_DIR.Trim()) {
    $env:OPENCODE_VOICE_DIR.Trim().TrimEnd('\', '/')
} else {
    Join-Path $HOME 'dev\opencode-voice'
}

$SecretsDir = Join-Path $HOME '.config\opencode\secrets'
$KeyPath    = Join-Path $SecretsDir 'elevenlabs-key'

# >>> BEGIN CONFIG HELPERS
# OpenCode's global config is JSONC (comments and trailing commas allowed).
# Round-tripping through ConvertFrom-Json would reject comments and rewrite
# the whole file, so these helpers make targeted text edits instead.
#
# Behavior mirrors OpenCode itself: opencode.jsonc is preferred over the
# legacy opencode.json, and a missing config file is created as
# opencode.jsonc. Plugin entries use the V2 "plugins" field (the V1
# "plugin" field is used as a fallback when that is the only key present).

# Build a mask marking which characters are code (1) vs inside a comment or
# JSON value string (0). Quoted keys keep mask 1 so key lookup can use it.
function Get-ConfigCodeMask {
    param([string]$Text)

    $mask = New-Object 'int[]' $Text.Length
    for ($i = 0; $i -lt $Text.Length; $i++) { $mask[$i] = 1 }

    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($c -eq '/' -and $n -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $mask[$i] = 0; $i++ }
            continue
        }
        if ($c -eq '/' -and $n -eq '*') {
            $mask[$i] = 0
            $mask[$i + 1] = 0
            $i += 2
            while ($i -lt $Text.Length) {
                if ($Text[$i] -eq '*' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '/') {
                    $mask[$i] = 0
                    $mask[$i + 1] = 0
                    $i += 2
                    break
                }
                $mask[$i] = 0
                $i++
            }
            continue
        }
        if ($c -eq '"') {
            $start = $i
            $i++
            while ($i -lt $Text.Length) {
                if ($Text[$i] -eq '\') {
                    $mask[$i] = 0
                    if ($i + 1 -lt $Text.Length) { $mask[$i + 1] = 0 }
                    $i += 2
                    continue
                }
                if ($Text[$i] -eq '"') { break }
                $i++
            }
            $end = [Math]::Min($i, $Text.Length - 1)

            # A string followed by a colon is a key (stays code); otherwise it
            # is a value string and gets masked.
            $j = $end + 1
            while ($j -lt $Text.Length -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
            $isKey = ($j -lt $Text.Length -and $Text[$j] -eq ':')
            if (-not $isKey) {
                for ($k = $start; $k -le $end; $k++) { $mask[$k] = 0 }
            }
            $i = $end + 1
            continue
        }
        $i++
    }
    return ,$mask
}

# Object/array nesting depth at Index, ignoring strings and comments.
# Root-level members of the config object are at braces=1, brackets=0.
function Get-NestingDepthAt {
    param([string]$Text, [int]$Index)

    $braces = 0
    $brackets = 0
    $inString = $false
    $inLine = $false
    $inBlock = $false
    $i = 0
    while ($i -lt $Index) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }
        if ($inString) {
            if ($c -eq '\') { $i += 2; continue }
            if ($c -eq '"') { $inString = $false }
            $i++
            continue
        }
        if ($inLine) {
            if ($c -eq "`n") { $inLine = $false }
            $i++
            continue
        }
        if ($inBlock) {
            if ($c -eq '*' -and $n -eq '/') { $inBlock = $false; $i += 2; continue }
            $i++
            continue
        }
        if ($c -eq '"') { $inString = $true; $i++; continue }
        if ($c -eq '/' -and $n -eq '/') { $inLine = $true; $i += 2; continue }
        if ($c -eq '/' -and $n -eq '*') { $inBlock = $true; $i += 2; continue }
        if ($c -eq '{') { $braces++ }
        elseif ($c -eq '}') { $braces-- }
        elseif ($c -eq '[') { $brackets++ }
        elseif ($c -eq ']') { $brackets-- }
        $i++
    }
    return @{ Braces = $braces; Brackets = $brackets }
}

# Find the index of a top-level property name: "Name" followed by ':'.
# Returns -1 when absent, inside comments/strings, or nested below the root.
function Find-JsonProperty {
    param([string]$Text, [int[]]$Mask, [string]$Name)

    $pattern = '"' + [regex]::Escape($Name) + '"\s*:'
    foreach ($m in ([regex]::Matches($Text, $pattern))) {
        if ($Mask[$m.Index] -ne 1) { continue }
        $depth = Get-NestingDepthAt -Text $Text -Index $m.Index
        if ($depth.Braces -eq 1 -and $depth.Brackets -eq 0) { return $m.Index }
    }
    return -1
}

# Find the matching closing delimiter for the opener at OpenIndex
# (skips JSON strings, // line comments and /* block comments).
function Find-MatchingDelimiter {
    param([string]$Text, [int]$OpenIndex, [string]$OpenChar, [string]$CloseChar)

    $depth = 0
    $inString = $false
    $inLine = $false
    $inBlock = $false
    $i = $OpenIndex
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inString) {
            if ($c -eq '\') { $i += 2; continue }
            if ($c -eq '"') { $inString = $false }
            $i++
            continue
        }
        if ($inLine) {
            if ($c -eq "`n") { $inLine = $false }
            $i++
            continue
        }
        if ($inBlock) {
            if ($c -eq '*' -and $n -eq '/') { $inBlock = $false; $i += 2; continue }
            $i++
            continue
        }
        if ($c -eq '"') { $inString = $true; $i++; continue }
        if ($c -eq '/' -and $n -eq '/') { $inLine = $true; $i += 2; continue }
        if ($c -eq '/' -and $n -eq '*') { $inBlock = $true; $i += 2; continue }
        if ($c -eq $OpenChar) {
            $depth++
        } elseif ($c -eq $CloseChar) {
            $depth--
            if ($depth -eq 0) { return $i }
        }
        $i++
    }
    return -1
}

# Locate the [...] span of the given property. Returns $null if the property
# is absent or its value is not an array.
function Find-JsonArraySpan {
    param([string]$Text, [int[]]$Mask, [string]$Name)

    $keyIdx = Find-JsonProperty -Text $Text -Mask $Mask -Name $Name
    if ($keyIdx -lt 0) { return $null }

    $i = $Text.IndexOf(':', $keyIdx) + 1
    while ($i -lt $Text.Length -and -not ($Mask[$i] -eq 1 -and $Text[$i] -eq '[')) { $i++ }
    if ($i -ge $Text.Length) { return $null }

    $end = Find-MatchingDelimiter -Text $Text -OpenIndex $i -OpenChar '[' -CloseChar ']'
    if ($end -lt 0) { return $null }
    return @{ Open = $i; Close = $end }
}

# Inspect array contents: bounds of the last top-level value, whether a comma
# follows it, and where the first value starts (for indentation).
function Get-ArrayInsertionInfo {
    param([string]$Text, [int]$Open, [int]$Close)

    $info = @{ HasValues = $false; CommaAfterLast = $false; LastValueEnd = -1; FirstValueStart = -1 }

    $inString = $false
    $inLine = $false
    $inBlock = $false
    $nest = 0
    $inValue = $false
    $i = $Open + 1
    while ($i -lt $Close) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inString) {
            if ($c -eq '\') { $i += 2; continue }
            if ($c -eq '"') {
                $inString = $false
                if ($nest -eq 0) {
                    $inValue = $false
                    $info.HasValues = $true
                    $info.CommaAfterLast = $false
                    $info.LastValueEnd = $i + 1
                }
            }
            $i++
            continue
        }
        if ($inLine) {
            if ($c -eq "`n") { $inLine = $false }
            $i++
            continue
        }
        if ($inBlock) {
            if ($c -eq '*' -and $n -eq '/') { $inBlock = $false; $i += 2; continue }
            $i++
            continue
        }
        if ($c -eq '"') {
            if ($nest -eq 0 -and -not $inValue) {
                $inValue = $true
                if ($info.FirstValueStart -lt 0) { $info.FirstValueStart = $i }
            }
            $inString = $true
            $i++
            continue
        }
        if ($c -eq '/' -and $n -eq '/') { $inLine = $true; $i += 2; continue }
        if ($c -eq '/' -and $n -eq '*') { $inBlock = $true; $i += 2; continue }
        if ($c -eq '{' -or $c -eq '[') {
            if ($nest -eq 0 -and -not $inValue) {
                $inValue = $true
                if ($info.FirstValueStart -lt 0) { $info.FirstValueStart = $i }
            }
            $nest++
            $i++
            continue
        }
        if ($c -eq '}' -or $c -eq ']') {
            $nest--
            if ($nest -le 0) {
                $nest = 0
                $inValue = $false
                $info.HasValues = $true
                $info.CommaAfterLast = $false
                $info.LastValueEnd = $i + 1
            }
            $i++
            continue
        }
        if ($c -eq ',' -and $nest -eq 0 -and -not $inValue -and $info.HasValues) {
            $info.CommaAfterLast = $true
            $i++
            continue
        }
        $i++
    }
    return $info
}

# Index of the start of the line containing $Index.
function Get-LineStart {
    param([string]$Text, [int]$Index)
    $nl = $Text.LastIndexOf("`n", $Index)
    if ($nl -lt 0) { return 0 }
    return $nl + 1
}

# Leading whitespace of the line containing $Index.
function Get-LineIndent {
    param([string]$Text, [int]$Index)
    $start = Get-LineStart -Text $Text -Index $Index
    $i = $start
    while ($i -lt $Text.Length -and ($Text[$i] -eq ' ' -or $Text[$i] -eq "`t")) { $i++ }
    return $Text.Substring($start, $i - $start)
}

function Get-Newline {
    param([string]$Text)
    if ($Text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

# Insert an entry string into the array spanning Open..Close, preserving
# comments, formatting and existing entries.
function Add-EntryToArray {
    param([string]$Text, [int]$Open, [int]$Close, [string]$Entry)

    $nl = Get-Newline -Text $Text
    $info = Get-ArrayInsertionInfo -Text $Text -Open $Open -Close $Close

    $lineOpen = Get-LineStart -Text $Text -Index $Open
    $lineClose = Get-LineStart -Text $Text -Index $Close

    if ($lineOpen -eq $lineClose) {
        # Array opens and closes on one line: single insert.
        $sep = ''
        if ($info.HasValues) { $sep = $(if ($info.CommaAfterLast) { ' ' } else { ', ' }) }
        return $Text.Insert($Close, $sep + $Entry)
    }

    # Multi-line: comma first (so later indexes stay valid), then the entry
    # line in front of the closing bracket.
    $result = $Text
    $commaPos = -1
    if ($info.HasValues -and -not $info.CommaAfterLast) {
        $commaPos = $info.LastValueEnd
        $result = $result.Insert($commaPos, ',')
    }

    $closeIndent = Get-LineIndent -Text $Text -Index $Close
    if ($info.HasValues) { $entryIndent = Get-LineIndent -Text $Text -Index $info.FirstValueStart }
    else { $entryIndent = $closeIndent + '  ' }

    $insertAt = $lineClose
    if ($commaPos -ge 0 -and $commaPos -lt $lineClose) { $insertAt = $lineClose + 1 }
    return $result.Insert($insertAt, $entryIndent + $Entry + $nl)
}

# Add a brand-new top-level array property to the root object.
# Returns $null when the root object cannot be identified.
function Add-RootProperty {
    param([string]$Text, [int[]]$Mask, [string]$Name, [string[]]$Entries)

    # Skip leading whitespace and comments to the root '{'
    $i = 0
    while ($i -lt $Text.Length -and -not ($Mask[$i] -eq 1 -and $Text[$i] -eq '{')) { $i++ }
    if ($i -ge $Text.Length) { return $null }

    $open = $i
    $close = Find-MatchingDelimiter -Text $Text -OpenIndex $open -OpenChar '{' -CloseChar '}'
    if ($close -lt 0) { return $null }

    $nl = Get-Newline -Text $Text
    $between = $Text.Substring($open + 1, $close - $open - 1)

    # Is the root object empty (only whitespace/comments)?
    $stripped = $between -replace '//[^\r\n]*', '' -replace '/\*[\s\S]*?\*/', ''
    $rootEmpty = ($stripped.Trim().Length -eq 0)

    $memberIndent = '  '
    if (-not $rootEmpty) {
        # Reuse the indentation of the first existing member: find the first
        # non-whitespace after '{' and take that line's indentation.
        $scan = $open + 1
        while ($scan -lt $close -and [char]::IsWhiteSpace($Text[$scan])) { $scan++ }
        if ($scan -lt $close) {
            $detected = Get-LineIndent -Text $Text -Index $scan
            if ($detected.Length -gt 0) { $memberIndent = $detected }
        }
    }
    $entryIndent = $memberIndent + '  '

    $entryLines = @($Entries | ForEach-Object { $entryIndent + $_ }) -join $nl
    $block = $nl + $memberIndent + '"' + $Name + '": [' + $nl + $entryLines + $nl + $memberIndent + ']'
    if (-not $rootEmpty) { $block += ',' }

    return $Text.Insert($open + 1, $block)
}

# Register the plugin in an OpenCode config file.
# Returns @{ Status = 'created'|'added'|'exists'|'exists-elsewhere'|'manual'
#            Detail = <key, path or reason> }
function Add-PluginToConfig {
    param([string]$Path, [string]$PluginUrl)

    $entryQuoted = '"' + ($PluginUrl -replace '\\', '\\' -replace '"', '\"') + '"'
    $nl = "`r`n"

    # Missing, empty or whitespace-only config: start fresh as a complete
    # opencode.jsonc (same as what OpenCode itself would create).
    $text = ''
    if (Test-Path -LiteralPath $Path) {
        $text = [System.IO.File]::ReadAllText($Path)
    }
    if ($text.Trim().Length -eq 0) {
        $content = '{' + $nl +
            '  "$schema": "https://opencode.ai/config.json",' + $nl +
            '  "plugins": [' + $nl +
            '    ' + $entryQuoted + $nl +
            '  ]' + $nl +
            '}' + $nl
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
        return @{ Status = 'created'; Detail = $Path }
    }

    # Already registered (same path)?
    if ($text.IndexOf($PluginUrl, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        return @{ Status = 'exists'; Detail = $PluginUrl }
    }

    # Registered under a different opencode-voice path? Do not add a second
    # entry - that would load the same plugin twice.
    $other = [regex]::Match($text, '"[^"]*opencode-voice[^"]*"')
    if ($other.Success) {
        return @{ Status = 'exists-elsewhere'; Detail = $other.Value.Trim('"') }
    }

    $mask = Get-ConfigCodeMask -Text $text

    # Preferred: the native V2 "plugins" array, then the legacy V1 "plugin".
    foreach ($name in @('plugins', 'plugin')) {
        $span = Find-JsonArraySpan -Text $text -Mask $mask -Name $name
        if ($null -ne $span) {
            $updated = Add-EntryToArray -Text $text -Open $span.Open -Close $span.Close -Entry $entryQuoted
            [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
            return @{ Status = 'added'; Detail = $name }
        }
        if ((Find-JsonProperty -Text $text -Mask $mask -Name $name) -ge 0) {
            # Key exists but is not an array - cannot edit safely.
            return @{ Status = 'manual'; Detail = "$name is present but is not an array" }
        }
    }

    # No plugins array yet - add the property to the root object.
    $updated = Add-RootProperty -Text $text -Mask $mask -Name 'plugins' -Entries @($entryQuoted)
    if ($null -eq $updated) {
        return @{ Status = 'manual'; Detail = 'root object not found' }
    }
    [System.IO.File]::WriteAllText($Path, $updated, (New-Object System.Text.UTF8Encoding($false)))
    return @{ Status = 'added'; Detail = 'plugins' }
}
# <<< END CONFIG HELPERS

Write-Host ''
Write-Host '==========================================================='
Write-Host '           opencode-voice Setup Script'
Write-Host '   ElevenLabs v3 TTS Plugin for OpenCode (Windows)'
Write-Host '==========================================================='
Write-Host ''

# Check for required tools
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '  Error: git is not installed' -ForegroundColor Red
    Write-Host '  Install it from: https://git-scm.com/download/win'
    exit 1
}

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host '  Error: bun is not installed' -ForegroundColor Red
    Write-Host '  Install it in PowerShell with:'
    Write-Host '    powershell -c "irm bun.sh/install | iex"'
    exit 1
}

# Step 1: Clone or update the repository
Write-Host '  Step 1: Installing plugin...'
if (Test-Path (Join-Path $InstallDir '.git')) {
    Write-Host '   Directory exists, pulling latest...'
    Push-Location $InstallDir
    git pull --quiet
    Pop-Location
} else {
    Write-Host '   Cloning repository...'
    $parentDir = Split-Path -Parent $InstallDir
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
    git clone --quiet $RepoUrl $InstallDir
}

# Step 2: Install dependencies
Write-Host '  Step 2: Installing dependencies...'
Push-Location $InstallDir
bun install --silent
Pop-Location

# Step 3: Get ElevenLabs API key
Write-Host ''
Write-Host '  Step 3: ElevenLabs API Key'
Write-Host '   Get your API key from: https://elevenlabs.io/app/settings/api-keys'
Write-Host ''

$skipKey = $false
if (Test-Path $KeyPath) {
    $existingKey = (Get-Content $KeyPath -Raw).Trim()
    if ($existingKey -and $existingKey -ne 'YOUR_ELEVENLABS_API_KEY_HERE') {
        Write-Host '   Found existing API key.'
        $keepKey = Read-Host '   Keep existing key? [Y/n]'
        if (-not $keepKey -or $keepKey -match '^[Yy]') {
            Write-Host '   Keeping existing key'
            $skipKey = $true
        }
    }
}

if (-not $skipKey) {
    $apiKey = Read-Host '   Enter your ElevenLabs API key'

    if (-not $apiKey) {
        Write-Host '   No key provided. You can add it later to:'
        Write-Host "      $KeyPath"
    } else {
        New-Item -ItemType Directory -Force -Path $SecretsDir | Out-Null
        Set-Content -Path $KeyPath -Value $apiKey -NoNewline
        Write-Host '   API key saved'
    }
}

# Step 4: Register the plugin in the active OpenCode config
Write-Host ''
Write-Host '  Step 4: Configuring OpenCode...'

# file:/// URL with forward slashes (works with drive letters on Windows)
$pluginUrl = 'file:///' + ($InstallDir -replace '\\', '/')

$configDir = Join-Path $HOME '.config\opencode'
$jsoncFile = Join-Path $configDir 'opencode.jsonc'
$jsonFile  = Join-Path $configDir 'opencode.json'

# OpenCode prefers opencode.jsonc over the legacy opencode.json and creates
# opencode.jsonc when no config exists yet.
$targetFile = if (Test-Path -LiteralPath $jsoncFile) { $jsoncFile }
              elseif (Test-Path -LiteralPath $jsonFile) { $jsonFile }
              else { $jsoncFile }

try {
    $result = Add-PluginToConfig -Path $targetFile -PluginUrl $pluginUrl
} catch {
    $result = @{ Status = 'manual'; Detail = $_.Exception.Message }
}

Write-Host "   Config file: $targetFile"

switch ($result.Status) {
    'created' {
        Write-Host '   Plugin registered in new config'
    }
    'added' {
        Write-Host "   Plugin added to config (array: $($result.Detail))"
    }
    'exists' {
        Write-Host '   Plugin already registered in config'
    }
    'exists-elsewhere' {
        Write-Host '   Plugin already registered at a different path:' -ForegroundColor Yellow
        Write-Host "      $($result.Detail)"
        Write-Host '   Remove that entry if this install replaced it.'
    }
    default {
        Write-Host '   Could not update config automatically.' -ForegroundColor Yellow
        if ($result.Detail) { Write-Host "   ($($result.Detail))" }
        Write-Host '   Please manually add this to the "plugins" array in'
        Write-Host "      $targetFile"
        Write-Host "      `"$pluginUrl`""
    }
}

# Done!
Write-Host ''
Write-Host '==========================================================='
Write-Host '                    Setup Complete!'
Write-Host '==========================================================='
Write-Host ''
Write-Host "  Plugin installed to: $InstallDir"
Write-Host "  API key stored in:   $KeyPath"
Write-Host "  Config file:         $targetFile"
Write-Host ''
Write-Host "  Restart OpenCode to load the 'speak' tool!"
Write-Host '  (if it is already running, run: opencode service restart)'
Write-Host ''
Write-Host '   Example usage:'
Write-Host '   speak("[excited] Hello! [laughs] This is amazing!")'
Write-Host ''
