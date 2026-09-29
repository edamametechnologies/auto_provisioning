# Distribution channels

Verified on 2026-09-28 against release 2.0.1 (GitHub release assets listed
with `gh release view`, S3 objects checked with HTTP HEAD). `<ver>` is a
version without the `v`, e.g. `2.0.1`; GitHub tags are `v<ver>`.

## Which artifact for which MDM job

| Job | Recommended artifact | Why |
|---|---|---|
| Posture on Linux | APT / APK repository | Signed repository, systemd / OpenRC service, conf file |
| Posture on macOS | `edamame-posture-macos-<ver>.pkg` (GitHub) | Signed + notarized, Endpoint Security entitlement |
| Posture on Windows | `edamame_posture-<ver>-x86_64-pc-windows-msvc.exe` (GitHub) | Authenticode-signed binary; no installer, service through `edamame_posture install-service` (EDAMAME >= 2.0.2) |
| App on macOS | `edamame-macos-<ver>.pkg` (GitHub) | Signed + notarized, app **and** helper |
| App on Windows | `edamame-windows-<ver>-setup.exe` (GitHub) | Signed Burn bundle: helper MSI + MSIX provisioned machine-wide |
| App on Linux | APT package `edamame-security` (amd64) | Pulls `edamame-posture` |

The scripts in this repository download from **GitHub releases**. From
EDAMAME 2.0.2 every release carries a signed `SHA256SUMS` (see
[Verifying downloads](#verifying-downloads-edamame--202)), which the scripts
read first; for older releases they fall back to the SHA-256 digest GitHub
publishes for every asset (`digest` field of
`https://api.github.com/repos/<repo>/releases/tags/v<ver>`, rate-limited API).
Releases up to 2.0.1 have no `SHA256SUMS`, no signature and no checksum next
to the S3 copies.

## Verifying downloads (EDAMAME >= 2.0.2)

Every release of `edamame_posture_cli`, `edamame_cli`, `edamame_helper` and
`edamame_security` carries:

| Asset | What it is |
|---|---|
| `SHA256SUMS` | SHA-256 of every other asset of the release, `sha256sum -c` format |
| `SHA256SUMS.sigstore.json` | Keyless Sigstore signature of `SHA256SUMS` (cosign bundle), made by the release workflow; no EDAMAME key to distribute |

and each binary built in a public repository (posture, CLI, helper) has a
GitHub build provenance attestation. The app installers on `edamame_security`
are built in an internal repository: their attestations are readable by
EDAMAME only, so verify them through the signed `SHA256SUMS`.

```sh
V=2.0.2
R=edamametechnologies/edamame_posture_cli   # or edamame_cli, edamame_helper
gh release download "v$V" --repo "$R" --pattern SHA256SUMS --pattern 'SHA256SUMS.sigstore.json' \
  --pattern "edamame-posture-macos-$V.pkg"

# 1. The checksum file was produced by the release workflow of that repository
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp "^https://github\.com/$R/\.github/workflows/release_checksums\.yml@refs/heads/main\$" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS

# 2. The download matches it
sha256sum --ignore-missing -c SHA256SUMS      # macOS: shasum -a 256 --ignore-missing -c SHA256SUMS

# 3. Optional, public repositories: build provenance of one file
gh attestation verify "edamame-posture-macos-$V.pkg" --repo "$R"
```

For the app (`edamame_security` release), the signing identity is the
workflow in the internal `edamame_app` repository:

```sh
cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/edamametechnologies/edamame_app/\.github/workflows/release_checksums\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

On Windows: `(Get-FileHash .\edamame-windows-2.0.2-setup.exe -Algorithm SHA256).Hash`
against the line of `SHA256SUMS`; `cosign.exe` and `gh.exe` take the same
arguments.

The S3 mirrors (`macos/`, `windows/` of the `edamame` bucket, the
`edamame-helper` bucket) have a `<object>.sha256` next to each object, e.g.
`https://edamame.s3.eu-west-1.amazonaws.com/windows/edamame-latest-setup.exe.sha256`.
It holds the same digest as the release's `SHA256SUMS` (which names the file
differently, e.g. `edamame-windows-<ver>-setup.exe`): trust the signed
`SHA256SUMS`, and use the sidecar only to detect a truncated or stale mirror
download. `LATEST` files carry no checksum; resolve the version, then verify
the versioned object. APT and APK repositories keep their own signatures
(below).

Suggested MDM practice: verify the signature once on an admin workstation,
then pin `EDAMAME_VERSION` and `EDAMAME_SHA256` in the MDM so endpoints need
neither cosign nor the GitHub API.

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

The macOS PKG, Homebrew, Chocolatey and raw binaries **install no service by
themselves**. From EDAMAME 2.0.2, `edamame_posture install-service` (as root /
Administrator) registers one that starts at boot, restarts on failure and
reads a configuration file only root / SYSTEM can read (the PIN never
appears on a command line):

| Platform | Service | Default configuration |
|---|---|---|
| macOS | LaunchDaemon `com.edamametechnologies.edamame-posture` | `/Library/Application Support/EDAMAME/EDAMAME-Posture/edamame_posture.conf` |
| Windows | service `edamame_posture` (LocalSystem, automatic), binary copied to `%ProgramFiles%\EDAMAME\Posture` | `%ProgramData%\EDAMAME\Posture\edamame_posture.conf` |
| Linux raw binary (systemd) | `/etc/systemd/system/edamame_posture.service` | `/etc/edamame_posture.conf` |

The file uses the Linux `edamame_posture.conf` format (see
[configuration-reference.md](configuration-reference.md)); `--conf <path>`
selects another one. The macOS PKG (including `brew upgrade`) and the
Chocolatey package restart an installed service on upgrade;
`edamame_posture uninstall-service` removes it. The scripts in this repository
use it on 2.0.2 and later, and fall back to their own LaunchDaemon (macOS) or
SYSTEM scheduled task (Windows) for older releases, where the upstream
`install.sh` only starts a background daemon that does not survive a reboot.

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

S3 mirrors (same builds; from 2.0.2 each object has a `<object>.sha256` next
to it, see [Verifying downloads](#verifying-downloads-edamame--202)):

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
| Chocolatey | `edamame`, `edamame-helper` | The `edamame` (app) package is not on the community feed today: its last version, 1.1.2, was never approved, and 1.9.0 to 2.0.2 were not published. Publication resumes with 2.0.3, whose package provisions the MSIX machine-wide (`Add-AppxProvisionedPackage`, the bundle's own installer script) and registers it for the signed-in user; other users get it at their next sign-in. Until then, use the bundle. The helper comes from `edamame-helper` (published) |
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
