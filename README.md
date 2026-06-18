# claude-local

A Claude Code workspace for administering your machines — system settings, environment, software, services, scheduled jobs, dev tooling. One git checkout, synced across Windows, Linux, and macOS. Sysadmin-style asks; not an application.

When you open Claude Code in this directory on any machine, `CLAUDE.md` is auto-loaded. It detects the current OS from session context and tells Claude which skills, tools, and commands are eligible. Conversations pick up the conventions and tool knowledge without re-explaining each session.

## OS support matrix

| OS | Status | Skills available | Tools available |
|---|---|---|---|
| Windows 11 | ✅ Full | 11 (`windows-*`, `winget-packages`, `nilesoft-shell`) | 11 (perf ×4, startup ×3, monitoring ×4) |
| Linux | ✅ Baseline | 4 (`linux-perf-diagnosis`, `linux-systemd`, `linux-packages`, `linux-env-vars`) | 1 native + 2 shared (`tools/unix`) |
| macOS | ✅ Baseline | 5 (`macos-perf-diagnosis`, `macos-launchd`, `macos-homebrew`, `macos-defaults`, `macos-env-vars`) | 1 native + 2 shared (`tools/unix`) |
| WSL | ↪ Treated as Linux | inherits Linux scope; flags `/mnt/c/...` writes | inherits Linux |
| All OSes | ✅ | `completing-an-improvement`, `perf-capture` | `/ship` + `/capture` commands · 2 hooks · `perf-analyst` agent |

Each skill description starts with a `[scope]` tag — `[windows]`, `[linux]`, `[macos]`, `[unix]` (Linux+macOS), or `[all]`. Claude filters by current OS automatically; see the **Detect your platform first** section in `CLAUDE.md`.

## What this is

Five layers:

- **Skills** (`.claude/skills/`) — instruction files that tell Claude how to approach a task domain. Scope-tagged so Claude only uses ones that match the current OS.
- **Tools** (`tools/<os>/`) — executable scripts Claude can run directly (PowerShell on Windows, bash on Linux/macOS). Self-describing via header comments; Claude discovers them automatically via the Tool inventory section of `CLAUDE.md`.
- **Commands** (`.claude/commands/`) — slash commands that trigger multi-step workflows (e.g. `/perf`, `/capture`).
- **Hooks** (`.claude/hooks/`) — `pwsh` scripts Claude Code runs automatically on events: a `PreToolUse` safety guard (warns on destructive system commands) and a `SessionStart` orientation. Registered in `.claude/settings.json`.
- **Agents** (`.claude/agents/`) — subagents Claude can delegate to (e.g. `perf-analyst` for chewing through capture logs off the main context).

What it intentionally does **not** contain:

- No application code, build tooling, or tests.
- No persistent memory — that lives at `~/.claude/projects/<slug>/memory/`, outside this repo.

## Layout

```
claude-local/
├── CLAUDE.md                          # Workspace orientation + tool discovery instructions (auto-loaded)
├── README.md                          # You are here
├── .gitignore                         # Excludes backups/ and logs/
├── .claude/
│   ├── settings.json                  # Committed: hooks (guard + session-start), cross-OS via pwsh
│   ├── settings.local.json            # Per-machine permissions (optional)
│   ├── commands/                      # Slash commands (/perf, /startup, /disable-startup, /ship, /capture)
│   ├── hooks/                         # PreToolUse safety guard + SessionStart orientation (pwsh)
│   ├── agents/                        # Subagents (perf-analyst)
│   └── skills/                        # Domain skills, auto-discovered by name
│       ├── windows-registry/                # [windows]
│       ├── windows-env-vars/                # [windows]
│       ├── winget-packages/                 # [windows]
│       ├── windows-services/                # [windows]
│       ├── windows-scheduled-tasks/         # [windows]
│       ├── windows-system-settings/         # [windows]
│       ├── windows-dev-environment/         # [windows]
│       ├── unix-dev-environment/            # [unix] (Linux + macOS)
│       ├── nilesoft-shell/                  # [windows]
│       ├── windows-perf-diagnosis/          # [windows]
│       ├── windows-startup-management/      # [windows]
│       ├── windows-hello-diagnosis/         # [windows]
│       ├── perf-capture/                     # [all]
│       └── completing-an-improvement/        # [all]
├── docs/                              # Tracked runbooks / root-cause diagnoses, by OS
│   └── windows/
│       ├── scantopdf-lockup-runbook.md   # ScanToPDF lockup diagnosis + auto-recovery
│       ├── scantopdf-dashboard-guide.md  # ScanToPDF status dashboard — install/use/security
│       ├── cursor-stall-gpu-tts-runbook.md  # Cursor/desktop stutter from GPU TTS + Ollama VRAM — diagnose + fix
│       └── whfb-cloud-kerberos-trust-runbook.md  # Hello PIN 0xC00000BB on hybrid join — diagnosis + cloud-trust fix
├── tools/                             # Executable scripts, organized by OS
│   ├── windows/                       # PowerShell — .ps1
│   │   ├── diagnostics/
│   │   │   ├── perf-snapshot.ps1      # One-shot system snapshot
│   │   │   ├── perf-watch.ps1         # Continuous threshold monitor (interactive)
│   │   │   ├── perf-capture.ps1       # Unattended background monitor -> log (intermittent)
│   │   │   ├── perf-analyze.ps1       # Parse a capture log -> culprits + slow windows
│   │   │   ├── proc-track.ps1         # Track named procs' CPU+I/O over time (AV/EDR scan bursts); -Summarize reads it back
│   │   │   ├── gpu-tts-diagnose.ps1   # Read-only triage: GPU VRAM / TTS-container / Ollama contention (cursor stall)
│   │   │   ├── gpu-tts-quiet.ps1      # Reversible fix: disable TTS, stop GPU TTS containers, kill relays, unload Ollama
│   │   │   └── dev-allowlist.ps1      # Shared dev-tool allowlist (dot-sourced by perf-* for -ExcludeDev)
│   │   ├── startup/
│   │   │   ├── startup-inventory.ps1     # Read-only audit of every startup vector
│   │   │   ├── inspect-task.ps1          # Deep-dive on named scheduled task(s)
│   │   │   └── disable-startup-item.ps1  # Reversibly disable a startup item (presets; -Undo)
│   │   ├── monitoring/
│   │       ├── scantopdf-watchdog.ps1           # Self-healing watchdog for ScanToPDF
│   │       ├── install-scantopdf-watchdog.ps1   # Installer: SYSTEM task + event-log source + batch cap
│   │       ├── scantopdf-dashboard.ps1          # Read-only status dashboard (web server + HTML snapshot)
│   │       ├── scantopdf-dashboard.lib.ps1      # Dashboard collection + rendering (hot-reloaded by the server)
│   │       └── install-scantopdf-dashboard.ps1  # Installer: SYSTEM start-up task + urlacl + subnet firewall rule
│   │   └── identity/
│   │       ├── setup-whfb-cloud-kerberos-trust.ps1   # Server-side: create AzureADKerberos object (once per domain)
│   │       └── enable-whfb-cloud-trust-client.ps1    # Client pilot: UseCloudTrustForOnPremAuth=1 (-Undo reverts)
│   ├── linux/                         # bash — .sh (perf-snapshot.sh)
│   ├── macos/                         # bash — .sh (perf-snapshot.sh)
│   └── unix/                          # portable bash for Linux + macOS
│       └── diagnostics/
│           ├── perf-capture.sh        # Unattended background monitor -> log
│           └── perf-analyze.sh        # Parse a capture log -> culprits + slow windows
├── staging/                           # Edits ready to copy into protected dirs (elevated)
│   ├── windows/
│   │   ├── nilesoft/
│   │   │   ├── shell.nss
│   │   │   └── imports/
│   │   └── registry/
│   ├── linux/                         # systemd units, dotfiles, etc. (as needed)
│   └── macos/                         # plists, defaults exports (as needed)
├── logs/                              # GIT-IGNORED. Output from -SaveLog runs.
│   ├── windows/
│   ├── linux/
│   └── macos/
└── backups/                           # GIT-IGNORED. Timestamped snapshots before edits.
    ├── windows/
    ├── linux/
    └── macos/
```

## Skills

### Windows (`[windows]`)

| Skill | What it covers |
|---|---|
| [`windows-registry`](.claude/skills/windows-registry/SKILL.md) | Reading/writing the registry safely; `reg export` backup pattern; HKCU vs HKLM scope rules |
| [`windows-env-vars`](.claude/skills/windows-env-vars/SKILL.md) | User vs Machine env vars; PATH split-dedupe-rewrite pattern; `WM_SETTINGCHANGE` broadcast |
| [`winget-packages`](.claude/skills/winget-packages/SKILL.md) | Search/install/upgrade/list/pin/uninstall; export/import for snapshots |
| [`windows-services`](.claude/skills/windows-services/SKILL.md) | `Get-Service` / `Set-Service`; startup type; critical-service warning list |
| [`windows-scheduled-tasks`](.claude/skills/windows-scheduled-tasks/SKILL.md) | `Register-ScheduledTask`; logon vs daily vs startup triggers; SYSTEM vs interactive |
| [`windows-system-settings`](.claude/skills/windows-system-settings/SKILL.md) | Common Win11 tweaks (Explorer, taskbar, dark mode, privacy); restart-Explorer pattern |
| [`windows-dev-environment`](.claude/skills/windows-dev-environment/SKILL.md) | git config, SSH (ssh-agent service), WSL setup, Node/Python/Go/Rust/.NET install via winget+nvm-windows; PowerShell `$PROFILE`; VS Code; Windows Terminal |
| [`nilesoft-shell`](.claude/skills/nilesoft-shell/SKILL.md) | `.nss` syntax; CLI flags; runtime modifier shortcuts; reload mechanics |
| [`windows-perf-diagnosis`](.claude/skills/windows-perf-diagnosis/SKILL.md) | Diagnose slow/unresponsive machine; interpret snapshot output; known hogs and fixes |
| [`windows-startup-management`](.claude/skills/windows-startup-management/SKILL.md) | Audit startup items across Run keys / folders / scheduled tasks / services; triage tiers; disable patterns |
| [`windows-hello-diagnosis`](.claude/skills/windows-hello-diagnosis/SKILL.md) | Diagnose and fix Windows Hello PIN/fingerprint failures — services, NGC corruption, Azure AD device registration (`dsregcmd /forcerecovery`), hybrid key-trust-without-PKI (0xC00000BB → cloud Kerberos trust), Intune WHfB policy, TPM lockout |

### Linux (`[linux]`)

| Skill | What it covers |
|---|---|
| [`linux-perf-diagnosis`](.claude/skills/linux-perf-diagnosis/SKILL.md) | Diagnose slow/unresponsive Linux box; interpret `perf-snapshot.sh` output; hogs and triage tree |
| [`linux-systemd`](.claude/skills/linux-systemd/SKILL.md) | Inspect/control systemd units (system + user); enable/disable/mask; journalctl; critical-unit safety list |
| [`linux-packages`](.claude/skills/linux-packages/SKILL.md) | Distro-aware package management — apt (Debian/Ubuntu), dnf (Fedora/RHEL), pacman (Arch); install/remove/upgrade/hold/pin |
| [`linux-env-vars`](.claude/skills/linux-env-vars/SKILL.md) | `.profile` / `.bashrc` / `.zshrc` / `/etc/environment` / `/etc/profile.d/`; PATH editing; reload semantics |

### macOS (`[macos]`)

| Skill | What it covers |
|---|---|
| [`macos-perf-diagnosis`](.claude/skills/macos-perf-diagnosis/SKILL.md) | Diagnose slow Mac / beachballs / fan noise; interpret `perf-snapshot.sh` output; common hogs (kernel_task, WindowServer, mds_stores) |
| [`macos-launchd`](.claude/skills/macos-launchd/SKILL.md) | LaunchAgents vs LaunchDaemons; bootstrap/bootout; plist authoring; SIP-protected paths; critical-service list |
| [`macos-homebrew`](.claude/skills/macos-homebrew/SKILL.md) | `brew` for formulae + casks; install/upgrade/pin/cleanup; tap; Brewfile; Apple Silicon vs Intel paths |
| [`macos-defaults`](.claude/skills/macos-defaults/SKILL.md) | `defaults read/write` for Dock/Finder/Safari/NSGlobalDomain; killall to apply; backup pattern |
| [`macos-env-vars`](.claude/skills/macos-env-vars/SKILL.md) | zsh hierarchy (`.zshrc`/`.zprofile`/`.zshenv`); `/etc/paths` and `paths.d/`; `launchctl setenv` for GUI |

### Linux + macOS (`[unix]`)

| Skill | What it covers |
|---|---|
| [`unix-dev-environment`](.claude/skills/unix-dev-environment/SKILL.md) | git config + credential helpers (libsecret on Linux, osxkeychain on macOS); SSH (ssh-agent on Linux/macOS); language runtimes via mise/asdf or native pkg managers; bash/zsh shell profiles; VS Code; terminal emulators |

### Cross-platform (`[all]`)

| Skill | What it covers |
|---|---|
| [`perf-capture`](.claude/skills/perf-capture/SKILL.md) | Catch intermittent ("comes and goes") slowdowns a one-shot snapshot misses: start an unattended background monitor, then analyze the log by timestamp; the spike-vs-calm fork |
| [`completing-an-improvement`](.claude/skills/completing-an-improvement/SKILL.md) | End-to-end ship cycle for a verified repo improvement: smoke-test, doc updates, commit (with great-message guide), push |

## Tools

Scripts Claude can run directly. All paths are relative — no hardcoded machine paths. Filtered by `.PLATFORM` against the current OS.

### Windows (`tools/windows/`)

| Script | What it does | Key params |
|---|---|---|
| `tools/windows/diagnostics/perf-snapshot.ps1` | One-shot snapshot: CPU, RAM, disk, pagefile, power plan, top processes, known-hog check | `-Top <n>`, `-SaveLog`, `-ExcludeDev`, `-Exclude <names>`, `-OnlyDev` |
| `tools/windows/diagnostics/perf-watch.ps1` | Continuous monitor; highlights processes crossing CPU % or RAM MB thresholds (interactive, console) | `-IntervalSec`, `-CpuThreshold`, `-RamThresholdMb`, `-ExcludeDev`, `-Exclude <names>`, `-OnlyDev` |
| `tools/windows/diagnostics/perf-capture.ps1` | Unattended background monitor; appends timestamped CPU/disk/RAM samples + spike flag to a log (for intermittent slowdowns); writes a PID file | `-IntervalSec`, `-CpuPct`, `-DiskQ`, `-DurationMin` |
| `tools/windows/diagnostics/perf-analyze.ps1` | Parse a perf-capture log into ranked culprits, slow-time windows, and an optional time-focused view | `-Path`, `-Around HH:mm`, `-WindowMin`, `-CpuPct`, `-ExcludeDev`, `-Exclude <names>`, `-OnlyDev` |
| `tools/windows/diagnostics/proc-track.ps1` | Track named processes' CPU% + file-I/O ops/sec + RAM over time to a log (catches AV/EDR scan bursts that `perf-capture`'s CPU/disk-queue thresholds miss — high IOPS, low queue); `-Summarize` reads the log back | `-Names`, `-IntervalSec`, `-DurationMin`, `-SpikeCpu`, `-SpikeIops`, `-Summarize`, `-Path` |
| `tools/windows/diagnostics/gpu-tts-diagnose.ps1` | Read-only triage for cursor/desktop stutter from **GPU contention** (VRAM saturation, GPU TTS containers, Ollama keep-alive, Claude Code TTS hooks, hung relays) — flags causes + verdict when CPU/disk/RAM look idle. See [runbook](docs/windows/cursor-stall-gpu-tts-runbook.md) | `-SaveLog` |
| `tools/windows/diagnostics/gpu-tts-quiet.ps1` | **Reversible** remediation: disable Claude TTS (backed up), stop GPU TTS containers, kill hung relays, unload idle Ollama models; previews by default | `-All`, `-DisableClaudeTts`, `-StopTtsContainers`, `-KillHungRelays`, `-UnloadOllama`, `-Apply`, `-Undo` |
| `tools/windows/diagnostics/dev-allowlist.ps1` | Shared dev-tool allowlist + matcher (`node`/Docker+WSL/PowerToys/Tailscale); dot-sourced by the perf-* tools to power `-ExcludeDev`. Not run directly | _(library — dot-sourced)_ |
| `tools/windows/startup/startup-inventory.ps1` | Read-only audit: Run keys (incl. WOW6432), startup folders, logon/boot tasks, auto-start services, with enable/disable state | `-IncludeMicrosoftTasks`, `-SaveLog` |
| `tools/windows/startup/inspect-task.ps1` | Show full details of named scheduled task(s): action, principal, triggers | `-Name <task>[,<task>...]` |
| `tools/windows/startup/disable-startup-item.ps1` | Reversibly disable a startup item (auto-start service + Run entry + processes); backs up first, prints a `RunAs` block instead of auto-elevating, `-Undo` reverses. Ships a `LogiOptionsPlus` preset | `-Preset`, `-Service`, `-RunEntry`, `-KillProcess`, `-Undo`, `-DryRun` |
| `tools/windows/monitoring/scantopdf-watchdog.ps1` | Self-healing watchdog for ScanToPDF: restarts the stopped service, kills the hung UI / orphaned OCR engines, quarantines oversized poison PDFs, alerts to Teams + event log | `-DryRun`, `-SaveLog`, `-QuarantineSizeMB`, `-NoAlert` |
| `tools/windows/monitoring/install-scantopdf-watchdog.ps1` | Installs the watchdog: registers the SYSTEM scheduled task, ensures the event-log source, provisions the Teams webhook, caps `maxBatchCount`. Run elevated | `-DryRun`, `-IntervalMinutes`, `-BatchCap`, `-WebhookUrl`, `-Uninstall` |
| `tools/windows/monitoring/scantopdf-dashboard.ps1` | Read-only ScanToPDF status dashboard: a tiny web server (`-Serve`) + static `status.html`/`status.json` snapshot (`-Once`) — service health, watchdog, OCR, activity, queue. PII-safe by default | `-Serve`, `-Once`, `-Port`, `-SharePath`, `-ShowFilenames` |
| `tools/windows/monitoring/install-scantopdf-dashboard.ps1` | Installs the dashboard: SYSTEM start-up task + URL ACL + subnet-scoped inbound firewall rule. Run elevated | `-Subnet` (required), `-Port`, `-SharePath`, `-DryRun`, `-Uninstall` |
| `tools/windows/identity/setup-whfb-cloud-kerberos-trust.ps1` | One-time server-side WHfB cloud Kerberos trust setup: creates the `AzureADKerberos` object + `krbtgt_AzureAD` in on-prem AD so Entra issues partial TGTs. Run as Domain Admin (+ Entra admin sign-in) | `-Domain`, `-UserPrincipalName` |
| `tools/windows/identity/enable-whfb-cloud-trust-client.ps1` | Client-side cloud-trust pilot: backs up then sets `UseCloudTrustForOnPremAuth=1` (HKLM policy), starts `WbioSrvc` if stopped. Run elevated | `-Undo` |

📁 **Per-directory guides:** [`diagnostics/`](tools/windows/diagnostics/README.md) · [`startup/`](tools/windows/startup/README.md) · [`monitoring/`](tools/windows/monitoring/README.md) (ScanToPDF watchdog + status dashboard; [lockup runbook](docs/windows/scantopdf-lockup-runbook.md) · [dashboard guide](docs/windows/scantopdf-dashboard-guide.md)) · [`identity/`](tools/windows/identity/README.md) (WHfB cloud Kerberos trust; [runbook](docs/windows/whfb-cloud-kerberos-trust-runbook.md))

### Linux (`tools/linux/`)

| Script | What it does | Key params |
|---|---|---|
| `tools/linux/diagnostics/perf-snapshot.sh` | One-shot snapshot: distro, kernel, load, CPU, RAM, swap, disk, top processes by CPU+RAM, known-hog check | `-t TOP` (default 15), `-l` (save log) |

📁 **Per-directory guide:** [`diagnostics/`](tools/linux/diagnostics/README.md)

### macOS (`tools/macos/`)

| Script | What it does | Key params |
|---|---|---|
| `tools/macos/diagnostics/perf-snapshot.sh` | One-shot snapshot: macOS version, model + chip (Apple Silicon perf/efficiency cores), memory (`vm_stat`), swap, disks, power/battery, top by CPU+RAM, Mac-specific known-hog check (kernel_task, WindowServer, mds_stores, etc.) | `-t TOP` (default 15), `-l` (save log) |

📁 **Per-directory guide:** [`diagnostics/`](tools/macos/diagnostics/README.md)

### Linux + macOS (`tools/unix/`)

Portable bash, used by both Linux and macOS (the `/capture` command dispatches here for `linux` and `darwin`). OS-specific bits branch internally on `uname`.

| Script | What it does | Key params |
|---|---|---|
| `tools/unix/diagnostics/perf-capture.sh` | Unattended background monitor; appends timestamped CPU/load/mem samples + spike flag to a log (intermittent slowdowns); writes a PID file | `-i INTERVAL`, `-c CPU_PCT`, `-d DURATION_MIN`, `-t TOP` |
| `tools/unix/diagnostics/perf-analyze.sh` | Parse a perf-capture log into ranked culprits, slow-time windows, and an optional time-focused view | `-p LOG`, `-a HH:MM`, `-w WINDOW_MIN`, `-c CPU_PCT` |

📁 **Per-directory guide:** [`diagnostics/`](tools/unix/diagnostics/README.md)

## Commands

| Command | OS scope | What it does |
|---|---|---|
| `/perf` | All (Windows + Linux + macOS) | Run perf-snapshot, interpret output, return top issues + recommended actions; dispatches by `Platform:` |
| `/capture` | All (Windows + Linux + macOS) | `start`/`stop`/`status`/`analyze [HH:mm]` a background perf-capture for intermittent ("comes and goes") slowdowns; dispatches by `Platform:` |
| `/startup` | Windows only | Run startup-inventory, classify items into disable / investigate / leave-alone tiers, stage commands |
| `/gpu-tts` | Windows only | Diagnose cursor/desktop stutter from GPU contention (local TTS + Ollama VRAM); `quiet` to fix, `undo` to reverse |
| `/disable-startup` | Windows only | Disable a startup item (preset or ad-hoc) via `disable-startup-item.ps1`: preview → confirm → apply → verify; `-Undo` to reverse |
| `/ship` | All | Commit any uncommitted work (with doc check) and push to the remote |

## Hooks

Project-scoped hooks in `.claude/hooks/`, registered in [`.claude/settings.json`](.claude/settings.json). Written in `pwsh` so one committed config works on all three OSes (Linux/macOS need PowerShell installed — see [`.claude/hooks/README.md`](.claude/hooks/README.md)). Both are read-only and always exit 0; they observe and remind, never block.

| Hook | Event | What it does |
|---|---|---|
| `guard-destructive.ps1` | `PreToolUse` (`Bash`/`PowerShell`) | **Warns** (never blocks, never auto-approves) when a command matches a destructive-system-change rule — HKLM/registry deletes, disabling Defender/UAC/SmartScreen/Windows Update, stopping services; `rm -rf` on system paths, `/etc` edits, `systemctl disable/mask`, firewall/SELinux, SIP/Gatekeeper/FileVault, `sudo`, disk/format ops. The normal permission prompt still applies. |
| `session-start.ps1` | `SessionStart` | Injects an OS-filtered tool inventory (name + synopsis) and reports whether a `perf-capture` monitor is already running. Automates the "list tools at session start" step from `CLAUDE.md`. |

## Agents

Subagents in `.claude/agents/`. Invoke by naming them, or Claude delegates automatically.

| Agent | What it does |
|---|---|
| [`perf-analyst`](.claude/agents/perf-analyst.md) | Read-only. Analyzes a `perf-capture` log (runs `perf-analyze`, correlates a reported slow time) and returns a ranked culprit list + a clear spike-vs-calm verdict — keeps large logs out of the main context. |

## How a session typically works

1. Open Claude Code in this directory on whichever machine you're on.
2. Claude reads `Platform: win32 | linux | darwin` from the session's system reminder and filters skills/tools to the matching `[scope]`.
3. Ask in natural language — "why is my machine slow", "remove the AMD entry from the right-click menu", "set up scheduled defrag at 3am" (Windows); "what's holding port 8080" / "make this systemd unit start at boot" (Linux); etc.
4. For changes that need elevation (Windows: HKLM, services, machine env vars, `Program Files`; Linux/macOS: anything under `/etc`, system units, system-wide installs): Claude proposes the change, stages files in `staging/<os>/<area>/`, takes a backup in `backups/<os>/<area>/<timestamp>/`, and prints a one-line elevated command for you to paste into an admin/sudo shell.
5. Reversible local changes (per-user registry, user env vars, user packages, dotfile edits, file ops) execute directly.
6. When performance/slowness/resource issues come up, Claude auto-discovers `tools/<os>/diagnostics/` scripts and runs the appropriate one.

## Conventions

Every OS:
- **Honor the `[scope]` tag.** Don't reach for a Windows skill on Linux, or vice versa.
- **Back up before destructive edits.** Snapshot to `backups/<os>/<area>/<ts>/...`.
- **Don't auto-elevate.** Stage and hand back the `Start-Process -Verb RunAs` / `sudo ...` command.
- **Note the inverse** of any forward operation.
- **All tool scripts use relative paths via `$PSScriptRoot` (PS) or `$(dirname "$0")` (bash).** Never hardcode absolute paths to the repo.

OS-specific safety rules live in `CLAUDE.md` under **Per-OS conventions** — those override or extend the above for HKLM (Windows), `/etc/` and systemd (Linux), and SIP/launchd (macOS).

## Adding to the workspace

**New skill:** `.claude/skills/<kebab-name>/SKILL.md` with frontmatter + body. Description must start with a `[scope]` tag (`[windows]`, `[linux]`, `[macos]`, `[unix]`, or `[all]`) — wrap in double quotes since YAML treats leading `[` as a flow sequence. Use OS-prefixed names (`windows-foo`, `linux-foo`, `macos-foo`, `unix-foo`) for OS-specific skills. Add a row to the matching subtable above and to `CLAUDE.md`.

**New tool:** `tools/<os>/<category>/<name>.ps1` (or `.sh` for Linux/macOS) with the standard header block (`.NAME`, `.SYNOPSIS`, `.PLATFORM`, `.CATEGORY`, `.USAGE`, `.WHEN`). Add a row to the tools table above. Claude discovers it automatically next session via `CLAUDE.md`.

**New command:** `.claude/commands/<name>.md` describing the workflow (first line = its description). Add a row to the commands table above.

**New hook:** add a `pwsh` script to `.claude/hooks/` and register it in `.claude/settings.json` under the right event (`PreToolUse`, `SessionStart`, …). Keep it read-only and non-blocking unless intentionally gating. Document it in `.claude/hooks/README.md` and add a row to the Hooks table above.

**New agent:** `.claude/agents/<name>.md` with `name` + `description` frontmatter (optionally `tools`, `model`, `color`). Add a row to the Agents table above.

## Reference

- `everything-claude-code` (at `C:\DATA\Workspace-public\everything-claude-code` if present) — blueprint repo with 300+ skills / 50+ agents / 80+ commands. Consult as a library; don't auto-pull.
- [Nilesoft Shell](https://nilesoft.org) — source of truth for `.nss` syntax used by the `nilesoft-shell` skill.
