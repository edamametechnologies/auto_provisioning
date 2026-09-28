#!/bin/sh
# EDAMAME Posture -- Linux provisioning script for MDM / configuration management.
#
# Installs edamame-posture from the signed EDAMAME package repository (APT on
# Debian/Ubuntu/Raspberry Pi OS, APK on Alpine), writes the service
# configuration /etc/edamame_posture.conf (root:root, mode 0600) and
# (re)starts the edamame_posture service. Optionally installs the
# EDAMAME Security desktop app (edamame-security, amd64 only), which on Linux
# is a GUI for the same edamame_posture service and uses the same
# configuration.
#
# Idempotent: re-running with the same parameters changes nothing and does not
# restart the service. Parameters that are not supplied keep their current
# value in /etc/edamame_posture.conf.
#
# Parameters (environment variables; never pass secrets on a command line):
#   EDAMAME_ACTION           install (default) | uninstall
#   EDAMAME_USER             EDAMAME Hub user (the part before '@'; "user@domain" is split)
#   EDAMAME_DOMAIN           EDAMAME Hub domain
#   EDAMAME_PIN              EDAMAME Hub PIN (digits)            [secret]
#   EDAMAME_PIN_FILE         file holding the PIN (alternative)  [secret]
#   EDAMAME_DEVICE_ID        optional device id suffix
#   EDAMAME_LLM_PROVIDER     portal | claude | openai | ollama | none
#   EDAMAME_LLM_API_KEY      Portal API key or provider key      [secret]
#   EDAMAME_LLM_API_KEY_FILE file holding the key (alternative)  [secret]
#   EDAMAME_LLM_MODEL        model name (claude / openai / ollama)
#   EDAMAME_LLM_BASE_URL     Ollama URL, or an API base URL for claude / openai
#   EDAMAME_AGENTIC_MODE     analyze | auto | disabled (default: analyze when a
#                            provider is set, otherwise unchanged)
#   EDAMAME_AGENTIC_INTERVAL seconds between Assistant runs (default: unchanged, 3600)
#   EDAMAME_VERSION          latest (default) or an exact version, e.g. 2.0.1
#   EDAMAME_INSTALL_APP      true to also install the edamame-security GUI (amd64)
#   EDAMAME_LOG_FILE         default /var/log/edamame-provisioning.log
#
# Exit codes: 0 ok, 1 unexpected error, 2 invalid parameters, 3 unsupported
# platform, 4 download failed, 5 integrity check failed, 6 package install
# failed, 7 configuration failed, 8 service did not start.

set -eu
umask 077

CONF=/etc/edamame_posture.conf
DROPIN_DIR=/etc/systemd/system/edamame_posture.service.d
DROPIN="$DROPIN_DIR/50-edamame-provisioning.conf"
OPENRC_CONFD=/etc/conf.d/edamame_posture
REPO_BASE=https://edamame.s3.eu-west-1.amazonaws.com/repo
APT_KEYRING=/usr/share/keyrings/edamame.gpg
APT_LIST=/etc/apt/sources.list.d/edamame.list
# OpenPGP key that signs the APT repository (published at $REPO_BASE/public.key).
APT_KEY_FPR=D1C58B47675E486792DAFBAE42A2002B57F1A203
APK_REPO="$REPO_BASE/alpine/v3.15/main"
APK_KEY=/etc/apk/keys/edamame.rsa.pub
# SHA-256 of the APK signing key (identical for x86_64 and aarch64).
APK_KEY_SHA256=32bb30b9b83d56a84d65155c7e04095da4a554ec451627dcdd789ac4ede89d7c

LOG_FILE="${EDAMAME_LOG_FILE:-/var/log/edamame-provisioning.log}"
TMP_DIR=""

log() {
    _msg="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [edamame-posture] $*"
    printf '%s\n' "$_msg" >&2
    printf '%s\n' "$_msg" >>"$LOG_FILE" 2>/dev/null || true
}

die() {
    _code="$1"
    shift
    log "ERROR: $*"
    exit "$_code"
}

# shellcheck disable=SC2329  # invoked through trap
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Parameters
# ---------------------------------------------------------------------------
# ---- Embedded settings -------------------------------------------------------
# For MDMs that cannot pass environment variables (e.g. Intune shell scripts):
# fill values in a PRIVATE copy, e.g. : "${EDAMAME_USER:=alice}". Never commit
# a copy holding secrets. The environment takes precedence.
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
P_APP="${EDAMAME_INSTALL_APP:-false}"

read_secret_file() {
    # $1 = path; prints the first line without trailing whitespace.
    [ -r "$1" ] || die 2 "secret file $1 is not readable"
    head -n 1 "$1" | tr -d '\r' | sed 's/[[:space:]]*$//'
}

if [ -z "$P_PIN" ] && [ -n "${EDAMAME_PIN_FILE:-}" ]; then
    P_PIN="$(read_secret_file "$EDAMAME_PIN_FILE")"
fi
if [ -z "$P_KEY" ] && [ -n "${EDAMAME_LLM_API_KEY_FILE:-}" ]; then
    P_KEY="$(read_secret_file "$EDAMAME_LLM_API_KEY_FILE")"
fi

has_newline() {
    case "$1" in
        *'
'*) return 0 ;;
    esac
    return 1
}

validate() {
    case "$ACTION" in install | uninstall) ;; *) die 2 "EDAMAME_ACTION must be install or uninstall" ;; esac

    case "$P_USER" in
        *@*)
            if [ -z "$P_DOMAIN" ]; then
                P_DOMAIN="${P_USER#*@}"
                P_USER="${P_USER%%@*}"
            else
                die 2 "EDAMAME_USER must not contain '@' when EDAMAME_DOMAIN is set"
            fi
            ;;
    esac
    if [ -n "$P_USER$P_DOMAIN$P_PIN" ]; then
        [ -n "$P_USER" ] && [ -n "$P_DOMAIN" ] && [ -n "$P_PIN" ] ||
            die 2 "EDAMAME_USER, EDAMAME_DOMAIN and EDAMAME_PIN must be set together"
    fi
    case "$P_PIN" in *[!0-9]*) die 2 "EDAMAME_PIN must contain digits only" ;; esac
    case "$P_DOMAIN" in
        "") ;;
        *[!A-Za-z0-9.-]* | .* | *. | *..*) die 2 "EDAMAME_DOMAIN is not a valid domain name" ;;
        *.*) ;;
        *) die 2 "EDAMAME_DOMAIN is not a fully qualified domain name" ;;
    esac
    case "$P_PROVIDER" in
        "" | claude | openai | ollama | none) ;;
        portal | edamame) P_PROVIDER=edamame ;;
        *) die 2 "EDAMAME_LLM_PROVIDER must be portal, claude, openai, ollama or none" ;;
    esac
    case "$P_MODE" in "" | analyze | auto | disabled) ;; *) die 2 "EDAMAME_AGENTIC_MODE must be analyze, auto or disabled" ;; esac
    case "$P_INTERVAL" in *[!0-9]*) die 2 "EDAMAME_AGENTIC_INTERVAL must be a number of seconds" ;; esac
    case "$P_VERSION" in
        latest) ;;
        *[!0-9.]* | "") die 2 "EDAMAME_VERSION must be 'latest' or a version such as 2.0.1" ;;
    esac
    case "$P_APP" in true | false) ;; *) die 2 "EDAMAME_INSTALL_APP must be true or false" ;; esac
    for _v in "$P_USER" "$P_DOMAIN" "$P_PIN" "$P_DEVICE_ID" "$P_KEY" "$P_MODEL" "$P_BASE_URL"; do
        if has_newline "$_v"; then
            die 2 "parameter values must be single-line"
        fi
    done
    case "$P_MODEL$P_BASE_URL" in *'"'* | *\\*) die 2 "EDAMAME_LLM_MODEL / EDAMAME_LLM_BASE_URL must not contain quotes or backslashes" ;; esac
    case "$P_PROVIDER" in
        edamame | claude | openai)
            if [ -z "$P_KEY" ] && ! conf_has_slot_for "$P_PROVIDER"; then
                die 2 "EDAMAME_LLM_PROVIDER=$P_PROVIDER needs EDAMAME_LLM_API_KEY (or EDAMAME_LLM_API_KEY_FILE)"
            fi
            ;;
        ollama)
            if [ -z "$P_BASE_URL" ] && ! conf_has_slot_for ollama; then
                die 2 "EDAMAME_LLM_PROVIDER=ollama needs EDAMAME_LLM_BASE_URL (e.g. http://localhost:11434)"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Configuration file helpers (same parser as edamame_posture_daemon.sh)
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
      q = substr(v, 1, 1)
      if (q == "\"") {
        out = ""; i = 2; n = length(v)
        while (i <= n) {
          c = substr(v, i, 1)
          if (c == "\\" && i < n) { out = out substr(v, i + 1, 1); i += 2; continue }
          if (c == "\"") break
          out = out c; i++
        }
        v = out
      } else if (q == "\047") {
        v = substr(v, 2); p = index(v, "\047"); if (p > 0) v = substr(v, 1, p - 1)
      } else {
        sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      }
      print v
      exit
    }' "$CONF"
}

conf_has_slot_for() {
    case "$1" in
        edamame) [ -n "$(conf_get llm_api_key)" ] ;;
        claude) [ -n "$(conf_get claude_api_key)" ] ;;
        openai) [ -n "$(conf_get openai_api_key)" ] ;;
        ollama) [ -n "$(conf_get ollama_base_url)" ] ;;
        *) return 1 ;;
    esac
}

yaml_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# kv <key> <value>: one conf line.
kv() {
    printf '%s: "%s"\n' "$1" "$(yaml_escape "$2")"
}

render_conf() {
    # Carry every key over from the current conf, then apply this run's values.
    c_user="$(conf_get edamame_user)"
    c_domain="$(conf_get edamame_domain)"
    c_pin="$(conf_get edamame_pin)"
    c_device="$(conf_get edamame_device_id)"
    c_mode="$(conf_get agentic_mode)"
    c_provider="$(conf_get agentic_provider)"
    c_interval="$(conf_get agentic_interval)"
    c_llm="$(conf_get llm_api_key)"
    c_claude="$(conf_get claude_api_key)"
    c_openai="$(conf_get openai_api_key)"
    c_ollama="$(conf_get ollama_base_url)"

    if [ -n "$P_USER" ]; then
        c_user="$P_USER"
        c_domain="$P_DOMAIN"
        c_pin="$P_PIN"
    fi
    if [ -n "$P_DEVICE_ID" ]; then c_device="$P_DEVICE_ID"; fi
    if [ -n "$P_INTERVAL" ]; then c_interval="$P_INTERVAL"; fi

    if [ -n "$P_PROVIDER" ]; then
        # An explicit provider owns the credential slots: keep only its own
        # slot so a key for a provider no longer in use does not stay on disk.
        _keep_llm="$c_llm"; _keep_claude="$c_claude"; _keep_openai="$c_openai"; _keep_ollama="$c_ollama"
        c_llm=""; c_claude=""; c_openai=""; c_ollama=""
        case "$P_PROVIDER" in
            edamame) c_llm="${P_KEY:-$_keep_llm}"; c_provider=edamame ;;
            claude) c_claude="${P_KEY:-$_keep_claude}"; c_provider=claude ;;
            openai) c_openai="${P_KEY:-$_keep_openai}"; c_provider=openai ;;
            ollama) c_ollama="${P_BASE_URL:-$_keep_ollama}"; c_provider=ollama ;;
            none) c_provider="" ;;
        esac
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

    if [ "$c_mode" != disabled ] && [ -z "$c_llm$c_claude$c_openai$c_ollama" ]; then
        die 2 "agentic mode '$c_mode' needs an LLM provider: set EDAMAME_LLM_PROVIDER and its key (the service would otherwise start with the Assistant disabled)"
    fi

    cat <<'EOF'
# EDAMAME Posture service configuration.
# Written by the EDAMAME auto_provisioning Linux script. Holds the Hub PIN and
# the LLM credential: keep it root-owned, mode 0600.
EOF
    echo
    kv edamame_user "$c_user"
    kv edamame_domain "$c_domain"
    kv edamame_pin "$c_pin"
    kv edamame_device_id "$c_device"
    echo
    for _k in start_lanscan start_capture fail_on_whitelist fail_on_blacklist fail_on_findings cancel_on_violation include_local_traffic; do
        _v="$(conf_get "$_k")"
        kv "$_k" "${_v:-false}"
    done
    kv whitelist_name "$(conf_get whitelist_name)"
    echo
    kv agentic_mode "$c_mode"
    kv agentic_provider "$c_provider"
    kv agentic_interval "$c_interval"
    kv llm_api_key "$c_llm"
    kv claude_api_key "$c_claude"
    kv openai_api_key "$c_openai"
    kv ollama_base_url "$c_ollama"
    echo
    _np="$(conf_get notification_provider)"
    kv notification_provider "${_np:-auto}"
    for _k in notification_slack_bot_token notification_slack_channel notification_telegram_bot_token \
        notification_telegram_chat_id slack_bot_token slack_actions_channel slack_escalations_channel \
        telegram_bot_token telegram_chat_id; do
        kv "$_k" "$(conf_get "$_k")"
    done
}

# install_file <tmp> <dest> <mode>: sets CHANGED=true when the content differs.
install_file() {
    if [ -f "$2" ] && cmp -s "$1" "$2"; then
        chmod "$3" "$2"
        chown root:root "$2" 2>/dev/null || true
        return 0
    fi
    chmod "$3" "$1"
    chown root:root "$1" 2>/dev/null || true
    mv -f "$1" "$2"
    CHANGED=true
}

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------
fetch() {
    # fetch <url> <dest>
    if command -v curl >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 5 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        return 127
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

# ---------------------------------------------------------------------------
# APT
# ---------------------------------------------------------------------------
apt_setup_repo() {
    export DEBIAN_FRONTEND=noninteractive
    _need=""
    command -v gpg >/dev/null 2>&1 || _need="$_need gnupg"
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _need="$_need curl"
    [ -f /etc/ssl/certs/ca-certificates.crt ] || _need="$_need ca-certificates"
    if [ -n "$_need" ]; then
        log "Installing prerequisites:$_need"
        apt-get update -qq >>"$LOG_FILE" 2>&1 || die 4 "apt-get update failed (see $LOG_FILE)"
        # shellcheck disable=SC2086
        apt-get install -y -qq $_need >>"$LOG_FILE" 2>&1 || die 6 "could not install prerequisites:$_need"
    fi

    fetch "$REPO_BASE/public.key" "$TMP_DIR/public.key" || die 4 "could not download the repository key"
    _fprs="$(gpg --batch --with-colons --show-keys "$TMP_DIR/public.key" 2>/dev/null | awk -F: '$1=="fpr"{print $10}')"
    echo "$_fprs" | grep -qx "$APT_KEY_FPR" || die 5 "repository key fingerprint mismatch (expected $APT_KEY_FPR)"
    gpg --batch --yes --dearmor -o "$TMP_DIR/edamame.gpg" "$TMP_DIR/public.key" || die 5 "could not convert the repository key"
    CHANGED=false
    install_file "$TMP_DIR/edamame.gpg" "$APT_KEYRING" 0644

    _arch="$(dpkg --print-architecture)"
    case "$_arch" in amd64 | arm64 | armhf | i386) ;; *) die 3 "unsupported Debian architecture $_arch" ;; esac
    printf 'deb [arch=%s signed-by=%s] %s stable main\n' "$_arch" "$APT_KEYRING" "$REPO_BASE" >"$TMP_DIR/edamame.list"
    install_file "$TMP_DIR/edamame.list" "$APT_LIST" 0644
    log "Refreshing APT package lists"
    apt-get update -qq >>"$LOG_FILE" 2>&1 || die 4 "apt-get update failed (see $LOG_FILE)"
}

# apt_resolve <package>: prints the package=version spec for P_VERSION.
apt_resolve() {
    if [ "$P_VERSION" = latest ]; then
        printf '%s' "$1"
        return 0
    fi
    _full="$(apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' |
        grep -E "^${P_VERSION}(-|$)" | head -n 1)"
    [ -n "$_full" ] || die 4 "version $P_VERSION of $1 is not in the EDAMAME repository"
    printf '%s=%s' "$1" "$_full"
}

apt_install() {
    _pkgs=""
    for _p in "$@"; do
        _pkgs="$_pkgs $(apt_resolve "$_p")"
    done
    _before="$(dpkg-query -W -f='${Version}' edamame-posture 2>/dev/null || true)"
    log "Installing:$_pkgs"
    # --force-confold keeps /etc/edamame_posture.conf, which this script owns.
    # shellcheck disable=SC2086
    apt-get install -y -qq --allow-downgrades \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $_pkgs >>"$LOG_FILE" 2>&1 ||
        die 6 "apt-get install failed (see $LOG_FILE)"
    _after="$(dpkg-query -W -f='${Version}' edamame-posture 2>/dev/null || true)"
    [ "$_before" = "$_after" ] || PKG_CHANGED=true
    log "edamame-posture version: ${_after:-unknown}"
}

# ---------------------------------------------------------------------------
# APK
# ---------------------------------------------------------------------------
apk_setup_and_install() {
    if [ "$P_APP" = true ]; then die 3 "edamame-security (GUI) is not packaged for Alpine"; fi
    fetch "$APK_REPO/$(uname -m)/edamame.rsa.pub" "$TMP_DIR/edamame.rsa.pub" || die 4 "could not download the APK signing key"
    [ "$(sha256_of "$TMP_DIR/edamame.rsa.pub")" = "$APK_KEY_SHA256" ] || die 5 "APK signing key checksum mismatch"
    CHANGED=false
    install_file "$TMP_DIR/edamame.rsa.pub" "$APK_KEY" 0644
    grep -qxF "$APK_REPO" /etc/apk/repositories 2>/dev/null || echo "$APK_REPO" >>/etc/apk/repositories
    apk update >>"$LOG_FILE" 2>&1 || die 4 "apk update failed"
    _spec=edamame-posture
    if [ "$P_VERSION" != latest ]; then _spec="edamame-posture=${P_VERSION}-r1"; fi
    _before="$(apk info -v edamame-posture 2>/dev/null | head -n 1 || true)"
    apk add --upgrade "$_spec" >>"$LOG_FILE" 2>&1 || die 6 "apk add $_spec failed (see $LOG_FILE)"
    _after="$(apk info -v edamame-posture 2>/dev/null | head -n 1 || true)"
    [ "$_before" = "$_after" ] || PKG_CHANGED=true
    log "installed: ${_after:-unknown}"
}

# ---------------------------------------------------------------------------
# Service environment for values the service conf has no key for
# (model; base URL of claude/openai). The service wrapper passes its
# environment through to edamame_posture, which reads EDAMAME_LLM_MODEL and
# EDAMAME_LLM_BASE_URL. Neither value is a secret.
# ---------------------------------------------------------------------------
write_service_env() {
    _provider="$(conf_get agentic_provider)"
    _model="$P_MODEL"
    _url=""
    case "$_provider" in claude | openai) _url="$P_BASE_URL" ;; esac
    if [ "$_provider" = edamame ] && [ -n "$_model" ]; then
        log "WARNING: EDAMAME_LLM_MODEL is ignored for the EDAMAME Portal provider"
        _model=""
    fi
    if [ -z "$P_PROVIDER" ]; then
        # Provider not managed on this run: leave the current overrides alone.
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if [ -z "$_model$_url" ]; then
            if [ -f "$DROPIN" ]; then rm -f "$DROPIN"; CHANGED=true; fi
            return 0
        fi
        mkdir -p "$DROPIN_DIR"
        {
            echo "# Written by the EDAMAME auto_provisioning Linux script."
            echo "[Service]"
            if [ -n "$_model" ]; then printf 'Environment="EDAMAME_LLM_MODEL=%s"\n' "$_model"; fi
            if [ -n "$_url" ]; then printf 'Environment="EDAMAME_LLM_BASE_URL=%s"\n' "$_url"; fi
        } >"$TMP_DIR/dropin"
        install_file "$TMP_DIR/dropin" "$DROPIN" 0644
    elif [ -d /etc/conf.d ]; then
        _begin="# BEGIN edamame auto_provisioning"
        _end="# END edamame auto_provisioning"
        [ -f "$OPENRC_CONFD" ] || : >"$OPENRC_CONFD"
        awk -v b="$_begin" -v e="$_end" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$OPENRC_CONFD" >"$TMP_DIR/confd"
        if [ -n "$_model$_url" ]; then
            {
                echo "$_begin"
                if [ -n "$_model" ]; then printf 'export EDAMAME_LLM_MODEL="%s"\n' "$_model"; fi
                if [ -n "$_url" ]; then printf 'export EDAMAME_LLM_BASE_URL="%s"\n' "$_url"; fi
                echo "$_end"
            } >>"$TMP_DIR/confd"
        fi
        install_file "$TMP_DIR/confd" "$OPENRC_CONFD" 0644
    fi
}

restart_service() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl daemon-reload
        systemctl enable edamame_posture.service >>"$LOG_FILE" 2>&1 || true
        if [ "$1" = true ] || ! systemctl is-active --quiet edamame_posture.service; then
            log "Restarting edamame_posture.service"
            systemctl restart edamame_posture.service || die 8 "systemctl restart edamame_posture failed"
        fi
        _i=0
        while [ $_i -lt 30 ]; do
            systemctl is-active --quiet edamame_posture.service && return 0
            sleep 2
            _i=$((_i + 1))
        done
        die 8 "edamame_posture.service is not active (journalctl -u edamame_posture)"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add edamame_posture default >>"$LOG_FILE" 2>&1 || true
        if [ "$1" = true ] || ! rc-service edamame_posture status >/dev/null 2>&1; then
            log "Restarting edamame_posture (OpenRC)"
            rc-service edamame_posture restart >>"$LOG_FILE" 2>&1 || die 8 "rc-service edamame_posture restart failed"
        fi
        sleep 3
        rc-service edamame_posture status >/dev/null 2>&1 || die 8 "edamame_posture (OpenRC) is not running"
    else
        die 3 "neither systemd nor OpenRC found"
    fi
}

uninstall() {
    log "Uninstalling EDAMAME Posture"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now edamame_posture.service >>"$LOG_FILE" 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service edamame_posture stop >>"$LOG_FILE" 2>&1 || true
        rc-update del edamame_posture default >>"$LOG_FILE" 2>&1 || true
    fi
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq edamame-security edamame-posture >>"$LOG_FILE" 2>&1 || true
        rm -f "$APT_LIST" "$APT_KEYRING"
    elif command -v apk >/dev/null 2>&1; then
        apk del edamame-posture >>"$LOG_FILE" 2>&1 || true
        sed -i "\\#^$APK_REPO\$#d" /etc/apk/repositories 2>/dev/null || true
        rm -f "$APK_KEY"
    fi
    rm -f "$CONF" "$DROPIN"
    rmdir "$DROPIN_DIR" 2>/dev/null || true
    if [ -f "$OPENRC_CONFD" ]; then
        sed -i '/# BEGIN edamame auto_provisioning/,/# END edamame auto_provisioning/d' "$OPENRC_CONFD"
    fi
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
    log "Uninstall complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# Test hook: `EDAMAME_PROVISIONING_LIB=1 . ./install-edamame-posture.sh` loads
# the functions without running anything (tests/linux_conf_test.sh).
if [ "${EDAMAME_PROVISIONING_LIB:-}" = 1 ]; then
    CONF="${EDAMAME_TEST_CONF:-$CONF}"
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

[ "$(uname -s)" = Linux ] || die 3 "this script is for Linux"
[ "$(id -u)" -eq 0 ] || die 2 "run as root"
touch "$LOG_FILE" 2>/dev/null && chmod 0640 "$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null

validate

if [ "$ACTION" = uninstall ]; then
    uninstall
    exit 0
fi

log "Provisioning EDAMAME Posture (version: $P_VERSION, provider: ${P_PROVIDER:-unchanged}, hub: $([ -n "$P_USER" ] && echo "$P_USER@$P_DOMAIN" || echo unchanged), pin: $([ -n "$P_PIN" ] && echo set || echo unchanged), llm key: $([ -n "$P_KEY" ] && echo set || echo unchanged))"
TMP_DIR="$(mktemp -d)"
PKG_CHANGED=false

if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
    apt_setup_repo
    if [ "$P_APP" = true ]; then
        [ "$(dpkg --print-architecture)" = amd64 ] || die 3 "edamame-security (GUI) is published for amd64 only"
        apt_install edamame-posture edamame-security
    else
        apt_install edamame-posture
    fi
elif command -v apk >/dev/null 2>&1; then
    apk_setup_and_install
else
    die 3 "no supported package manager (apt or apk); see docs/distribution.md for the raw binaries"
fi

CHANGED=false
render_conf >"$TMP_DIR/edamame_posture.conf" || exit $?
install_file "$TMP_DIR/edamame_posture.conf" "$CONF" 0600
CONF_CHANGED="$CHANGED"

CHANGED=false
write_service_env
ENV_CHANGED="$CHANGED"

if [ "$CONF_CHANGED" = true ] || [ "$ENV_CHANGED" = true ] || [ "$PKG_CHANGED" = true ]; then
    restart_service true
else
    log "Configuration unchanged"
    restart_service false
fi

log "Done: service active, mode=$(conf_get agentic_mode), provider=$(conf_get agentic_provider), hub=$(conf_get edamame_user)@$(conf_get edamame_domain)"
exit 0
