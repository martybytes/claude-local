# claude-local — multi-OS sysadmin workspace

This repo is a home base for system-administration tasks across Windows, Linux, and macOS. One git checkout, synced across machines via push/pull. Per-machine artifacts (backups, logs) are gitignored so they don't collide.

This is not a code project. There's no app to build, no tests to run. Tasks are sysadmin-flavored: *change something on this machine safely*.

## Detect your platform first

The session-start system reminder includes `Platform: win32 | linux | darwin` (and `Shell:` and `OS Version:`). **Use that to decide what's eligible:**

| Platform value | Use skills/tools tagged | Primary shell |
|---|---|---|
| `win32` | `[windows]` and `[all]` | PowerShell |
| `linux` | `[linux]`, `[unix]`, and `[all]` | bash / zsh |
| `darwin` (macOS) | `[macos]`, `[unix]`, and `[all]` | zsh |
| WSL (linux + `$WSL_DISTRO_NAME` set, or `microsoft` in `/proc/version`) | treat as `linux`; flag any `/mnt/c/...` write — that path crosses into Windows | bash |

Each skill's `description` frontmatter starts with a bracketed scope tag (`[windows]`, `[linux]`, `[macos]`, `[unix]`, or `[all]`). Each tool header has a `.PLATFORM` field for the same purpose. **Honor the tag.** If asked to run a tool tagged for a different OS, refuse and explain why rather than silently doing nothing or quietly using the wrong tool.

## Per-OS conventions

### When on Windows (`Platform: win32`)

Primary tool: `PowerShell` (PowerShell 7+ / `pwsh`). `Bash` (Git for Windows) is fine for file ops and git. Avoid `cmd.exe`.

Safety:
- **Confirm before destructive system changes.** Stopping critical services, deleting registry keys, uninstalling packages, removing scheduled tasks — pause and confirm.
- **Back up the registry before edits.** Use `reg export <key> <path>.reg` before any `Set-ItemProperty` / `New-Item` / `Remove-Item` against the registry. Save backups to `backups\windows\registry\` (relative to repo root) with a timestamped filename.
- **HKLM requires explicit confirmation.** `HKCU` changes affect only this user and are reversible — proceed with normal care. `HKLM` (machine-wide) changes need a clear "yes go ahead" from the user before each write.
- **Never disable UAC, Defender, SmartScreen, or Windows Update** without an explicit instruction naming the thing to disable.
- **Don't auto-elevate.** If something needs admin (`HKLM`, system services, machine env vars), say so and let the user re-launch the shell elevated rather than chaining `Start-Process -Verb RunAs`.

### When on Linux (`Platform: linux`)

Primary tool: `Bash`. Detect distro via `/etc/os-release` to choose between `apt`, `dnf`, `pacman`, etc. Use `sudo` explicitly — never `sudo` silently.

Safety:
- **Confirm before destructive system changes.** Stopping `systemd` units the system depends on, removing packages, editing files under `/etc/`, modifying `/etc/fstab` or `/etc/sudoers`, killing processes — pause and confirm.
- **Back up files under `/etc/` before edits.** Copy to `backups/linux/etc/<timestamp>/` (relative to repo root) before editing in place.
- **System-wide changes require explicit confirmation.** Per-user changes (`~/.bashrc`, `~/.config/`, user systemd units under `~/.config/systemd/user/`) are reversible — proceed with care. System-wide changes (`/etc/`, system units, `apt` install/remove) need a clear "yes" from the user before each write.
- **Never modify SELinux/AppArmor enforcement, firewall rules, or sshd config** without an explicit instruction naming the thing.
- **Don't auto-elevate.** If a command needs `sudo`, print it and let the user run it; don't pipe to `sudo` silently.

### When on macOS (`Platform: darwin`)

Primary tool: `Bash` (zsh is the user shell; bash works fine for scripting). Homebrew is the package manager. SIP-protected paths (under `/System`, `/usr` except `/usr/local`) are read-only without disabling SIP — don't try to write there.

Safety:
- **Confirm before destructive system changes.** Unloading LaunchAgents/LaunchDaemons that the system uses, `defaults delete`, removing apps, killing processes — pause and confirm.
- **Back up before `defaults write` or plist edits.** Snapshot the current value (`defaults read <domain> <key>`) into `backups/macos/defaults/<timestamp>/<domain>.txt` so it can be reverted.
- **System-level launchd changes require explicit confirmation.** Per-user `~/Library/LaunchAgents/` is reversible — proceed with care. `/Library/LaunchDaemons/` and anything under `/Library/LaunchAgents/` (system-wide) needs a clear "yes" before each write.
- **Never disable Gatekeeper, SIP, FileVault, or the firewall** without an explicit instruction.
- **Don't auto-elevate.** If something needs `sudo`, print it.

### Conventions that apply on every OS

- **Prefer reversible changes.** A flip-back beats a reinstall. Note the inverse of every forward operation.
- **Don't bundle unrelated work in the same commit.** If you wandered, split.
- **A `PreToolUse` guard hook reminds you** when a command matches a destructive-system-change pattern (registry/HKLM, Defender/UAC, services, `/etc`, `systemctl`, firewall, SIP, `sudo`, …). It only warns — the normal permission prompt still applies. Treat its reminder as a cue to back up / confirm / note the inverse, not as approval.
- See [Completing a task](#completing-a-task) for the doc-update + commit workflow that applies everywhere.

## Where things live

All paths below are relative to the repo root.

- **Skills** — `.claude/skills/<name>/SKILL.md`. Each skill is one folder with a `SKILL.md` containing YAML frontmatter (`name`, `description`) and a tight body. Loaded automatically by Claude Code.
- **Commands** — `.claude/commands/<name>.md`. Slash commands invokable as `/<name>` in Claude Code. Each file describes what Claude should do when the command runs (the first line is the command's description).
- **Hooks** — `.claude/hooks/<name>.ps1`, registered in `.claude/settings.json`. `pwsh` scripts Claude Code runs automatically on events. Currently: `guard-destructive.ps1` (`PreToolUse` — warns on destructive system commands, never blocks) and `session-start.ps1` (`SessionStart` — injects the OS tool inventory + perf-capture monitor status). Cross-OS via `pwsh`; Linux/macOS need PowerShell installed (see `.claude/hooks/README.md`).
- **Agents** — `.claude/agents/<name>.md` (frontmatter `name`, `description`, optional `tools`/`model`). Subagents Claude can delegate to. Currently: `perf-analyst` (read-only capture-log analysis).
- **Tools** — `tools/<os>/<category>/<name>.ps1` (or `.sh` on Linux/macOS; `tools/unix/` for portable bash shared by Linux + macOS). Executable scripts. All paths inside scripts are relative (via `$PSScriptRoot` / `$(dirname "$0")`). See **Tool inventory** below.
- **Docs** — `docs/<os>/<name>.md`. Tracked (not gitignored) runbooks / root-cause diagnoses that accompany a tool or skill — the long-form "why + how to recover" a `SKILL.md` is too tight to hold (e.g. `docs/windows/scantopdf-lockup-runbook.md`).
- **Staging** — `staging/<os>/<area>/`. Config file edits that need elevation to copy into place (e.g. Nilesoft `.nss`, `.reg` files on Windows).
- **Backups** — `backups/<os>/<area>/<timestamp>/`. Gitignored. Timestamped snapshots before destructive changes.
- **Logs** — `logs/<os>/<category>/`. Gitignored. Output from tool runs that requested `-SaveLog`.
- **Persistent memory** — `~/.claude/projects/<project-slug>/memory/`. Auto-managed by Claude; lives outside this repo.

## Tool inventory

Tools live under `tools/<os>/<category>/`. The `SessionStart` hook (`.claude/hooks/session-start.ps1`) already injects this inventory for the current OS at session start, so you usually have it. To refresh it mid-session, list the tools for the current OS only:

```powershell
# Windows:
Get-ChildItem tools\windows -Recurse -Filter *.ps1 | Select-Object -ExpandProperty FullName

# Linux / macOS / WSL (Linux side):
find tools/linux tools/macos tools/unix -name '*.sh' 2>/dev/null
```

Then read the first 15 lines of each result. The `.SYNOPSIS`, `.PLATFORM`, and `.WHEN` header fields tell you what each script does and when to reach for it. Run scripts from the repo root:

```powershell
.\tools\<os>\<category>\<name>.ps1 [params]   # Windows
./tools/<os>/<category>/<name>.sh [params]     # Linux / macOS
```

Every script uses this header format — the `.WHEN` field is the trigger: what the user says that should make you reach for this tool. Skip scripts whose `.PLATFORM` doesn't match the current OS.

```powershell
<#
.NAME        <name>
.SYNOPSIS    <one line — what it does>
.PLATFORM    windows | linux | macos | unix | all
.CATEGORY    <category folder name>
.USAGE       .\tools\<os>\<category>\<name>.ps1 [params]
.WHEN        <what the user says that should trigger this tool>
#>
```

## Adding new skills

When a recurring task doesn't fit any existing skill, create a new one:

1. Pick a name that reflects scope. Use OS-prefixed kebab names for OS-specific skills (`windows-foo`, `linux-foo`, `macos-foo`); use a `unix-` prefix for Linux+macOS shared skills; otherwise no prefix for `[all]` skills.
2. Make `.claude/skills/<kebab-name>/SKILL.md` with frontmatter:

   ```markdown
   ---
   name: <kebab-name>
   description: "[scope] <one line — when this skill applies>"
   ---
   ```

   The `[scope]` token must be one of `[windows]`, `[linux]`, `[macos]`, `[unix]`, or `[all]`. Wrap the whole description in double quotes whenever the leading character is `[`, otherwise YAML parses it as a flow sequence.
3. Body should cover: when to use, key cmdlets/commands, safety notes, common patterns. Aim for 30–80 lines. Practical, not exhaustive.
4. Add a one-line entry to the skills table in README.md (in the OS section that matches the scope).
5. Commit. The skill is then auto-discovered in future sessions.

## Adding new tools

When a recurring task would benefit from a reusable script:

1. Pick the OS subdir (`tools/windows/`, `tools/linux/`, `tools/macos/`, or `tools/unix/` for portable bash) and a category folder under it (e.g. `diagnostics`, `network`, `system`, `startup`).
2. Add `<name>.ps1` (Windows) or `<name>.sh` (Unix) with the standard header block (see Tool inventory above), including the `.PLATFORM` field.
3. Use `$PSScriptRoot` (PS) or `$(cd "$(dirname "$0")" && pwd)` (bash) for all relative path resolution inside the script. Never hardcode absolute paths.
4. If the script produces output worth saving, write to `$repoRoot/logs/<os>/<category>/<timestamp>-<name>.txt` behind a `-SaveLog` switch.
5. Update the tools table in README.md.
6. Give the tool's category directory a `README.md` (e.g. `tools/windows/monitoring/README.md`) covering what the tool(s) there do, quick-start usage, config knobs, and safety notes — and link it from the root README's Tools section. Each tool directory should carry its own README linked from the root.

## Adding new hooks

When an event should trigger automatic behavior (safety reminders, session orientation, post-edit checks):

1. Write the logic as a `pwsh` script in `.claude/hooks/<name>.ps1` (pwsh runs on all three OSes). Read the hook JSON from stdin, keep it read-only unless intentionally gating, wrap in try/catch, and **always `exit 0`** unless you deliberately block (exit 2). Never break the session over a hook.
2. Register it in `.claude/settings.json` under the event (`PreToolUse`, `SessionStart`, …) with `pwsh -NoProfile -File "${CLAUDE_PROJECT_DIR}/.claude/hooks/<name>.ps1"`. Use a `matcher` (e.g. `Bash|PowerShell`) for `PreToolUse`.
3. To warn without blocking, emit `{"hookSpecificOutput":{"hookEventName":"<event>","additionalContext":"…"}}` — do NOT set `permissionDecision:"allow"` (that would skip the permission prompt).
4. Document it in `.claude/hooks/README.md` and the Hooks table in README.md.

## Adding new agents

When a sub-task benefits from isolation (big logs, parallel work, a narrow read-only role):

1. Create `.claude/agents/<name>.md` with frontmatter `name` + `description` (required), optionally `tools`, `model`, `color`. The body is the agent's system prompt.
2. Keep the tool list minimal and the role tight. State clearly if it is read-only.
3. Add a row to the Agents table in README.md.

## Completing a task

After any task that adds or modifies a tool, skill, command, staging file, or any other repo artifact:

1. **Verify** — smoke-test the change. Don't claim it works without running it.
2. **Update documentation** — if you added a skill, tool, or command, add a row to the relevant table in README.md and a one-line entry in the appropriate list in CLAUDE.md (if it isn't already there). If you modified one, update its description.
3. **Commit** — stage the changed files explicitly by name and commit with a clear message describing what changed and why. Use the `Co-Authored-By` trailer. Do not commit `backups/` or `logs/`.
4. **Push for successful improvements.** When the change is a real improvement to the project (new tool/skill/command, or material enhancement of one) and verification passed, push to origin. The `completing-an-improvement` skill encapsulates the full lifecycle including a "great commit message" guide. For partial work, debugging detours, or ad-hoc fixes that aren't repo improvements, don't auto-push — the user can run `/ship` when ready.

If a task was purely conversational (no files changed), skip 1–4.

## Existing skills

Each skill's `description` frontmatter starts with a scope tag — `[windows]`, `[linux]`, `[macos]`, `[unix]` (Linux+macOS), or `[all]`. Honor the tag: only use skills whose scope matches the current OS.

**Windows:**
- `windows-registry` — safe registry read/write with backup
- `windows-env-vars` — user/machine env vars and PATH editing
- `winget-packages` — install/upgrade/list/pin via winget
- `windows-services` — service inspection and control
- `windows-scheduled-tasks` — Task Scheduler via PowerShell
- `windows-system-settings` — common Win11 tweaks (taskbar, Explorer, dark mode, privacy)
- `windows-perf-diagnosis` — diagnose slow/unresponsive machine; interpret perf-snapshot output; known hogs
- `windows-startup-management` — audit Run keys, startup folders, logon scheduled tasks, auto-start services; triage what to disable
- `nilesoft-shell` — context-menu customization via Nilesoft Shell (.nss configs, register/unregister, themes)
- `windows-dev-environment` — git, SSH, WSL, language toolchains, PowerShell profile, VS Code on Windows
- `windows-hello-diagnosis` — diagnose and fix Windows Hello PIN/fingerprint failures; covers services, NGC folder, Azure AD device registration (`dsregcmd /forcerecovery`), hybrid key-trust-without-PKI (0xC00000BB → cloud Kerberos trust via `tools/windows/identity/`), Intune WHfB policy, TPM lockout

**Linux:**
- `linux-perf-diagnosis` — diagnose slow/unresponsive Linux box; interpret perf-snapshot.sh output
- `linux-systemd` — inspect/control systemd units; journalctl; critical-unit safety list
- `linux-packages` — distro-aware package management (apt/dnf/pacman) with hold/pin support
- `linux-env-vars` — per-user / system-wide env var locations; PATH editing; reload semantics

**macOS:**
- `macos-perf-diagnosis` — diagnose slow Mac / beachballs / fan noise; interpret perf-snapshot.sh output
- `macos-launchd` — inspect/control LaunchAgents and LaunchDaemons; plist authoring; SIP rules
- `macos-homebrew` — `brew` for formulae + casks; install/upgrade/pin; Brewfile snapshot/restore
- `macos-defaults` — read/write app + system preferences (Dock, Finder, Safari, NSGlobalDomain); killall to apply
- `macos-env-vars` — zsh hierarchy (`.zshrc`/`.zprofile`/`.zshenv`); `/etc/paths` and `paths.d`; GUI-app env via launchctl

**Linux + macOS (`[unix]`):**
- `unix-dev-environment` — git, SSH, language toolchains via mise/asdf, shell profile, VS Code on Linux/macOS

**Cross-platform (`[all]`):**
- `perf-capture` — catch intermittent ("comes and goes") slowdowns a one-shot snapshot misses: start an unattended background monitor, then analyze the log by timestamp; the spike-vs-calm fork
- `completing-an-improvement` — full ship cycle for a verified repo improvement: docs, commit, push

## Existing commands

- `/perf` — run a performance snapshot and get an interpreted summary; dispatches by Platform: win32 → `windows-perf-diagnosis`, linux → `linux-perf-diagnosis`, darwin → `macos-perf-diagnosis`
- `/capture` — `start`/`stop`/`status`/`analyze [HH:mm]` a background perf-capture for intermittent ("comes and goes") slowdowns; dispatches by Platform (win32 → `tools\windows\diagnostics\perf-{capture,analyze}.ps1`, linux/darwin → `tools/unix/diagnostics/perf-{capture,analyze}.sh`); interprets via the `perf-capture` skill + the OS perf-diagnosis skill
- `/startup` — audit startup items and recommend what to disable (Windows-only; no equivalent planned for Linux/macOS — startup vectors differ)
- `/disable-startup` — disable a startup item (preset like `LogiOptionsPlus`, or ad-hoc) reversibly via `disable-startup-item.ps1`; preview → confirm → apply → verify (Windows-only)
- `/gpu-tts` — diagnose whole-desktop/cursor stutter from GPU contention (local Kokoro/Chatterbox TTS + VRAM-pinned Ollama) via `tools\windows\diagnostics\gpu-tts-diagnose.ps1`; `quiet` remediates and `undo` reverses via `gpu-tts-quiet.ps1`; interprets with `windows-perf-diagnosis` + the [cursor-stall runbook](docs/windows/cursor-stall-gpu-tts-runbook.md) (Windows-only)
- `/ship` — commit any uncommitted work and push to the remote (cross-platform)
