#!/usr/bin/env bats
# 0.8.1 Part C goals 4-5: hooks/lib/transcript.sh (shared transcript parsing)
# and skills/handoff/scripts/memokit-stats.sh (one stats line at handoff).
load helpers

FX="$MK_REPO/tests/fixtures/transcripts"
STATS="$MK_REPO/skills/handoff/scripts/memokit-stats.sh"
# session.jsonl, counted by hand: last usage 3 + 200 + 23000 = 23203; output
# tokens 300+120+80+60+70+50+900+200+40+150+400 = 2370 (msg_A, msg_G and msg_J
# are split over several records that repeat one usage); 13 tool_use blocks
# (Bash 5, Agent 2, Task, SendMessage, Edit, Write, Grep, Read 1 each); 2 hook
# denies (one with permissionDecision.source "hook", one older text-only); the
# auto-mode classifier deny and a quoted "hook error" inside a log are not
# hook denies; 3 dispatches (Agent 2, Task 1); the progress record's nested
# subagent call, the garbage line and the truncated last line count nowhere.
EN_LINE='[MEMOKIT] Session stats: context 23.2k · output 2.3k tokens · 13 tool calls (Bash 5, Agent 2, Edit 1, Grep 1, Read 1) · 2 hook denies · 3 subagent dispatches'

# Runs the stats script from a directory without memokit config (English, tag MEMOKIT).
stats_plain() {
  local d; d="$(mktemp -d "${MK_FIXTMP}/mkplain.XXXXXX")"
  run env -u CLAUDE_PROJECT_DIR "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$d" "$MK_BASH" "$STATS" "$@"
}
line_of() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1; }
lib_call() { # $1 function, rest args: sources the library under the OS bash
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/transcript.sh"; shift; "$@"' x "$HOOKS" "$@"
}

@test "lib: context number is the last usage record, tail or whole file" {
  lib_call mk_tr_context_used "$FX/session.jsonl" 500
  [ "$status" -eq 0 ]; [ "$output" = "23203" ]
  lib_call mk_tr_context_used "$FX/session.jsonl"
  [ "$output" = "23203" ]
}
@test "lib: an empty transcript reads as 0, as the budget hook always did" {
  lib_call mk_tr_context_used "$FX/empty.jsonl" 500
  [ "$status" -eq 0 ]; [ "$output" = "0" ]
}
@test "lib: record stream drops malformed lines and keeps every object" {
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/transcript.sh"; mk_tr_jq "$2" "[mk_tr_records] | length"' x "$HOOKS" "$FX/session.jsonl"
  [ "$status" -eq 0 ]; [ "$output" = "33" ]
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/transcript.sh"; mk_tr_jq_tail "$2" 3 "[mk_tr_records | .uuid] | join(\",\")"' x "$HOOKS" "$FX/session.jsonl"
  [ "$status" -eq 0 ]; [ "$output" = '"a16,s01"' ]
}
@test "stats: one line with context, output tokens, top-5 tools, hook denies, dispatches" {
  stats_plain "$FX/session.jsonl"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$output" = "$EN_LINE" ] || { echo "got: $output"; false; }
}
@test "stats: output tokens count each split message once" {
  stats_plain "$FX/session.jsonl"
  printf '%s' "$output" | grep -qF 'output 2.3k tokens'
  lacks "$output" '3.5k'
}
@test "stats: no currency" {
  stats_plain "$FX/session.jsonl"
  [ "$status" -eq 0 ]; [ -n "$output" ]
  for w in '$' '€' 'USD' 'cost' 'price'; do lacks "$output" "$w"; done
}
@test "stats: project language and tag come from .claude/memokit.json" {
  mk_project
  run "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS" "$FX/session.jsonl"
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]
  [ "$output" = '[DMO] Oturum istatistiği: bağlam 23.2k · çıktı 2.3k token · 13 araç çağrısı (Bash 5, Agent 2, Edit 1, Grep 1, Read 1) · 2 hook reddi · 3 alt ajan görevi' ] || { echo "got: $output"; false; }
}
@test "stats: an empty transcript prints n/a and zeros, exit 0" {
  stats_plain "$FX/empty.jsonl"
  [ "$status" -eq 0 ]; [ "${#lines[@]}" -eq 1 ]
  [ "$output" = '[MEMOKIT] Session stats: context n/a · output 0 tokens · 0 tool calls (-) · 0 hook denies · 0 subagent dispatches' ] || { echo "got: $output"; false; }
}
@test "stats: numbers read as plain, k or M, rounded down" {
  t="$BATS_TEST_TMPDIR/n.jsonl"
  printf '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":950,"output_tokens":1529999}}}\n' > "$t"
  stats_plain "$t"
  printf '%s' "$output" | grep -qF 'context 950 · output 1.5M tokens' || { echo "got: $output"; false; }
  printf '{"type":"assistant","message":{"id":"m2","usage":{"input_tokens":2000000,"output_tokens":140085}}}\n' >> "$t"
  stats_plain "$t"
  printf '%s' "$output" | grep -qF 'context 2M · output 1.6M tokens' || { echo "got: $output"; false; }
}
@test "stats: a missing transcript or a bad call fails without a stats line" {
  stats_plain "$BATS_TEST_TMPDIR/nope.jsonl"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF 'nope.jsonl'
  lacks "$output" 'tool calls'
  stats_plain a b
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'usage: memokit-stats.sh'
}
@test "stats: the context is the budget hook's number" {
  mk_project
  T="$FX/session.jsonl"
  MEMOKIT_CONTEXT_LIMIT=1000 run_hook check-context-budget.sh "$(jq -nc --arg t "$T" '{transcript_path:$t,session_id:"st1"}')"
  ctx | grep -qF '~23k'
  grep -qF '. "$(dirname "$0")/lib/transcript.sh"' "$HOOKS/check-context-budget.sh"
  grep -qF 'mk_tr_context_used "$TRANSCRIPT" 500' "$HOOKS/check-context-budget.sh"
  run grep -F 'fromjson' "$HOOKS/check-context-budget.sh"; [ "$status" -ne 0 ]
  grep -qF 'mk_tr_context' "$STATS"
}
@test "stats: without an argument it finds the session transcript, newest .jsonl as fallback" {
  mk_project
  cfg="$BATS_TEST_TMPDIR/cfgdir"
  slug="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$cfg/projects/other-project" "$cfg/projects/$slug"
  cp "$FX/session.jsonl" "$cfg/projects/other-project/sid-123.jsonl"
  cp "$FX/empty.jsonl" "$cfg/projects/$slug/older.jsonl"
  run env CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-123 "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS"
  [ "$status" -eq 0 ]; printf '%s' "$output" | grep -qF 'bağlam 23.2k'
  # No session id (or an unsafe one): the newest .jsonl of the project's own folder.
  touch -t 202001010000 "$cfg/projects/$slug/older.jsonl"
  cp "$FX/session.jsonl" "$cfg/projects/$slug/newer.jsonl"
  run env CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID='../x' "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS"
  [ "$status" -eq 0 ]; printf '%s' "$output" | grep -qF 'bağlam 23.2k'
  rm "$cfg/projects/$slug/newer.jsonl"
  run env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS"
  [ "$status" -eq 0 ]; printf '%s' "$output" | grep -qF 'bağlam yok'
  rm "$cfg/projects/$slug/older.jsonl"
  run env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS"
  [ "$status" -ne 0 ]
  lacks "$output" 'araç çağrısı'
}
@test "stats: the newest-.jsonl fallback names its pick on stderr, one line; the session-id pick is silent" {
  mk_project
  cfg="$BATS_TEST_TMPDIR/cfgdir"
  slug="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$cfg/projects/other-project" "$cfg/projects/$slug"
  cp "$FX/session.jsonl" "$cfg/projects/other-project/sid-123.jsonl"
  cp "$FX/session.jsonl" "$cfg/projects/$slug/newer.jsonl"
  errf="$BATS_TEST_TMPDIR/err"
  out="$(env CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sid-123 "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS" 2>"$errf")"
  printf '%s' "$out" | grep -qF 'bağlam 23.2k'
  [ ! -s "$errf" ] || { echo "stderr on the session-id pick: $(cat "$errf")"; false; }
  out="$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS" 2>"$errf")"
  printf '%s' "$out" | grep -qF 'bağlam 23.2k'
  lacks "$out" 'newer.jsonl'
  [ "$(wc -l < "$errf" | tr -d ' ')" = 1 ] || { echo "stderr: $(cat "$errf")"; false; }
  grep -qF "$cfg/projects/$slug/newer.jsonl" "$errf" || { echo "stderr: $(cat "$errf")"; false; }
  grep -qF 'en yeni' "$errf"
  grep -qF "bu oturumun transcript'i bulunamadı" "$errf" || { echo "stderr: $(cat "$errf")"; false; }
  # English wording too
  printf '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  out="$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$cfg" "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_BASH" "$STATS" 2>"$errf")"
  grep -qF 'no transcript found for this session' "$errf" || { echo "stderr: $(cat "$errf")"; false; }
}
@test "stats: a 4 MB transcript in one pass within a time bound" {
  big="$BATS_TEST_TMPDIR/big.jsonl"
  # The fixture's 34 complete lines, 400 copies; message ids made unique per copy.
  awk 'NR==FNR { if (FNR < 35) l[n++] = $0; next } END { for (i = 0; i < 400; i++) for (j = 0; j < n; j++) { s = l[j]; gsub(/"msg_/, "\"msg_" i "_", s); print s } }' \
    "$FX/session.jsonl" /dev/null > "$big"
  start=$(date +%s)
  stats_plain "$big"
  took=$(( $(date +%s) - start ))
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'output 948k tokens · 5200 tool calls (Bash 2000, Agent 800, Edit 400, Grep 400, Read 400)'
  printf '%s' "$output" | grep -qF '800 hook denies · 1200 subagent dispatches'
  [ "$took" -le 20 ] || { echo "took ${took}s"; false; }
}
@test "handoff step 10 prints the stats line; STATE gets none of it; a failure does not fail the handoff" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  grep -qF '"${CLAUDE_PLUGIN_ROOT}/skills/handoff/scripts/memokit-stats.sh"' "$f"
  grep -qF 'CLAUDE_CODE_SESSION_ID' "$f"
  grep -qF 'newest `.jsonl`' "$f"
  grep -qF 'STATE.md gets none of it' "$f"
  grep -qF 'A stats failure does not fail the handoff' "$f"
  v="$(line_of "$f" '10. **VERIFY BY MEASURING**')"; s="$(line_of "$f" 'memokit-stats.sh"')"; n="$(line_of "$f" '11. **Notify')"
  [ -n "$v" ] && [ -n "$s" ] && [ -n "$n" ] && [ "$v" -lt "$s" ] && [ "$s" -lt "$n" ]
}
