#!/usr/bin/env bash
# memokit transcript reader. Sourced after common.sh, never executed.
# bash 3.2 and jq only. Shared by check-context-budget.sh (every Stop, tail
# only), skills/handoff/scripts/memokit-stats.sh (once, whole file) and
# /memokit:learn's miner (once, whole file).
#
# A transcript is JSON Lines, one record per line. Rules every reader keeps:
# - Parse line by line (`jq -nR` + `fromjson?`), never `jq -s` over raw text:
#   a Stop hook races the writer, so the last line can be half-written, and
#   one bad line must be dropped, not poison the batch (the 0.7 Round 6
#   finding of check-context-budget.sh).
# - Only JSON objects are records; every field access is `?`-guarded, so an
#   odd record is skipped instead of aborting the pass.
# - One pass with `reduce`/`last`-style state: memory does not grow with the
#   file (no `[...]` of all records over a whole transcript).
#
# Record shapes (measured 2026-11-12 on 300 real transcripts, Claude Code
# 2.x; tests/fixtures/transcripts/session.jsonl copies the shapes):
# - Only `type:"assistant"` records carry `.message.usage`. One API message is
#   split over several consecutive records (one per content block: thinking,
#   text, each tool_use), all with the same `.message.id` and the SAME usage;
#   per-message sums must count an id once (ids were contiguous in 100 of 100
#   transcripts checked).
# - A tool call is a `.message.content[]` block `{type:"tool_use", id, name,
#   input}` of an assistant record. A subagent dispatch is name "Agent" (older
#   builds: "Task"); SendMessage continues an agent and is not a dispatch.
# - A tool result is a `type:"user"` record whose `.message.content` array
#   holds one `{type:"tool_result", tool_use_id, content, is_error}` block;
#   `content` is a string or an array of `{type:"text", text}` blocks.
# - A PreToolUse hook deny: newer builds put `permissionDecision:{decision:
#   "reject", source:"hook", reasonCode:"hook:PreToolUse"}` on that user
#   record; every build writes the block as `is_error:true` with content
#   starting "PreToolUse:<Tool> hook error: <reason>". Permission-system and
#   auto-mode denies have `source:"config"` and start "Permission for this".
# - Subagents' own records are not in the main transcript; a `type:"progress"`
#   record nests subagent messages under `.data`, which these readers ignore.
#
# Interface:
#   MK_TR_JQ_DEFS                  jq defs, prepended to every program:
#     mk_tr_records                every well-formed object, in file order
#     mk_tr_context                usage object -> context tokens
#     mk_tr_tool_uses              record -> its tool_use blocks
#     mk_tr_tool_results           record -> its tool_result blocks
#     mk_tr_head($n)               result content -> first $n chars of text
#     mk_tr_hook_deny($rec)        tool_result block -> PreToolUse hook deny?
#   mk_tr_jq FILE PROG [jq opts]   run PROG over the whole file (jq -nR)
#   mk_tr_jq_tail FILE N PROG [..] run PROG over the last N lines
#   mk_tr_context_used FILE [N]    context size of the last usage record
#   mk_tr_locate [KEY]             path of this session's transcript

# Context size = what was actually sent last turn. output_tokens is excluded:
# it is not part of the request, it lands in the NEXT turn's input. The
# budget hook's comment records the /context comparison behind this formula.
# shellcheck disable=SC2016  # jq program text: $n and $rec are jq's
MK_TR_JQ_DEFS='
def mk_tr_records: inputs | fromjson? // empty | objects;
def mk_tr_context:
  ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
   + (.cache_creation_input_tokens // 0));
def mk_tr_tool_uses:
  select(.type? == "assistant") | .message.content? | arrays | .[]
  | objects | select(.type? == "tool_use");
def mk_tr_tool_results:
  select(.type? == "user") | .message.content? | arrays | .[]
  | objects | select(.type? == "tool_result");
def mk_tr_head($n):
  if type == "string" then .[0:$n]
  elif type == "array" then ([.[]? | objects | .text? | strings][0] // "") | .[0:$n]
  else "" end;
def mk_tr_hook_deny($rec):
  (($rec.permissionDecision? | objects
    | (.decision? == "reject" and .source? == "hook")) // false)
  or (.is_error? == true
      and (.content? | mk_tr_head(200) | test("^PreToolUse:[^ ]* hook error")));
'

mk_tr_jq() {
  local file="$1" prog="$2"
  shift 2
  jq -nR "$@" "$MK_TR_JQ_DEFS $prog" < "$file"
}

mk_tr_jq_tail() {
  local file="$1" n="$2" prog="$3"
  shift 3
  tail -n "$n" "$file" | jq -nR "$@" "$MK_TR_JQ_DEFS $prog"
}

# Prints the context tokens of the LAST record that carries .message.usage,
# or 0 when there is none (an empty slice included) -- the number the budget
# hook has always compared against its limit. Prints nothing when jq fails.
# With N, only the last N lines are read (the budget hook: N=500).
mk_tr_context_used() {
  # shellcheck disable=SC2016  # jq program text: $r is jq's
  local prog='reduce (mk_tr_records | select(.message.usage?)) as $r (null; $r)
              | .message.usage | mk_tr_context'
  if [ -n "${2:-}" ]; then
    mk_tr_jq_tail "$1" "$2" "$prog" 2>/dev/null
  else
    mk_tr_jq "$1" "$prog" 2>/dev/null
  fi
}

# This session's transcript: <config>/projects/<slug>/<session id>.jsonl,
# where <config> is $CLAUDE_CONFIG_DIR or ~/.claude. The session id comes from
# $CLAUDE_CODE_SESSION_ID (set in the Bash tool environment; a subagent's
# shell carries its parent's id, so callers that must not run in a subagent
# check CLAUDE_CODE_CHILD_SESSION themselves). The id is looked up in every
# project folder, so the slug need not be known. Fallback: the newest .jsonl
# in the folder of MK_ROOT (call mk_resolve_root first), whose slug is the
# path with every character outside [A-Za-z0-9] replaced by "-". With KEY,
# a pick made by that fallback is named on stderr in one line (message KEY,
# the path with control characters dropped), so the user can tell a wrong
# pick; stdout stays the path alone.
mk_tr_locate() {
  local base="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/projects"
  local sid="${CLAUDE_CODE_SESSION_ID:-}" f best="" slug fb=0
  case "$sid" in ''|*[!A-Za-z0-9_-]*) sid="" ;; esac
  if [ -n "$sid" ]; then
    for f in "$base"/*/"$sid".jsonl; do
      [ -f "$f" ] || continue
      if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
    done
  fi
  if [ -z "$best" ] && [ -n "${MK_ROOT:-}" ]; then
    slug="$(printf '%s' "$MK_ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
    for f in "$base/$slug"/*.jsonl; do
      [ -f "$f" ] || continue
      if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best="$f"; fi
    done
    fb=1
  fi
  [ -n "$best" ] || return 1
  if [ "$fb" = 1 ] && [ -n "${1:-}" ]; then
    f="$(printf '%s' "$best" | LC_ALL=C tr -d '\000-\037\177')"
    { mk_msg "$1" "$f" || printf 'memokit: transcript %s' "$f"; printf '\n'; } >&2
  fi
  printf '%s\n' "$best"
}
