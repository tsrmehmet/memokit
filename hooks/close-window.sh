#!/usr/bin/env bash
# PostToolUse / PostToolUseFailure (Bash): closes the change window when a
# command that ran inside it failed. Design: the 0.8 spec, "The change
# window" -> "Close on failure".
#
# guard-destructive.sh writes a running marker (careful-window-running-<TUID>,
# the first line of the command) when it lets a window-covered command pass.
# Claude Code fires ONLY PostToolUseFailure for a non-zero exit (no exit-code
# field) and ONLY PostToolUse for a zero exit. So:
#   - PostToolUseFailure with a marker, whatever the error text (fail closed:
#     a timeout or kill has an unmeasured shape): the payload session's window
#     is closed and the command line is left as the failed reason for the
#     next deny (mk_careful_window_close). A false close costs one cheap
#     re-approval.
#   - PostToolUse: the marker is just removed; the window stays.
# The marker key is built exactly as guard-destructive.sh / check-disk.sh do.
#
# The marker lives under mk_tmp (shared /tmp on Linux), so it is hostile: a
# symlink or a file we do not own is neither read nor removed. This hook
# prints NOTHING, ever, and always exits 0. MEMOKIT_CAREFUL_OFF=1 turns it off.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "close-window" "$PAYLOAD"
mk_load_config || exit 0

[ -z "$PAYLOAD" ] && exit 0
[ "${MEMOKIT_CAREFUL_OFF:-0}" = "1" ] && exit 0
# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$(dirname "$0")/lib/careful.sh" 2>/dev/null || exit 0

EVENT="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)"
case "$EVENT" in PostToolUse|PostToolUseFailure) ;; *) exit 0 ;; esac
[ "$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0

_san() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' _; }
SESSION="$(_san "$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null)")"
[ -z "$SESSION" ] && SESSION="unknown"
TUID="$(_san "$(printf '%s' "$PAYLOAD" | jq -r '.tool_use_id // empty' 2>/dev/null)")"
if [ -z "$TUID" ]; then
  CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  TUID="c-${SESSION}-$(printf '%s' "$CMD" | cksum | cut -d' ' -f1)"
fi

# Markers of commands that never reported back (crash, kill) expire after a
# day; this hook's own prefix only, regular files only (find does not follow
# symlinks).
PFX="$(mk_tmp "careful-window-running-")"
case "$PFX" in
  /?*) find "$(dirname "$PFX")" -maxdepth 1 -type f -name "$(basename "$PFX")*" -mtime +0 -delete >/dev/null 2>&1 ;;
esac

MARKER="$(mk_tmp "careful-window-running-${TUID}")"
case "$MARKER" in /?*) ;; *) exit 0 ;; esac
# Absent, symlinked, foreign or not a regular file: nothing to do (a symlink
# is left alone, never followed).
[ -L "$MARKER" ] && exit 0
[ -f "$MARKER" ] && [ -O "$MARKER" ] || exit 0

LINE=""
IFS= read -r LINE < <(head -c 4096 "$MARKER" 2>/dev/null) || true
rm -f "$MARKER" 2>/dev/null

[ "$EVENT" = "PostToolUseFailure" ] || exit 0

[ -n "$LINE" ] || LINE="(unknown command)"
mk_careful_window_close "$SESSION" "$LINE" >/dev/null 2>&1
exit 0
