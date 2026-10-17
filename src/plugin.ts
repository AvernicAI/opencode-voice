import { tool, type Plugin } from "@opencode-ai/plugin";
import { readFileSync, writeFileSync, unlinkSync } from "fs";
import { tmpdir, homedir } from "os";
import { join } from "path";
import { spawn } from "child_process";

/**
 * Voice ID for ElevenLabs TTS
 */
const VOICE_ID = "pNInz6obpgDQGcFmaJgB";

/**
 * ElevenLabs v3 model ID - most expressive with audio tag support
 */
const MODEL_ID = "eleven_v3";

/**
 * Path to the ElevenLabs API key secret file.
 * (~/.config/opencode is the config location OpenCode uses on Windows too).
 */
const API_KEY_PATH = join(
  homedir(),
  ".config",
  "opencode",
  "secrets",
  "elevenlabs-key"
);

/**
 * Load API key from secrets file
 */
function loadApiKey(): string {
  try {
    return readFileSync(API_KEY_PATH, "utf-8").trim();
  } catch (error) {
    throw new Error(
      `Failed to read ElevenLabs API key from ${API_KEY_PATH}. ` +
        `Please create this file with your API key.`
    );
  }
}

/**
 * Clamp a number between min and max
 */
function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

/**
 * This plugin only supports Windows - playback is implemented with the
 * built-in Windows media stack (WPF MediaPlayer + WMPlayer.OCX fallback).
 */
export function assertWindows(): void {
  if (process.platform !== "win32") {
    throw new Error(
      "opencode-voice is a Windows-only plugin: audio playback requires " +
        "PowerShell with the WPF MediaPlayer (PresentationCore). " +
        `Detected platform: ${process.platform}`
    );
  }
}

/**
 * Build the PowerShell script used to play an MP3 on Windows.
 *
 * Both engines are built into stock Windows 10/11 - no extra dependencies:
 *  1. WPF MediaPlayer (PresentationCore, ships with .NET Framework)
 *  2. Legacy Windows Media Player COM object (WMPlayer.OCX) as a fallback
 *
 * The script:
 *  - plays the file with the first engine that works on the machine
 *  - maps the 0-2 volume range to each engine's native scale
 *  - waits until playback finishes (guarded by watchdog timeouts)
 *  - always deletes the temp file when done
 */
export function buildWindowsPlaybackScript(filePath: string, volume: number): string {
  const escapedPath = filePath.replace(/'/g, "''");
  // 0-2 -> 0-1 (WPF MediaPlayer scale) and 0-100 (WMP COM scale)
  const wpfVolume = clamp(volume, 0, 2) / 2;
  const wmpVolume = Math.round(clamp(volume, 0, 2) * 50);

  return `
$ErrorActionPreference = 'Stop'
$path = '${escapedPath}'
$wpfVolume = [math]::Round(${wpfVolume}, 2)
$wmpVolume = ${wmpVolume}
$played = $false
$player = $null
$isCom = $false

# Engine 1: WPF MediaPlayer (PresentationCore, ships with .NET Framework)
try {
  Add-Type -AssemblyName PresentationCore
  $player = New-Object System.Windows.Media.MediaPlayer
  $player.Open([Uri]$path)
  $player.Volume = $wpfVolume
  $player.Play()

  # Wait until duration metadata is available (media fully opened)
  $started = Get-Date
  while (-not $player.NaturalDuration.HasTimeSpan) {
    if (((Get-Date) - $started).TotalSeconds -gt 15) {
      throw 'Timed out waiting for media metadata'
    }
    Start-Sleep -Milliseconds 100
  }

  # Wait for playback to finish (duration plus a small grace period)
  $duration = [double]$player.NaturalDuration.TimeSpan.TotalSeconds
  $remaining = ($duration + 1) - ((Get-Date) - $started).TotalSeconds
  if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
  $played = $true
} catch {
  if ($null -ne $player) { try { $player.Close() } catch { } }
  $player = $null
}

# Engine 2: legacy Windows Media Player COM object (WMPlayer.OCX)
if (-not $played) {
  try {
    $isCom = $true
    $player = New-Object -ComObject WMPlayer.OCX
    $player.settings.volume = $wmpVolume
    $player.URL = $path
    $player.controls.play()

    # Wait until duration metadata is available (media fully opened)
    $started = Get-Date
    while (-not $player.currentMedia -or $player.currentMedia.duration -le 0) {
      if (((Get-Date) - $started).TotalSeconds -gt 15) {
        throw 'Timed out waiting for media metadata'
      }
      Start-Sleep -Milliseconds 100
    }

    # Nudge playback if it has not started yet
    if ($player.playState -notin 3) {
      $player.controls.play()
    }

    # Wait for playback to finish (duration plus a small grace period)
    $limit = [double]$player.currentMedia.duration + 5
    while ($player.playState -in 3, 6, 7, 9) {
      if (((Get-Date) - $started).TotalSeconds -gt $limit) { break }
      Start-Sleep -Milliseconds 200
    }
    $played = $true
  } catch {
    if ($null -ne $player) { try { $player.close() } catch { } }
    $player = $null
  }
}

# Release the player and always delete the temp file (retry: media handles are
# released asynchronously, so the file can be locked for a moment)
if ($null -ne $player) {
  if ($isCom) {
    try { $player.controls.stop() } catch { }
    try { $player.close() } catch { }
    try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($player) } catch { }
  } else {
    try { $player.Close() } catch { }
  }
  $player = $null
}
for ($i = 0; $i -lt 10 -and (Test-Path -LiteralPath $path); $i++) {
  Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $path) { Start-Sleep -Milliseconds 200 }
}
if (-not $played) { exit 1 }
`.trim();
}

/**
 * Build the playback command for the current platform.
 *
 * Windows-only: a hidden PowerShell process plays the file using the built-in
 * engines (WPF MediaPlayer, falling back to the legacy WMP COM object).
 */
export function buildPlaybackCandidates(
  filePath: string,
  volume: number
): Array<{ command: string; args: string[] }> {
  assertWindows();

  const script = buildWindowsPlaybackScript(filePath, volume);
  // Base64 (UTF-16LE) encoded script avoids all path/quoting issues
  const encodedScript = Buffer.from(script, "utf16le").toString("base64");

  return [
    {
      command: "powershell.exe",
      args: [
        "-NoProfile",
        "-NonInteractive",
        "-WindowStyle",
        "Hidden",
        "-EncodedCommand",
        encodedScript,
      ],
    },
  ];
}

/**
 * Play an audio file in the background (non-blocking).
 *
 * A hidden PowerShell process plays the file via the built-in WPF
 * `MediaPlayer` (falling back to the legacy Windows Media Player COM object)
 * and removes the temp file when playback finishes.
 */
export function playAudio(filePath: string, volume: number): void {
  const cleanup = (): void => {
    try {
      unlinkSync(filePath);
    } catch {
      // Ignore cleanup errors (the player may have already removed the file)
    }
  };

  let candidates: Array<{ command: string; args: string[] }>;
  try {
    candidates = buildPlaybackCandidates(filePath, volume);
  } catch (error) {
    // Unsupported platform - clean up the temp file and surface the error
    cleanup();
    throw error;
  }

  const attempt = (index: number): void => {
    if (index >= candidates.length) {
      // No playable command found - clean up the temp file
      cleanup();
      return;
    }

    const { command, args } = candidates[index];

    let child;
    try {
      // On Windows, a plain spawn + unref() is already non-blocking and the
      // hidden window option prevents any console flash. `detached` is NOT
      // used: bun's detached spawn on Windows exits the child immediately
      // without ever running the command.
      child = spawn(command, args, {
        detached: false,
        stdio: "ignore",
        windowsHide: true,
      });
    } catch {
      // Spawn failed synchronously - try the next candidate
      attempt(index + 1);
      return;
    }

    // Command not installed - fall through to the next candidate
    child.on("error", () => {
      attempt(index + 1);
    });

    // Clean up the temp file once playback completes
    child.on("exit", () => {
      cleanup();
    });

    child.unref();
  };

  attempt(0);
}

/**
 * Audio tag categories for reference in tool description
 */
const AUDIO_TAG_EXAMPLES = `
Audio Tags (v3 expressive features):
  Emotions: [laughs], [sighs], [whispers], [excited], [sad], [angry], [happily], [sarcastic], [curious]
  Delivery: [whispers], [shouts], [dramatically], [calmly], [nervously]
  Reactions: [laughs], [laughs harder], [giggles], [clears throat], [sighs], [gasps], [gulps]
  Accents: [strong French accent], [British accent], [Southern US accent]
  Sound FX: [applause], [gunshot], [explosion]

Example: "[whispers] Something's coming... [sighs] I can feel it."
Example: "[excited] We did it! [laughs] I can't believe it worked!"
`;

/**
 * The speak tool definition
 */
const speakTool = tool({
  description: `Convert text to speech using ElevenLabs v3 and play it on the device speakers (non-blocking).

Uses the expressive v3 model which supports inline audio tags for emotional control, 
delivery direction, non-verbal reactions, accents, and sound effects.

Windows-only: audio plays through a hidden PowerShell process using the built-in
WPF MediaPlayer (falls back to the legacy Windows Media Player COM object).

${AUDIO_TAG_EXAMPLES}

The audio plays in the background and control returns immediately.

USAGE GUIDANCE:
- Use in SHORT BURSTS to notify the user of important state changes
- Good for: task completion, errors requiring attention, questions needing user input
- Keep messages concise (1-2 sentences) - don't read entire responses aloud
- Examples of when to use:
  * "[excited] Done! The build succeeded."
  * "[curious] I have a question - should I proceed with the refactor?"
  * "[sighs] I found 3 errors we need to fix."
  * "[whispers] Heads up - I'm about to make a breaking change."`,

  args: {
    text: tool.schema
      .string()
      .describe(
        "The text to convert to speech. Can include audio tags like [laughs], [whispers], [excited], etc."
      ),

    stability: tool.schema
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe(
        "Voice stability (0-1). Lower = more expressive/emotional range, higher = more consistent. Default: 0.5"
      ),

    similarity_boost: tool.schema
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe(
        "How closely to match the original voice (0-1). Default: 0.75"
      ),

    speed: tool.schema
      .number()
      .min(0.5)
      .max(2.0)
      .optional()
      .describe("Speech speed multiplier (0.5-2.0). Default: 1.0"),

    volume: tool.schema
      .number()
      .min(0)
      .max(2)
      .optional()
      .describe("Playback volume (0-2). Default: 1.0"),
  },

  async execute(args) {
    const {
      text,
      stability = 0.5,
      similarity_boost = 0.75,
      speed = 1.0,
      volume = 1.0,
    } = args;

    // Fail fast on non-Windows hosts before spending an API call
    assertWindows();

    // Load API key from secrets file
    const apiKey = loadApiKey();

    // Call ElevenLabs v3 API
    const response = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}?output_format=mp3_44100_128`,
      {
        method: "POST",
        headers: {
          "xi-api-key": apiKey,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          text,
          model_id: MODEL_ID,
          voice_settings: {
            stability,
            similarity_boost,
            style: 0,
            use_speaker_boost: true,
            speed,
          },
        }),
      }
    );

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(
        `ElevenLabs API error (${response.status}): ${errorText}`
      );
    }

    // Save audio to temp file
    const audioBuffer = await response.arrayBuffer();
    const tempFile = join(tmpdir(), `opencode-voice-${Date.now()}.mp3`);
    writeFileSync(tempFile, Buffer.from(audioBuffer));

    // Play audio in background (non-blocking)
    playAudio(tempFile, volume);

    // Return immediately with confirmation
    const preview =
      text.length > 80 ? text.substring(0, 80) + "..." : text;
    return `<speak_started>
Playing speech (non-blocking): "${preview}"
Voice: ${VOICE_ID}
Model: ${MODEL_ID} (v3 expressive)
</speak_started>`;
  },
});

/**
 * The main plugin export
 */
export const VoicePlugin: Plugin = async () => {
  return {
    tool: {
      speak: speakTool,
    },
  };
};
