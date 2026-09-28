# Omnissa Workspace ONE UEM

Workspace ONE scripts (**Resources > Scripts**) run as System / root and can
define **variables** that reach the script as environment variables, which
matches the `EDAMAME_*` parameters of the scripts here. Check your console
version for the exact screens and whether variables can be hidden.

## Windows

- **Posture**: Resources > Scripts > Add > Windows. Language PowerShell,
  execution context **System**, timeout 600 s. Paste
  `scripts/windows/Install-EdamamePosture.ps1`; add variables
  `EDAMAME_USER`, `EDAMAME_DOMAIN`, `EDAMAME_PIN`, `EDAMAME_LLM_PROVIDER`,
  `EDAMAME_LLM_API_KEY`, `EDAMAME_VERSION`. Trigger: on assignment, and
  optionally a schedule for drift remediation.
- **App**: Resources > Apps > Native > Internal > Add: upload
  `edamame-windows-<ver>-setup.exe`; install command
  `edamame-windows-<ver>-setup.exe /quiet /norestart`, uninstall command
  `... /uninstall /quiet /norestart`, install context **Device**, success
  codes 0 / 3010 / 1641, detection: registry
  `HKLM\SOFTWARE\EDAMAME` `EdamameMsixInstalledVersion` = `<ver>.0`.

## macOS

- **Profile**: Resources > Profiles > Add > macOS > Device > Custom
  Settings: paste the content of
  [edamame-pppc-login-items.mobileconfig](../../profiles/macos/edamame-pppc-login-items.mobileconfig)
  (or use the Privacy Preferences payload with the same bundle ids and code
  requirements).
- **Posture**: Resources > Scripts > Add > macOS, language Bash, execution
  context **System**, script `scripts/macos/install-edamame-posture.sh`,
  variables as above.
- **App**: Resources > Apps > Native > Internal: upload
  `edamame-macos-<ver>.pkg` (generate the metadata with the Workspace ONE
  Admin Assistant), or run `scripts/macos/install-edamame-app.sh` as a
  script.

## Linux

Workspace ONE Linux management can run scripts as root: use
`scripts/linux/install-edamame-posture.sh` with the same variables.
