# Mosyle (Business / Fuse / Manager)

Mosyle deploys PKGs, custom profiles and **Custom Commands** (shell scripts
run as root). Screen names differ between Mosyle editions; the pattern is
"custom script + PKG + custom profile".

## Profile

**Management > Custom Profiles**: upload
[profiles/macos/edamame-pppc-login-items.mobileconfig](../../profiles/macos/edamame-pppc-login-items.mobileconfig).

## Posture (scenario A)

**Management > Custom Commands > Add**:

- Code: a **private copy** of `scripts/macos/install-edamame-posture.sh`
  with the embedded-settings block filled in.
- Execution settings: run **once** (or **every check-in** / daily for drift
  remediation; unchanged runs are no-ops).
- Restrict access to the command; its body holds the PIN and the key.

## App (scenario B)

**Management > Install PKG** (or your edition's custom app / PKG
deployment): upload `edamame-macos-<ver>.pkg`, or run
`scripts/macos/install-edamame-app.sh` as a Custom Command.

With EDAMAME >= 2.0.2, a Custom Profile built from
[edamame-managed-settings.mobileconfig](../../profiles/macos/edamame-managed-settings.mobileconfig)
enrolls the app; see [app-configuration.md](../app-configuration.md) for the
secrets file. Earlier versions: users enroll in the app.
