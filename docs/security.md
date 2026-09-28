# Security notes

## Secrets

Two values are secrets: the **Hub PIN** (with the user and domain it
enrolls a device into the organization's Hub and reports posture under that
identity) and the **LLM API key** (billable; a Portal key also identifies the
organization). Treat both like passwords:

- Never commit them. The embedded-settings blocks in the scripts are for a
  private copy uploaded to the MDM only.
- Prefer, in this order: a secret store feeding the script's environment
  (Ansible Vault, CI secrets, Workspace ONE / other script variables), a
  root-only file passed as `EDAMAME_PIN_FILE` / `EDAMAME_LLM_API_KEY_FILE`
  (delete it afterwards), MDM script parameters restricted to a small admin
  group, and last the script body stored in the MDM.
- Rotate the Portal key and re-issue the PIN if a script copy leaks.
- Use a dedicated Hub user per server / CI fleet, not a person's account.

What each MDM exposes:

| Mechanism | Who can read the secret |
|---|---|
| Intune platform / shell script body | Intune admins with script read rights; the script is cached on the device during execution (admin/root-only locations) |
| Intune Win32 app install command | Intune admins; the command line appears in the Intune Management Extension logs on the device |
| Jamf Pro script parameters `$4`-`$11` | Jamf admins with policy read rights; passed on the script's command line, so visible to local `ps` while the script runs |
| ConfigMgr program / deployment type command line | Console users; logged in `AppEnforce.log` on the client |
| Workspace ONE script variables | Console admins; passed as environment variables |
| Ansible Vault | Holders of the vault password; tasks writing secrets use `no_log` |

## Files and permissions

| File | Owner / mode |
|---|---|
| `/etc/edamame_posture.conf` (Linux) | `root:root 0600` |
| `/Library/Application Support/EDAMAME/Provisioning/edamame_posture.conf` (macOS) | `root:wheel 0600` |
| `%ProgramData%\EDAMAME\Provisioning\` (Windows) | ACL: SYSTEM and BUILTIN\Administrators only, inheritance disabled |

The posture conf holds the PIN and the LLM key. Older `edamame-posture`
packages shipped it world-readable, which exposes both to every local
account. The scripts re-apply `0600` (or the ACL) on every run, including
when the content is unchanged; check the mode on hosts configured by hand.

## Process arguments

EDAMAME >= 2.0.2 on macOS and Windows: the scripts register the product's
service (`edamame_posture install-service --conf <file>`). It runs
`edamame_posture service-run --conf <file>`, which reads the PIN and the LLM
key from the root / SYSTEM-only file itself: neither appears in any process's
arguments or environment, nor in the LaunchDaemon plist or the service
definition. The service refuses a configuration file that is not owned by
root or is writable by other users (macOS / Linux).

Older releases, and the Linux packages' wrapper up to 2.0.1, take the PIN only
as `--pin <PIN>`, so while the daemon runs:

- Linux: `/proc/<pid>/cmdline` shows the PIN to every local user unless
  `/proc` is mounted with `hidepid=2`.
- macOS: `ps` shows other users' process arguments, the PIN included.
- Windows: process command lines of SYSTEM processes are readable by
  administrators.

The LLM key never appears in arguments: the service wrapper, the macOS
launcher and the Windows launcher pass it as `EDAMAME_LLM_API_KEY` in the
daemon's environment only. An `EDAMAME_PIN` environment variable and a
`--pin-file` option for `edamame_posture` (and the Linux wrapper exporting the
PIN instead of passing it) are planned for 2.0.2.

## Download verification

| OS | Checks before install |
|---|---|
| macOS | SHA-256 against the release's `SHA256SUMS` (EDAMAME >= 2.0.2; its Sigstore signature is verified too when `cosign` is installed), else the GitHub asset digest (or `EDAMAME_SHA256`); `pkgutil --check-signature` must show "Developer ID Installer: Edamame Technologies (WSL782B48J)" and Apple notarization |
| Windows | SHA-256 against the release's `SHA256SUMS` (EDAMAME >= 2.0.2), else the GitHub asset digest (or `-Sha256`); `Get-AuthenticodeSignature` must be `Valid` with signer `O=EDAMAME TECHNOLOGIES SAS` |
| Linux APT | Repository `Release` signature by key `D1C58B47675E486792DAFBAE42A2002B57F1A203` (fingerprint checked before the key is trusted) |
| Linux APK | Package signatures by the repository key (key file SHA-256 pinned) |

The GitHub API is rate-limited (60 unauthenticated requests per hour per
public IP). From 2.0.2 the scripts read `SHA256SUMS` from the release
download URL instead, which is not rate-limited the same way; for older
releases, fleets behind one NAT should pin `EDAMAME_VERSION` +
`EDAMAME_SHA256` (read the digest once from the release page or
`gh release view --json assets`) or pass `EDAMAME_GITHUB_TOKEN`.

Checking the `SHA256SUMS` signature (`cosign verify-blob`) and the build
provenance (`gh attestation verify`) is best done once, centrally, before a
version is approved for the fleet; see
[distribution.md](distribution.md#verifying-downloads-edamame--202) for the
exact commands. Endpoints then only need the pinned SHA-256 and the platform
code signature.

## Observer independence

Configuration is an operator action. The Hub enrollment, the LLM
configuration and the protection switch are set by root / SYSTEM scripts
here, never through the MCP interface an AI agent on the host can reach:
EDAMAME keeps protection on/off and dismissals operator-only so a compromised
agent cannot switch off the monitoring that watches it.
