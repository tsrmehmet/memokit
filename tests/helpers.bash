# Shared fixtures for memokit bats tests. bash 3.2-safe.
MK_REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HOOKS="$MK_REPO/hooks"
# Always run hooks under the OS bash so macOS CI proves 3.2 compatibility.
MK_BASH="${MK_BASH:-/bin/bash}"
# A developer's own memokit env (e.g. MEMOKIT_NO_INIT_HINT=1 under `env` in
# ~/.claude/settings.json, inherited by Claude Code's shell) must not leak in.
for _v in $(env | sed -n 's/^\(MEMOKIT_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
unset _v
# Run from a Claude Code subagent shell, the suite would inherit
# CLAUDE_CODE_CHILD_SESSION=1 and session-start.sh would skip the config
# snapshot; tests that need it set it themselves.
unset CLAUDE_CODE_CHILD_SESSION
# Session-start auto-clean (0.6.1) starts detached jobs; tests that exercise
# it unset this and set MEMOKIT_AUTOCLEAN_SYNC=1.
export MEMOKIT_AUTOCLEAN_OFF=1
# Hooks write state to ${TMPDIR}/memokit-*. Capture the real temp dir once (a
# second `load helpers` must not overwrite it), then give every test a private
# TMPDIR. bats re-sources the file inside each test's own process, where
# BATS_TEST_TMPDIR already exists (cleaned by bats), so this works whether or
# not a file defines its own setup(); BATS_FILE_TMPDIR is the fallback.
: "${MK_REAL_TMPDIR:=${TMPDIR:-/tmp}}"
export MK_REAL_TMPDIR
if [ -n "${BATS_TEST_TMPDIR:-}" ]; then
  export TMPDIR="$BATS_TEST_TMPDIR"
elif [ -n "${BATS_FILE_TMPDIR:-}" ]; then
  export TMPDIR="$BATS_FILE_TMPDIR"
fi
# Fixture dirs (projects, fake homes, shims, ...) go to bats's per-file temp
# dir: inside bats's run dir, which bats removes when the run ends, and
# outside the per-test TMPDIR the hooks write their state to. Never directly
# under BATS_TMPDIR, the real temp dir (repo-hygiene.bats checks).
MK_FIXTMP="${BATS_FILE_TMPDIR:-${BATS_TMPDIR:-/tmp}}"
DEFAULT_CONFIG='{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"tr","guardedDirs":["src","tests"]}'

mk_project() {
  PROJ="$(mktemp -d "${MK_FIXTMP}/mkproj.XXXXXX")"
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
prompt_payload() { jq -nc --arg p "$1" --arg cwd "$PROJ" --arg s "${2-sess5}" '{prompt:$p,cwd:$cwd,session_id:$s}'; }

# Negative assertion. Never start a bats line with `!` -- set -e ignores it.
lacks() { if printf '%s' "$1" | grep -qF -- "$2"; then echo "unexpected: $2"; return 1; fi; }

# Prints a PATH whose single bin dir symlinks every command the hooks use
# except the ones named as arguments.
path_without() {
  local bin c skip x
  bin="$(mktemp -d "${MK_FIXTMP}/mkbin.XXXXXX")"
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
  TROOT_LOGICAL="$(mktemp -d "${MK_FIXTMP}/troot.XXXXXX")"
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

# A project carrying legacy per-repo hooks (shared by migrate and inventory tests).
legacy_project() {
  mk_project none; mkdir -p "$PROJ/.claude/hooks" "$PROJ/.claude/agents" "$PROJ/.claude/skills/handoff"
  cp "$MK_REPO"/tests/fixtures/legacy/*.sh "$PROJ/.claude/hooks/"
  printf 'x' > "$PROJ/.claude/agents/coder.md"; printf 'x' > "$PROJ/.claude/skills/handoff/SKILL.md"
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR/.claude/hooks/check-state-stale.sh\""}]}]}}' > "$PROJ/.claude/settings.json"
  git -C "$PROJ" -c user.email=t@t -c user.name=t add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm legacy
  # extract-legacy compares vendored skills against $HOME/.claude/skills: never the real one.
  export HOME="$(mktemp -d "${MK_FIXTMP}/mkhome.XXXXXX")"
}

# Worktree fixtures (worktrees.bats, careful-cleanup.bats): a throwaway repo
# R on main with .claude/worktrees/ ignored; lanes under W.
g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
gw() { local d="$1"; shift; git -C "$d" -c user.email=t@t -c user.name=t "$@"; }

wt_repo() {
  R="$(mktemp -d "${MK_FIXTMP}/mkwt.XXXXXX")"
  R="$(cd -P "$R" && pwd -P)"
  git -C "$R" init -q
  g symbolic-ref HEAD refs/heads/main
  printf '.claude/worktrees/\n' > "$R/.gitignore"
  printf 'a\n' > "$R/a.txt"
  g add -A; g commit -qm init
  W="$R/.claude/worktrees"
  export R W
}
# wt_add NAME BRANCH -- a worktree at $W/NAME on a new branch off main.
wt_add() { g worktree add -q "$W/$1" -b "$2" main; }
wt_commit() { printf '%s\n' "$2" > "$1/$2.txt"; gw "$1" add -A; gw "$1" commit -qm "$2"; }
# ledger DIR RUN STATUS -- DIR/.claude/memokit/runs/RUN/ledger.md with that status.
ledger() { mkdir -p "$1/.claude/memokit/runs/$2"; printf '# Run %s\n\nstatus: %s\nintegration: main\n' "$2" "$3" > "$1/.claude/memokit/runs/$2/ledger.md"; }
