# OpenCode Voice Plugin - Agent Knowledge

## ElevenLabs v3 API

- Model ID is `eleven_v3` (not `eleven_v3_alpha` or `elevenlabs_v3`) - use in `model_id` field
- Audio tags must be lowercase in square brackets: `[whispers]` not `[Whispers]` or `[WHISPERS]`
- Output format `mp3_44100_128` is passed as query param, not in request body: `?output_format=mp3_44100_128`
- API returns raw binary audio stream, not JSON - use `response.arrayBuffer()` directly

## OpenCode Plugin Architecture

- Plugin entry point (`index.ts`) must export named export matching plugin name: `export { VoicePlugin }`
- `.ts` extension required in imports when using `allowImportingTsExtensions: true` in tsconfig
- API keys pattern: read from `~/.config/opencode/secrets/{service}-key` (not env vars for user plugins)
- `tool.schema` is Zod - use `.string()`, `.number()`, `.optional()` - NOT TypeScript types

## Audio Playback (Cross-Platform)

Playback is selected by `process.platform` in `src/plugin.ts` (`buildPlaybackCandidates`):
- Windows: `powershell.exe` with `-EncodedCommand` (base64 UTF-16LE); primary engine is WPF `MediaPlayer` (PresentationCore, ships with .NET Framework), fallback is WMPlayer.OCX COM (the legacy WMP engine hangs in Transitioning state on some Windows 11 Enterprise builds - that is why WPF is first)
- macOS: `afplay`
- Linux: `ffplay` fallback to `paplay` (candidates tried in order on spawn `error` event)

Key gotchas:
- CRITICAL: bun's `detached: true` spawn is broken on Windows - the child exits immediately (code 0) without ever running the command. On Windows spawn WITHOUT `detached` (plain spawn + `unref()` + `windowsHide` is already non-blocking there); keep `detached` for macOS/Linux
- `afplay` is non-blocking by default ONLY if spawned with `detached: true` and `child.unref()`
- Without `unref()`, parent process waits for audio completion even with `detached: true`
- Always spawn the Windows player with `windowsHide: true` to avoid a flashing console window
- Pass the PowerShell script via `-EncodedCommand` (never `-Command`) to avoid path/quoting bugs
- WPF `MediaPlayer`: wait for `NaturalDuration.HasTimeSpan` before trusting the duration, and never poll `Position` (it needs a WPF Dispatcher pump - just sleep for the duration instead)
- Volume scales: `afplay -v` is 0-255, WMP COM is 0-100, WPF MediaPlayer is 0.0-1.0 - but represent to users as 0-2 for intuitive control
- Temp file cleanup: attach to child process `exit` event, not `close` (more reliable); the Windows PowerShell script also deletes the temp file itself in a `finally` block

## Setup Script Best Practices

Two setup scripts must stay in sync: `setup.sh` (macOS/Linux) and `setup.ps1` (Windows)
- bash: use `set -e` to fail fast; PowerShell: use `$ErrorActionPreference = 'Stop'`
- Check for `jq` (bash) / `ConvertFrom-Json` errors (PowerShell) before attempting JSON manipulation - provide manual fallback
- Use `mkdir -p` (bash) / `New-Item -ItemType Directory -Force` (PowerShell) for secrets dir - may not exist on fresh OpenCode installs
- `chmod 600` on API key files for security on macOS/Linux (PowerShell: default ACLs are user-scoped)
- Git operations: use `--quiet` flag to reduce noise in setup scripts
- Plugin path in opencode.json is a file URL; on Windows use forward slashes: `file:///C:/Users/...`

## File Changes That Must Happen Together

- `setup.sh` AND `setup.ps1` and `README.md` all contain repo URL - update all when changing GitHub org/username
- When changing voice ID: `src/plugin.ts` VOICE_ID constant + README.md configuration section
