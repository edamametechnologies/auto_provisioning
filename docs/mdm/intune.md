# Microsoft Intune

Menu names are those of the Intune admin center at the time of writing;
check Microsoft's documentation if they moved.

## Windows

### Posture: platform script (simplest)

Intune platform scripts cannot pass parameters or environment variables, so
upload a **private copy** of `scripts/windows/Install-EdamamePosture.ps1`
with the `$Embedded` block filled in (never commit it).

1. **Devices > Scripts and remediations > Platform scripts > Add > Windows 10 and later.**
2. Upload the private copy. Settings:
   - Run this script using the logged on credentials: **No** (runs as SYSTEM)
   - Enforce script signature check: **No** (or sign the script with your code-signing certificate and set Yes)
   - Run script in 64 bit PowerShell Host: **Yes**
3. Assign to a device group.

Intune runs a platform script once per device, and again when the script
changes. To upgrade or change a setting, edit the script (for example
`Version`) and save.

Restrict who can read the script (Intune RBAC); its body holds the PIN and
the key.

### Posture: Win32 app (versioned, with detection)

1. Put `Install-EdamamePosture.ps1` (unmodified) and, if you use them, a
   `pin.txt` and `llm_key.txt` in a folder; package it with
   `IntuneWinAppUtil.exe -c <folder> -s Install-EdamamePosture.ps1 -o <out>`.
2. **Apps > Windows > Add > Windows app (Win32)**, upload the `.intunewin`.
3. Install command:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-EdamamePosture.ps1 -User ci-fleet -Domain example.com -PinFile pin.txt -LlmProvider portal -LlmApiKeyFile llm_key.txt -Version 2.0.1`
   Uninstall command:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-EdamamePosture.ps1 -Action uninstall`
   Install behavior: **System**.
4. Detection rule: custom script
   ```powershell
   $s = Join-Path $env:ProgramData 'EDAMAME\Provisioning\installed.json'
   if ((Test-Path $s) -and ((Get-Content -Raw $s | ConvertFrom-Json).version -eq '2.0.1') -and
       ((Get-Service -Name 'edamame_posture' -ErrorAction SilentlyContinue) -or
        (Get-ScheduledTask -TaskPath '\EDAMAME\' -TaskName 'EDAMAME Posture' -ErrorAction SilentlyContinue))) { 'installed' }
   ```
   (EDAMAME >= 2.0.2 installs the `edamame_posture` Windows service; older
   releases the `\EDAMAME\EDAMAME Posture` scheduled task.)
5. Return codes: add `2`-`8` as **Failed** (defaults treat unknown codes as failed).

The Win32 install command is visible to Intune admins and written to the
Intune Management Extension log on the device; keep secrets in the packaged
files, not on the command line. Intune's Win32 agent may start the script in
32-bit PowerShell; the script relaunches itself in 64-bit.

### Posture: drift (optional)

**Devices > Scripts and remediations > Remediations** (license requirements
apply): detection script exits 1 when the task is missing or
`edamame_posture` is not running; remediation = the private copy of
`Install-EdamamePosture.ps1`.

### App: Win32 app

1. Download `edamame-windows-<ver>-setup.exe` from the
   [edamame_security release](https://github.com/edamametechnologies/edamame_security/releases)
   and package it with `IntuneWinAppUtil.exe`.
2. Install command: `edamame-windows-<ver>-setup.exe /quiet /norestart`
   Uninstall command: `edamame-windows-<ver>-setup.exe /uninstall /quiet /norestart`
   Install behavior: **System**. Return codes: 0 success, 3010 soft reboot,
   1641 hard reboot, 1618 retry.
3. Detection: registry `HKEY_LOCAL_MACHINE\SOFTWARE\EDAMAME`, value
   `EdamameMsixInstalledVersion`, String comparison **Equals** `<ver>.0`
   (e.g. `2.0.1.0`).

Alternatively package `Install-EdamameApp.ps1`, which downloads and verifies
the bundle at install time (install command
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-EdamameApp.ps1 -Version 2.0.2`).

Another option is two line-of-business apps: the MSIX (install context:
Device) and the helper MSI. The Chocolatey `edamame` package is not an
option before 2.0.3 (see [distribution.md](../distribution.md)).

Managed settings (EDAMAME >= 2.0.2, see
[app-configuration.md](../app-configuration.md)): import
[profiles/windows/admx](../../profiles/windows/admx) through **Devices >
Configuration > Import ADMX**, then create an **Imported Administrative
templates** profile; or set the values of
[edamame-managed-settings.reg](../../profiles/windows/edamame-managed-settings.reg)
with a remediation script. `HubEmailSource` = `upn` enrolls each device with
the signed-in user's UPN. Deploy `secrets.json` (Hub PIN, LLM key) with a
Win32 app or a platform script running as SYSTEM.

## macOS

### PPPC profile (both scenarios)

**Devices > macOS > Configuration > Create > Templates > Custom**, upload
[profiles/macos/edamame-pppc-login-items.mobileconfig](../../profiles/macos/edamame-pppc-login-items.mobileconfig),
deployment channel **Device channel**. Deploy it before the app or posture.

### Posture: shell script

1. Private copy of `scripts/macos/install-edamame-posture.sh` with the
   embedded-settings block filled in.
2. **Devices > macOS > Shell scripts > Add**: Run script as signed-in user
   **No**, Hide script notifications **Yes**, Script frequency **Every 1 day**
   (no-op when nothing changed) or **Not configured** (once), Max retries **3**.

### App

- **Apps > macOS > Add > macOS app (PKG)**: upload
  `edamame-macos-<ver>.pkg` (signed with a Developer ID Installer
  certificate, as Intune requires). Or
- a shell script with `scripts/macos/install-edamame-app.sh`
  (`EDAMAME_VERSION` fixed in a private copy's first lines, e.g.
  `export EDAMAME_VERSION=2.0.1`).

Managed settings (EDAMAME >= 2.0.2): a custom profile built from
[edamame-managed-settings.mobileconfig](../../profiles/macos/edamame-managed-settings.mobileconfig);
`HubEmail` can use the Intune `{{mail}}` token. Deploy
`/Library/Application Support/EDAMAME/Managed/secrets.json` (root:wheel
0600) with a shell script running as root.

## Linux

Intune's Linux management (Ubuntu, RHEL) supports custom configuration
scripts in recent tenants; check availability in yours. If available, deploy
a private copy of `scripts/linux/install-edamame-posture.sh` (embedded block
filled in) as a root script. The APT path supports Debian / Ubuntu; RHEL is
not packaged (raw binaries only, no service), so use scenario A on
Debian-family hosts or manage RHEL with your own unit file.
