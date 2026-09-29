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

# --- 0.1.1: git worktrees and subdirectory launch ---------------------------
# A linked worktree of $PROJ at $1 (detached, so no branch name collides).
mk_worktree() { git -C "$PROJ" worktree add -q --detach "$1" >/dev/null 2>&1 || return 1; WT="$1"; }
# Write / Bash payloads whose session cwd is $3 / $2 (the worktree), the way
# Claude Code reports it after EnterWorktree while CLAUDE_PROJECT_DIR stays put.
wt_write_payload() {
  jq -nc --arg p "$1" --arg a "${2:-}" --arg cwd "$3" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:"x"},cwd:$cwd} + (if $a=="" then {} else {agent_id:$a} end)'
}
wt_bash_payload() {
  jq -nc --arg c "$1" --arg cwd "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'
}

@test "worktree in .claude/worktrees: main-session write to src is denied" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_write_payload "$WT/src/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "worktree in .claude/worktrees: subagent write to src is allowed" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_write_payload "$WT/src/a.cs" agent-1 "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "allow" ]
}
@test "worktree in .claude/worktrees: docs write is allowed" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_write_payload "$WT/docs/a.md" "" "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "allow" ]
}
@test "worktree in .claude/worktrees: bash redirect into src with worktree cwd is denied" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_bash_payload 'echo x > src/a.cs' "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "worktree in .claude/worktrees: quoted bash redirect into src with worktree cwd is denied" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_bash_payload 'echo x > "src/a.cs"' "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "worktree outside the root: main-session write to src is denied" {
  mk_project
  base="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkwt.XXXXXX")"
  mk_worktree "$base/wt"
  run_hook guard-edit.sh "$(wt_write_payload "$WT/src/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "worktree in .claude/worktrees: uppercase SRC variant is denied" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_write_payload "$WT/SRC/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "worktree in .claude/worktrees: symlink inside it pointing into its src is denied" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  mkdir -p "$WT/src/sub"
  ln -s src/sub "$WT/lnk"
  run_hook guard-edit.sh "$(wt_write_payload "$WT/lnk/pwn.cs" "" "$WT")"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "worktree coverage keeps the root's own offset when the config sits in a repo subdir" {
  # Config at <repo>/app: the main checkout's <repo>/src is NOT guarded (as
  # before), the worktree's counterpart <wt>/app/src IS.
  mk_project none
  mkdir -p "$PROJ/app/.claude" "$PROJ/app/src"
  printf '%s' "$DEFAULT_CONFIG" > "$PROJ/app/.claude/memokit.json"
  export CLAUDE_PROJECT_DIR="$PROJ/app"
  mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_write_payload "$PROJ/src/a.cs" "" "$PROJ")"
  [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
  run_hook guard-edit.sh "$(wt_write_payload "$WT/src/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
  run_hook guard-edit.sh "$(wt_write_payload "$WT/app/src/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]; [ "$(decision)" = "deny" ]
}
@test "without git on PATH the root itself stays guarded" {
  mk_project; mk_worktree "$PROJ/.claude/worktrees/w"
  p="$(write_payload "$PROJ/src/A.cs")"
  run env PATH="$(path_without git)" "$MK_BASH" -c 'printf "%s" "$1" | "$0" "$2"' "$MK_BASH" "$p" "$HOOKS/guard-edit.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | /usr/bin/env jq -r .hookSpecificOutput.permissionDecision)" = "deny" ]
}
@test "subdirectory launch: main-session write under the root's src is denied" {
  mk_project
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run_hook guard-edit.sh "$(jq -nc --arg p "$PROJ/src/a.cs" --arg cwd "$PROJ/src" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"},cwd:$cwd}')"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "deny" ]
}
@test "subdirectory launch in a repo without config stays silent" {
  mk_project none
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run_hook guard-edit.sh "$(write_payload "$PROJ/src/a.cs")"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "non-git directory without config stays silent" {
  d="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mknogit.XXXXXX")"
  mkdir -p "$d/src"
  export CLAUDE_PROJECT_DIR="$d/src"; PROJ="$d"
  run_hook guard-edit.sh "$(write_payload "$d/src/a.cs")"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}
@test "case-variant CLAUDE_PROJECT_DIR with the config in a repo subdir keeps the offset" {
  mk_project none
  mkdir -p "$PROJ/app/.claude" "$PROJ/app/src"
  printf '%s' "$DEFAULT_CONFIG" > "$PROJ/app/.claude/memokit.json"
  variant="$(dirname "$PROJ")/$(basename "$PROJ" | tr '[:lower:]' '[:upper:]')/app"
  [ -d "$variant" ] || skip "case-sensitive filesystem"
  export CLAUDE_PROJECT_DIR="$variant"
  mk_worktree "$PROJ/.claude/worktrees/w"
  run_hook guard-edit.sh "$(wt_write_payload "$PROJ/src/a.cs" "" "$PROJ")"
  [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
  run_hook guard-edit.sh "$(wt_write_payload "$WT/src/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]; [ "$(decision)" = "allow" ]
  run_hook guard-edit.sh "$(wt_write_payload "$WT/app/src/a.cs" "" "$WT")"
  [ "$status" -eq 0 ]; [ "$(decision)" = "deny" ]
}
