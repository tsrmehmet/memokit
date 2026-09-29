#!/usr/bin/env bash
# Static, warn-only scan of project Claude settings for plaintext secrets and
# over-broad permission rules. Sourced by session-start.sh when present; not
# executed directly (matches the other files in hooks/lib).
#
# NEVER PRINTS ANY MATCHED VALUE. Output is limited to the settings file's
# own (fixed, repo-relative) name plus a fixed kind/shape label -- never any
# substring of the rule text that triggered the match. This is why every
# branch below tests the rule text with grep and, on a match, prints only a
# constant label (`sshpass-p`, `token=`, `Bash(*)`, ...) rather than the rule
# itself or any part of it: the whole point of this scan is to flag that a
# secret exists in permissions config without ever putting that secret into
# a hook's stdout, a transcript, or additionalContext.
risk_scan() {
  local root="$1" f rel rules kind
  for rel in .claude/settings.json .claude/settings.local.json; do
    f="$root/$rel"
    [ -f "$f" ] || continue
    # A settings file the project controls, not this repo -- broken JSON,
    # rules containing quotes/newlines/control characters, anything. jq
    # failing here (bad JSON) must just skip this file, never break
    # session-start.sh's own JSON output.
    rules="$(jq -r '[.permissions.allow[]?, .permissions.ask[]?] | .[]' "$f" 2>/dev/null)" || continue
    kind=""
    printf '%s\n' "$rules" | grep -Eqi 'sshpass[[:space:]]+-p' && kind="${kind}sshpass-p,"
    printf '%s\n' "$rules" | grep -Eqi '(password|passwd|pwd)=' && kind="${kind}password=,"
    printf '%s\n' "$rules" | grep -Eqi '(token|secret|api[_-]?key)=' && kind="${kind}token=,"
    printf '%s\n' "$rules" | grep -Eq 'BEGIN [A-Z ]*PRIVATE KEY' && kind="${kind}private-key,"
    printf '%s\n' "$rules" | grep -Eq '(ghp|gho|github_pat)_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}' && kind="${kind}token-literal,"
    [ -n "$kind" ] && mk_msg SS_RISK_SECRET "$rel" "${kind%,}" && printf '\n'
    printf '%s\n' "$rules" | grep -Fxq 'Bash(*)' && mk_msg SS_RISK_BROAD "$rel" 'Bash(*)' && printf '\n'
    printf '%s\n' "$rules" | grep -Fxq 'Bash' && mk_msg SS_RISK_BROAD "$rel" 'Bash' && printf '\n'
    printf '%s\n' "$rules" | grep -Eq '^Bash\(rm( |:)\*?\)?' && mk_msg SS_RISK_BROAD "$rel" 'Bash(rm:*)' && printf '\n'
    printf '%s\n' "$rules" | grep -Eq '^Bash\((curl|wget)[^)]*\|[[:space:]]*(ba)?sh' && mk_msg SS_RISK_BROAD "$rel" 'Bash(curl … | sh)' && printf '\n'
  done
  return 0
}
