#!/usr/bin/env bats
load helpers

bg_payload() { # $1 transcript path
  jq -nc --arg t "$1" '{hook_event_name:"SubagentStop",agent_id:"a1",agent_transcript_path:$t,transcript_path:$t,background_tasks:[{id:"b1",type:"bash",status:"running",command:"sleep 99"}]}'
}

@test "silent without config" { mk_project none; run_hook check-subagent-background.sh "$(bg_payload /nonexistent)"; [ "$status" -eq 0 ]; [ -z "$output" ]; }
@test "kill switch" { mk_project; MEMOKIT_SUBAGENT_BG_OFF=1 run_hook check-subagent-background.sh "$(bg_payload /nonexistent)"; [ "$status" -eq 0 ]; }
@test "not a subagent payload exits 0" { mk_project; run_hook check-subagent-background.sh '{"hook_event_name":"SubagentStop"}'; [ "$status" -eq 0 ]; }
@test "counter dir lives under memokit tmp prefix" {
  mk_project
  run grep -c 'mk_tmp subagent-bg' "$HOOKS/check-subagent-background.sh"; [ "$output" -ge 1 ]
}

tr_line() { jq -nc --arg c "$1" '{message:{content:[{type:"tool_result",content:$c}]}}'; }
bgp() { jq -nc --arg t "$1" --arg id "${2:-b1}" '{hook_event_name:"SubagentStop",agent_id:"a1",agent_transcript_path:$t,background_tasks:[{id:$id,type:"bash",status:"running",command:"dotnet test"}]}'; }

@test "owned run_in_background task blocks with tag" {
  mk_project; T="$(mktemp)"; tr_line "Command running in background with ID: b1. Output is being written to x" > "$T"
  run_hook check-subagent-background.sh "$(bgp "$T")"
  [ "$status" -eq 2 ]; printf '%s' "$output" | grep -q '\[DMO-SUBAGENT-BG\]'
}
@test "owned auto-backgrounded task blocks (any timeout number)" {
  mk_project; T="$(mktemp)"; tr_line "Command did not complete within its 590s timeout and was moved to the background (ID: b1)" > "$T"
  run_hook check-subagent-background.sh "$(bgp "$T")"; [ "$status" -eq 2 ]
}
@test "owned Monitor task blocks" {
  mk_project; T="$(mktemp)"; tr_line "Monitor started (task b1, watching x)" > "$T"
  run_hook check-subagent-background.sh "$(bgp "$T")"; [ "$status" -eq 2 ]
}
@test "session task not started by this agent does not block" {
  mk_project; T="$(mktemp)"; tr_line "unrelated output" > "$T"
  run_hook check-subagent-background.sh "$(bgp "$T")"; [ "$status" -eq 0 ]
}
@test "phrase quoted mid-text (not at start) does not count" {
  mk_project; T="$(mktemp)"; tr_line "12  Command running in background with ID: b1." > "$T"
  run_hook check-subagent-background.sh "$(bgp "$T")"; [ "$status" -eq 0 ]
}
@test "loop guard: blocks three times then lets the agent go" {
  mk_project; T="$(mktemp)"; tr_line "Command running in background with ID: b1. x" > "$T"
  for i in 1 2 3; do run_hook check-subagent-background.sh "$(bgp "$T")"; [ "$status" -eq 2 ]; done
  printf '%s' "$output" | grep -q 'UNFINISHED: b1'
  run_hook check-subagent-background.sh "$(bgp "$T")"; [ "$status" -eq 0 ]
}
@test "agent_id with ../ is sanitized before it becomes a counter path" {
  mk_project; T="$(mktemp)"; tr_line "Command running in background with ID: b1. x" > "$T"
  export TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mktmp.XXXXXX")"
  p="$(jq -nc --arg t "$T" '{hook_event_name:"SubagentStop",agent_id:"../x",agent_transcript_path:$t,background_tasks:[{id:"b1",type:"bash",status:"running",command:"dotnet test"}]}')"
  run_hook check-subagent-background.sh "$p"; [ "$status" -eq 2 ]
  [ ! -e "$TMPDIR/x" ]
  ls "$TMPDIR"/memokit-*-subagent-bg/ | grep -qx '___x'
}
