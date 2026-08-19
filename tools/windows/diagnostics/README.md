# Windows performance diagnostics — `tools/windows/diagnostics/`

PowerShell tools for diagnosing a slow or unresponsive Windows machine — one-shot snapshots, live
threshold watching, unattended capture of *intermittent* slowdowns, and per-process AV/EDR overhead.

> 🧰 **All repo tools:** [root README → Tools](../../../README.md#tools)
> 🧠 **Interpretation:** the [`windows-perf-diagnosis`](../../../.claude/skills/windows-perf-diagnosis/SKILL.md)
> and [`perf-capture`](../../../.claude/skills/perf-capture/SKILL.md) skills; the [`/perf`](../../../.claude/commands/perf.md)
> and [`/capture`](../../../.claude/commands/capture.md) commands drive these tools and interpret the output.

## Scripts

| Script | What it does | Key params |
|---|---|---|
| [`perf-snapshot.ps1`](perf-snapshot.ps1) | One-shot snapshot: CPU, RAM, disk, pagefile, power plan, top processes, known-hog check | `-Top <n>`, `-SaveLog`, `-ExcludeDev`, `-Exclude <names>`, `-OnlyDev` |
| [`perf-watch.ps1`](perf-watch.ps1) | Continuous, interactive console monitor; alerts when a process crosses a CPU % or RAM MB threshold | `-IntervalSec`, `-CpuThreshold`, `-RamThresholdMb`, `-Top`, `-ExcludeDev`, `-Exclude`, `-OnlyDev` |
| [`perf-capture.ps1`](perf-capture.ps1) | **Unattended** background monitor; appends timestamped CPU/disk/RAM samples + a spike flag to a log; writes a PID file | `-IntervalSec`, `-CpuPct`, `-DiskQ`, `-DurationMin`, `-Top` |
| [`perf-analyze.ps1`](perf-analyze.ps1) | Parse a perf-capture log into ranked culprits, slow-time windows, and an optional time-focused view | `-Path`, `-Around HH:mm`, `-WindowMin`, `-CpuPct`, `-DiskQ`, `-Top`, `-ExcludeDev`, `-Exclude`, `-OnlyDev` |
| [`proc-track.ps1`](proc-track.ps1) | Track named processes' CPU% + file-I/O ops/sec + RAM over time to a log — catches AV/EDR scan bursts (high IOPS, low disk queue) that `perf-capture` thresholds miss; `-Summarize` reads the log back. See the [spawn-latency runbook](../../../docs/windows/security-agent-spawn-latency-runbook.md) | `-Names`, `-IntervalSec`, `-DurationMin`, `-SpikeCpu`, `-SpikeIops`, `-Summarize`, `-Path` |
| [`gpu-tts-diagnose.ps1`](gpu-tts-diagnose.ps1) | Read-only triage for cursor/desktop stutter from **GPU contention**: VRAM saturation, GPU TTS containers (Kokoro/Chatterbox), Ollama keep-alive, Claude Code TTS hooks, hung TTS relays. Flags causes + prints a verdict | `-SaveLog` |
| [`gpu-tts-quiet.ps1`](gpu-tts-quiet.ps1) | **Reversible** remediation for the above: disable Claude TTS (backed up), stop GPU TTS containers, kill hung relays, unload idle Ollama models. Previews by default | `-All`, `-DisableClaudeTts`, `-StopTtsContainers`, `-KillHungRelays`, `-UnloadOllama`, `-Apply`, `-Undo` |
| [`dev-allowlist.ps1`](dev-allowlist.ps1) | Shared dev-tool allowlist + matcher (node / Docker+WSL / PowerToys / Tailscale); **dot-sourced** by the perf-* tools to power `-ExcludeDev`. Not run directly | _(library — dot-sourced)_ |

## Quick start

```powershell
# Machine is slow right now -> one-shot snapshot
.\tools\windows\diagnostics\perf-snapshot.ps1 -SaveLog

# Watch live, hide your own dev tools from the noise
.\tools\windows\diagnostics\perf-watch.ps1 -CpuThreshold 25 -RamThresholdMb 800 -ExcludeDev

# "Comes and goes" -> capture unattended in the background, then analyze by timestamp
.\tools\windows\diagnostics\perf-capture.ps1 -IntervalSec 5 -DurationMin 120   # (run in background)
.\tools\windows\diagnostics\perf-analyze.ps1 -Around 14:30 -ExcludeDev          # focus a moment it lagged

# Suspect an AV/EDR/RMM agent -> sample its CPU + I/O over time, then summarize
.\tools\windows\diagnostics\proc-track.ps1 -Names MsMpEng,Sysmon64 -DurationMin 60
.\tools\windows\diagnostics\proc-track.ps1 -Summarize

# Everything feels slow but CPU/disk look idle -> measure process-spawn latency (the AV/EDR tax)
$ms = 1..12 | ForEach-Object { (Measure-Command { & cmd.exe /c exit }).TotalMilliseconds }
($ms | Sort-Object)[6]     # median; healthy is ~10-15 ms, 150 ms+ means launches are being gated

# Cursor/desktop stutters "in sessions" but compute is idle -> GPU/TTS contention triage, then fix
.\tools\windows\diagnostics\gpu-tts-diagnose.ps1
.\tools\windows\diagnostics\gpu-tts-quiet.ps1 -All -Apply     # reversible: -Undo
```

> **GPU/TTS contention** (`gpu-tts-*`) is a distinct failure mode from compute slowness: a local GPU
> TTS service (Kokoro) + a VRAM-pinned Ollama model stall the *display compositor*, so CPU/disk/RAM
> sweeps look clean. Full mechanism + manual `OLLAMA_KEEP_ALIVE` fix:
> [`docs/windows/cursor-stall-gpu-tts-runbook.md`](../../../docs/windows/cursor-stall-gpu-tts-runbook.md);
> driven by the [`/gpu-tts`](../../../.claude/commands/gpu-tts.md) command.

> **Stacked AV/EDR process-gating** is a third distinct failure mode, and the sneakiest: the whole
> box feels slow while CPU sits at 15% and the disk queue at ~0, because the cost is *latency per
> `CreateProcess`*, not throughput — so no process ever looks busy in Task Manager. It punishes
> agent/CLI work hardest, since one tool call is a chain of spawns. Measure spawn time, not CPU.
> Full diagnosis, the publisher-vs-path exclusion argument, and verification targets:
> [`docs/windows/security-agent-spawn-latency-runbook.md`](../../../docs/windows/security-agent-spawn-latency-runbook.md).

## Notes

- **One-shot vs intermittent:** reach for `perf-snapshot` when it's slow *now*; use `perf-capture` +
  `perf-analyze` when the slowness "comes and goes" and a single snapshot looks clean. The
  [`perf-analyst`](../../../.claude/agents/perf-analyst.md) agent chews through long capture logs off the main context.
- **`-ExcludeDev`** (on snapshot / watch / analyze) filters the dev-tool noise defined in `dev-allowlist.ps1`;
  `-OnlyDev` does the inverse, `-Exclude <names>` adds ad-hoc names.
- **`proc-track -Names` takes a comma list** (`-Names MsMpEng,SnapAgent,ztac`) and prefix-matches, so
  `RMM` catches `RMM.WebRemote`. The list is split defensively because `pwsh -File script.ps1 -Names a,b,c`
  passes it as a *single string* (`-File` does no type coercion) — that used to produce a filter matching
  nothing and a log full of all-zero samples, with no error to tell you so.
- **Logs:** `-SaveLog` / capture output lands under `logs\windows\diagnostics\` (git-ignored).
