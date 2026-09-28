# Distribution channels

Verified on 2026-09-28 against release 2.0.1 (GitHub release assets listed
with `gh release view`, S3 objects checked with HTTP HEAD). `<ver>` is a
version without the `v`, e.g. `2.0.1`; GitHub tags are `v<ver>`.

## Which artifact for which MDM job

| Job | Recommended artifact | Why |
|---|---|---|
| Posture on Linux | APT / APK repository | Signed repository, systemd / OpenRC service, conf file |
| Posture on macOS | `edamame-posture-macos-<ver>.pkg` (GitHub) | Signed + notarized, Endpoint Security entitlement |
| Posture on Windows | `edamame_posture-<ver>-x86_64-pc-windows-msvc.exe` (GitHub) | Authenticode-signed binary; no installer exists |
| App on macOS | `edamame-macos-<ver>.pkg` (GitHub) | Signed + notarized, app **and** helper |
| App on Windows | `edamame-windows-<ver>-setup.exe` (GitHub) | Signed Burn bundle: helper MSI + MSIX provisioned machine-wide |
| App on Linux | APT package `edamame-security` (amd64) | Pulls `edamame-posture` |

The scripts in this repository download from **GitHub releases** because
GitHub publishes a SHA-256 digest for every release asset (`digest` field of
`https://api.github.com/repos/<repo>/releases/tags/v<ver>`), which the scripts
verify. The S3 copies have no published checksum. EDAMAME does not publish a
`SHA256SUMS` file or detached signatures today.

## EDAMAME Posture

Repository: `edamametechnologies/edamame_posture_cli`
(`edamametechnologies/edamame_posture` redirects to it).
URL pattern: `https://github.com/edamametechnologies/edamame_posture_cli/releases/download/v<ver>/<asset>`

| Asset | Platform |
|---|---|
| `edamame-posture-macos-<ver>.pkg` | macOS, universal (installs an app-like bundle under `/Library/Application Support/EDAMAME/EDAMAME-Posture/` and the symlink `/usr/local/bin/edamame_posture`) |
| `edamame_posture-<ver>-universal-apple-darwin` | macOS raw binary (no Endpoint Security provisioning profile; prefer the PKG) |
| `edamame_posture-<ver>-x86_64-pc-windows-msvc.exe` | Windows x64 |
| `edamame-posture_<ver>-1_{amd64,arm64,armhf,i386}.deb` | Debian family (same packages as the APT repository) |
| `edamame-posture-<ver>-r1-{x86_64,aarch64}.apk` | Alpine |
| `edamame_posture-<ver>-{x86_64,aarch64,i686}-unknown-linux-gnu`, `-{x86_64,aarch64}-unknown-linux-musl`, `-armv7-unknown-linux-gnueabihf` | Linux raw binaries |
| `*-debug*` | Debug builds (do not deploy) |
| `install.sh` | The upstream interactive/CI installer |

Package managers:

| Channel | Identifier | Notes |
|---|---|---|
| APT | `edamame-posture` from `deb [signed-by=/usr/share/keyrings/edamame.gpg] https://edamame.s3.eu-west-1.amazonaws.com/repo stable main` | Key: `https://edamame.s3.eu-west-1.amazonaws.com/repo/public.key`, fingerprint `D1C5 8B47 675E 4867 92DA FBAE 42A2 002B 57F1 A203`. Architectures amd64, arm64, armhf, i386. Installs `edamame_posture.service` (enabled and started by the package) and `/etc/edamame_posture.conf` |
| APK | `edamame-posture` from `https://edamame.s3.eu-west-1.amazonaws.com/repo/alpine/v3.15/main` | Key `.../alpine/v3.15/main/<arch>/edamame.rsa.pub` (SHA-256 `32bb30b9...de89d7c`). OpenRC service `edamame_posture` |
| Homebrew | `brew install --cask edamametechnologies/tap/edamame-posture` | Installs the PKG; no service |
| Chocolatey | `edamame-posture` | Downloads the GitHub exe (checksum pinned in the package) and adds a shim; no service |

The macOS PKG, Homebrew, Chocolatey and raw binaries **install no service**.
The upstream `install.sh` starts a background daemon on macOS/Windows that
does not survive a reboot. The scripts in this repository add a LaunchDaemon
(macOS) or a SYSTEM scheduled task (Windows).

## EDAMAME Security app and EDAMAME Helper

Repository: `edamametechnologies/edamame_security` (releases carry the app
installers; source is not public).
URL pattern: `https://github.com/edamametechnologies/edamame_security/releases/download/v<ver>/<asset>`

| Asset | Contents |
|---|---|
| `edamame-macos-<ver>.pkg` | Distribution PKG with two choices: `com.edamametechnologies.edamame` (the app, `/Applications/EDAMAME Security.app`) and `com.edamametechnologies.edamame-helper` (the helper LaunchDaemon). Signed "Developer ID Installer: Edamame Technologies (WSL782B48J)", notarized. The postinstall relaunches the app in the console user's session |
| `edamame-windows-<ver>-setup.exe` | WiX 5 Burn bundle: installs the helper MSI (service `edamame_helper`) and provisions the MSIX machine-wide (`Add-AppxProvisionedPackage` plus registration for the logged-on user). Silent switches: `/quiet /norestart /log <file>`; uninstall `/uninstall /quiet`. Writes `HKLM\SOFTWARE\EDAMAME\EdamameMsixInstalledVersion` (4-part version) |
| `edamame-windows-<ver>-helper.msi` | Helper MSI alone (`msiexec /i ... /qn /norestart`) |
| `edamame-windows-<ver>.msix` | App MSIX alone |

Helper-only releases also exist in `edamametechnologies/edamame_helper`
(`edamame-helper-macos-<ver>.pkg`, `edamame-helper-windows-<ver>.msi`).

S3 mirrors (same builds, no checksum file):

| URL | |
|---|---|
| `https://edamame.s3.eu-west-1.amazonaws.com/macos/edamame-latest.pkg`, `.../macos/edamame-<ver>.pkg` | macOS PKG |
| `https://edamame.s3.eu-west-1.amazonaws.com/windows/edamame-latest-setup.exe`, `.../windows/edamame-<ver>-setup.exe` | Windows bundle |
| `https://edamame.s3.eu-west-1.amazonaws.com/windows/edamame-latest.msix`, `.../windows/edamame-<ver>.msix` | MSIX |
| `https://edamame.s3.eu-west-1.amazonaws.com/windows/edamame_helper-latest-x86_64.msi`, `.../windows/edamame_helper-<ver>-x86_64.msi` | Helper MSI |
| `https://edamame.s3.eu-west-1.amazonaws.com/{macos,windows}/LATEST` | Plain-text latest version |

Linux: APT package `edamame-security` (amd64 only), which depends on
`edamame-posture`. The Linux app is a gRPC front end for the
`edamame_posture` service; it has no core of its own.

Package managers and stores:

| Channel | Identifier | MDM notes |
|---|---|---|
| Homebrew | `edamametechnologies/tap/edamame`, `edamametechnologies/tap/edamame-helper` | Casks install the same PKGs |
| Chocolatey | `edamame`, `edamame-helper` | The `edamame` package registers the MSIX with `Add-AppxPackage` for the account that runs choco; run as SYSTEM (as MDMs do) the app is not registered for users. Use the bundle instead |
| Mac App Store | `id1636777324` | Sandboxed build without the helper; can be assigned through Apple Business Manager, but cannot be preconfigured and the helper must be deployed separately |
| Microsoft Store | `9N399LMTKQLQ` | MSIX only, no helper; same limits |
| iOS App Store / Google Play | `id6448937722` / `com.edamametech.edamame` | Mobile, out of scope here |

The snap (`edamame-security`) is built but only published to a development
S3 folder; it is not a production channel.

## Npcap (Windows packet capture)

Neither the bundle nor posture's exe ships Npcap. `edamame_posture` tries to
install Npcap silently at start only when it is started with
`--packet-capture`; the scripts here do not pass that flag, and turning
agentic protection on starts capture without installing Npcap. Deploy Npcap
with your MDM before enabling agentic mode on Windows. Npcap's free
license does not cover every commercial fleet deployment; check Npcap's
licensing (Npcap OEM) before deploying it at scale, and deploy it yourself if
you hold an OEM license.
