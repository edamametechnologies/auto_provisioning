#!/bin/bash
# EDAMAME Posture -- macOS provisioning script for MDM (Jamf, Intune, Kandji,
# Mosyle, Workspace ONE, or any tool that runs a script as root).
#
# 1. Downloads the signed and notarized EDAMAME Posture PKG from the GitHub
#    release, verifies its SHA-256 against the digest GitHub publishes for the
#    asset (or EDAMAME_SHA256) and its Developer ID Installer signature
#    (Team ID WSL782B48J), and installs it.
# 2. Writes /Library/Application Support/EDAMAME/Provisioning/edamame_posture.conf
#    (root:wheel, 0600) holding the Hub enrollment and the LLM configuration.
# 3. Installs a LaunchDaemon that starts `edamame_posture foreground-start`
#    from that file at boot and keeps it running. (The posture PKG itself
#    installs no service; see docs/configuration-reference.md.)
#
# Idempotent: nothing is downloaded when the requested version is installed,
# and the daemon restarts only when the version or the configuration changed.
# Parameters not supplied keep their current value in the configuration file.
#
# Parameters (environment variables, or Jamf script parameters -- see below):
#   EDAMAME_ACTION           install (default) | uninstall
#   EDAMAME_USER             EDAMAME Hub user ("user@domain" is split)
#   EDAMAME_DOMAIN           EDAMAME Hub domain
#   EDAMAME_PIN              EDAMAME Hub PIN (digits)            [secret]
#   EDAMAME_PIN_FILE         file holding the PIN (alternative)  [secret]
#   EDAMAME_DEVICE_ID        optional device id suffix
#   EDAMAME_LLM_PROVIDER     portal | claude | openai | ollama | none
#   EDAMAME_LLM_API_KEY      Portal API key or provider key      [secret]
#   EDAMAME_LLM_API_KEY_FILE file holding the key (alternative)  [secret]
#   EDAMAME_LLM_MODEL        model (claude / openai / ollama)
#   EDAMAME_LLM_BASE_URL     Ollama URL, or an API base URL for claude / openai
#   EDAMAME_AGENTIC_MODE     analyze | auto | disabled (default: analyze when a
#                            provider is set, otherwise unchanged)
#   EDAMAME_AGENTIC_INTERVAL seconds between Assistant runs (default 3600)
#   EDAMAME_VERSION          latest (default) or an exact version, e.g. 2.0.1
#   EDAMAME_SHA256           expected SHA-256 of the PKG (skips the GitHub API)
#   EDAMAME_GITHUB_TOKEN     optional token for the GitHub API rate limit
#   EDAMAME_LOG_FILE         default /Library/Logs/EDAMAME/provisioning.log
#
# Jamf Pro script parameters (used when $1 is a mount point, as Jamf passes it):
#   $4 user  $5 domain  $6 PIN  $7 LLM provider  $8 LLM API key
#   $9 agentic mode  $10 version  $11 extra "KEY=VALUE;KEY=VALUE" for
#   EDAMAME_LLM_MODEL, EDAMAME_LLM_BASE_URL, EDAMAME_DEVICE_ID,
#   EDAMAME_AGENTIC_INTERVAL, EDAMAME_SHA256, EDAMAME_PIN_FILE,
#   EDAMAME_LLM_API_KEY_FILE, EDAMAME_ACTION
#
# Exit codes: 0 ok, 1 unexpected error, 2 invalid parameters, 3 unsupported
# platform, 4 download failed, 5 integrity check failed, 6 install failed,
# 7 configuration failed, 8 daemon did not start.

set -euo pipefail
umask 077

REPO="edamametechnologies/edamame_posture_cli"
TEAM_ID="WSL782B48J"
PKG_SIGNER="Developer ID Installer: Edamame Technologies (${TEAM_ID})"
BUNDLE="/Library/Application Support/EDAMAME/EDAMAME-Posture/edamame_posture.app"
BINARY="${BUNDLE}/Contents/MacOS/edamame_posture"
PROV_DIR="/Library/Application Support/EDAMAME/Provisioning"
CONF="${PROV_DIR}/edamame_posture.conf"
LAUNCHER="${PROV_DIR}/edamame_posture_launcher.sh"
STATE_DIR="${PROV_DIR}/state"
LABEL="com.edamametechnologies.auto-provisioning.posture"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
DAEMON_LOG="/Library/Logs/EDAMAME/edamame_posture_daemon.log"
LOG_FILE="${EDAMAME_LOG_FILE:-/Library/Logs/EDAMAME/provisioning.log}"
TMP_DIR=""

log() {
    local msg
    msg="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [edamame-posture] $*"
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
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
if [ "$#" -ge 3 ] && [ "${1:0:1}" = "/" ]; then
    # Jamf Pro: $1 mount point, $2 computer name, $3 user name.
    [ -n "${4:-}" ] && EDAMAME_USER="$4"
    [ -n "${5:-}" ] && EDAMAME_DOMAIN="$5"
    [ -n "${6:-}" ] && EDAMAME_PIN="$6"
    [ -n "${7:-}" ] && EDAMAME_LLM_PROVIDER="$7"
    [ -n "${8:-}" ] && EDAMAME_LLM_API_KEY="$8"
    [ -n "${9:-}" ] && EDAMAME_AGENTIC_MODE="$9"
    [ -n "${10:-}" ] && EDAMAME_VERSION="${10}"
    if [ -n "${11:-}" ]; then
        IFS=';' read -r -a _extra <<<"${11}"
        for _kv in "${_extra[@]}"; do
            case "$_kv" in
                EDAMAME_LLM_MODEL=* | EDAMAME_LLM_BASE_URL=* | EDAMAME_DEVICE_ID=* | EDAMAME_AGENTIC_INTERVAL=* | \
                    EDAMAME_SHA256=* | EDAMAME_PIN_FILE=* | EDAMAME_LLM_API_KEY_FILE=* | EDAMAME_ACTION=*)
                    export "${_kv?}"
                    ;;
                "") ;;
                *) echo "Ignoring unsupported extra parameter ${_kv%%=*}" >&2 ;;
            esac
        done
    fi
fi

# ---- Embedded settings -------------------------------------------------------
# For MDMs that cannot pass environment variables (e.g. Intune shell scripts):
# fill values in a PRIVATE copy, e.g. : "${EDAMAME_USER:=alice}". Never commit
# a copy holding secrets. The environment (or a Jamf parameter) takes precedence.
: "${EDAMAME_USER:=}"
: "${EDAMAME_DOMAIN:=}"
: "${EDAMAME_PIN:=}"
: "${EDAMAME_DEVICE_ID:=}"
: "${EDAMAME_LLM_PROVIDER:=}"
: "${EDAMAME_LLM_API_KEY:=}"
: "${EDAMAME_LLM_MODEL:=}"
: "${EDAMAME_LLM_BASE_URL:=}"
: "${EDAMAME_AGENTIC_MODE:=}"
: "${EDAMAME_VERSION:=}"
# -----------------------------------------------------------------------------

ACTION="${EDAMAME_ACTION:-install}"
P_USER="${EDAMAME_USER:-}"
P_DOMAIN="${EDAMAME_DOMAIN:-}"
P_PIN="${EDAMAME_PIN:-}"
P_DEVICE_ID="${EDAMAME_DEVICE_ID:-}"
P_PROVIDER="${EDAMAME_LLM_PROVIDER:-}"
P_KEY="${EDAMAME_LLM_API_KEY:-}"
P_MODEL="${EDAMAME_LLM_MODEL:-}"
P_BASE_URL="${EDAMAME_LLM_BASE_URL:-}"
P_MODE="${EDAMAME_AGENTIC_MODE:-}"
P_INTERVAL="${EDAMAME_AGENTIC_INTERVAL:-}"
P_VERSION="${EDAMAME_VERSION:-latest}"
P_SHA256="$(printf '%s' "${EDAMAME_SHA256:-}" | tr 'A-F' 'a-f')"

read_secret_file() {
    [ -r "$1" ] || die 2 "secret file $1 is not readable"
    head -n 1 "$1" | tr -d '\r' | sed 's/[[:space:]]*$//'
}
if [ -z "$P_PIN" ] && [ -n "${EDAMAME_PIN_FILE:-}" ]; then P_PIN="$(read_secret_file "$EDAMAME_PIN_FILE")"; fi
if [ -z "$P_KEY" ] && [ -n "${EDAMAME_LLM_API_KEY_FILE:-}" ]; then P_KEY="$(read_secret_file "$EDAMAME_LLM_API_KEY_FILE")"; fi

# ---------------------------------------------------------------------------
# Configuration file (same line format as /etc/edamame_posture.conf on Linux)
# ---------------------------------------------------------------------------
conf_get() {
    [ -f "$CONF" ] || return 0
    awk -v key="$1" '
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (index(line, key ":") != 1) next
      v = substr(line, length(key) + 2)
      sub(/^[ \t]+/, "", v)
      if (substr(v, 1, 1) == "\"") {
        out = ""; i = 2; n = length(v)
        while (i <= n) {
          c = substr(v, i, 1)
          if (c == "\\" && i < n) { out = out substr(v, i + 1, 1); i += 2; continue }
          if (c == "\"") break
          out = out c; i++
        }
        v = out
      }
      print v
      exit
    }' "$CONF"
}

yaml_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
kv() { printf '%s: "%s"\n' "$1" "$(yaml_escape "$2")"; }

validate() {
    case "$ACTION" in install | uninstall) ;; *) die 2 "EDAMAME_ACTION must be install or uninstall" ;; esac
    if [[ "$P_USER" == *@* ]]; then
        [ -z "$P_DOMAIN" ] || die 2 "EDAMAME_USER must not contain '@' when EDAMAME_DOMAIN is set"
        P_DOMAIN="${P_USER#*@}"
        P_USER="${P_USER%%@*}"
    fi
    if [ -n "$P_USER$P_DOMAIN$P_PIN" ]; then
        { [ -n "$P_USER" ] && [ -n "$P_DOMAIN" ] && [ -n "$P_PIN" ]; } ||
            die 2 "EDAMAME_USER, EDAMAME_DOMAIN and EDAMAME_PIN must be set together"
    fi
    [[ -z "$P_PIN" || "$P_PIN" =~ ^[0-9]+$ ]] || die 2 "EDAMAME_PIN must contain digits only"
    [[ -z "$P_DOMAIN" || "$P_DOMAIN" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die 2 "EDAMAME_DOMAIN is not a fully qualified domain name"
    case "$P_PROVIDER" in
        "" | claude | openai | ollama | none) ;;
        portal | edamame) P_PROVIDER=edamame ;;
        *) die 2 "EDAMAME_LLM_PROVIDER must be portal, claude, openai, ollama or none" ;;
    esac
    case "$P_MODE" in "" | analyze | auto | disabled) ;; *) die 2 "EDAMAME_AGENTIC_MODE must be analyze, auto or disabled" ;; esac
    [[ -z "$P_INTERVAL" || "$P_INTERVAL" =~ ^[0-9]+$ ]] || die 2 "EDAMAME_AGENTIC_INTERVAL must be a number of seconds"
    [[ "$P_VERSION" == latest || "$P_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 2 "EDAMAME_VERSION must be 'latest' or a version such as 2.0.1"
    [[ -z "$P_SHA256" || "$P_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 2 "EDAMAME_SHA256 must be 64 hex characters"
    if [ -n "$P_SHA256" ] && [ "$P_VERSION" = latest ]; then
        die 2 "EDAMAME_SHA256 needs an exact EDAMAME_VERSION"
    fi
    local v
    for v in "$P_USER" "$P_DOMAIN" "$P_PIN" "$P_DEVICE_ID" "$P_KEY" "$P_MODEL" "$P_BASE_URL"; do
        [[ "$v" != *$'\n'* ]] || die 2 "parameter values must be single-line"
    done
    case "$P_PROVIDER" in
        edamame | claude | openai)
            if [ -z "$P_KEY" ] && [ -z "$(conf_get llm_api_key)" ]; then
                die 2 "EDAMAME_LLM_PROVIDER=$P_PROVIDER needs EDAMAME_LLM_API_KEY (or EDAMAME_LLM_API_KEY_FILE)"
            fi
            ;;
        ollama)
            if [ -z "$P_BASE_URL" ] && [ -z "$(conf_get llm_base_url)" ]; then
                die 2 "EDAMAME_LLM_PROVIDER=ollama needs EDAMAME_LLM_BASE_URL (e.g. http://localhost:11434)"
            fi
            ;;
    esac
}

render_conf() {
    local c_user c_domain c_pin c_device c_mode c_provider c_interval c_key c_model c_url
    c_user="$(conf_get edamame_user)"
    c_domain="$(conf_get edamame_domain)"
    c_pin="$(conf_get edamame_pin)"
    c_device="$(conf_get edamame_device_id)"
    c_mode="$(conf_get agentic_mode)"
    c_provider="$(conf_get agentic_provider)"
    c_interval="$(conf_get agentic_interval)"
    c_key="$(conf_get llm_api_key)"
    c_model="$(conf_get llm_model)"
    c_url="$(conf_get llm_base_url)"

    if [ -n "$P_USER" ]; then c_user="$P_USER"; c_domain="$P_DOMAIN"; c_pin="$P_PIN"; fi
    if [ -n "$P_DEVICE_ID" ]; then c_device="$P_DEVICE_ID"; fi
    if [ -n "$P_INTERVAL" ]; then c_interval="$P_INTERVAL"; fi
    if [ -n "$P_PROVIDER" ]; then
        if [ "$P_PROVIDER" != "$c_provider" ]; then
            # A different provider: never reuse the previous provider's key, model or URL.
            c_key=""; c_model=""; c_url=""
        fi
        c_provider="$P_PROVIDER"
        if [ -n "$P_KEY" ]; then c_key="$P_KEY"; fi
        if [ -n "$P_MODEL" ]; then c_model="$P_MODEL"; fi
        if [ -n "$P_BASE_URL" ]; then c_url="$P_BASE_URL"; fi
        if [ "$P_PROVIDER" = none ]; then c_provider=""; c_key=""; c_model=""; c_url=""; fi
        if [ "$P_PROVIDER" = ollama ]; then c_key=""; fi
        if [ "$P_PROVIDER" = edamame ] && [ -n "$c_model" ]; then
            log "WARNING: EDAMAME_LLM_MODEL is ignored for the EDAMAME Portal provider"
            c_model=""
        fi
    fi
    if [ -n "$P_MODE" ]; then
        c_mode="$P_MODE"
    elif [ "$P_PROVIDER" = none ]; then
        c_mode=disabled
    elif [ -n "$P_PROVIDER" ]; then
        c_mode=analyze
    fi
    c_mode="${c_mode:-disabled}"
    c_interval="${c_interval:-3600}"
    if [ "$c_mode" != disabled ] && [ -z "$c_provider" ]; then
        die 2 "agentic mode '$c_mode' needs an LLM provider: set EDAMAME_LLM_PROVIDER and its key"
    fi

    echo "# EDAMAME Posture configuration, written by the EDAMAME auto_provisioning macOS script."
    echo "# Read by ${LAUNCHER}. Holds the Hub PIN and the LLM key: root:wheel, mode 0600."
    kv edamame_user "$c_user"
    kv edamame_domain "$c_domain"
    kv edamame_pin "$c_pin"
    kv edamame_device_id "$c_device"
    kv agentic_mode "$c_mode"
    kv agentic_provider "$c_provider"
    kv agentic_interval "$c_interval"
    kv llm_api_key "$c_key"
    kv llm_model "$c_model"
    kv llm_base_url "$c_url"
}

# install_file <tmp> <dest> <mode>: sets CHANGED=true when the content differs.
install_file() {
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        chmod "$3" "$2"
        chown root:wheel "$2"
        return 0
    fi
    chmod "$3" "$1"
    chown root:wheel "$1"
    mv -f "$1" "$2"
    CHANGED=true
}

render_launcher() {
    cat <<'LAUNCHER_EOF'
#!/bin/sh
# Installed by the EDAMAME auto_provisioning macOS script. Started by launchd
# (com.edamametechnologies.auto-provisioning.posture): reads the provisioning
# configuration and runs edamame_posture in the foreground. The LLM key is
# passed through the environment, never on the command line.
set -eu
CONF="/Library/Application Support/EDAMAME/Provisioning/edamame_posture.conf"
BIN="/Library/Application Support/EDAMAME/EDAMAME-Posture/edamame_posture.app/Contents/MacOS/edamame_posture"
STATE="/Library/Application Support/EDAMAME/Provisioning/state"

get() {
  awk -v key="$1" '
  {
    line = $0; sub(/^[ \t]+/, "", line)
    if (index(line, key ":") != 1) next
    v = substr(line, length(key) + 2); sub(/^[ \t]+/, "", v)
    if (substr(v, 1, 1) == "\"") {
      out = ""; i = 2; n = length(v)
      while (i <= n) {
        c = substr(v, i, 1)
        if (c == "\\" && i < n) { out = out substr(v, i + 1, 1); i += 2; continue }
        if (c == "\"") break
        out = out c; i++
      }
      v = out
    }
    print v; exit
  }' "$CONF"
}

[ -f "$CONF" ] || { echo "missing $CONF"; exit 78; }
[ -x "$BIN" ] || { echo "missing $BIN"; exit 78; }

user="$(get edamame_user)"; domain="$(get edamame_domain)"; pin="$(get edamame_pin)"
device_id="$(get edamame_device_id)"
mode="$(get agentic_mode)"; provider="$(get agentic_provider)"; interval="$(get agentic_interval)"
key="$(get llm_api_key)"; model="$(get llm_model)"; url="$(get llm_base_url)"

# No -v: edamame_posture then writes its own daily log files under
# /var/log/edamame/ instead of flooding the launchd stdout file.
set -- foreground-start
if [ -n "$user" ] && [ -n "$domain" ] && [ -n "$pin" ]; then
  # edamame_posture takes the PIN only as an argument today.
  set -- "$@" --user "$user" --domain "$domain" --pin "$pin"
  if [ -n "$device_id" ]; then set -- "$@" --device-id "$device_id"; fi
  echo "Starting in connected mode: $user@$domain"
else
  echo "Starting in disconnected mode"
fi

if [ "${mode:-disabled}" != disabled ] && [ -n "$provider" ]; then
  if [ -n "$key" ]; then export EDAMAME_LLM_API_KEY="$key"; fi
  if [ -n "$model" ]; then export EDAMAME_LLM_MODEL="$model"; fi
  if [ -n "$url" ]; then export EDAMAME_LLM_BASE_URL="$url"; fi
  set -- "$@" --agentic-mode "$mode" --agentic-provider "$provider" --agentic-interval "${interval:-3600}"
  echo "AI assistant: mode=$mode provider=$provider"
fi

mkdir -p "$STATE"
cd "$STATE"
exec "$BIN" "$@"
LAUNCHER_EOF
}

render_plist() {
    cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>${LAUNCHER}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>WorkingDirectory</key>
    <string>${STATE_DIR}</string>
    <key>StandardOutPath</key>
    <string>${DAEMON_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${DAEMON_LOG}</string>
</dict>
</plist>
PLIST_EOF
}

# ---------------------------------------------------------------------------
# Download and verification
# ---------------------------------------------------------------------------
installed_version() {
    if [ -f "${BUNDLE}/Contents/Info.plist" ]; then
        /usr/bin/defaults read "${BUNDLE}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
    fi
}

github_release_json() {
    # $1 = release path (latest | tags/vX.Y.Z), $2 = output file
    local auth=()
    if [ -n "${EDAMAME_GITHUB_TOKEN:-}" ]; then
        auth=(-H "Authorization: Bearer ${EDAMAME_GITHUB_TOKEN}")
    fi
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 \
        -H 'Accept: application/vnd.github+json' "${auth[@]+"${auth[@]}"}" \
        -o "$2" "https://api.github.com/repos/${REPO}/releases/$1"
}

# release_field <json> <asset name>: prints "<tag> <digest>".
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
    # Sets VERSION and EXPECTED_SHA256.
    if [ -n "$P_SHA256" ]; then
        VERSION="$P_VERSION"
        EXPECTED_SHA256="$P_SHA256"
        return 0
    fi
    local path json out tag digest
    json="$TMP_DIR/release.json"
    if [ "$P_VERSION" = latest ]; then path=latest; else path="tags/v${P_VERSION}"; fi
    github_release_json "$path" "$json" || die 4 "GitHub API request failed for ${REPO} release ${path} (rate limit? set EDAMAME_GITHUB_TOKEN, or pin EDAMAME_VERSION + EDAMAME_SHA256)"
    tag="$(release_field "$json" "__none__" | awk '{print $1}')"
    VERSION="${tag#v}"
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die 4 "could not read the release version from the GitHub API"
    out="$(release_field "$json" "edamame-posture-macos-${VERSION}.pkg")"
    digest="${out#* }"
    [[ "$digest" == sha256:* ]] || die 5 "GitHub publishes no SHA-256 digest for edamame-posture-macos-${VERSION}.pkg; pass EDAMAME_SHA256"
    EXPECTED_SHA256="${digest#sha256:}"
}

download_and_verify() {
    local url="https://github.com/${REPO}/releases/download/v${VERSION}/edamame-posture-macos-${VERSION}.pkg"
    PKG="$TMP_DIR/edamame-posture-macos-${VERSION}.pkg"
    log "Downloading ${url}"
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 -o "$PKG" "$url" || die 4 "download failed: $url"
    local got
    got="$(/usr/bin/shasum -a 256 "$PKG" | awk '{print $1}')"
    [ "$got" = "$EXPECTED_SHA256" ] || die 5 "SHA-256 mismatch for $(basename "$PKG") (got $got, expected $EXPECTED_SHA256)"
    log "SHA-256 verified: $got"
    local sig
    sig="$(/usr/sbin/pkgutil --check-signature "$PKG" 2>&1 || true)"
    printf '%s\n' "$sig" | grep -q "1\. ${PKG_SIGNER}" || die 5 "PKG is not signed by ${PKG_SIGNER}"
    printf '%s\n' "$sig" | grep -q "Notarization: trusted by the Apple notary service" || die 5 "PKG is not notarized"
    log "Signature verified: ${PKG_SIGNER}, notarized"
}

# ---------------------------------------------------------------------------
# Daemon control
# ---------------------------------------------------------------------------
# run_with_timeout <seconds> <command...>
run_with_timeout() {
    local secs="$1"
    shift
    "$@" >>"$LOG_FILE" 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$secs" ]; then
            kill "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        i=$((i + 1))
    done
    wait "$pid"
}

stop_daemon() {
    /bin/launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
    # A daemon started earlier with `edamame_posture start` (install.sh,
    # manual use) would hold the same RPC endpoint: stop it too.
    if [ -x "$BINARY" ] && pgrep -f "edamame_posture (start|background-start|foreground-start)" >/dev/null 2>&1; then
        run_with_timeout 30 "$BINARY" stop || true
        sleep 2
        pkill -f "edamame_posture (start|background-start|foreground-start)" 2>/dev/null || true
    fi
}

start_daemon() {
    /bin/launchctl bootstrap system "$PLIST" >>"$LOG_FILE" 2>&1 || die 8 "launchctl bootstrap failed"
    /bin/launchctl enable "system/${LABEL}" >/dev/null 2>&1 || true
    local i=0
    while [ "$i" -lt 30 ]; do
        if /bin/launchctl print "system/${LABEL}" 2>/dev/null | grep -q "state = running"; then
            log "Daemon running (${LABEL})"
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    die 8 "daemon is not running; see ${DAEMON_LOG}"
}

uninstall() {
    log "Uninstalling EDAMAME Posture"
    stop_daemon
    rm -f "$PLIST"
    rm -rf "$PROV_DIR"
    rm -rf "$BUNDLE"
    rm -f /usr/local/bin/edamame_posture
    /usr/sbin/pkgutil --pkgs | grep -i 'edamame-posture' | while read -r id; do
        /usr/sbin/pkgutil --forget "$id" >/dev/null 2>&1 || true
    done
    log "Uninstall complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# Test hook: `EDAMAME_PROVISIONING_LIB=1 source install-edamame-posture.sh`.
if [ "${EDAMAME_PROVISIONING_LIB:-}" = 1 ]; then
    CONF="${EDAMAME_TEST_CONF:-$CONF}"
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

[ "$(uname -s)" = Darwin ] || die 3 "this script is for macOS"
[ "$(id -u)" -eq 0 ] || die 2 "run as root"
mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE" && chmod 0640 "$LOG_FILE" || LOG_FILE=/dev/null

validate
if [ "$ACTION" = uninstall ]; then
    uninstall
    exit 0
fi

log "Provisioning EDAMAME Posture (version: ${P_VERSION}, provider: ${P_PROVIDER:-unchanged}, hub: $([ -n "$P_USER" ] && echo "${P_USER}@${P_DOMAIN}" || echo unchanged), pin: $([ -n "$P_PIN" ] && echo set || echo unchanged), llm key: $([ -n "$P_KEY" ] && echo set || echo unchanged))"
TMP_DIR="$(mktemp -d /tmp/edamame-provisioning.XXXXXX)"

CURRENT="$(installed_version)"
PKG_CHANGED=false
if [ "$P_VERSION" != latest ] && [ "$CURRENT" = "$P_VERSION" ] && [ -z "$P_SHA256" ]; then
    log "EDAMAME Posture ${CURRENT} already installed"
else
    resolve_version_and_digest
    if [ "$CURRENT" = "$VERSION" ]; then
        log "EDAMAME Posture ${CURRENT} already installed"
    else
        download_and_verify
        stop_daemon
        log "Installing EDAMAME Posture ${VERSION} (was: ${CURRENT:-none})"
        /usr/sbin/installer -pkg "$PKG" -target / >>"$LOG_FILE" 2>&1 || die 6 "installer failed (see $LOG_FILE)"
        PKG_CHANGED=true
    fi
fi
[ -x "$BINARY" ] || die 6 "$BINARY is missing after installation"

mkdir -p "$PROV_DIR" "$STATE_DIR" "$(dirname "$DAEMON_LOG")"
chown root:wheel "$PROV_DIR" "$STATE_DIR"
chmod 0755 "$PROV_DIR"
chmod 0700 "$STATE_DIR"

CHANGED=false
render_conf >"$TMP_DIR/conf" || exit $?
install_file "$TMP_DIR/conf" "$CONF" 0600
render_launcher >"$TMP_DIR/launcher"
install_file "$TMP_DIR/launcher" "$LAUNCHER" 0755
render_plist >"$TMP_DIR/plist"
/usr/bin/plutil -lint "$TMP_DIR/plist" >/dev/null || die 7 "generated LaunchDaemon plist is invalid"
install_file "$TMP_DIR/plist" "$PLIST" 0644

if [ "$CHANGED" = true ] || [ "$PKG_CHANGED" = true ] ||
    ! /bin/launchctl print "system/${LABEL}" 2>/dev/null | grep -q "state = running"; then
    stop_daemon
    start_daemon
else
    log "Configuration unchanged; daemon running"
fi

log "Done: EDAMAME Posture $(installed_version), mode=$(conf_get agentic_mode), provider=$(conf_get agentic_provider), hub=$(conf_get edamame_user)@$(conf_get edamame_domain)"
exit 0
