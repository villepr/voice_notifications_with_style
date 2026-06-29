param(
    [ValidateSet("neutral", "reggae", "cinematic", "electronic", "rock", "jazz", "country")]
    [string]$StyleProfile,
    [ValidateSet("templates", "gemini", "openai")]
    [string]$StylingProvider,
    [ValidateSet("local", "elevenlabs", "openai")]
    [string]$TtsProvider,
    [switch]$Speak,
    [switch]$NoSpeak,
    [switch]$SaveAudio
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$invokeScript = Join-Path $scriptRoot "Invoke-VoiceNotification.ps1"
$examplesRoot = Join-Path $projectRoot "examples"

$shouldSpeak = $Speak.IsPresent -and -not $NoSpeak.IsPresent
$examples = @(
    "completed-work.json",
    "approval-needed.json",
    "blocker-error.json"
)

foreach ($example in $examples) {
    $payloadPath = Join-Path $examplesRoot $example
    Write-Host ""
    Write-Host "=== Example: $example ===" -ForegroundColor Cyan
    $invokeParams = @{
        PayloadFile = $payloadPath
    }
    if ($shouldSpeak) {
        $invokeParams["Speak"] = $true
    } else {
        $invokeParams["NoSpeak"] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($StyleProfile)) {
        $invokeParams["StyleProfile"] = $StyleProfile
    }
    if (-not [string]::IsNullOrWhiteSpace($StylingProvider)) {
        $invokeParams["StylingProvider"] = $StylingProvider
    }
    if (-not [string]::IsNullOrWhiteSpace($TtsProvider)) {
        $invokeParams["TtsProvider"] = $TtsProvider
    }
    if ($SaveAudio.IsPresent) {
        $invokeParams["SaveAudio"] = $true
    }
    & $invokeScript @invokeParams
}
