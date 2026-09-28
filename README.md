# EDAMAME auto_provisioning

Scripts, profiles and MDM guides for deploying [EDAMAME](https://edamame.tech)
on managed fleets with a preconfigured EDAMAME Hub enrollment (user, domain,
PIN) and LLM configuration (EDAMAME Portal API key, or your own Claude, OpenAI
or Ollama).

It covers two products:

| Product | What it is | Runs as |
|---|---|---|
| **EDAMAME Posture** (`edamame_posture`) | Headless agent: security posture, Hub reporting, network capture, attack pattern and divergence detection, AI assistant | root / SYSTEM service |
| **EDAMAME Security** app + **EDAMAME Helper** | Desktop app (macOS, Windows, Linux) with a privileged helper | per-user app + root / SYSTEM helper |

## Scenarios

| | Scenario | Zero-touch today? |
|---|---|---|
| A | **Posture only**: servers, CI runners, Linux fleets, kiosks, any headless host | **Yes** on Linux, macOS and Windows |
| B | **EDAMAME Security app + helper** on managed desktops | **Linux: yes** (the Linux app is a GUI for the posture service, so scenario A's configuration applies). **macOS / Windows: yes with EDAMAME >= 2.0.2**: a configuration profile / Group Policy sets Hub enrollment, the LLM, protection and locks, and a root-only secrets file delivers the PIN and key ([docs/app-configuration.md](docs/app-configuration.md)); earlier versions: install only |
| C | **Mixed fleet**: A on servers, B on desktops, one Hub domain | As A and B. Do not install Posture and the app on the same macOS or Windows host (see [docs/configuration-reference.md](docs/configuration-reference.md#one-edamame-core-per-host)) |

## Contents

```
scripts/
  linux/install-edamame-posture.sh    APT/APK install, /etc/edamame_posture.conf, service (A, Linux B)
  macos/install-edamame-posture.sh    PKG install + verification, config, service (A)
  macos/install-edamame-app.sh        App + helper PKG install + verification (B)
  windows/Install-EdamamePosture.ps1  exe install + verification, config, service (A)
  windows/Install-EdamameApp.ps1      All-in-one bundle install + verification (B)
profiles/
  macos/edamame-pppc-login-items.mobileconfig          Full Disk Access + managed login items (works today)
  macos/edamame-managed-settings.mobileconfig         app managed settings (EDAMAME >= 2.0.2)
  windows/edamame-managed-settings.reg                same, registry form (EDAMAME >= 2.0.2)
  windows/admx/                                       same, ADMX/ADML (EDAMAME >= 2.0.2)
ansible/                              Ansible role `edamame` + example playbook (Linux fleets)
docs/                                 distribution, configuration reference, app status, security, per-MDM guides
tests/, tools/lint.sh                 unit tests for the configuration logic, static checks
```

## Quick start

Linux (Debian, Ubuntu, Raspberry Pi OS, Alpine), as root:

```sh
export EDAMAME_USER=ci-fleet EDAMAME_DOMAIN=example.com
export EDAMAME_PIN_FILE=/root/edamame_pin            # 0600 file, or EDAMAME_PIN
export EDAMAME_LLM_PROVIDER=portal
export EDAMAME_LLM_API_KEY_FILE=/root/edamame_llm_key
sh scripts/linux/install-edamame-posture.sh
```

macOS, as root: same variables, `bash scripts/macos/install-edamame-posture.sh`.
Windows, elevated or as SYSTEM: same variables, `powershell -ExecutionPolicy Bypass -File scripts\windows\Install-EdamamePosture.ps1`.

Every script reads the same parameters:

| Variable | Meaning |
|---|---|
| `EDAMAME_USER`, `EDAMAME_DOMAIN`, `EDAMAME_PIN` | Hub enrollment (set all three, or none). `user@domain` in `EDAMAME_USER` is split |
| `EDAMAME_PIN_FILE`, `EDAMAME_LLM_API_KEY_FILE` | Read the secret from a file instead of the environment |
| `EDAMAME_DEVICE_ID` | Optional device id suffix (CI runners) |
| `EDAMAME_LLM_PROVIDER` | `portal`, `claude`, `openai`, `ollama` or `none` |
| `EDAMAME_LLM_API_KEY` | Portal API key (`edm_...`) or provider key |
| `EDAMAME_LLM_MODEL`, `EDAMAME_LLM_BASE_URL` | Model; Ollama URL or API base URL |
| `EDAMAME_AGENTIC_MODE` | `analyze` (default when a provider is set), `auto`, or `disabled` |
| `EDAMAME_VERSION` | `latest` (default) or an exact version such as `2.0.1` |
| `EDAMAME_SHA256` | Expected SHA-256 of the download (with an exact version) |
| `EDAMAME_ACTION` | `install` (default) or `uninstall` |

Exit codes are the same everywhere: `0` ok, `1` unexpected error, `2` invalid
parameters, `3` unsupported platform, `4` download failed, `5` integrity check
failed, `6` install failed, `7` configuration failed, `8` service did not start
(`3010` from `Install-EdamameApp.ps1` = installed, reboot required).

The scripts are idempotent: a re-run with the same parameters downloads
nothing and does not restart anything. Parameters left out keep their current
value.

EDAMAME >= 2.0.2: the macOS and Windows posture scripts register the
product's own service (`edamame_posture install-service`, which reads the
configuration file itself, so the PIN never appears on a command line) and
replace the LaunchDaemon / scheduled task they install for older releases.
Downloads are checked against the release's signed `SHA256SUMS`; see
[docs/distribution.md](docs/distribution.md#verifying-downloads-edamame--202).

## Prerequisites

- **An EDAMAME Hub domain.** Users are invited from the Hub's Onboarding page
  (or self-onboard). The PIN is a 6-digit code the Hub issues for a Hub user.
  For servers and CI, create one Hub user per fleet and reuse its PIN on every
  host, with `EDAMAME_DEVICE_ID` to tell hosts apart; this is how the
  EDAMAME GitHub Action enrolls runners.
- **An LLM**, only if you enable the AI assistant and the attack pattern /
  divergence detectors (`EDAMAME_AGENTIC_MODE` other than `disabled`):
  - **EDAMAME Portal** (recommended): create an API key at
    `https://portal.edamame.tech`. Keys start with `edm_` (or `edak_`).
  - **Bring your own**: an Anthropic or OpenAI API key, or a reachable Ollama
    server (`EDAMAME_LLM_BASE_URL=http://host:11434`).

  With posture, detection findings are only published when the LLM answers
  (fail-closed adjudication), so an agentic mode without a working LLM
  reports nothing. The scripts refuse an agentic mode without a provider.
- **Network egress** to `github.com`, `api.github.com`,
  `objects.githubusercontent.com` / `release-assets.githubusercontent.com`
  (downloads), `edamame.s3.eu-west-1.amazonaws.com` (Linux packages), and the
  EDAMAME Hub / Portal endpoints at run time.

## Security notes

- **The Hub PIN and the LLM API key are secrets.** Deliver them through your
  MDM's secret mechanism (Ansible Vault, Jamf script parameters restricted to
  admins, Intune script content restricted by RBAC, a root-only file), never
  in a script committed to git. The `$Embedded` / `: "${EDAMAME_...:=}"`
  blocks exist for tools that cannot pass parameters: fill them only in a
  private copy uploaded to the MDM.
- **Configuration files are root-only.** `/etc/edamame_posture.conf` and the
  macOS provisioning file are `0600 root`; the Windows `posture.json` lives in
  a directory whose ACL is SYSTEM + Administrators only. A world-readable
  posture configuration leaks the LLM key: the Linux service conf once shipped
  `0644`, which is why the scripts re-apply the mode on every run.
- **Logs never contain secrets.** The scripts log "pin: set" / "llm key: set".
- **Known limitation:** `edamame_posture` accepts the PIN only as a command
  line argument, so while the service runs the PIN is visible in the process
  list to local users on Linux and macOS (administrators on Windows). The LLM
  key is always passed through the environment. See
  [docs/security.md](docs/security.md).
- **Downloads are verified** before install: SHA-256 against the digest
  GitHub publishes for each release asset, plus the Apple Developer ID
  Installer signature and notarization (Team ID `WSL782B48J`) on macOS, and
  the Authenticode signature (`EDAMAME TECHNOLOGIES SAS`) on Windows. The
  Linux repository key fingerprint is pinned.

## Documentation

- [docs/distribution.md](docs/distribution.md): every channel, artifact name and URL
- [docs/configuration-reference.md](docs/configuration-reference.md): posture flags, configuration keys, environment variables, where each script writes what
- [docs/app-configuration.md](docs/app-configuration.md): the desktop app's managed settings (EDAMAME >= 2.0.2): keys, secrets file, precedence and locks
- [docs/security.md](docs/security.md): secret handling per MDM, file permissions, verification
- MDM guides: [generic](docs/mdm/generic.md), [Microsoft Intune](docs/mdm/intune.md), [Jamf Pro](docs/mdm/jamf.md), [Kandji](docs/mdm/kandji.md), [Mosyle](docs/mdm/mosyle.md), [Workspace ONE](docs/mdm/workspace-one.md), [ConfigMgr (SCCM)](docs/mdm/configmgr.md), [Linux fleets: Ansible, Puppet, Chef, Salt](docs/linux-fleet.md)

## Validation

`tools/lint.sh` runs `sh -n` / `bash -n`, ShellCheck, the unit tests in
`tests/` (configuration rendering and merge, parameter validation, the
embedded macOS launcher against a stub binary, and optionally the real Linux
service wrapper), a PowerShell parse check (including the embedded launcher)
and PSScriptAnalyzer when `pwsh` is available, `plutil` / `xmllint` on the
profiles, and `ansible-playbook --syntax-check`, `ansible-lint` and
`yamllint` when installed. Missing tools are reported as `SKIP`.

## License

Apache License 2.0, see [LICENSE](LICENSE).
