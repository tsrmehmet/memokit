# Shared fixtures for memokit bats tests. bash 3.2-safe.
MK_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOKS="$MK_REPO/hooks"
# Always run hooks under the OS bash so macOS CI proves 3.2 compatibility.
MK_BASH="${MK_BASH:-/bin/bash}"
DEFAULT_CONFIG='{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"tr","guardedDirs":["src","tests"]}'

mk_project() {
  PROJ="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkproj.XXXXXX")"
  PROJ="$(cd "$PROJ" && pwd)"
  mkdir -p "$PROJ/src" "$PROJ/tests" "$PROJ/docs" "$PROJ/.claude"
  printf '# STATE\nSıradaki adım: demo\n' > "$PROJ/docs/STATE.md"
  git -C "$PROJ" init -q
  git -C "$PROJ" -c user.email=t@t -c user.name=t add -A
  git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm init
  if [ "${1:-default}" != "none" ]; then
    if [ "${1:-default}" = "default" ]; then
      printf '%s' "$DEFAULT_CONFIG" > "$PROJ/.claude/memokit.json"
    else
      printf '%s' "$1" > "$PROJ/.claude/memokit.json"
    fi
  fi
  export PROJ
  export CLAUDE_PROJECT_DIR="$PROJ"
}

run_hook() {
  run "$MK_BASH" -c 'printf "%s" "$2" | "$0" "$1"' "$MK_BASH" "$HOOKS/$1" "$2"
}

# jq on a truly empty stdin processes zero JSON values, so the `// "allow"`
# default filter never even runs (exit 0, zero output) -- guard against that
# separately from the `|| echo "allow"` fallback, which only catches a
# non-zero jq exit (e.g. genuinely invalid JSON).
decision() { [ -z "$output" ] && { printf 'allow'; return; }; printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo "allow"; }
reason()   { printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }
ctx()      { printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // empty'; }

write_payload() {
  jq -nc --arg p "$1" --arg a "${2:-}" --arg cwd "$PROJ" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:"x"},cwd:$cwd} + (if $a=="" then {} else {agent_id:$a} end)'
}
bash_payload() {
  jq -nc --arg c "$1" --arg a "${2:-}" --arg cwd "$PROJ" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd} + (if $a=="" then {} else {agent_id:$a} end)'
}
tool_payload() {
  jq -nc --arg t "$1" --arg a "${2:-}" --arg cwd "$PROJ" \
    '{tool_name:$t,tool_input:{prompt:"x"},cwd:$cwd} + (if $a=="" then {} else {agent_id:$a} end)'
}
prompt_payload() { jq -nc --arg p "$1" --arg cwd "$PROJ" '{prompt:$p,cwd:$cwd}'; }

# Negative assertion. Never start a bats line with `!` -- set -e ignores it.
lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then echo "unexpected: $2"; return 1; fi; }

# Prints a PATH whose single bin dir symlinks every command the hooks use
# except the ones named as arguments.
path_without() {
  local bin c skip x
  bin="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkbin.XXXXXX")"
  for c in bash sh cat tr readlink dirname basename git cksum cut head tail wc sed grep date mktemp stat ls pwd env printf mkdir rm jq sort uniq awk find paste; do
    skip=0
    for x in "$@"; do [ "$c" = "$x" ] && skip=1; done
    [ "$skip" -eq 1 ] && continue
    command -v "$c" >/dev/null 2>&1 && ln -s "$(command -v "$c")" "$bin/$c"
  done
  printf '%s' "$bin"
}
