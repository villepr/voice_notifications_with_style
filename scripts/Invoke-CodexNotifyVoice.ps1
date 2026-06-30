param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs,
    [switch]$NoSpeak,
    [ValidateSet("templates", "gemini", "openai")]
    [string]$StylingProvider,
    [ValidateSet("local", "elevenlabs", "openai")]
    [string]$TtsProvider
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$workerScript = Join-Path $scriptRoot "Invoke-CodexNotifyWorker.ps1"
$outputRoot = Join-Path $projectRoot "output"
$pendingRoot = Join-Path $outputRoot "pending"
$hookLogPath = Join-Path $outputRoot "codex-notify-hook.log"
$maxMessageChars = 3500

function Ensure-OutputRoot {
    if (-not (Test-Path -LiteralPath $outputRoot)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $pendingRoot)) {
        New-Item -ItemType Directory -Path $pendingRoot -Force | Out-Null
    }
}

function Write-HookLog {
    param([string]$Message)

    try {
        Ensure-OutputRoot
        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $hookLogPath -Value "$timestamp $Message" -Encoding UTF8
    } catch {
        # Notify hooks must never fail the Codex turn because logging failed.
    }
}

function Get-JsonProperty {
    param(
        $Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return ""
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ""
    }

    return [string]$property.Value
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxChars = $maxMessageChars
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $clean = $Text.Trim()
    if ($clean.Length -le $MaxChars) {
        return $clean
    }

    return $clean.Substring(0, $MaxChars) + "`n`nThe original Codex message was longer, so this voice notification was shortened."
}

function New-ManualPayload {
    param([string]$Message)

    $bounded = Limit-Text -Text $Message
    if ([string]::IsNullOrWhiteSpace($bounded)) {
        $bounded = "Codex finished a turn."
    }

    return [ordered]@{
        type = "manual.message"
        title = "Manual notification"
        message = $bounded
        status = "completed"
        source = [ordered]@{
            notifyHook = "codex-native"
            normalized = $false
        }
    }
}

function ConvertTo-NotificationPayload {
    param(
        [string]$RawText,
        [string]$InputSource
    )

    if ([string]::IsNullOrWhiteSpace($RawText)) {
        return (New-ManualPayload -Message "Codex finished a turn.")
    }

    $text = $RawText.Trim()
    $text = $text -replace '^\s*Codex notification:\s*', ''

    try {
        $json = $text | ConvertFrom-Json -ErrorAction Stop
        $type = Get-JsonProperty -Object $json -Name "type"
        $lastAssistantMessage = Get-JsonProperty -Object $json -Name "last-assistant-message"

        if (-not [string]::IsNullOrWhiteSpace($lastAssistantMessage)) {
            return [ordered]@{
                type = "codex.agent_turn_complete"
                title = "Codex turn finished"
                message = (Limit-Text -Text $lastAssistantMessage)
                status = "completed"
                source = [ordered]@{
                    notifyHook = "codex-native"
                    normalized = $true
                    inputSource = $InputSource
                    rawType = $type
                    threadId = (Get-JsonProperty -Object $json -Name "thread-id")
                    turnId = (Get-JsonProperty -Object $json -Name "turn-id")
                    cwd = (Get-JsonProperty -Object $json -Name "cwd")
                    client = (Get-JsonProperty -Object $json -Name "client")
                }
            }
        }

        $message = Get-JsonProperty -Object $json -Name "message"
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $title = Get-JsonProperty -Object $json -Name "title"
            $status = Get-JsonProperty -Object $json -Name "status"
            if ([string]::IsNullOrWhiteSpace($title)) {
                $title = "Codex notification"
            }
            if ([string]::IsNullOrWhiteSpace($status)) {
                $status = "completed"
            }
            if ([string]::IsNullOrWhiteSpace($type)) {
                $type = "codex.notification"
            }

            return [ordered]@{
                type = $type
                title = $title
                message = (Limit-Text -Text $message)
                status = $status
                source = [ordered]@{
                    notifyHook = "codex-native"
                    normalized = $true
                    inputSource = $InputSource
                }
            }
        }
    } catch {
        # Non-JSON args are valid; treat them as a plain notification.
    }

    return (New-ManualPayload -Message $text)
}

function Write-PendingPayload {
    param($Payload)

    Ensure-OutputRoot
    $path = Join-Path $pendingRoot ("codex-notify-{0}.json" -f ([guid]::NewGuid().ToString("N")))
    $Payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

try {
    Write-HookLog "Voice notify hook invoked."

    $stdinText = ""
    if ([Console]::IsInputRedirected) {
        $stdinText = [Console]::In.ReadToEnd()
    }

    $inputSource = "args"
    $rawText = ($RemainingArgs -join " ")
    if (-not [string]::IsNullOrWhiteSpace($stdinText)) {
        $inputSource = "stdin"
        $rawText = $stdinText
    }

    $payload = ConvertTo-NotificationPayload -RawText $rawText -InputSource $inputSource
    $payloadPath = Write-PendingPayload -Payload $payload

    if (-not (Test-Path -LiteralPath $workerScript)) {
        Write-HookLog "Voice notify skipped: worker script missing at '$workerScript'. Payload left at '$payloadPath'."
        exit 0
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $workerScript,
        "-PayloadFile",
        $payloadPath
    )
    if ($NoSpeak.IsPresent) {
        $args += "-NoSpeak"
    }
    if (-not [string]::IsNullOrWhiteSpace($StylingProvider)) {
        $args += "-StylingProvider"
        $args += $StylingProvider
    }
    if (-not [string]::IsNullOrWhiteSpace($TtsProvider)) {
        $args += "-TtsProvider"
        $args += $TtsProvider
    }

    $process = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
    $messageLength = if ($null -ne $payload.message) { ([string]$payload.message).Length } else { 0 }
    Write-HookLog "Voice notify queued. workerPid=$($process.Id) payload='$payloadPath' inputSource=$inputSource messageChars=$messageLength."
    exit 0
} catch {
    Write-HookLog "Voice notify hook failed before queueing: $($_.Exception.Message)"
    exit 0
}
