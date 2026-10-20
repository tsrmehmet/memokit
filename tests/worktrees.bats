#!/usr/bin/env bats
load helpers
# hooks/lib/worktrees.sh: leftover worktrees under .claude/worktrees/ and mk/*
# branches without a worktree, classified against the current branch.
# Every fixture is a throwaway repo under $BATS_TMPDIR.

g() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
gw() { local d="$1"; shift; git -C "$d" -c user.email=t@t -c user.name=t "$@"; }

wt_repo() {
  R="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkwt.XXXXXX")"
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

wt_list() {
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_list "$2" ${3:+"$3"}; echo "rc=$?"' x "$HOOKS" "$@"
}
tab="$(printf '\t')"
row() { printf '%s\n' "$output" | grep -F -- "$tab$1" | grep -vF -- "$tab$1/"; }
row_status() { row "$1" | cut -f2 | head -n1; }

@test "merged mk/ worktree is merged-clean, with a size and a UTC commit time" {
  wt_repo; wt_add mk-r1-a mk/r1/a
  wt_commit "$W/mk-r1-a" lane-a
  g merge -q --no-ff -m merge mk/r1/a
  wt_list "$R"
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^worktree	merged-clean	[0-9]+	[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	$W/mk-r1-a	mk/r1/a	head$"
  printf '%s\n' "$output" | grep -qx 'rc=0'
  rm -rf "$R"
}
@test "a worktree with uncommitted or untracked changes is dirty" {
  wt_repo; wt_add mk-r1-b mk/r1/b; wt_add mk-r1-u mk/r1/u
  printf 'x\n' >> "$W/mk-r1-b/a.txt"
  printf 'new\n' > "$W/mk-r1-u/new.txt"
  # A config that hides untracked files must not hide them from the check.
  g config status.showUntrackedFiles no
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-b")" = dirty ]
  [ "$(row_status "$W/mk-r1-u")" = dirty ]
  rm -rf "$R"
}
@test "a worktree whose branch has a commit not in the current branch is unmerged" {
  wt_repo; wt_add mk-r1-c mk/r1/c
  wt_commit "$W/mk-r1-c" lane-c
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-c")" = unmerged ]
  rm -rf "$R"
}
@test "mk/ branches without a worktree: unmerged is orphan-branch, merged is merged-clean" {
  wt_repo; wt_add mk-r1-d mk/r1/d
  wt_commit "$W/mk-r1-d" lane-d
  g worktree remove "$W/mk-r1-d"
  g branch mk/r1/e main
  g branch other main
  wt_list "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^branch	orphan-branch	0	[0-9T:-]+Z	mk/r1/d	mk/r1/d	-$"
  printf '%s\n' "$output" | grep -Eq "^branch	merged-clean	0	[0-9T:-]+Z	mk/r1/e	mk/r1/e	head$"
  lacks "$output" 'other'
  rm -rf "$R"
}
@test "Claude Code agent-* worktree on an unmerged feature branch is reported, never merged-clean" {
  wt_repo; wt_add agent-ae0336 feature/permissions
  wt_commit "$W/agent-ae0336" feat
  wt_list "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^worktree	unmerged	[0-9]+	.*	$W/agent-ae0336	feature/permissions	-$"
  rm -rf "$R"
}
@test "a checked-out mk/ branch outside .claude/worktrees is neither listed nor an orphan" {
  wt_repo
  O="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkwto.XXXXXX")"; O="$(cd -P "$O" && pwd -P)"
  g worktree add -q "$O/elsewhere" -b mk/r1/x main
  wt_list "$R"
  echo "$output"
  [ "$output" = "rc=0" ]
  rm -rf "$R" "$O"
}
@test "detached, locked and missing-directory worktrees are never merged-clean" {
  wt_repo
  g worktree add -q --detach "$W/agent-det" main
  wt_add mk-r1-l mk/r1/l; g worktree lock "$W/mk-r1-l"
  wt_add mk-r1-p mk/r1/p; rm -rf "$W/mk-r1-p"
  wt_add mk-r1-g mk/r1/g; rm -f "$W/mk-r1-g/.git"
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/agent-det")" = detached ]
  [ "$(row_status "$W/mk-r1-l")" = locked ]
  [ "$(row_status "$W/mk-r1-p")" = prunable ]
  [ "$(row "$W/mk-r1-p" | cut -f3)" = '?' ]
  [ "$(row_status "$W/mk-r1-g")" = prunable ]
  lacks "$output" 'merged-clean'
  rm -rf "$R"
}
@test "the worktree the session runs in is not listed; status is relative to its branch" {
  wt_repo; wt_add agent-me feature/me; wt_add mk-r1-s mk/r1/s
  wt_commit "$W/agent-me" mine
  # mk/r1/s is merged into agent-me's branch but not into main.
  gw "$W/mk-r1-s" reset -q --hard feature/me
  wt_list "$W/agent-me"
  echo "$output"
  lacks "$output" "$W/agent-me"
  [ "$(row_status "$W/mk-r1-s")" = merged-clean ]
  wt_list "$R"
  [ "$(row_status "$W/mk-r1-s")" = unmerged ]
  rm -rf "$R"
}
@test "a size not measured within the budget shows ?" {
  wt_repo; wt_add mk-r1-a mk/r1/a
  wt_list "$R" 0
  echo "$output"
  [ "$(row "$W/mk-r1-a" | cut -f3)" = '?' ]
  [ "$(row_status "$W/mk-r1-a")" = merged-clean ]
  rm -rf "$R"
}
@test "no worktrees and no mk/ branches: no output" {
  wt_repo
  wt_list "$R"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
  rm -rf "$R"
}
@test "a non-git directory is silent with exit 0" {
  d="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkng.XXXXXX")"
  wt_list "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
  wt_list "$d/does-not-exist"
  [ "$output" = "rc=0" ]
  rm -rf "$d"
}
@test "read-only: no index rewrite, no lock, nothing removed" {
  wt_repo; wt_add mk-r1-a mk/r1/a
  idx="$(git -C "$W/mk-r1-a" rev-parse --git-path index)"
  case "$idx" in /*) ;; *) idx="$W/mk-r1-a/$idx" ;; esac
  # A stat-dirty tracked file: a plain `git status` would refresh the index.
  touch -t 203001010000 "$W/mk-r1-a/a.txt"
  before="$(cksum < "$idx")"
  wt_list "$R"
  [ "$(row_status "$W/mk-r1-a")" = merged-clean ]
  [ "$(cksum < "$idx")" = "$before" ]
  [ -d "$W/mk-r1-a" ]
  git -C "$R" rev-parse -q --verify refs/heads/mk/r1/a >/dev/null
  rm -rf "$R"
}
@test "a path with a tab is shown with ? and keeps its row intact" {
  wt_repo; wt_add "x$(printf '\t')y" mk/r1/t
  wt_list "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^worktree	merged-clean	[0-9]+	[^	]+	$W/x\?y	mk/r1/t	head$"
  rm -rf "$R"
}

# --- merged = reachable from HEAD or the default branch (I1) ----------------
@test "merged into main while the session is on a feature branch: merged-clean, merged-into default" {
  wt_repo
  base="$(g rev-parse HEAD)"
  wt_add mk-r1-a mk/r1/a; wt_commit "$W/mk-r1-a" lane-a
  g merge -q --no-ff -m merge mk/r1/a
  g branch mk/r1/o mk/r1/a
  g checkout -q -b feature/x "$base"
  wt_list "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^worktree	merged-clean	[0-9]+	[^	]+	$W/mk-r1-a	mk/r1/a	default$"
  printf '%s\n' "$output" | grep -Eq "^branch	merged-clean	0	[^	]+	mk/r1/o	mk/r1/o	default$"
  rm -rf "$R"
}
@test "a lane in neither HEAD nor the default branch stays unmerged / orphan-branch" {
  wt_repo
  base="$(g rev-parse HEAD)"
  wt_add mk-r1-c mk/r1/c; wt_commit "$W/mk-r1-c" lane-c
  g branch mk/r1/o mk/r1/c
  g checkout -q -b feature/x "$base"
  wt_list "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^worktree	unmerged	[0-9]+	[^	]+	$W/mk-r1-c	mk/r1/c	-$"
  printf '%s\n' "$output" | grep -Eq "^branch	orphan-branch	0	[^	]+	mk/r1/o	mk/r1/o	-$"
  rm -rf "$R"
}
@test "origin/HEAD names the default branch when present; main is the fallback when absent" {
  wt_repo
  wt_add mk-r1-a mk/r1/a; wt_commit "$W/mk-r1-a" lane-a
  # The lane landed only in origin/develop (not in HEAD = main).
  g update-ref refs/remotes/origin/develop mk/r1/a
  g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-a")" = merged-clean ]
  [ "$(row "$W/mk-r1-a" | cut -f7)" = default ]
  g symbolic-ref --delete refs/remotes/origin/HEAD
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-a")" = unmerged ]
  rm -rf "$R"
}
@test "unborn HEAD and no default branch: nothing resolves, fail closed" {
  wt_repo
  wt_add mk-r1-a mk/r1/a
  g branch -q -m main trunk
  g checkout -q --orphan newroot
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-a")" = unmerged ]
  rm -rf "$R"
}

# --- the session's own worktree (I2) ----------------------------------------
@test "extra exclude dirs (the session cwd) drop their worktree" {
  wt_repo; wt_add agent-me feature/me; wt_add mk-r1-a mk/r1/a
  mkdir -p "$W/agent-me/sub"
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_list "$2" "" "$3"' x "$HOOKS" "$R" "$W/agent-me/sub"
  echo "$output"
  lacks "$output" "$W/agent-me"
  printf '%s\n' "$output" | grep -qF "$W/mk-r1-a"
  rm -rf "$R"
}

# --- count mode for session start (I3) --------------------------------------
@test "mk_wt_count: count, total KB and unmeasured count, without status/rev-list/log" {
  wt_repo; wt_add mk-r1-a mk/r1/a; wt_add agent-b feature/b; g branch mk/r1/o
  printf 'x\n' >> "$W/agent-b/a.txt"
  SHIM="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkshim.XXXXXX")"
  real="$(command -v git)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log"\nexec "%s" "$@"\n' "$SHIM" "$real" > "$SHIM/git"
  chmod +x "$SHIM/git"
  run env PATH="$SHIM:$PATH" "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_count "$2"' x "$HOOKS" "$R"
  echo "$output"; cat "$SHIM/log"
  printf '%s\n' "$output" | grep -Eq "^3	[0-9]+	0	0	$"
  [ "$(grep -cE '(^| )(status|rev-list|log)( |$)' "$SHIM/log")" -eq 0 ]
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_count "$2" 0' x "$HOOKS" "$R"
  printf '%s\n' "$output" | grep -Eq "^3	0	2	0	$"
  rm -rf "$R" "$SHIM"
}
@test "mk_wt_count prints nothing without leftovers or outside git" {
  wt_repo
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_count "$2"; mk_wt_count /; echo rc=$?' x "$HOOKS" "$R"
  [ "$output" = "rc=0" ]
  rm -rf "$R"
}

# --- sweep CLI -------------------------------------------------------------
sweep_wt() {
  run env -u MEMOKIT_SESSION_ID -u MEMOKIT_TRANSCRIPT_PATH CLAUDE_CONFIG_DIR="$R/.none" \
    "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$R" "$MK_REPO/skills/sweep/scripts/memokit-temp.sh" worktrees
}
wt_proj() { wt_repo; mkdir -p "$R/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$R/.claude/memokit.json"; }

@test "memokit-temp.sh worktrees: status first, human size, works without a temp tree" {
  wt_proj; wt_add mk-r1-a mk/r1/a; wt_add mk-r1-c mk/r1/c
  wt_commit "$W/mk-r1-c" lane-c
  sweep_wt
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^merged-clean	worktree	[0-9]+	[0-9.]+ (KB|MB|GB)	[0-9T:-]+Z	$W/mk-r1-a	mk/r1/a	head	-$"
  printf '%s\n' "$output" | grep -Eq "^unmerged	worktree	.*	$W/mk-r1-c	mk/r1/c	-	-$"
  rm -rf "$R"
}
@test "memokit-temp.sh worktrees marks names unsafe for a literal command as manual" {
  wt_proj; wt_add "a b" mk/r1/sp; wt_add ok-1 'mk/r1/semi;x'; wt_add "t$(printf '\t')u" mk/r1/tab
  sweep_wt
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | grep -qF "manual	worktree	"
  [ "$(printf '%s\n' "$output" | grep -c '^manual')" -eq 3 ]
  [ "$(printf '%s\n' "$output" | grep -c '^merged-clean')" -eq 0 ]
  rm -rf "$R"
}
@test "memokit-temp.sh worktrees refuses without config and prints nothing when there is nothing" {
  wt_proj
  sweep_wt
  [ "$status" -eq 0 ]; [ -z "$output" ]
  rm -f "$R/.claude/memokit.json"
  sweep_wt
  [ "$status" -eq 2 ]
  rm -rf "$R"
}
@test "memokit-temp.sh worktrees: the worktree the shell runs in is never listed (CLAUDE_PROJECT_DIR = main)" {
  wt_proj; wt_add agent-me feature/me; wt_add mk-r1-a mk/r1/a
  run env -u MEMOKIT_SESSION_ID -u MEMOKIT_TRANSCRIPT_PATH CLAUDE_PROJECT_DIR="$R" CLAUDE_CONFIG_DIR="$R/.none" \
    "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$W/agent-me" "$MK_REPO/skills/sweep/scripts/memokit-temp.sh" worktrees
  [ "$status" -eq 0 ]
  echo "$output"
  lacks "$output" "$W/agent-me"
  printf '%s\n' "$output" | grep -qF "$W/mk-r1-a"
  rm -rf "$R"
}
@test "memokit-temp.sh worktrees: ignored files make merged-ignored with their names; a nested repo makes manual" {
  wt_proj
  printf '.env\nnode_modules/\nvendor/\n' >> "$R/.gitignore"; g add -A; g commit -qm ignores
  wt_add mk-r1-i mk/r1/i; wt_add mk-r1-n mk/r1/n; wt_add mk-r1-c mk/r1/c
  printf 'SECRET=1\n' > "$W/mk-r1-i/.env"; mk_blob "$W/mk-r1-i/node_modules/x/y.js" 1
  git init -q "$W/mk-r1-n/vendor/dep"
  sweep_wt
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | grep -E "^merged-ignored	worktree	.*	$W/mk-r1-i	mk/r1/i	head	" | grep -F '.env' | grep -qF 'node_modules/'
  printf '%s\n' "$output" | grep -E "^manual	worktree	.*	$W/mk-r1-n	mk/r1/n	head	" | grep -qF 'vendor/'
  printf '%s\n' "$output" | grep -Eq "^merged-clean	worktree	.*	$W/mk-r1-c	mk/r1/c	head	-$"
  rm -rf "$R"
}
@test "memokit-temp.sh worktrees: a space in the repo path does not make a row manual" {
  P="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mk sp.XXXXXX")"; P="$(cd -P "$P" && pwd -P)"
  R="$P/repo dir"; mkdir -p "$R"
  git -C "$R" init -q; g symbolic-ref HEAD refs/heads/main
  printf '.claude/worktrees/\n' > "$R/.gitignore"; g add -A; g commit -qm init
  mkdir -p "$R/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$R/.claude/memokit.json"
  W="$R/.claude/worktrees"; wt_add mk-r1-a mk/r1/a; wt_add "q'x" mk/r1/q
  sweep_wt
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | grep -qF "merged-clean	worktree	"
  printf '%s\n' "$output" | grep -F "$W/mk-r1-a" | grep -q '^merged-clean'
  printf '%s\n' "$output" | grep -F "$W/q'x" | grep -q '^manual'
  rm -rf "$P"
}
@test "memokit-temp.sh worktrees: nested-repo search runs find only for ignored directories, not per ignored file" {
  wt_proj
  printf '*.log\nvendor/\n' >> "$R/.gitignore"; mkdir -p "$R/logs"; printf 'k\n' > "$R/logs/keep.txt"
  g add -A; g commit -qm ignores
  wt_add mk-r1-i mk/r1/i
  i=0; while [ "$i" -lt 2000 ]; do : > "$W/mk-r1-i/logs/f$i.log"; i=$((i + 1)); done
  mkdir -p "$W/mk-r1-i/vendor/x"; printf 'v\n' > "$W/mk-r1-i/vendor/x/v.txt"
  S="$R/.shim"; mkdir -p "$S"; real="$(command -v find)"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = .git ] && echo x >> "%s/calls"; done\nexec "%s" "$@"\n' "$S" "$real" > "$S/find"
  chmod +x "$S/find"
  t0="$(date +%s)"
  run env -u MEMOKIT_SESSION_ID -u MEMOKIT_TRANSCRIPT_PATH PATH="$S:$PATH" CLAUDE_CONFIG_DIR="$R/.none" \
    "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$R" "$MK_REPO/skills/sweep/scripts/memokit-temp.sh" worktrees
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  echo "$output"; echo "elapsed: $((t1 - t0)) s"
  printf '%s\n' "$output" | grep -E "^merged-ignored	worktree	.*	$W/mk-r1-i	mk/r1/i	head	" | grep -qF 'ignored: 2001'
  n="$(wc -l < "$S/calls" | tr -d ' ')"
  [ "$n" -eq 1 ] || { echo "find -name .git ran $n times"; false; }
  # Report-style bound (was 5.6 s with one find per file); generous for slow runners.
  [ $((t1 - t0)) -lt 10 ]
  rm -rf "$R"
}

# --- lanes of an active parallel run (final review I1) ------------------------
# ledger DIR RUN STATUS -- DIR/.claude/memokit/runs/RUN/ledger.md with that status.
ledger() { mkdir -p "$1/.claude/memokit/runs/$2"; printf '# Run %s\n\nstatus: %s\nintegration: main\n' "$2" "$3" > "$1/.claude/memokit/runs/$2/ledger.md"; }

@test "lanes and branches of an active run are active-run (never offerable); count leaves them out and names the run" {
  wt_repo
  ledger "$R" 20261018-1200 active
  wt_add mk-20261018-1200-L1 mk/20261018-1200/L1
  wt_add mk-20261018-1200-L2 mk/20261018-1200/L2; printf 'wip\n' >> "$W/mk-20261018-1200-L2/a.txt"
  g branch mk/20261018-1200/L3 main
  wt_add mk-r9-a mk/r9/a
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-20261018-1200-L1")" = active-run ]
  [ "$(row_status "$W/mk-20261018-1200-L2")" = active-run ]
  printf '%s\n' "$output" | grep -Eq "^branch	active-run	0	[^	]+	mk/20261018-1200/L3	mk/20261018-1200/L3	-$"
  [ "$(row "$W/mk-20261018-1200-L1" | cut -f7)" = - ]
  [ "$(row_status "$W/mk-r9-a")" = merged-clean ]
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_count "$2"' x "$HOOKS" "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^1	[0-9]+	0	3	20261018-1200$"
  rm -rf "$R"
}
@test "a closed or stopped run's lanes are reported normally" {
  wt_repo
  ledger "$R" r1 stopped; ledger "$R" r2 closed
  wt_add mk-r1-L1 mk/r1/L1; wt_add mk-r2-L1 mk/r2/L1
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-L1")" = merged-clean ]
  [ "$(row_status "$W/mk-r2-L1")" = merged-clean ]
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_count "$2"' x "$HOOKS" "$R"
  printf '%s\n' "$output" | grep -Eq "^2	[0-9]+	0	0	$"
  rm -rf "$R"
}
@test "only an active ledger's own run id matches: mk-r1-* of run r1, not run r10" {
  wt_repo
  ledger "$R" r1 active
  wt_add mk-r1-a mk/r1/a; wt_add mk-r10-a mk/r10/a
  # Markdown list/bold and CRLF forms of the status line count, too; a later
  # `status: active` (e.g. in a log line) does not.
  mkdir -p "$R/.claude/memokit/runs/r3" "$R/.claude/memokit/runs/r4"
  printf '# Run\r\n- **status:** active\r\n' > "$R/.claude/memokit/runs/r3/ledger.md"
  printf 'status: closed\nlog: status: active\n' > "$R/.claude/memokit/runs/r4/ledger.md"
  wt_add mk-r3-a mk/r3/a; wt_add mk-r4-a mk/r4/a
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r1-a")" = active-run ]
  [ "$(row_status "$W/mk-r10-a")" = merged-clean ]
  [ "$(row_status "$W/mk-r3-a")" = active-run ]
  [ "$(row_status "$W/mk-r4-a")" = merged-clean ]
  rm -rf "$R"
}

@test "ledger status line: Status with a capital and a last line without a newline still mark the run active (0.6.1 N1)" {
  wt_repo
  mkdir -p "$R/.claude/memokit/runs/r5" "$R/.claude/memokit/runs/r6"
  printf '# Run\nStatus: active\n' > "$R/.claude/memokit/runs/r5/ledger.md"
  printf 'status: active' > "$R/.claude/memokit/runs/r6/ledger.md"
  wt_add mk-r5-a mk/r5/a; wt_add mk-r6-a mk/r6/a
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$W/mk-r5-a")" = active-run ]
  [ "$(row_status "$W/mk-r6-a")" = active-run ]
  rm -rf "$R"
}

# --- lanes made from a sibling worktree (final review I2) ---------------------
@test "lanes under a sibling worktree's .claude/worktrees are listed; its ledger marks its active run" {
  wt_repo
  O="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkwts.XXXXXX")"; O="$(cd -P "$O" && pwd -P)"
  g worktree add -q "$O/p-feat" -b feat main
  S="$O/p-feat/.claude/worktrees"
  gw "$O/p-feat" worktree add -q "$S/mk-r1-a" -b mk/r1/a feat
  printf 'wip\n' >> "$S/mk-r1-a/a.txt"
  gw "$O/p-feat" worktree add -q "$S/mk-r2-b" -b mk/r2/b feat
  ledger "$O/p-feat" r2 active
  wt_list "$R"
  echo "$output"
  [ "$(row_status "$S/mk-r1-a")" = dirty ]
  [ "$(row_status "$S/mk-r2-b")" = active-run ]
  lacks "$output" "	$O/p-feat	"
  # From a session in the sibling itself, too.
  wt_list "$O/p-feat"
  echo "$output"
  [ "$(row_status "$S/mk-r1-a")" = dirty ]
  [ "$(row_status "$S/mk-r2-b")" = active-run ]
  run "$MK_BASH" -c '. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"; mk_wt_count "$2"' x "$HOOKS" "$R"
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^1	[0-9]+	0	1	r2$"
  rm -rf "$R" "$O"
}
@test "memokit-temp.sh worktrees: an active run's lanes are active-run with the run id in the note, never merged-clean" {
  wt_proj
  ledger "$R" 20261018-1200 active
  wt_add mk-20261018-1200-L1 mk/20261018-1200/L1
  g branch mk/20261018-1200/L2 main
  sweep_wt
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | grep -Eq "^active-run	worktree	[0-9]+	[^	]+	[^	]+	$W/mk-20261018-1200-L1	mk/20261018-1200/L1	-	run 20261018-1200 \(/memokit:resume\)$"
  printf '%s\n' "$output" | grep -Eq "^active-run	branch	0	0 KB	[^	]+	mk/20261018-1200/L2	mk/20261018-1200/L2	-	run 20261018-1200 \(/memokit:resume\)$"
  lacks "$output" 'merged-clean'
  rm -rf "$R"
}
