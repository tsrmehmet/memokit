#!/usr/bin/env bats
# 0.8.1 Part C goals 1-3: /memokit:learn and its miner
# skills/learn/scripts/memokit-learn.sh (mine <transcript>).
load helpers

FX="$MK_REPO/tests/fixtures/transcripts"
LEARN="$MK_REPO/skills/learn/scripts/memokit-learn.sh"
SKILL="$MK_REPO/skills/learn/SKILL.md"
# learn.jsonl, counted by hand:
# - hook denies: "[DMO-CAREFUL] rm-recursive" twice (one permissionDecision
#   source "hook", one older text-only), first command "rm -rf build"; the
#   untagged guard deny once, labelled by its first sentence, first = the
#   Write's file path. The auto-mode deny, the user's rejection and a quoted
#   "hook error" inside a log are not hook denies.
# - tool errors: Bash 3 (two test runs, the log one), first error line
#   "FAIL demo.test.js" (an "Exit code N" line is skipped); Read 1. The
#   auto-mode deny and the user's rejection are not errors.
# - corrections: tr "hayır" (thinking record skipped, first text line taken),
#   en "Don't" in a text-block array (a tool_use-only record skipped),
#   "YANLIŞ" answered by nothing (the next user message comes first), "stop".
#   "nothing", "durum", the isMeta and <command> records, the progress record
#   and the sidechain record are not corrections.
# - repeats: "git status" 3 (the progress record's nested call not counted),
#   "npm test" 3; "ls" 2 is below the threshold.
EXPECT='{"denies":[{"label":"[DMO-CAREFUL] rm-recursive","count":2,"first":"rm -rf build"},{"label":"Writing under src is blocked in the main session (WORKING-MODEL.md §1)","count":1,"first":"/work/demo/src/a.js"}],"errors":[{"tool":"Bash","count":3,"first":"FAIL demo.test.js"},{"tool":"Read","count":1,"first":"File does not exist."}],"corrections":[{"user":"hayır, önce testleri çalıştır","assistant":"Haklısın, önce testleri çalıştırıyorum."},{"user":"Don'"'"'t push yet","assistant":"OK, not pushing."},{"user":"YANLIŞ dosya","assistant":""},{"user":"stop","assistant":"Stopped."}],"repeats":[{"command":"git status","count":3},{"command":"npm test","count":3}]}'

# Runs the miner from a directory without memokit config (English messages).
learn_plain() {
  local d; d="$(mktemp -d "${MK_FIXTMP}/mkplain.XXXXXX")"
  run env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_CHILD_SESSION "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$d" "$MK_BASH" "$LEARN" "$@"
}
# A one-message-per-line transcript: user text, then an assistant text reply.
pair() {
  jq -nc --arg u "$1" '{type:"user",isSidechain:false,message:{role:"user",content:$u}}'
  jq -nc --arg a "$2" '{type:"assistant",isSidechain:false,message:{id:"m",role:"assistant",content:[{type:"text",text:$a}]}}'
}
line_of() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1; }

@test "mine: denies, errors, corrections and repeats from the fixture" {
  learn_plain mine "$FX/learn.jsonl"
  [ "$status" -eq 0 ]
  got="$(printf '%s' "$output" | jq -cS .)"
  want="$(printf '%s' "$EXPECT" | jq -cS .)"
  [ "$got" = "$want" ] || { echo "got:  $got"; echo "want: $want"; false; }
}
@test "mine: denies use the same hook-deny test as the stats line" {
  learn_plain mine "$FX/session.jsonl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.denies[] | [.label, .count, .first]]')" = '[["[DMO-CAREFUL] rm-recursive",1,"rm -rf demo-dir"],["demo guard text.",1,"echo x > src/a"]]' ] || { echo "got: $output"; false; }
  [ "$(printf '%s' "$output" | jq '[.denies[].count] | add')" = "2" ]
  grep -qF 'mk_tr_hook_deny' "$LEARN"
}
@test "mine: every tr and en correction prefix of the spec counts, with the following assistant line" {
  t="$BATS_TEST_TMPDIR/c.jsonl"; : > "$t"
  i=0
  for p in 'hayır' 'yanlış' 'yapma' 'değil' 'olmaz' 'dur' 'no' 'wrong' "don't" 'stop' 'not that'; do
    i=$((i + 1)); pair "$p demo $i" "ack $i" >> "$t"
  done
  learn_plain mine "$t"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.corrections | length')" = "11" ] || { echo "got: $output"; false; }
  [ "$(printf '%s' "$output" | jq -c '.corrections[2]')" = '{"user":"yapma demo 3","assistant":"ack 3"}' ]
  [ "$(printf '%s' "$output" | jq -c '.corrections[10]')" = '{"user":"not that demo 11","assistant":"ack 11"}' ]
}
@test "mine: the prefix is a whole word at the start of the first line, any case" {
  t="$BATS_TEST_TMPDIR/n.jsonl"; : > "$t"
  for p in 'nothing to add' 'durum nedir' 'now run it' 'noted' 'stopwatch demo' 'not this one' 'değildi' 'wrongly placed' 'yapmalı mıyız' 'ok\nno' 'please stop'; do
    pair "$(printf "$p")" "ack" >> "$t"
  done
  for p in 'No, the other one' 'Stop.' 'Hayır!' 'Not that file' 'DUR' '  wrong file' 'Don’t touch it'; do
    pair "$p" "ack" >> "$t"
  done
  learn_plain mine "$t"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.corrections[].user]')" = '["No, the other one","Stop.","Hayır!","Not that file","DUR","  wrong file","Don’t touch it"]' ] || { echo "got: $output"; false; }
}
@test "mine: a Bash command run three identical times is a repeat, twice is not" {
  t="$BATS_TEST_TMPDIR/r.jsonl"; : > "$t"
  for c in 'make a' 'make a' 'make a' 'make b' 'make b' 'make a '; do
    jq -nc --arg c "$c" '{type:"assistant",message:{id:"m",content:[{type:"tool_use",id:"x",name:"Bash",input:{command:$c}}]}}' >> "$t"
  done
  jq -nc '{type:"assistant",message:{id:"m",content:[{type:"tool_use",id:"y",name:"Grep",input:{pattern:"make b"}}]}}' >> "$t"
  learn_plain mine "$t"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .repeats)" = '[{"command":"make a","count":3}]' ] || { echo "got: $output"; false; }
}
# Pending-call shapes: tool_use <id> <name> <command> [<message id>], result <id> <text> [hook].
tu() { jq -nc --arg i "$1" --arg n "$2" --arg c "$3" --arg m "${4-}" '{type:"assistant",message:({content:[{type:"tool_use",id:$i,name:$n,input:{command:$c}}]} + (if $m == "" then {} else {id:$m} end))}'; }
said() { jq -nc --arg m "${2-}" --arg t "$1" '{type:"assistant",message:({content:[{type:"text",text:$t}]} + (if $m == "" then {} else {id:$m} end))}'; }
res() { jq -nc --arg i "$1" --arg t "$2" '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:$i,content:$t,is_error:true}]}}'; }
@test "mine: a result after a later assistant message keeps its tool and command (with and without message ids)" {
  for m in with without; do
    t="$BATS_TEST_TMPDIR/p-$m.jsonl"
    if [ "$m" = with ]; then a=m1; b=m2; c=m3; d=m4; else a=; b=; c=; d=; fi
    { tu t1 Bash 'make x' "$a"; said 'working' "$b"; res t1 'boom'
      tu t2 Bash 'rm -rf out' "$c"; said 'next' "$d"; res t2 'PreToolUse:Bash hook error: [DMO-CAREFUL] rm-recursive: demo.'; } > "$t"
    learn_plain mine "$t"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .errors)" = '[{"tool":"Bash","count":1,"first":"boom"}]' ] || { echo "$m got: $output"; false; }
    [ "$(printf '%s' "$output" | jq -c .denies)" = '[{"label":"[DMO-CAREFUL] rm-recursive","count":1,"first":"rm -rf out"}]' ] || { echo "$m got: $output"; false; }
  done
}
@test "mine: a result removes its pending call; at most 200 calls wait, the oldest goes first" {
  t="$BATS_TEST_TMPDIR/cap.jsonl"; : > "$t"
  i=0; while [ "$i" -lt 201 ]; do i=$((i + 1)); tu "c$i" Read "f$i" "m$i" >> "$t"; done
  { res c1 'lost'; res c2 'kept'; res c2 'again'; } >> "$t"
  learn_plain mine "$t"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .errors)" = '[{"tool":"?","count":2,"first":"lost"},{"tool":"Read","count":1,"first":"kept"}]' ] || { echo "got: $output"; false; }
}
@test "mine: an empty transcript gives four empty lists" {
  learn_plain mine "$FX/empty.jsonl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -cS .)" = '{"corrections":[],"denies":[],"errors":[],"repeats":[]}' ]
}
@test "mine: long texts are clipped" {
  t="$BATS_TEST_TMPDIR/l.jsonl"
  long="$(printf 'x%.0s' $(seq 1 500))"
  pair "no $long" "$long" > "$t"
  for i in 1 2 3; do
    jq -nc --arg c "echo $long" '{type:"assistant",message:{id:"m",content:[{type:"tool_use",id:"x",name:"Bash",input:{command:$c}}]}}' >> "$t"
  done
  learn_plain mine "$t"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.corrections[0].user | length')" = "200" ]
  [ "$(printf '%s' "$output" | jq '.corrections[0].assistant | length')" = "200" ]
  [ "$(printf '%s' "$output" | jq '.repeats[0] | [(.command | length), .count] | join(",")')" = '"200,3"' ]
}
@test "mine: refuses to run in a subagent (CLAUDE_CODE_CHILD_SESSION=1)" {
  d="$(mktemp -d "${MK_FIXTMP}/mkplain.XXXXXX")"
  run env -u CLAUDE_PROJECT_DIR CLAUDE_CODE_CHILD_SESSION=1 "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$d" "$MK_BASH" "$LEARN" mine "$FX/learn.jsonl"
  [ "$status" -eq 3 ]
  printf '%s' "$output" | grep -qF 'subagent'
  lacks "$output" 'denies'
  mk_project
  run env CLAUDE_CODE_CHILD_SESSION=1 "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$LEARN" mine "$FX/learn.jsonl"
  [ "$status" -eq 3 ]
  printf '%s' "$output" | grep -qF '[DMO] '
  printf '%s' "$output" | grep -qF 'alt ajan'
}
@test "mine: without a path it reads this session's transcript, newest .jsonl as fallback" {
  mk_project
  cfg="$BATS_TEST_TMPDIR/cfgdir"
  slug="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$cfg/projects/other-project" "$cfg/projects/$slug"
  cp "$FX/learn.jsonl" "$cfg/projects/other-project/sid-123.jsonl"
  cp "$FX/empty.jsonl" "$cfg/projects/$slug/older.jsonl"
  run env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-123 "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$LEARN" mine
  [ "$status" -eq 0 ]; [ "$(printf '%s' "$output" | jq '.repeats | length')" = "2" ]
  touch -t 202001010000 "$cfg/projects/$slug/older.jsonl"
  cp "$FX/learn.jsonl" "$cfg/projects/$slug/newer.jsonl"
  run env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@" 2>/dev/null' x "$PROJ" "$MK_BASH" "$LEARN" mine
  [ "$status" -eq 0 ]; [ "$(printf '%s' "$output" | jq '.corrections | length')" = "4" ]
  rm "$cfg/projects/$slug/newer.jsonl"
  run env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@" 2>/dev/null' x "$PROJ" "$MK_BASH" "$LEARN" mine
  [ "$status" -eq 0 ]; [ "$(printf '%s' "$output" | jq -cS .)" = '{"corrections":[],"denies":[],"errors":[],"repeats":[]}' ]
  rm "$cfg/projects/$slug/older.jsonl"
  run env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$LEARN" mine
  [ "$status" -eq 1 ]
  lacks "$output" 'denies'
}
@test "mine: the newest-.jsonl fallback names its pick on stderr, one line; the session-id pick is silent" {
  mk_project
  local cfg slug errf out
  cfg="$BATS_TEST_TMPDIR/cfgdir"; errf="$BATS_TEST_TMPDIR/err"
  slug="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$cfg/projects/other-project" "$cfg/projects/$slug"
  cp "$FX/learn.jsonl" "$cfg/projects/other-project/sid-123.jsonl"
  cp "$FX/learn.jsonl" "$cfg/projects/$slug/newer.jsonl"
  out="$(env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-123 "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$LEARN" mine 2>"$errf")"
  [ "$(printf '%s' "$out" | jq '.repeats | length')" = "2" ]
  [ ! -s "$errf" ] || { echo "stderr on the session-id pick: $(cat "$errf")"; false; }
  out="$(env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$LEARN" mine 2>"$errf")"
  [ "$(printf '%s' "$out" | jq '.repeats | length')" = "2" ]
  lacks "$out" 'newer.jsonl'
  [ "$(wc -l < "$errf" | tr -d ' ')" = 1 ] || { echo "stderr: $(cat "$errf")"; false; }
  grep -qF "$cfg/projects/$slug/newer.jsonl" "$errf" || { echo "stderr: $(cat "$errf")"; false; }
  grep -qF "bu oturumun transcript'i bulunamadı" "$errf" || { echo "stderr: $(cat "$errf")"; false; }
  grep -qF 'Learn' "$errf"
  # English wording too
  printf '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$LEARN" mine >/dev/null 2>"$errf"
  grep -qF 'no transcript found for this session; mined the newest one of this project instead' "$errf" || { echo "stderr: $(cat "$errf")"; false; }
}
@test "mine: a missing transcript fails; a bad call prints the usage" {
  learn_plain mine "$BATS_TEST_TMPDIR/nope.jsonl"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'nope.jsonl'
  lacks "$output" 'denies'
  learn_plain
  [ "$status" -eq 2 ]; printf '%s' "$output" | grep -qF 'usage: memokit-learn.sh mine'
  learn_plain list
  [ "$status" -eq 2 ]
  learn_plain mine a b
  [ "$status" -eq 2 ]
}
@test "mine: a 4 MB transcript in one pass within a time bound" {
  big="$BATS_TEST_TMPDIR/big.jsonl"
  # The fixture's 48 complete lines, 400 copies.
  awk 'NR==FNR { if (FNR < 49) l[n++] = $0; next } END { for (i = 0; i < 400; i++) for (j = 0; j < n; j++) print l[j] }' \
    "$FX/learn.jsonl" /dev/null > "$big"
  start=$(date +%s)
  learn_plain mine "$big"
  took=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.denies[0].count, .errors[0].count, (.corrections | length), .repeats[0].count]')" = '[800,1200,20,1200]' ] || { echo "got: $output"; false; }
  [ "$took" -le 20 ] || { echo "took ${took}s"; false; }
}

# --- skill text ---------------------------------------------------------
@test "skill: gated, mines with the script, refuses in a subagent" {
  grep -q '^name: learn$' "$SKILL"
  sed -n '/^---$/,/^---$/p' "$SKILL" | grep -qF 'description: Only in projects that have .claude/memokit.json — '
  grep -qF '"${CLAUDE_PLUGIN_ROOT}/skills/learn/scripts/memokit-learn.sh" mine' "$SKILL"
  grep -qF 'CLAUDE_CODE_CHILD_SESSION' "$SKILL"
  grep -qF 'CLAUDE_CODE_SESSION_ID' "$SKILL"
  grep -qF 'newest `.jsonl`' "$SKILL"
  grep -qF 'project `language`' "$SKILL"
}
@test "skill: table, at most 5 lines of at most 160 characters, each with its evidence row" {
  grep -qF 'at most 5' "$SKILL"
  grep -qF '160 characters' "$SKILL"
  grep -qF 'evidence row' "$SKILL"
  for w in denies errors corrections repeats; do grep -qF "\`$w\`" "$SKILL" || { echo "$w"; false; }; done
}
@test "skill: per-line choice rules.md / LESSONS.md / drop; 1536 bytes measured with wc -c; nothing written without approval" {
  grep -qF '`.claude/memokit/rules.md`' "$SKILL"
  grep -qF '`docs/LESSONS.md`' "$SKILL"
  grep -qF 'only if the project already uses it' "$SKILL"
  grep -qF 'drop' "$SKILL"
  grep -qF 'per line' "$SKILL"
  grep -qF 'wc -c' "$SKILL"
  grep -qF '1536 bytes' "$SKILL"
  grep -qF 'never exceeded' "$SKILL"
  grep -qF 'Nothing is written without' "$SKILL"
  grep -qF 'The question says that the approved lines will be written and committed' "$SKILL"
  a="$(line_of "$SKILL" 'Ask per line')"; w="$(line_of "$SKILL" 'Write the approved lines')"
  [ -n "$a" ] && [ -n "$w" ] && [ "$a" -lt "$w" ]
}
@test "handoff step 6 points to /memokit:learn" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  s="$(sed -n '/^6\. \*\*Durable records/,/^7\. /p' "$f")"
  printf '%s' "$s" | grep -qF 'Run `/memokit:learn` when the session had corrections or repeated denies.'
}
@test "CI shellchecks the learn script" {
  grep -qF 'skills/learn/scripts/*.sh' "$MK_REPO/.github/workflows/ci.yml"
}
