#!/usr/bin/env bash
# Stop hook: warn when the session context has grown past the working budget.
#
# Why this exists: every turn re-sends the whole context, so a session's total
# input cost grows roughly with the SQUARE of how large the context gets.
# Splitting a long session in two at half the size costs about half as much for
# the same work -- which is only cheap because docs/STATE.md makes re-orientation
# cheap. This hook is the trigger that makes that split actually happen.
#
# Claude Code has no context-threshold event, so this rides on Stop and derives
# usage from the transcript, which records per-message token usage. The user
# checked this by running /context and comparing it against the transcript:
# on 2026-07-26 /context reported 140.1k, and the transcript's last record's
# cache_read_input_tokens was 140085 -- matching within rounding.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "check-context-budget" "$PAYLOAD"
mk_load_config || exit 0

# Empty stdin is the knowledge-health smoke test: stay silent, exit clean.
[ -z "$PAYLOAD" ] && exit 0
[ "${MEMOKIT_CONTEXT_OFF:-0}" = "1" ] && exit 0

TRANSCRIPT="$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)"
[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0

SESSION="$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null)"
# session_id becomes part of a file name below: keep only [A-Za-z0-9_-] so a
# crafted id ("../x", "a/b") cannot point the marker outside $TMPDIR.
SESSION="$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9_-' _)"
[ -z "$SESSION" ] && SESSION="unknown"

# Context size = what was actually sent last turn (input + cache read + cache
# creation of the last usage record; output_tokens lands in the NEXT turn's
# input). Only the tail is scanned -- transcripts reach many MB and this runs
# every turn.
#
# Round 6 merge-gate audit fix (Finding 4, confirmed): this used to be a
# single `jq -s` over the raw tail. A Stop hook races the transcript writer,
# so the last line can be half-written at the exact moment this runs; `jq -s`
# then failed on the whole batch, USED ended up empty and the warning never
# fired. The parsing now lives in lib/transcript.sh (shared with the handoff
# stats and /memokit:learn): line by line, a malformed line is dropped
# instead of poisoning the batch. Its header records the transcript shapes.
# shellcheck source-path=SCRIPTDIR source=lib/transcript.sh
. "$(dirname "$0")/lib/transcript.sh"
USED="$(mk_tr_context_used "$TRANSCRIPT" 500)"

# No usable reading -> stay silent. A false alarm is worse than a missed one.
case "$USED" in ''|null|*[!0-9]*) exit 0 ;; esac

DEFAULT_LIMIT="$MK_CONTEXT_LIMIT"
DEFAULT_STEP=100000

# Both knobs are documented as user-settable (README (Context budget)), so a
# bad value ("abc", empty, negative-looking, or 0 for STEP which would divide
# by zero) must degrade to the default, not crash the hook. A Stop hook that
# exits non-zero blocks stopping and dumps stderr back at the model -- this
# script must never do that regardless of what garbage lands in these two
# variables.
LIMIT="${MEMOKIT_CONTEXT_LIMIT:-$DEFAULT_LIMIT}"
case "$LIMIT" in ''|*[!0-9]*) LIMIT="$DEFAULT_LIMIT" ;; esac

STEP="${MEMOKIT_CONTEXT_STEP:-$DEFAULT_STEP}"
case "$STEP" in ''|*[!0-9]*|0) STEP="$DEFAULT_STEP" ;; esac

[ "$USED" -lt "$LIMIT" ] && exit 0

# Fire once when the budget is crossed, then again every STEP tokens -- so the
# reminder cannot be lost in scrollback, but does not nag on every single turn.
BAND=$(( (USED - LIMIT) / STEP ))
MARKER="$(mk_tmp "context-band-${SESSION}")"
LAST="$(cat "$MARKER" 2>/dev/null || printf '%s' "-1")"
[ "$BAND" = "$LAST" ] && exit 0
printf '%s' "$BAND" > "$MARKER"

USED_K=$(( USED / 1000 ))
LIMIT_K=$(( LIMIT / 1000 ))
# §7.5 (2026-09-29): the model decides the handoff timing itself; the user is
# informed, not asked.
MSG="$(mk_msg CB_AUTONOMOUS "$USED_K" "$LIMIT_K")"

jq -n --arg m "$MSG" '{hookSpecificOutput:{hookEventName:"Stop",additionalContext:$m}}'
exit 0
