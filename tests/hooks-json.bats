#!/usr/bin/env bats
load helpers

@test "hooks.json wires the 8 hooks with legacy timeouts" {
  run jq -r '[.hooks | to_entries[] | .key as $e | .value[] | .matcher as $m | .hooks[] | "\($e)|\($m // "")|\(.command | sub(".*/hooks/"; "") | sub("\"$"; ""))|\(.timeout)"] | sort | .[]' "$HOOKS/hooks.json"
  [ "$output" = "$(printf '%s\n' \
    'PreCompact||precompact-handoff.sh|5' \
    'PreToolUse|Bash|Agent|Task|SendMessage|guard-subagent-authority.sh|5' \
    'PreToolUse|Edit|Write|MultiEdit|NotebookEdit|Bash|guard-edit.sh|5' \
    'SessionStart|startup|resume|clear|compact|session-start.sh|15' \
    'Stop||check-context-budget.sh|8' \
    'Stop||check-state-stale.sh|8' \
    'SubagentStop||check-subagent-background.sh|5' \
    'UserPromptSubmit||inject-rules.sh|5' | LC_ALL=C sort)" ]
}

@test "every wired script exists and is executable" {
  for s in $(jq -r '.. | .command? // empty' "$HOOKS/hooks.json" | sed 's#.*/hooks/##; s#"$##'); do
    [ -x "$HOOKS/$s" ] || { echo "not executable: $s"; false; }
  done
}

@test "all hooks silent without config (except session-start hint)" {
  mk_project none; mkdir -p "$PROJ/.claude/hooks"   # legacy project shape
  for h in guard-edit.sh guard-subagent-authority.sh inject-rules.sh session-start.sh check-state-stale.sh check-context-budget.sh check-subagent-background.sh precompact-handoff.sh; do
    run_hook "$h" "$(write_payload "$PROJ/src/A.cs" a1)"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "not silent: $h"; false; }
  done
}

@test "all 8 hooks silent in a legacy repo launched from a subdirectory" {
  mk_project none; mkdir -p "$PROJ/.claude/hooks"   # legacy project shape
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  p="$(jq -nc --arg f "$PROJ/src/A.cs" --arg cwd "$PROJ/src" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"},agent_id:"a1",cwd:$cwd}')"
  errf="$(mktemp "${BATS_TMPDIR:-/tmp}/mkerr.XXXXXX")"
  for h in guard-edit.sh guard-subagent-authority.sh inject-rules.sh session-start.sh check-state-stale.sh check-context-budget.sh check-subagent-background.sh precompact-handoff.sh; do
    rc=0
    out="$(printf '%s' "$p" | "$MK_BASH" "$HOOKS/$h" 2>"$errf")" || rc=$?
    [ "$rc" -eq 0 ] || { echo "rc=$rc: $h"; false; }
    [ -z "$out" ] || { echo "stdout from $h: $out"; false; }
    [ ! -s "$errf" ] || { echo "stderr from $h: $(cat "$errf")"; false; }
  done
}
