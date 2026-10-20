# Shared fixtures for memokit bats tests. bash 3.2-safe.
MK_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOKS="$MK_REPO/hooks"
# Always run hooks under the OS bash so macOS CI proves 3.2 compatibility.
MK_BASH="${MK_BASH:-/bin/bash}"
# A developer's own memokit env (e.g. MEMOKIT_NO_INIT_HINT=1 under `env` in
# ~/.claude/settings.json, inherited by Claude Code's shell) must not leak in.
for _v in $(env | sed -n 's/^\(MEMOKIT_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
unset _v
# Session-start auto-clean (0.6.1) starts detached jobs; tests that exercise
# it unset this and set MEMOKIT_AUTOCLEAN_SYNC=1.
export MEMOKIT_AUTOCLEAN_OFF=1
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

# Temp-tree fixture for hooks/lib/temp.sh. Builds
#   $TROOT/claude-<uid>/<slug>/<sid>/{scratchpad,tasks}   (Claude Code's temp tree)
#   $TROOT/projects/<slug>/<sid>.jsonl                    (the transcript dir)
# and exports MEMOKIT_TEMP_ROOT (the logical, as-created spelling of
# $TROOT/claude-<uid>) plus TT_* paths in their physical (cd -P) form and
# TT_PAYLOAD, a hook payload pointing at that session.
mk_temp_tree() {
  TROOT_LOGICAL="$(mktemp -d "${BATS_TMPDIR:-/tmp}/troot.XXXXXX")"
  TROOT="$(cd -P "$TROOT_LOGICAL" && pwd -P)"
  TT_UID="$(id -u)"
  TT_SLUG="${1:--fix-proj}"
  TT_SID="${2:-11111111-2222-3333-4444-555555555555}"
  TT_ROOT="$TROOT/claude-$TT_UID"
  TT_PROJ="$TT_ROOT/$TT_SLUG"
  TT_SESS="$TT_PROJ/$TT_SID"
  TT_SP="$TT_SESS/scratchpad"
  TT_TDIR="$TROOT/projects/$TT_SLUG"
  mkdir -p "$TT_SP" "$TT_SESS/tasks" "$TT_TDIR"
  # mk_temp_init wants owned, not group/world-writable dirs; do not rely on umask.
  chmod 700 "$TT_ROOT" "$TT_PROJ" "$TT_SESS" "$TT_SP"
  : > "$TT_TDIR/$TT_SID.jsonl"
  TT_PAYLOAD="$(jq -nc --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" '{session_id:$s,transcript_path:$t,cwd:"/x"}')"
  MEMOKIT_TEMP_ROOT="$TROOT_LOGICAL/claude-$TT_UID"
  export MEMOKIT_TEMP_ROOT TROOT TROOT_LOGICAL TT_UID TT_SLUG TT_SID TT_ROOT TT_PROJ TT_SESS TT_SP TT_TDIR TT_PAYLOAD
}

# mk_blob PATH KB -- a file of KB kilobytes (parent dirs created).
mk_blob() {
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1024 count="$2" 2>/dev/null
}
