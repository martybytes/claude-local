Diagnose (and optionally fix) whole-desktop cursor stutter caused by GPU contention from a local TTS service or a VRAM-pinned Ollama model. Windows-only.

Argument (optional): `$ARGUMENTS` — `quiet` to remediate, `undo` to reverse, otherwise just diagnose.

Steps:
1. Confirm `Platform: win32`. If not Windows, stop and say this is Windows-only (Linux/macOS don't have this Kokoro/Ollama-on-the-display-GPU stack).
2. **Always diagnose first** — run `.\tools\windows\diagnostics\gpu-tts-diagnose.ps1` (read-only). Interpret with the `windows-perf-diagnosis` skill (the "GPU VRAM contention from local TTS" section) and the runbook `docs\windows\cursor-stall-gpu-tts-runbook.md`.
3. Report the verdict tightly: VRAM %, which adapter holds it, any running GPU TTS container, whether Claude TTS is enabled, and any hung relays. Name the single most likely cause.
4. Then branch on `$ARGUMENTS`:
   - **(no arg / `diagnose`)** — stop after the diagnosis. Show the exact `gpu-tts-quiet.ps1` command you'd run and ask before changing anything.
   - **`quiet`** — preview with `.\tools\windows\diagnostics\gpu-tts-quiet.ps1`, then, on confirmation, `gpu-tts-quiet.ps1 -All -Apply`. Mention the config backup path it writes.
   - **`undo`** — run `.\tools\windows\diagnostics\gpu-tts-quiet.ps1 -Undo` to re-enable Claude TTS and restart the TTS containers.
5. For durable VRAM headroom, point at the Ollama `OLLAMA_KEEP_ALIVE=10m` recreate step in the runbook — it's machine-specific, so confirm before recreating the container.

Keep it tight: findings, the one cause, the one action. No preamble.
