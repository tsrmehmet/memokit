#!/usr/bin/env bash
# SubagentStop hook: stop a subagent from returning while it has left more
# than scratch.agentMaxMB (default 1024) of NEW files in the session's
# scratchpad. Sibling of check-subagent-background.sh (same event, same
# exit-2-with-stderr block, same bounded loop guard); design: the 0.5.0
# scratch and disk hygiene spec, feature 1.
#
# "New" = born at or after the agent's first transcript line (the timestamp of
# line 1 of agent_transcript_path). The scratchpad is session-wide, so entries
# a sibling or the orchestrator made earlier are never charged to this agent;
# entries holding a .memokit-keep marker are exempt (mk_temp_footprint).
#
# The block lists the largest counted entries. A direct scratchpad child born
# during the run is an rm -rf target (the destructive-command guard exempts
# only a single literal absolute direct-child path). An entry counted deeper
# lives inside a PRE-EXISTING dir: it is listed apart, with the instruction
# not to delete the parent.
#
# Loop guard: the counter file (mk_tmp subagent-scratch/<agent_id>) holds a
# plain integer of blocks so far. Blocks while < 3; on the next stop it prints
# the give-up note and lets the agent go. A clean stop or an explicit
# stop_hook_active:false resets it. Fail-open (exit 0) on every error path;
# the only exit 2 is the deliberate block.
# MEMOKIT_SCRATCH_OFF=1 turns the hook off.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "subagent-scratch" "$PAYLOAD"
mk_load_config || exit 0

if [ "${MEMOKIT_SCRATCH_OFF:-0}" = "1" ]; then exit 0; fi

printf '%s' "$PAYLOAD" | jq -e '.' >/dev/null 2>&1 || exit 0

HOOK_EVENT="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)"
AGENT_ID="$(printf '%s' "$PAYLOAD" | jq -r '.agent_id // empty' 2>/dev/null)"
[ -z "$AGENT_ID" ] && exit 0
[ "$HOOK_EVENT" != "SubagentStop" ] && exit 0
AGENT_ID="$(printf '%s' "$AGENT_ID" | tr -c 'A-Za-z0-9_-' _)"

COUNTER_DIR="$(mk_tmp subagent-scratch)"
COUNTER_FILE="$COUNTER_DIR/$AGENT_ID"

# The counter dir sits in a possibly shared temp dir: never follow a symlink
# there and never trust a dir or file that is not ours (same rule as
# _mk_cf_unsafe in lib/careful.sh). Anything unsafe -> fail-open, no counting.
_ss_unsafe() { [ -L "$1" ] || { [ -e "$1" ] && [ ! -O "$1" ]; }; }
_ss_counter_ok() { ! _ss_unsafe "$COUNTER_DIR" && ! _ss_unsafe "$COUNTER_FILE"; }

AGENT_TR="$(printf '%s' "$PAYLOAD" | jq -r '.agent_transcript_path // empty' 2>/dev/null)"
[ -n "$AGENT_TR" ] && [ -f "$AGENT_TR" ] && [ -r "$AGENT_TR" ] || exit 0
FIRST_TS="$(head -n 1 "$AGENT_TR" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)"
[ -n "$FIRST_TS" ] || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/temp.sh
. "$MK_LIB_DIR/temp.sh"
mk_temp_init "$PAYLOAD" || exit 0
START="$(mk_temp_iso_epoch "$FIRST_TS")" || exit 0
FOOT="$(mk_temp_footprint "$START")" || exit 0

# mk_temp_footprint reports an entry deeper than a direct scratchpad child
# only when that child was NOT born during this run (otherwise the child itself
# is the counted entry). Such a deep entry sits inside a pre-existing dir the
# agent must not delete, so it is listed separately, by its own path.
SP="$MK_TEMP_SESSION_DIR/scratchpad"
[ -n "$FOOT" ] || { _ss_counter_ok && rm -f "$COUNTER_FILE" 2>/dev/null; exit 0; }

# Classify every record. Sizes of well-formed records always count toward the
# total (so the gate still blocks); only entries whose path is plain (strict
# charset, short, exists under the scratchpad) may be printed as deletion
# advice. Names with glob chars, whitespace, control chars or quotes, and
# malformed records (a newline/tab in a name splits a record), are only
# summarised, never echoed: they could expand a pattern or inject text.
TOTAL_KB=0
UNUSUAL_N=0
UNUSUAL_KB=0
SAFE=""
TAB="$(printf '\t')"
if mk_temp_has_birth "$SP"; then HAVE_BIRTH=1; else HAVE_BIRTH=0; fi
# Byte-wise charset judgement (no locale ranges, no accented letters).
LC_ALL_SAVED="${LC_ALL-}"; LC_ALL_WAS_SET="${LC_ALL+x}"
export LC_ALL=C
while IFS= read -r REC; do
  [ -n "$REC" ] || continue
  KB="${REC%%"$TAB"*}"
  P="${REC#*"$TAB"}"
  case "$KB" in ''|*[!0-9]*) UNUSUAL_N=$((UNUSUAL_N + 1)); continue ;; esac
  if [ "$P" = "$REC" ]; then UNUSUAL_N=$((UNUSUAL_N + 1)); continue; fi
  case "$P" in "$SP"/?*) ;; *) UNUSUAL_N=$((UNUSUAL_N + 1)); continue ;; esac
  REL="${P#"$SP"/}"
  # Re-verify the record against the filesystem: only an entry born at or
  # after the agent started is the agent's (never trust a line the walk
  # produced for a name it may have misparsed).
  if [ -e "$P" ] || [ -L "$P" ]; then
    BIRTH="$(mk_temp_birth "$P")" || continue
    [ "$BIRTH" -ge "$START" ] || continue
  fi
  TOTAL_KB=$((TOTAL_KB + KB))
  OK=1
  case "$P" in *[!A-Za-z0-9._+@,:%/-]*) OK=0 ;; esac
  case "/$REL/" in */./*|*/../*|*//*) OK=0 ;; esac
  [ "${#REL}" -le 200 ] || OK=0
  { [ -e "$P" ] || [ -L "$P" ]; } || OK=0
  if [ "$OK" -eq 1 ]; then
    SAFE="$SAFE$KB$TAB$P
"
  else
    UNUSUAL_N=$((UNUSUAL_N + 1)); UNUSUAL_KB=$((UNUSUAL_KB + KB))
  fi
done <<EOF3
$FOOT
EOF3
if [ -n "$LC_ALL_WAS_SET" ]; then export LC_ALL="$LC_ALL_SAVED"; else unset LC_ALL; fi
[ "$TOTAL_KB" -gt 0 ] || { _ss_counter_ok && rm -f "$COUNTER_FILE" 2>/dev/null; exit 0; }

LIMIT_MB="${MK_SCRATCH_AGENT_MAX_MB:-1024}"
case "$LIMIT_MB" in ''|*[!0-9]*) exit 0 ;; esac
if [ "$TOTAL_KB" -lt $((LIMIT_MB * 1024)) ]; then
  _ss_counter_ok && rm -f "$COUNTER_FILE" 2>/dev/null
  exit 0
fi

# Over the limit: loop guard.
STOP_HOOK_ACTIVE_FALSE="$(printf '%s' "$PAYLOAD" | jq -r \
  'if (has("stop_hook_active") and (.stop_hook_active == false)) then "true" else "false" end' 2>/dev/null)"
_ss_counter_ok || exit 0
COUNT=0
if [ "$STOP_HOOK_ACTIVE_FALSE" != "true" ]; then
  COUNT="$(cat "$COUNTER_FILE" 2>/dev/null)"
  case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
fi
TOTAL_H="$(mk_human_kb "$TOTAL_KB")" || exit 0
if [ "$COUNT" -ge 3 ]; then
  rm -f "$COUNTER_FILE" 2>/dev/null
  # Log trace only: stderr of an exit-0 hook is not shown to the agent.
  mk_msg SS_SCRATCH_GIVEUP "$TOTAL_H" >&2
  printf '\n' >&2
  exit 0
fi
( umask 077; mkdir -p "$COUNTER_DIR" ) 2>/dev/null || exit 0
_ss_counter_ok && [ ! -L "$COUNTER_DIR" ] || exit 0
CTMP="$( umask 077; mktemp "$COUNTER_DIR/.tmp.XXXXXX" 2>/dev/null )" || exit 0
[ -n "$CTMP" ] || exit 0
if ! printf '%s' "$((COUNT + 1))" > "$CTMP" 2>/dev/null || ! mv -f "$CTMP" "$COUNTER_FILE" 2>/dev/null; then
  rm -f "$CTMP" 2>/dev/null
  exit 0
fi

LIST=""
LIST_PRE=""
LIST_UNV=""
N=0
while IFS="$(printf '\t')" read -r KB P; do
  [ -n "$P" ] || continue
  N=$((N + 1))
  [ "$N" -le 5 ] || break
  H="$(mk_human_kb "$KB")" || H="${KB}K"
  REL="${P#"$SP"/}"
  if [ "$HAVE_BIRTH" -eq 0 ]; then
    LIST_UNV="$LIST_UNV  $H  $P
"
    continue
  fi
  case "$REL" in
    */*) LIST_PRE="$LIST_PRE  $H  $P
" ;;
    *) LIST="$LIST  $H  $P
" ;;
  esac
done <<EOF2
$SAFE
EOF2
LIST="${LIST%
}"
LIST_PRE="${LIST_PRE%
}"
LIST_UNV="${LIST_UNV%
}"

{
  mk_msg SS_SCRATCH_BLOCK "$TOTAL_H" "$LIMIT_MB"
  printf '\n'
  if [ -n "$LIST" ]; then
    mk_msg SS_SCRATCH_RMLIST "$LIST"
    printf '\n'
  fi
  if [ -n "$LIST_UNV" ]; then
    mk_msg SS_SCRATCH_UNVERIFIED "$LIST_UNV"
    printf '\n'
  fi
  if [ -n "$LIST_PRE" ]; then
    mk_msg SS_SCRATCH_PREEXISTING "$LIST_PRE"
    printf '\n'
  fi
  if [ "$UNUSUAL_N" -gt 0 ]; then
    mk_msg SS_SCRATCH_UNUSUAL "$UNUSUAL_N" "$(mk_human_kb "$UNUSUAL_KB")"
    printf '\n'
  fi
} >&2
exit 2
