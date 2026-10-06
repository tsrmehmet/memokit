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

if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then static_deny CONFIG_NO_JQ_STATIC; exit 0; fi
  jq -n --arg r "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

if [ -z "$PAYLOAD" ]; then
  [ "${MEMOKIT_KH_SMOKE:-0}" = "1" ] && exit 0
  static_deny CF_EMPTY_STDIN_STATIC
  exit 0
fi

deny() {
  local out
  if out="$(jq -n --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)" &&
     [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    static_deny CF_JQ_FAILED_STATIC
  fi
}

if ! tool="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null)"; then
  deny "$(mk_msg CF_INVALID_JSON)"; exit 0
fi

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
        *careful-grants*) deny "$(mk_msg CF_STATE)"; exit 0 ;;
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

if ! cmd="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"; then
  deny "$(mk_msg CF_INVALID_JSON)"; exit 0
fi
[ -n "$cmd" ] || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$MK_LIB_DIR/careful.sh"
labels="$(mk_careful_labels "$cmd")"
[ -n "$labels" ] || exit 0

if printf '%s\n' "$labels" | grep -qx 'careful-state'; then
  deny "$(mk_msg CF_STATE)"; exit 0
fi

code="$(mk_careful_code "$cmd")"
mk_careful_consume "$code" && exit 0
deny "$(mk_msg CF_BLOCKED "$(printf '%s\n' "$labels" | paste -sd, - | sed 's/,/, /g')" "$code")"
exit 0
