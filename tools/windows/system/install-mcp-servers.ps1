<#
.NAME        install-mcp-servers
.SYNOPSIS    Merge an mcpServers block into the Claude Desktop config (MSIX-aware), wrapping npx launchers so they spawn reliably on Windows. Previews by default; -Undo removes the block.
.PLATFORM    windows
.CATEGORY    system
.USAGE       .\tools\windows\system\install-mcp-servers.ps1 [-SourceConfig <path>] [-Apply] [-Undo] [-TargetConfig <path>]
.WHEN        User wants local MCP servers available in Claude Desktop chat or Cowork, says "my MCP servers don't show up in Claude Desktop/Cowork", or moved to a new machine and needs the MCP config reinstalled.
#>
[CmdletBinding()]
param(
    # Client-neutral claude_desktop_config.json holding the mcpServers block to install.
    # Kept OUTSIDE this repo because it carries API keys and tokens.
    [string]$SourceConfig,

    # Explicit target. Normally auto-detected (MSIX package path, then legacy %APPDATA%).
    [string]$TargetConfig,

    # Write the change. Without this the script only previews.
    [switch]$Apply,

    # Remove the mcpServers key from the target config (backs up first).
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))

function Resolve-SourceConfig {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "Source config not found: $Explicit" }
        return (Resolve-Path $Explicit).Path
    }
    $candidates = @(
        (Join-Path $env:USERPROFILE '.claude\mcp-servers.source.json'),
        (Join-Path $env:USERPROFILE 'Desktop\claude_desktop_config.json')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return (Resolve-Path $c).Path } }
    throw "No source config found. Looked in:`n  $($candidates -join "`n  ")"
}

function Resolve-TargetConfig {
    param([string]$Explicit)
    if ($Explicit) { return $Explicit }

    # MSIX / Microsoft Store build redirects %APPDATA% into the package LocalCache.
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    $msix = Get-ChildItem $pkgRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json' } |
        Where-Object { Test-Path (Split-Path -Parent $_) } |
        Select-Object -First 1
    if ($msix) { return $msix }

    # Legacy Electron/Squirrel build.
    $legacy = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    if (Test-Path (Split-Path -Parent $legacy)) { return $legacy }

    throw 'Could not locate a Claude Desktop config directory (checked MSIX package LocalCache and %APPDATA%\Claude).'
}

function New-Backup {
    param([string]$Path)
    $ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $repoRoot "backups\windows\claude-desktop\$ts"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (Test-Path $Path) { Copy-Item $Path (Join-Path $dir 'claude_desktop_config.json') -Force }
    return $dir
}

# Claude Desktop on Windows spawns the command without a shell, so a bare "npx"
# (which is npx.cmd, a batch file) fails to launch. Route it through cmd /c.
function ConvertTo-WindowsLauncher {
    param([psobject]$Server)
    $cmd  = $Server.command
    $argv = @()
    if ($null -ne $Server.args) { $argv = @($Server.args) }

    if ($cmd -in @('npx', 'npm', 'yarn', 'pnpm', 'bunx')) {
        $out = [ordered]@{ command = 'cmd'; args = @('/c', $cmd) + $argv }
    } else {
        $out = [ordered]@{ command = $cmd }
        if ($argv.Count -gt 0) { $out.args = $argv }
    }
    if ($null -ne $Server.env) { $out.env = $Server.env }
    return [pscustomobject]$out
}

$target = Resolve-TargetConfig -Explicit $TargetConfig
Write-Host "Target config : $target"

if (-not (Test-Path $target)) { throw "Target config file does not exist: $target" }
$targetJson = Get-Content $target -Raw | ConvertFrom-Json -Depth 100

# ---------------------------------------------------------------- Undo
if ($Undo) {
    if (-not $targetJson.PSObject.Properties.Name.Contains('mcpServers')) {
        Write-Host 'Nothing to undo: target config has no mcpServers key.' -ForegroundColor Yellow
        return
    }
    $names = @($targetJson.mcpServers.PSObject.Properties.Name)
    Write-Host "Would remove mcpServers ($($names.Count)): $($names -join ', ')" -ForegroundColor Yellow
    if (-not $Apply) { Write-Host 'Preview only. Re-run with -Undo -Apply to remove.' -ForegroundColor Cyan; return }

    $bak = New-Backup -Path $target
    Write-Host "Backed up to  : $bak"
    $targetJson.PSObject.Properties.Remove('mcpServers')
    $targetJson | ConvertTo-Json -Depth 100 | Set-Content $target -Encoding utf8
    Write-Host 'mcpServers removed. Fully quit and relaunch Claude Desktop to apply.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- Install
$source = Resolve-SourceConfig -Explicit $SourceConfig
Write-Host "Source config : $source"

$sourceJson = Get-Content $source -Raw | ConvertFrom-Json -Depth 100
if (-not $sourceJson.PSObject.Properties.Name.Contains('mcpServers')) {
    throw "Source config has no mcpServers key: $source"
}

$merged = [ordered]@{}
foreach ($name in $sourceJson.mcpServers.PSObject.Properties.Name) {
    $merged[$name] = ConvertTo-WindowsLauncher -Server $sourceJson.mcpServers.$name
}

Write-Host ''
Write-Host "Servers to install ($($merged.Keys.Count)):"
foreach ($name in $merged.Keys) {
    $s = $merged[$name]
    $envKeys = if ($s.PSObject.Properties.Name -contains 'env' -and $s.env) {
        ($s.env.PSObject.Properties.Name) -join ','
    } else { '' }
    $line = "  {0,-12} {1} {2}" -f $name, $s.command, (@($s.args) -join ' ')
    if ($envKeys) { $line += "   [env: $envKeys]" }
    Write-Host $line
}

$existing = @()
if ($targetJson.PSObject.Properties.Name -contains 'mcpServers' -and $targetJson.mcpServers) {
    $existing = @($targetJson.mcpServers.PSObject.Properties.Name)
}
Write-Host ''
Write-Host "Preserved keys: $((@($targetJson.PSObject.Properties.Name) | Where-Object { $_ -ne 'mcpServers' }) -join ', ')"
if ($existing.Count) { Write-Host "Replacing existing mcpServers: $($existing -join ', ')" -ForegroundColor Yellow }

if (-not $Apply) {
    Write-Host ''
    Write-Host 'Preview only. Re-run with -Apply to write.' -ForegroundColor Cyan
    return
}

$bak = New-Backup -Path $target
Write-Host "Backed up to  : $bak"

if ($targetJson.PSObject.Properties.Name -contains 'mcpServers') {
    $targetJson.mcpServers = [pscustomobject]$merged
} else {
    $targetJson | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([pscustomobject]$merged)
}
$targetJson | ConvertTo-Json -Depth 100 | Set-Content $target -Encoding utf8

Write-Host ''
Write-Host 'Installed. Fully quit Claude Desktop (tray icon -> Quit, not just closing the window),' -ForegroundColor Green
Write-Host 'confirm claude.exe and cowork-svc have exited, then relaunch.' -ForegroundColor Green
