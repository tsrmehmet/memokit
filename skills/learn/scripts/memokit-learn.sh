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
# - corrections: a human message (a user record or a queued_command
#   attachment; with `origin` only kind "human", without it not isMeta; never a
#   sidechain or a "<...>" notification text). Text = its text blocks joined,
#   2000 chars; pasted_content, [Image..], quoted .png/.jpg/.pdf paths and
#   fenced code are removed, İ is read as i for matching only. One jq match per message against the
#   tr and en correction patterns (sentence start or anywhere, letter
#   boundaries); `user` = the sentence that matched (<= 200 chars), paired
#   with the first line of the next assistant text block before the next
#   human message ("" when none). The first 20 are kept.
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
# clipped to 1000 characters (corrections: 2000, see above).
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
def ln_clean:
  .[0:2000]
  | gsub("<pasted_content[^>]*>[\\s\\S]*?</pasted_content[^>]*>"; " ")
  | gsub("\\[Image[^\\]]*\\]"; " ")
  | gsub("\\x27[^\\x27\\n]*\\.(png|jpe?g|gif|pdf|webp)\\x27"; " "; "i")
  | gsub("```[\\s\\S]*?```"; " ");
def ln_w: "(?<!\\p{L})";
def ln_b: "(?!\\p{L})";
def ln_s: "(?:^|[.!?\\n]\\s*|,\\s*)";
def ln_re:
  ln_w as $w | ln_b as $b | ln_s as $s
  | [ $s + "(hay[ıi]r|yanl[ıi]ş(?!\\s+(yok|m[ıi])" + $b + ")|dur|yapma|vazge[çc]|iptal et|olmaz)" + $b,
      "yanl[ıi]ş\\s+(yap[ıi]lm[ıi]ş|yaz[ıi]lm[ıi]ş|yapt[ıi]n|yazd[ıi]n|anlad[ıi]n|anlam[ıi]şs[ıi]n|olmuş|dosya|yer)" + $b,
      "\\p{L}\\s+(bence\\s+)?gerek\\s+yok" + $b,
      "beğenme(dim|diğim|dik|diğimiz)" + $b,
      $w + "\\p{L}*(istemiştim|söylemiştim|belirtmiştim|demiştim|sormuştum)" + $b,
      $w + "zaten\\s+(\\p{L}+\\s+){0,3}?\\p{L}+m[ıiuü]şt[ıiuü]m" + $b,
      $w + "unutma(y[ıi]n)?" + $b,
      "m[ıiuü]şs[ıiuü]n" + $b + "[^.?!\\n]{0,40}?" + $w + "(ama|fakat|neden|niye)" + $b,
      $w + "(ama|fakat)\\s[^.?!\\n]{0,40}?m[ıiuü]şs[ıiuü]n" + $b,
      $w + "(neden|niye|niçin)\\s[^.?!\\n]{0,60}?(\\p{L}(d[ıiuü]n|t[ıiuü]n|[ıiuü]yorsun|m[ae]d[ıi]n|m[ıi]yorsun)" + $b + "|(hala|hâlâ|sürekli|bu kadar))",
      $w + "(öyle|kabul|doğru)\\s+değil" + $b,
      $w + "(istemedim|demedim|söylemedim)" + $b,
      $w + "geri\\s+al" + $b,
      $w + "(hiç|güzel|iyi|doğru)\\s+olmam[ıi]ş" + $b,
      $s + "((no|nope|stop)(?=\\s*([,.!]|$))|wrong|don[\\x27\\x{2019}]t|do not|not that|that[\\x27\\x{2019}]s not|undo|revert)" + $b,
      $w + "(i (said|told you|asked you)|why did you|you (broke|deleted|removed|ignored)|that[\\x27\\x{2019}]s wrong|not what i (asked|wanted|meant))" + $b
    ] | join("|");
# The message text of a human record, or null when the record is not one:
# a user record or a queued_command attachment; with origin only kind
# "human", without it (older transcripts) not isMeta.
def ln_text($r):
  (if $r.type? == "attachment" then
     (if ((($r.attachment? | objects | .type?) // null) == "queued_command") then $r.attachment.prompt? else null end)
   else $r.message?.content? end) as $c
  | (($r.attachment? | objects | .origin?) // $r.origin?) as $o
  | if ($r.isSidechain? == true) or ($r.isMeta? == true) then null
    elif $o != null and ((($o | objects | .kind?) // null) != "human") then null
    elif $o == null and ($r.isCompactSummary? == true) then null
    else
      (if ($c | type) == "string" then $c
       elif ($c | type) == "array" then [$c[]? | objects | select(.type? == "text") | .text? | strings] | join("\n")
       else null end)
    end;
# The sentence around the first match, at most 200 chars, or null.
def ln_hit($re):
  ln_clean as $c
  | ($c | gsub("İ"; "i")) as $t
  | ([$t | match($re; "i")][0]) as $x
  | if $x == null then null
    else
      ($c[$x.offset:] | capture("^(?<l>[.!?,\\s]*)").l | length) as $lead
      | ($x.offset + $lead) as $st
      | (($c[0:$st] | sub("^[\\s\\S]*[.!?\\n]\\s*"; "")) as $pre
         | ($c[$st:] | capture("^(?<s>[^.!?\\n]*[.!?]?)").s) as $post
         | ($pre + $post) | sub("^\\s+"; "") | sub("\\s+$"; "") | .[0:200])
    end;
def ln_rejected($r):
  ((($r.permissionDecision? | objects | .decision?) // null) == "reject")
  or test("^(Permission (for this|to use)|The user doesn[\\x27\\x{2019}]t want to)");

ln_re as $re
| reduce mk_tr_records as $r (
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
  elif $r.type? == "user" or $r.type? == "attachment" then
    if $r.type? == "user" and ([$r | mk_tr_tool_results] | length) > 0 then
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
    else
      ln_text($r) as $u
      | if $u == null or ($u | test("^\\s*<")) or (($u | test("\\S")) | not) then .
        else
          .pend = null
          | ($u | ln_hit($re)) as $l
          | if $l != null and (.cor | length) < 20 then
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
