#!/usr/bin/env bash
# PermissionRequest hook (Bash, Edit, Write, MultiEdit, NotebookEdit, Read,
# WebFetch): the evidence side of the runtime integrity check's allow-only exemption
# (0.8.1). It ONLY records; it never decides. Its stdout and stderr go to
# /dev/null before anything else runs, so no allow, deny or other output can
# reach Claude Code, whatever happens below.
#
# Claude Code runs PermissionRequest only when it is about to show a
# permission prompt, after the PreToolUse hooks. The payload has tool_name,
# tool_input, session_id and an optional permission_suggestions array (no
# tool_use_id). Each suggested allow rule that would be written to a
# settings file ({"type":"addRules","behavior":"allow","destination":
# "localSettings"|"projectSettings"|"userSettings","rules":[{"toolName",
# "ruleContent"?}]}) becomes one JSON line in careful-integrity-perm-<sid>
# (lib/integrity.sh): {"t": jq's now, "tool", "dest", "rule":
# "Tool(content)" or "Tool"}. At PostToolUse, check-integrity.sh lets an
# allow-only settings change pass without the full alert only when every
# added rule matches such a line (same rule and destination) recorded
# between that call's Pre and Post (mk_integrity_perm_ok): a prompt of any
# call of the agent in that window, since "don't ask again" on a parallel
# call writes the same settings file while this call runs.
#
# Failing closed: out of time, jq missing or failing, a payload without
# suggestions, a record that cannot be written -- nothing is recorded, so a
# later allow-only change gets the full alert.
set -u
PAYLOAD="$(cat)"
exec >/dev/null 2>&1
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
mk_guard_off && exit 0
# shellcheck source-path=SCRIPTDIR source=lib/budget.sh
. "$MK_LIB_DIR/budget.sh"
# shellcheck source-path=SCRIPTDIR source=lib/integrity.sh
. "$MK_LIB_DIR/integrity.sh"

# The longest suggested rule recorded (a longer one is not recorded: adding
# it keeps the full alert) and the lines the record keeps.
MK_IG_PERM_RULE_MAX=4096
MK_IG_PERM_LINES=64

# The shared budget, armed before the first jq. Event "Quiet": its static
# path prints nothing (and stdout is /dev/null anyway); mode "zero".
MK_BUDGET_EVENT=Quiet
mk_budget_arm 3.3 4 IG_POST_FAIL_STATIC IG_POST_FAIL_STATIC zero
mk_budget_test_burn

if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then mk_resolve_root ""; else mk_resolve_root "$PAYLOAD"; fi
mk_active || exit 0
mk_debug_dump "record-permission" "$PAYLOAD"

# One jq: the session id, the number of rules, then one JSON line per rule
# (tojson escapes newlines). Nothing when the tool is not one of the seven or
# no rule fits.
_rp_out="$(printf '%s' "$PAYLOAD" | jq -r --argjson max "$MK_IG_PERM_RULE_MAX" '
  (.tool_name // "" | tostring) as $t
  | select($t == "Bash" or $t == "Edit" or $t == "Write" or $t == "MultiEdit" or $t == "NotebookEdit"
           or $t == "Read" or $t == "WebFetch")
  | [ .permission_suggestions? | arrays | .[] | objects
      | select(.type == "addRules" and .behavior == "allow")
      | .destination as $d
      | select($d == "localSettings" or $d == "projectSettings" or $d == "userSettings")
      | .rules | arrays | .[] | objects
      | select((.toolName | type) == "string" and (.ruleContent == null or (.ruleContent | type) == "string"))
      | {t: now, tool: $t, dest: $d,
         rule: (if .ruleContent == null then .toolName else "\(.toolName)(\(.ruleContent))" end)}
      | select((.rule | length) <= $max) ] as $r
  | select($r | length > 0)
  | (.session_id // "unknown" | tostring | gsub("\n"; " ")),
    ($r | length | tostring),
    ($r[] | tojson)' 2>/dev/null)" || exit 0
[ -n "$_rp_out" ] || exit 0

_rp_new=""
{
  IFS= read -r _rp_sid
  IFS= read -r _rp_n
  case "$_rp_n" in ''|*[!0-9]*) exit 0 ;; esac
  _rp_i=0
  while [ "$_rp_i" -lt "$_rp_n" ]; do
    IFS= read -r _rp_l || exit 0
    case "$_rp_l" in '{"t":'*'}') ;; *) exit 0 ;; esac
    _rp_new="$_rp_new$_rp_l$MK_IG_NL"
    _rp_i=$((_rp_i + 1))
  done
} <<EOF
$_rp_out
EOF
[ -n "$_rp_new" ] || exit 0

# Append, keeping the last MK_IG_PERM_LINES lines (the safe writer; an old
# record that is not a regular file of ours is not read). Old lines whose
# time is 10 minutes or more before this prompt's (jq's now, the new lines'
# "t") are pruned on read: they back nothing any more (mk_integrity_perm_ok).
_rp_f="$(_mk_session_tmp integrity-perm "$_rp_sid")"
_rp_now="${_rp_new#\{\"t\":}"; _rp_now="${_rp_now%%[!0-9]*}"
_rp_old=""
# The record's lock (lib/integrity.sh), so a binding check-integrity.sh
# writes meanwhile is not lost; not taken in time: nothing is recorded. A
# holder that dies leaves it for 30 s (then removed as stale).
_mk_ig_lock "$_rp_f" || exit 0
if [ -f "$_rp_f" ] && [ ! -L "$_rp_f" ] && [ -O "$_rp_f" ]; then
  _rp_old="$(tail -n "$MK_IG_PERM_LINES" "$_rp_f" 2>/dev/null)"
fi
printf '%s\n%s' "$_rp_old" "$_rp_new" |
  LC_ALL=C awk -v now="${_rp_now:-0}" 'NF == 0 { next }
    match($0, /^\{"t":[0-9.]+[,}]/) { t = substr($0, 6, RLENGTH - 6) + 0; if (now > 0 && t <= now - 600) next }
    { print }' | tail -n "$MK_IG_PERM_LINES" | _mk_state_write "$_rp_f" 2>/dev/null
rmdir "$_rp_f.lock" 2>/dev/null
exit 0
