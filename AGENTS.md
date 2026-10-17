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

## Audio Playback (Windows Only)

This plugin is Windows-only. `src/plugin.ts` guards it with `assertWindows()` (called by `buildPlaybackCandidates` and at the start of `speak.execute`, so non-Windows hosts fail before spending an API call).

Playback command (`buildPlaybackCandidates`):
- `powershell.exe` with `-EncodedCommand` (base64 UTF-16LE); primary engine is WPF `MediaPlayer` (PresentationCore, ships with .NET Framework), fallback is WMPlayer.OCX COM (the legacy WMP engine hangs in Transitioning state on some Windows 11 Enterprise builds - that is why WPF is first)
- No macOS/Linux candidates remain (`afplay`/`ffplay`/`paplay` were removed) - do not reintroduce them

Key gotchas:
- CRITICAL: bun's `detached: true` spawn is broken on Windows - the child exits immediately (code 0) without ever running the command. Always spawn WITHOUT `detached` (plain spawn + `unref()` + `windowsHide` is already non-blocking there)
- Without `unref()`, parent process waits for audio completion
- Always spawn with `windowsHide: true` to avoid a flashing console window
- Pass the PowerShell script via `-EncodedCommand` (never `-Command`) to avoid path/quoting bugs
- WPF `MediaPlayer`: wait for `NaturalDuration.HasTimeSpan` before trusting the duration, and never poll `Position` (it needs a WPF Dispatcher pump - just sleep for the duration instead)
- Volume scales: WMP COM is 0-100, WPF MediaPlayer is 0.0-1.0 - but represent to users as 0-2 for intuitive control
- Temp file cleanup: attach to child process `exit` event, not `close` (more reliable); the PowerShell script also deletes the temp file itself when playback finishes

## Setup Script Best Practices

Single setup script: `setup.ps1` (Windows). `setup.sh` was removed with macOS/Linux support.
- PowerShell: use `$ErrorActionPreference = 'Stop'` to fail fast
- Check `ConvertFrom-Json` errors before attempting JSON manipulation - provide manual fallback
- Use `New-Item -ItemType Directory -Force` for the secrets dir - may not exist on fresh OpenCode installs
- API key file relies on default user-scoped ACLs (no `chmod` equivalent needed)
- Git operations: use `--quiet` flag to reduce noise in setup scripts
- Plugin path in opencode.json is a file URL; on Windows use forward slashes: `file:///C:/Users/...`

## File Changes That Must Happen Together

- `setup.ps1` and `README.md` both contain repo URL - update both when changing GitHub org/username
- When changing voice ID: `src/plugin.ts` VOICE_ID constant + README.md configuration section
- Windows-only scope is documented in `README.md`, `package.json` (description/keywords), and `AGENTS.md` - keep them consistent with `src/plugin.ts`
