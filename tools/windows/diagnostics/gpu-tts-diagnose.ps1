<#
.NAME        gpu-tts-diagnose
.SYNOPSIS    Read-only triage for whole-desktop/cursor stutter caused by GPU contention: VRAM saturation, GPU TTS containers (Kokoro/Chatterbox), Ollama keep-alive, Claude Code TTS hooks, and hung TTS relays.
.PLATFORM    windows
.CATEGORY    diagnostics
.USAGE       .\tools\windows\diagnostics\gpu-tts-diagnose.ps1 [-SaveLog]
.WHEN        Mouse cursor / whole desktop stutters during work "sessions" but CPU/RAM/disk look idle; perf-snapshot is clean yet the box feels laggy; suspect GPU/VRAM or a local TTS (text-to-speech) service.
#>
param(
    [switch]$SaveLog
)

$repoRoot  = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$logDir    = Join-Path $repoRoot 'logs\windows\diagnostics'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$lines     = [System.Collections.Generic.List[string]]::new()
$issues    = [System.Collections.Generic.List[string]]::new()

function Section([string]$title) {
    $lines.Add(''); $lines.Add("=== $title ===")
    Write-Host "`n=== $title ===" -ForegroundColor Cyan
}
function Out([string]$text)  { $lines.Add($text); Write-Host $text }
function Flag([string]$text) { $lines.Add("  [FLAG] $text"); Write-Host "  [FLAG] $text" -ForegroundColor Yellow; $issues.Add($text) }
function Have([string]$cmd)  { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Run a command in the default WSL distro, swallowing the cosmetic "screen size is bogus" stderr.
function Wsl([string]$bash) {
    try { (& wsl.exe -e bash -lc $bash 2>$null) -join "`n" } catch { '' }
}

# ── GPU adapters & displays ───────────────────────────────────────────────────
Section 'GPU ADAPTERS & DISPLAYS'
$vcs = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.CurrentRefreshRate -gt 0 })
foreach ($v in $vcs) {
    Out ("{0}  {1}x{2} @ {3}Hz" -f $v.Name, $v.CurrentHorizontalResolution, $v.CurrentVerticalResolution, $v.CurrentRefreshRate)
}
# Which adapters actually composite? Win32_VideoController reports a refresh rate even for an IDLE
# integrated GPU with no monitor attached, so trust dedicated-VRAM usage to find the real compositor(s).
$ded = @{}
try {
    (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples |
        Where-Object { $_.CookedValue -gt 0 } |
        ForEach-Object { $ded[$_.InstanceName] = [math]::Round($_.CookedValue / 1MB) }
} catch {}
$activeAdapters = @($ded.GetEnumerator() | Where-Object { $_.Value -gt 256 })
if ($ded.Count) {
    Out ('  adapter dedicated VRAM: ' + (($ded.Values | Sort-Object -Descending | ForEach-Object { "${_}MB" }) -join ', '))
}
if ($activeAdapters.Count -ge 2) {
    Flag "Two+ GPUs each hold >256MB VRAM — monitors may be split across adapters → cross-adapter DWM compositing → global micro-stutter at ~0% GPU. Verify all monitors are on the discrete card (an idle iGPU holds little VRAM and is fine)."
}
if ($vcs | Where-Object { $_.CurrentRefreshRate -lt 60 }) {
    Out '  note: a display reports <60 Hz. If that adapter actually drives a monitor (not an idle iGPU), set the rated refresh in Settings → Display → Advanced; an odd 59 Hz hints at a cable/EDID issue.'
}

# ── GPU VRAM (NVIDIA) ─────────────────────────────────────────────────────────
Section 'GPU VRAM'
if (Have 'nvidia-smi') {
    $smi = (& nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits 2>$null) -join "`n"
    foreach ($row in ($smi -split "`n" | Where-Object { $_ -match '\d' })) {
        $p = $row -split ',\s*'
        if ($p.Count -ge 3) {
            $used = [int]$p[0]; $total = [int]$p[1]; $util = [int]$p[2]
            $pct = if ($total) { [math]::Round($used / $total * 100) } else { 0 }
            Out ("VRAM: {0} / {1} MiB ({2}%)  util {3}%" -f $used, $total, $pct, $util)
            if ($pct -ge 85) {
                Flag "VRAM ${pct}% full — a near-full framebuffer forces the compositor to spill surfaces to system RAM the moment anything else (e.g. a TTS model) loads → cursor stall. See OLLAMA + GPU TTS below for the holder."
            }
        }
    }
} else {
    Out 'nvidia-smi not found (no NVIDIA GPU, or driver tools not on PATH). VRAM check skipped.'
}

# ── Ollama (typical VRAM holder) ──────────────────────────────────────────────
Section 'OLLAMA'
if (Have 'docker') {
    $oll = (& docker ps -a --filter 'ancestor=ollama/ollama' --format '{{.Names}}|{{.Status}}' 2>$null) -join "`n"
    if (-not $oll) { $oll = (& docker ps -a --filter 'name=ollama' --format '{{.Names}}|{{.Status}}' 2>$null) -join "`n" }
    if ($oll) {
        foreach ($c in ($oll -split "`n" | Where-Object { $_ })) {
            $n, $st = $c -split '\|', 2
            Out "container: $n  ($st)"
            if ($st -like 'Up*') {
                $ka = (& docker inspect $n --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null |
                       Select-String 'OLLAMA_KEEP_ALIVE=').ToString()
                if ($ka) { Out "  $ka" }
                if ($ka -match 'OLLAMA_KEEP_ALIVE=(-1|0s?$)') {
                    Flag "Ollama keep-alive is '$($Matches[1])' (never unloads) — a loaded model pins VRAM forever. Set OLLAMA_KEEP_ALIVE=10m so idle models free VRAM."
                }
                $ps = (& docker exec $n ollama ps 2>$null) -join "`n"
                if ($ps -match '\d+\s*(GB|MB)') {
                    Out '  loaded models:'
                    foreach ($l in ($ps -split "`n" | Select-Object -Skip 1 | Where-Object { $_ -match '\S' })) { Out "    $l" }
                } else { Out '  no models currently loaded (VRAM free)' }
            }
        }
    } else { Out 'no ollama container found' }
} else { Out 'docker not found — Ollama/container checks skipped.' }

# ── GPU TTS containers (the cursor-stall trigger) ─────────────────────────────
Section 'GPU TTS CONTAINERS'
$ttsRunning = $false
if (Have 'docker') {
    $cs = (& docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>$null) -join "`n"
    $tts = $cs -split "`n" | Where-Object { $_ -match 'kokoro|chatterbox|tts|piper|coqui' }
    if ($tts) {
        foreach ($c in $tts) {
            $n, $img, $st = $c -split '\|', 3
            $gpu = if ($img -match 'gpu|cu\d|blackwell') { ' [GPU image]' } else { '' }
            Out "$n  $img$gpu  ($st)"
            if ($st -like 'Up*') {
                $ttsRunning = $true
                Flag "TTS container '$n' is RUNNING$gpu — each synthesis competes with the display compositor for the GPU. Stop it when not in use (gpu-tts-quiet.ps1 -StopTtsContainers)."
            }
        }
    } else { Out 'no kokoro/chatterbox/TTS containers found' }
} else { Out 'docker not found — TTS container check skipped.' }

# ── Claude Code TTS hooks ─────────────────────────────────────────────────────
Section 'CLAUDE CODE TTS HOOKS'
$ttsCfg = Join-Path $env:USERPROFILE '.claude\tts\config.json'
$ttsEnabled = $false
if (Test-Path $ttsCfg) {
    try {
        $cfg = Get-Content $ttsCfg -Raw | ConvertFrom-Json
        $ttsEnabled = [bool]$cfg.enabled
        Out "config: enabled=$($cfg.enabled)  engine=$($cfg.engine)  events=[$(@($cfg.events) -join ', ')]"
        if ($ttsEnabled -and $ttsRunning) {
            Flag "Claude TTS is ENABLED and a GPU TTS container is running — TTS fires on Stop/error/question/permission/notification, i.e. constantly mid-session, hitting the GPU each time. This is the classic 'cursor stalls in sessions' cause. Disable with gpu-tts-quiet.ps1 -DisableClaudeTts, or move TTS to a CPU container."
        }
    } catch { Out "could not parse $ttsCfg : $($_.Exception.Message)" }
} else { Out "no Claude TTS config at $ttsCfg (TTS hooks not configured)" }

# ── TTS processes & listeners (Windows + WSL) ─────────────────────────────────
Section 'TTS PROCESSES & LISTENERS'
$winTts = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'voicebox|kokoro|chatterbox|piper|coqui' })
if ($winTts) { $winTts | ForEach-Object { Out ("  win: {0} (pid {1}, {2} MB)" -f $_.ProcessName, $_.Id, [math]::Round($_.WorkingSet64/1MB)) } }
else { Out '  win: no native TTS app processes' }
foreach ($port in 8880, 8881, 8782) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    if ($c) { $pr = Get-Process -Id $c[0].OwningProcess -ErrorAction SilentlyContinue; Out "  win: :$port LISTEN (pid $($c[0].OwningProcess) $($pr.ProcessName))" }
}
if (Have 'wsl') {
    # Detect WSL-side TTS by listening port (avoids ps-grep self-match). 8782 = orion_tts_switch.
    $wslPorts = Wsl "ss -ltn 2>/dev/null | grep -E ':(8880|8881|8782)' || true"
    if ($wslPorts.Trim()) {
        foreach ($l in ($wslPorts -split "`n" | Where-Object { $_.Trim() })) { Out "  wsl listener: $($l.Trim())" }
        if ($wslPorts -match ':8782') { Out '  (:8782 = orion_tts_switch engine switcher — can docker-start kokoro/chatterbox on request)' }
    } else { Out '  wsl: no TTS listeners (8880/8881/8782)' }
}

# ── Hung TTS relay processes ──────────────────────────────────────────────────
Section 'HUNG TTS RELAYS'
$now = Get-Date
$hung = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessId -ne $PID -and $_.CommandLine -match 'cc-tts-debug|cc-speak-play' })
if ($hung) {
    foreach ($h in $hung) {
        $started = try { $h.CreationDate } catch { $null }
        $ageMin = if ($started) { [math]::Round(($now - $started).TotalMinutes) } else { '?' }
        Out ("  pid {0} {1}  age {2} min" -f $h.ProcessId, $h.Name, $ageMin)
        if ($started -and ($now - $started).TotalMinutes -gt 5) {
            Flag "TTS relay pid $($h.ProcessId) ($($h.Name)) stuck ~$ageMin min — a hung cc-tts-debug/cc-speak-play chain holds the audio path. Clear with gpu-tts-quiet.ps1 -KillHungRelays."
        }
    }
} else { Out '  none' }

# ── Verdict ───────────────────────────────────────────────────────────────────
Section 'VERDICT'
if ($issues.Count -eq 0) {
    Out '  No GPU/TTS contention indicators found. If the cursor still stutters, work the display→GPU→driver→input path (see windows-perf-diagnosis "Whole-desktop / perceptual slowness").'
} else {
    Out "  $($issues.Count) issue(s) flagged above. Likely fix path:"
    Out '    1) gpu-tts-quiet.ps1            # preview the remediation'
    Out '    2) gpu-tts-quiet.ps1 -All -Apply  # disable Claude TTS, stop GPU TTS containers, kill hung relays, unload idle Ollama models'
    Out '    Durable Ollama VRAM headroom: set OLLAMA_KEEP_ALIVE=10m (see docs\windows\cursor-stall-gpu-tts-runbook.md).'
}

# ── Save log ──────────────────────────────────────────────────────────────────
if ($SaveLog) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logPath = Join-Path $logDir "${timestamp}-gpu-tts-diagnose.txt"
    $lines | Set-Content -Path $logPath -Encoding UTF8
    Write-Host "`nLog saved: $logPath" -ForegroundColor Green
}
