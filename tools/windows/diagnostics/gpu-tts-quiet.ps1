<#
.NAME        gpu-tts-quiet
.SYNOPSIS    Reversibly quiet the GPU-contention sources behind cursor stutter: disable Claude Code TTS, stop GPU TTS containers, kill hung TTS relays, and unload idle Ollama models. Previews by default.
.PLATFORM    windows
.CATEGORY    diagnostics
.USAGE       .\tools\windows\diagnostics\gpu-tts-quiet.ps1 [-All] [-DisableClaudeTts] [-StopTtsContainers] [-KillHungRelays] [-UnloadOllama] [-Apply] [-Undo]
.WHEN        gpu-tts-diagnose flagged GPU/TTS contention and you want to stop the cursor stall fast; -Undo restores Claude TTS + the TTS containers.
#>
param(
    [switch]$All,                 # select every action below (default when no specific action is given)
    [switch]$DisableClaudeTts,    # set ~/.claude/tts/config.json enabled=false (backed up first)
    [switch]$StopTtsContainers,   # docker stop kokoro/chatterbox/*tts* + restart=no
    [switch]$KillHungRelays,      # kill stuck cc-tts-debug / cc-speak-play chains (Windows + WSL)
    [switch]$UnloadOllama,        # unload loaded Ollama models now to free VRAM (reloads on next query)
    [switch]$Apply,               # actually perform the forward actions (omit = preview only)
    [switch]$Undo                 # reverse: re-enable Claude TTS and restart the TTS containers
)

$repoRoot  = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $repoRoot "backups\windows\tts\$timestamp"

# Default to all actions when the caller named none.
if (-not ($DisableClaudeTts -or $StopTtsContainers -or $KillHungRelays -or $UnloadOllama)) { $All = $true }
$doTts   = $All -or $DisableClaudeTts
$doCont  = $All -or $StopTtsContainers
$doRelay = $All -or $KillHungRelays
$doOll   = $All -or $UnloadOllama
$execute = $Apply -or $Undo
$mode    = if ($Undo) { 'UNDO' } elseif ($Apply) { 'APPLY' } else { 'PREVIEW' }

function Section([string]$t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Step([string]$t)    { $tag = if ($execute) { '[DO]  ' } else { '[would]' }; Write-Host "$tag $t" -ForegroundColor ($(if ($execute) { 'Green' } else { 'Yellow' })) }
function Info([string]$t)    { Write-Host "       $t" -ForegroundColor DarkGray }
function Have([string]$c)    { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

Write-Host "gpu-tts-quiet  mode=$mode" -ForegroundColor White
if (-not $execute) { Write-Host '(preview only — re-run with -Apply to perform, or -Undo to reverse)' -ForegroundColor DarkGray }

# ── Claude Code TTS hooks ─────────────────────────────────────────────────────
if ($doTts) {
    Section 'Claude Code TTS hooks'
    $cfgPath = Join-Path $env:USERPROFILE '.claude\tts\config.json'
    if (-not (Test-Path $cfgPath)) {
        Info "no config at $cfgPath — nothing to do"
    } else {
        $newEnabled = [bool]$Undo   # forward => false ; undo => true
        Step "set enabled = $($newEnabled.ToString().ToLower()) in $cfgPath"
        if ($execute) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            Copy-Item $cfgPath (Join-Path $backupDir 'config.json') -Force
            Info "backed up -> $backupDir\config.json"
            $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $cfg.enabled = $newEnabled
            ($cfg | ConvertTo-Json -Depth 12) | Set-Content -Path $cfgPath -Encoding UTF8
            Info "enabled is now $($cfg.enabled)"
        }
    }
}

# ── GPU TTS containers ────────────────────────────────────────────────────────
if ($doCont) {
    Section 'GPU TTS containers'
    if (-not (Have 'docker')) { Info 'docker not found — skipped' }
    else {
        $rows = (& docker ps -a --format '{{.Names}}|{{.Status}}' 2>$null) -split "`n" |
            Where-Object { $_ -match 'kokoro|chatterbox|tts|piper|coqui' }
        if (-not $rows) { Info 'no TTS containers found' }
        foreach ($r in $rows) {
            $n, $st = $r -split '\|', 2
            if ($Undo) {
                if ($st -notlike 'Up*') {
                    Step "docker start $n  (+ restart=unless-stopped)"
                    if ($execute) { & docker update --restart=unless-stopped $n *> $null; & docker start $n *> $null; Info 'started' }
                } else { Info "$n already running" }
            } else {
                if ($st -like 'Up*') {
                    Step "docker stop $n  (+ restart=no)"
                    if ($execute) { & docker update --restart=no $n *> $null; & docker stop $n *> $null; Info 'stopped' }
                } else { Info "$n already stopped ($st)" }
            }
        }
    }
}

# ── Hung TTS relays (forward only) ────────────────────────────────────────────
if ($doRelay -and -not $Undo) {
    Section 'Hung TTS relays'
    $hung = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'cc-tts-debug|cc-speak-play' })
    if (-not $hung) { Info 'none on Windows side' }
    foreach ($h in $hung) {
        Step "kill pid $($h.ProcessId) ($($h.Name))"
        if ($execute) { Stop-Process -Id $h.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if (Have 'wsl') {
        Step 'pkill -f cc-tts-debug / cc-speak-play (WSL)'
        if ($execute) { & wsl.exe -e bash -lc 'pkill -f cc-tts-debug 2>/dev/null; pkill -f cc-speak-play 2>/dev/null; true' 2>$null | Out-Null }
    }
    # stale audio play-lock left by a hung player
    $lock = Join-Path $env:LOCALAPPDATA 'terminal-stack\cc-tts.play.lock'
    if (Test-Path $lock) { Step "remove stale play-lock $lock"; if ($execute) { Remove-Item $lock -Force -ErrorAction SilentlyContinue } }
}

# ── Unload Ollama models (forward only) ───────────────────────────────────────
if ($doOll -and -not $Undo) {
    Section 'Ollama models (free VRAM now)'
    if (-not (Have 'docker')) { Info 'docker not found — skipped' }
    else {
        $name = ((& docker ps --filter 'ancestor=ollama/ollama' --format '{{.Names}}' 2>$null) -split "`n" | Where-Object { $_ })[0]
        if (-not $name) { $name = ((& docker ps --filter 'name=ollama' --format '{{.Names}}' 2>$null) -split "`n" | Where-Object { $_ })[0] }
        if (-not $name) { Info 'no running ollama container' }
        else {
            $ps = (& docker exec $name ollama ps 2>$null) -split "`n" | Select-Object -Skip 1 | Where-Object { $_ -match '\S' }
            if (-not $ps) { Info 'no models loaded — VRAM already free' }
            foreach ($line in $ps) {
                $model = ($line -split '\s+')[0]
                Step "ollama stop $model"
                if ($execute) { & docker exec $name ollama stop $model *> $null }
            }
            Info 'tip: for durable headroom set OLLAMA_KEEP_ALIVE=10m (see cursor-stall-gpu-tts-runbook.md)'
        }
    }
}

Write-Host ''
if (-not $execute) { Write-Host 'Nothing changed (preview). Add -Apply to perform, -Undo to reverse.' -ForegroundColor White }
else { Write-Host "Done ($mode)." -ForegroundColor Green; if ($doTts) { Write-Host "Config backup: $backupDir" -ForegroundColor DarkGray } }
