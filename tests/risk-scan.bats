#!/usr/bin/env bats
load helpers

@test "plaintext ssh password flagged without leaking it" {
  mk_project
  printf '%s' '{"permissions":{"allow":["Bash(sshpass -p hunter2pass ssh root@203.0.113.9 uptime)"]}}' > "$PROJ/.claude/settings.local.json"
  run_hook session-start.sh '{}'
  ctx | grep -q 'settings.local.json'
  ctx | grep -q 'sshpass-p'
  lacks "$output" 'hunter2pass'
  lacks "$output" '203.0.113.9'
}
@test "broad Bash(*) flagged" {
  mk_project
  printf '%s' '{"permissions":{"allow":["Bash(*)"]}}' > "$PROJ/.claude/settings.json"
  run_hook session-start.sh '{}'; ctx | grep -q 'Bash(\*)'
}
@test "clean settings produce no security line" {
  mk_project
  printf '%s' '{"permissions":{"allow":["Bash(git status)"]}}' > "$PROJ/.claude/settings.json"
  run_hook session-start.sh '{}'; lacks "$(ctx)" 'GÜVENLİK'
}
@test "broken settings json does not break session start" {
  mk_project; printf '{' > "$PROJ/.claude/settings.json"
  run_hook session-start.sh '{}'; printf '%s' "$output" | jq -e . >/dev/null
}
