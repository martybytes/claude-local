# Runbook: whole-desktop cursor stall from GPU contention (local TTS + Ollama VRAM)

**Symptom.** The mouse cursor / whole desktop stutters and freezes in short bursts **during work "sessions"**, while `perf-snapshot` / `perf-capture` show idle CPU, disk, and RAM. Powerful machine, yet it "runs terribly." The stutter correlates with *events* (finishing a task, being asked a question) rather than sustained load.

**One-line cause.** A local **GPU** text-to-speech service (Kokoro/Chatterbox in Docker) runs neural inference on the **same GPU that drives the displays**, every time a Claude Code session event fires — on a GPU whose **VRAM is already saturated** (typically by an Ollama model pinned with `keep_alive` forever). Each synthesis evicts compositor surfaces from VRAM → global micro-stutter at ~0% GPU utilization.

This is the GPU-pipeline sibling of the AV-scan and perceptual-slowness cases in the [`windows-perf-diagnosis`](../../.claude/skills/windows-perf-diagnosis/SKILL.md) skill: a machine that measures healthy on every compute sweep *is itself the finding* — work the display → GPU → VRAM → driver path, not the process list.

---

## Why it stalls (mechanism)

1. **Displays + compute share one GPU.** The RTX 5070 drives the monitors *and* runs CUDA workloads. The desktop compositor (DWM) needs the GPU every refresh.
2. **VRAM is near-full.** Ollama keeps a model resident (`OLLAMA_KEEP_ALIVE=-1` = forever). On a 12 GB card, one 5 GB model + dozens of GPU-accelerated Electron apps leaves the framebuffer ~90% full.
3. **TTS fires constantly mid-session.** Claude Code hooks call the TTS server on **five** events — `Stop`, `StopFailure`, `Notification`, `PermissionRequest`, and every `AskUserQuestion`. Each is an HTTP POST → 0.5–2 s of GPU inference.
4. **The collision.** Loading the TTS model / running inference on an already-full framebuffer forces DWM surfaces to spill to system RAM over PCIe → the cursor freezes for the duration. GPU *utilization* and CPU read ~0%, so every compute-based tool calls it healthy.

Contributing noise seen on this machine: **hung `cc-tts-debug` → `cc-speak-play` relay processes** left over from a manual TTS test, stuck >24 h holding the audio path; a `voicebox.exe` desktop app; and `orion_tts_switch.py` (WSL, port 8782) that can `docker start` the GPU TTS containers on request.

---

## Standing one up in the first place

If no `kokoro` container exists yet — `gpu-tts-diagnose.ps1` reports "no TTS containers found" and
nothing listens on 8880 — use:

```powershell
.\tools\windows\system\setup-kokoro-docker.ps1               # preview
.\tools\windows\system\setup-kokoro-docker.ps1 -Apply         # pull + create/start it (GPU by default)
.\tools\windows\system\setup-kokoro-docker.ps1 -Cpu -Apply    # CPU-only — sidesteps this whole runbook
```

See [`tools/windows/system/README.md`](../../tools/windows/system/README.md#setup-kokoro-dockerps1)
for config knobs and safety notes. **On Blackwell (RTX 50-series) cards the GPU image's default
`:latest` tag is broken** — see the gotcha below — the script defaults to the working `v0.8.0-cu128`
tag instead.

---

## Diagnose (fast)

```powershell
.\tools\windows\diagnostics\gpu-tts-diagnose.ps1        # read-only; add -SaveLog to keep it
```

It checks, and FLAGs, the whole chain in one pass:
- GPU adapters + which one actually holds VRAM (so an **idle iGPU** isn't mistaken for a real cross-adapter split — the trap that derails this diagnosis)
- NVIDIA VRAM used/total/util (flags ≥ 85%)
- Ollama container `OLLAMA_KEEP_ALIVE` + loaded models (flags `-1`/forever with a model pinned)
- GPU TTS containers (kokoro/chatterbox/*-gpu) running state
- Claude Code TTS `enabled` + events (flags enabled **while** a GPU TTS container runs)
- TTS apps/listeners on Windows + WSL (voicebox, ports 8880/8881/8782)
- Hung `cc-tts-debug` / `cc-speak-play` relays (flags age > 5 min)

The verdict block tells you whether GPU/TTS contention is present and points at the fix.

---

## Fix

### One shot (recommended)

```powershell
.\tools\windows\diagnostics\gpu-tts-quiet.ps1            # preview what it will do
.\tools\windows\diagnostics\gpu-tts-quiet.ps1 -All -Apply
```

`-All -Apply` does the reversible set: disables Claude TTS (backs up `config.json` to `backups\windows\tts\<ts>\` first), stops the GPU TTS containers (`restart=no`), kills hung relays + clears the stale audio play-lock, and unloads idle Ollama models. Pick a subset with `-DisableClaudeTts`, `-StopTtsContainers`, `-KillHungRelays`, `-UnloadOllama`.

**Reverse it:** `gpu-tts-quiet.ps1 -Undo` re-enables Claude TTS and restarts the TTS containers (`restart=unless-stopped`).

### Durable VRAM headroom — Ollama keep-alive (manual, machine-specific)

Unloading frees VRAM *now*, but a `keep_alive=-1` model reloads and pins it again on next query. Make idle models unload after 10 minutes. Ollama here is a plain `docker run` (no compose), so recreate it preserving the named `ollama` volume (models persist) — only the keep-alive changes:

```powershell
docker rm -f ollama
docker run -d --name ollama --restart unless-stopped --gpus all -p 11434:11434 -v ollama:/root/.ollama `
  -e OLLAMA_CONTEXT_LENGTH=8192 -e OLLAMA_MAX_LOADED_MODELS=1 -e OLLAMA_HOST=0.0.0.0:11434 `
  -e OLLAMA_KEEP_ALIVE=10m ollama/ollama
```

Confirm: `docker inspect ollama --format '{{range .Config.Env}}{{println .}}{{end}}'` shows `OLLAMA_KEEP_ALIVE=10m`; `docker exec ollama ollama list` still shows your models. Revert by recreating with `-e OLLAMA_KEEP_ALIVE=-1`. First query after a 10-min idle gap pays a few seconds of reload — the trade-off for freed VRAM.

### Keep it from coming back

- Re-enable TTS later by flipping `enabled` to `true` in `~/.claude/tts/config.json` and `docker start kokoro` — or, better, move TTS off the GPU: recreate the Kokoro container from the **CPU** image (`ghcr.io/remsky/kokoro-fastapi-cpu`). A Ryzen-class CPU synthesizes short notification phrases with imperceptible latency and never touches the display GPU.
- If you don't use the WSL switcher, `wsl -e bash -lc 'pkill -f orion_tts_switch'` stops the port-8782 service that can restart the GPU containers.

---

## Gotchas learned the hard way

- **The idle iGPU red herring.** `Get-CimInstance Win32_VideoController` reports a `CurrentRefreshRate` for an integrated GPU **even with no monitor attached**, which looks exactly like a two-monitors-on-two-GPUs split. Confirm with **dedicated VRAM per adapter** (`\GPU Adapter Memory(*)\Dedicated Usage`): the real compositor holds GBs; an idle iGPU holds < 100 MB. `gpu-tts-diagnose.ps1` already does this.
- **`pgrep -f orion_tts_switch` self-matches.** Any `wsl … bash -lc` whose command line contains the search string is itself a hit. Use the bracket trick (`[o]rion`) or match by **listening port** (8782) instead — the diagnose tool uses the port.
- **`local.json` overrides were silently ignored** (`Merge-CcTtsHashtable` iterated `$Over.PSObject.Properties` on a *hashtable*, yielding `Count/Keys/Values` instead of the data keys). Fixed upstream in `terminal-stack` (commit on `windows/.claude/hooks/cc-tts-lib.ps1`). On a machine still carrying the old hook, set `enabled` directly in `config.json` rather than `local.json`.
- **A "calm" perf-snapshot does not rule this out** — by design, GPU-VRAM contention is invisible to CPU/disk/RAM sweeps.
- **Kokoro's `:latest` GPU tag silently fails on Blackwell (RTX 50-series).** The container pulls, starts, and then dies on the first synthesis with `CUDA error: no kernel image is available for execution on the device` — `:latest` ships a CUDA 12.6 PyTorch build with kernels only through RTX 40-series (sm_90). It looks created (`docker ps` shows it, briefly) but crash-loops under `restart unless-stopped`. Fix: use the `v0.8.0-cu128` tag (CUDA 12.8, includes sm_120). `setup-kokoro-docker.ps1` defaults to it for this reason.
