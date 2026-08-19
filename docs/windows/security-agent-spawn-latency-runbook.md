# Runbook — "the whole machine is slow" from stacked security agents (process-spawn latency)

**Symptom.** WezTerm feels laggy, Claude Code agent turns crawl, everything takes a beat longer —
but Task Manager looks *fine*. CPU sits at 15%, disk queue is ~0, RAM is half free. Nothing is
obviously pegged, so the usual "find the hog" hunt turns up nothing.

**Diagnosis (measured 2026-08-19).** It is not a throughput problem. It is a **per-`CreateProcess`
latency tax** imposed by a stack of real-time security filters. Task Manager cannot show it because
no single process is consuming the time — the time is spent *blocked in kernel callbacks* while
each new process is inspected.

---

## 1. How to reproduce the measurement

Run these from the repo root. Nothing here needs admin.

```powershell
# 10-minute background capture while you do real work
.\tools\windows\diagnostics\proc-track.ps1 -Names MsMpEng,endpointprotection,wsc_agent,SnapAgent,ztac,HUNTAgent,agent,CagService,AEMAgent,wezterm,claude,node,git,pwsh,System,svchost -IntervalSec 3 -DurationMin 10
.\tools\windows\diagnostics\perf-capture.ps1 -IntervalSec 2 -DurationMin 10

# then
.\tools\windows\diagnostics\proc-track.ps1 -Summarize
.\tools\windows\diagnostics\perf-analyze.ps1
```

The decisive test is **spawn latency**, not CPU. Time N identical process launches and compare
against a healthy baseline (a machine with only Defender active):

```powershell
$ms = 1..12 | ForEach-Object { (Measure-Command { & cmd.exe /c exit }).TotalMilliseconds }
($ms | Sort-Object)[6]   # median
```

---

## 2. What the numbers looked like on this machine

32 cores, 93.6 GB RAM, NVMe. Sustained 5-minute agent-like load (414 rounds of spawn + file churn).

| Operation | Measured median | Healthy reference | Factor |
|---|---|---|---|
| `cmd.exe` spawn | **153 ms** (p95 274, max 3617) | ~10–15 ms | ~10–15x |
| `git.exe` spawn (`cmd\git.exe` shim) | **307 ms** (p95 648) | ~20–25 ms | ~12–15x |
| `pwsh.exe` spawn | **398 ms** (p95 1155, max 2115) | ~150–250 ms | ~2–3x |
| write an 8 KB file | **0.4 ms** (p95 6.4) | ~0.2–0.5 ms | ~1x — **fine** |

> Reference values are typical figures for an equivalent machine, not a control measured on this
> box. The *ratios between the tests on this machine* are the load-bearing evidence.

System-wide during that load: CPU avg **15.2%**, max 40.9%; disk queue max **0.2**; disk busy max
18%; RAM 46.6 / 93.6 GB. **Zero samples crossed a spike threshold.** The box was never short of
any resource — it was waiting.

Kernel time told the real story: the `System` process (where minifilter and process-notify
callbacks execute) averaged **36.6%** and peaked at **148%** core-CPU.

### The two costs, separated

A size sweep proves the cost is per-*process*, not per-*byte*:

| Binary | Size | Median spawn |
|---|---|---|
| `hostname.exe` | 0.04 MB | 205 ms |
| `cmd.exe` | 0.33 MB | 163 ms |
| `node.exe` | 87.45 MB | 311 ms |
| `git.exe` (40 KB shim, re-execs real git) | 0.04 MB | **575 ms** |
| `git.exe` (real, `mingw64\bin`) | 4.18 MB | 204 ms |

A 40 KB binary costs about the same as an 87 MB one — so this is **not** full-file hashing. But the
40 KB *shim*, which spawns a second process, costs roughly **double**. The tax is charged per
`CreateProcess` and **compounds with process-chain depth**.

A second, smaller cost applies to binaries the AV has never seen: copying `cmd.exe` to a new path
made its first launch **500 ms**, dropping to **157 / 155 ms** on the 2nd and 3rd. So ~345 ms is a
one-time new-executable scan; ~155 ms is the fixed per-spawn floor.

### Why this destroys agent work specifically

One Claude Code Bash tool call is a *chain*: `wezterm -> pwsh -> bash.exe -> git.exe (shim) -> git.exe (real)`.
At ~150–300 ms per link that is **~1 second of pure security overhead per tool call**, before any
work happens. Multiply by several concurrent sessions each running many tool calls.

---

## 3. Root cause — the filter stack

Eight filesystem minifilters are layered on this machine (`Altitude`, descending):

| Altitude | Filter | Product | Real-time cost |
|---|---|---|---|
| 389225.5 | `ZtacFltr` | **Blackpoint ZTAC** (Zero Trust Application Control) | gates every process launch |
| 385600 | `MsSecFlt` | Microsoft Defender for Endpoint (Sense) | telemetry |
| 385110 | `WtdFilter` | Microsoft Web Threat Defense | telemetry |
| 328010 | `WdFilter` | Microsoft Defender AV | loaded, but **passive** |
| 320500.7 / .6 | `rtp2` / `rtp1` | **Datto AV** real-time protection | scanning |
| 266211 | `BdSentry` | **Bitdefender** engine (used by Datto AV) | scanning |
| 265000 | `applockerfltr` | AppLocker | policy |

Plus user-mode agents: `endpointprotection.exe` / `wsc_agent.exe` (Datto AV, in
`C:\Program Files\infocyte\agent\dattoav\`), `agent.exe` (Datto EDR / Infocyte), `SnapAgent.exe` +
`ztac.exe` (Blackpoint), `CagService.exe` / `AEMAgent.exe` (Datto RMM / CentraStage).

**Defender is in Passive Mode** (`AMRunningMode: Passive Mode`, `RealTimeProtectionEnabled: False`)
because Datto AV registered as the primary AV. So *Defender exclusions barely matter for real-time
scanning* — the money is in the Datto AV and Blackpoint ZTAC policies.

### Blackpoint ZTAC indicts itself

`C:\Program Files (x86)\Blackpoint\ZTAC\agent.log` logs its own inspection stalls — 27 entries:

```
"msg":"excessive processing time: 6.728134 file: \??\C:\Program Files\Git\cmd\git.exe"
"msg":"excessive processing time: 8.121593 file: \??\C:\Program Files\Docker\cli-plugins\docker-dhi.exe"
"msg":"excessive processing time: 8.020358 file: \??\...\.rustup\toolchains\stable-...\bin\rust-lld.exe"   (x9)
"msg":"excessive processing time: 6.211618 file: \??\...\AppData\Local\GitKrakenCLI\gk.exe"
```

The worst offenders are exactly the developer toolchain: `git.exe`, `rust-lld.exe` (9 separate
hits), Docker CLI plugins, GitKraken CLI. ZTAC also computes an MD5 per binary (`FileMD5` appears
in its alert events) and evaluates rules even when the action is `REPORTED_ONLY` — i.e. it pays the
inline inspection cost even where it is not enforcing.

### An aggravating factor

`claude.exe` lives at `%USERPROFILE%\.local\bin\claude.exe` and is **314.8 MB**. A very large
executable in a *user-writable profile path* is the single most suspicious shape an AV/app-control
product can be shown, and it gets re-examined whenever it is updated.

---

## 4. The fix — exclusions, ranked

> **The most important thing to understand:** folder exclusions alone will **not** fix this. The
> dominant cost is process-creation interception, so it needs **process / publisher** allow rules.
> Folder exclusions fix the secondary cost (new-binary scans: builds, `npm install`, `cargo build`).

### Guiding principle for "highest level that is still safe"

Prefer, in this order:

1. **Publisher-certificate allow rules** — broader *and* safer than paths. "Trust binaries signed
   by Microsoft / OpenJS Foundation / Docker Inc" cannot be abused by dropping a file in a folder.
2. **Specific process-name exclusions** for the toolchain.
3. **A small number of top-level dev paths** — last resort, most abusable.

### Tier 1 — Blackpoint ZTAC (largest single win)

Ask the MSP / Blackpoint console owner to, for this endpoint (or a "developer workstation" device
group — **not** org-wide):

- Add **trusted-publisher** allow rules so signed toolchain binaries skip inline inspection:
  - `Microsoft Corporation` (pwsh, cmd, system utilities)
  - `OpenJS Foundation` (`node.exe`)
  - `Johannes Schindelin` (Git for Windows)
  - `Anthropic` (`claude.exe`)
  - `Docker Inc`
  - `Wez Furlong` / WezTerm
  - Rust Foundation / `rustup` toolchain binaries
- Add path allow rules for the toolchain roots ZTAC is already flagging:
  `C:\Program Files\Git\`, `C:\Program Files\nodejs\`, `C:\Program Files\PowerShell\7\`,
  `C:\Program Files\Docker\`, `C:\Program Files\WezTerm\`,
  `%USERPROFILE%\.rustup\`, `%USERPROFILE%\.cargo\`, `%USERPROFILE%\.local\bin\`
- Ask whether ZTAC can run **detect-only / low-latency mode** on this endpoint. The log already
  shows `Action: REPORTED_ONLY` rules that still cost inline time — that is latency bought for no
  enforcement.

### Tier 2 — Datto AV (Bitdefender engine: `BdSentry`, `rtp1`, `rtp2`)

**Process exclusions** (these buy the most):
`node.exe`, `git.exe`, `bash.exe`, `pwsh.exe`, `rg.exe`, `claude.exe`, `wezterm-gui.exe`,
`cargo.exe`, `rustc.exe`, `rust-lld.exe`, `docker.exe`

**Path exclusions** — the *highest level that is still defensible*:

| Path | Why it is safe to exclude |
|---|---|
| `C:\DATA\Workspace\` | The dev tree — 1.14 M files / 79 GB, source you author or clone. Not a download landing zone. Still covered by scheduled scans and EDR behavioral detection. |
| `%USERPROFILE%\.claude\` | Agent session state, very high write churn (7 089 files, 576 written in 24 h). Data, not an execution path. |
| `%LOCALAPPDATA%\Temp\claude\` | Agent scratchpad. **Scope to this subfolder — do *not* exclude all of `%TEMP%`.** |
| `%LOCALAPPDATA%\npm-cache\` | 62 533 files / 6.9 GB of package tarballs, re-read constantly. |
| `%APPDATA%\npm\` | Global npm shims. |
| `%USERPROFILE%\.cargo\`, `%USERPROFILE%\.rustup\` | Rust toolchain — source of 9 of the 27 ZTAC stalls. |

### Tier 3 — Microsoft Defender

Defender is passive, so this is mostly future-proofing plus making the scheduled quick scan
cheaper. Apply the same path list via `Add-MpPreference -ExclusionPath` (needs admin).

Separately worth raising with the security team: **`MsSecFlt` (Defender for Endpoint), Datto AV and
Blackpoint are three overlapping stacks.** If MDE is licensed and in use, whether Datto AV is still
needed is a real question — collapsing one layer would help more than any exclusion.

### Tier 4 — leave alone

Datto EDR (`agent.exe`, 4.6% CPU avg) and Blackpoint SnapAgent detection are your behavioral safety
net and are cheap. **Do not exclude or disable them** — they are what makes the exclusions above
acceptable.

---

## 5. What must NOT be excluded

- `C:\`, `C:\Users\`, `C:\Windows\`, `C:\Program Files\` wholesale
- `%TEMP%` / `%LOCALAPPDATA%\Temp` in full (scope to the `claude` subfolder only)
- `%USERPROFILE%\Downloads\` — new, untrusted executables land here
- Browser caches and mail stores
- Behavioral monitoring, EDR telemetry, tamper protection, or the firewall

## 6. Compensating controls that keep this safe

- Scope every exclusion to **this endpoint / a developer device group**, never the whole org.
- Keep **scheduled full scans** on — they still scan real-time-excluded paths.
- Keep **EDR behavioral detection** at full strength (it is path-independent).
- Prefer **publisher certificate** rules over path rules wherever the console supports it.
- Re-review the exclusion list quarterly and when the toolchain moves.

## 7. Verify the fix

Re-run the spawn benchmark after the MSP applies the changes. Targets:

- `cmd.exe` median **< 40 ms** (from 153 ms)
- `git.exe` median **< 80 ms** (from 307 ms)
- `System` process CPU average **< 10%** under load (from 36.6%)

If spawn latency does not move, the remaining cost is inline application control — go back to
Blackpoint about detect-only mode rather than adding more path exclusions.

## 8. Non-security follow-up spotted during this capture

`wezterm-gui.exe` averaged **25–29%** core-CPU with a 77% peak while mostly idle. That is high for
a terminal and is a separate thread to pull (GPU front-end / `front_end` setting, animation, or
too many panes). See also [cursor-stall-gpu-tts-runbook.md](cursor-stall-gpu-tts-runbook.md).
