# Jamf Pro

## 1. Configuration profile (PPPC + managed login items)

**Computers > Configuration Profiles > Upload**:
[profiles/macos/edamame-pppc-login-items.mobileconfig](../../profiles/macos/edamame-pppc-login-items.mobileconfig).
Scope it to the same computers as the policies below, and deploy it first so
the EDAMAME Helper / Posture get Full Disk Access without a prompt. Remove the
posture entry if you only deploy the app, and vice versa.

## 2. Posture (scenario A)

1. **Settings > Computer management > Scripts > New**: paste
   `scripts/macos/install-edamame-posture.sh`. Under **Options**, label the
   parameters:

   | Parameter | Label |
   |---|---|
   | 4 | Hub user (or user@domain) |
   | 5 | Hub domain |
   | 6 | Hub PIN |
   | 7 | LLM provider (portal, claude, openai, ollama, none) |
   | 8 | LLM API key |
   | 9 | Agentic mode (analyze, auto, disabled) |
   | 10 | Version (latest or 2.0.1) |
   | 11 | Extra, `KEY=VALUE;KEY=VALUE`: `EDAMAME_LLM_MODEL`, `EDAMAME_LLM_BASE_URL`, `EDAMAME_DEVICE_ID`, `EDAMAME_AGENTIC_INTERVAL`, `EDAMAME_SHA256`, `EDAMAME_PIN_FILE`, `EDAMAME_LLM_API_KEY_FILE`, `EDAMAME_ACTION` |

2. **Computers > Policies > New**:
   - General: trigger **Enrollment Complete** and **Recurring Check-in**,
     frequency **Once per computer** (or **Once every day** for drift
     remediation; an unchanged run is a no-op).
   - Scripts: add the script, priority **After**, fill parameters 4-11.
3. Scope to the target smart group.

Jamf passes parameters on the script's command line: local users can see
them with `ps` while the script runs, and Jamf admins who can read the
policy can see them. Limit policy read rights. To keep the PIN and key out
of parameters, deliver them as root-only files (for example a package that
installs `/var/root/edamame_pin`, mode 0600, removed after provisioning) and
pass `EDAMAME_PIN_FILE=/var/root/edamame_pin;EDAMAME_LLM_API_KEY_FILE=...` in
parameter 11.

Upgrade: change parameter 10 (or keep `latest` with a daily policy).
Remove: a policy running the same script with parameter 11 =
`EDAMAME_ACTION=uninstall`.

Extension attribute (Settings > Computer management > Extension attributes,
input type Script):

```sh
#!/bin/sh
p="/Library/Application Support/EDAMAME/EDAMAME-Posture/edamame_posture.app/Contents/Info"
v=$(defaults read "$p" CFBundleShortVersionString 2>/dev/null || echo none)
r=$(launchctl print system/com.edamametechnologies.auto-provisioning.posture 2>/dev/null | awk '/state =/{print $3; exit}')
echo "<result>${v} ${r:-not-loaded}</result>"
```

## 3. App (scenario B)

Either:

- **Package**: download `edamame-macos-<ver>.pkg` from the
  [edamame_security release](https://github.com/edamametechnologies/edamame_security/releases),
  upload it in **Settings > Computer management > Packages**, add it to a
  policy (Packages payload, Action **Install**). Or
- **Script**: add `scripts/macos/install-edamame-app.sh` to a policy
  (parameter 4 = version, parameter 5 = SHA-256 optional).

The PKG installs the app and the helper and relaunches the app for the
console user. Users then enroll in the app. Extension attribute:

```sh
#!/bin/sh
v=$(defaults read "/Applications/EDAMAME Security.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo none)
echo "<result>${v}</result>"
```

Proposed later (requires EDAMAME >= 2.1, proposed): upload
[PROPOSED-edamame-managed-settings.mobileconfig](../../profiles/macos/PROPOSED-edamame-managed-settings.mobileconfig)
as a configuration profile (Application & Custom Settings); `HubEmail` =
`$EMAIL` uses Jamf's payload variable for the assigned user's email.
