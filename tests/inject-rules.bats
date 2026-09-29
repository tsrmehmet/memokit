#!/usr/bin/env bats
load helpers

@test "silent without config" {
  mk_project none
  run_hook inject-rules.sh "$(prompt_payload 'hata var')"; [ -z "$output" ]
}
@test "base block with tag, dirs and coder" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  ctx | grep -q '^\[DMO-KURAL\]'; ctx | grep -q 'src/, tests/'; ctx | grep -q 'memokit:coder'
  lacks "$(ctx)" '[SKILL]'
}
@test "debugging hint fires" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'bu test hata veriyor')"
  ctx | grep -q 'systematic-debugging'
}
@test "builtin hints can be disabled" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"builtin":["review"]}}'
  run_hook inject-rules.sh "$(prompt_payload 'bu test hata veriyor')"
  lacks "$(ctx)" 'systematic-debugging'
}
@test "custom hint fires" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"custom":[{"match":"razor|cshtml","text":"FE-HINT-X"}]}}'
  run_hook inject-rules.sh "$(prompt_payload 'razor sayfasını düzelt')"
  ctx | grep -q 'FE-HINT-X'
}
@test "rules.md appended" {
  mk_project; mkdir -p "$PROJ/.claude/memokit"; printf 'PROJ-RULE-7' > "$PROJ/.claude/memokit/rules.md"
  run_hook inject-rules.sh "$(prompt_payload 'x')"
  ctx | grep -q 'PROJ-RULE-7'
}
@test "resume and handoff hints use memokit names" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'devam et')";        ctx | grep -q 'memokit:resume'
  run_hook inject-rules.sh "$(prompt_payload 'handoff yapalım')"; ctx | grep -q 'memokit:handoff'
}
@test "graphify gate output is sanitized" {
  mk_project; mkdir -p "$PROJ/scripts"
  printf '#!/bin/sh\nprintf "Graf \\"3\\" commit bayat\\\\\\033x\\n"\n' > "$PROJ/scripts/graph-staleness.sh"; chmod +x "$PROJ/scripts/graph-staleness.sh"
  run_hook inject-rules.sh "$(prompt_payload 'bu servis nerede')"
  ctx | grep -q 'Graf 3 commit bayat'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "prompt text is never echoed" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'SECRET-XYZ hata')"
  lacks "$output" 'SECRET-XYZ'
}
@test "no jq: static base block, valid json" {
  mk_project
  p="$(prompt_payload 'hata')"
  run env PATH="$(path_without jq)" "$MK_BASH" -c 'printf "%s" "$1" | "$0" "$2"' "$MK_BASH" "$p" "$HOOKS/inject-rules.sh"
  printf '%s' "$output" | /usr/bin/env jq -e '.hookSpecificOutput.additionalContext | test("KURAL")' >/dev/null
}
@test "custom hint with invalid ERE does not crash or fire" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"custom":[{"match":"[","text":"BROKEN-HINT"}]}}'
  run_hook inject-rules.sh "$(prompt_payload 'merhaba [ dunyasi')"
  [ "$status" -eq 0 ]
  lacks "$(ctx)" 'BROKEN-HINT'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "english keywords: continue fires resume, hand off / handoff fire handoff" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook inject-rules.sh "$(prompt_payload 'continue')";               ctx | grep -q 'memokit:resume'
  run_hook inject-rules.sh "$(prompt_payload 'OK, Continue please')";    ctx | grep -q 'memokit:resume'
  run_hook inject-rules.sh "$(prompt_payload 'please hand off now')";    ctx | grep -q 'memokit:handoff'
  run_hook inject-rules.sh "$(prompt_payload 'time for a handoff')";     ctx | grep -q 'memokit:handoff'
}
@test "continue inside another word does not fire the resume hint" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'we discontinued that api')"
  [ "$status" -eq 0 ]
  lacks "$(ctx)" 'memokit:resume'
}
@test "subdirectory launch: rule block is injected" {
  mk_project
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  ctx | grep -q '^\[DMO-KURAL\]'
}
