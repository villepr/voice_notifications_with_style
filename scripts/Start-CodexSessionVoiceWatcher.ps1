param(
    [string]$CodexHome = (Join-Path $env:USERPROFILE ".codex"),
    [int]$PollSeconds = 2,
    [int]$NotifyGraceSeconds = 3,
    [int]$MaxMessageChars = 4000,
    [switch]$NoSpeak,
    [switch]$Once,
    [switch]$ReplayLastCompleted,
    [ValidateSet("templates", "gemini", "openai")]
    [string]$StylingProvider,
    [ValidateSet("local", "elevenlabs", "openai")]
    [string]$TtsProvider
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$invokeScript = Join-Path $scriptRoot "Invoke-VoiceNotification.ps1"
$outputRoot = Join-Path $projectRoot "output"
$watcherLogPath = Join-Path $outputRoot "codex-session-watcher.log"
$pidPath = Join-Path $outputRoot "codex-session-watcher.pid"
$hookLogPath = Join-Path $outputRoot "codex-notify-hook.log"
$sessionsRoot = Join-Path $CodexHome "sessions"

function Ensure-OutputRoot {
    if (-not (Test-Path -LiteralPath $outputRoot)) {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }
}

function Write-WatcherLog {
    param([string]$Message)

    try {
        Ensure-OutputRoot
        $timestamp = (Get-Date).ToString("o")
        Add-Content -LiteralPath $watcherLogPath -Value "$timestamp $Message" -Encoding UTF8
    } catch {
        # The watcher should keep running even if logging fails.
    }
}

function ConvertFrom-JsonLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    try {
        return ($Line | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-TurnId {
    param($Payload)

    if ($null -eq $Payload) {
        return ""
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Payload.turn_id)) {
        return [string]$Payload.turn_id
    }

    if ($null -ne $Payload.internal_chat_message_metadata_passthrough -and -not [string]::IsNullOrWhiteSpace([string]$Payload.internal_chat_message_metadata_passthrough.turn_id)) {
        return [string]$Payload.internal_chat_message_metadata_passthrough.turn_id
    }

    return ""
}

function Get-AssistantText {
    param($Payload)

    if ($null -eq $Payload -or [string]$Payload.type -ne "message" -or [string]$Payload.role -ne "assistant") {
        return ""
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Payload.phase) -and [string]$Payload.phase -ne "final_answer") {
        return ""
    }

    $parts = @()
    foreach ($content in @($Payload.content)) {
        if ($null -ne $content -and -not [string]::IsNullOrWhiteSpace([string]$content.text)) {
            $parts += [string]$content.text
        }
    }

    return (($parts -join "`n").Trim())
}

function Test-UserSessionFile {
    param([string]$Path)

    try {
        $firstLine = Get-Content -TotalCount 1 -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop
        $meta = ConvertFrom-JsonLine -Line $firstLine
        if ($null -eq $meta -or [string]$meta.type -ne "session_meta") {
            return $false
        }

        $threadSource = [string]$meta.payload.thread_source
        if ($threadSource -eq "subagent") {
            return $false
        }

        return $true
    } catch {
        return $false
    }
}

function Get-UserSessionFiles {
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return @()
    }

    $files = Get-ChildItem -Recurse -File -LiteralPath $sessionsRoot -Filter "*.jsonl" -ErrorAction SilentlyContinue
    return @($files | Where-Object { Test-UserSessionFile -Path $_.FullName })
}

function Read-AppendedText {
    param(
        [string]$Path,
        [long]$Position
    )

    $fs = $null
    $reader = $null

    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Position -gt $fs.Length -or $Position -lt 0) {
            $Position = 0
        }
        [void]$fs.Seek($Position, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $newPosition = $fs.Position
        return [pscustomobject]@{
            Text = $text
            Position = $newPosition
        }
    } finally {
        if ($null -ne $reader) {
            $reader.Close()
        } elseif ($null -ne $fs) {
            $fs.Close()
        }
    }
}

function Test-NativeNotifyStarted {
    param([datetime]$DetectedAt)

    if ($NotifyGraceSeconds -gt 0) {
        Start-Sleep -Seconds $NotifyGraceSeconds
    }

    try {
        if (-not (Test-Path -LiteralPath $hookLogPath)) {
            return $false
        }

        $hookLog = Get-Item -LiteralPath $hookLogPath
        return ($hookLog.LastWriteTime -ge $DetectedAt.AddSeconds(-1))
    } catch {
        return $false
    }
}

function Invoke-SessionVoiceNotification {
    param(
        [string]$SessionPath,
        [string]$TurnId,
        [string]$Message,
        $CompletePayload
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-WatcherLog "Skipped turn $TurnId from '$SessionPath': no final assistant message."
        return
    }

    if ($Message.Length -gt $MaxMessageChars) {
        $Message = $Message.Substring(0, $MaxMessageChars) + "`n`nThe assistant message was longer; this notification was trimmed for speech."
    }

    $payload = [ordered]@{
        type = "codex.session.task_complete"
        title = "Codex turn finished"
        message = $Message
        status = "completed"
        source = [ordered]@{
            sessionFile = $SessionPath
            turnId = $TurnId
            completedAt = $CompletePayload.completed_at
            durationMs = $CompletePayload.duration_ms
            timeToFirstTokenMs = $CompletePayload.time_to_first_token_ms
            watcher = "codex-session-jsonl"
        }
    }

    $tempPayloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-session-voice-notification-{0}.json" -f ([guid]::NewGuid().ToString("N")))

    try {
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPayloadPath -Encoding UTF8

        $args = @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $invokeScript,
            "-PayloadFile",
            $tempPayloadPath
        )

        if ($NoSpeak.IsPresent) {
            $args += "-NoSpeak"
        } else {
            $args += "-Speak"
        }

        if (-not [string]::IsNullOrWhiteSpace($StylingProvider)) {
            $args += "-StylingProvider"
            $args += $StylingProvider
        }

        if (-not [string]::IsNullOrWhiteSpace($TtsProvider)) {
            $args += "-TtsProvider"
            $args += $TtsProvider
        }

        & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" @args | ForEach-Object {
            Write-WatcherLog "notifier: $_"
        }

        Write-WatcherLog "Voice notify completed for turn $TurnId from '$SessionPath'."
    } catch {
        Write-WatcherLog "Voice notify failed for turn $TurnId from '$SessionPath': $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $tempPayloadPath) {
            Remove-Item -LiteralPath $tempPayloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Process-SessionLines {
    param(
        [string]$SessionPath,
        [string[]]$Lines
    )

    foreach ($line in $Lines) {
        $event = ConvertFrom-JsonLine -Line $line
        if ($null -eq $event -or $null -eq $event.payload) {
            continue
        }

        $payload = $event.payload

        if ([string]$event.type -eq "response_item") {
            $assistantText = Get-AssistantText -Payload $payload
            if (-not [string]::IsNullOrWhiteSpace($assistantText)) {
                $turnId = Get-TurnId -Payload $payload
                if (-not [string]::IsNullOrWhiteSpace($turnId)) {
                    $lastFinalByTurn[$turnId] = $assistantText
                }
            }
            continue
        }

        if ([string]$event.type -ne "event_msg" -or [string]$payload.type -ne "task_complete") {
            continue
        }

        $completeTurnId = Get-TurnId -Payload $payload
        if ([string]::IsNullOrWhiteSpace($completeTurnId)) {
            continue
        }

        if ($processedTurns.Contains($completeTurnId)) {
            continue
        }

        $processedTurns.Add($completeTurnId) | Out-Null
        $detectedAt = Get-Date

        if (Test-NativeNotifyStarted -DetectedAt $detectedAt) {
            Write-WatcherLog "Skipped turn $completeTurnId because native notify hook started."
            continue
        }

        $message = ""
        if ($lastFinalByTurn.ContainsKey($completeTurnId)) {
            $message = [string]$lastFinalByTurn[$completeTurnId]
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$payload.last_agent_message)) {
            $fallback = [string]$payload.last_agent_message
            if (-not $fallback.TrimStart().StartsWith("{")) {
                $message = $fallback
            }
        }

        Invoke-SessionVoiceNotification -SessionPath $SessionPath -TurnId $completeTurnId -Message $message -CompletePayload $payload
    }
}

function Invoke-ReplayLastCompleted {
    $sessionFiles = Get-UserSessionFiles | Sort-Object LastWriteTime -Descending
    foreach ($file in $sessionFiles) {
        $localFinals = @{}
        $localCompletes = @()

        foreach ($line in (Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            $event = ConvertFrom-JsonLine -Line $line
            if ($null -eq $event -or $null -eq $event.payload) {
                continue
            }

            $payload = $event.payload
            if ([string]$event.type -eq "response_item") {
                $assistantText = Get-AssistantText -Payload $payload
                if (-not [string]::IsNullOrWhiteSpace($assistantText)) {
                    $turnId = Get-TurnId -Payload $payload
                    if (-not [string]::IsNullOrWhiteSpace($turnId)) {
                        $localFinals[$turnId] = $assistantText
                    }
                }
            } elseif ([string]$event.type -eq "event_msg" -and [string]$payload.type -eq "task_complete") {
                $localCompletes += $payload
            }
        }

        for ($i = $localCompletes.Count - 1; $i -ge 0; $i--) {
            $complete = $localCompletes[$i]
            $turnId = Get-TurnId -Payload $complete
            if ([string]::IsNullOrWhiteSpace($turnId) -or -not $localFinals.ContainsKey($turnId)) {
                continue
            }

            Invoke-SessionVoiceNotification -SessionPath $file.FullName -TurnId $turnId -Message ([string]$localFinals[$turnId]) -CompletePayload $complete
            return $true
        }
    }

    Write-WatcherLog "Replay requested, but no completed user-session final answer was found."
    return $false
}

Ensure-OutputRoot
Set-Content -LiteralPath $pidPath -Value ([string]$PID) -Encoding ASCII
Write-WatcherLog "Watcher started. PID=$PID CodexHome='$CodexHome' sessionsRoot='$sessionsRoot' NoSpeak=$($NoSpeak.IsPresent) ReplayLastCompleted=$($ReplayLastCompleted.IsPresent)."

$positions = @{}
$lastFinalByTurn = @{}
$processedTurns = New-Object "System.Collections.Generic.HashSet[string]"
$initialized = $false

try {
    if ($ReplayLastCompleted.IsPresent) {
        Invoke-ReplayLastCompleted | Out-Null
        if ($Once.IsPresent) {
            return
        }
    }

    while ($true) {
        $files = Get-UserSessionFiles
        foreach ($file in $files) {
            $path = $file.FullName

            if (-not $positions.ContainsKey($path)) {
                if ($initialized) {
                    $positions[$path] = 0L
                    Write-WatcherLog "Tracking new user session from start: '$path'."
                } else {
                    $positions[$path] = [long]$file.Length
                    Write-WatcherLog "Tracking existing user session from EOF: '$path'."
                }
                continue
            }

            $read = Read-AppendedText -Path $path -Position ([long]$positions[$path])
            $positions[$path] = [long]$read.Position

            if (-not [string]::IsNullOrWhiteSpace([string]$read.Text)) {
                $lines = [string]$read.Text -split "`r?`n"
                Process-SessionLines -SessionPath $path -Lines $lines
            }
        }

        $initialized = $true

        if ($Once.IsPresent) {
            break
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Write-WatcherLog "Watcher stopped. PID=$PID."
    try {
        if (Test-Path -LiteralPath $pidPath) {
            $pidText = (Get-Content -Raw -LiteralPath $pidPath -ErrorAction SilentlyContinue).Trim()
            if ($pidText -eq [string]$PID) {
                Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # Leaving a stale PID file is harmless; the stop script handles it.
    }
}
