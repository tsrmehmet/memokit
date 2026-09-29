#!/usr/bin/env bash
# SubagentStop hook: stop a subagent from returning while background work it
# ITSELF started (a `run_in_background` Bash call, a Bash call auto-moved to
# the background because it ran long, or a Monitor task) is still running.
#
# Why this exists: 3 real incidents traced to the same root cause. A coder
# ran `dotnet test` (Integration/E2E) that ran long enough to be auto-moved
# to the background ("Command did not complete within its <N>s timeout and
# was moved to the background (ID: ...)"). The coder started a Monitor,
# ended its turn with "waiting for the background run...", and returned to
# the orchestrator without evidence -- a report written before the run
# finishes is not a passing test, it is a claim.
#
# --- SESSION SCOPE (measured live) -------------------------------------
# `background_tasks[]` in the SubagentStop payload is SESSION-scoped, not
# agent-scoped: with a `sleep 240` started in the background on the MAIN
# thread, a subagent that called no tools at all still received that task in
# ITS OWN `background_tasks[]`. The Agent tool's own bookkeeping shows up the
# same way (a `type:"subagent"` entry for the very Agent call that launched
# the stopping agent). No entry carries an owner/agent field, so
# `background_tasks[]` alone can never tell "is this task mine".
#
# --- OWNERSHIP: ANCHORED TEXT MATCH AGAINST THE AGENT'S OWN TRANSCRIPT ------
# Cross-reference against the STOPPING AGENT'S OWN transcript
# (`agent_transcript_path`, JSONL). Measured: the structured field a hook
# would prefer, `toolUseResult.backgroundTaskId`, does NOT exist in subagent
# transcripts (0 occurrences across 3 real ones) -- it is main-session-only.
# So text is the only source, read from tool_result blocks ONLY
# (`.message.content[] | select(.type=="tool_result")`) -- a tool_result's
# own `content` is either a plain string or an array of `{type:"text",text}`
# blocks (both shapes measured; for the array shape, the first `type:"text"`
# block is used). A phrase that merely appears in a plain user/assistant
# message that is NOT itself a tool_result (the task prompt, this hook's own
# "Stop hook feedback:" text on the next turn, or an assistant's own
# narration in a `{type:"text"}` block sitting directly in the message, not
# inside a tool_result) is excluded -- measured: widening the scope to scan
# every content block turns a should-be-0 case into a false block.
#
# The match is ANCHORED TO THE START of that tool_result content (phrase 1
# and 3: `startswith`; phrase 2: `startswith` the fixed prefix AND
# `contains` the fixed suffix around the variable timeout number), not a
# substring/regex scan over the whole transcript -- measured: 26 real
# task-start messages across multiple transcripts were ALL at the very start
# of their tool_result content; every OTHER occurrence of one of these
# phrases was a Read/cat/grep/python-repr dump of a transcript FILE quoting
# an old message mid-text (those start with a line-number prefix, `{`, or a
# `NNN content type <class 'str'>` marker -- never with the phrase itself).
# ids are compared with jq `startswith`/`contains` on the literal id string
# from the payload, never a regex over the id, so an id containing `-` or
# `_` works unmodified. Three phrases:
#   1. run_in_background:  starts with "Command running in background with
#      ID: <id>."
#   2. auto-backgrounded:  starts with "Command did not complete within its "
#      AND contains "s timeout and was moved to the background (ID: <id>)"
#      -- the timeout number is NOT hardcoded: measured values include 120,
#      550, 590 and 600 (seconds), so the number itself is a wildcard,
#      matched by splitting the fixed prefix from the fixed suffix.
#   3. Monitor:            starts with "Monitor started (task <id>,"
#
# --- ARG_MAX: THE TRANSCRIPT NEVER GOES THROUGH A COMMAND-LINE ARGUMENT ----
# Measured: passing the transcript's extracted text through `jq --argjson
# contents "$BIG_JSON"` silently breaks on a large transcript -- macOS
# ARG_MAX is 1,048,576 bytes, and synthetic transcripts of 0.9 MB, 1.1 MB and
# 3 MB gave rc=2, 0 and 0 respectively (jq printing "argument list too long"
# on stderr, which this script's own `2>/dev/null` was swallowing). The
# largest real subagent transcript measured on this account today extracts
# to 734,786 bytes of tool_result text -- inside the limit YET, but the
# failure mode is silent and only a few large test outputs away. Fix: only
# the SMALL side -- the ids of currently-running background tasks, straight
# from the payload -- is ever passed via `--argjson`; the transcript itself
# is streamed through stdin in one jq pass (`jq -R 'fromjson? // empty' "$T"
# | jq -n --argjson ids "$RUNNING_IDS" '[inputs | ...] ...'`), which has no
# practical size limit. That pass returns the SUBSET of the running ids it
# can actually prove ownership of. If that jq pass itself exits non-zero (a
# real jq failure, not merely "nothing matched"), this hook prints a
# distinct fail-open notice and exits 0, rather than silently treating a
# broken check as "nothing is running".
#
# --- HARDENING AGAINST ODD TRANSCRIPT/PAYLOAD SHAPES ------------------------
# Measured (jq exit 5 in all three cases, which without the guards below took
# the WHOLE ownership check down with it -- and `background_tasks[]` is
# session-wide, so one bad entry anywhere, even a sibling agent's, disabled
# the hook for every agent in the session, not just the one that hit it):
#   - a transcript LINE that is a bare JSON string (not an object): indexing
#     it with `.message` throws before the trailing `?` on `.content?` ever
#     gets a chance to suppress anything -- `?` only wraps the field access
#     it is directly attached to, not everything before it. Fixed with
#     `| objects` immediately after `inputs`.
#   - a tool_result's extracted text being a NUMBER, not a string (a
#     malformed `{type:"text",text:12345}`): `startswith()` throws on a
#     non-string input. Fixed with `| strings` on the extracted content,
#     which drops anything that is not actually a string (also subsumes the
#     old null-check this replaced).
#   - a running background task whose `id` is a NUMBER: string-concatenating
#     it into a phrase (`"...ID: " + $id + "."`) throws (`string and number
#     cannot be added`). Fixed with `| strings` on the ids pulled from
#     `background_tasks[]`, before they are ever used to build a phrase --
#     an unprovable-by-construction id is simply dropped, not fatal.
# Every place this hook walks into a transcript- or payload-supplied array
# whose element shape it does not fully control (`.background_tasks[]?`, a
# transcript line, a message content array's elements, a tool_result's own
# array-shaped `content`) is guarded this way instead of erroring on it.
#
# --- COUNTER: PER-AGENT, KEYED TO WHICH OWN TASKS ARE ACTUALLY RUNNING ------
# A block (exit 2) buys a subagent up to 3 rounds of continued blocking
# before this hook gives up (a long-lived server or watcher must not trap a
# subagent forever) -- scoped to ONE continuous episode of waiting on the
# SAME own background work, not 3 rounds for the agent's whole lifetime. The
# counter file (COUNTER_DIR/<agent_id>) stores BOTH the count and the SET of
# own running ids it was counted against (`{"count":N,"ids":[...]}`), and
# the count restarts at 0 whenever either:
#   - `stop_hook_active` is an EXPLICIT `false` in the payload. Measured: the
#     FIRST stop of a fresh invocation carries `stop_hook_active:false`;
#     every stop that happens after this hook itself blocked carries `true`,
#     even across several tool calls in between. A MISSING field or `null`
#     is deliberately NOT treated as fresh -- this half is a SYNTHETIC/
#     defensive assumption, not a measured harness behaviour: the real
#     harness has never actually been observed omitting the field, but IF
#     some path ever did, treating that omission as "fresh" would silently
#     defeat the loop guard for it (never counting past 1), so the safer
#     default is to keep counting unless the field is explicitly `false`; OR
#   - the CURRENT own-running id set shares NO id with the set stored at the
#     last block. Reproduced with synthetic payloads (see the "reset-fresh"
#     test case): task A blocks twice (count 1,2) with `stop_hook_active`
#     staying literally `true` throughout, the agent waits it out, then a
#     NEW background task B starts. {A} and {B} share no id, so B correctly
#     restarts at count 1 instead of silently inheriting A's count and
#     reaching the loop guard one block early. An overlapping set (the same
#     task, or the same task plus a new one) keeps counting.
# A clean stop (nothing of the agent's own is running any more) still
# removes the counter file outright -- kept deliberately even though the
# id-set check above would eventually self-correct too. Read from the
# enabled security-guidance plugin's own config (its `hooks.json` declares a
# SubagentStop hook with `asyncRewake:true`), NOT observed live: that plugin
# can apparently wake an agent again after a clean stop, and a resumed agent
# deserves a fully fresh counter rather than a lingering file. The counter
# file is read defensively: missing, unreadable, or corrupt (not valid JSON,
# or the older bare-integer format from an earlier round of this hook) all
# read as `{"count":0,"ids":[]}`, never an error.
#
# --- VISIBLE LAST BLOCK ------------------------------------------------------
# The loop-guard's silent release (the block after count reaches 3 exits 0
# with no message at all) left an agent no signal that it was about to be
# let go while its own task was still unresolved. The block on which COUNT
# reaches exactly 3 (the LAST block before that release) adds one extra line
# naming the still-running own task ids and asking for an explicit
# "UNFINISHED" marker in the final report if the agent still cannot wait it
# out. No time floor is added -- this is purely the 3rd counted block,
# whichever wall-clock moment that happens to be.
#
# --- FAIL-OPEN LIST ----------------------------------------------------------
# Unlike guard-edit.sh / guard-subagent-authority.sh, this is a QUALITY
# gate, not a security boundary: every one of the following makes it exit 0
# (let the agent go) rather than block indefinitely or crash noisily --
# missing jq (via the shared preamble's mk_load_config), an unparsable
# payload, a missing/empty/unreadable transcript (treated as "no ownership
# evidence", which naturally reads as a clean stop), the ownership jq pass
# itself failing (a distinct stderr notice, see ARG_MAX above), the
# per-agent counter directory/file failing to be created or written to, a
# corrupt counter file (treated as count 0), and the loop-guard threshold
# itself. `MEMOKIT_SUBAGENT_BG_JQ` (see ARG_MAX above) is a TESTING-ONLY
# seam, never set in normal operation -- but it is also, in effect, another
# way to turn this whole gate off: pointing it at anything that always exits
# non-zero (or even at a no-op like `true`, which exits 0 with no output and
# would make OWN_PROVEN_JSON silently empty) disables real ownership
# checking. It is not treated as a security control, so this is accepted,
# the same way MEMOKIT_SUBAGENT_BG_OFF is.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "subagent-bg" "$PAYLOAD"
mk_load_config || exit 0

# Emergency kill switch, same convention as MEMOKIT_GUARD_OFF / MEMOKIT_CONTEXT_OFF.
if [ "${MEMOKIT_SUBAGENT_BG_OFF:-0}" = "1" ]; then exit 0; fi

if ! printf '%s' "$PAYLOAD" | jq -e '.' >/dev/null 2>&1; then
  mk_msg BG_BAD_JSON >&2
  printf '\n' >&2
  exit 0
fi

HOOK_EVENT="$(printf '%s' "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null)"
AGENT_ID="$(printf '%s' "$PAYLOAD" | jq -r '.agent_id // empty' 2>/dev/null)"

# No agent_id -> this is not even a subagent payload (defensive; SubagentStop
# should always carry one). Wrong event name -> not our event at all
# (defensive; settings.json only wires this under SubagentStop).
[ -z "$AGENT_ID" ] && exit 0
[ "$HOOK_EVENT" != "SubagentStop" ] && exit 0

# agent_id becomes a file name inside COUNTER_DIR: keep only [A-Za-z0-9_-]
# so a crafted id ("../x") cannot write outside it.
AGENT_ID="$(printf '%s' "$AGENT_ID" | tr -c 'A-Za-z0-9_-' _)"
COUNTER_DIR="$(mk_tmp subagent-bg)"
# ${AGENT_ID:-...} fallback: AGENT_ID is already known non-empty at this
# point (checked above) in normal operation -- this only matters if a
# future edit ever removes that check, so a blank id can never turn this
# into "$COUNTER_DIR/" (an existing DIRECTORY path, not a file), which would
# make every later write to it fail with "Is a directory" for reasons
# entirely unrelated to whatever is actually being tested/debugged.
COUNTER_FILE="$COUNTER_DIR/${AGENT_ID:-_no_agent_id_}"

# --- ALL_RUNNING_IDS: ids of every "running" background_tasks[] entry, no
# ownership check yet. This is the SMALL side, straight from the payload --
# safe to pass via --argjson regardless of transcript size (see ARG_MAX
# above). `objects` drops any non-object element instead of throwing on it
# (see HARDENING above).
ALL_RUNNING_IDS_JSON="$(printf '%s' "$PAYLOAD" | jq -c \
  '[.background_tasks[]? | objects | select(.status == "running") | .id | strings]' 2>/dev/null)"
case "$ALL_RUNNING_IDS_JSON" in ''|null) ALL_RUNNING_IDS_JSON='[]' ;; esac

ALL_RUNNING_COUNT="$(printf '%s' "$ALL_RUNNING_IDS_JSON" | jq 'length' 2>/dev/null)"
case "$ALL_RUNNING_COUNT" in ''|*[!0-9]*) ALL_RUNNING_COUNT=0 ;; esac

# Nothing is running at all (own or foreign) -> a clean stop regardless of
# ownership; skip ever touching the transcript.
if [ "$ALL_RUNNING_COUNT" -eq 0 ]; then
  rm -f "$COUNTER_FILE" 2>/dev/null
  exit 0
fi

# --- OWN_PROVEN: the subset of ALL_RUNNING_IDS this agent's OWN transcript
# proves it started. The transcript is streamed through stdin (`inputs`),
# NEVER passed as a jq argument -- see ARG_MAX above.
TRANSCRIPT_PATH="$(printf '%s' "$PAYLOAD" | jq -r '.agent_transcript_path // empty' 2>/dev/null)"

OWN_PROVEN_JSON='[]'
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  # Testing-only escape hatch: overrides the jq binary used for JUST the
  # ownership computation below (nowhere else in this script), so a test can
  # inject a deliberately-failing stub to exercise the OWNERSHIP_RC
  # fail-open branch. After the `objects`/`strings` hardening below, no real
  # transcript/payload shape this hook's own tests could construct still
  # makes this jq pass fail -- this variable exists so that branch can still
  # be tested at all. Defaults to plain `jq`; never set in normal operation.
  JQ_OWNERSHIP="${MEMOKIT_SUBAGENT_BG_JQ:-jq}"

  # Transcript is JSONL (one JSON object per line), not one JSON document --
  # `fromjson? // empty` drops any single malformed/in-progress line instead
  # of poisoning the whole pass (same pattern as check-context-budget.sh).
  # `objects` right after `inputs` guards against a transcript LINE that is
  # itself a bare non-object (a bare JSON string throws on `.message`
  # before `.content?`'s own `?` can ever suppress it). `objects` also
  # guards the message content array's own elements and a tool_result's
  # array-shaped `content` the same way. `strings` on the extracted content
  # drops anything that is not actually a string (a malformed
  # `{type:"text",text:12345}`; `startswith` throws on a non-string input;
  # this also subsumes the old null-check it replaced). For an array-shaped
  # tool_result `content`, only the FIRST `type:"text"` block is kept
  # (measured, see OWNERSHIP above).
  # shellcheck disable=SC2016 # intentional: this is jq's own $id/$contents/
  # $ids syntax, single-quoted so the SHELL never expands it -- only flagged
  # here (not on the other single-quoted jq scripts below) because the
  # command name itself is a variable ("$JQ_OWNERSHIP") rather than a literal.
  OWN_PROVEN_JSON="$(jq -R 'fromjson? // empty' "$TRANSCRIPT_PATH" 2>/dev/null | "$JQ_OWNERSHIP" -n --argjson ids "$ALL_RUNNING_IDS_JSON" '
    [ inputs
      | objects
      | .message.content? // empty
      | select(type == "array")
      | .[]
      | objects
      | select(.type == "tool_result")
      | .content
      | if type == "string" then .
        elif type == "array" then ([.[] | objects | select(.type == "text") | .text] | first)
        else empty end
      | strings
    ] as $contents
    | $ids
    | map(select(
        . as $id
        | any($contents[];
            startswith("Command running in background with ID: " + $id + ".")
            or (startswith("Command did not complete within its ")
                and contains("s timeout and was moved to the background (ID: " + $id + ")"))
            or startswith("Monitor started (task " + $id + ",")
          )
      ))
  ' 2>/dev/null)"
  OWNERSHIP_RC=$?
  if [ "$OWNERSHIP_RC" -ne 0 ]; then
    mk_msg BG_OWNERSHIP_FAILED "$OWNERSHIP_RC" >&2
    printf '\n' >&2
    exit 0
  fi
  case "$OWN_PROVEN_JSON" in ''|null) OWN_PROVEN_JSON='[]' ;; esac
fi

# --- RUNNING: the full background_tasks[] objects (id/type/command/...) for
# every id that is both currently "running" AND proven own.
RUNNING="$(printf '%s' "$PAYLOAD" | jq -c --argjson own "$OWN_PROVEN_JSON" '
  [ .background_tasks[]?
    | objects
    | select(.status == "running")
    | select(.id as $id | $own | index($id))
  ]
' 2>/dev/null)"
case "$RUNNING" in ''|null) RUNNING='[]' ;; esac

RUNNING_COUNT="$(printf '%s' "$RUNNING" | jq 'length' 2>/dev/null)"
case "$RUNNING_COUNT" in ''|*[!0-9]*) RUNNING_COUNT=0 ;; esac

# Clean stop: something was running, but none of it provably this agent's
# own. Reset the block counter so a LATER round of background work is not
# silently allowed through on borrowed budget from an earlier round.
if [ "$RUNNING_COUNT" -eq 0 ]; then
  rm -f "$COUNTER_FILE" 2>/dev/null
  exit 0
fi

# Fail-open: if the counter directory cannot even be created, this agent's
# block/loop-guard state can never be persisted -- exit 0 rather than either
# silently re-block forever (COUNT stuck at "unknown, assume 0" every single
# call) or crash on the write below.
if ! mkdir -p "$COUNTER_DIR" 2>/dev/null; then
  mk_msg BG_COUNTER_DIR_FAILED "$COUNTER_DIR" >&2
  printf '\n' >&2
  exit 0
fi

# --- reset decision: EXPLICIT stop_hook_active:false, OR the running-own id
# set sharing nothing with the set stored at the last block (see COUNTER
# above for both, measured/reproduced separately).
STOP_HOOK_ACTIVE_FALSE="$(printf '%s' "$PAYLOAD" | jq -r \
  'if (has("stop_hook_active") and (.stop_hook_active == false)) then "true" else "false" end' 2>/dev/null)"

CURRENT_IDS_JSON="$(printf '%s' "$RUNNING" | jq -c '[.[].id]' 2>/dev/null)"
case "$CURRENT_IDS_JSON" in ''|null) CURRENT_IDS_JSON='[]' ;; esac

# Counter file is JSON: {"count":N,"ids":[...]}. Any read/parse problem
# (missing file, unreadable, corrupt content, or the older bare-integer
# format from an earlier round of this hook) reads as count 0 / empty ids --
# never an error.
STORED_RAW="$(cat "$COUNTER_FILE" 2>/dev/null)"
STORED_COUNT="$(printf '%s' "$STORED_RAW" | jq -r '(.count // 0) | if type == "number" then . else 0 end' 2>/dev/null)"
case "$STORED_COUNT" in ''|*[!0-9]*) STORED_COUNT=0 ;; esac
STORED_IDS_JSON="$(printf '%s' "$STORED_RAW" | jq -c '(.ids // []) | if type == "array" then . else [] end' 2>/dev/null)"
case "$STORED_IDS_JSON" in ''|null) STORED_IDS_JSON='[]' ;; esac

OVERLAP="$(jq -n --argjson a "$CURRENT_IDS_JSON" --argjson b "$STORED_IDS_JSON" \
  'any($a[]; . as $x | $b | index($x))' 2>/dev/null)"

if [ "$STOP_HOOK_ACTIVE_FALSE" = "true" ] || [ "$OVERLAP" != "true" ]; then
  COUNT=0
else
  COUNT="$STORED_COUNT"
fi
COUNT=$((COUNT + 1))

COUNTER_JSON="$(jq -n --argjson count "$COUNT" --argjson ids "$CURRENT_IDS_JSON" '{count:$count, ids:$ids}' 2>/dev/null)"

# Fail-open: if the counter cannot be built or written (e.g. an unwritable
# TMPDIR), this agent's state can never be persisted -- exit 0 BEFORE ever
# constructing or printing the block message.
if [ -z "$COUNTER_JSON" ]; then
  mk_msg BG_COUNTER_DATA_FAILED >&2
  printf '\n' >&2
  exit 0
fi
if ! printf '%s' "$COUNTER_JSON" > "$COUNTER_FILE" 2>/dev/null; then
  mk_msg BG_COUNTER_WRITE_FAILED "$COUNTER_FILE" >&2
  printf '\n' >&2
  exit 0
fi

# Loop guard: a server/watcher that legitimately never ends (or a subagent
# that never manages to wait it out) must not be blocked from returning
# forever.
if [ "$COUNT" -gt 3 ]; then
  exit 0
fi

TASK_LINES="$(printf '%s' "$RUNNING" | jq -r \
  '.[] | "- \(.id) (\(.type)): \((.command // .description // "") | .[0:120])"' 2>/dev/null)"

{
  mk_msg BG_BLOCK "$TASK_LINES"
  printf '\n'
  if [ "$COUNT" -eq 3 ]; then
    UNFINISHED_IDS="$(printf '%s' "$RUNNING" | jq -r '[.[].id] | join(", ")' 2>/dev/null)"
    mk_msg BG_LAST_BLOCK "$UNFINISHED_IDS"
    printf '\n'
  fi
} >&2

exit 2
