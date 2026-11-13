#!/usr/bin/env bash
# memokit session miner for /memokit:learn.
#   memokit-learn.sh mine [<transcript>]
# Prints one JSON object (compact, one line):
#   {"denies":[{"label","count","first"}],      PreToolUse hook denies
#    "errors":[{"tool","count","first"}],       tool errors that are no deny
#    "corrections":[{"user","assistant"}],      user corrections + the reply
#    "repeats":[{"command","count"}]}           identical Bash commands, >= 3
# Without a path it reads this session's transcript (mk_tr_locate in
# hooks/lib/transcript.sh, which records the transcript shapes relied on
# here). It refuses to run in a subagent (CLAUDE_CODE_CHILD_SESSION=1): a
# subagent's shell carries its parent's session id, so it would mine the
# orchestrator's session and not its own.
# Exit: 0 JSON printed; 1 transcript missing/unreadable or not parsable;
# 2 bad call; 3 refused in a subagent. Nothing is written anywhere.
#
# What counts (the stats line in skills/handoff/scripts/memokit-stats.sh
# uses the same hook-deny test, mk_tr_hook_deny):
# - denies: grouped by label = the deny reason's "[TAG-X] word" prefix (e.g.
#   "[DMO-CAREFUL] rm-recursive"), else its "[TAG-X]" tag, else its first
#   sentence (up to 80 chars); first = the first denied call's command (Bash)
#   or path, as the tool_use block gave it.
# - errors: tool_result blocks with is_error that are neither a hook deny nor
#   a permission or user rejection (permissionDecision "reject" of any source,
#   "Permission for this|to use ...", "The user doesn't want to ..."); grouped
#   by tool; first = the first non-blank line of the first error that is not
#   a bare "Exit code N".
# - corrections: a main-session user message (not a tool result, not isMeta,
#   not a sidechain, not a "<...>" command/notification text) whose FIRST line
#   starts with a whole word tr hayır|yanlış|yapma|değil|olmaz|dur or en
#   no|wrong|don't|stop|not that (any case; ı/I and ’ tolerated), paired with
#   the first line of the next assistant text block before the next user
#   message ("" when none). The first 20 are kept.
# - repeats: Bash tool_use commands seen >= 3 times, compared by length plus
#   the first 300 characters.
# Every printed text is clipped to 200 characters.
#
# Bounds: one jq `reduce` over the file, line by line. Its state is the
# pending tool calls (a list, an entry removed when its result arrives, at
# most 200 kept, the oldest dropped first: a call older than that reads as
# tool "?"), one counter per deny label and per tool, at most 20
# corrections, and one entry of at most
# about 300 characters per distinct Bash command -- so memory follows the
# number of distinct commands, not the file size. Regexes run on texts
# clipped to 1000 characters.
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

if [ "${CLAUDE_CODE_CHILD_SESSION:-}" = "1" ]; then say_err LN_SUBAGENT; exit 3; fi
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ "$1" != "mine" ]; then say_err LN_USAGE; exit 2; fi
T="${2:-}"
if [ -z "$T" ]; then
  # The newest-.jsonl fallback names its pick on stderr (LN_PICKED).
  T="$(mk_tr_locate LN_PICKED)" || { say_err LN_NOT_FOUND; exit 1; }
fi
if [ ! -f "$T" ] || [ ! -r "$T" ]; then say_err LN_NO_FILE "$T"; exit 1; fi

# shellcheck disable=SC2016  # jq program text: $r, $b, $id ... are jq's
PROG='
def ln_line($n): (split("\n")[0] // "") | .[0:$n];
def ln_err_line:
  ([split("\n")[] | select(test("\\S")) | select(test("^Exit code [0-9]+$") | not)][0]
   // split("\n")[0] // "") | .[0:200];
def ln_label:
  (sub("^PreToolUse:[^ ]* hook error: *"; "") | split("\n")[0] // "") as $l
  | (($l | capture("^(?<x>\\[[^\\]]{1,40}\\]( [A-Za-z0-9_.-]{1,40}(?=:))?)").x)
     // ($l | capture("^(?<x>.*?)\\. ").x)
     // $l)
  | .[0:80];
def ln_input:
  ((.input? | objects | (.command? // .file_path? // .notebook_path? // .path?
                         // .pattern? // .url?)) // null)
  | if type == "string" then .[0:200] else "" end;
def ln_correction:
  test("^\\s*(hay[ıI]r|yanl[ıI]ş|yapma|değil|olmaz|dur|no|wrong|don[\\x27\\x{2019}]t|stop|not that)($|[^\\p{L}\\p{N}_])"; "i");
def ln_rejected($r):
  ((($r.permissionDecision? | objects | .decision?) // null) == "reject")
  or test("^(Permission (for this|to use)|The user doesn[\\x27\\x{2019}]t want to)");

reduce mk_tr_records as $r (
  {p: [], den: {}, err: {}, cor: [], pend: null, rep: {}};
  if $r.type? == "assistant" then
    reduce ($r | mk_tr_tool_uses) as $b (.;
      (($b.id? // "") | if type == "string" then . else "" end) as $id
      | (($b.name? // "?") | if type == "string" then . else "?" end) as $n
      | (if $id != "" then
           .p += [{i: $id, n: $n, c: ($b | ln_input)}]
           | if (.p | length) > 200 then .p = .p[1:] else . end
         else . end)
      | ((($b.input? | objects | .command?) // null)
         | if type == "string" then . else null end) as $cmd
      | if $n == "Bash" and $cmd != null then
          ("\($cmd | length):\($cmd[0:300])") as $k
          | .rep[$k] = {c: $cmd[0:200], n: ((.rep[$k].n // 0) + 1)}
        else . end)
    | if .pend != null then
        ([$r.message.content? | arrays | .[] | objects | select(.type? == "text")
          | .text? | strings | select(test("\\S"))][0] // null) as $t
        | .pend as $i
        | if $t != null then .cor[$i].assistant = ($t[0:1000] | ln_line(200)) | .pend = null
          else . end
      else . end
  elif $r.type? == "user" then
    if ([$r | mk_tr_tool_results] | length) > 0 then
      reduce ($r | mk_tr_tool_results) as $b (.;
        (($b.tool_use_id? // "") | if type == "string" then . else "" end) as $id
        | ((if $id == "" then null else first(.p[] | select(.i == $id)) end)
           // {n: "?", c: ""}) as $t
        | (if $id != "" then .p |= map(select(.i != $id)) else . end)
        | ($b.content? | mk_tr_head(1000)) as $h
        | if ($b | mk_tr_hook_deny($r)) then
            ($h | ln_label) as $l
            | .den[$l] = {n: ((.den[$l].n // 0) + 1), f: (.den[$l].f // $t.c)}
          elif $b.is_error? == true and (($h | ln_rejected($r)) | not) then
            .err[$t.n] = {n: ((.err[$t.n].n // 0) + 1), f: (.err[$t.n].f // ($h | ln_err_line))}
          else . end)
    elif $r.isMeta? == true or $r.isSidechain? == true then .
    else
      ($r.message.content? | mk_tr_head(1000)) as $u
      | if ($u | test("^\\s*<")) or (($u | test("\\S")) | not) then .
        else
          .pend = null
          | ($u | ln_line(200)) as $l
          | if ($l | ln_correction) and (.cor | length) < 20 then
              .cor += [{user: $l, assistant: ""}] | .pend = ((.cor | length) - 1)
            else . end
        end
    end
  else . end
)
| {denies: ([.den | to_entries[] | {label: .key, count: .value.n, first: .value.f}]
            | sort_by(-.count, .label)),
   errors: ([.err | to_entries[] | {tool: .key, count: .value.n, first: .value.f}]
            | sort_by(-.count, .tool)),
   corrections: .cor,
   repeats: ([.rep[] | select(.n >= 3) | {command: .c, count: .n}]
             | sort_by(-.count, .command))}
'
RES="$(mk_tr_jq "$T" "$PROG" -c 2>/dev/null)" || RES=""
case "$RES" in '{"denies":'*) ;; *) say_err LN_FAILED "$T"; exit 1 ;; esac
printf '%s\n' "$RES"
