#!/usr/bin/env bash
# PreToolUse / PostToolUse / PostToolUseFailure (Bash) and Stop hook:
# disk-space watchdog. Design: the 0.5.0 scratch and disk hygiene spec,
# feature 2.
#
# - Every event first runs mk_temp_init (no du), so the free space is the min
#   of the project root's and the session temp root's filesystems (see
#   mk_disk_free_kb); without a temp tree only the project root is measured.
# - PreToolUse records that free space under a per-command key. It prints
#   NOTHING, ever, so it cannot interfere with the allow/deny decisions of
#   other PreToolUse hooks.
# - PostToolUse, and PostToolUseFailure (Claude Code fires PostToolUse only on
#   success; a failing command gets PostToolUseFailure, which carries the same
#   tool_use_id / tool_input / session_id / transcript_path and honours
#   hookSpecificOutput.additionalContext, per the hooks reference), consume
#   that record: a drop of at least disk.dropWarnGB (default 10) is reported to
#   the model as additionalContext under the event's own hookEventName,
#   together with the session temp size. They also report a free-space floor
#   crossing (disk.minFreeGB, default 30; 0 disables) at most once per 10 min.
# - Stop reports the floor crossing to the user as systemMessage, at most once
#   per 30 min, with the cached leftover total written by the sweep logic
#   (file temp-leftover-<session>, one integer KB, absent = 0).
#
# Baseline key: the sanitised tool_use_id when the payload carries one, else
# session_id + a cksum of tool_input.command (Pre and Post compute the same).
# tool_use_id is documented for all three tool events but was never measured
# live here; the fallback keeps the hook working either way.
#
# State files live under mk_tmp (shared /tmp on Linux), so they are treated as
# hostile: every id is sanitised to [A-Za-z0-9_-], a target that is a symlink
# or not owned by us is skipped silently, writes go through a umask-077 temp
# file in the same dir + mv, and the Pre pruning only touches this hook's own
# prefix, regular files only (find does not follow symlinks).
#
# Test-only seam: MEMOKIT_DF_KB (handled in mk_disk_free_kb) replaces the
# measured free space. MEMOKIT_DISK_OFF=1 turns the hook off. Fail-open.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "check-disk" "$PAYLOAD"
mk_load_config || exit 0

[ -z "$PAYLOAD" ] && exit 0
[ "${MEMOKIT_DISK_OFF:-0}" = "1" ] && exit 0
# shellcheck source-path=SCRIPTDIR source=lib/temp.sh
. "$(dirname "$0")/lib/temp.sh" 2>/dev/null || exit 0

EVENT="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)"
case "$EVENT" in PreToolUse|PostToolUse|PostToolUseFailure|Stop) ;; *) exit 0 ;; esac

_san() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' _; }
SESSION="$(_san "$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null)")"
[ -z "$SESSION" ] && SESSION="unknown"

# _safe F -- 0 when F may be read/written/removed: absent, or a regular file we
# own that is not a symlink.
_safe() {
  [ -L "$1" ] && return 1
  [ -e "$1" ] || return 0
  [ -f "$1" ] && [ -O "$1" ]
}
# _read_int F -- prints the digits-only content of a safe file (empty if none).
_read_int() {
  local v
  [ -e "$1" ] && _safe "$1" || return 0
  v="$(head -c 24 "$1" 2>/dev/null | tr -d '\n')"
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}
# _write F VALUE -- atomic write via same-dir temp file under umask 077.
_write() {
  local t
  _safe "$1" || return 0
  t="$(umask 077; mktemp "$1.XXXXXX" 2>/dev/null)" || return 0
  if printf '%s' "$2" > "$t" 2>/dev/null; then mv -f "$t" "$1" 2>/dev/null || rm -f "$t"; else rm -f "$t"; fi
  return 0
}
_remove() { [ -e "$1" ] || [ -L "$1" ] || return 0; _safe "$1" && rm -f "$1" 2>/dev/null; return 0; }

# Locates the session temp root too (cheap, no du), so mk_disk_free_kb also
# measures its filesystem; harmless when there is no temp tree.
mk_temp_init "$PAYLOAD" >/dev/null 2>&1
FREE="$(mk_disk_free_kb)" || exit 0
case "$FREE" in ''|*[!0-9]*) exit 0 ;; esac

if [ "$EVENT" != "Stop" ]; then
  TUID="$(_san "$(printf '%s' "$PAYLOAD" | jq -r '.tool_use_id // empty' 2>/dev/null)")"
  if [ -z "$TUID" ]; then
    CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    TUID="c-${SESSION}-$(printf '%s' "$CMD" | cksum | cut -d' ' -f1)"
  fi
  PRE="$(mk_tmp "disk-pre-${TUID}")"
fi

if [ "$EVENT" = "PreToolUse" ]; then
  _write "$PRE" "$FREE" >/dev/null 2>&1
  PFX="$(mk_tmp "disk-pre-")"
  find "$(dirname "$PFX")" -maxdepth 1 -type f -name "$(basename "$PFX")*" -mtime +0 -delete >/dev/null 2>&1
  exit 0
fi

FLOOR_KB=$(( MK_DISK_MIN_FREE_GB * 1048576 ))
NOW="$(date +%s)"

# _floor_due MARKER GAP -- 0 when below floor and the last message is older than
# GAP seconds (records NOW); above floor it forgets the marker.
_floor_due() {
  local last
  if [ "$MK_DISK_MIN_FREE_GB" -le 0 ] || [ "$FREE" -ge "$FLOOR_KB" ]; then _remove "$1"; return 1; fi
  last="$(_read_int "$1")"
  if [ -n "$last" ] && [ $(( NOW - last )) -lt "$2" ]; then return 1; fi
  [ -e "$1" ] && ! _safe "$1" && return 1
  _write "$1" "$NOW"
  return 0
}

# Session temp size, measured only when a message actually uses it (du over a
# multi-GB scratch tree must not run on every silent command). Relies on the
# mk_temp_init above.
_temp_h() {
  local kb=0
  if [ -n "${MK_TEMP_SESSION_DIR:-}" ] && [ -d "$MK_TEMP_SESSION_DIR" ]; then
    kb="$(du -sk "$MK_TEMP_SESSION_DIR" 2>/dev/null | cut -f1)"
    case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  fi
  mk_human_kb "$kb" || printf '0 MB'
}
FREE_H="$(mk_human_kb "$FREE")" || exit 0

if [ "$EVENT" = "PostToolUse" ] || [ "$EVENT" = "PostToolUseFailure" ]; then
  MSG=""
  BEFORE="$(_read_int "$PRE")"
  _remove "$PRE"
  if [ -n "$BEFORE" ] && [ "$BEFORE" -gt "$FREE" ]; then
    DROP=$(( BEFORE - FREE ))
    if [ "$DROP" -ge $(( MK_DISK_DROP_WARN_GB * 1048576 )) ]; then
      MSG="$(mk_msg DK_DROP "$(mk_human_kb "$DROP")" "$FREE_H" "$(_temp_h)")"
    fi
  fi
  if _floor_due "$(mk_tmp "disk-floorctx-${SESSION}")" 600; then
    M2="$(mk_msg DK_FLOOR_CTX "$FREE_H" "$MK_DISK_MIN_FREE_GB")"
    if [ -n "$MSG" ]; then MSG="$MSG
$M2"; else MSG="$M2"; fi
  fi
  [ -z "$MSG" ] && exit 0
  jq -n --arg e "$EVENT" --arg m "$MSG" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$m}}'
  exit 0
fi

# Stop
_floor_due "$(mk_tmp "disk-floorstop-${SESSION}")" 1800 || exit 0
LEFT="$(_read_int "$(mk_tmp "temp-leftover-${SESSION}")")"
LEFT_H="$(mk_human_kb "${LEFT:-0}")" || LEFT_H="0 MB"
MSG="$(mk_msg DK_FLOOR_STOP "$FREE_H" "$MK_DISK_MIN_FREE_GB" "$(_temp_h)" "$LEFT_H")"
[ -z "$MSG" ] && exit 0
jq -n --arg m "$MSG" '{systemMessage:$m}'
exit 0
