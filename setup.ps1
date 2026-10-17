<#
.SYNOPSIS
    opencode-voice setup script for Windows.

.DESCRIPTION
    Downloads and configures the OpenCode voice plugin with ElevenLabs v3 TTS:
      - Clones/updates the repository
      - Installs dependencies with bun
      - Prompts for your ElevenLabs API key
      - Registers the plugin in your OpenCode config

.EXAMPLE
    irm https://raw.githubusercontent.com/R44VC0RP/opencode-voice/main/setup.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

$RepoUrl    = 'https://github.com/R44VC0RP/opencode-voice.git'
$InstallDir = Join-Path $HOME 'dev\opencode-voice'
$SecretsDir = Join-Path $HOME '.config\opencode\secrets'
$KeyPath    = Join-Path $SecretsDir 'elevenlabs-key'
$ConfigFile = Join-Path $HOME '.config\opencode\opencode.json'

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

# Step 4: Update OpenCode config
Write-Host ''
Write-Host '  Step 4: Configuring OpenCode...'

# file:/// URL with forward slashes (works with drive letters on Windows)
$pluginPath = 'file:///' + ($InstallDir -replace '\\', '/')

if (Test-Path $ConfigFile) {
    $configRaw = Get-Content $ConfigFile -Raw

    if ($configRaw -match 'opencode-voice') {
        Write-Host '   Plugin already registered in config'
    } else {
        try {
            $config = $configRaw | ConvertFrom-Json

            if ($null -eq $config.plugin) {
                $config | Add-Member -MemberType NoteProperty -Name 'plugin' -Value @()
            }

            $config.plugin = @($config.plugin) + @($pluginPath)
            $config | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigFile -Encoding UTF8
            Write-Host '   Plugin added to config'
        } catch {
            Write-Host '   Could not update config automatically.' -ForegroundColor Yellow
            Write-Host '   Please manually add this to your opencode.json plugin array:'
            Write-Host "      `"$pluginPath`""
        }
    }
} else {
    # Create new config file
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ConfigFile) | Out-Null
    $newConfig = [ordered]@{
        '$schema' = 'https://opencode.ai/config.json'
        plugin    = @($pluginPath)
    }
    $newConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host '   Created new config with plugin'
}

# Done!
Write-Host ''
Write-Host '==========================================================='
Write-Host '                    Setup Complete!'
Write-Host '==========================================================='
Write-Host ''
Write-Host "  Plugin installed to: $InstallDir"
Write-Host "  API key stored in:   $KeyPath"
Write-Host "  Config file:         $ConfigFile"
Write-Host ''
Write-Host "  Restart OpenCode to use the 'speak' tool!"
Write-Host ''
Write-Host '   Example usage:'
Write-Host '   speak("[excited] Hello! [laughs] This is amazing!")'
Write-Host ''
