#!/bin/sh
# Unit tests for the configuration logic of scripts/linux/install-edamame-posture.sh.
# Runs anywhere (macOS or Linux, no root): it only loads the functions and
# renders configuration files into a temporary directory.
#
# Optional: EDAMAME_POSTURE_WRAPPER=/path/to/edamame_posture/linux/edamame_posture_daemon.sh
# additionally feeds each rendered file to the real service wrapper (with a
# stub binary) and checks the arguments it would start edamame_posture with.

set -u
# Start from a clean parameter environment (a developer shell may export some).
for _v in EDAMAME_ACTION EDAMAME_USER EDAMAME_DOMAIN EDAMAME_PIN EDAMAME_PIN_FILE EDAMAME_DEVICE_ID \
    EDAMAME_LLM_PROVIDER EDAMAME_LLM_API_KEY EDAMAME_LLM_API_KEY_FILE EDAMAME_LLM_MODEL \
    EDAMAME_LLM_BASE_URL EDAMAME_AGENTIC_MODE EDAMAME_AGENTIC_INTERVAL EDAMAME_VERSION EDAMAME_INSTALL_APP; do
    unset "$_v"
done
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/linux/install-edamame-posture.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

# run_render <conf> <env assignments...>: renders into <conf> in a subshell.
run_render() {
    _conf="$1"
    shift
    (
        for _a in "$@"; do export "${_a?}"; done
        EDAMAME_PROVISIONING_LIB=1 EDAMAME_TEST_CONF="$_conf" EDAMAME_LOG_FILE=/dev/null
        export EDAMAME_PROVISIONING_LIB EDAMAME_TEST_CONF EDAMAME_LOG_FILE
        # shellcheck disable=SC1090
        . "$SCRIPT"
        validate
        render_conf >"$_conf.new" || exit $?
        mv "$_conf.new" "$_conf"
    ) 2>"$WORK/stderr"
}

get() {
    (
        EDAMAME_PROVISIONING_LIB=1 EDAMAME_TEST_CONF="$1" EDAMAME_LOG_FILE=/dev/null
        export EDAMAME_PROVISIONING_LIB EDAMAME_TEST_CONF EDAMAME_LOG_FILE
        # shellcheck disable=SC1090
        . "$SCRIPT"
        conf_get "$2"
    )
}

expect() {
    _got="$(get "$1" "$2")"
    if [ "$_got" = "$3" ]; then pass "$4"; else fail "$4 ($2: got '$_got', want '$3')"; fi
}

C="$WORK/edamame_posture.conf"

# 1. Fresh install, Portal provider.
if run_render "$C" EDAMAME_USER=alice EDAMAME_DOMAIN=example.com EDAMAME_PIN=123456 \
    EDAMAME_LLM_PROVIDER=portal 'EDAMAME_LLM_API_KEY=edm_live_a"b\c'; then
    expect "$C" edamame_user alice "fresh: user"
    expect "$C" edamame_pin 123456 "fresh: pin"
    expect "$C" agentic_provider edamame "fresh: portal maps to edamame"
    expect "$C" agentic_mode analyze "fresh: provider implies analyze"
    expect "$C" llm_api_key 'edm_live_a"b\c' "fresh: key with quote and backslash round-trips"
    expect "$C" notification_provider auto "fresh: notification default"
else
    fail "fresh render exited $?: $(cat "$WORK/stderr")"
fi

# 2. Switch to Claude: Hub settings carried over, Portal key removed.
if run_render "$C" EDAMAME_LLM_PROVIDER=claude EDAMAME_LLM_API_KEY=sk-ant-x; then
    expect "$C" edamame_user alice "switch: hub user carried over"
    expect "$C" edamame_pin 123456 "switch: pin carried over"
    expect "$C" agentic_provider claude "switch: provider"
    expect "$C" claude_api_key sk-ant-x "switch: claude slot"
    expect "$C" llm_api_key "" "switch: stale Portal key cleared"
else
    fail "switch render exited $?: $(cat "$WORK/stderr")"
fi

# 3. Re-run with nothing: unchanged.
cp "$C" "$WORK/before"
if run_render "$C"; then
    if cmp -s "$C" "$WORK/before"; then pass "idempotent re-run"; else fail "re-run changed the file"; fi
else
    fail "empty re-run exited $?"
fi

# 4. Provider none: disabled, all credentials cleared.
if run_render "$C" EDAMAME_LLM_PROVIDER=none; then
    expect "$C" agentic_mode disabled "none: mode disabled"
    expect "$C" claude_api_key "" "none: key cleared"
else
    fail "none render exited $?"
fi

# 5. Mode without any credential is refused.
rm -f "$WORK/empty.conf"
run_render "$WORK/empty.conf" EDAMAME_AGENTIC_MODE=analyze
rc=$?
if [ $rc -eq 2 ]; then pass "mode without credential -> exit 2"; else fail "mode without credential exited $rc"; fi

# 6. Invalid PIN / partial Hub credentials / bad provider.
expect_exit2() {
    _label="$1"
    shift
    run_render "$WORK/x.conf" "$@"
    if [ $? -eq 2 ]; then pass "$_label -> exit 2"; else fail "$_label accepted"; fi
}
expect_exit2 "non-digit PIN" EDAMAME_USER=a EDAMAME_DOMAIN=example.com EDAMAME_PIN=12ab
expect_exit2 "partial hub credentials" EDAMAME_USER=a EDAMAME_PIN=123456
expect_exit2 "unknown provider" EDAMAME_LLM_PROVIDER=gemini
expect_exit2 "single-label domain" EDAMAME_USER=a EDAMAME_DOMAIN=localhost EDAMAME_PIN=123456

# 7. user@domain is split.
rm -f "$WORK/s.conf"
if run_render "$WORK/s.conf" EDAMAME_USER=bob@corp.example EDAMAME_PIN=654321; then
    expect "$WORK/s.conf" edamame_user bob "split: user"
    expect "$WORK/s.conf" edamame_domain corp.example "split: domain"
else
    fail "user@domain render exited $?"
fi

# 8. Ollama uses the base URL slot.
rm -f "$WORK/o.conf"
if run_render "$WORK/o.conf" EDAMAME_LLM_PROVIDER=ollama EDAMAME_LLM_BASE_URL=http://10.0.0.5:11434; then
    expect "$WORK/o.conf" ollama_base_url http://10.0.0.5:11434 "ollama: base url slot"
else
    fail "ollama render exited $?"
fi

# 9. Optional: the real service wrapper accepts the rendered files.
WRAPPER="${EDAMAME_POSTURE_WRAPPER:-}"
if [ -n "$WRAPPER" ] && [ -f "$WRAPPER" ]; then
    STUB="$WORK/stub_posture"
    cat >"$STUB" <<'EOF'
#!/bin/sh
echo "ARGS: $*"
echo "KEY_SET: ${EDAMAME_LLM_API_KEY:+yes}"
EOF
    chmod +x "$STUB"
    rm -f "$WORK/w.conf"
    run_render "$WORK/w.conf" EDAMAME_USER=alice EDAMAME_DOMAIN=example.com EDAMAME_PIN=123456 \
        EDAMAME_LLM_PROVIDER=portal EDAMAME_LLM_API_KEY=edm_live_x EDAMAME_AGENTIC_MODE=auto
    out="$(EDAMAME_POSTURE_CONF="$WORK/w.conf" EDAMAME_POSTURE_BIN="$STUB" sh "$WRAPPER" 2>&1)"
    case "$out" in
        *"ARGS: foreground-start -v --user alice --domain example.com --pin 123456 --agentic-mode auto --agentic-provider edamame --agentic-interval 3600"*) pass "wrapper: arguments" ;;
        *) fail "wrapper: unexpected arguments: $(echo "$out" | grep ARGS)" ;;
    esac
    case "$out" in *"KEY_SET: yes"*) pass "wrapper: key exported" ;; *) fail "wrapper: key not exported" ;; esac
    case "$out" in *edm_live_x*) fail "wrapper output contains the key" ;; *) pass "wrapper: key not printed" ;; esac
else
    echo "skip: set EDAMAME_POSTURE_WRAPPER to test against edamame_posture_daemon.sh"
fi

echo
if [ $FAILS -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILS FAILURE(S)"; fi
[ $FAILS -eq 0 ]
