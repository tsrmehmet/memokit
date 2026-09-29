#!/usr/bin/env bats
load helpers

transcript() { # $1 total tokens
  T="$(mktemp "${BATS_TMPDIR:-/tmp}/tr.XXXXXX")"
  printf '{"message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$(( $1 - 1000 ))" > "$T"
  printf '{"message":{"usage":' >> "$T"   # half-written last line must be tolerated
}
stop_payload() { jq -nc --arg t "$T" --arg s "${1:-s1}" '{transcript_path:$t,session_id:$s}'; }

@test "silent without config" { mk_project none; transcript 350000; run_hook check-context-budget.sh "$(stop_payload)"; [ -z "$output" ]; }
@test "fires over budget with autonomous instructions" {
  mk_project; transcript 350000
  run_hook check-context-budget.sh "$(stop_payload)"
  ctx | grep -q '\[DMO-CONTEXT\]'
  ctx | grep -q '/memokit:handoff'
  ctx | grep -q "devam et"
  ctx | grep -q 'ÖLÇEREK'
  lacks "$(ctx)" 'AskUserQuestion'
  lacks "$(ctx)" 'cevabını bekle'
}
@test "fires once per band" {
  mk_project; transcript 350000
  run_hook check-context-budget.sh "$(stop_payload s2)"; [ -n "$output" ]
  run_hook check-context-budget.sh "$(stop_payload s2)"; [ -z "$output" ]
}
@test "under budget is silent" { mk_project; transcript 250000; run_hook check-context-budget.sh "$(stop_payload)"; [ -z "$output" ]; }
@test "config limit applies, env overrides" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","contextBudget":{"limitTokens":200000}}'
  transcript 250000
  run_hook check-context-budget.sh "$(stop_payload s3)"; [ -n "$output" ]
  MEMOKIT_CONTEXT_LIMIT=400000 run_hook check-context-budget.sh "$(stop_payload s4)"; [ -z "$output" ]
}
@test "band markers are per project" {
  mk_project; transcript 350000
  run_hook check-context-budget.sh "$(stop_payload same)"; [ -n "$output" ]
  mk_project
  run_hook check-context-budget.sh "$(stop_payload same)"; [ -n "$output" ]
}
@test "session_id with ../ is sanitized before it becomes a marker path" {
  mk_project; transcript 350000
  export TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mktmp.XXXXXX")"
  mkdir -p "$TMPDIR/sub"
  run_hook check-context-budget.sh "$(stop_payload '../x')"; [ -n "$output" ]
  run_hook check-context-budget.sh "$(stop_payload '../x')"; [ -z "$output" ]   # once per band: the marker was written
  [ ! -e "$TMPDIR/x" ]
  ls "$TMPDIR" | grep -q -- '-context-band-___x$'
}
