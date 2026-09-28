# Kandji

Kandji runs custom scripts as root and deploys custom apps and profiles.
Library item names below are Kandji's; check Kandji's documentation for
current screens.

## Profile

**Library > Add new > Custom Profile**: upload
[profiles/macos/edamame-pppc-login-items.mobileconfig](../../profiles/macos/edamame-pppc-login-items.mobileconfig)
and assign it to the Blueprint before the apps.

## Posture (scenario A)

**Library > Add new > Custom Script**:

- Execution frequency: **Run once per device**, or **Run every 15 min /
  daily** for drift remediation (an unchanged run is a no-op).
- Script: a **private copy** of `scripts/macos/install-edamame-posture.sh`
  with the embedded-settings block filled in (Kandji does not pass
  parameters). Restrict who can view the Library item.
- Optional remediation pattern: audit script =
  `launchctl print system/com.edamametechnologies.edamame-posture | grep -q "state = running"`
  (EDAMAME >= 2.0.2; older releases:
  `system/com.edamametechnologies.auto-provisioning.posture`),
  remediation script = the private copy.

## App (scenario B)

**Library > Add new > Custom App**: upload `edamame-macos-<ver>.pkg`
(install type **Package**, enforcement **Install once** or **Audit and
enforce** with an audit script checking
`/Applications/EDAMAME Security.app`'s `CFBundleShortVersionString`).
Or use a Custom Script with `scripts/macos/install-edamame-app.sh`
(`export EDAMAME_VERSION=2.0.1` in the first lines of a copy).

Users then enroll in the app (managed settings: requires EDAMAME >= 2.1,
proposed; Kandji's profile variables such as `$EMAIL` would fill `HubEmail`).
