param(
    [string]$PayloadFile,
    [string]$Message,
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
$modulePath = Join-Path $projectRoot "src\VoiceNotifier.psm1"

Import-Module $modulePath -Force

$shouldSpeak = $Speak.IsPresent -and -not $NoSpeak.IsPresent
$result = Invoke-VoiceNotifierRun -ProjectRoot $projectRoot -PayloadFile $PayloadFile -Message $Message -StyleProfile $StyleProfile -StylingProvider $StylingProvider -TtsProvider $TtsProvider -Speak:$shouldSpeak -SaveAudio:$SaveAudio.IsPresent

Write-VoiceNotifierResult -Result $result
