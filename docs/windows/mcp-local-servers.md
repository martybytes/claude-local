# Local MCP servers on Windows — Claude Desktop, Cowork, and Claude Code

How to make MCP servers running on the local network (here: a Tailscale node) available to every Claude
surface that runs on this machine. Written after wiring seven servers on `quark` (100.94.21.96) into
Claude Desktop chat, Cowork, and Claude Code.

**Tool:** [`tools/windows/system/install-mcp-servers.ps1`](../../tools/windows/system/install-mcp-servers.ps1)

---

## The boundary that decides everything: local vs cloud execution

| Surface | Where the agent runs | Can it reach `100.x`/LAN? | Local MCP servers? |
|---|---|---|---|
| Claude Desktop chat | This machine | Yes | **Yes** |
| Cowork — *local execution* | This machine (code in a Hyper-V VM) | Yes | **Yes** |
| Cowork — *cloud execution* | Anthropic sandbox | **No** | No |
| claude.ai web / mobile | Anthropic cloud | **No** | No |
| Claude Code | This machine | Yes | **Yes** |

Per [Anthropic's Cowork architecture doc](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview),
the cloud sandbox "can't reach private, internal, link-local, or cloud-metadata addresses," and all egress
passes through a proxy it can't reconfigure. Local execution has no such restriction and supports locally
configured MCP servers by default (the `isLocalDevMcpEnabled` MDM key can disable them).

**Consequence:** a Tailscale CGNAT address (`100.64.0.0/10`) is unreachable from cloud surfaces, full stop.
Serving those surfaces means publishing each server to the public internet over HTTPS with auth and
registering it as a [custom connector](https://claude.com/docs/connectors/custom/remote-mcp) — Anthropic's
outbound range for allowlisting is `160.79.104.0/21`. That is a deliberate, separate decision with real
attack surface; nothing in this runbook does it.

---

## Gotcha 1: MSIX relocates the config

Claude Desktop from the Microsoft Store is an MSIX package, so `%APPDATA%` is redirected. The documented
path **does not exist** for this build:

```
%APPDATA%\Claude\claude_desktop_config.json          <-- legacy Electron/Squirrel build only
```

The real file for an MSIX install is under the package's `LocalCache`:

```
%LOCALAPPDATA%\Packages\Claude_<hash>\LocalCache\Roaming\Claude\claude_desktop_config.json
```

Dropping a config at the legacy path silently does nothing — no error, no servers. The install tool
resolves the MSIX path by package-family glob and falls back to the legacy path, so it works on both builds.

## Gotcha 2: the config holds more than MCP config

That same file carries `coworkUserFilesPath` and a large `preferences` object — Cowork trusted folders,
per-session folder grants, per-account permission-mode flags, starred spaces. **Overwriting the file to add
`mcpServers` destroys all of it**, silently. Always merge. The install tool merges and backs up to
`backups/windows/claude-desktop/<timestamp>/` first.

## Gotcha 3: bare `npx` doesn't spawn

Claude Desktop launches the command without a shell. `npx` on Windows is `npx.cmd`, a batch file, which
can't be launched directly — servers just fail to start. Route through `cmd`:

```json
{ "command": "cmd", "args": ["/c", "npx", "-y", "some-mcp-server"] }
```

The install tool applies this automatically for `npx`/`npm`/`yarn`/`pnpm`/`bunx`, so the source config stays
in portable form.

## Gotcha 4: `mcp-remote` headers containing spaces

`mcp-remote` mangles `--header` values containing spaces on Windows — which is every `Bearer <token>`.
Use the env-substitution form:

```json
{
  "args": ["-y", "mcp-remote", "https://host/mcp", "--header", "Authorization:${AUTH_HEADER}"],
  "env":  { "AUTH_HEADER": "Bearer glsa_..." }
}
```

Plain-HTTP targets additionally need `--allow-http --transport http-only`.

## Gotcha 5: Grafana's built-in MCP endpoint is feature-gated

Grafana 13.x can serve MCP at `/api/mcp`, but it is behind a feature toggle. **An unauthenticated `401`
from that path proves nothing** — Grafana answers `401` for any unauthenticated `/api/*` request, existent
or not. Probe it *with* the token: `404` means the toggle is off.

```powershell
Invoke-WebRequest https://grafana.example/api/mcp -Method POST -Headers @{Authorization="Bearer $tok"} -SkipHttpErrorCheck
```

With the toggle off, use the standalone [`grafana/mcp-grafana`](https://github.com/grafana/mcp-grafana)
binary over stdio instead — no server-side change needed:

```json
{
  "command": "C:\\Tools\\mcp-grafana\\mcp-grafana.exe",
  "env": { "GRAFANA_URL": "https://grafana.example", "GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa_..." }
}
```

---

## Where secrets live

MCP configs hold API keys and tokens in plaintext. This is inherent to the clients, not avoidable.

- **Canonical source:** `%USERPROFILE%\.claude\mcp-servers.source.json` — a standard
  `claude_desktop_config.json`-shaped file, deliberately **outside this repo**. The install tool reads it
  and defaults to it, so no secret ever has to be retyped or pasted into a command.
- Secrets also land in the packaged Desktop config and in `~/.claude.json` (Claude Code user scope).
- **Never commit any of them.** Don't leave a copy on the Desktop, where it's one screenshot or screen-share
  away from disclosure.

---

## Procedure

### Claude Desktop + Cowork

```powershell
.\tools\windows\system\install-mcp-servers.ps1              # preview
.\tools\windows\system\install-mcp-servers.ps1 -Apply       # merge + back up
```

Then **fully quit Claude Desktop** — tray icon → Quit, not just closing the window. Confirm `claude.exe`
and `cowork-svc` have exited, then relaunch. Config is read at startup only.

### Claude Code

User scope so every project inherits them. Claude Code speaks Streamable HTTP natively, so HTTP servers
skip the `mcp-remote` shim entirely — fewer processes, no Node per server:

```powershell
claude mcp add -s user -t http <name> http://host:port/mcp
claude mcp add -s user -t http <name> https://host/mcp --header "Authorization: Bearer $tok"
claude mcp add -s user <name> -e KEY=value -- npx -y some-mcp-server
```

Trailing slashes in URLs are preserved and can matter — `…/mcp/` is not `…/mcp`.

---

## Verification

```powershell
claude mcp list          # per-server health; performs a real initialize handshake
```

A bare `GET` against a Streamable-HTTP MCP endpoint returning **406 Not Acceptable** is *healthy* — the
server is refusing a request without `Accept: text/event-stream`. It is not an error.

End-to-end check that actually exercises a tool call:

```powershell
claude -p "Use the grafana MCP tool to list datasources. Be terse."
```

Per-surface:

- **Claude Code** — `claude mcp list`, or `/mcp` in-session.
- **Desktop chat** — `+` → Connectors; failures log to
  `…\LocalCache\Roaming\Claude\logs\mcp-server-<name>.log`.
- **Cowork** — start a fresh local session and ask it to list MCP tools.

### If Desktop chat sees the servers but Cowork doesn't

That's a known client bug, not a config error — see
[#23424](https://github.com/anthropics/claude-code/issues/23424), #26259, #27492 on local MCP servers not
being passed into the Cowork VM in some builds. Don't thrash on the config. Confirm the session is
**local execution** (cloud sessions can never see them), then check for an app update.

---

## Rollback

```powershell
.\tools\windows\system\install-mcp-servers.ps1 -Undo -Apply   # strip mcpServers, keep preferences
claude mcp remove -s user <name>                              # per server
```

Both directions are clean: no registry, no services, no elevation anywhere in this procedure.
