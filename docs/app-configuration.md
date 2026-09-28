# EDAMAME Security app: what can be preconfigured

## Today (2.0.x)

| Setting | Linux | macOS / Windows |
|---|---|---|
| Silent install | yes (APT) | yes (`installer -pkg`, bundle `/quiet`) |
| Helper Full Disk Access (macOS) | n/a | yes, PPPC profile ([profiles/macos](../profiles/macos/edamame-pppc-login-items.mobileconfig)) |
| Hub user / domain / PIN | yes: `/etc/edamame_posture.conf` (the Linux app uses the posture service) | **no** |
| EDAMAME Portal key / BYO LLM | yes: same file | **no** |
| Protection on (Assistant + detectors) | yes: `agentic_mode` in the same file | **no** |
| Network monitoring consent | n/a (service configuration) | **no** |
| Lock settings against user changes | root-only file | **no** |

On macOS and Windows the app reads no managed configuration. What was
checked in the source:

- The app's only startup switches are compile-time `--dart-define` values
  (`EDAMAME_CORE_TARGET`, `EDAMAME_DEMO_MODE`, certificates); nothing is read
  from the environment, the registry or managed preferences at run time.
- The core persists its state per user: `UserDefaults` of
  `com.edamametechnologies.edamame` on macOS, `%APPDATA%\com.edamametech\EDAMAME Security\`
  on Windows. Hub credentials are the `connection_status` entry; the LLM
  configuration is the `agentic` entry. Pre-seeding these is not supported
  (format is internal, and the MSIX / sandbox containers redirect paths).

So for scenario B on macOS and Windows: deploy the app and the PPPC profile
with the MDM, then have users enroll in the app (email + PIN from the Hub
invitation, then **Connect Portal** or their own model, then the protection
button).

### Unsupported interim workaround: edamame_cli against the running app

The app's core serves the same local RPC interface as the posture daemon, and
`edamame_cli` (Homebrew `edamametechnologies/tap/edamame-cli`, Chocolatey
`edamame-cli`, or the `edamame_cli` GitHub releases) can call it. EDAMAME uses
this internally to inspect running apps. A script running while the user's
app is open could therefore configure it:

```sh
# Secrets go through stdin, never on the command line.
{
  printf 'set_credentials {"user":"%s","domain":"%s","pin":"%s"}\n' "$U" "$D" "$PIN"
  printf 'connect_domain\n'
  printf 'agentic_set_edamame_api_key {"api_key":"%s"}\n' "$KEY"
  printf 'agentic_set_protection {"enabled":true}\n'
  printf 'exit\n'
} | edamame_cli interactive
```

This is **not validated by this repository and not a supported admin
interface**: it needs the app running in a user session, the RPC names and
arguments are internal and can change between releases, and nothing
prevents the user from changing the values afterwards. It is documented so
admins know what the product change below replaces.

## Proposed: managed configuration (requires EDAMAME >= 2.1, proposed)

The templates in [profiles/](../profiles) show the proposed keys. They are
**not read by any released version**.

| Key | Type | Meaning |
|---|---|---|
| `OrganizationName` | string | Shown as "Managed by <org>" in the app |
| `HubEmail` | string | `user@domain`; accepts MDM variables (Jamf `$EMAIL`, Intune `{{mail}}` in macOS custom profiles) |
| `HubEmailSource` | `upn` / `policy` | Windows: use the signed-in user's UPN instead of a per-device value |
| `LockHubEnrollment` | bool | User cannot change or disconnect the Hub account |
| `LLMProvider` | `portal` / `claude` / `openai` / `ollama` / `none` | |
| `LLMModel`, `LLMBaseURL` | string | |
| `LockLLM` | bool | User cannot change the LLM |
| `ProtectionEnabled` | bool | Turns the protection switch on |
| `AssistantLevel` | `review` / `auto` | |
| `LockProtection` | bool | User cannot turn protection off |
| `NetworkMonitoringConsent` | bool | Organization consent for LAN scan / capture (the app still shows the user what is collected) |

Where they would be read:

| OS | Non-secret keys | Secrets (Hub PIN, LLM key) |
|---|---|---|
| macOS | Configuration profile, preference domain `com.edamametechnologies.edamame` | `/Library/Application Support/EDAMAME/Managed/secrets.json`, `root:wheel 0600`, read by the helper |
| Windows | `HKLM\SOFTWARE\Policies\EDAMAME\EDAMAME Security` (GPO / ADMX / Intune) | `%ProgramData%\EDAMAME\Managed\secrets.json`, SYSTEM + Administrators, read by the helper |
| Linux | `/etc/edamame_posture.conf` (already works) | same file |

Secrets are kept out of profiles and policy on purpose: managed preferences
and `HKLM\SOFTWARE\Policies` are readable by every local user, while the
helper already runs as root / SYSTEM. A per-user PIN is also a poor fit for a
device-wide profile; the proposal includes a Hub-issued enrollment token
that an MDM can deploy fleet-wide.
