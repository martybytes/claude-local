<#
.NAME        proc-track
.SYNOPSIS    Track named processes' CPU% + disk I/O ops/sec + RAM over time to a log (and summarize it) — for measuring AV/EDR/security-agent overhead during real work.
.PLATFORM    windows
.CATEGORY    diagnostics
.USAGE       .\tools\windows\diagnostics\proc-track.ps1 [-Names a,b,c] [-IntervalSec 10] [-DurationMin 0] [-SpikeCpu 15] [-SpikeIops 2000]
             .\tools\windows\diagnostics\proc-track.ps1 -Summarize [-Path <log>]
.WHEN        You suspect a specific named process (antivirus, an EDR/RMM agent, a file watcher) is causing intermittent slowness and want its CPU + I/O sampled over a while, not a one-shot. Default tracks Microsoft Defender; add this machine's other agents with e.g.
             -Names MsMpEng,MpDefenderCoreService,endpointprotection,SnapAgent,ztac,agent,HUNTAgent,CagService
             Record during real work, then re-run with -Summarize to read the log back.
.NOTES       Read-only. Samples the pre-cooked CIM class Win32_PerfFormattedData_PerfProc_Process (CPU% + IODataOperationsPersec + IOOtherOperationsPersec) — cheap per interval and lets us track processes by name directly. (Note: the system-wide PerfOS_* classes / Get-Counter can momentarily take many seconds *while a heavy AV scan is thrashing WMI/disk* — that slowness is a symptom of the scan, not a standing fault; counters are ~1-2s when the box is calm.) I/O ops = read+write data ops PLUS "other" ops (file open/close/query) — the "other" count is the real tell for an AV scanning many files. CPU% is core-% (can exceed 100 across cores). Writes logs\windows\diagnostics\<ts>-proc-track.log and a .proc-track.pid. Stop: (Get-Content logs\windows\diagnostics\.proc-track.pid).Split('|')[0] | Stop-Process -Id {$_}  (or close the window).
#>
param(
    # Default = Microsoft Defender (present on every Windows box). Add this machine's third-party agents via -Names, e.g.
    #   Blackpoint: SnapAgent, ztac   ·   Datto: agent, HUNTAgent, CagService, AEMAgent   ·   other AV: endpointprotection
    [string[]]$Names  = @('MsMpEng','MpDefenderCoreService'),
    [int]$IntervalSec = 10,
    [int]$DurationMin = 0,      # 0 = run until stopped
    [double]$SpikeCpu = 15,     # flag a sample when any tracked proc's CPU >= this (core-%)
    [int]$SpikeIops   = 2000,   # ...or its disk I/O ops/sec (data+other) >= this
    [switch]$Summarize,         # analyze an existing proc-track log instead of recording
    [string]$Path               # log to summarize (default: most recent *-proc-track.log)
)

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..')
$logDir   = Join-Path $repoRoot 'logs\windows\diagnostics'

# ── Summarize mode: parse a recorded log into per-agent peaks/averages + worst burst ──────────────
if ($Summarize) {
    if (-not $Path) {
        $latest = Get-ChildItem (Join-Path $logDir '*-proc-track.log') -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { Write-Host "No proc-track logs in $logDir. Run the recorder first." -ForegroundColor Yellow; exit 1 }
        $Path = $latest.FullName
    }
    if (-not (Test-Path $Path)) { Write-Host "Log not found: $Path" -ForegroundColor Red; exit 1 }

    $tokenRx = '([A-Za-z0-9_.\-]+)\((-?\d+(?:\.\d+)?)%/(\d+)/(\d+)MB\)'
    $agg = @{}; $times = [System.Collections.Generic.List[string]]::new(); $spikeCount = 0; $samples = 0
    $worst = [pscustomobject]@{ Time=''; Name=''; Iops=-1; Cpu=0 }

    foreach ($l in (Get-Content $Path)) {
        if ($l -notmatch '^(\d{2}:\d{2}:\d{2}) \|') { continue }
        $samples++; $time = $Matches[1]; $times.Add($time)
        if ($l -match '\| SPIKE \|') { $spikeCount++ }
        foreach ($m in [regex]::Matches($l, $tokenRx)) {
            $n = $m.Groups[1].Value
            $cpu = [double]$m.Groups[2].Value; $iops = [int]$m.Groups[3].Value; $ram = [int]$m.Groups[4].Value
            if (-not $agg.ContainsKey($n)) { $agg[$n] = [pscustomobject]@{ Name=$n; CpuPeak=0.0; CpuSum=0.0; IopsPeak=0; IopsSum=0; RamPeak=0; Count=0 } }
            $a = $agg[$n]
            if ($cpu  -gt $a.CpuPeak)  { $a.CpuPeak  = $cpu }
            if ($iops -gt $a.IopsPeak) { $a.IopsPeak = $iops }
            if ($ram  -gt $a.RamPeak)  { $a.RamPeak  = $ram }
            $a.CpuSum += $cpu; $a.IopsSum += $iops; $a.Count++
            if ($iops -gt $worst.Iops) { $worst.Iops = $iops; $worst.Time = $time; $worst.Name = $n; $worst.Cpu = $cpu }
        }
    }
    if (-not $samples) { Write-Host "No parseable sample lines in $Path." -ForegroundColor Yellow; exit 1 }

    Write-Host "=== PROC-TRACK SUMMARY ===" -ForegroundColor Cyan
    Write-Host ("log    : {0}" -f (Split-Path $Path -Leaf))
    Write-Host ("span   : {0} -> {1}   samples={2}   SPIKE samples={3}" -f $times[0], $times[$times.Count-1], $samples, $spikeCount)
    if ($worst.Iops -ge 0) { Write-Host ("worst  : {0}  {1}  {2} iops / {3}% cpu" -f $worst.Time, $worst.Name, $worst.Iops, $worst.Cpu) -ForegroundColor Yellow }
    Write-Host "`n=== PER-AGENT (by peak I/O ops/sec) ===" -ForegroundColor Cyan
    $agg.Values | Sort-Object IopsPeak, CpuPeak -Descending | ForEach-Object {
        $cpuAvg  = if ($_.Count) { [math]::Round($_.CpuSum / $_.Count, 1) } else { 0 }
        $iopsAvg = if ($_.Count) { [int]($_.IopsSum / $_.Count) } else { 0 }
        Write-Host ("  {0,-26} cpuPeak={1,5}% cpuAvg={2,5}%   iopsPeak={3,6} iopsAvg={4,6}   ramPeak={5,5}MB  seen={6}x" -f `
            $_.Name, $_.CpuPeak, $cpuAvg, $_.IopsPeak, $iopsAvg, $_.RamPeak, $_.Count)
    }
    exit 0
}

# ── Record mode ───────────────────────────────────────────────────────────────────────────────────
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$ts       = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath  = Join-Path $logDir "$ts-proc-track.log"
$pidPath  = Join-Path $logDir '.proc-track.pid'
"$PID|$logPath" | Set-Content -Path $pidPath -Encoding ASCII

# Normalize -Names: `pwsh -File script.ps1 -Names a,b,c` passes ONE literal string (the -File
# parser does no type coercion), which silently produced a filter that matched nothing. Split on
# commas/semicolons/whitespace so both -File and -Command invocations bind the same way.
$Names = @($Names | ForEach-Object { $_ -split '[,;\s]+' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $Names.Count) { Write-Host 'No process names to track.' -ForegroundColor Red; exit 1 }

$like = ($Names | ForEach-Object { "Name LIKE '{0}%'" -f $_ }) -join ' OR '

function WriteLine([string]$s) { Add-Content -Path $logPath -Value $s; Write-Host $s }

WriteLine ("proc-track  started={0}  interval={1}s  tracking: {2}" -f (Get-Date -Format s), $IntervalSec, ($Names -join ', '))
WriteLine  "columns: HH:mm:ss | SPIKE | name(cpu%/iops/ramMB) ...   [iops = read+write+other file ops/sec]"

$endAt = if ($DurationMin -gt 0) { (Get-Date).AddMinutes($DurationMin) } else { [datetime]::MaxValue }

while ((Get-Date) -lt $endAt) {
    $t    = Get-Date
    $rows = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter $like -ErrorAction SilentlyContinue)
    $parts = @(); $spike = $false; $totCpu = 0.0; $totIops = 0
    foreach ($name in $Names) {
        $set = @($rows | Where-Object { $_.Name -like "$name*" })
        if (-not $set.Count) { continue }
        $cpu  = [math]::Round((($set | Measure-Object PercentProcessorTime -Sum).Sum), 1)
        $iops = [int]((($set | Measure-Object IODataOperationsPersec  -Sum).Sum) + (($set | Measure-Object IOOtherOperationsPersec -Sum).Sum))
        $ram  = [math]::Round((($set | Measure-Object WorkingSet -Sum).Sum / 1MB), 0)
        $totCpu += $cpu; $totIops += $iops
        if ($cpu -ge $SpikeCpu -or $iops -ge $SpikeIops) { $spike = $true }
        $parts += ('{0}({1}%/{2}/{3}MB)' -f $name, $cpu, $iops, $ram)
    }
    $flag = if ($spike) { 'SPIKE' } else { '     ' }
    WriteLine ('{0} | {1} | {2}   [ALL: {3}% cpu / {4} iops]' -f $t.ToString('HH:mm:ss'), $flag, ($parts -join '  '), [math]::Round($totCpu,1), $totIops)
    Start-Sleep -Seconds $IntervalSec
}
WriteLine ("proc-track stopped={0}" -f (Get-Date -Format s))
