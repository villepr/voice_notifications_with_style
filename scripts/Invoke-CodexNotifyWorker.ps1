param(
    [Parameter(Mandatory = $true)]
    [string]$PayloadFile,
    [switch]$NoSpeak,
    [ValidateSet("templates", "gemini", "openai")]
    [string]$StylingProvider,
    [ValidateSet("local", "elevenlabs", "openai")]
    [string]$TtsProvider,
    [int]$MaxRuntimeSeconds = 180,
    [int]$StaleLockSeconds = 300
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$invokeScript = Join-Path $scriptRoot "Invoke-VoiceNotification.ps1"
$outputRoot = Join-Path $projectRoot "output"
$hookLogPath = Join-Path $outputRoot "codex-notify-hook.log"
$lockPath = Join-Path $outputRoot "codex-notify-worker.lock"

function Ensure-OutputRoot {
    if (-not (Test-Path -LiteralPath $outputRoot)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
}

function Write-WorkerLog {
    param([string]$Message)

    try {
        Ensure-OutputRoot
        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $hookLogPath -Value "$timestamp $Message" -Encoding UTF8
    } catch {
        # Logging must not make the detached worker crash noisily.
    }
}

function Remove-StaleLock {
    if (-not (Test-Path -LiteralPath $lockPath)) {
        return
    }

    try {
        $item = Get-Item -LiteralPath $lockPath
        if ($item.LastWriteTime -lt (Get-Date).AddSeconds(-1 * $StaleLockSeconds)) {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
            Write-WorkerLog "Removed stale voice worker lock '$lockPath'."
        }
    } catch {
        Write-WorkerLog "Could not inspect/remove voice worker lock: $($_.Exception.Message)"
    }
}

function New-WorkerLock {
    Ensure-OutputRoot
    Remove-StaleLock

    try {
        $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $body = "pid=$PID started=$((Get-Date).ToString("o")) payload=$PayloadFile"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return $stream
    } catch {
        return $null
    }
}

function Invoke-NotifierChild {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $speakArg = if ($NoSpeak.IsPresent) { "-NoSpeak" } else { "-Speak" }
    $extraArgs = ""
    if (-not [string]::IsNullOrWhiteSpace($StylingProvider)) {
        $extraArgs += " -StylingProvider $StylingProvider"
    }
    if (-not [string]::IsNullOrWhiteSpace($TtsProvider)) {
        $extraArgs += " -TtsProvider $TtsProvider"
    }
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$invokeScript`" -PayloadFile `"$PayloadFile`" $speakArg$extraArgs"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    $completed = $process.WaitForExit($MaxRuntimeSeconds * 1000)
    if (-not $completed) {
        try {
            $process.Kill()
        } catch {
            # The process may already have exited between the timeout and kill.
        }
        Write-WorkerLog "Voice notify worker timed out after ${MaxRuntimeSeconds}s and killed childPid=$($process.Id)."
        return 124
    }

    return $process.ExitCode
}

$lockStream = $null

try {
    Write-WorkerLog "Voice notify worker starting. payload='$PayloadFile'."

    if (-not (Test-Path -LiteralPath $PayloadFile)) {
        Write-WorkerLog "Voice notify worker skipped: payload file not found."
        exit 0
    }

    if (-not (Test-Path -LiteralPath $invokeScript)) {
        Write-WorkerLog "Voice notify worker skipped: Invoke-VoiceNotification.ps1 missing at '$invokeScript'."
        exit 0
    }

    $lockStream = New-WorkerLock
    if ($null -eq $lockStream) {
        Write-WorkerLog "Voice notify worker skipped: another worker is active. Dropping payload '$PayloadFile'."
        exit 0
    }

    $exitCode = Invoke-NotifierChild
    Write-WorkerLog "Voice notify worker completed. childExitCode=$exitCode payload='$PayloadFile'."
    exit 0
} catch {
    Write-WorkerLog "Voice notify worker failed: $($_.Exception.Message)"
    exit 0
} finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $PayloadFile) {
        Remove-Item -LiteralPath $PayloadFile -Force -ErrorAction SilentlyContinue
    }
}
