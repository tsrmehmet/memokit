#!/usr/bin/env bash
# memokit session stats: ONE line for the handoff's verify step.
#   memokit-stats.sh [<transcript>]
# Prints: context at the end (the budget hook's number), total output tokens,
# tool calls with the top 5 tools, PreToolUse hook denies and subagent
# dispatches. No currency. Without an argument it reads this session's
# transcript (mk_tr_locate in hooks/lib/transcript.sh, which records the
# transcript shapes these counts rely on).
# Exit: 0 line printed; 1 transcript missing/unreadable or not parsable;
# 2 bad call. Nothing is written anywhere.
#
# Bounds: the whole file is read once, line by line, by a single jq `reduce`
# whose state is a few numbers plus one counter per distinct tool name, so
# time is linear in the file size and memory does not grow with it (the
# per-message output tokens are summed with the previous id only, which the
# contiguous split records allow).
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/common.sh
. "$SELF_DIR/../../../hooks/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/transcript.sh
. "$MK_LIB_DIR/transcript.sh"

say_err() { mk_msg "$@" >&2; printf '\n' >&2; }

mk_resolve_root "$(jq -nc --arg c "$PWD" '{cwd:$c}' 2>/dev/null || printf '{}')"
if mk_active; then
  mk_load_config || :   # an invalid config still loads its language's messages
else
  mk_load_messages en
fi

[ "$#" -le 1 ] || { say_err ST_USAGE; exit 2; }
T="${1:-}"
if [ -z "$T" ]; then
  # The newest-.jsonl fallback names its pick on stderr (ST_PICKED).
  T="$(mk_tr_locate ST_PICKED)" || { say_err ST_NOT_FOUND; exit 1; }
fi
if [ ! -f "$T" ] || [ ! -r "$T" ]; then say_err ST_NO_FILE "$T"; exit 1; fi

# State: u = last usage object; out = output tokens of finished messages,
# cur/id = the running message (split records repeat one usage: count the id
# once, its largest value); tools = calls per tool name; deny; sub.
# shellcheck disable=SC2016  # jq program text: $r, $o, $id, $n, $b are jq's
PROG='
reduce mk_tr_records as $r (
  {u: null, out: 0, cur: 0, id: null, tools: {}, deny: 0, sub: 0};
  (if $r.message.usage? then .u = $r.message.usage else . end)
  | if $r.type? == "assistant" then
      (($r.message.usage.output_tokens? // 0) | if type == "number" then . else 0 end) as $o
      | (($r.message.id? // null) | if type == "string" then . else null end) as $id
      | (if $id != null and $id == .id then .cur = ([.cur, $o] | max)
         else .out += .cur | .cur = $o | .id = $id end)
      | reduce ($r | mk_tr_tool_uses | (.name? // "?")
                | if type == "string" then . else "?" end) as $n (.;
          .tools[$n] += 1
          | if $n == "Agent" or $n == "Task" then .sub += 1 else . end)
    elif $r.type? == "user" then
      reduce ($r | mk_tr_tool_results | select(mk_tr_hook_deny($r))) as $b (.; .deny += 1)
    else . end
)
| [ (if .u == null then "-" else (.u | try (mk_tr_context | floor | tostring) catch "-") end),
    ((.out + .cur) | floor | tostring),
    ([.tools[]] | add // 0 | tostring),
    (.tools | to_entries | sort_by(-.value, .key) | .[0:5]
     | map("\(.key) \(.value)") | join(", ") | if . == "" then "-" else . end),
    (.deny | tostring),
    (.sub | tostring) ]
| @tsv
'
RES="$(mk_tr_jq "$T" "$PROG" -r 2>/dev/null)" || RES=""
IFS=$'\t' read -r CTX OUT CALLS TOP DENY SUB <<< "$RES"
for n in "$OUT" "$CALLS" "$DENY" "$SUB"; do
  case "$n" in ''|*[!0-9]*) say_err ST_FAILED "$T"; exit 1 ;; esac
done

# 950 -> 950, 23203 -> 23.2k, 140085 -> 140k, 1529500 -> 1.5M (floor, like
# the hook's ~Nk).
fmt_k() {
  local n="$1" unit=1000 sfx=k d
  if [ "$n" -lt 1000 ]; then printf '%s' "$n"; return; fi
  if [ "$n" -ge 1000000 ]; then unit=1000000; sfx=M; fi
  d=$(( (n % unit) / (unit / 10) ))
  if [ "$d" -eq 0 ]; then printf '%s%s' "$(( n / unit ))" "$sfx"; else printf '%s.%s%s' "$(( n / unit ))" "$d" "$sfx"; fi
}
case "$CTX" in ''|*[!0-9]*) CTX_S="$(mk_msg ST_NA)" ;; *) CTX_S="$(fmt_k "$CTX")" ;; esac

mk_msg ST_LINE "$CTX_S" "$(fmt_k "$OUT")" "$CALLS" "$TOP" "$DENY" "$SUB"
printf '\n'
