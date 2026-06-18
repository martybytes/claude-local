---
name: windows-perf-diagnosis
description: "[windows] Diagnose Windows performance issues — slow/unresponsive machine, high CPU or RAM. Use when the user reports sluggishness or when interpreting perf-snapshot output."
---

# windows-perf-diagnosis

Use this skill when:
- the user says the machine is slow, unresponsive, or laggy
- Interpreting output from `tools/windows/diagnostics/perf-snapshot.ps1`
- Deciding which running processes to kill, cap, or disable

## Tools available

Run from the repo root (relative paths, no elevation needed):

```powershell
# One-shot snapshot — use this first
.\tools\windows\diagnostics\perf-snapshot.ps1 [-Top 15] [-SaveLog] [-ExcludeDev] [-Exclude <names>] [-OnlyDev]

# Continuous monitor — use to catch intermittent spikes (live "what's busy NOW")
.\tools\windows\diagnostics\perf-watch.ps1 [-IntervalSec 5] [-CpuThreshold 25] [-RamThresholdMb 800] [-ExcludeDev]

# Track specific named processes' CPU + file-I/O over time (AV/EDR/agent overhead), then read it back
.\tools\windows\diagnostics\proc-track.ps1 -Names MsMpEng,MpDefenderCoreService,SnapAgent,ztac -IntervalSec 10
.\tools\windows\diagnostics\proc-track.ps1 -Summarize
```

Saved logs land in `logs/windows/diagnostics/` (gitignored).

## Excluding dev tools (`-ExcludeDev`)

When the box is busy with legitimate development work and you want to know what *else* is loading it, add `-ExcludeDev` (supported on `perf-snapshot`, `perf-watch`, and `perf-analyze`). It hides a shared allowlist defined in `tools/windows/diagnostics/dev-allowlist.ps1`:

- **Claude** — `claude` (Claude Code CLI — a native binary, *not* node)
- **Codex** — `codex` (Codex CLI/UI; matches `Codex` too)
- **node** — `node` (MCP servers, language servers, other node-based dev tools)
- **Docker** — `Docker Desktop`, `com.docker.backend/build`, `dockerd`, `docker`, plus `vmmem` / `vmmemWSL` / `wslservice` / `wsl` (the WSL2 VM that backs Docker)
- **PowerToys** — `PowerToys*` (all modules, incl. `PowerToys.Awake`)
- **Tailscale** — `tailscaled`, `Tailscale-IPN`, `tailscale`

Notes:
- The filter applies **only to the top-consumers tables**. The KNOWN HOGS check and VM section stay unfiltered on purpose, so `Docker Desktop` / `vmmemWSL` still surface there.
- A footer **always prints what was hidden** (`(suppressed from top tables: node x7, Docker x3 … totaling Ns CPU / N GB RAM)`), so nothing vanishes silently.
- `node` is matched by name, so a *rogue* non-dev `node` would be hidden too — but it's only summarized in the footer, not erased. Confirm node processes with `Get-CimInstance Win32_Process -Filter "name='node.exe'" | Select ProcessId,CommandLine`.
- `-Exclude 'msedge*','Cursor'` hides extra names; `-OnlyDev` inverts the filter to show just the dev stack's own footprint.

## AV/EDR scan bursts (Defender Passive Mode)

When the box feels horrible while developing but `perf-capture` / `perf-snapshot` look calm, suspect a **security agent scanning files in bursts**. Key facts seen on a real managed box:

- Microsoft Defender can run in **Passive Mode** (a third-party AV is registered as primary). `Get-MpComputerStatus` then shows `RealTimeProtectionEnabled=False` / `AMRunningMode=Passive Mode` — but `MsMpEng` **still runs passive/scheduled scans** (default schedule: daily 02:00, idle-only, 50% CPU cap). One was caught bursting **182% CPU and ~5,600 file-ops/sec**.
- These bursts are **invisible to `perf-capture`'s thresholds**: a scan is high *IOPS* but low *disk-queue* and well under `CPU≥60%` of a 32-thread box, so it never trips a SLOW WINDOW. A "calm" capture does **not** rule out an AV scan.
- Measure it directly with **`proc-track.ps1`** (CPU% + file-I/O ops/sec per named agent, over time): `-Names MsMpEng,MpDefenderCoreService` plus this machine's third-party agents (e.g. Blackpoint `SnapAgent`/`ztac`, Datto `agent`/`HUNTAgent`/`CagService`, other AV `endpointprotection`). Record during real work, then `proc-track.ps1 -Summarize`.
- If an agent's I/O bursts line up with the felt-slow moments, the fix is **dev-path AV exclusions via IT** (`C:\…\Workspace`, `node_modules`, build caches) — **not** disabling the agent. Never disable Defender or a managed EDR without an explicit, named instruction.

> Side note: a slow `Get-Counter` / Resource Monitor / Task Manager *during* such a burst is a symptom of the scan thrashing WMI/disk, not a broken perf subsystem — counters return to ~1–2 s once the box is calm.

## Whole-desktop / perceptual slowness (calm counters, mouse + UI laggy)

When the user reports the *whole desktop* feels slow — **mouse movement, window dragging, typing, switching apps, everything** — but `perf-snapshot`/`perf-capture` show idle CPU/disk/RAM and per-core/`proc-track` show no saturation, the bottleneck is **not compute/IO**. Mouse and window dragging depend on the display/GPU/input pipeline and almost nothing else, so work that layer:

1. **Throttle?** `Get-CimInstance Win32_Processor | Select CurrentClockSpeed,MaxClockSpeed,LoadPercentage` + `powercfg /q SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX`. Current clock far below max, or proc max-state < 100% (`0x64`), means the CPU is capped → uniformly slow. (High-performance plan with min=max=100% = no throttle.)
2. **Remote session?** `qwinsta` — if the active session is `rdp-tcp#…` rather than `console`, the lag is the remote pipe, not the PC (which looks idle). Rule this out first.
3. **Multi-GPU cross-adapter compositing** (common cause). `Get-CimInstance Win32_VideoController | ? CurrentRefreshRate` — if two monitors are split across two GPUs (e.g. one on a discrete card, one on the CPU's integrated graphics), DWM syncs/copies frames across adapters every refresh → global micro-stutter while GPU utilization **and** DWM CPU read ~0%. Fix: put all monitors on the discrete GPU, or disable the iGPU in Device Manager.
4. **Display refresh / timing.** A panel running below its rated refresh (e.g. 59 Hz on a 60/75/144 Hz display) makes the whole desktop feel sluggish; an odd value like 59 vs 60 hints at a cable/port/EDID issue. Set the rated refresh (Settings → Display → Advanced display); try another cable/port.
5. **Driver DPC/ISR latency.** The `% DPC Time` / `% Interrupt Time` counters are coarse — a driver can inject latency spikes without raising them. Run **LatencyMon** for a few minutes; it names the offending driver (GPU, NIC, audio, storage). This is the canonical tool for "everything stutters but the PC is idle."
6. **Input device.** A misbehaving mouse/HID driver or wireless-dongle interference makes the cursor specifically laggy.

**Key principle:** a machine that measures healthy on *every* sweep is itself the finding — stop trimming processes/startup items and look at the display → GPU → driver → input path.

## GPU VRAM contention from local TTS (cursor stalls "in sessions")

A specific, high-yield case of the perceptual-slowness pattern: the cursor/desktop stutters **during work sessions** (especially right when an event fires — a task finishing, a question, a permission prompt) on a box whose CPU/RAM/disk are idle. Cause: a local **GPU** text-to-speech service runs neural inference on the **same GPU that drives the displays**, on a card whose **VRAM is already saturated** (usually an Ollama model pinned with `OLLAMA_KEEP_ALIVE=-1`). Each synthesis evicts the compositor's surfaces → global micro-stutter at ~0% GPU util. Invisible to `perf-snapshot`/`perf-capture` by design.

**Don't reason it out by hand — run the tool:**

```powershell
.\tools\windows\diagnostics\gpu-tts-diagnose.ps1        # read-only triage + verdict
.\tools\windows\diagnostics\gpu-tts-quiet.ps1           # preview the fix
.\tools\windows\diagnostics\gpu-tts-quiet.ps1 -All -Apply   # disable Claude TTS, stop GPU TTS containers, kill hung relays, unload idle Ollama models (reversible: -Undo)
```

Key facts (full writeup: [`docs/windows/cursor-stall-gpu-tts-runbook.md`](../../../docs/windows/cursor-stall-gpu-tts-runbook.md)):
- **Trigger:** Claude Code TTS hooks fire on five events (`Stop`, `StopFailure`, `Notification`, `PermissionRequest`, `AskUserQuestion`) → an HTTP POST to a Kokoro/Chatterbox GPU container each time. Disable via `~/.claude/tts/config.json` `enabled:false`, or move TTS to the **CPU** container image.
- **VRAM holder:** `docker exec ollama ollama ps` shows resident models; `keep_alive` `-1`/forever pins VRAM. Durable fix: recreate Ollama with `OLLAMA_KEEP_ALIVE=10m` (preserve the named `ollama` volume — models survive).
- **Idle-iGPU red herring:** `Win32_VideoController` reports a refresh rate for an integrated GPU **with no monitor attached**, mimicking a cross-adapter split. Confirm the real compositor by **dedicated VRAM per adapter** (`\GPU Adapter Memory(*)\Dedicated Usage`) — GBs vs < 100 MB. The tool does this for you.
- **Hung relays:** leftover `cc-tts-debug`/`cc-speak-play` chains can stick for hours holding the audio path; the tool kills them and clears the stale play-lock.

## Reading the snapshot

**CPU column is accumulated seconds**, not live %. A process showing 9000s has burned 9000 CPU-seconds since it started. To get live activity, run `perf-watch` for 30 seconds and watch the delta column.

**Memory Compression > 1 GB** means the system has hit RAM pressure at some point this session. Over 2 GB = significant.

**Committed > 85% of virtual** means you're close to the edge; adding more apps will cause swapping.

**Pagefile peak > 2 GB** means the system has already been swapping hard this session — even if it looks OK now.

## Known culprits on this machine

| Process | Normal behavior | Red flag | Fix |
|---|---|---|---|
| `Cursor` | Low CPU when idle | CPU > 2000s, RAM > 1 GB | Restart Cursor; check if workspace points at a huge folder or network share |
| `Docker Desktop` / `com.docker.backend` | Only run when needed | Always running | Quit from tray when not containerizing |
| `com.docker.backend` running alone | — | Running without Docker Desktop UI | Orphaned backend — kill it: `Stop-Process -Name com.docker.backend -Force` |
| `vmmemWSL` | Small when idle | > 1 GB | Add `[wsl2]\nmemory=4GB` to `%USERPROFILE%\.wslconfig` |
| `Wox` | Near-zero CPU | CPU > 500s | Rebuild index: Settings → Index → Rebuild; or switch to PowerToys Run |
| `LogiPluginService` / `logioptionsplus_agent` | Near-zero | Hundreds or thousands of CPU-seconds | Disable from startup via `windows-services` skill if not using special Logitech features |
| `RzSynapse` | Near-zero | CPU > 1000s | Razer Synapse peripheral manager — restart it; disable startup if not needed |
| `Creative Cloud` / `AdobeCollabSync` | Not running | Always in tray | CC Preferences → uncheck "Launch at login"; AdobeCollabSync stops when CC quits |
| `SnagitCapture` | Only when capturing | Always running + high RAM | Quit between sessions |
| `Wispr Flow` | 1–2 processes | 3+ instances | Multiple orphaned instances — restart the app to clear them |
| `Move Mouse` | Near-zero | > 200s | Check interval setting — 1-second loops cause this |
| `msedgewebview2` | Moderate | > 500 MB per instance | Embedded browser spawned by other apps (Creative Cloud, 1Password, Wispr Flow); killing the parent app reclaims the memory |
| `Memory Compression` | < 500 MB | > 2 GB | Symptom of RAM pressure — find and stop large consumers |
| `notepad++` | Near-zero | CPU > 500s | Text editors should never accumulate CPU; likely a runaway plugin or a very large file open |
| `endpointprotection` | Always present, low CPU | High CPU | EDR/antivirus; if scanning heavily, check if it's doing a scheduled scan |

## Virtual machines (vmmem / vmwp)

The snapshot now auto-identifies running VMs. If you see `vmmem` processes:

- **`vmmemWSL`** — always WSL2. Cap with `%USERPROFILE%\.wslconfig`.
- **`vmmem` (generic)** — a Hyper-V VM. The snapshot identifies it via named pipes.

**Known VMs on this machine:**

| Identity | RAM | Notes |
|---|---|---|
| WSL2 | ~1–2 GB | Used by Docker and direct WSL usage |
| Docker Desktop VM | ~1–2 GB | Quit Docker Desktop to stop |
| Cowork | ~1.5 GB | Collaboration app — quit from tray if not in a Cowork session |
| Windows Subsystem for Android | varies | Stop via WSA Settings if not needed |

**Manual VM identification** (if snapshot doesn't catch it):
```powershell
# Find all vmwp processes and their named pipes
[System.IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'cowork|wsl|docker|android' }
```

## Docker orphaned backend pattern

If Docker Desktop "won't start" but `com.docker.backend` is still in the process list:
The backend is stuck; the UI can't attach to it. Fix:
```powershell
Stop-Process -Name "com.docker.backend" -Force
Stop-Process -Name "Docker Desktop" -Force -ErrorAction SilentlyContinue
# Then relaunch Docker Desktop normally
```

## Triage order

1. **Quit unused background apps** (Docker, Creative Cloud, Snagit, Cowork) — zero risk, immediate RAM gain.
2. **Restart runaway processes** (Cursor high CPU, Wispr Flow multiple instances, Notepad++ anomaly) — resets accumulated debt.
3. **Kill orphaned backends** (Docker backend without UI, extra Wispr Flow processes).
4. **Cap VM memory** (WSL `.wslconfig`, Docker resource limits) — persistent fix for next session.
5. **Disable startup items** (Logitech, Razer Synapse, Wox) — use `windows-services` skill; requires restart to verify.

## Asking for a live snapshot

If the user hasn't run a snapshot yet:

```
I'll run a quick snapshot to see what's going on.
```

Then: `.\tools\windows\diagnostics\perf-snapshot.ps1 -SaveLog`
