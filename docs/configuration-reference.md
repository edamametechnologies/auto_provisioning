# Configuration reference

Read from the source of `edamame_posture` 2.0.1 / 2.0.2 (`src/cli.rs`,
`src/background.rs`, `src/daemon.rs`, `linux/edamame_posture_daemon.sh`,
`install.sh`).

## edamame_posture start commands

| Command | Use |
|---|---|
| `foreground-start` | Runs in the foreground until killed. What the Linux service, and the macOS / Windows launchers of this repository, run |
| `background-start` (alias `start`) | Forks a background daemon. Used by `install.sh` on macOS / Windows; does not survive a reboot |
| `background-start-disconnected` | Background daemon without Hub credentials |
| `background-stop` (alias `stop`), `status`, `wait-for-connection [timeout]`, `logs` | Control of a running daemon |

Options shared by `foreground-start` and `background-start`:

| Option | Environment | Meaning |
|---|---|---|
| `--user`, `-u` | | Hub user (no `@`) |
| `--domain`, `-d` | | Hub domain (FQDN) |
| `--pin`, `-p` | | Hub PIN (digits). **No environment variable exists**; see [security.md](security.md) |
| `--device-id` | | Device id suffix; flags the endpoint as a CI/CD runner |
| `--llm-api-key`, `-k` | `EDAMAME_LLM_API_KEY` | LLM key (all providers use this variable) |
| `--agentic-mode` | | `auto`, `analyze`, `disabled` (default `disabled`) |
| `--agentic-provider` | | `edamame` (Portal), `claude`, `openai`, `ollama`, `none` |
| `--agentic-interval` | | Seconds between Assistant runs (default 3600) |
| | `EDAMAME_LLM_MODEL` | Model for claude / openai / ollama. Defaults: `claude-haiku-4-5-20251001`, `gpt-5-mini-2025-08-07`, `llama4` |
| | `EDAMAME_LLM_BASE_URL` | Ollama URL; also passed as the base URL for claude / openai |
| `--network-scan`, `--packet-capture`, `--whitelist`, `--fail-on-*`, `--cancel-on-violation`, `--include-local-traffic` | | Network monitoring and CI enforcement |
| `--export-to-portal` | `EDAMAME_EXPORT_TO_PORTAL` | Export agentic action history to the Portal |
| `-v` | | Log to stdout instead of the daemon's own log files |

Semantics worth knowing:

- `--agentic-mode analyze|auto` is the **agentic protection switch**: it turns
  on the Assistant, attack pattern detection and divergence detection
  together, and pins the strict `llm` adjudication. Findings are published
  only when the LLM answers, so an agentic mode without a working LLM reports
  nothing.
- `--agentic-mode disabled` does **not** turn protection off. It leaves the
  persisted state as it was (all off on a fresh install). To turn protection
  off on a host where it was on, use the operator RPC
  (`edamame_cli rpc agentic_set_protection '{"enabled": false}'`) against the
  running daemon.
- With `edamame`, the key must start with `edm_` or `edak_` (a warning is
  logged otherwise) and the model is chosen by the Portal.

## Linux: /etc/edamame_posture.conf

Read at every service start by `/usr/bin/edamame_posture_daemon.sh` (systemd
unit `edamame_posture.service`, OpenRC service `edamame_posture`), which runs
`edamame_posture foreground-start -v ...`. The package ships the file with
mode `0600`; it is a dpkg conffile, so install with
`-o Dpkg::Options::=--force-confold` once you manage it.

| Key | Values | Effect |
|---|---|---|
| `edamame_user`, `edamame_domain`, `edamame_pin` | strings | Connected mode when all three are set, else disconnected |
| `edamame_device_id` | string | `--device-id` |
| `agentic_mode` | `auto`, `analyze`, `disabled` | Passed only when a provider credential is present |
| `agentic_provider` | `edamame`, `claude`, `openai`, `ollama`, empty | Selects which credential slot is used. Empty = first non-empty slot in the order below |
| `llm_api_key` | Portal key | slot for `edamame` |
| `claude_api_key`, `openai_api_key` | provider keys | slots for `claude`, `openai` |
| `ollama_base_url` | URL | slot for `ollama` |
| `agentic_interval` | seconds | |
| `start_lanscan`, `start_capture`, `whitelist_name`, `fail_on_whitelist`, `fail_on_blacklist`, `fail_on_findings`, `cancel_on_violation`, `include_local_traffic` | `true`/`false`, string | Network monitoring flags |
| `notification_*`, `slack_*`, `telegram_*` | strings | Slack / Telegram notifications |

Values are double-quoted; inside quotes `\"` and `\\` are escapes. The file
has no key for the model or for a claude / openai base URL: the Linux script
and the Ansible role put `EDAMAME_LLM_MODEL` / `EDAMAME_LLM_BASE_URL` in the
systemd drop-in `/etc/systemd/system/edamame_posture.service.d/50-edamame-provisioning.conf`
(OpenRC: a marked block in `/etc/conf.d/edamame_posture`, not validated). The
wrapper passes its environment through to `edamame_posture`.

The Linux GUI (`edamame-security`) talks to this same service, so this file
also configures the desktop app on Linux.

## What each script writes

| Script | Binary | Configuration (secrets) | Service | Logs |
|---|---|---|---|---|
| `scripts/linux/install-edamame-posture.sh` | APT/APK package | `/etc/edamame_posture.conf` `0600 root`; drop-in for model / base URL | `edamame_posture.service` (enabled, restarted on change) | `/var/log/edamame-provisioning.log`; daemon: `journalctl -u edamame_posture` |
| `scripts/macos/install-edamame-posture.sh` | PKG → `/Library/Application Support/EDAMAME/EDAMAME-Posture/edamame_posture.app` | `/Library/Application Support/EDAMAME/Provisioning/edamame_posture.conf` `0600 root:wheel` (same line format; one `llm_api_key` slot plus `llm_model`, `llm_base_url`) | LaunchDaemon `com.edamametechnologies.auto-provisioning.posture` → `/bin/sh .../Provisioning/edamame_posture_launcher.sh` → `foreground-start` (KeepAlive) | `/Library/Logs/EDAMAME/provisioning.log`, `/Library/Logs/EDAMAME/edamame_posture_daemon.log`; daemon: `/var/log/edamame/edamame_posture_*.log` |
| `scripts/windows/Install-EdamamePosture.ps1` | `%ProgramFiles%\EDAMAME\Posture\edamame_posture.exe` | `%ProgramData%\EDAMAME\Provisioning\posture.json` (directory ACL: SYSTEM + Administrators) | Scheduled task `\EDAMAME\EDAMAME Posture` (SYSTEM, at startup, no time limit) → `Start-EdamamePosture.ps1` loop → `foreground-start` | `%ProgramData%\EDAMAME\Provisioning\Logs\`; daemon: log files beside the exe |
| `scripts/macos/install-edamame-app.sh` | PKG (app + helper) | none | helper LaunchDaemon from the PKG | `/Library/Logs/EDAMAME/provisioning.log` |
| `scripts/windows/Install-EdamameApp.ps1` | Burn bundle (helper MSI + MSIX) | none | `edamame_helper` service from the MSI | `%ProgramData%\EDAMAME\Provisioning\Logs\` |

Merge rules (all posture scripts): parameters not supplied keep their current
value. Setting `EDAMAME_LLM_PROVIDER` makes the script own the credential:
switching provider drops the previous provider's key, model and URL;
`none` clears all of them and sets the mode to `disabled`. Setting a provider
without `EDAMAME_AGENTIC_MODE` sets the mode to `analyze`.

## One EDAMAME core per host

The EDAMAME Security app (macOS, Windows) and `edamame_posture` each embed an
EDAMAME core that registers the device with the Hub and serves the local RPC
endpoint `edamame_cli` uses. Running both on one macOS or Windows host
gives that host two Hub devices and two cores competing for the local RPC
endpoint (its address is compiled into the binaries; this repository did not
test the combination), so it is not a supported setup. On Linux the app has no core of its own and uses the
posture service. Pick one product per host (scenario C = both products in one
fleet, not on one host).
