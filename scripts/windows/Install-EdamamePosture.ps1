#Requires -Version 5.1
<#
.SYNOPSIS
    EDAMAME Posture -- Windows provisioning script for MDM (Intune, ConfigMgr,
    Workspace ONE, or any tool that runs PowerShell as SYSTEM).

.DESCRIPTION
    1. Gets edamame_posture.exe (x86_64) from the GitHub release (default) or
       from Chocolatey (-Source choco), verifies its SHA-256 against the digest
       GitHub publishes for the asset (or -Sha256) and its Authenticode
       signature (signer O=EDAMAME TECHNOLOGIES SAS), and installs it to
       %ProgramFiles%\EDAMAME\Posture.
    2. Writes %ProgramData%\EDAMAME\Provisioning\posture.json (ACL: SYSTEM and
       Administrators only) holding the Hub enrollment and LLM configuration.
    3. Registers the scheduled task \EDAMAME\EDAMAME Posture (SYSTEM, at
       startup, no time limit) that runs Start-EdamamePosture.ps1, which reads
       posture.json and keeps `edamame_posture foreground-start` running.
       edamame_posture ships no Windows service today.

    Idempotent: nothing is downloaded when the installed binary already matches
    the requested release, and the task restarts only when the binary or the
    configuration changed. Settings not supplied keep their current value.

    Settings are resolved in this order: script parameter, environment
    variable (EDAMAME_*), then the $Embedded block below. Intune platform
    scripts cannot pass parameters: upload a private copy with the $Embedded
    block filled in, and never commit that copy.

.PARAMETER Action          install (default) | uninstall          (EDAMAME_ACTION)
.PARAMETER User            EDAMAME Hub user; "user@domain" is split (EDAMAME_USER)
.PARAMETER Domain          EDAMAME Hub domain                      (EDAMAME_DOMAIN)
.PARAMETER Pin             EDAMAME Hub PIN (digits), secret         (EDAMAME_PIN)
.PARAMETER PinFile         file holding the PIN                    (EDAMAME_PIN_FILE)
.PARAMETER DeviceId        optional device id suffix               (EDAMAME_DEVICE_ID)
.PARAMETER LlmProvider     portal | claude | openai | ollama | none (EDAMAME_LLM_PROVIDER)
.PARAMETER LlmApiKey       Portal or provider API key, secret      (EDAMAME_LLM_API_KEY)
.PARAMETER LlmApiKeyFile   file holding the key                    (EDAMAME_LLM_API_KEY_FILE)
.PARAMETER LlmModel        model for claude / openai / ollama      (EDAMAME_LLM_MODEL)
.PARAMETER LlmBaseUrl      Ollama URL, or API base URL             (EDAMAME_LLM_BASE_URL)
.PARAMETER AgenticMode     analyze | auto | disabled               (EDAMAME_AGENTIC_MODE)
.PARAMETER AgenticInterval seconds between Assistant runs          (EDAMAME_AGENTIC_INTERVAL)
.PARAMETER Version         latest (default) or e.g. 2.0.1          (EDAMAME_VERSION)
.PARAMETER Sha256          expected SHA-256 of the exe             (EDAMAME_SHA256)
.PARAMETER Source          github (default) | choco                (EDAMAME_SOURCE)
.PARAMETER GitHubToken     optional GitHub API token               (EDAMAME_GITHUB_TOKEN)

.NOTES
    Exit codes: 0 ok, 1 unexpected error, 2 invalid parameters, 3 unsupported
    platform, 4 download failed, 5 integrity check failed, 6 install failed,
    7 configuration failed, 8 daemon did not start.
    Log: %ProgramData%\EDAMAME\Provisioning\Logs\provisioning.log (no secrets).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Unattended MDM script')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'MDM agents capture the host stream')]
[CmdletBinding()]
param(
    [string]$Action,
    [string]$User,
    [string]$Domain,
    [string]$Pin,
    [string]$PinFile,
    [string]$DeviceId,
    [string]$LlmProvider,
    [string]$LlmApiKey,
    [string]$LlmApiKeyFile,
    [string]$LlmModel,
    [string]$LlmBaseUrl,
    [string]$AgenticMode,
    [string]$AgenticInterval,
    [string]$Version,
    [string]$Sha256,
    [string]$Source,
    [string]$GitHubToken
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---- Embedded settings (for tools that cannot pass parameters) --------------
# Fill these in a PRIVATE copy only. Never commit a copy with secrets.
$Embedded = @{
    User        = ''
    Domain      = ''
    Pin         = ''
    DeviceId    = ''
    LlmProvider = ''   # portal | claude | openai | ollama | none
    LlmApiKey   = ''
    LlmModel    = ''
    LlmBaseUrl  = ''
    AgenticMode = ''   # analyze | auto | disabled
    Version     = ''   # latest or e.g. 2.0.1
}
# -----------------------------------------------------------------------------

$Repo        = 'edamametechnologies/edamame_posture_cli'
$SignerMatch = 'O=EDAMAME TECHNOLOGIES SAS'
$InstallDir  = Join-Path $env:ProgramFiles 'EDAMAME\Posture'
$Exe         = Join-Path $InstallDir 'edamame_posture.exe'
$Launcher    = Join-Path $InstallDir 'Start-EdamamePosture.ps1'
$ProvDir     = Join-Path $env:ProgramData 'EDAMAME\Provisioning'
$ConfigPath  = Join-Path $ProvDir 'posture.json'
$StatePath   = Join-Path $ProvDir 'installed.json'
$LogDir      = Join-Path $ProvDir 'Logs'
$LogFile     = Join-Path $LogDir 'provisioning.log'
$TaskPath    = '\EDAMAME\'
$TaskName    = 'EDAMAME Posture'

function Write-ProvLog([string]$Message) {
    $line = '{0} [edamame-posture] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { Write-Verbose 'log file not writable' }
}

function Stop-WithCode([int]$Code, [string]$Message) {
    Write-ProvLog "ERROR: $Message"
    exit $Code
}

function Resolve-Setting([string]$Explicit, [string]$EnvName, [string]$EmbeddedKey, [string]$Default = '') {
    if ($Explicit) { return $Explicit }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) { return $fromEnv }
    if ($EmbeddedKey -and $Embedded.ContainsKey($EmbeddedKey) -and $Embedded[$EmbeddedKey]) { return $Embedded[$EmbeddedKey] }
    return $Default
}

function Read-SecretFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-WithCode 2 "secret file $Path not found" }
    return ((Get-Content -LiteralPath $Path -TotalCount 1) -replace '\s+$', '')
}

function Set-RestrictedAcl([string]$Path) {
    # SYSTEM and BUILTIN\Administrators only, no inheritance from the parent.
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Test-EdamameSignature([string]$Path) {
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { return "signature status $($sig.Status)" }
    if ($sig.SignerCertificate.Subject -notmatch [regex]::Escape($SignerMatch)) { return "unexpected signer $($sig.SignerCertificate.Subject)" }
    return $null
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-GitHubRelease([string]$Ver) {
    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'edamame-auto-provisioning' }
    if ($script:P.GitHubToken) { $headers['Authorization'] = "Bearer $($script:P.GitHubToken)" }
    $path = if ($Ver -eq 'latest') { 'latest' } else { "tags/v$Ver" }
    try {
        return Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/$path"
    } catch {
        Stop-WithCode 4 "GitHub API request failed for $Repo release $path ($($_.Exception.Message)); set EDAMAME_GITHUB_TOKEN, or pin -Version with -Sha256"
    }
}

function Stop-Posture {
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) { Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue }
    # Launcher loop and any daemon started earlier with `edamame_posture start`.
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Start-EdamamePosture.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-Process -Name 'edamame_posture' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5   # let the RPC port leave TIME_WAIT
}

$LauncherContent = @'
# Installed by the EDAMAME auto_provisioning Windows script. Started by the
# scheduled task \EDAMAME\EDAMAME Posture (SYSTEM). Reads posture.json and keeps
# edamame_posture running. The LLM key is passed through the environment of
# this process only, never on a command line.
$ErrorActionPreference = 'Continue'
$cfgPath = Join-Path $env:ProgramData 'EDAMAME\Provisioning\posture.json'
$exe     = Join-Path $env:ProgramFiles 'EDAMAME\Posture\edamame_posture.exe'
$state   = Join-Path $env:ProgramData 'EDAMAME\Provisioning\state'
$log     = Join-Path $env:ProgramData 'EDAMAME\Provisioning\Logs\launcher.log'
function Log([string]$m) { Add-Content -Path $log -Value ('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $m) }
New-Item -ItemType Directory -Force -Path $state | Out-Null
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 5MB)) { Move-Item -Force $log "$log.1" }
while ($true) {
    try {
        $c = Get-Content -Raw -LiteralPath $cfgPath -ErrorAction Stop | ConvertFrom-Json
        $argv = @('foreground-start')
        if ($c.user -and $c.domain -and $c.pin) {
            # edamame_posture takes the PIN only as an argument today.
            $argv += @('--user', $c.user, '--domain', $c.domain, '--pin', $c.pin)
            if ($c.device_id) { $argv += @('--device-id', $c.device_id) }
            Log "starting connected: $($c.user)@$($c.domain)"
        } else {
            Log 'starting disconnected'
        }
        foreach ($n in 'EDAMAME_LLM_API_KEY', 'EDAMAME_LLM_MODEL', 'EDAMAME_LLM_BASE_URL') { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        if ($c.agentic_mode -and $c.agentic_mode -ne 'disabled' -and $c.agentic_provider) {
            if ($c.llm_api_key)  { $env:EDAMAME_LLM_API_KEY  = $c.llm_api_key }
            if ($c.llm_model)    { $env:EDAMAME_LLM_MODEL    = $c.llm_model }
            if ($c.llm_base_url) { $env:EDAMAME_LLM_BASE_URL = $c.llm_base_url }
            $argv += @('--agentic-mode', $c.agentic_mode, '--agentic-provider', $c.agentic_provider, '--agentic-interval', [string]$c.agentic_interval)
            Log "AI assistant: mode=$($c.agentic_mode) provider=$($c.agentic_provider)"
        }
        Set-Location -LiteralPath $state
        # No -v: edamame_posture writes its own daily log files beside the exe.
        & $exe @argv | Out-Null
        Log "edamame_posture exited with code $LASTEXITCODE; restarting in 30 s"
    } catch {
        Log "launcher error: $($_.Exception.Message); retrying in 30 s"
    }
    Start-Sleep -Seconds 30
}
'@

# ---------------------------------------------------------------------------
# Resolve and validate parameters
# ---------------------------------------------------------------------------
$script:P = @{
    Action          = (Resolve-Setting $Action 'EDAMAME_ACTION' '' 'install').ToLowerInvariant()
    User            = Resolve-Setting $User 'EDAMAME_USER' 'User'
    Domain          = Resolve-Setting $Domain 'EDAMAME_DOMAIN' 'Domain'
    Pin             = Resolve-Setting $Pin 'EDAMAME_PIN' 'Pin'
    DeviceId        = Resolve-Setting $DeviceId 'EDAMAME_DEVICE_ID' 'DeviceId'
    LlmProvider     = (Resolve-Setting $LlmProvider 'EDAMAME_LLM_PROVIDER' 'LlmProvider').ToLowerInvariant()
    LlmApiKey       = Resolve-Setting $LlmApiKey 'EDAMAME_LLM_API_KEY' 'LlmApiKey'
    LlmModel        = Resolve-Setting $LlmModel 'EDAMAME_LLM_MODEL' 'LlmModel'
    LlmBaseUrl      = Resolve-Setting $LlmBaseUrl 'EDAMAME_LLM_BASE_URL' 'LlmBaseUrl'
    AgenticMode     = (Resolve-Setting $AgenticMode 'EDAMAME_AGENTIC_MODE' 'AgenticMode').ToLowerInvariant()
    AgenticInterval = Resolve-Setting $AgenticInterval 'EDAMAME_AGENTIC_INTERVAL' ''
    Version         = Resolve-Setting $Version 'EDAMAME_VERSION' 'Version' 'latest'
    Sha256          = (Resolve-Setting $Sha256 'EDAMAME_SHA256' '').ToLowerInvariant()
    Source          = (Resolve-Setting $Source 'EDAMAME_SOURCE' '' 'github').ToLowerInvariant()
    GitHubToken     = Resolve-Setting $GitHubToken 'EDAMAME_GITHUB_TOKEN' ''
}
$pinFileSetting = Resolve-Setting $PinFile 'EDAMAME_PIN_FILE' ''
$keyFileSetting = Resolve-Setting $LlmApiKeyFile 'EDAMAME_LLM_API_KEY_FILE' ''

if (-not [Environment]::Is64BitOperatingSystem) { Stop-WithCode 3 'edamame_posture is published for 64-bit Windows only' }
foreach ($n in 'PinFile', 'LlmApiKeyFile') {
    # Relative paths (package content) must survive the 64-bit relaunch below.
    if ($PSBoundParameters.ContainsKey($n) -and $PSBoundParameters[$n] -and (Test-Path -LiteralPath $PSBoundParameters[$n])) {
        $PSBoundParameters[$n] = (Resolve-Path -LiteralPath $PSBoundParameters[$n]).ProviderPath
        Set-Variable -Name $n -Value $PSBoundParameters[$n]
    }
}
if (-not [Environment]::Is64BitProcess) {
    # 32-bit host (Intune Win32 apps, some agents): re-run in 64-bit PowerShell
    # so that %ProgramFiles% and the scheduled task resolve natively.
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
    exit $LASTEXITCODE
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Stop-WithCode 2 'run as SYSTEM or an elevated administrator' }

New-Item -ItemType Directory -Force -Path $ProvDir | Out-Null
Set-RestrictedAcl $ProvDir
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if (-not $P.Pin -and $pinFileSetting) { $P.Pin = Read-SecretFile $pinFileSetting }
if (-not $P.LlmApiKey -and $keyFileSetting) { $P.LlmApiKey = Read-SecretFile $keyFileSetting }

if ($P.Action -notin @('install', 'uninstall')) { Stop-WithCode 2 'Action must be install or uninstall' }
if ($P.User -like '*@*') {
    if ($P.Domain) { Stop-WithCode 2 'User must not contain @ when Domain is set' }
    $P.Domain = $P.User.Split('@', 2)[1]
    $P.User = $P.User.Split('@', 2)[0]
}
if (($P.User + $P.Domain + $P.Pin) -and -not ($P.User -and $P.Domain -and $P.Pin)) { Stop-WithCode 2 'User, Domain and Pin must be set together' }
if ($P.Pin -and $P.Pin -notmatch '^[0-9]+$') { Stop-WithCode 2 'Pin must contain digits only' }
if ($P.DeviceId -and $P.DeviceId -notmatch '^[A-Za-z0-9._-]+$') { Stop-WithCode 2 'DeviceId may contain letters, digits, dot, dash and underscore only' }
if ($P.Domain -and $P.Domain -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { Stop-WithCode 2 'Domain is not a fully qualified domain name' }
switch ($P.LlmProvider) {
    { $_ -in @('portal', 'edamame') } { $P.LlmProvider = 'edamame' }
    { $_ -in @('', 'claude', 'openai', 'ollama', 'none') } { }
    default { Stop-WithCode 2 'LlmProvider must be portal, claude, openai, ollama or none' }
}
if ($P.AgenticMode -notin @('', 'analyze', 'auto', 'disabled')) { Stop-WithCode 2 'AgenticMode must be analyze, auto or disabled' }
if ($P.AgenticInterval -and $P.AgenticInterval -notmatch '^[0-9]+$') { Stop-WithCode 2 'AgenticInterval must be a number of seconds' }
if ($P.Version -ne 'latest' -and $P.Version -notmatch '^[0-9]+(\.[0-9]+)*$') { Stop-WithCode 2 "Version must be 'latest' or e.g. 2.0.1" }
if ($P.Sha256 -and $P.Sha256 -notmatch '^[0-9a-f]{64}$') { Stop-WithCode 2 'Sha256 must be 64 hex characters' }
if ($P.Sha256 -and $P.Version -eq 'latest') { Stop-WithCode 2 'Sha256 needs an exact Version' }
if ($P.Source -notin @('github', 'choco')) { Stop-WithCode 2 'Source must be github or choco' }

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($P.Action -eq 'uninstall') {
    Write-ProvLog 'Uninstalling EDAMAME Posture'
    Stop-Posture
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ConfigPath, $StatePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $ProvDir 'state') -Recurse -Force -ErrorAction SilentlyContinue
    Write-ProvLog 'Uninstall complete (logs kept in %ProgramData%\EDAMAME\Provisioning\Logs)'
    exit 0
}

try {
    Write-ProvLog ("Provisioning EDAMAME Posture (version: {0}, source: {1}, provider: {2}, hub: {3}, pin: {4}, llm key: {5})" -f `
            $P.Version, $P.Source, $(if ($P.LlmProvider) { $P.LlmProvider } else { 'unchanged' }),
        $(if ($P.User) { "$($P.User)@$($P.Domain)" } else { 'unchanged' }),
        $(if ($P.Pin) { 'set' } else { 'unchanged' }), $(if ($P.LlmApiKey) { 'set' } else { 'unchanged' }))
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # -----------------------------------------------------------------------
    # Configuration (merge: settings not supplied keep their current value)
    # -----------------------------------------------------------------------
    $cur = [ordered]@{ user = ''; domain = ''; pin = ''; device_id = ''; agentic_mode = 'disabled'; agentic_provider = '';
        agentic_interval = 3600; llm_api_key = ''; llm_model = ''; llm_base_url = ''
    }
    $oldJson = ''
    if (Test-Path -LiteralPath $ConfigPath) {
        $oldJson = Get-Content -Raw -LiteralPath $ConfigPath
        $old = $oldJson | ConvertFrom-Json
        foreach ($k in @($cur.Keys)) {
            $prop = $old.PSObject.Properties[$k]
            if ($prop -and $null -ne $prop.Value) { $cur[$k] = $prop.Value }
        }
    }
    if ($P.User) { $cur.user = $P.User; $cur.domain = $P.Domain; $cur.pin = $P.Pin }
    if ($P.DeviceId) { $cur.device_id = $P.DeviceId }
    if ($P.AgenticInterval) { $cur.agentic_interval = [int]$P.AgenticInterval }
    if ($P.LlmProvider) {
        if ($P.LlmProvider -ne $cur.agentic_provider) { $cur.llm_api_key = ''; $cur.llm_model = ''; $cur.llm_base_url = '' }
        $cur.agentic_provider = $P.LlmProvider
        if ($P.LlmApiKey) { $cur.llm_api_key = $P.LlmApiKey }
        if ($P.LlmModel) { $cur.llm_model = $P.LlmModel }
        if ($P.LlmBaseUrl) { $cur.llm_base_url = $P.LlmBaseUrl }
        switch ($P.LlmProvider) {
            'none' { $cur.agentic_provider = ''; $cur.llm_api_key = ''; $cur.llm_model = ''; $cur.llm_base_url = '' }
            'ollama' { $cur.llm_api_key = ''; if (-not $cur.llm_base_url) { Stop-WithCode 2 'LlmProvider ollama needs LlmBaseUrl (e.g. http://localhost:11434)' } }
            'edamame' { if ($cur.llm_model) { Write-ProvLog 'WARNING: LlmModel is ignored for the EDAMAME Portal provider'; $cur.llm_model = '' } }
        }
        if ($P.LlmProvider -in @('edamame', 'claude', 'openai') -and -not $cur.llm_api_key) { Stop-WithCode 2 "LlmProvider $($P.LlmProvider) needs LlmApiKey (or LlmApiKeyFile)" }
    }
    if ($P.AgenticMode) { $cur.agentic_mode = $P.AgenticMode }
    elseif ($P.LlmProvider -eq 'none') { $cur.agentic_mode = 'disabled' }
    elseif ($P.LlmProvider) { $cur.agentic_mode = 'analyze' }
    if ($cur.agentic_mode -ne 'disabled' -and -not $cur.agentic_provider) { Stop-WithCode 2 "agentic mode '$($cur.agentic_mode)' needs an LLM provider" }

    $newJson = $cur | ConvertTo-Json
    $configChanged = ($newJson.Trim() -ne ([string]$oldJson).Trim())

    # -----------------------------------------------------------------------
    # Binary
    # -----------------------------------------------------------------------
    $binaryChanged = $false
    $installed = $null
    if (Test-Path -LiteralPath $StatePath) { $installed = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json }
    $currentHash = if (Test-Path -LiteralPath $Exe) { Get-Sha256 $Exe } else { '' }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('edamame-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $candidate = $null
        $targetVersion = $P.Version
        if ($P.Source -eq 'choco') {
            $choco = Get-Command choco.exe -ErrorAction SilentlyContinue
            if (-not $choco) { Stop-WithCode 3 'Chocolatey (choco.exe) is not installed' }
            $chocoArgs = @('upgrade', 'edamame-posture', '-y', '--no-progress')
            if ($P.Version -ne 'latest') { $chocoArgs += @('--version', $P.Version, '--allow-downgrade') }
            & $choco.Source @chocoArgs | Out-File -Append -FilePath $LogFile -Encoding UTF8
            if ($LASTEXITCODE -ne 0) { Stop-WithCode 6 "choco exited with $LASTEXITCODE" }
            $chocoRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { Join-Path $env:ProgramData 'chocolatey' }
            $candidate = Join-Path $chocoRoot 'lib\edamame-posture\tools\edamame_posture.exe'
            if (-not (Test-Path -LiteralPath $candidate)) { Stop-WithCode 6 "choco did not install $candidate" }
            $expected = Get-Sha256 $candidate   # Chocolatey verified its own package checksum
        } else {
            if ($P.Sha256) {
                $expected = $P.Sha256
            } else {
                $rel = Get-GitHubRelease $P.Version
                $targetVersion = ([string]$rel.tag_name).TrimStart('v')
                $assetName = "edamame_posture-$targetVersion-x86_64-pc-windows-msvc.exe"
                $asset = @($rel.assets | Where-Object { $_.name -eq $assetName })
                if ($asset.Count -ne 1) { Stop-WithCode 4 "release v$targetVersion has no asset $assetName" }
                $digestProp = $asset[0].PSObject.Properties['digest']
                if (-not $digestProp -or -not ([string]$digestProp.Value).StartsWith('sha256:')) { Stop-WithCode 5 "GitHub publishes no SHA-256 digest for $assetName; pass -Sha256" }
                $expected = ([string]$digestProp.Value).Substring(7).ToLowerInvariant()
            }
            if ($currentHash -ne $expected) {
                $url = "https://github.com/$Repo/releases/download/v$targetVersion/edamame_posture-$targetVersion-x86_64-pc-windows-msvc.exe"
                $candidate = Join-Path $tmp 'edamame_posture.exe'
                Write-ProvLog "Downloading $url"
                try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $candidate } catch { Stop-WithCode 4 "download failed: $url ($($_.Exception.Message))" }
                $got = Get-Sha256 $candidate
                if ($got -ne $expected) { Stop-WithCode 5 "SHA-256 mismatch (got $got, expected $expected)" }
                Write-ProvLog "SHA-256 verified: $got"
            }
        }

        if ($currentHash -ne $expected) {
            $sigError = Test-EdamameSignature $candidate
            if ($sigError) { Stop-WithCode 5 "Authenticode check failed: $sigError" }
            Write-ProvLog "Authenticode verified ($SignerMatch)"
            Stop-Posture
            New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
            Copy-Item -LiteralPath $candidate -Destination $Exe -Force
            @{ version = $targetVersion; sha256 = $expected; source = $P.Source } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
            $binaryChanged = $true
            Write-ProvLog "Installed edamame_posture $targetVersion to $Exe"
        } else {
            Write-ProvLog "edamame_posture already matches the requested release$(if ($installed) { " ($($installed.version))" })"
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($configChanged) {
        Set-Content -LiteralPath $ConfigPath -Value $newJson -Encoding UTF8
        Write-ProvLog "Configuration written to $ConfigPath"
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $ProvDir 'state') | Out-Null

    $launcherChanged = $true
    if (Test-Path -LiteralPath $Launcher) { $launcherChanged = ((Get-Content -Raw -LiteralPath $Launcher).Trim() -ne $LauncherContent.Trim()) }
    if ($launcherChanged) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
        Set-Content -LiteralPath $Launcher -Value $LauncherContent -Encoding UTF8
    }

    # -----------------------------------------------------------------------
    # Scheduled task
    # -----------------------------------------------------------------------
    $actionObj = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $Launcher)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principalObj = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $existing = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $actionObj -Trigger $trigger `
        -Principal $principalObj -Settings $settings -Description 'EDAMAME Posture (auto_provisioning)' -Force | Out-Null

    $running = @(Get-Process -Name 'edamame_posture' -ErrorAction SilentlyContinue).Count -gt 0
    if ($binaryChanged -or $configChanged -or $launcherChanged -or -not $existing -or -not $running) {
        Stop-Posture
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
        $ok = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            if (Get-Process -Name 'edamame_posture' -ErrorAction SilentlyContinue) { $ok = $true; break }
        }
        if (-not $ok) { Stop-WithCode 8 "edamame_posture did not start; see $LogDir\launcher.log and the log files beside $Exe" }
        Write-ProvLog 'edamame_posture started'
    } else {
        Write-ProvLog 'Configuration unchanged; edamame_posture running'
    }
    Write-ProvLog ("Done: mode={0}, provider={1}, hub={2}@{3}" -f $cur.agentic_mode, $cur.agentic_provider, $cur.user, $cur.domain)
    exit 0
} catch {
    Stop-WithCode 1 "unexpected error: $($_.Exception.Message)"
}
