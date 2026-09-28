#!/bin/sh
# Static checks and unit tests for this repository. Tools that are not
# installed are reported as SKIP, not as a pass.
#   PWSH=/path/to/pwsh             PowerShell 7 for the .ps1 parse check
#   PSSA_MODULE_PATH=/path          directory holding PSScriptAnalyzer
#   ANSIBLE_BIN_DIR=/path/bin       directory holding ansible-playbook / ansible-lint
#   EDAMAME_POSTURE_WRAPPER=/path   edamame_posture/linux/edamame_posture_daemon.sh
set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0
ok() { echo "PASS  $*"; }
ko() { echo "FAIL  $*"; FAIL=1; }
skip() { echo "SKIP  $*"; }

for f in scripts/linux/*.sh tests/linux_conf_test.sh tools/lint.sh; do
    if sh -n "$f"; then ok "sh -n $f"; else ko "sh -n $f"; fi
done
for f in scripts/macos/*.sh tests/macos_conf_test.sh; do
    if bash -n "$f"; then ok "bash -n $f"; else ko "bash -n $f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s sh scripts/linux/*.sh tests/linux_conf_test.sh tools/lint.sh; then ok "shellcheck (sh)"; else ko "shellcheck (sh)"; fi
    if shellcheck scripts/macos/*.sh tests/macos_conf_test.sh; then ok "shellcheck (bash)"; else ko "shellcheck (bash)"; fi
else
    skip "shellcheck not installed"
fi

if sh tests/linux_conf_test.sh >/tmp/edamame_lint_linux.$$ 2>&1; then ok "tests/linux_conf_test.sh"; else ko "tests/linux_conf_test.sh"; cat /tmp/edamame_lint_linux.$$; fi
if bash tests/macos_conf_test.sh >/tmp/edamame_lint_macos.$$ 2>&1; then ok "tests/macos_conf_test.sh"; else ko "tests/macos_conf_test.sh"; cat /tmp/edamame_lint_macos.$$; fi
rm -f /tmp/edamame_lint_linux.$$ /tmp/edamame_lint_macos.$$

PWSH="${PWSH:-$(command -v pwsh || true)}"
if [ -n "$PWSH" ]; then
    # shellcheck disable=SC2016
    if "$PWSH" -NoProfile -Command '
        $bad = 0
        foreach ($f in Get-ChildItem -Recurse -Filter *.ps1 scripts) {
            $t = $null; $e = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
            if ($e.Count) { $bad++; $e | ForEach-Object { "{0}:{1} {2}" -f $f.Name, $_.Extent.StartLineNumber, $_.Message } }
            # Embedded launcher here-strings are parsed too.
            $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $args[0].StringConstantType -eq "SingleQuotedHereString" }, $true) | ForEach-Object {
                $t2 = $null; $e2 = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($_.Value, [ref]$t2, [ref]$e2)
                if ($e2.Count) { $bad++; "{0}: embedded script: {1}" -f $f.Name, $e2[0].Message }
            }
        }
        exit $bad'; then ok "PowerShell parse"; else ko "PowerShell parse"; fi
    if [ -n "${PSSA_MODULE_PATH:-}" ]; then
        # shellcheck disable=SC2016
        if "$PWSH" -NoProfile -Command '
            $env:PSModulePath = $env:PSSA_MODULE_PATH + [IO.Path]::PathSeparator + $env:PSModulePath
            $r = Invoke-ScriptAnalyzer -Path scripts/windows -Recurse -Severity Warning,Error
            $r | Format-Table -AutoSize ScriptName,Line,RuleName,Message | Out-String -Width 200
            exit @($r).Count'; then ok "PSScriptAnalyzer (warnings, errors)"; else ko "PSScriptAnalyzer"; fi
    else
        skip "PSScriptAnalyzer (set PSSA_MODULE_PATH)"
    fi
else
    skip "pwsh not installed: PowerShell scripts not parsed"
fi

if command -v plutil >/dev/null 2>&1; then
    if plutil -lint profiles/macos/*.mobileconfig >/dev/null; then ok "plutil -lint profiles"; else ko "plutil -lint profiles"; fi
else
    skip "plutil not available"
fi
if command -v xmllint >/dev/null 2>&1; then
    if xmllint --noout profiles/windows/admx/EDAMAME.admx profiles/windows/admx/en-US/EDAMAME.adml; then ok "xmllint ADMX/ADML"; else ko "xmllint ADMX/ADML"; fi
else
    skip "xmllint not installed"
fi

AB="${ANSIBLE_BIN_DIR:-}"
if [ -z "$AB" ] && command -v ansible-playbook >/dev/null 2>&1; then AB="$(dirname "$(command -v ansible-playbook)")"; fi
if [ -n "$AB" ] && [ -x "$AB/ansible-playbook" ]; then
    inv="$(mktemp)"
    printf '[edamame_hosts]\nlocalhost ansible_connection=local\n' >"$inv"
    if (cd ansible && "$AB/ansible-playbook" -i "$inv" playbook.example.yml --syntax-check </dev/null >/dev/null 2>&1); then ok "ansible-playbook --syntax-check"; else ko "ansible-playbook --syntax-check"; fi
    rm -f "$inv"
    if [ -x "$AB/ansible-lint" ]; then
        if (cd ansible && ANSIBLE_ROLES_PATH=roles "$AB/ansible-lint" --offline playbook.example.yml roles/edamame </dev/null >/dev/null 2>&1); then ok "ansible-lint"; else ko "ansible-lint"; fi
    else
        skip "ansible-lint not installed"
    fi
else
    skip "ansible not installed"
fi
if command -v yamllint >/dev/null 2>&1; then
    if yamllint -d '{extends: default, rules: {line-length: {max: 160}}}' ansible; then ok "yamllint ansible"; else ko "yamllint ansible"; fi
else
    skip "yamllint not installed"
fi

exit $FAIL
