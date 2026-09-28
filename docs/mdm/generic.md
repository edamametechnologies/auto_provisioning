# Any MDM or tool that can run a script

Everything in this repository works with a tool that can (1) run a script as
root / SYSTEM and (2) either set environment variables or store the script
body privately.

## Posture (scenario A)

| OS | Run as | Command |
|---|---|---|
| Linux | root | `sh install-edamame-posture.sh` |
| macOS | root | `bash install-edamame-posture.sh` |
| Windows | SYSTEM or elevated admin, 64-bit PowerShell preferred (the script relaunches itself in 64-bit) | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-EdamamePosture.ps1` |

Pass settings in this order of preference:

1. Environment variables set by the tool (`EDAMAME_USER`, `EDAMAME_DOMAIN`,
   `EDAMAME_PIN`, `EDAMAME_LLM_PROVIDER`, `EDAMAME_LLM_API_KEY`, ...).
2. Secret files: `EDAMAME_PIN_FILE`, `EDAMAME_LLM_API_KEY_FILE`
   (Windows: `-PinFile`, `-LlmApiKeyFile`).
3. Script parameters (Windows `-User -Domain -Pin ...`; macOS Jamf-style
   `$4`-`$11`).
4. The embedded-settings block at the top of a **private** copy of the
   script.

Schedule it:

- **Once** at enrollment, then again whenever you change a setting or want
  to upgrade (`EDAMAME_VERSION=latest` upgrades; a pinned version downgrades
  or holds).
- Optionally **daily** as drift remediation: an unchanged run is a no-op and
  restarts nothing; a stopped daemon is started again.

Detect / report:

| OS | Installed | Running |
|---|---|---|
| Linux | `dpkg-query -W edamame-posture` | `systemctl is-active edamame_posture` |
| macOS | `defaults read "/Library/Application Support/EDAMAME/EDAMAME-Posture/edamame_posture.app/Contents/Info" CFBundleShortVersionString` | `launchctl print system/com.edamametechnologies.auto-provisioning.posture` |
| Windows | `%ProgramData%\EDAMAME\Provisioning\installed.json` (version, sha256) | `Get-ScheduledTask -TaskPath \EDAMAME\ -TaskName "EDAMAME Posture"`, process `edamame_posture` |

`edamame_posture status` (any OS, as root / admin) prints the daemon's Hub
connection and agentic state.

Remove: run the same script with `EDAMAME_ACTION=uninstall`.

## App (scenario B)

| OS | Run as | Command | Detection |
|---|---|---|---|
| macOS | root | `bash install-edamame-app.sh` | `/Applications/EDAMAME Security.app` `CFBundleShortVersionString` |
| Windows | SYSTEM | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install-EdamameApp.ps1` | `HKLM\SOFTWARE\EDAMAME` `EdamameMsixInstalledVersion` = `<ver>.0` |
| Linux | root | `EDAMAME_INSTALL_APP=true sh install-edamame-posture.sh` | `dpkg-query -W edamame-security` |

On macOS also deploy [the PPPC profile](../../profiles/macos/edamame-pppc-login-items.mobileconfig)
(before the app, so the helper never prompts). Users then enroll in the app
([app-configuration.md](../app-configuration.md)).

If your tool installs packages natively, you can skip the app scripts and
deploy the artifacts directly: macOS `edamame-macos-<ver>.pkg`; Windows
`edamame-windows-<ver>-setup.exe /quiet /norestart` (exit codes 0, 3010,
1641), or the helper MSI (`msiexec /i edamame-windows-<ver>-helper.msi /qn /norestart`)
plus the MSIX installed in device context.
