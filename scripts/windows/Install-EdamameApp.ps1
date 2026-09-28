#Requires -Version 5.1
<#
.SYNOPSIS
    EDAMAME Security app + EDAMAME Helper -- Windows silent install for MDM.

.DESCRIPTION
    Downloads the all-in-one installer edamame-windows-<version>-setup.exe (a
    WiX Burn bundle that installs the EDAMAME Helper MSI and provisions the
    EDAMAME Security MSIX machine-wide) from the edamame_security GitHub
    release, verifies its SHA-256 against the digest GitHub publishes for the
    asset (or -Sha256) and its Authenticode signature (O=EDAMAME TECHNOLOGIES
    SAS), and runs it with /quiet /norestart /log.

    The current app has no managed configuration: Hub enrollment, the LLM
    provider and the protection switch are set by the user in the app (see
    docs/app-configuration.md). Npcap (packet capture) is not installed by the
    bundle; see docs/distribution.md.

    Idempotent: when the bundle's registry marker already shows the requested
    version the script exits 0 without downloading.

.PARAMETER Action       install (default) | uninstall   (EDAMAME_ACTION)
.PARAMETER Version      latest (default) or e.g. 2.0.1  (EDAMAME_VERSION)
.PARAMETER Sha256       expected SHA-256 of setup.exe   (EDAMAME_SHA256)
.PARAMETER GitHubToken  optional GitHub API token       (EDAMAME_GITHUB_TOKEN)

.NOTES
    Exit codes: 0 ok, 3010 ok but a reboot is required (passed through from
    the installer), 1 unexpected error, 2 invalid parameters, 3 unsupported
    platform, 4 download failed, 5 integrity check failed, 6 installer failed
    (the installer's own code is in the log).
    Log: %ProgramData%\EDAMAME\Provisioning\Logs\ (provisioning.log and the
    Burn log edamame-bundle-<version>.log).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'MDM agents capture the host stream')]
[CmdletBinding()]
param(
    [string]$Action,
    [string]$Version,
    [string]$Sha256,
    [string]$GitHubToken
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Repo        = 'edamametechnologies/edamame_security'
$SignerMatch = 'O=EDAMAME TECHNOLOGIES SAS'
$LogDir      = Join-Path $env:ProgramData 'EDAMAME\Provisioning\Logs'
$LogFile     = Join-Path $LogDir 'provisioning.log'
# Written by the bundle's MSIX step (windows_bundle/install_msix.ps1).
$MarkerKey   = 'HKLM:\SOFTWARE\EDAMAME'
$MarkerValue = 'EdamameMsixInstalledVersion'

function Write-ProvLog([string]$Message) {
    $line = '{0} [edamame-app] {1}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { Write-Verbose 'log file not writable' }
}
function Exit-WithCode([int]$Code, [string]$Message) {
    Write-ProvLog "ERROR: $Message"
    exit $Code
}
function Get-Setting([string]$Explicit, [string]$EnvName, [string]$Default = '') {
    if ($Explicit) { return $Explicit }
    $v = [Environment]::GetEnvironmentVariable($EnvName)
    if ($v) { return $v }
    return $Default
}

if (-not [Environment]::Is64BitOperatingSystem) { Exit-WithCode 3 'EDAMAME Security is published for 64-bit Windows only' }
if (-not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
    exit $LASTEXITCODE
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Exit-WithCode 2 'run as SYSTEM or an elevated administrator' }
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$act = (Get-Setting -Explicit $Action -EnvName 'EDAMAME_ACTION' -Default 'install').ToLowerInvariant()
$ver = Get-Setting -Explicit $Version -EnvName 'EDAMAME_VERSION' -Default 'latest'
$sha = (Get-Setting -Explicit $Sha256 -EnvName 'EDAMAME_SHA256').ToLowerInvariant()
$tok = Get-Setting -Explicit $GitHubToken -EnvName 'EDAMAME_GITHUB_TOKEN'
if ($act -notin @('install', 'uninstall')) { Exit-WithCode 2 'Action must be install or uninstall' }
if ($ver -ne 'latest' -and $ver -notmatch '^[0-9]+(\.[0-9]+)*$') { Exit-WithCode 2 "Version must be 'latest' or e.g. 2.0.1" }
if ($sha -and $sha -notmatch '^[0-9a-f]{64}$') { Exit-WithCode 2 'Sha256 must be 64 hex characters' }
if ($sha -and $ver -eq 'latest') { Exit-WithCode 2 'Sha256 needs an exact Version' }

function Get-InstalledVersion {
    $item = Get-ItemProperty -Path $MarkerKey -Name $MarkerValue -ErrorAction SilentlyContinue
    if ($item) { return [string]$item.$MarkerValue }
    return ''
}

function Test-SameVersion([string]$Installed, [string]$Wanted) {
    # The marker holds the 4-part MSIX version (2.0.1.0); releases are 3-part.
    if (-not $Installed -or -not $Wanted) { return $false }
    $a = @($Installed.Split('.') + @('0', '0', '0', '0'))[0..3] -join '.'
    $b = @($Wanted.Split('.') + @('0', '0', '0', '0'))[0..3] -join '.'
    return $a -eq $b
}

function Get-BundleUninstallCommand {
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($r in $roots) {
        foreach ($k in (Get-ChildItem -Path $r -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            $dn = $p.PSObject.Properties['DisplayName']
            $bu = $p.PSObject.Properties['BundleCachePath']
            if ($dn -and $dn.Value -eq 'EDAMAME Security' -and $bu) { return [string]$bu.Value }
        }
    }
    return $null
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if ($act -eq 'uninstall') {
        $bundle = Get-BundleUninstallCommand
        if (-not $bundle -or -not (Test-Path -LiteralPath $bundle)) { Write-ProvLog 'EDAMAME Security bundle not found; nothing to uninstall'; exit 0 }
        $log = Join-Path $LogDir 'edamame-bundle-uninstall.log'
        Write-ProvLog "Uninstalling with $bundle /uninstall /quiet /norestart"
        $p = Start-Process -FilePath $bundle -ArgumentList @('/uninstall', '/quiet', '/norestart', '/log', "`"$log`"") -Wait -PassThru
        Write-ProvLog "Uninstaller exit code $($p.ExitCode)"
        if ($p.ExitCode -in @(0, 3010, 1641)) { exit $(if ($p.ExitCode -eq 0) { 0 } else { 3010 }) }
        Exit-WithCode 6 "uninstaller exited with $($p.ExitCode)"
    }

    $installed = Get-InstalledVersion
    Write-ProvLog "Installed: $(if ($installed) { $installed } else { 'none' }); requested: $ver"
    if ($ver -ne 'latest' -and (Test-SameVersion $installed $ver) -and -not $sha) {
        Write-ProvLog "Already at $installed"
        exit 0
    }

    if ($sha) {
        $target = $ver
        $expected = $sha
    } else {
        $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'edamame-auto-provisioning' }
        if ($tok) { $headers['Authorization'] = "Bearer $tok" }
        $path = if ($ver -eq 'latest') { 'latest' } else { "tags/v$ver" }
        try { $rel = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri "https://api.github.com/repos/$Repo/releases/$path" }
        catch { Exit-WithCode 4 "GitHub API request failed for $Repo release $path ($($_.Exception.Message)); set EDAMAME_GITHUB_TOKEN, or pin -Version with -Sha256" }
        $target = ([string]$rel.tag_name).TrimStart('v')
        $assetName = "edamame-windows-$target-setup.exe"
        $asset = @($rel.assets | Where-Object { $_.name -eq $assetName })
        if ($asset.Count -ne 1) { Exit-WithCode 4 "release v$target has no asset $assetName" }
        $d = $asset[0].PSObject.Properties['digest']
        if (-not $d -or -not ([string]$d.Value).StartsWith('sha256:')) { Exit-WithCode 5 "GitHub publishes no SHA-256 digest for $assetName; pass -Sha256" }
        $expected = ([string]$d.Value).Substring(7).ToLowerInvariant()
    }
    if (Test-SameVersion $installed $target) {
        Write-ProvLog "Already at $installed"
        exit 0
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('edamame-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $url = "https://github.com/$Repo/releases/download/v$target/edamame-windows-$target-setup.exe"
        $file = Join-Path $tmp "edamame-windows-$target-setup.exe"
        Write-ProvLog "Downloading $url"
        try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file } catch { Exit-WithCode 4 "download failed: $url ($($_.Exception.Message))" }
        $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($got -ne $expected) { Exit-WithCode 5 "SHA-256 mismatch (got $got, expected $expected)" }
        $sig = Get-AuthenticodeSignature -LiteralPath $file
        if ($sig.Status -ne 'Valid') { Exit-WithCode 5 "Authenticode status $($sig.Status)" }
        if ($sig.SignerCertificate.Subject -notmatch [regex]::Escape($SignerMatch)) { Exit-WithCode 5 "unexpected signer $($sig.SignerCertificate.Subject)" }
        Write-ProvLog "Verified SHA-256 $got and signer $SignerMatch"

        $log = Join-Path $LogDir "edamame-bundle-$target.log"
        Write-ProvLog "Running installer /quiet /norestart (log: $log)"
        $p = Start-Process -FilePath $file -ArgumentList @('/quiet', '/norestart', '/log', "`"$log`"") -Wait -PassThru
        $code = $p.ExitCode
        Write-ProvLog "Installer exit code $code"
        switch ($code) {
            0 { Write-ProvLog "Done: EDAMAME Security $(Get-InstalledVersion)"; exit 0 }
            { $_ -in @(3010, 1641) } { Write-ProvLog 'Installed; a reboot is required'; exit 3010 }
            default { Exit-WithCode 6 "installer exited with $code (see $log)" }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
} catch {
    Exit-WithCode 1 "unexpected error: $($_.Exception.Message)"
}
