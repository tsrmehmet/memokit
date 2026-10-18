#!/usr/bin/env bash
# PreToolUse(Bash|Edit|Write|MultiEdit|NotebookEdit) hook: destructive commands
# need the user's own approval.
#
# A command matching a builtin or project pattern (lib/careful.sh) is denied
# with a 6-hex approval code. The user approves by STARTING their next
# message with "onay <code>" / "approve <code>"; inject-rules.sh records a
# single-use 10-minute grant, and the exact re-run is let through once.
# File-writing tools are only checked for one thing: they may not touch the
# grant file (approvals come from the user's message, never from the model).
#
# deny, not ask: "ask" does not reliably prompt in auto mode or claude -p,
# deny holds in every mode. This hook never emits "allow" -- that would skip
# Claude Code's own permission flow; "let through" means no output at all.
# Same rules for the main session and subagents.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
[ "${MEMOKIT_CAREFUL_OFF:-0}" = "1" ] && exit 0
mk_guard_off && exit 0
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "guard-destructive" "$PAYLOAD"

static_deny() {
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg "$1")"
}

# deny REASON -- deny JSON from jq; a jq that fails or prints anything but
# the deny object gives a static deny.
deny() {
  local out
  if out="$(jq -n --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)"; then
    case "$out" in
      '{'*'"permissionDecision": "deny"'*'}') printf '%s\n' "$out"; return 0 ;;
    esac
  fi
  static_deny CF_JQ_FAILED_STATIC
}

if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then static_deny CONFIG_NO_JQ_STATIC; exit 0; fi
  deny "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")"
  exit 0
fi

if [ -z "$PAYLOAD" ]; then
  [ "${MEMOKIT_KH_SMOKE:-0}" = "1" ] && exit 0
  static_deny CF_EMPTY_STDIN_STATIC
  exit 0
fi

# "T" sentinel: a jq that fails or prints anything else is not trusted.
if ! tool="$(printf '%s' "$PAYLOAD" | jq -r '"T" + (.tool_name // "" | tostring)' 2>/dev/null)"; then
  deny "$(mk_msg CF_INVALID_JSON)"; exit 0
fi
case "$tool" in
  T*) tool="${tool#T}" ;;
  *) deny "$(mk_msg CF_INVALID_JSON)"; exit 0 ;;
esac

case "$tool" in
  Bash) ;;
  Edit|Write|MultiEdit|NotebookEdit)
    if ! fpath="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // empty)' 2>/dev/null)"; then
      deny "$(mk_msg CF_INVALID_JSON)"; exit 0
    fi
    # Follow symlink chains (max 10 hops; bash 3.2/BSD-safe, no readlink -f).
    # Any hop naming the grant file, or an unresolvable/looping link, denies.
    hops=0
    while :; do
      case "$fpath" in
        # any case: macOS file systems are case-insensitive
        *[Cc][Aa][Rr][Ee][Ff][Uu][Ll]-[Gg][Rr][Aa][Nn][Tt][Ss]*) deny "$(mk_msg CF_STATE)"; exit 0 ;;
      esac
      [ -L "$fpath" ] || break
      hops=$((hops + 1))
      if [ "$hops" -gt 10 ] || ! lnk="$(readlink "$fpath" 2>/dev/null)" || [ -z "$lnk" ]; then
        deny "$(mk_msg CF_STATE)"; exit 0
      fi
      case "$lnk" in
        /*) fpath="$lnk" ;;
        *) fpath="$(dirname "$fpath")/$lnk" ;;
      esac
    done
    exit 0 ;;
  *) exit 0 ;;
esac

# jq -r prints a \u0000 in the command as a raw NUL, which $(...) drops: the
# text checked would differ from the command run. One jq call flags it ("N")
# or returns the command behind a "Y" sentinel.
if ! cmd="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // "" | tostring) as $c
    | if ($c | explode | any(. == 0)) then "N" else "Y" + $c end' 2>/dev/null)"; then
  deny "$(mk_msg CF_INVALID_JSON)"; exit 0
fi
case "$cmd" in
  Y*) cmd="${cmd#Y}" ;;
  N) deny "$(mk_msg CF_NUL)"; exit 0 ;;
  *) deny "$(mk_msg CF_INVALID_JSON)"; exit 0 ;;
esac
[ -n "$cmd" ] || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$MK_LIB_DIR/careful.sh"
# Recursive rm inside this session's scratchpad/ or of a whole stale sibling
# temp entry needs no code (lib/temp.sh, mk_temp_rm_safe), but only for a
# command that is one simple rm; the temp tree is located only then. When it
# is not found (or the payload has no transcript_path), nothing changes.
if mk_careful_single_rm "$cmd"; then
  # shellcheck source-path=SCRIPTDIR source=lib/temp.sh
  . "$MK_LIB_DIR/temp.sh"
  mk_temp_init "$PAYLOAD" || true
fi
labels="$(mk_careful_labels "$cmd")"
[ -n "$labels" ] || exit 0
# Membership in bash, not grep: a failing tool must not read as "absent".
# (labels is short: one line per distinct label.)
nl='
'
case "$nl$labels$nl" in
  *"${nl}careful-state${nl}"*) deny "$(mk_msg CF_STATE)"; exit 0 ;;
esac

code="$(mk_careful_code "$cmd")"
mk_careful_consume "$code" && exit 0
# Every message names every label: a special case must not hide the rest.
all="${labels//$nl/, }"
case "$nl$labels$nl" in
  *"${nl}careful-state-glob${nl}"*) deny "$(mk_msg CF_STATE_GLOB "$all" "$code")"; exit 0 ;;
  *"${nl}too-large${nl}"*) deny "$(mk_msg CF_TOO_LARGE "$all" "$code")"; exit 0 ;;
esac
deny "$(mk_msg CF_BLOCKED "$all" "$code")"
exit 0
