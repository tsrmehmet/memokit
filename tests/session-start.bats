#!/usr/bin/env bats
load helpers

@test "init hint in git repo without config" {
  mk_project none
  LANG=tr_TR.UTF-8 run_hook session-start.sh '{}'
  ctx | grep -q '/memokit:init'
}
@test "no hint in legacy project" {
  mk_project none; mkdir -p "$PROJ/.claude/hooks"
  run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "no hint outside git" {
  d="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$d"
  run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "hint can be disabled" {
  mk_project none
  MEMOKIT_NO_INIT_HINT=1 run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "injects header, STATE and resume note" {
  mk_project
  run_hook session-start.sh '{}'
  ctx | grep -q '\[Demo — oturum açılışı\]'
  ctx | grep -q 'Sıradaki adım: demo'
  ctx | grep -q '/memokit:resume'
}
@test "health script output included; missing script reported" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","sessionStart":{"healthScript":"scripts/kh.sh"}}'
  run_hook session-start.sh '{}'; ctx | grep -q 'scripts/kh.sh'
  mkdir -p "$PROJ/scripts"; printf '#!/bin/sh\necho HEALTH-OK\n' > "$PROJ/scripts/kh.sh"; chmod +x "$PROJ/scripts/kh.sh"
  run_hook session-start.sh '{}'; ctx | grep -q 'HEALTH-OK'
}
@test "missing docs are reported" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","sessionStart":{"docs":["docs/RULES.md — kurallar"]}}'
  run_hook session-start.sh '{}'
  ctx | grep -q 'docs/RULES.md'
  ctx | grep -qi 'eksik'
}
@test "unknown key warned" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","colour":1}'
  run_hook session-start.sh '{}'; ctx | grep -q 'colour'
}
@test "control characters in STATE still yield valid json" {
  mk_project; printf 'a\033b\001c\n' > "$PROJ/docs/STATE.md"
  run_hook session-start.sh '{}'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "invalid config still injects STATE with warning" {
  mk_project '{"version":1,"project":{"name":"D","tag":"bad"}}'
  run_hook session-start.sh '{}'
  ctx | grep -q 'memokit.json'; ctx | grep -q 'Sıradaki adım'
}
@test "invalid config still runs the risk scan without leaking the secret" {
  mk_project '{"version":1,"project":{"name":"D","tag":"bad"}}'
  printf '%s' '{"permissions":{"allow":["Bash(sshpass -p hunter2pass ssh root@203.0.113.9 uptime)"]}}' > "$PROJ/.claude/settings.local.json"
  run_hook session-start.sh '{}'
  ctx | grep -q 'memokit.json'
  ctx | grep -q 'Sıradaki adım'
  ctx | grep -q 'sshpass-p'
  lacks "$output" 'hunter2pass'
}
