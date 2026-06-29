param()

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$outputRoot = Join-Path $projectRoot "output"
$pidPath = Join-Path $outputRoot "codex-session-watcher.pid"
$watcherLogPath = Join-Path $outputRoot "codex-session-watcher.log"

function Write-WatcherLog {
    param([string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $outputRoot)) {
            New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $watcherLogPath -Value "$timestamp $Message" -Encoding UTF8
    } catch {
        # Stop should not fail just because logging failed.
    }
}

if (-not (Test-Path -LiteralPath $pidPath)) {
    Write-Output "No watcher PID file found."
    exit 0
}

$pidText = (Get-Content -Raw -LiteralPath $pidPath).Trim()
$processId = 0
if (-not [int]::TryParse($pidText, [ref]$processId)) {
    Write-Output "Watcher PID file is invalid: $pidText"
    exit 1
}

$process = Get-Process -Id $processId -ErrorAction SilentlyContinue
if ($null -eq $process) {
    Write-Output "Watcher process $processId is not running."
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    exit 0
}

Stop-Process -Id $processId -Force
Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
Write-WatcherLog "Watcher process $processId stopped by stop script."
Write-Output "Stopped watcher process $processId."
