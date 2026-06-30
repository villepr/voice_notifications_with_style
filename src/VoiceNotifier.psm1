Set-StrictMode -Version Latest

function ConvertTo-ConfigHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-ConfigHashtable -Value $property.Value
        }
        return $result
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-ConfigHashtable -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @()
        foreach ($item in $Value) {
            $items += (ConvertTo-ConfigHashtable -Value $item)
        }
        return $items
    }

    return $Value
}

function Read-ConfigJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $raw = Get-Content -Raw -LiteralPath $Path
    return ConvertTo-ConfigHashtable -Value ($raw | ConvertFrom-Json)
}

function Merge-ConfigHashtable {
    param(
        [System.Collections.IDictionary]$Base,
        [System.Collections.IDictionary]$Override
    )

    $result = [ordered]@{}
    foreach ($key in $Base.Keys) {
        $result[[string]$key] = $Base[$key]
    }

    foreach ($key in $Override.Keys) {
        $keyText = [string]$key
        if ($result.Contains($keyText) -and
            $result[$keyText] -is [System.Collections.IDictionary] -and
            $Override[$key] -is [System.Collections.IDictionary]) {
            $result[$keyText] = Merge-ConfigHashtable -Base $result[$keyText] -Override $Override[$key]
        } else {
            $result[$keyText] = $Override[$key]
        }
    }

    return $result
}

function Resolve-ConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $ProjectRoot $Path
}

function Apply-PromptFileOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    if (-not $Config.Contains("promptFiles")) {
        return $Config
    }

    $promptFiles = $Config["promptFiles"]
    if ($null -eq $promptFiles -or -not ($promptFiles -is [System.Collections.IDictionary]) -or -not $promptFiles.Contains("stylingSystem")) {
        return $Config
    }

    $promptPath = Resolve-ConfigPath -ProjectRoot $ProjectRoot -Path ([string]$promptFiles["stylingSystem"])
    if ([string]::IsNullOrWhiteSpace($promptPath) -or -not (Test-Path -LiteralPath $promptPath)) {
        return $Config
    }

    $promptText = (Get-Content -Raw -LiteralPath $promptPath).Trim()
    if ([string]::IsNullOrWhiteSpace($promptText)) {
        return $Config
    }

    if (-not $Config.Contains("prompts") -or $null -eq $Config["prompts"] -or -not ($Config["prompts"] -is [System.Collections.IDictionary])) {
        $Config["prompts"] = [ordered]@{}
    }
    if (-not $Config["prompts"].Contains("styling") -or $null -eq $Config["prompts"]["styling"] -or -not ($Config["prompts"]["styling"] -is [System.Collections.IDictionary])) {
        $Config["prompts"]["styling"] = [ordered]@{}
    }

    $Config["prompts"]["styling"]["systemLines"] = @($promptText)
    return $Config
}

function Get-VoiceNotifierConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $defaultsPath = Join-Path $ProjectRoot "src\VoiceNotifier.defaults.json"
    $configPath = Join-Path $ProjectRoot "config\voice-notifier.config.json"
    if (-not (Test-Path -LiteralPath $defaultsPath)) {
        throw "Defaults file not found: $defaultsPath"
    }
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Config file not found: $configPath"
    }

    $defaults = Read-ConfigJsonFile -Path $defaultsPath
    $overrides = Read-ConfigJsonFile -Path $configPath
    $merged = Merge-ConfigHashtable -Base $defaults -Override $overrides
    $merged = Apply-PromptFileOverrides -Config $merged -ProjectRoot $ProjectRoot

    return ($merged | ConvertTo-Json -Depth 64 | ConvertFrom-Json)
}

function Get-VoiceNotifierSecret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name, "Process")
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, "User")
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($name, "Machine")
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [ordered]@{
                value = $value
                source = "environment:$name"
            }
        }
    }

    $secretsPath = Join-Path $ProjectRoot "config\secrets.local.json"
    if (Test-Path -LiteralPath $secretsPath) {
        try {
            $secrets = Get-Content -Raw -LiteralPath $secretsPath | ConvertFrom-Json
            foreach ($name in $Names) {
                $property = @($secrets.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
                if ($property.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$property[0].Value)) {
                    return [ordered]@{
                        value = [string]$property[0].Value
                        source = "file:config\secrets.local.json:$name"
                    }
                }
            }

            foreach ($fallbackName in @("geminiApiKey", "apiKey", "key")) {
                $property = @($secrets.PSObject.Properties | Where-Object { $_.Name -eq $fallbackName } | Select-Object -First 1)
                if ($property.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$property[0].Value)) {
                    return [ordered]@{
                        value = [string]$property[0].Value
                        source = "file:config\secrets.local.json:$fallbackName"
                    }
                }
            }
        } catch {
            return [ordered]@{
                value = ""
                source = "file:config\secrets.local.json"
                error = $_.Exception.Message
            }
        }
    }

    $plaintextSecretFiles = @()
    if (@($Names | Where-Object { $_ -match "GEMINI|GOOGLE" }).Count -gt 0) {
        $plaintextSecretFiles += @(
            "config\geminiapikey.secret",
            "config\gemini-api-key.secret",
            "config\googleapikey.secret",
            "config\google-api-key.secret"
        )
    }
    if (@($Names | Where-Object { $_ -match "ELEVEN" }).Count -gt 0) {
        $plaintextSecretFiles += @(
            "config\elevenlabsvoice.secret",
            "config\elevenlabsapikey.secret",
            "config\elevenlabs-api-key.secret",
            "config\elevenlabs.secret"
        )
    }
    if (@($Names | Where-Object { $_ -match "OPENAI" }).Count -gt 0) {
        $plaintextSecretFiles += @(
            "config\openaiapikey.secret",
            "config\openai-api-key.secret",
            "config\openai.secret"
        )
    }

    foreach ($relativeSecretPath in $plaintextSecretFiles) {
        $plaintextPath = Join-Path $ProjectRoot $relativeSecretPath
        if (Test-Path -LiteralPath $plaintextPath) {
            try {
                $value = (Get-Content -Raw -LiteralPath $plaintextPath).Trim()
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return [ordered]@{
                        value = $value
                        source = "file:$relativeSecretPath"
                    }
                }
            } catch {
                return [ordered]@{
                    value = ""
                    source = "file:$relativeSecretPath"
                    error = $_.Exception.Message
                }
            }
        }
    }

    return [ordered]@{
        value = ""
        source = "missing"
    }
}

function ConvertTo-HashtableDeep {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $hash = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $hash[$key] = ConvertTo-HashtableDeep $InputObject[$key]
            }
            return $hash
        }

        if ($InputObject -is [pscustomobject]) {
            $hash = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-HashtableDeep $property.Value
            }
            return $hash
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $items = @()
            foreach ($item in $InputObject) {
                $items += ConvertTo-HashtableDeep $item
            }
            return $items
        }

        return $InputObject
    }
}

function Read-NotificationPayload {
    param(
        [string]$PayloadFile,
        [string]$Message
    )

    if (-not [string]::IsNullOrWhiteSpace($PayloadFile)) {
        if (-not (Test-Path -LiteralPath $PayloadFile)) {
            throw "Payload file not found: $PayloadFile"
        }
        $raw = Get-Content -Raw -LiteralPath $PayloadFile
        return @{
            RawText = $raw
            Payload = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
            Source = "file"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $payload = [ordered]@{
            type = "manual.message"
            title = "Manual notification"
            message = $Message
            status = "completed"
        }
        return @{
            RawText = ($payload | ConvertTo-Json -Depth 8)
            Payload = $payload
            Source = "message"
        }
    }

    $stdinText = ""
    if (-not [Console]::IsInputRedirected) {
        $stdinText = ""
    } else {
        $stdinText = [Console]::In.ReadToEnd()
    }

    if (-not [string]::IsNullOrWhiteSpace($stdinText)) {
        try {
            return @{
                RawText = $stdinText
                Payload = ConvertTo-HashtableDeep ($stdinText | ConvertFrom-Json)
                Source = "stdin-json"
            }
        } catch {
            $payload = [ordered]@{
                type = "stdin.text"
                title = "Notification"
                message = $stdinText.Trim()
                status = "completed"
            }
            return @{
                RawText = ($payload | ConvertTo-Json -Depth 8)
                Payload = $payload
                Source = "stdin-text"
            }
        }
    }

    $defaultPayload = [ordered]@{
        type = "manual.message"
        title = "Manual notification"
        message = "Codex finished a task. No notification payload was supplied."
        status = "completed"
    }

    return @{
        RawText = ($defaultPayload | ConvertTo-Json -Depth 8)
        Payload = $defaultPayload
        Source = "default"
    }
}

function Get-ValueFromPayload {
    param(
        [hashtable]$Payload,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if ($Payload.Contains($name) -and -not [string]::IsNullOrWhiteSpace([string]$Payload[$name])) {
            return [string]$Payload[$name]
        }
    }
    return ""
}

function Get-ArrayFromPayload {
    param(
        [hashtable]$Payload,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        if (-not $Payload.Contains($name) -or $null -eq $Payload[$name]) {
            continue
        }

        $value = $Payload[$name]
        if ($value -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return @($value)
            }
        } elseif ($value -is [System.Collections.IEnumerable]) {
            $items = @()
            foreach ($item in $value) {
                if ($item -is [hashtable] -or $item -is [System.Collections.IDictionary]) {
                    if ($item.Contains("name") -and $item.Contains("status")) {
                        $items += ("{0}: {1}" -f $item["name"], $item["status"])
                    } elseif ($item.Contains("path")) {
                        $items += [string]$item["path"]
                    } else {
                        $items += ($item | ConvertTo-Json -Compress -Depth 6)
                    }
                } else {
                    $items += [string]$item
                }
            }
            return $items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    }

    return @()
}

function ConvertTo-FriendlyPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $normalized = $Path -replace "/", "\"
    $parts = $normalized -split "\\"
    if ($parts.Count -le 2) {
        return $Path
    }

    return "{0}\{1}" -f $parts[$parts.Count - 2], $parts[$parts.Count - 1]
}

function Format-ListForSpeech {
    param(
        [string[]]$Items,
        [int]$MaxItems = 4
    )

    $cleanItems = @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($cleanItems.Count -eq 0) {
        return ""
    }

    $visible = @($cleanItems | Select-Object -First $MaxItems)
    if ($cleanItems.Count -gt $MaxItems) {
        $visible += ("{0} more" -f ($cleanItems.Count - $MaxItems))
    }

    if ($visible.Count -eq 1) {
        return $visible[0]
    }

    if ($visible.Count -eq 2) {
        return "{0} and {1}" -f $visible[0], $visible[1]
    }

    $prefix = ($visible[0..($visible.Count - 2)] -join ", ")
    return "$prefix, and $($visible[-1])"
}

function Convert-TechnicalTerms {
    param(
        [string]$Text,
        $Config
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    $result = $Text
    if ($null -eq $Config.technicalTranslations) {
        return $result
    }

    foreach ($property in $Config.technicalTranslations.PSObject.Properties) {
        $pattern = "(?i)\b" + [regex]::Escape($property.Name) + "\b"
        $replacement = [string]$property.Value
        $result = [regex]::Replace($result, $pattern, $replacement)
    }

    return $result
}

function Get-NotificationFacts {
    param(
        [hashtable]$Payload,
        $Config
    )

    $title = Get-ValueFromPayload -Payload $Payload -Names @("title", "subject", "summary")
    $message = Get-ValueFromPayload -Payload $Payload -Names @("message", "body", "text", "description")
    $status = Get-ValueFromPayload -Payload $Payload -Names @("status", "state", "result")
    $type = Get-ValueFromPayload -Payload $Payload -Names @("type", "event", "kind")
    $nextAction = Get-ValueFromPayload -Payload $Payload -Names @("next_action", "nextAction", "next", "action")

    $files = @(Get-ArrayFromPayload -Payload $Payload -Names @("files", "changed_files", "changedFiles", "paths")) |
        ForEach-Object { ConvertTo-FriendlyPath $_ }
    $commands = @(Get-ArrayFromPayload -Payload $Payload -Names @("commands", "command", "cmd"))
    $tests = @(Get-ArrayFromPayload -Payload $Payload -Names @("tests", "checks", "test_results", "testResults"))
    $errors = @(Get-ArrayFromPayload -Payload $Payload -Names @("errors", "error", "blockers", "warnings"))

    $combined = "$title $message $status $type $nextAction"
    $needsApproval = $false
    if ($combined -match "(?i)approval|required|permission|confirm") {
        $needsApproval = $true
    }

    $plainTitle = Convert-TechnicalTerms -Text $title -Config $Config
    $plainMessage = Convert-TechnicalTerms -Text $message -Config $Config
    $plainNextAction = Convert-TechnicalTerms -Text $nextAction -Config $Config

    return [ordered]@{
        type = $type
        status = $status
        title = $plainTitle
        message = $plainMessage
        files = @($files)
        commands = @($commands)
        tests = @($tests)
        errors = @($errors)
        needsApproval = $needsApproval
        nextAction = $plainNextAction
    }
}

function New-NeutralBrief {
    param(
        [hashtable]$Facts
    )

    $sentences = @()

    $status = [string]$Facts.status
    $title = [string]$Facts.title
    $message = [string]$Facts.message

    if ($Facts.needsApproval) {
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $sentences += "Codex needs your permission: $message"
        } else {
            $sentences += "Codex needs your permission before it can continue."
        }
    } elseif ($status -match "(?i)blocked|failed|error") {
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $sentences += "Codex is blocked: $message"
        } else {
            $sentences += "Codex is blocked and needs attention."
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($message)) {
        $lead = "Codex has an update"
        if ($Facts.type -eq "manual.message" -and $title -eq "Manual notification") {
            $lead = ""
        } elseif (-not [string]::IsNullOrWhiteSpace($title)) {
            $lead = "Codex update: $title."
        }
        $sentences += ("$lead $message").Trim()
    } else {
        $sentences += "Codex has an update."
    }

    if ($Facts.files.Count -gt 0) {
        $sentences += "It touched $(Format-ListForSpeech -Items $Facts.files)."
    }

    if ($Facts.tests.Count -gt 0) {
        $sentences += "Checks: $(Format-ListForSpeech -Items $Facts.tests)."
    }

    if ($Facts.errors.Count -gt 0) {
        $sentences += "Issue noted: $(Format-ListForSpeech -Items $Facts.errors)."
    }

    if ($Facts.commands.Count -gt 0) {
        $sentences += "Relevant command: $(Format-ListForSpeech -Items $Facts.commands -MaxItems 2)."
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Facts.nextAction)) {
        $sentences += "Next: $($Facts.nextAction)"
    }

    return (($sentences -join " ") -replace "\s+", " " -replace "\.\.", ".").Trim()
}

function New-SpeakableFacts {
    param(
        [hashtable]$Facts
    )

    $supportingDetails = @()

    if ($Facts.files.Count -gt 0) {
        if ($Facts.files.Count -eq 1) {
            $supportingDetails += "One project file was updated."
        } else {
            $supportingDetails += ("{0} project files were updated." -f $Facts.files.Count)
        }
    }

    if ($Facts.commands.Count -gt 0) {
        if (($Facts.commands -join " ") -match "(?i)test|smoke|check") {
            $supportingDetails += "The local verification run completed."
        } else {
            $supportingDetails += "A local command was involved."
        }
    }

    foreach ($test in $Facts.tests) {
        $supportingDetails += (Convert-TechnicalTerms -Text ([string]$test) -Config ([pscustomobject]@{ technicalTranslations = $null }))
    }

    foreach ($errorItem in $Facts.errors) {
        $supportingDetails += ("Issue: {0}" -f $errorItem)
    }

    $eventType = "generic"
    if ($Facts.needsApproval) {
        $eventType = "approval"
    } elseif ([string]$Facts.status -match "(?i)blocked|failed|error") {
        $eventType = "blocked"
    } elseif ([string]$Facts.status -match "(?i)complete|completed|success|passed") {
        $eventType = "completed"
    }

    $mainResult = [string]$Facts.message
    if ([string]::IsNullOrWhiteSpace($mainResult)) {
        $mainResult = [string]$Facts.title
    }
    if ([string]::IsNullOrWhiteSpace($mainResult)) {
        $mainResult = "Codex has an update."
    }

    return [ordered]@{
        eventType = $eventType
        title = [string]$Facts.title
        mainResult = $mainResult
        supportingDetails = @($supportingDetails | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        nextAction = [string]$Facts.nextAction
        technicalDetailsToAvoidReadingVerbatim = @((@($Facts.files) + @($Facts.commands)) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Await-WinRtOperation {
    param(
        [Parameter(Mandatory = $true)]
        $Operation,
        [Parameter(Mandatory = $true)]
        [type]$ResultType
    )

    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object {
            $_.Name -eq "AsTask" -and
            $_.IsGenericMethodDefinition -and
            $_.GetParameters().Count -eq 1
        } |
        Select-Object -First 1

    if ($null -eq $method) {
        throw "Could not locate System.WindowsRuntimeSystemExtensions.AsTask generic method."
    }

    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-WindowsMediaSessions {
    $sessions = @()

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        [void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        [void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]

        $managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
        $propsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
        $manager = Await-WinRtOperation -Operation ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) -ResultType $managerType

        foreach ($session in $manager.GetSessions()) {
            $props = Await-WinRtOperation -Operation ($session.TryGetMediaPropertiesAsync()) -ResultType $propsType
            $playbackStatus = "Unknown"
            try {
                $playbackStatus = $session.GetPlaybackInfo().PlaybackStatus.ToString()
            } catch {
                $playbackStatus = "Unknown"
            }

            $sessions += [ordered]@{
                source = "windows-media-session"
                sourceAppUserModelId = [string]$session.SourceAppUserModelId
                title = [string]$props.Title
                artist = [string]$props.Artist
                albumTitle = [string]$props.AlbumTitle
                albumArtist = [string]$props.AlbumArtist
                playbackStatus = $playbackStatus
                quality = "media-session"
            }
        }
    } catch {
        $sessions += [ordered]@{
            source = "windows-media-session"
            sourceAppUserModelId = ""
            title = ""
            artist = ""
            albumTitle = ""
            albumArtist = ""
            playbackStatus = "Unavailable"
            quality = "error"
            error = $_.Exception.Message
        }
    }

    return $sessions
}

function Get-SpotifyWindowMetadata {
    $processes = @(Get-Process Spotify -ErrorAction SilentlyContinue |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.MainWindowTitle) } |
        Select-Object -ExpandProperty MainWindowTitle -Unique)

    foreach ($title in $processes) {
        if ($title -eq "Spotify") {
            continue
        }

        $artist = ""
        $track = $title
        if ($title -match "^\s*(?<artist>.+?)\s+-\s+(?<track>.+?)\s*$") {
            $artist = $Matches.artist.Trim()
            $track = $Matches.track.Trim()
        }

        return [ordered]@{
            source = "spotify-window-title"
            sourceAppUserModelId = "Spotify"
            title = $track
            artist = $artist
            albumTitle = ""
            albumArtist = ""
            playbackStatus = "Unknown"
            quality = "window-title"
            rawWindowTitle = $title
        }
    }

    return $null
}

function Test-MediaMetadataUsable {
    param([hashtable]$Metadata)

    if ($null -eq $Metadata) {
        return $false
    }

    $title = [string]$Metadata.title
    $artist = [string]$Metadata.artist
    if ([string]::IsNullOrWhiteSpace($title) -and [string]::IsNullOrWhiteSpace($artist)) {
        return $false
    }

    $combined = "$title $artist"
    if ($combined -match "(?i)spotify|advertisement|mainos|kuuntele musiikkia|listening is everything") {
        return $false
    }

    return $true
}

function Get-NowPlayingMetadata {
    param($Config)

    $selected = $null
    $sessions = @()
    if ($Config.media.useWindowsMediaSessions) {
        $sessions = @(Get-WindowsMediaSessions)
        $spotifySessions = @($sessions | Where-Object { ([string]$_["sourceAppUserModelId"]) -match "(?i)spotify" })
        $candidateSessions = if ($Config.media.preferSpotify -and $spotifySessions.Count -gt 0) { $spotifySessions } else { $sessions }
        $usableSessions = @($candidateSessions | Where-Object { Test-MediaMetadataUsable $_ } | Select-Object -First 1)
        if ($usableSessions.Count -gt 0) {
            $selected = $usableSessions[0]
        }
    }

    $fallback = $null
    if ($Config.media.useSpotifyWindowTitleFallback) {
        $fallback = Get-SpotifyWindowMetadata
    }

    if ($null -eq $selected -and $null -ne $fallback) {
        $selected = $fallback
    } elseif ($null -ne $selected -and $selected["sourceAppUserModelId"] -match "(?i)spotify" -and $null -ne $fallback) {
        $selected["fallbackCandidate"] = $fallback
    }

    if ($null -eq $selected) {
        $selected = [ordered]@{
            source = "none"
            sourceAppUserModelId = ""
            title = ""
            artist = ""
            albumTitle = ""
            albumArtist = ""
            playbackStatus = "Unavailable"
            quality = "none"
        }
    }

    return [ordered]@{
        selected = $selected
        sessions = @($sessions)
        spotifyWindowFallback = $fallback
    }
}

function Select-StyleProfile {
    param(
        [hashtable]$NowPlaying,
        $Config,
        [string]$StyleOverride
    )

    if (-not [string]::IsNullOrWhiteSpace($StyleOverride)) {
        $property = @($Config.styleProfiles.PSObject.Properties | Where-Object { $_.Name -eq $StyleOverride } | Select-Object -First 1)
        if ($property.Count -gt 0) {
            return [ordered]@{
                name = $StyleOverride
                reason = "manual override"
                profile = $property[0].Value
            }
        }
    }

    $metadata = $NowPlaying.selected
    $haystack = @(
        [string]$metadata.title,
        [string]$metadata.artist,
        [string]$metadata.albumTitle,
        [string]$metadata.albumArtist
    ) -join " "

    foreach ($override in $Config.keywordOverrides) {
        foreach ($keyword in $override.keywords) {
            if ($haystack -match [regex]::Escape([string]$keyword)) {
                return [ordered]@{
                    name = [string]$override.style
                    reason = "keyword: $keyword"
                    profile = $Config.styleProfiles.([string]$override.style)
                }
            }
        }
    }

    return [ordered]@{
        name = "neutral"
        reason = "no metadata keyword match"
        profile = $Config.styleProfiles.neutral
    }
}

function ConvertTo-StyledBrief {
    param(
        [string]$NeutralBrief,
        [string]$StyleName,
        [hashtable]$Facts
    )

    $brief = $NeutralBrief

    switch ($StyleName) {
        "reggae" {
            $brief = $brief -replace "^Codex update:", "Codex has a warm update:"
            $brief = $brief -replace "^Codex has an update\.", "Codex has an easy-flowing update."
            $brief = $brief -replace "Codex finished", "Codex wrapped up"
            $brief = $brief -replace "Checks:", "The checks came through:"
            $brief = $brief -replace "Next:", "Next step:"
            return "Here is the update, steady and clear. $brief"
        }
        "cinematic" {
            $brief = $brief -replace "^Codex update:", "Codex status scene:"
            $brief = $brief -replace "^Codex has an update\.", "Codex has a status scene ready."
            $brief = $brief -replace "Codex is blocked", "Codex has reached a blocker"
            $brief = $brief -replace "Checks:", "Verification:"
            $brief = $brief -replace "Next:", "Next move:"
            return "Scene set. $brief"
        }
        "electronic" {
            $brief = $brief -replace "^Codex update:", "Codex signal:"
            $brief = $brief -replace "^Codex has an update\.", "Codex signal received."
            $brief = $brief -replace "It touched", "Files updated:"
            $brief = $brief -replace "Checks:", "Checks locked:"
            $brief = $brief -replace "Next:", "Next:"
            return $brief
        }
        "rock" {
            $brief = $brief -replace "^Codex update:", "Codex update, loud and clear:"
            $brief = $brief -replace "^Codex has an update\.", "Codex has an update, loud and clear."
            $brief = $brief -replace "Codex finished", "Codex knocked out"
            $brief = $brief -replace "Checks:", "Checks passed through:"
            $brief = $brief -replace "Next:", "Next up:"
            return $brief
        }
        "jazz" {
            $brief = $brief -replace "^Codex update:", "Codex has a smooth update:"
            $brief = $brief -replace "^Codex has an update\.", "Codex has a smooth update."
            $brief = $brief -replace "It touched", "It worked across"
            $brief = $brief -replace "Checks:", "The checks say:"
            $brief = $brief -replace "Next:", "Next cue:"
            return $brief
        }
        default {
            return $brief
        }
    }
}

function New-GeminiStylingPrompt {
    param(
        [hashtable]$SpeakableFacts,
        [hashtable]$NowPlaying,
        $Config
    )

    $selected = $NowPlaying.selected
    $payload = [ordered]@{
        nowPlaying = [ordered]@{
            artist = [string]$selected.artist
            title = [string]$selected.title
            album = [string]$selected.albumTitle
            albumArtist = [string]$selected.albumArtist
            source = [string]$selected.source
            playbackStatus = [string]$selected.playbackStatus
        }
        notification = [ordered]@{
            eventType = [string]$SpeakableFacts.eventType
            message = [string]$SpeakableFacts.mainResult
            supportingDetails = @($SpeakableFacts.supportingDetails)
            nextAction = [string]$SpeakableFacts.nextAction
            avoidReading = @($SpeakableFacts.technicalDetailsToAvoidReadingVerbatim)
        }
    }

    return $payload | ConvertTo-Json -Depth 12
}

function Get-GeminiOutputText {
    param($Response)

    if ($null -ne $Response.candidates) {
        $candidateTexts = @()
        foreach ($candidate in $Response.candidates) {
            if ($null -ne $candidate.content -and $null -ne $candidate.content.parts) {
                foreach ($part in $candidate.content.parts) {
                    if ($null -ne $part.text) {
                        $candidateTexts += [string]$part.text
                    }
                }
            }
        }
        $candidateOutput = ($candidateTexts -join "`n").Trim()
        if (-not [string]::IsNullOrWhiteSpace($candidateOutput)) {
            return $candidateOutput
        }
    }

    if ($null -ne $Response.output_text) {
        return [string]$Response.output_text
    }

    $texts = @()
    if ($null -ne $Response.steps) {
        foreach ($step in $Response.steps) {
            if ($null -ne $step.modelOutput -and $null -ne $step.modelOutput.content) {
                foreach ($content in $step.modelOutput.content) {
                    if ($null -ne $content.text) {
                        if ($content.text -is [string]) {
                            $texts += [string]$content.text
                        } elseif ($null -ne $content.text.text) {
                            $texts += [string]$content.text.text
                        }
                    }
                }
            }
            if ($null -ne $step.model_output -and $null -ne $step.model_output.content) {
                foreach ($content in $step.model_output.content) {
                    if ($null -ne $content.text) {
                        if ($content.text -is [string]) {
                            $texts += [string]$content.text
                        } elseif ($null -ne $content.text.text) {
                            $texts += [string]$content.text.text
                        }
                    }
                }
            }
        }
    }

    return ($texts -join "`n").Trim()
}

function ConvertFrom-ModelJsonText {
    param([string]$Text)

    $clean = $Text.Trim()
    if ($clean -match '```(?:json)?\s*(?<json>[\s\S]*?)\s*```') {
        $clean = $Matches.json.Trim()
    }

    return $clean | ConvertFrom-Json
}

function Get-ObjectValue {
    param(
        $Object,
        [string]$Key,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Key)) {
        return $Object[$Key]
    }

    $property = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Key } | Select-Object -First 1)
    if ($property.Count -gt 0) {
        return $property[0].Value
    }

    return $Default
}

function Get-ProviderSettings {
    param(
        $Config,
        [string]$Provider,
        [string]$Capability
    )

    $providerKey = $Provider
    if ($Capability -eq "speech" -and $Provider -eq "local") {
        $providerKey = "windowsSpeech"
    }

    $providers = Get-ObjectValue -Object $Config -Key "providers" -Default $null
    $providerSettings = Get-ObjectValue -Object $providers -Key $providerKey -Default $null
    if ($null -ne $providerSettings) {
        if ($Provider -eq "local" -and $Capability -eq "speech") {
            return $providerSettings
        }

        $capabilitySettings = Get-ObjectValue -Object $providerSettings -Key $Capability -Default $null
        if ($null -ne $capabilitySettings) {
            return $capabilitySettings
        }
    }

    if ($Capability -eq "text") {
        if ($Provider -eq "openai") {
            return Get-ObjectValue -Object (Get-ObjectValue -Object $Config -Key "styling" -Default $null) -Key "openai" -Default $null
        }
        if ($Provider -eq "gemini") {
            return Get-ObjectValue -Object (Get-ObjectValue -Object $Config -Key "styling" -Default $null) -Key "gemini" -Default $null
        }
    }

    if ($Capability -eq "speech") {
        $tts = Get-ObjectValue -Object $Config -Key "tts" -Default $null
        if ($Provider -eq "openai") {
            return Get-ObjectValue -Object (Get-ObjectValue -Object $tts -Key "adapters" -Default $null) -Key "openai" -Default $null
        }
        if ($Provider -eq "elevenlabs") {
            return Get-ObjectValue -Object (Get-ObjectValue -Object $tts -Key "adapters" -Default $null) -Key "elevenlabs" -Default $null
        }
        if ($Provider -eq "local") {
            return Get-ObjectValue -Object $tts -Key "local" -Default $null
        }
    }

    return $null
}

function Get-DefaultTextProvider {
    param($Config)

    $defaults = Get-ObjectValue -Object $Config -Key "defaults" -Default $null
    $styling = Get-ObjectValue -Object $Config -Key "styling" -Default $null
    $provider = [string](Get-ObjectValue -Object (Get-ObjectValue -Object $defaults -Key "text" -Default $null) -Key "provider" -Default "")
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = [string](Get-ObjectValue -Object $styling -Key "provider" -Default "")
    }
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = "openai"
    }

    return $provider
}

function Get-DefaultSpeechProvider {
    param($Config)

    $defaults = Get-ObjectValue -Object $Config -Key "defaults" -Default $null
    $tts = Get-ObjectValue -Object $Config -Key "tts" -Default $null
    $provider = [string](Get-ObjectValue -Object (Get-ObjectValue -Object $defaults -Key "speech" -Default $null) -Key "provider" -Default "")
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = [string](Get-ObjectValue -Object $tts -Key "provider" -Default "")
    }
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $provider = "local"
    }

    return $provider
}

function Get-ConfiguredTextModel {
    param(
        $Config,
        [string]$Provider,
        $ProviderSettings
    )

    $defaultText = Get-ObjectValue -Object (Get-ObjectValue -Object $Config -Key "defaults" -Default $null) -Key "text" -Default $null
    $defaultProvider = [string](Get-ObjectValue -Object $defaultText -Key "provider" -Default "")
    $defaultModel = [string](Get-ObjectValue -Object $defaultText -Key "model" -Default "")
    if ($Provider -eq $defaultProvider -and -not [string]::IsNullOrWhiteSpace($defaultModel)) {
        return $defaultModel
    }

    return [string](Get-ObjectValue -Object $ProviderSettings -Key "model" -Default "")
}

function Get-StylingMaxWords {
    param(
        $Config,
        $ProviderSettings
    )

    $maxWords = Get-ObjectValue -Object (Get-ObjectValue -Object (Get-ObjectValue -Object $Config -Key "prompts" -Default $null) -Key "styling" -Default $null) -Key "maxWords" -Default $null
    if ($null -eq $maxWords) {
        $maxWords = Get-ObjectValue -Object $ProviderSettings -Key "maxWords" -Default 90
    }

    return [int]$maxWords
}

function Get-OpenAISpeechSettings {
    param($Config)

    return Get-ProviderSettings -Config $Config -Provider "openai" -Capability "speech"
}

function Get-ExceptionDetailMessage {
    param($ErrorRecord)

    if ($null -ne $ErrorRecord -and -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
        return [string]$ErrorRecord.ErrorDetails.Message
    }
    if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.Exception) {
        return [string]$ErrorRecord.Exception.Message
    }
    return "Unknown error"
}

function ConvertFrom-StylingModelOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputText
    )

    $parsed = ConvertFrom-ModelJsonText -Text $OutputText
    $text = [string](Get-ObjectValue -Object $parsed -Key "text" -Default "")
    if ([string]::IsNullOrWhiteSpace($text)) {
        $text = [string](Get-ObjectValue -Object $parsed -Key "spokenText" -Default "")
    }

    $voiceSource = Get-ObjectValue -Object $parsed -Key "voice" -Default $null
    $legacyInstructions = [string](Get-ObjectValue -Object $parsed -Key "ttsInstructions" -Default "")
    $voice = [ordered]@{
        instructions = [string](Get-ObjectValue -Object $voiceSource -Key "instructions" -Default $legacyInstructions)
        voice = [string](Get-ObjectValue -Object $voiceSource -Key "voice" -Default "")
        speed = 1.0
        energy = [string](Get-ObjectValue -Object $voiceSource -Key "energy" -Default "")
        pace = [string](Get-ObjectValue -Object $voiceSource -Key "pace" -Default "")
        response_format = [string](Get-ObjectValue -Object $voiceSource -Key "response_format" -Default "mp3")
    }

    $requestedSpeed = Get-ObjectValue -Object $voiceSource -Key "speed" -Default $null
    if ($null -ne $requestedSpeed -and -not [string]::IsNullOrWhiteSpace([string]$requestedSpeed)) {
        $parsedSpeed = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        if ([double]::TryParse([string]$requestedSpeed, $styles, $culture, [ref]$parsedSpeed)) {
            $voice.speed = $parsedSpeed
        }
    }

    return [ordered]@{
        text = $text
        voice = $voice
    }
}

function New-StylingSystemInstruction {
    param(
        $Config,
        $ProviderSettings = $null
    )

    $openAiSpeechSettings = Get-OpenAISpeechSettings -Config $Config
    $voiceChoices = @()
    foreach ($voiceChoice in @(Get-ObjectValue -Object $openAiSpeechSettings -Key "voiceChoices" -Default @())) {
        if (-not [string]::IsNullOrWhiteSpace([string]$voiceChoice)) {
            $voiceChoices += ([string]$voiceChoice).Trim().ToLowerInvariant()
        }
    }
    $defaultVoice = [string](Get-ObjectValue -Object $openAiSpeechSettings -Key "voice" -Default "")
    if ($voiceChoices.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($defaultVoice)) {
        $voiceChoices += $defaultVoice.Trim().ToLowerInvariant()
    }
    $voiceChoiceText = if ($voiceChoices.Count -gt 0) { $voiceChoices -join ", " } else { "the configured default voice" }
    $maxWords = Get-StylingMaxWords -Config $Config -ProviderSettings $ProviderSettings

    $promptLines = @(Get-ObjectValue -Object (Get-ObjectValue -Object (Get-ObjectValue -Object $Config -Key "prompts" -Default $null) -Key "styling" -Default $null) -Key "systemLines" -Default @())
    if ($promptLines.Count -eq 0) {
        $promptLines = @(
        "You turn coding-assistant notifications into short spoken DJ or MC announcements.",
        "Use the current music metadata to infer style, tempo, mood, narrator energy, vocabulary, and rhythm. Make it sound like a DJ or MC speaking over that music. If no music is available, use a neutral MC style.",
        "Avoid stock phrases, catchphrases, parody lines, and generic genre cliches. Use the music as atmosphere, not a costume.",
        "Keep the main meaning. Skip file paths, shell commands, and long technical strings; summarize them naturally. Stay mostly in the notification's language.",
        "Be concise: one or two spoken sentences, max {{maxWords}} words.",
        "Make a strong, plausible call on dynamism. Do not default to neutral energy unless the track clearly calls for it. Decide whether the delivery should feel restrained, driving, breathy, clipped, warm, tense, dramatic, intimate, or high-voltage.",
        "Set voice.speed deliberately between 0.85 and 1.20: slower for spacious, heavy, smoky, or dramatic tracks; faster for bright, driving, dance, punk, or high-energy tracks.",
        "Voice instructions must be concrete and performable: describe vocal energy, pacing, intensity, pauses, emotional temperature, delivery archetype, and how hard the speaker should push the words.",
        "Choose voice.voice from this OpenAI-compatible list only: {{voiceChoices}}. Pick the closest timbre; do not invent voice names.",
        "Return JSON only: { `"text`": `"spoken announcement`", `"voice`": { `"instructions`": `"voice direction for TTS`", `"voice`": `"voice name from the allowed list`", `"speed`": 1.0, `"energy`": `"low|medium|high`", `"pace`": `"slow|medium|fast`", `"response_format`": `"mp3`" } }"
        )
    }

    $resolvedLines = @()
    foreach ($line in $promptLines) {
        $resolvedLines += ([string]$line).Replace("{{maxWords}}", [string]$maxWords).Replace("{{voiceChoices}}", $voiceChoiceText)
    }

    return $resolvedLines -join "`n`n"
}

function Invoke-GeminiStyling {
    param(
        [string]$ProjectRoot,
        [hashtable]$SpeakableFacts,
        [hashtable]$NowPlaying,
        $Config
    )

    $textSettings = Get-ProviderSettings -Config $Config -Provider "gemini" -Capability "text"
    $model = Get-ConfiguredTextModel -Config $Config -Provider "gemini" -ProviderSettings $textSettings
    $secret = Get-VoiceNotifierSecret -ProjectRoot $ProjectRoot -Names @((Get-ObjectValue -Object $textSettings -Key "apiKeyEnvironmentVariables" -Default @("GOOGLE_API_KEY", "GEMINI_API_KEY")))
    if ([string]::IsNullOrWhiteSpace([string]$secret.value)) {
        return [ordered]@{
            ok = $false
            fallbackReason = "Gemini API key not found. Set GEMINI_API_KEY, GOOGLE_API_KEY, or config\secrets.local.json."
            secretSource = $secret.source
        }
    }

    $systemInstruction = New-StylingSystemInstruction -Config $Config -ProviderSettings $textSettings
    $inputText = New-GeminiStylingPrompt -SpeakableFacts $SpeakableFacts -NowPlaying $NowPlaying -Config $Config
    $body = [ordered]@{
        systemInstruction = [ordered]@{
            parts = @(
                [ordered]@{ text = $systemInstruction }
            )
        }
        contents = @(
            [ordered]@{
                role = "user"
                parts = @(
                    [ordered]@{ text = $inputText }
                )
            }
        )
        generationConfig = [ordered]@{
            temperature = [double](Get-ObjectValue -Object $textSettings -Key "temperature" -Default 0.9)
            responseMimeType = "application/json"
        }
    } | ConvertTo-Json -Depth 14

    $modelEscaped = [uri]::EscapeDataString($model)
    $uri = ([string](Get-ObjectValue -Object $textSettings -Key "endpoint" -Default "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent")).Replace("{model}", $modelEscaped)

    $retryAttempts = 0
    $retryDelayMs = 2500
    try {
        $retryAttempts = [Math]::Max(0, [int](Get-ObjectValue -Object $textSettings -Key "retryAttempts" -Default 0))
        $retryDelayMs = [Math]::Max(0, [int](Get-ObjectValue -Object $textSettings -Key "retryDelayMs" -Default 2500))
    } catch {
        $retryAttempts = 0
        $retryDelayMs = 2500
    }

    $attempts = @()
    $response = $null
    $lastError = ""
    for ($attempt = 0; $attempt -le $retryAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $uri `
                -Headers @{ "x-goog-api-key" = [string]$secret.value; "Content-Type" = "application/json" } `
                -Body $body `
                -TimeoutSec ([int](Get-ObjectValue -Object $textSettings -Key "timeoutSeconds" -Default 20))

            $attempts += [ordered]@{
                attempt = $attempt + 1
                ok = $true
                model = $model
            }
            break
        } catch {
            $lastError = Get-ExceptionDetailMessage -ErrorRecord $_
            $attempts += [ordered]@{
                attempt = $attempt + 1
                ok = $false
                model = $model
                error = $lastError
            }
            if ($attempt -lt $retryAttempts -and $retryDelayMs -gt 0) {
                Start-Sleep -Milliseconds $retryDelayMs
            }
        }
    }

    if ($null -eq $response) {
        return [ordered]@{
            ok = $false
            provider = "gemini"
            fallbackReason = "Gemini request failed after $($retryAttempts + 1) attempt(s): $lastError"
            secretSource = $secret.source
            attempts = $attempts
        }
    }

    try {
        $outputText = Get-GeminiOutputText -Response $response
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            return [ordered]@{
                ok = $false
                provider = "gemini"
                fallbackReason = "Gemini returned no output text."
                secretSource = $secret.source
                attempts = $attempts
            }
        }

        $stylingOutput = ConvertFrom-StylingModelOutput -OutputText $outputText

        if ([string]::IsNullOrWhiteSpace([string]$stylingOutput.text)) {
            return [ordered]@{
                ok = $false
                provider = "gemini"
                fallbackReason = "Gemini output did not include text."
                rawOutput = $outputText
                secretSource = $secret.source
                attempts = $attempts
            }
        }

        return [ordered]@{
            ok = $true
            provider = "gemini"
            used = $true
            secretSource = $secret.source
            attempts = $attempts
            requestInput = $inputText
            rawOutput = $outputText
            text = [string]$stylingOutput.text
            voice = $stylingOutput.voice
        }
    } catch {
        return [ordered]@{
            ok = $false
            provider = "gemini"
            fallbackReason = "Gemini response handling failed: $(Get-ExceptionDetailMessage -ErrorRecord $_)"
            secretSource = $secret.source
            attempts = $attempts
        }
    }
}

function Get-OpenAIResponseOutputText {
    param($Response)

    $directOutput = [string](Get-ObjectValue -Object $Response -Key "output_text" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($directOutput)) {
        return $directOutput
    }

    $texts = @()
    $outputItems = @(Get-ObjectValue -Object $Response -Key "output" -Default @())
    foreach ($outputItem in $outputItems) {
        $contentItems = @(Get-ObjectValue -Object $outputItem -Key "content" -Default @())
        foreach ($contentItem in $contentItems) {
            $textValue = Get-ObjectValue -Object $contentItem -Key "text" -Default $null
            if ($null -ne $textValue -and -not [string]::IsNullOrWhiteSpace([string]$textValue)) {
                $texts += [string]$textValue
            }
        }
    }

    return ($texts -join "`n").Trim()
}

function Invoke-OpenAIStyling {
    param(
        [string]$ProjectRoot,
        [hashtable]$SpeakableFacts,
        [hashtable]$NowPlaying,
        $Config
    )

    $textSettings = Get-ProviderSettings -Config $Config -Provider "openai" -Capability "text"
    $model = Get-ConfiguredTextModel -Config $Config -Provider "openai" -ProviderSettings $textSettings
    $secret = Get-VoiceNotifierSecret -ProjectRoot $ProjectRoot -Names @([string](Get-ObjectValue -Object $textSettings -Key "apiKeyEnvironmentVariable" -Default "OPENAI_API_KEY"))
    if ([string]::IsNullOrWhiteSpace([string]$secret.value)) {
        return [ordered]@{
            ok = $false
            provider = "openai"
            fallbackReason = "OpenAI API key not found. Set OPENAI_API_KEY or add config\openaiapikey.secret."
            secretSource = $secret.source
        }
    }

    $systemInstruction = New-StylingSystemInstruction -Config $Config -ProviderSettings $textSettings
    $inputText = New-GeminiStylingPrompt -SpeakableFacts $SpeakableFacts -NowPlaying $NowPlaying -Config $Config

    $schema = [ordered]@{
        type = "object"
        additionalProperties = $false
        required = @("text", "voice")
        properties = [ordered]@{
            text = [ordered]@{
                type = "string"
                description = "The spoken notification text."
            }
            voice = [ordered]@{
                type = "object"
                additionalProperties = $false
                required = @("instructions", "voice", "speed", "energy", "pace", "response_format")
                properties = [ordered]@{
                    instructions = [ordered]@{
                        type = "string"
                        description = "Concrete delivery instructions for OpenAI TTS."
                    }
                    voice = [ordered]@{
                        type = "string"
                        description = "OpenAI-compatible voice name from the allowed list."
                    }
                    speed = [ordered]@{
                        type = "number"
                        minimum = 0.85
                        maximum = 1.2
                    }
                    energy = [ordered]@{
                        type = "string"
                        enum = @("low", "medium", "high")
                    }
                    pace = [ordered]@{
                        type = "string"
                        enum = @("slow", "medium", "fast")
                    }
                    response_format = [ordered]@{
                        type = "string"
                        enum = @("mp3")
                    }
                }
            }
        }
    }

    $requestBodyObject = [ordered]@{
        model = $model
        instructions = $systemInstruction
        input = $inputText
        max_output_tokens = [int](Get-ObjectValue -Object $textSettings -Key "maxOutputTokens" -Default 420)
        store = $false
        text = [ordered]@{
            format = [ordered]@{
                type = "json_schema"
                name = "voice_notification_style"
                strict = $true
                schema = $schema
            }
        }
    }
    $requestBody = $requestBodyObject | ConvertTo-Json -Depth 20
    $requestBodyBytes = [System.Text.Encoding]::UTF8.GetBytes($requestBody)

    $retryAttempts = 0
    $retryDelayMs = 1200
    try {
        $retryAttempts = [Math]::Max(0, [int](Get-ObjectValue -Object $textSettings -Key "retryAttempts" -Default 0))
        $retryDelayMs = [Math]::Max(0, [int](Get-ObjectValue -Object $textSettings -Key "retryDelayMs" -Default 1200))
    } catch {
        $retryAttempts = 0
        $retryDelayMs = 1200
    }

    $attempts = @()
    $response = $null
    $lastError = ""
    for ($attempt = 0; $attempt -le $retryAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri ([string](Get-ObjectValue -Object $textSettings -Key "endpoint" -Default "https://api.openai.com/v1/responses")) `
                -Headers @{
                    "Authorization" = "Bearer $([string]$secret.value)"
                } `
                -ContentType "application/json; charset=utf-8" `
                -Body $requestBodyBytes `
                -TimeoutSec ([int](Get-ObjectValue -Object $textSettings -Key "timeoutSeconds" -Default 20))

            $attempts += [ordered]@{
                attempt = $attempt + 1
                ok = $true
                model = $model
            }
            break
        } catch {
            $lastError = Get-ExceptionDetailMessage -ErrorRecord $_
            $attempts += [ordered]@{
                attempt = $attempt + 1
                ok = $false
                model = $model
                error = $lastError
            }
            if ($attempt -lt $retryAttempts -and $retryDelayMs -gt 0) {
                Start-Sleep -Milliseconds $retryDelayMs
            }
        }
    }

    if ($null -eq $response) {
        return [ordered]@{
            ok = $false
            provider = "openai"
            fallbackReason = "OpenAI styling request failed after $($retryAttempts + 1) attempt(s): $lastError"
            secretSource = $secret.source
            attempts = $attempts
            requestInput = $inputText
        }
    }

    try {
        $outputText = Get-OpenAIResponseOutputText -Response $response
        if ([string]::IsNullOrWhiteSpace($outputText)) {
            return [ordered]@{
                ok = $false
                provider = "openai"
                fallbackReason = "OpenAI styling returned no output text."
                secretSource = $secret.source
                attempts = $attempts
                requestInput = $inputText
            }
        }

        $stylingOutput = ConvertFrom-StylingModelOutput -OutputText $outputText
        if ([string]::IsNullOrWhiteSpace([string]$stylingOutput.text)) {
            return [ordered]@{
                ok = $false
                provider = "openai"
                fallbackReason = "OpenAI styling output did not include text."
                rawOutput = $outputText
                secretSource = $secret.source
                attempts = $attempts
                requestInput = $inputText
            }
        }

        return [ordered]@{
            ok = $true
            provider = "openai"
            used = $true
            secretSource = $secret.source
            attempts = $attempts
            model = [string](Get-ObjectValue -Object $response -Key "model" -Default $model)
            usage = (Get-ObjectValue -Object $response -Key "usage" -Default $null)
            requestInput = $inputText
            rawOutput = $outputText
            text = [string]$stylingOutput.text
            voice = $stylingOutput.voice
        }
    } catch {
        return [ordered]@{
            ok = $false
            provider = "openai"
            fallbackReason = "OpenAI styling response handling failed: $(Get-ExceptionDetailMessage -ErrorRecord $_)"
            secretSource = $secret.source
            attempts = $attempts
            requestInput = $inputText
        }
    }
}

function Initialize-AudioDuckingSupport {
    if ([type]::GetType("VoiceNotifierAudio.AudioSessionManager", $false)) {
        return
    }

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace VoiceNotifierAudio
{
    public class AudioSessionVolumeChange
    {
        public int ProcessId;
        public string ProcessName;
        public string SessionInstanceIdentifier;
        public float OriginalVolume;
        public float TargetVolume;
    }

    public static class AudioSessionManager
    {
        public static List<AudioSessionVolumeChange> SetProcessVolume(string processName, float targetVolume)
        {
            List<AudioSessionVolumeChange> changes = new List<AudioSessionVolumeChange>();
            targetVolume = ClampVolume(targetVolume);

            foreach (SessionInfo session in EnumerateSessions())
            {
                if (!String.Equals(session.ProcessName, processName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                float originalVolume;
                int getResult = session.Volume.GetMasterVolume(out originalVolume);
                if (getResult != 0)
                {
                    continue;
                }

                Guid eventContext = Guid.Empty;
                int setResult = session.Volume.SetMasterVolume(targetVolume, ref eventContext);
                if (setResult != 0)
                {
                    continue;
                }

                changes.Add(new AudioSessionVolumeChange
                {
                    ProcessId = session.ProcessId,
                    ProcessName = session.ProcessName,
                    SessionInstanceIdentifier = session.SessionInstanceIdentifier,
                    OriginalVolume = originalVolume,
                    TargetVolume = targetVolume
                });
            }

            return changes;
        }

        public static List<AudioSessionVolumeChange> RestoreVolumes(List<AudioSessionVolumeChange> changes)
        {
            List<AudioSessionVolumeChange> restored = new List<AudioSessionVolumeChange>();
            if (changes == null || changes.Count == 0)
            {
                return restored;
            }

            Dictionary<string, AudioSessionVolumeChange> bySession = new Dictionary<string, AudioSessionVolumeChange>();
            foreach (AudioSessionVolumeChange change in changes)
            {
                if (!String.IsNullOrWhiteSpace(change.SessionInstanceIdentifier) && !bySession.ContainsKey(change.SessionInstanceIdentifier))
                {
                    bySession.Add(change.SessionInstanceIdentifier, change);
                }
            }

            foreach (SessionInfo session in EnumerateSessions())
            {
                AudioSessionVolumeChange change = null;
                if (!String.IsNullOrWhiteSpace(session.SessionInstanceIdentifier) && bySession.ContainsKey(session.SessionInstanceIdentifier))
                {
                    change = bySession[session.SessionInstanceIdentifier];
                }
                else
                {
                    foreach (AudioSessionVolumeChange candidate in changes)
                    {
                        if (candidate.ProcessId == session.ProcessId &&
                            String.Equals(candidate.ProcessName, session.ProcessName, StringComparison.OrdinalIgnoreCase))
                        {
                            change = candidate;
                            break;
                        }
                    }
                }

                if (change == null)
                {
                    continue;
                }

                Guid eventContext = Guid.Empty;
                int setResult = session.Volume.SetMasterVolume(ClampVolume(change.OriginalVolume), ref eventContext);
                if (setResult == 0)
                {
                    restored.Add(change);
                }
            }

            return restored;
        }

        public static List<AudioSessionVolumeChange> GetProcessVolumes(string processName)
        {
            List<AudioSessionVolumeChange> volumes = new List<AudioSessionVolumeChange>();
            foreach (SessionInfo session in EnumerateSessions())
            {
                if (!String.Equals(session.ProcessName, processName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                float currentVolume;
                if (session.Volume.GetMasterVolume(out currentVolume) != 0)
                {
                    continue;
                }

                volumes.Add(new AudioSessionVolumeChange
                {
                    ProcessId = session.ProcessId,
                    ProcessName = session.ProcessName,
                    SessionInstanceIdentifier = session.SessionInstanceIdentifier,
                    OriginalVolume = currentVolume,
                    TargetVolume = currentVolume
                });
            }

            return volumes;
        }

        private static float ClampVolume(float volume)
        {
            if (volume < 0.0f) { return 0.0f; }
            if (volume > 1.0f) { return 1.0f; }
            return volume;
        }

        private static List<SessionInfo> EnumerateSessions()
        {
            List<SessionInfo> sessions = new List<SessionInfo>();
            IMMDeviceEnumerator deviceEnumerator = null;
            IMMDevice device = null;
            object managerObject = null;
            IAudioSessionEnumerator sessionEnumerator = null;

            try
            {
                deviceEnumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
                int endpointResult = deviceEnumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, ERole.eMultimedia, out device);
                if (endpointResult != 0 || device == null)
                {
                    return sessions;
                }

                Guid managerGuid = typeof(IAudioSessionManager2).GUID;
                int activateResult = device.Activate(ref managerGuid, CLSCTX.ALL, IntPtr.Zero, out managerObject);
                if (activateResult != 0 || managerObject == null)
                {
                    return sessions;
                }

                IAudioSessionManager2 sessionManager = (IAudioSessionManager2)managerObject;
                int enumResult = sessionManager.GetSessionEnumerator(out sessionEnumerator);
                if (enumResult != 0 || sessionEnumerator == null)
                {
                    return sessions;
                }

                int count;
                if (sessionEnumerator.GetCount(out count) != 0)
                {
                    return sessions;
                }

                for (int i = 0; i < count; i++)
                {
                    IAudioSessionControl control = null;
                    if (sessionEnumerator.GetSession(i, out control) != 0 || control == null)
                    {
                        continue;
                    }

                    IAudioSessionControl2 control2 = control as IAudioSessionControl2;
                    ISimpleAudioVolume volume = control as ISimpleAudioVolume;
                    if (control2 == null || volume == null)
                    {
                        continue;
                    }

                    int processId;
                    if (control2.GetProcessId(out processId) != 0 || processId <= 0)
                    {
                        continue;
                    }

                    string processName = "";
                    try
                    {
                        processName = Process.GetProcessById(processId).ProcessName;
                    }
                    catch
                    {
                        processName = "";
                    }

                    string sessionInstanceIdentifier = "";
                    try
                    {
                        control2.GetSessionInstanceIdentifier(out sessionInstanceIdentifier);
                    }
                    catch
                    {
                        sessionInstanceIdentifier = "";
                    }

                    sessions.Add(new SessionInfo
                    {
                        ProcessId = processId,
                        ProcessName = processName,
                        SessionInstanceIdentifier = sessionInstanceIdentifier,
                        Volume = volume
                    });
                }
            }
            catch
            {
                return sessions;
            }

            return sessions;
        }

        private class SessionInfo
        {
            public int ProcessId;
            public string ProcessName;
            public string SessionInstanceIdentifier;
            public ISimpleAudioVolume Volume;
        }
    }

    public enum EDataFlow
    {
        eRender = 0,
        eCapture = 1,
        eAll = 2
    }

    public enum ERole
    {
        eConsole = 0,
        eMultimedia = 1,
        eCommunications = 2
    }

    [Flags]
    public enum CLSCTX
    {
        INPROC_SERVER = 0x1,
        INPROC_HANDLER = 0x2,
        LOCAL_SERVER = 0x4,
        REMOTE_SERVER = 0x10,
        ALL = INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER | REMOTE_SERVER
    }

    [ComImport]
    [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    internal class MMDeviceEnumerator
    {
    }

    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, uint dwStateMask, out IntPtr ppDevices);

        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppEndpoint);

        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);

        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr pClient);

        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMMDevice
    {
        [PreserveSig]
        int Activate(ref Guid iid, CLSCTX dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);

        [PreserveSig]
        int OpenPropertyStore(int stgmAccess, out IntPtr ppProperties);

        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);

        [PreserveSig]
        int GetState(out int pdwState);
    }

    [ComImport]
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionManager2
    {
        [PreserveSig]
        int GetAudioSessionControl(IntPtr audioSessionGuid, int streamFlags, out IAudioSessionControl sessionControl);

        [PreserveSig]
        int GetSimpleAudioVolume(IntPtr audioSessionGuid, int streamFlags, out ISimpleAudioVolume audioVolume);

        [PreserveSig]
        int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);

        [PreserveSig]
        int RegisterSessionNotification(IntPtr sessionNotification);

        [PreserveSig]
        int UnregisterSessionNotification(IntPtr sessionNotification);

        [PreserveSig]
        int RegisterDuckNotification(string sessionID, IntPtr duckNotification);

        [PreserveSig]
        int UnregisterDuckNotification(IntPtr duckNotification);
    }

    [ComImport]
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionEnumerator
    {
        [PreserveSig]
        int GetCount(out int sessionCount);

        [PreserveSig]
        int GetSession(int sessionCount, out IAudioSessionControl session);
    }

    [ComImport]
    [Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl
    {
        [PreserveSig]
        int GetState(out int state);

        [PreserveSig]
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string displayName);

        [PreserveSig]
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string displayName, ref Guid eventContext);

        [PreserveSig]
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string iconPath);

        [PreserveSig]
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string iconPath, ref Guid eventContext);

        [PreserveSig]
        int GetGroupingParam(out Guid groupingId);

        [PreserveSig]
        int SetGroupingParam(ref Guid groupingId, ref Guid eventContext);

        [PreserveSig]
        int RegisterAudioSessionNotification(IntPtr client);

        [PreserveSig]
        int UnregisterAudioSessionNotification(IntPtr client);
    }

    [ComImport]
    [Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IAudioSessionControl2
    {
        [PreserveSig]
        int GetState(out int state);

        [PreserveSig]
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string displayName);

        [PreserveSig]
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string displayName, ref Guid eventContext);

        [PreserveSig]
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string iconPath);

        [PreserveSig]
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string iconPath, ref Guid eventContext);

        [PreserveSig]
        int GetGroupingParam(out Guid groupingId);

        [PreserveSig]
        int SetGroupingParam(ref Guid groupingId, ref Guid eventContext);

        [PreserveSig]
        int RegisterAudioSessionNotification(IntPtr client);

        [PreserveSig]
        int UnregisterAudioSessionNotification(IntPtr client);

        [PreserveSig]
        int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string sessionId);

        [PreserveSig]
        int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string sessionInstanceId);

        [PreserveSig]
        int GetProcessId(out int processId);

        [PreserveSig]
        int IsSystemSoundsSession();

        [PreserveSig]
        int SetDuckingPreference(bool optOut);
    }

    [ComImport]
    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISimpleAudioVolume
    {
        [PreserveSig]
        int SetMasterVolume(float level, ref Guid eventContext);

        [PreserveSig]
        int GetMasterVolume(out float level);

        [PreserveSig]
        int SetMute(bool isMuted, ref Guid eventContext);

        [PreserveSig]
        int GetMute(out bool isMuted);
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Start-AudioDucking {
    param($Config)

    $duckingConfig = $Config.tts.audioDucking
    if ($null -eq $duckingConfig -or -not [bool]$duckingConfig.enabled) {
        return [ordered]@{
            enabled = $false
            applied = $false
            reason = "disabled"
        }
    }

    try {
        Initialize-AudioDuckingSupport
        $processName = [string]$duckingConfig.targetProcessName
        $targetVolume = [float]$duckingConfig.duckVolume
        $changes = [VoiceNotifierAudio.AudioSessionManager]::SetProcessVolume($processName, $targetVolume)
        return [ordered]@{
            enabled = $true
            applied = ($changes.Count -gt 0)
            targetProcessName = $processName
            targetVolume = $targetVolume
            changedSessions = $changes.Count
            changes = $changes
        }
    } catch {
        return [ordered]@{
            enabled = $true
            applied = $false
            error = $_.Exception.Message
        }
    }
}

function Stop-AudioDucking {
    param(
        [hashtable]$DuckingState,
        $Config
    )

    if ($null -eq $DuckingState -or -not $DuckingState.applied) {
        return [ordered]@{
            restored = $false
            reason = "not applied"
        }
    }

    try {
        $delayMs = 0
        if ($null -ne $Config.tts.audioDucking.restoreDelayMs) {
            $delayMs = [int]$Config.tts.audioDucking.restoreDelayMs
        }
        if ($delayMs -gt 0) {
            Start-Sleep -Milliseconds $delayMs
        }

        Initialize-AudioDuckingSupport
        $restored = [VoiceNotifierAudio.AudioSessionManager]::RestoreVolumes($DuckingState.changes)
        return [ordered]@{
            restored = ($restored.Count -gt 0)
            restoredSessions = $restored.Count
        }
    } catch {
        return [ordered]@{
            restored = $false
            error = $_.Exception.Message
        }
    }
}

function Get-LocalVoiceName {
    param($Config)

    $speechSettings = Get-ProviderSettings -Config $Config -Provider "local" -Capability "speech"
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    try {
        $installed = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
        $configuredVoice = [string](Get-ObjectValue -Object $speechSettings -Key "voice" -Default "")
        if (-not [string]::IsNullOrWhiteSpace($configuredVoice) -and $installed -contains $configuredVoice) {
            return $configuredVoice
        }

        foreach ($voice in @(Get-ObjectValue -Object $speechSettings -Key "preferredVoices" -Default @())) {
            if ($installed -contains [string]$voice) {
                return [string]$voice
            }
        }

        if ($installed.Count -gt 0) {
            return [string]$installed[0]
        }
    } finally {
        $synth.Dispose()
    }

    return ""
}

function Invoke-LocalSpeech {
    param(
        [string]$Text,
        $Config,
        [hashtable]$StyleSelection,
        [bool]$Speak
    )

    if (-not $Speak) {
        return [ordered]@{
            provider = "local"
            spoken = $false
            skipped = $true
            reason = "NoSpeak mode"
            audioDucking = [ordered]@{
                duck = [ordered]@{ enabled = $false; applied = $false; reason = "NoSpeak mode" }
                restore = [ordered]@{ restored = $false; reason = "NoSpeak mode" }
            }
        }
    }

    $duckingState = [ordered]@{ enabled = $false; applied = $false; reason = "not started" }
    $restoreState = [ordered]@{ restored = $false; reason = "not started" }
    $result = $null
    $synth = $null

    try {
        $speechSettings = Get-ProviderSettings -Config $Config -Provider "local" -Capability "speech"
        Add-Type -AssemblyName System.Speech
        $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
        try {
            $voice = Get-LocalVoiceName -Config $Config
            if (-not [string]::IsNullOrWhiteSpace($voice)) {
                $synth.SelectVoice($voice)
            }

            $rate = [int](Get-ObjectValue -Object $speechSettings -Key "rate" -Default 0)
            $volume = [int](Get-ObjectValue -Object $speechSettings -Key "volume" -Default 100)
            if ($null -ne $StyleSelection.profile.rate) {
                $rate = [int]$StyleSelection.profile.rate
            }
            if ($null -ne $StyleSelection.profile.volume) {
                $volume = [int]$StyleSelection.profile.volume
            }

            $synth.Rate = [Math]::Max(-10, [Math]::Min(10, $rate))
            $synth.Volume = [Math]::Max(0, [Math]::Min(100, $volume))
            $duckingState = Start-AudioDucking -Config $Config
            $synth.Speak($Text)

            $result = [ordered]@{
                provider = "local"
                spoken = $true
                skipped = $false
                voice = $voice
                rate = $synth.Rate
                volume = $synth.Volume
            }
        } finally {
            $restoreState = Stop-AudioDucking -DuckingState $duckingState -Config $Config
            if ($null -ne $synth) {
                $synth.Dispose()
            }
        }

        $result["audioDucking"] = [ordered]@{
            duck = $duckingState
            restore = $restoreState
        }
        return $result
    } catch {
        return [ordered]@{
            provider = "local"
            spoken = $false
            skipped = $false
            error = $_.Exception.Message
            audioDucking = [ordered]@{
                duck = $duckingState
                restore = $restoreState
            }
        }
    }
}

function New-SafeFileStem {
    param(
        [string]$Prefix = "voice-notification"
    )

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return "$Prefix-$timestamp"
}

function Resolve-VoiceNotifierPath {
    param(
        [string]$ProjectRoot,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return Join-Path $ProjectRoot $Path
}

function Get-ShouldSaveSpeechAudio {
    param(
        $SpeechSettings,
        [bool]$SaveAudio
    )

    if ($SaveAudio) {
        return $true
    }

    return [bool](Get-ObjectValue -Object $SpeechSettings -Key "saveAudioByDefault" -Default $false)
}

function New-SpeechAudioTarget {
    param(
        [string]$ProjectRoot,
        $SpeechSettings,
        [string]$Prefix,
        [string]$Extension,
        [bool]$SaveAudio
    )

    $stem = New-SafeFileStem -Prefix $Prefix
    if ($SaveAudio) {
        $outputDir = Resolve-VoiceNotifierPath -ProjectRoot $ProjectRoot -Path ([string](Get-ObjectValue -Object $SpeechSettings -Key "outputDirectory" -Default "output/audio"))
        if (-not (Test-Path -LiteralPath $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

        return [ordered]@{
            audioPath = Join-Path $outputDir "$stem.$Extension"
            metadataPath = Join-Path $outputDir "$stem.json"
            saveAudio = $true
            transient = $false
        }
    }

    return [ordered]@{
        audioPath = Join-Path ([System.IO.Path]::GetTempPath()) "$stem.$Extension"
        metadataPath = ""
        saveAudio = $false
        transient = $true
    }
}

function Get-ElevenLabsVoice {
    param(
        [string]$ApiKey,
        $Config,
        $SpeechSettings
    )

    if ($null -eq $SpeechSettings) {
        $SpeechSettings = Get-ProviderSettings -Config $Config -Provider "elevenlabs" -Capability "speech"
    }

    $configuredVoiceId = [string](Get-ObjectValue -Object $SpeechSettings -Key "voiceId" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($configuredVoiceId)) {
        return [ordered]@{
            voiceId = $configuredVoiceId
            voiceName = "configured"
            source = "config"
        }
    }

    try {
        $voicesResponse = Invoke-RestMethod `
            -Method Get `
            -Uri ([string](Get-ObjectValue -Object $SpeechSettings -Key "voicesEndpoint" -Default "https://api.elevenlabs.io/v1/voices")) `
            -Headers @{ "xi-api-key" = $ApiKey } `
            -TimeoutSec 20

        $voices = @($voicesResponse.voices)
        if ($voices.Count -gt 0) {
            $preferred = @($voices | Where-Object { [string]$_.name -match "(?i)rachel|adam|antoni|bella|josh|arnold|domi|elli" } | Select-Object -First 1)
            if ($preferred.Count -eq 0) {
                $preferred = @($voices | Select-Object -First 1)
            }

            return [ordered]@{
                voiceId = [string]$preferred[0].voice_id
                voiceName = [string]$preferred[0].name
                source = "elevenlabs-voices"
            }
        }
    } catch {
        return [ordered]@{
            voiceId = "21m00Tcm4TlvDq8ikWAM"
            voiceName = "Rachel fallback"
            source = "fallback-after-voice-list-error"
            error = $_.Exception.Message
        }
    }

    return [ordered]@{
        voiceId = "21m00Tcm4TlvDq8ikWAM"
        voiceName = "Rachel fallback"
        source = "fallback"
    }
}

function Invoke-ElevenLabsSpeech {
    param(
        [string]$ProjectRoot,
        [string]$Text,
        [string]$VoiceInstructions,
        $Config,
        [bool]$Speak,
        [bool]$SaveAudio
    )

    if (-not $Speak) {
        return [ordered]@{
            provider = "elevenlabs"
            spoken = $false
            skipped = $true
            saved = $false
            reason = "NoSpeak mode"
        }
    }

    $speechSettings = Get-ProviderSettings -Config $Config -Provider "elevenlabs" -Capability "speech"
    $secret = Get-VoiceNotifierSecret -ProjectRoot $ProjectRoot -Names @([string](Get-ObjectValue -Object $speechSettings -Key "apiKeyEnvironmentVariable" -Default "ELEVENLABS_API_KEY"))
    if ([string]::IsNullOrWhiteSpace([string]$secret.value)) {
        return [ordered]@{
            provider = "elevenlabs"
            spoken = $false
            skipped = $false
            saved = $false
            error = "ElevenLabs API key not found. Set ELEVENLABS_API_KEY or config\elevenlabsvoice.secret."
            secretSource = $secret.source
        }
    }

    $audioPath = ""
    $metadataPath = ""
    $deleteTransientAudio = $false
    $transientAudioDeleted = $false
    try {
        $voice = Get-ElevenLabsVoice -ApiKey ([string]$secret.value) -Config $Config -SpeechSettings $speechSettings
        $outputFormat = [string](Get-ObjectValue -Object $speechSettings -Key "outputFormat" -Default "mp3_44100_128")
        $extension = if ($outputFormat -match "^mp3") { "mp3" } else { "bin" }

        $saveAudioEffective = Get-ShouldSaveSpeechAudio -SpeechSettings $speechSettings -SaveAudio $SaveAudio
        $audioTarget = New-SpeechAudioTarget -ProjectRoot $ProjectRoot -SpeechSettings $speechSettings -Prefix "elevenlabs-notification" -Extension $extension -SaveAudio $saveAudioEffective
        $audioPath = [string]$audioTarget.audioPath
        $metadataPath = [string]$audioTarget.metadataPath
        $deleteTransientAudio = [bool]$audioTarget.transient

        $voiceSettings = ConvertTo-HashtableDeep (Get-ObjectValue -Object $speechSettings -Key "voiceSettings" -Default ([pscustomobject]@{}))
        $requestBodyObject = [ordered]@{
            text = $Text
            model_id = [string](Get-ObjectValue -Object $speechSettings -Key "modelId" -Default "eleven_multilingual_v2")
            voice_settings = $voiceSettings
        }
        $requestBody = $requestBodyObject | ConvertTo-Json -Depth 10

        $voiceIdEscaped = [uri]::EscapeDataString([string]$voice.voiceId)
        $uri = ([string](Get-ObjectValue -Object $speechSettings -Key "endpoint" -Default "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}")).Replace("{voice_id}", $voiceIdEscaped)
        if (-not [string]::IsNullOrWhiteSpace($outputFormat)) {
            $separator = if ($uri.Contains("?")) { "&" } else { "?" }
            $uri = "$uri${separator}output_format=$([uri]::EscapeDataString($outputFormat))"
        }

        Invoke-WebRequest `
            -Method Post `
            -Uri $uri `
            -Headers @{
                "xi-api-key" = [string]$secret.value
                "Accept" = "audio/mpeg"
                "Content-Type" = "application/json"
            } `
            -Body $requestBody `
            -OutFile $audioPath `
            -TimeoutSec 60 | Out-Null

        $metadata = [ordered]@{
            timestamp = (Get-Date).ToString("o")
            provider = "elevenlabs"
            audioPath = if ($saveAudioEffective) { $audioPath } else { "" }
            text = $Text
            voiceInstructions = $VoiceInstructions
            voice = $voice
            request = $requestBodyObject
            outputFormat = $outputFormat
        }
        if ($saveAudioEffective) {
            $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        }

        $audioItem = Get-Item -LiteralPath $audioPath
        $duckingState = Start-AudioDucking -Config $Config
        $restoreState = [ordered]@{ restored = $false; reason = "not started" }
        $playback = [ordered]@{ played = $false; reason = "not started" }
        try {
            $playback = Invoke-SavedAudioPlayback -AudioPath $audioPath -TimeoutSeconds 90
        } finally {
            $restoreState = Stop-AudioDucking -DuckingState $duckingState -Config $Config
            if ($deleteTransientAudio -and (Test-Path -LiteralPath $audioPath)) {
                Remove-Item -LiteralPath $audioPath -Force -ErrorAction SilentlyContinue
                $transientAudioDeleted = -not (Test-Path -LiteralPath $audioPath)
            }
        }

        $result = [ordered]@{
            provider = "elevenlabs"
            spoken = [bool]$playback.played
            skipped = $false
            saved = $saveAudioEffective
            bytes = $audioItem.Length
            voiceId = [string]$voice.voiceId
            voiceName = [string]$voice.voiceName
            secretSource = $secret.source
            playback = $playback
            transientAudio = -not $saveAudioEffective
            transientAudioDeleted = $transientAudioDeleted
            audioDucking = [ordered]@{
                duck = $duckingState
                restore = $restoreState
            }
        }
        if ($saveAudioEffective) {
            $result["audioPath"] = $audioPath
            $result["metadataPath"] = $metadataPath
        }
        return $result
    } catch {
        if ($deleteTransientAudio -and -not [string]::IsNullOrWhiteSpace($audioPath) -and (Test-Path -LiteralPath $audioPath)) {
            Remove-Item -LiteralPath $audioPath -Force -ErrorAction SilentlyContinue
        }
        return [ordered]@{
            provider = "elevenlabs"
            spoken = $false
            skipped = $false
            saved = $false
            error = $_.Exception.Message
            secretSource = $secret.source
        }
    }
}

function Invoke-SavedAudioPlayback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AudioPath,
        [int]$TimeoutSeconds = 90
    )

    if (-not (Test-Path -LiteralPath $AudioPath)) {
        return [ordered]@{
            played = $false
            method = "none"
            error = "Audio file not found: $AudioPath"
        }
    }

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $AudioPath).Path
        $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()

        if ($extension -eq ".wav") {
            $soundPlayer = New-Object System.Media.SoundPlayer
            $soundPlayer.SoundLocation = $resolvedPath
            $soundPlayer.Load()
            $soundPlayer.PlaySync()
            return [ordered]@{
                played = $true
                method = "System.Media.SoundPlayer"
            }
        }

        Initialize-MciPlaybackSupport
        $mciResult = [VoiceNotifierAudio.MciPlayback]::PlayWait($resolvedPath, $TimeoutSeconds)
        return [ordered]@{
            played = [bool]$mciResult.Success
            method = "winmm.mciSendString"
            message = [string]$mciResult.Message
        }
    } catch {
        return [ordered]@{
            played = $false
            method = "none"
            error = $_.Exception.Message
        }
    }
}

function Initialize-MciPlaybackSupport {
    if ([type]::GetType("VoiceNotifierAudio.MciPlayback", $false)) {
        return
    }

$source = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace VoiceNotifierAudio
{
    public class MciPlaybackResult
    {
        public bool Success;
        public string Message;
    }

    public static class MciPlayback
    {
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern int mciSendString(string command, StringBuilder returnValue, int returnLength, IntPtr winHandle);

        public static MciPlaybackResult PlayWait(string path, int timeoutSeconds)
        {
            string alias = "voiceNotifier" + Guid.NewGuid().ToString("N");
            string safePath = path.Replace("\"", "");
            string extension = System.IO.Path.GetExtension(safePath);
            string openCommand;
            if (String.Equals(extension, ".mp3", StringComparison.OrdinalIgnoreCase))
            {
                openCommand = "open \"" + safePath + "\" type mpegvideo alias " + alias;
            }
            else
            {
                openCommand = "open \"" + safePath + "\" alias " + alias;
            }

            int openResult = mciSendString(openCommand, null, 0, IntPtr.Zero);
            if (openResult != 0)
            {
                return new MciPlaybackResult { Success = false, Message = "open failed: " + openResult };
            }

            try
            {
                int playResult = mciSendString("play " + alias + " wait", null, 0, IntPtr.Zero);
                if (playResult != 0)
                {
                    return new MciPlaybackResult { Success = false, Message = "play failed: " + playResult };
                }

                return new MciPlaybackResult { Success = true, Message = "played" };
            }
            finally
            {
                mciSendString("close " + alias, null, 0, IntPtr.Zero);
            }
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Resolve-OpenAITtsSettings {
    param(
        $Config,
        $VoiceSettings
    )

    $speechSettings = Get-OpenAISpeechSettings -Config $Config
    $voice = [string](Get-ObjectValue -Object $speechSettings -Key "voice" -Default "alloy")
    $voiceChoices = @()
    foreach ($voiceChoice in @(Get-ObjectValue -Object $speechSettings -Key "voiceChoices" -Default @())) {
        if (-not [string]::IsNullOrWhiteSpace([string]$voiceChoice)) {
            $voiceChoices += ([string]$voiceChoice).Trim().ToLowerInvariant()
        }
    }

    $requestedVoice = [string](Get-ObjectValue -Object $VoiceSettings -Key "voice" -Default "")
    if (-not [string]::IsNullOrWhiteSpace($requestedVoice)) {
        $candidateVoice = $requestedVoice.Trim().ToLowerInvariant()
        if ($voiceChoices.Count -eq 0 -or $voiceChoices -contains $candidateVoice) {
            $voice = $candidateVoice
        }
    }

    $speed = [double](Get-ObjectValue -Object $speechSettings -Key "speed" -Default 1.0)
    $requestedSpeed = Get-ObjectValue -Object $VoiceSettings -Key "speed" -Default $null
    if ($null -ne $requestedSpeed -and -not [string]::IsNullOrWhiteSpace([string]$requestedSpeed)) {
        $parsedSpeed = 0.0
        $styles = [System.Globalization.NumberStyles]::Float
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        if ([double]::TryParse([string]$requestedSpeed, $styles, $culture, [ref]$parsedSpeed)) {
            $speed = [Math]::Min(1.2, [Math]::Max(0.85, $parsedSpeed))
        }
    }

    $responseFormat = [string](Get-ObjectValue -Object $speechSettings -Key "responseFormat" -Default "mp3")
    if ([string]::IsNullOrWhiteSpace($responseFormat)) {
        $responseFormat = "mp3"
    }

    return [ordered]@{
        voice = $voice
        speed = $speed
        responseFormat = $responseFormat
        requested = $VoiceSettings
    }
}

function Invoke-OpenAISpeech {
    param(
        [string]$ProjectRoot,
        [string]$Text,
        [string]$VoiceInstructions,
        $VoiceSettings,
        $Config,
        [bool]$Speak,
        [bool]$SaveAudio
    )

    if (-not $Speak) {
        return [ordered]@{
            provider = "openai"
            spoken = $false
            skipped = $true
            saved = $false
            reason = "NoSpeak mode"
        }
    }

    $speechSettings = Get-OpenAISpeechSettings -Config $Config
    $secret = Get-VoiceNotifierSecret -ProjectRoot $ProjectRoot -Names @([string](Get-ObjectValue -Object $speechSettings -Key "apiKeyEnvironmentVariable" -Default "OPENAI_API_KEY"))
    if ([string]::IsNullOrWhiteSpace([string]$secret.value)) {
        return [ordered]@{
            provider = "openai"
            spoken = $false
            skipped = $false
            saved = $false
            error = "OpenAI API key not found. Set OPENAI_API_KEY or add config\openaiapikey.secret."
            secretSource = $secret.source
        }
    }

    $audioPath = ""
    $metadataPath = ""
    $deleteTransientAudio = $false
    $transientAudioDeleted = $false
    try {
        $resolvedTtsSettings = Resolve-OpenAITtsSettings -Config $Config -VoiceSettings $VoiceSettings
        $responseFormat = [string]$resolvedTtsSettings.responseFormat
        $extension = if ([string]::IsNullOrWhiteSpace($responseFormat)) { "mp3" } else { $responseFormat.ToLowerInvariant() }
        if ($extension -eq "opus") { $extension = "opus" }
        if ($extension -eq "pcm") { $extension = "pcm" }
        if ($extension -eq "wav") { $extension = "wav" }

        $saveAudioEffective = Get-ShouldSaveSpeechAudio -SpeechSettings $speechSettings -SaveAudio $SaveAudio
        $audioTarget = New-SpeechAudioTarget -ProjectRoot $ProjectRoot -SpeechSettings $speechSettings -Prefix "openai-notification" -Extension $extension -SaveAudio $saveAudioEffective
        $audioPath = [string]$audioTarget.audioPath
        $metadataPath = [string]$audioTarget.metadataPath
        $deleteTransientAudio = [bool]$audioTarget.transient

        $requestBodyObject = [ordered]@{
            model = [string](Get-ObjectValue -Object $speechSettings -Key "model" -Default "gpt-4o-mini-tts")
            input = $Text
            voice = [string]$resolvedTtsSettings.voice
            response_format = $responseFormat
            speed = [double]$resolvedTtsSettings.speed
        }
        if (-not [string]::IsNullOrWhiteSpace($VoiceInstructions)) {
            $requestBodyObject["instructions"] = $VoiceInstructions
        }

        $requestBody = $requestBodyObject | ConvertTo-Json -Depth 10
        $requestBodyBytes = [System.Text.Encoding]::UTF8.GetBytes($requestBody)

        Invoke-WebRequest `
            -Method Post `
            -Uri ([string](Get-ObjectValue -Object $speechSettings -Key "endpoint" -Default "https://api.openai.com/v1/audio/speech")) `
            -Headers @{
                "Authorization" = "Bearer $([string]$secret.value)"
            } `
            -ContentType "application/json; charset=utf-8" `
            -Body $requestBodyBytes `
            -OutFile $audioPath `
            -TimeoutSec 60 | Out-Null

        $metadata = [ordered]@{
            timestamp = (Get-Date).ToString("o")
            provider = "openai"
            audioPath = if ($saveAudioEffective) { $audioPath } else { "" }
            text = $Text
            voiceInstructions = $VoiceInstructions
            voiceSettings = $VoiceSettings
            request = $requestBodyObject
        }
        if ($saveAudioEffective) {
            $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
        }

        $audioItem = Get-Item -LiteralPath $audioPath
        $duckingState = Start-AudioDucking -Config $Config
        $restoreState = [ordered]@{ restored = $false; reason = "not started" }
        $playback = [ordered]@{ played = $false; reason = "not started" }
        try {
            $playback = Invoke-SavedAudioPlayback -AudioPath $audioPath -TimeoutSeconds 90
        } finally {
            $restoreState = Stop-AudioDucking -DuckingState $duckingState -Config $Config
            if ($deleteTransientAudio -and (Test-Path -LiteralPath $audioPath)) {
                Remove-Item -LiteralPath $audioPath -Force -ErrorAction SilentlyContinue
                $transientAudioDeleted = -not (Test-Path -LiteralPath $audioPath)
            }
        }

        $result = [ordered]@{
            provider = "openai"
            spoken = [bool]$playback.played
            skipped = $false
            saved = $saveAudioEffective
            bytes = $audioItem.Length
            voice = [string]$resolvedTtsSettings.voice
            speed = [double]$resolvedTtsSettings.speed
            model = [string](Get-ObjectValue -Object $speechSettings -Key "model" -Default "gpt-4o-mini-tts")
            secretSource = $secret.source
            playback = $playback
            transientAudio = -not $saveAudioEffective
            transientAudioDeleted = $transientAudioDeleted
            audioDucking = [ordered]@{
                duck = $duckingState
                restore = $restoreState
            }
        }
        if ($saveAudioEffective) {
            $result["audioPath"] = $audioPath
            $result["metadataPath"] = $metadataPath
        }
        return $result
    } catch {
        if ($deleteTransientAudio -and -not [string]::IsNullOrWhiteSpace($audioPath) -and (Test-Path -LiteralPath $audioPath)) {
            Remove-Item -LiteralPath $audioPath -Force -ErrorAction SilentlyContinue
        }
        return [ordered]@{
            provider = "openai"
            spoken = $false
            skipped = $false
            saved = $false
            error = $_.Exception.Message
            secretSource = $secret.source
        }
    }
}

function Invoke-ConfiguredTts {
    param(
        [string]$ProjectRoot,
        [string]$Provider,
        [string]$Text,
        [string]$VoiceInstructions,
        $VoiceSettings,
        $Config,
        [hashtable]$StyleSelection,
        [bool]$Speak,
        [bool]$SaveAudio
    )

    switch ($Provider) {
        "elevenlabs" {
            return Invoke-ElevenLabsSpeech -ProjectRoot $ProjectRoot -Text $Text -VoiceInstructions $VoiceInstructions -Config $Config -Speak $Speak -SaveAudio $SaveAudio
        }
        "openai" {
            return Invoke-OpenAISpeech -ProjectRoot $ProjectRoot -Text $Text -VoiceInstructions $VoiceInstructions -VoiceSettings $VoiceSettings -Config $Config -Speak $Speak -SaveAudio $SaveAudio
        }
        default {
            return Invoke-LocalSpeech -Text $Text -Config $Config -StyleSelection $StyleSelection -Speak $Speak
        }
    }
}

function Write-VoiceNotifierTrace {
    param(
        [string]$ProjectRoot,
        $Config,
        [hashtable]$TraceRecord
    )

    if (-not $Config.trace.enabled) {
        return
    }

    $tracePath = [string]$Config.trace.path
    if (-not [System.IO.Path]::IsPathRooted($tracePath)) {
        $tracePath = Join-Path $ProjectRoot $tracePath
    }

    $traceDir = Split-Path -Parent $tracePath
    if (-not (Test-Path -LiteralPath $traceDir)) {
        New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
    }

    $json = $TraceRecord | ConvertTo-Json -Depth 12 -Compress
    Add-Content -LiteralPath $tracePath -Value $json -Encoding UTF8
}

function Invoke-VoiceNotifierRun {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [string]$PayloadFile,
        [string]$Message,
        [string]$StyleProfile,
        [string]$StylingProvider,
        [string]$TtsProvider,
        [switch]$Speak,
        [switch]$SaveAudio
    )

    $config = Get-VoiceNotifierConfig -ProjectRoot $ProjectRoot
    $payloadInput = Read-NotificationPayload -PayloadFile $PayloadFile -Message $Message
    $facts = Get-NotificationFacts -Payload $payloadInput.Payload -Config $config
    $nowPlaying = Get-NowPlayingMetadata -Config $config
    $styleSelection = Select-StyleProfile -NowPlaying $nowPlaying -Config $config -StyleOverride $StyleProfile
    $neutralBrief = New-NeutralBrief -Facts $facts
    $speakableFacts = New-SpeakableFacts -Facts $facts

    $provider = Get-DefaultTextProvider -Config $config
    if (-not [string]::IsNullOrWhiteSpace($StylingProvider)) {
        $provider = $StylingProvider
    }

    $llmStyling = [ordered]@{
        provider = $provider
        used = $false
    }

    if ($provider -eq "gemini") {
        $llmStyling = Invoke-GeminiStyling -ProjectRoot $ProjectRoot -SpeakableFacts $speakableFacts -NowPlaying $nowPlaying -Config $config
    } elseif ($provider -eq "openai") {
        $llmStyling = Invoke-OpenAIStyling -ProjectRoot $ProjectRoot -SpeakableFacts $speakableFacts -NowPlaying $nowPlaying -Config $config
    }

    $voiceSettings = [ordered]@{}
    if (($provider -eq "gemini" -or $provider -eq "openai") -and $llmStyling.ok) {
        $styledBrief = [string]$llmStyling.text
        $styleInstructions = [string]$llmStyling.voice.instructions
        $voiceSettings = $llmStyling.voice
        if ([string]::IsNullOrWhiteSpace($styleInstructions)) {
            $styleInstructions = [string]$styleSelection.profile.instructions
        }
        $styleSummary = "$provider-generated DJ/MC rewrite"
    } else {
        $styledBrief = ConvertTo-StyledBrief -NeutralBrief $neutralBrief -StyleName $styleSelection.name -Facts $facts
        $styleInstructions = [string]$styleSelection.profile.instructions
        $styleSummary = [string]$styleSelection.profile.description
        if ($provider -eq "gemini" -or $provider -eq "openai") {
            $llmStyling["used"] = $false
        }
    }

    $ttsProviderToUse = Get-DefaultSpeechProvider -Config $config
    if (-not [string]::IsNullOrWhiteSpace($TtsProvider)) {
        $ttsProviderToUse = $TtsProvider
    }

    $ttsResult = Invoke-ConfiguredTts -ProjectRoot $ProjectRoot -Provider $ttsProviderToUse -Text $styledBrief -VoiceInstructions $styleInstructions -VoiceSettings $voiceSettings -Config $config -StyleSelection $styleSelection -Speak $Speak.IsPresent -SaveAudio $SaveAudio.IsPresent

    $result = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        payloadSource = $payloadInput.Source
        rawNotification = $payloadInput.Payload
        extractedFacts = $facts
        speakableFacts = $speakableFacts
        nowPlaying = $nowPlaying
        selectedStyleProfile = [ordered]@{
            name = $styleSelection.name
            reason = $styleSelection.reason
            description = $styleSummary
        }
        neutralSpokenBrief = $neutralBrief
        styledSpokenBrief = $styledBrief
        styleInstructions = $styleInstructions
        stylingProvider = $llmStyling
        tts = $ttsResult
    }

    Write-VoiceNotifierTrace -ProjectRoot $ProjectRoot -Config $config -TraceRecord $result
    return $result
}

function Write-VoiceNotifierResult {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Result
    )

    $media = $Result.nowPlaying.selected
    Write-Host "Now playing source: $($media.source)"
    if (-not [string]::IsNullOrWhiteSpace([string]$media.artist) -or -not [string]::IsNullOrWhiteSpace([string]$media.title)) {
        Write-Host "Now playing: $($media.artist) - $($media.title)"
    } else {
        Write-Host "Now playing: unavailable"
    }

    $getValue = {
        param($Object, [string]$Key, $Default = "")
        if ($null -eq $Object) {
            return $Default
        }
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Key)) {
            return $Object[$Key]
        }
        $property = @($Object.PSObject.Properties | Where-Object { $_.Name -eq $Key } | Select-Object -First 1)
        if ($property.Count -gt 0) {
            return $property[0].Value
        }
        return $Default
    }

    Write-Host "Style profile: $($Result.selectedStyleProfile.name) ($($Result.selectedStyleProfile.reason))"
    $stylingProviderName = & $getValue $Result.stylingProvider "provider" ""
    if (-not [string]::IsNullOrWhiteSpace([string]$stylingProviderName)) {
        Write-Host "Styling provider: $stylingProviderName"
        $fallbackReason = & $getValue $Result.stylingProvider "fallbackReason" ""
        if (-not [string]::IsNullOrWhiteSpace([string]$fallbackReason)) {
            Write-Host "Styling fallback: $fallbackReason" -ForegroundColor Yellow
        }
    }
    Write-Host "Style instructions: $($Result.styleInstructions)"
    Write-Host ""
    Write-Host "Neutral spoken brief:" -ForegroundColor Cyan
    Write-Host $Result.neutralSpokenBrief
    Write-Host ""
    Write-Host "Styled spoken brief:" -ForegroundColor Cyan
    Write-Host $Result.styledSpokenBrief
    Write-Host ""

    Write-Host "TTS result: $($Result.tts.provider), spoken=$($Result.tts.spoken), skipped=$($Result.tts.skipped), saved=$(& $getValue $Result.tts 'saved' $false)"
    if ($Result.tts.Contains("audioPath")) {
        Write-Host "Audio file: $($Result.tts.audioPath)"
    }
    if ($Result.tts.Contains("metadataPath")) {
        Write-Host "Audio metadata: $($Result.tts.metadataPath)"
    }
    if ($Result.tts.Contains("transientAudio") -and [bool]$Result.tts.transientAudio) {
        $deleted = if ($Result.tts.Contains("transientAudioDeleted")) { [bool]$Result.tts.transientAudioDeleted } else { $false }
        Write-Host "Audio file: not saved (transient playback file deleted=$deleted)"
    }
    if ($Result.tts.Contains("playback")) {
        $playback = $Result.tts.playback
        Write-Host "Audio playback: played=$(& $getValue $playback 'played' $false), method=$(& $getValue $playback 'method' '')"
        $playbackError = & $getValue $playback "error" ""
        $playbackWarning = & $getValue $playback "warning" ""
        if (-not [string]::IsNullOrWhiteSpace([string]$playbackWarning)) {
            Write-Host "Audio playback warning: $playbackWarning" -ForegroundColor Yellow
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$playbackError)) {
            Write-Host "Audio playback error: $playbackError" -ForegroundColor Yellow
        }
    }
    if ($Result.tts.Contains("audioDucking")) {
        $duck = $Result.tts.audioDucking.duck
        $restore = $Result.tts.audioDucking.restore
        Write-Host "Audio ducking: applied=$(& $getValue $duck 'applied' ''), sessions=$(& $getValue $duck 'changedSessions' 0), restored=$(& $getValue $restore 'restored' ''), restoredSessions=$(& $getValue $restore 'restoredSessions' 0)"
        $duckError = & $getValue $duck "error" ""
        $restoreError = & $getValue $restore "error" ""
        if (-not [string]::IsNullOrWhiteSpace([string]$duckError)) {
            Write-Host "Audio ducking error: $duckError" -ForegroundColor Yellow
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$restoreError)) {
            Write-Host "Audio restore error: $restoreError" -ForegroundColor Yellow
        }
    }
    if ($Result.tts.Contains("error")) {
        Write-Host "TTS error: $($Result.tts.error)" -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function Invoke-VoiceNotifierRun, Write-VoiceNotifierResult
