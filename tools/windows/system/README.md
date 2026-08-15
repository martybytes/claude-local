# `tools/windows/system/`

Machine-level Windows configuration tasks that aren't diagnostics, startup, monitoring, or identity.

| Script | What it does |
|---|---|
| `install-mcp-servers.ps1` | Merge an `mcpServers` block into the Claude Desktop config so local/LAN MCP servers appear in Desktop chat **and** Cowork. MSIX-aware, backs up, previews by default, `-Undo` reverses. |

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
