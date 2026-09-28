# Microsoft Configuration Manager (SCCM / MECM)

## Posture (scenario A)

Create an **Application** with a **Script Installer** deployment type:

- Content: a folder with `Install-EdamamePosture.ps1` and, optionally,
  `pin.txt` / `llm_key.txt` (restrict the content share and the source
  folder to the ConfigMgr admins).
- Installation program:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-EdamamePosture.ps1 -User ci-fleet -Domain example.com -PinFile .\pin.txt -LlmProvider portal -LlmApiKeyFile .\llm_key.txt -Version 2.0.1`
- Uninstall program:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-EdamamePosture.ps1 -Action uninstall`
- Installation behavior: **Install for system**; logon requirement:
  **Whether or not a user is logged on**.
- Detection method: script (PowerShell):
  ```powershell
  $s = Join-Path $env:ProgramData 'EDAMAME\Provisioning\installed.json'
  if ((Test-Path $s) -and ((Get-Content -Raw $s | ConvertFrom-Json).version -eq '2.0.1')) { 'installed' }
  ```
- Return codes: 0 success; 2-8 failure (see the script header).

Do not put the PIN or the key on the program command line: it is stored in
the site database, shown in the console and logged in `AppEnforce.log` on
clients.

A **Configuration Item** with the same detection script (remediation = run
the application again) covers drift.

## App (scenario B)

Application, deployment type **Script Installer** with the bundle:

- Installation program: `edamame-windows-<ver>-setup.exe /quiet /norestart /log "%ProgramData%\EDAMAME\Provisioning\Logs\bundle.log"`
- Uninstall program: `edamame-windows-<ver>-setup.exe /uninstall /quiet /norestart`
- Detection: registry `HKEY_LOCAL_MACHINE\SOFTWARE\EDAMAME`, value
  `EdamameMsixInstalledVersion`, data type String, equals `<ver>.0`.
- Return codes: 0 success, 3010 soft reboot, 1641 hard reboot.

Or use `Install-EdamameApp.ps1` as the installation program to download and
verify the bundle at install time.
