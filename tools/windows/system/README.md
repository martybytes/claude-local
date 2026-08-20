# `tools/windows/system/`

Machine-level Windows configuration tasks that aren't diagnostics, startup, monitoring, or identity.

| Script | What it does |
|---|---|
| `install-mcp-servers.ps1` | Merge an `mcpServers` block into the Claude Desktop config so local/LAN MCP servers appear in Desktop chat **and** Cowork. MSIX-aware, backs up, previews by default, `-Undo` reverses. |
| `setup-kokoro-docker.ps1` | Create/start a local Kokoro TTS container reachable at `http://127.0.0.1:8880`. GPU-accelerated by default, previews by default, `-Undo` removes it. |

---

## `install-mcp-servers.ps1`

### Quick start

```powershell
.\tools\windows\system\install-mcp-servers.ps1              # preview — shows what would be written
.\tools\windows\system\install-mcp-servers.ps1 -Apply       # back up, then merge
.\tools\windows\system\install-mcp-servers.ps1 -Undo -Apply # remove the mcpServers key again
```

Fully quit and relaunch Claude Desktop afterwards (tray icon → Quit — closing the window is not enough).
The config is read only at startup.

### Why this isn't just "copy a file into place"

Three things make the naive approach fail silently:

1. **MSIX relocates the config.** Store builds don't use `%APPDATA%\Claude\` — that directory doesn't even
   exist. The real path is
   `%LOCALAPPDATA%\Packages\Claude_<hash>\LocalCache\Roaming\Claude\claude_desktop_config.json`. The script
   resolves it by package-family glob and falls back to the legacy path for Electron builds.
2. **The target file holds unrelated state.** `coworkUserFilesPath` and a large `preferences` object
   (Cowork trusted folders, session folder grants, per-account permission flags, starred spaces) live in the
   same file. The script merges rather than overwrites, and verifies nothing else moves.
3. **Bare `npx` won't spawn.** Claude Desktop launches commands without a shell, and `npx` is a `.cmd`
   batch file. The script rewrites `npx`/`npm`/`yarn`/`pnpm`/`bunx` launchers to `cmd /c <cmd> …`
   automatically, so the source config stays portable.

### Config knobs

| Parameter | Default | Notes |
|---|---|---|
| `-SourceConfig` | `%USERPROFILE%\.claude\mcp-servers.source.json`, then `%USERPROFILE%\Desktop\claude_desktop_config.json` | A standard `claude_desktop_config.json`-shaped file supplying the `mcpServers` block. |
| `-TargetConfig` | auto-detected | Override only for testing or an unusual install. |
| `-Apply` | off | Without it the script previews and writes nothing. |
| `-Undo` | off | Removes the `mcpServers` key. Still requires `-Apply` to write. |

### Safety notes

- **The source config lives outside this repo on purpose.** It carries API keys and service-account tokens
  in plaintext. Keeping it at `~/.claude/mcp-servers.source.json` means the script never needs secrets on a
  command line, and nothing sensitive is one `git add` away from being published. **Never commit it.**
- Every `-Apply` backs the target up to `backups/windows/claude-desktop/<timestamp>/` first (gitignored).
  Rollback is a file copy.
- No registry writes, no services, no elevation. Everything is per-user and reversible.

### See also

[`docs/windows/mcp-local-servers.md`](../../../docs/windows/mcp-local-servers.md) — the full runbook:
the local-vs-cloud execution boundary that decides which Claude surfaces can reach LAN servers at all,
the `mcp-remote` header quirk, Grafana's feature-gated `/api/mcp`, Claude Code wiring, and verification.

---

## `setup-kokoro-docker.ps1`

### Quick start

```powershell
.\tools\windows\system\setup-kokoro-docker.ps1               # preview — shows the docker pull/run it would use
.\tools\windows\system\setup-kokoro-docker.ps1 -Apply         # pull + create/start the 'kokoro' container
.\tools\windows\system\setup-kokoro-docker.ps1 -Cpu -Apply    # CPU-only image — no display-GPU contention
.\tools\windows\system\setup-kokoro-docker.ps1 -Undo -Apply   # remove the container (image stays cached)
```

Idempotent: re-running `-Apply` against an already-running container just reports it's up; against a
stopped one it `docker start`s rather than recreating.

### Why the GPU tag matters

The default GPU image tag is `v0.8.0-cu128`, not `:latest`. Kokoro-FastAPI's `:latest` tag ships a
PyTorch build compiled for CUDA 12.6, whose kernels only cover GTX 900 through RTX 40-series
(compute capability ≤ 9.0). On an RTX 50-series card (Blackwell, sm_120) it pulls fine, starts, and
then dies on the first inference with `CUDA error: no kernel image is available for execution on
the device` — the container looks created but never serves. `-GpuTag v0.8.0-cu128` uses the build
compiled with CUDA 12.8, which includes Blackwell kernels. Pass `-GpuTag v0.8.0-cu126` explicitly on
older (pre-Blackwell) cards if you want to pin rather than take the default.

### Config knobs

| Parameter | Default | Notes |
|---|---|---|
| `-Cpu` | off | Use `ghcr.io/remsky/kokoro-fastapi-cpu:latest` instead of the GPU image — slower, but zero contention with the display GPU (see the [cursor-stall runbook](../../../docs/windows/cursor-stall-gpu-tts-runbook.md)). |
| `-GpuTag` | `v0.8.0-cu128` | GPU image tag. Override to `v0.8.0-cu126` for GTX 900–RTX 40-series cards. Ignored with `-Cpu`. |
| `-Port` | `8880` | Host port mapped to the container's port 8880. |
| `-ContainerName` | `kokoro` | Matches what `gpu-tts-diagnose.ps1`/`gpu-tts-quiet.ps1` already look for. |
| `-Apply` | off | Without it the script previews and changes nothing. |
| `-Undo` | off | Removes the container (`docker rm -f`). Still requires `-Apply` to write. |

### Safety notes

- No registry writes, no services, no elevation — this is a per-user Docker Desktop container.
- `-Apply` on a fresh setup runs `docker pull` (network) then `docker run -d --restart unless-stopped
  --gpus all -p 8880:8880 <image>`; nothing is backed up because nothing existing is overwritten.
- `-Undo -Apply` removes the container but leaves the pulled image cached — run
  `docker rmi ghcr.io/remsky/kokoro-fastapi-gpu:v0.8.0-cu128` yourself to reclaim that disk space.
- Running the GPU image means every synthesis call shares the display GPU. If cursor/desktop
  stutter shows up afterward, that's exactly the scenario `gpu-tts-diagnose.ps1` and
  `gpu-tts-quiet.ps1` exist to catch and fix.

### See also

[`docs/windows/cursor-stall-gpu-tts-runbook.md`](../../../docs/windows/cursor-stall-gpu-tts-runbook.md) —
the GPU-contention runbook this script's container feeds into: how Kokoro competes with the display
GPU, and how to diagnose/quiet it once it's running.
