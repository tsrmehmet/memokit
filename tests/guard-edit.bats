#!/usr/bin/env bats
load helpers

@test "silent without config" {
  mk_project none
  run_hook guard-edit.sh "$(write_payload "$PROJ/src/A.cs")"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "main session write under src is denied" {
  mk_project
  run_hook guard-edit.sh "$(write_payload "$PROJ/src/A.cs")"
  [ "$(decision)" = "deny" ]
  reason | grep -q 'memokit:coder'
  reason | grep -q 'src/, tests/'
}
@test "subagent write under src is allowed" {
  mk_project
  run_hook guard-edit.sh "$(write_payload "$PROJ/src/A.cs" agent-1)"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "allow" ]
}
@test "docs write is allowed" {
  mk_project
  run_hook guard-edit.sh "$(write_payload "$PROJ/docs/x.md")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "allow" ]
}
@test "tests write is denied" {
  mk_project
  run_hook guard-edit.sh "$(write_payload "$PROJ/tests/B.cs")"
  [ "$(decision)" = "deny" ]
}
@test "custom guardedDirs are honoured" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"guardedDirs":["src","web"]}'
  mkdir -p "$PROJ/web"
  run_hook guard-edit.sh "$(write_payload "$PROJ/web/page.tsx")";  [ "$(decision)" = "deny" ]
  run_hook guard-edit.sh "$(write_payload "$PROJ/tests/B.cs")";   [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
}
@test "bash redirect into src is denied, read-only command allowed" {
  mk_project
  run_hook guard-edit.sh "$(bash_payload 'echo x > src/a.cs')"; [ "$(decision)" = "deny" ]
  run_hook guard-edit.sh "$(bash_payload 'ls src/')";           [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
}
@test "empty stdin with config is denied" {
  mk_project
  run_hook guard-edit.sh ""
  [ "$(decision)" = "deny" ]
}
@test "invalid json is denied" {
  mk_project
  run_hook guard-edit.sh "not json"
  [ "$(decision)" = "deny" ]
}
@test "kill switch allows" {
  mk_project
  MEMOKIT_GUARD_OFF=1 run_hook guard-edit.sh "$(write_payload "$PROJ/src/A.cs")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
@test "invalid config denies" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"guardedDirs":[".."]}'
  run_hook guard-edit.sh "$(write_payload "$PROJ/docs/x.md")"
  [ "$(decision)" = "deny" ]
  reason | grep -q 'memokit.json'
}
@test "jq missing denies with static json" {
  mk_project
  p="$(write_payload "$PROJ/src/A.cs")"
  run env PATH="$(path_without jq)" "$MK_BASH" -c 'printf "%s" "$1" | "$0" "$2"' "$MK_BASH" "$p" "$HOOKS/guard-edit.sh"
  [ "$(printf '%s' "$output" | /usr/bin/env jq -r .hookSpecificOutput.permissionDecision)" = "deny" ]
}
@test "english messages when language en" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook guard-edit.sh "$(write_payload "$PROJ/src/A.cs")"
  reason | grep -q 'blocked in the main session'
}
@test "uppercase path variant is denied" {
  mk_project
  run_hook guard-edit.sh "$(write_payload "$PROJ/SRC/A.cs")"
  [ "$(decision)" = "deny" ]
}
@test "root with space and uppercase" {
  base="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mk.XXXXXX")"
  mkdir -p "$base/My Project"
  export CLAUDE_PROJECT_DIR="$base/My Project"; PROJ="$CLAUDE_PROJECT_DIR"
  mkdir -p "$PROJ/src" "$PROJ/.claude"; git -C "$PROJ" init -q
  printf '%s' "$DEFAULT_CONFIG" > "$PROJ/.claude/memokit.json"
  run_hook guard-edit.sh "$(write_payload "$PROJ/src/A.cs")"; [ "$(decision)" = "deny" ]
  run_hook guard-edit.sh "$(write_payload "$PROJ/README.md")"; [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
}
@test "path outside the project is allowed" {
  mk_project
  run_hook guard-edit.sh "$(write_payload "/tmp/elsewhere/src/a.cs")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "allow" ]
}
@test "symlink outside the project into src/sub is denied (inode-identity walk)" {
  mk_project
  mkdir -p "$PROJ/src/sub"
  outside="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkoutside.XXXXXX")"
  ln -s "$PROJ/src/sub" "$outside/link"
  run_hook guard-edit.sh "$(write_payload "$outside/link/pwn.cs")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "quoted redirect, tee, cp targets and >| into src are denied" {
  mk_project
  for c in 'echo x > "src/a.cs"' "echo x > 'src/a.cs'" 'tee "src/a.cs"' 'cp /tmp/x "src/a.cs"' 'echo x >| src/a.cs' \
           'echo x >|"src/a.cs"' "echo x >> 'tests/b.cs'" "tee -a 'src/a.cs' < /dev/null"; do
    run_hook guard-edit.sh "$(bash_payload "$c")"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
}
@test "quoted write targets outside guarded dirs stay allowed" {
  mk_project
  for c in 'echo x > "docs/a.md"' "echo x > 'docs/a.md'" 'tee "docs/a.md"' 'cp /tmp/x "docs/a.md"' 'echo x >| docs/a.md' \
           'echo "src/a.cs" > docs/list.txt' "grep -rn 'src/a.cs' docs/"; do
    run_hook guard-edit.sh "$(bash_payload "$c")"
    [ "$status" -eq 0 ] || { echo "nonzero status: $c"; false; }
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
