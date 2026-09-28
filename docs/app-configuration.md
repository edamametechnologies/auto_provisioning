# EDAMAME Security app: managed configuration

Requires **EDAMAME >= 2.0.2** on macOS and Windows. On Linux the app is a GUI
for the posture service: configure `/etc/edamame_posture.conf` instead
([linux-fleet.md](linux-fleet.md)). iOS and Android are not covered yet.

| Setting | Linux | macOS / Windows (>= 2.0.2) |
|---|---|---|
| Silent install | yes (APT) | yes (`installer -pkg`, bundle `/quiet`) |
| Helper Full Disk Access (macOS) | n/a | yes, PPPC profile ([profiles/macos](../profiles/macos/edamame-pppc-login-items.mobileconfig)) |
| Hub user / domain / PIN | `/etc/edamame_posture.conf` | policy + secrets file |
| EDAMAME Portal key / own LLM | same file | policy + secrets file |
| Protection on (Assistant + detectors) | `agentic_mode` | policy |
| Network monitoring consent | n/a (service configuration) | policy |
| Lock settings against user changes | root-only file | policy `Lock*` keys |

## Where the app reads it

| OS | Non-secret keys | Secrets (Hub PIN, LLM / Portal key) |
|---|---|---|
| macOS | Configuration profile, preference domain `com.edamametechnologies.edamame` (the app's bundle identifier), device or user scope. Only profile-delivered (forced) values count | `/Library/Application Support/EDAMAME/Managed/secrets.json`, owner `root`, mode `0600` (refused otherwise), read by the EDAMAME Helper |
| Windows | `HKLM\SOFTWARE\Policies\EDAMAME\EDAMAME Security` (GPO, [ADMX](../profiles/windows/admx), Intune ADMX import or registry) | `%ProgramData%\EDAMAME\Managed\secrets.json`, ACL SYSTEM + Administrators only (set it yourself; the app does not inspect the ACL), read by the EDAMAME Helper service |

Secrets never go in the profile or the policy key: managed preferences and
`HKLM\SOFTWARE\Policies` are readable by every local user. The helper runs as
root / SYSTEM, reads the file and hands it to the app over its authenticated
local channel. Without the helper (not installed, not running, Store build
without it) the status says `secrets: unavailable` and the secret-bearing
settings wait; nothing reads as "no secrets".

Templates: [profiles/macos/edamame-managed-settings.mobileconfig](../profiles/macos/edamame-managed-settings.mobileconfig),
[profiles/windows/edamame-managed-settings.reg](../profiles/windows/edamame-managed-settings.reg),
[profiles/windows/admx](../profiles/windows/admx).

## Keys

| Key | Type | Meaning |
|---|---|---|
| `OrganizationName` | string | Shown as "Managed by <org>" in the app and its notice |
| `HubEmail` | string | Hub account `user@domain`; accepts MDM variables (Jamf / Kandji `$EMAIL`, Intune `{{mail}}` in macOS custom profiles). A value still holding `$`, `{{` or `%` is rejected |
| `HubEmailSource` | `policy` / `upn` | Windows: `upn` enrolls with the signed-in user's user principal name (Entra ID / AD) |
| `LockHubEnrollment` | bool | The user cannot change or disconnect the Hub account |
| `LLMProvider` | `portal` / `claude` / `openai` / `ollama` / `none` | The model the Assistant and detection adjudication use |
| `LLMModel` | string | Claude / OpenAI / Ollama model. Ignored for `portal` |
| `LLMBaseURL` | string | `https://` or `http://` (Ollama, compatible APIs) |
| `LockLLM` | bool | The user cannot change the values the policy sets (provider, model, base URL, and the key when the secrets file carries one). Notification settings stay the user's |
| `ProtectionEnabled` | bool | Turns the protection switch on (or off): the Assistant, attack pattern detection and intent divergence detection |
| `AssistantLevel` | `review` / `auto` | The Assistant's level |
| `LockProtection` | bool | The user cannot change protection or the Assistant level away from the policy |
| `NetworkMonitoringConsent` | bool | The organization consents to LAN scanning on the user's behalf, on every network the device joins |
| `ShareAIFailureDetails` | bool | `true`: AI failure details are added to score reports; `false`: never. The user cannot change a set value |
| `CaptureEnabled` | bool | Starts / stops network session capture (needs the helper) |
| `FileMonitorEnabled` | bool | Starts / stops file event monitoring (needs the helper) |
| `LockMonitoring` | bool | The user cannot change capture / file monitoring away from the policy; turning protection off leaves them running |
| `HideAISettings` | bool | Hides the model connection section of Config > AI |

Booleans: plist `<true/>` / `<false/>`, registry `REG_DWORD` 0 / 1, or the
strings `true` / `false` / `1` / `0`. A lock without the value it locks is
ignored and reported.

### Secrets file

```json
{
  "hub_pin": "123456",
  "llm_api_key": "edm_... or sk-...",
  "hub_enrollment_token": null
}
```

Every field is optional; unknown fields are an error (a typo would otherwise
drop a secret silently). `llm_api_key` is the EDAMAME Portal API key when
`LLMProvider` is `portal`, else the provider's API key. `hub_enrollment_token`
is reserved for Hub enrollment tokens (not used yet; the Hub PIN is per user,
so a device-wide file fits one user per device). The app keeps what it
applied: the LLM key in its OS secret store (Keychain on macOS, DPAPI on
Windows), the Hub PIN in its per-user settings. You may remove the file after
enrollment, but then a rotated secret can no longer be re-applied.

macOS:

```sh
sudo install -d -o root -g wheel -m 0755 "/Library/Application Support/EDAMAME/Managed"
sudo install -o root -g wheel -m 0600 secrets.json "/Library/Application Support/EDAMAME/Managed/secrets.json"
```

Windows (elevated PowerShell):

```powershell
$dir = "$env:ProgramData\EDAMAME\Managed"
New-Item -ItemType Directory -Force $dir | Out-Null
icacls $dir /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
Copy-Item secrets.json "$dir\secrets.json"
```

## When settings apply, and who wins

- The app applies the policy about 5 seconds after it starts, every 15
  minutes, and when the helper becomes available; Config > Info has an
  "Apply again" button. No restart is needed after a profile or GPO change.
- **Locked** values are enforced: re-applied whenever they drift, and the
  app (and any local program calling its interface) is refused a change.
- **Unlocked** values are defaults: applied the first time and whenever the
  organization changes them; a user change in between is kept.
- **Removed** keys: the last applied value stays, the lock is released.
- Problems (invalid key, secrets file refused, Hub refused the PIN) are listed
  in Config > Info and raise one notification.

## What the user sees

Organization consent does not remove the duty to inform the user. When the
organization turns something on (Hub enrollment, a model, protection, network
monitoring consent, AI failure sharing, capture / file monitoring), the app
shows once a notice "This device is managed by <org>" listing each item, and
whether it is locked, with a link to the privacy policy; the user
acknowledges it. The notice is shown again when the list changes, and stays
available from the "Managed configuration" card in Config > Info. Locked
controls are disabled with a "Set by <org>" explanation.

Analytics and crash-report preferences stay the user's. In France and
Germany, employee monitoring tools also involve the CSE / works council:
check with your data protection officer before enabling
`NetworkMonitoringConsent`.

## Checking

```sh
edamame_cli rpc get_managed_configuration_status --pretty
```

reports the source, the managed keys, the locks, `secrets_status` and the
problems (never a secret).
