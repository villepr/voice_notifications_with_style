param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$invokeScript = Join-Path $scriptRoot "Invoke-VoiceNotification.ps1"
$outputRoot = Join-Path $projectRoot "output"
$hookLogPath = Join-Path $outputRoot "codex-notify-hook.log"

function Write-HookLog {
    param([string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $outputRoot)) {
            New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $hookLogPath -Value "$timestamp $Message" -Encoding UTF8
    } catch {
        # Notify hooks must never fail the Codex turn because logging failed.
    }
}

$tempPayloadPath = $null

try {
    Write-HookLog "Voice notify started."

    $stdinText = ""
    if ([Console]::IsInputRedirected) {
        $stdinText = [Console]::In.ReadToEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stdinText)) {
        $tempPayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-voice-notification-{0}.json" -f ([guid]::NewGuid().ToString("N")))
        Set-Content -LiteralPath $tempPayloadPath -Value $stdinText -Encoding UTF8
        & $invokeScript -PayloadFile $tempPayloadPath -Speak
    } else {
        $message = "Codex finished a turn."
        if ($RemainingArgs.Count -gt 0) {
            $message = "Codex notification: $($RemainingArgs -join ' ')"
        }
        & $invokeScript -Message $message -Speak
    }

    Write-HookLog "Voice notify completed."
    exit 0
} catch {
    Write-HookLog "Voice notify failed: $($_.Exception.Message)"
    exit 0
} finally {
    if (-not [string]::IsNullOrWhiteSpace($tempPayloadPath) -and (Test-Path -LiteralPath $tempPayloadPath)) {
        Remove-Item -LiteralPath $tempPayloadPath -Force -ErrorAction SilentlyContinue
    }
}
