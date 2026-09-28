#!/bin/bash
# shellcheck disable=SC2030,SC2031  # the test subshells export on purpose
# Unit tests for scripts/macos/install-edamame-posture.sh: configuration
# rendering, the embedded launcher (run against a stub binary) and the
# LaunchDaemon plist. Needs no root; runs on macOS (plutil) or Linux (plist
# lint skipped).

set -u
for _v in EDAMAME_ACTION EDAMAME_USER EDAMAME_DOMAIN EDAMAME_PIN EDAMAME_PIN_FILE EDAMAME_DEVICE_ID \
    EDAMAME_LLM_PROVIDER EDAMAME_LLM_API_KEY EDAMAME_LLM_API_KEY_FILE EDAMAME_LLM_MODEL \
    EDAMAME_LLM_BASE_URL EDAMAME_AGENTIC_MODE EDAMAME_AGENTIC_INTERVAL EDAMAME_VERSION EDAMAME_SHA256; do
    unset "$_v"
done
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/macos/install-edamame-posture.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

run_render() {
    local conf="$1"
    shift
    (
        for a in "$@"; do export "${a?}"; done
        export EDAMAME_PROVISIONING_LIB=1 EDAMAME_TEST_CONF="$conf" EDAMAME_LOG_FILE=/dev/null
        # shellcheck disable=SC1090
        source "$SCRIPT"
        validate
        render_conf >"$conf.new" || exit $?
        mv "$conf.new" "$conf"
    ) 2>"$WORK/stderr"
}
get() {
    (
        export EDAMAME_PROVISIONING_LIB=1 EDAMAME_TEST_CONF="$1" EDAMAME_LOG_FILE=/dev/null
        # shellcheck disable=SC1090
        source "$SCRIPT"
        conf_get "$2"
    )
}
expect() {
    local got
    got="$(get "$1" "$2")"
    if [ "$got" = "$3" ]; then pass "$4"; else fail "$4 ($2: got '$got', want '$3')"; fi
}

C="$WORK/edamame_posture.conf"
if run_render "$C" EDAMAME_USER=alice@example.com EDAMAME_PIN=123456 EDAMAME_LLM_PROVIDER=openai \
    EDAMAME_LLM_API_KEY='sk-"x\y' EDAMAME_LLM_MODEL=gpt-5-mini EDAMAME_LLM_BASE_URL=https://llm.example.com/v1; then
    expect "$C" edamame_domain example.com "user@domain split"
    expect "$C" agentic_provider openai "provider"
    expect "$C" agentic_mode analyze "provider implies analyze"
    expect "$C" llm_api_key 'sk-"x\y' "key round-trips"
    expect "$C" llm_base_url https://llm.example.com/v1 "base url"
else
    fail "render exited $?: $(cat "$WORK/stderr")"
fi

cp "$C" "$WORK/before"
if run_render "$C" && cmp -s "$C" "$WORK/before"; then pass "idempotent re-run"; else fail "re-run changed the file"; fi

if run_render "$C" EDAMAME_LLM_PROVIDER=portal EDAMAME_LLM_API_KEY=edm_live_z; then
    expect "$C" agentic_provider edamame "portal maps to edamame"
    expect "$C" llm_model "" "model of previous provider dropped"
    expect "$C" llm_base_url "" "base url of previous provider dropped"
    expect "$C" edamame_user alice "hub user carried over"
else
    fail "switch exited $?"
fi

rm -f "$WORK/e.conf"
run_render "$WORK/e.conf" EDAMAME_AGENTIC_MODE=auto
if [ $? -eq 2 ]; then pass "mode without provider -> exit 2"; else fail "mode without provider accepted"; fi
run_render "$WORK/e.conf" EDAMAME_VERSION=latest EDAMAME_SHA256=abc
if [ $? -eq 2 ]; then pass "bad sha256 -> exit 2"; else fail "bad sha256 accepted"; fi

# Provider slots for `edamame_posture service-run` (EDAMAME >= 2.0.2).
C2="$WORK/slots.conf"
if run_render "$C2" EDAMAME_LLM_PROVIDER=claude EDAMAME_LLM_API_KEY=sk-ant-1; then
    expect "$C2" claude_api_key sk-ant-1 "claude key in its slot"
    expect "$C2" openai_api_key "" "no openai key"
    expect "$C2" llm_api_key sk-ant-1 "launcher key kept"
else
    fail "slots render exited $?"
fi

# SHA256SUMS parsing (EDAMAME >= 2.0.2 releases).
cat >"$WORK/SHA256SUMS" <<'SUMS'
1111111111111111111111111111111111111111111111111111111111111111  edamame-posture-macos-2.0.2-debug.pkg
2222222222222222222222222222222222222222222222222222222222222222  edamame-posture-macos-2.0.2.pkg
3333333333333333333333333333333333333333333333333333333333333333  edamame_posture-2.0.2-universal-apple-darwin
SUMS
sums_line() {
    (
        export EDAMAME_PROVISIONING_LIB=1 EDAMAME_LOG_FILE=/dev/null
        # shellcheck disable=SC1090
        source "$SCRIPT"
        # shellcheck disable=SC2034  # read by sums_pkg_line
        P_VERSION="$1"
        sums_pkg_line "$WORK/SHA256SUMS"
    )
}
case "$(sums_line latest)" in 2222*"edamame-posture-macos-2.0.2.pkg") pass "SHA256SUMS latest -> release PKG" ;; *) fail "SHA256SUMS latest: $(sums_line latest)" ;; esac
case "$(sums_line 2.0.2)" in 2222*) pass "SHA256SUMS exact version" ;; *) fail "SHA256SUMS exact: $(sums_line 2.0.2)" ;; esac
if [ -z "$(sums_line 2.0.20)" ] && [ -z "$(sums_line 2x0x2)" ]; then pass "SHA256SUMS no false match"; else fail "SHA256SUMS false match"; fi

# Launcher against a stub binary.
(
    export EDAMAME_PROVISIONING_LIB=1 EDAMAME_LOG_FILE=/dev/null
    # shellcheck disable=SC1090
    source "$SCRIPT"
    render_launcher >"$WORK/launcher.sh"
    render_plist >"$WORK/daemon.plist"
)
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s sh "$WORK/launcher.sh"; then pass "launcher shellcheck"; else fail "launcher shellcheck"; fi
fi
if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$WORK/daemon.plist" >/dev/null; then pass "plist lint"; else fail "plist lint"; fi
fi
mkdir -p "$WORK/bin" "$WORK/state"
cat >"$WORK/bin/posture" <<'EOF'
#!/bin/sh
echo "ARGS: $*"
echo "KEY: ${EDAMAME_LLM_API_KEY:+set}"
echo "CWD: $(pwd)"
EOF
chmod +x "$WORK/bin/posture"
sed -e "s|^CONF=.*|CONF=\"$C\"|" -e "s|^BIN=.*|BIN=\"$WORK/bin/posture\"|" -e "s|^STATE=.*|STATE=\"$WORK/state\"|" \
    "$WORK/launcher.sh" >"$WORK/launcher_test.sh"
out="$(sh "$WORK/launcher_test.sh" 2>&1)"
case "$out" in
    *"ARGS: foreground-start --user alice --domain example.com --pin 123456 --agentic-mode analyze --agentic-provider edamame --agentic-interval 3600"*) pass "launcher arguments" ;;
    *) fail "launcher arguments: $out" ;;
esac
case "$out" in *"KEY: set"*) pass "launcher exports key" ;; *) fail "launcher did not export key" ;; esac
case "$out" in *edm_live_z*) fail "launcher printed the key" ;; *) pass "launcher does not print the key" ;; esac
case "$out" in *"CWD: $WORK/state"* | *"CWD: /private$WORK/state"*) pass "launcher working directory" ;; *) fail "launcher cwd: $out" ;; esac

echo
if [ $FAILS -eq 0 ]; then echo "ALL PASSED"; else echo "$FAILS FAILURE(S)"; fi
[ $FAILS -eq 0 ]
