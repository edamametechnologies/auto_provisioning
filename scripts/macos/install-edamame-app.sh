#!/bin/bash
# EDAMAME Security app + EDAMAME Helper -- macOS silent install for MDM.
#
# Downloads the signed and notarized all-in-one PKG (app + helper) from the
# edamame_security GitHub release, verifies its SHA-256 against the digest
# GitHub publishes for the asset (or EDAMAME_SHA256) and its Developer ID
# Installer signature (Team ID WSL782B48J), and installs it with
# `installer -pkg ... -target /`.
#
# The current app has no managed configuration: Hub enrollment, the LLM
# provider and the protection switch are set by the user in the app (see
# docs/app-configuration.md). Deploy profiles/macos/edamame-pppc-login-items.mobileconfig
# first so the helper gets Full Disk Access without a user prompt.
#
# Idempotent: nothing is downloaded when the app and the helper are already at
# the requested version.
#
# Parameters (environment variables, or Jamf parameters $4 version, $5 SHA-256):
#   EDAMAME_ACTION        install (default) | uninstall
#   EDAMAME_VERSION       latest (default) or an exact version, e.g. 2.0.1
#   EDAMAME_SHA256        expected SHA-256 of the PKG (skips the GitHub API)
#   EDAMAME_GITHUB_TOKEN  optional token for the GitHub API rate limit
#   EDAMAME_LOG_FILE      default /Library/Logs/EDAMAME/provisioning.log
#
# Exit codes: 0 ok, 1 unexpected error, 2 invalid parameters, 3 unsupported
# platform, 4 download failed, 5 integrity check failed, 6 install failed.

set -euo pipefail
umask 077

REPO="edamametechnologies/edamame_security"
TEAM_ID="WSL782B48J"
PKG_SIGNER="Developer ID Installer: Edamame Technologies (${TEAM_ID})"
APP="/Applications/EDAMAME Security.app"
HELPER="/Library/Application Support/EDAMAME/EDAMAME-Helper/edamame_helper.app"
APP_UNINSTALLER="/Library/Application Support/EDAMAME/EDAMAME-Security/uninstall.sh"
HELPER_UNINSTALLER="/Library/Application Support/EDAMAME/EDAMAME-Helper/uninstall.sh"
LOG_FILE="${EDAMAME_LOG_FILE:-/Library/Logs/EDAMAME/provisioning.log}"
TMP_DIR=""

log() {
    local msg
    msg="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [edamame-app] $*"
    printf '%s\n' "$msg" >&2
    printf '%s\n' "$msg" >>"$LOG_FILE" 2>/dev/null || true
}
die() {
    local code="$1"
    shift
    log "ERROR: $*"
    exit "$code"
}
# shellcheck disable=SC2329  # invoked through trap
cleanup() { if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi; }
trap cleanup EXIT

if [ "$#" -ge 3 ] && [ "${1:0:1}" = "/" ]; then
    # Jamf Pro: $1 mount point, $2 computer name, $3 user name.
    if [ -n "${4:-}" ]; then EDAMAME_VERSION="$4"; fi
    if [ -n "${5:-}" ]; then EDAMAME_SHA256="$5"; fi
fi
ACTION="${EDAMAME_ACTION:-install}"
P_VERSION="${EDAMAME_VERSION:-latest}"
P_SHA256="$(printf '%s' "${EDAMAME_SHA256:-}" | tr 'A-F' 'a-f')"

bundle_version() {
    if [ -f "$1/Contents/Info.plist" ]; then
        /usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
    fi
}

release_field() {
    /usr/bin/osascript -l JavaScript - "$1" "$2" <<'JXA'
function run(argv) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  var r = JSON.parse(s);
  var d = "";
  (r.assets || []).forEach(function (a) { if (a.name === argv[1]) { d = a.digest || ""; } });
  return (r.tag_name || "") + " " + d;
}
JXA
}

resolve_version_and_digest() {
    if [ -n "$P_SHA256" ]; then
        VERSION="$P_VERSION"
        EXPECTED_SHA256="$P_SHA256"
        return 0
    fi
    local path json auth=() out digest tag
    if [ "$P_VERSION" = latest ]; then path=latest; else path="tags/v${P_VERSION}"; fi
    if [ -n "${EDAMAME_GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer ${EDAMAME_GITHUB_TOKEN}"); fi
    json="$TMP_DIR/release.json"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 -H 'Accept: application/vnd.github+json' \
        "${auth[@]+"${auth[@]}"}" -o "$json" "https://api.github.com/repos/${REPO}/releases/${path}" ||
        die 4 "GitHub API request failed for ${REPO} release ${path} (rate limit? set EDAMAME_GITHUB_TOKEN, or pin EDAMAME_VERSION + EDAMAME_SHA256)"
    tag="$(release_field "$json" "__none__" | awk '{print $1}')"
    VERSION="${tag#v}"
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 4 "could not read the release version from the GitHub API"
    out="$(release_field "$json" "edamame-macos-${VERSION}.pkg")"
    digest="${out#* }"
    [[ "$digest" == sha256:* ]] || die 5 "GitHub publishes no SHA-256 digest for edamame-macos-${VERSION}.pkg; pass EDAMAME_SHA256"
    EXPECTED_SHA256="${digest#sha256:}"
}

[ "$(uname -s)" = Darwin ] || die 3 "this script is for macOS"
[ "$(id -u)" -eq 0 ] || die 2 "run as root"
case "$ACTION" in install | uninstall) ;; *) die 2 "EDAMAME_ACTION must be install or uninstall" ;; esac
[[ "$P_VERSION" == latest || "$P_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 2 "EDAMAME_VERSION must be 'latest' or a version such as 2.0.1"
[[ -z "$P_SHA256" || "$P_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 2 "EDAMAME_SHA256 must be 64 hex characters"
if [ -n "$P_SHA256" ] && [ "$P_VERSION" = latest ]; then die 2 "EDAMAME_SHA256 needs an exact EDAMAME_VERSION"; fi
mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE" && chmod 0640 "$LOG_FILE" || LOG_FILE=/dev/null

if [ "$ACTION" = uninstall ]; then
    log "Uninstalling EDAMAME Security and EDAMAME Helper"
    if [ -x "$APP_UNINSTALLER" ] || [ -f "$APP_UNINSTALLER" ]; then
        /bin/bash "$APP_UNINSTALLER" >>"$LOG_FILE" 2>&1 || true
    fi
    if [ -f "$HELPER_UNINSTALLER" ]; then
        /bin/bash "$HELPER_UNINSTALLER" >>"$LOG_FILE" 2>&1 || true
    fi
    log "Uninstall complete (per-user preferences under ~/Library/Containers/com.edamametechnologies.edamame are left in place)"
    exit 0
fi

TMP_DIR="$(mktemp -d /tmp/edamame-provisioning.XXXXXX)"
APP_V="$(bundle_version "$APP")"
HELPER_V="$(bundle_version "$HELPER")"
log "Installed: app=${APP_V:-none} helper=${HELPER_V:-none}; requested: ${P_VERSION}"

if [ "$P_VERSION" != latest ] && [ "$APP_V" = "$P_VERSION" ] && [ "$HELPER_V" = "$P_VERSION" ] && [ -z "$P_SHA256" ]; then
    log "Already at ${P_VERSION}"
    exit 0
fi
resolve_version_and_digest
if [ "$APP_V" = "$VERSION" ] && [ "$HELPER_V" = "$VERSION" ]; then
    log "Already at ${VERSION}"
    exit 0
fi

URL="https://github.com/${REPO}/releases/download/v${VERSION}/edamame-macos-${VERSION}.pkg"
PKG="$TMP_DIR/edamame-macos-${VERSION}.pkg"
log "Downloading ${URL}"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 -o "$PKG" "$URL" || die 4 "download failed: $URL"
GOT="$(/usr/bin/shasum -a 256 "$PKG" | awk '{print $1}')"
[ "$GOT" = "$EXPECTED_SHA256" ] || die 5 "SHA-256 mismatch (got $GOT, expected $EXPECTED_SHA256)"
SIG="$(/usr/sbin/pkgutil --check-signature "$PKG" 2>&1 || true)"
printf '%s\n' "$SIG" | grep -q "1\. ${PKG_SIGNER}" || die 5 "PKG is not signed by ${PKG_SIGNER}"
printf '%s\n' "$SIG" | grep -q "Notarization: trusted by the Apple notary service" || die 5 "PKG is not notarized"
log "Verified SHA-256 ${GOT} and signature ${PKG_SIGNER}"

log "Installing EDAMAME Security ${VERSION}"
/usr/sbin/installer -pkg "$PKG" -target / >>"$LOG_FILE" 2>&1 || die 6 "installer failed (see $LOG_FILE)"
log "Done: app=$(bundle_version "$APP") helper=$(bundle_version "$HELPER")"
exit 0
