#!/usr/bin/env bash
# memokit leftover-worktree library. Sourced after common.sh, never executed.
# bash 3.2-safe; BSD (macOS) and GNU (Linux) du/sleep; git >= 2.7 (2.36+ for
# NUL-separated `worktree list -z`, with a newline fallback below it).
# Consumers: session-start.sh (mk_wt_count, one report line), the sweep CLI
# (skills/sweep/scripts/memokit-temp.sh worktrees, mk_wt_list) and
# guard-destructive.sh through lib/careful.sh (mk_wt_removable,
# mk_wt_branch_removable: the main session's code-free lane cleanup, at the
# end of this file).
#
# Leftovers: every `git worktree list` entry directly under <W>/.claude/worktrees/
# for ANY listed worktree W -- the main one or a sibling made by `git worktree
# add`, wherever the session that created the lane ran (memokit lanes
# mk-<run>-<lane>, Claude Code's agent-*) -- except the worktree DIR is in and
# the worktree of every EXCLUDE_DIR (the session's cwd), plus every
# refs/heads/mk/* branch checked out in no worktree at all. An mk/* branch
# checked out in a worktree outside every .claude/worktrees/ is not one.
#
# Active runs: a run whose ledger <W>/.claude/memokit/runs/<run>/ledger.md (W
# any listed worktree: the ledger lives in the checkout that ran the skill)
# has `status: active` as its first `status:` line (within the first 60
# lines; a leading "- ", "*" or "#" and "**" bold are allowed). Its lanes --
# worktrees named mk-<run>-* or on a branch mk/<run>/*, and branches
# mk/<run>/* -- belong to the run, which resumes them: they are status
# active-run, never offerable, and not counted as leftovers. `stopped` and
# `closed` runs are not active. <run> must match [A-Za-z0-9._-]+.
#
# mk_wt_list [DIR] [TICKS] [EXCLUDE_DIR...] -- READ-ONLY. DIR defaults to
# $MK_ROOT, an empty TICKS to 100. One TSV line per leftover:
#   <kind> \t <status> \t <kb> \t <last-commit-utc> \t <path-or-branch> \t <branch> \t <merged-into>
#   kind    worktree | branch
#   status  first match wins:
#     worktree rows
#       active-run    a lane of an active run (above); no status is read
#       prunable      registered, but the directory or its .git link is gone
#       dirty         `git status --porcelain` (untracked included, whatever
#                     status.showUntrackedFiles says) is non-empty, or the
#                     status could not be read
#       locked        `git worktree lock`ed (Claude Code may lock a live one)
#       detached      detached HEAD: memokit cannot prove its history is kept
#       unmerged      not merged (below), or that cannot be computed
#       merged-clean  none of the above: the only offerable worktree status
#     branch rows
#       active-run    a branch of an active run (above)
#       orphan-branch not merged, or that cannot be computed
#       merged-clean  merged: the only offerable branch status
#   "merged": every commit of the tip is reachable from DIR's HEAD or from the
#   default branch -- refs/remotes/origin/HEAD's target, else refs/heads/main,
#   else refs/heads/master, the first that resolves. An unborn HEAD is
#   dropped; when neither resolves nothing is merged (fail closed).
#   kb      `du -sk`, all entries measured in parallel within TICKS x 0.02 s
#           (about 2 s); "?" when not measured in time or not measurable.
#           Branch rows are 0.
#   last    committer date of the tip, UTC, YYYY-MM-DDTHH:MM:SSZ ("?" unknown)
#   field 5 the worktree path or the branch name; field 6 the short branch name
#           ("-" for a detached HEAD). A tab, newline or CR in a path is shown
#           as "?" so every row stays one line.
#   merged-into  head | default for a merged tip ("head" when HEAD has it),
#           "-" otherwise.
#
# mk_wt_count [DIR] [TICKS] [EXCLUDE_DIR...] -- the same leftovers, counted
# for session start: one line "<count> \t <total kb> \t <rows not measured>
# \t <active-run rows> \t <their run ids, ", " separated>", where count, kb
# and unmeasured leave the active-run rows out (they are not measured);
# nothing when there are no rows at all. No status, rev-list or log calls (a
# status is unbounded on a big worktree); only the bounded du.
#
# Both print nothing when DIR is not in a git work tree or git is missing,
# always return 0 and write nothing to stderr.
#
# Safety: every git call is a read under --no-optional-locks (no index
# refresh, so a concurrent commit in a lane is never blocked by a lock), and
# GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_COMMON_DIR are unset so the caller's
# environment cannot redirect the reads. When unsure, a row is classified as
# not offerable; the consumers offer only merged-clean rows.
# Not seen (documented limit, README Limitations): an unregistered nested
# repository in an ignored directory of a lane (`git init` under
# node_modules/) -- merged-clean does not look into ignored files, so the code-free
# lane removal (mk_wt_removable) deletes it with the lane. A nested worktree
# that `git worktree list` shows is refused.
# Cost when there is nothing: two git calls (`worktree list -z`, `for-each-ref
# refs/heads/mk/`); session start measured +16 ms on an empty repo and
# 120 ms total with 10 worktrees of 3000 files (was 0.9 s with a status each).
# Ledgers are read (bash builtins, no fork) only when there is a row.

# _mk_wt_ledger_active FILE -- 0 when FILE's first `status:` line within its
# first 60 lines says active (`Status:` too; a last line without a newline
# counts).
_mk_wt_ledger_active() {
  local ln k=0 v
  [ -f "$1" ] || return 1
  while [ "$k" -lt 60 ] && { IFS= read -r ln || [ -n "$ln" ]; }; do
    k=$((k + 1))
    v="${ln#"${ln%%[!	 #*-]*}"}"
    case "$v" in
      [Ss]tatus:*)
        v="${v#?tatus:}"; v="${v//\*/}"
        v="${v#"${v%%[![:space:]]*}"}"
        case "$v" in active|active[[:space:]]*) return 0 ;; *) return 1 ;; esac ;;
    esac
  done < "$1" 2>/dev/null
  return 1
}

# _mk_wt_git ARGS... -- git for reads only. With _MK_WT_SECS set (only inside
# mk_wt_removable / mk_wt_branch_removable) the call is bounded: a git still
# running after _MK_WT_SECS seconds is killed and the call fails, so the
# caller fails closed. A killer job (its sleep ended by a TERM trap) instead
# of _mk_wt_sizes' polling: same bound, no 0.02 s tick added to every call.
# Its output goes to /dev/null so a $(...) around the call never waits on it.
# One time bound per lookup: the killer that kills a git also creates the
# marker file _MK_WT_DEAD (noclobber), and every later bounded call of the
# same lookup fails at once while it exists (so a hung `worktree list -z`
# skips its fallback, a hung rev-list its second run). A marker that exists
# for any other reason only makes the lookup fail: fail closed.
_mk_wt_git() {
  local pid kp rc
  if [ -n "${_MK_WT_SECS:-}" ]; then
    if [ -n "${_MK_WT_DEAD:-}" ] && [ -e "$_MK_WT_DEAD" ]; then return 124; fi
    git --no-optional-locks "$@" </dev/null &
    pid=$!
    # shellcheck disable=SC2016  # $sp is expanded when the trap runs
    ( trap 'kill "$sp" 2>/dev/null; exit 0' TERM
      { sleep "$_MK_WT_SECS" 2>/dev/null || sleep 2; } & sp=$!
      wait "$sp"
      if kill "$pid" 2>/dev/null && [ -n "${_MK_WT_DEAD:-}" ]; then set -C; : > "$_MK_WT_DEAD"; fi
    ) >/dev/null 2>&1 </dev/null 3>&- &
    kp=$!
    wait "$pid"; rc=$?
    kill "$kp" 2>/dev/null
    return "$rc"
  fi
  git --no-optional-locks "$@"
}

# _mk_wt_bound -- in the calling subshell: bound every git call (1.5 s, 75
# ticks of 0.02 s) with one timeout marker for the whole lookup, removed when
# the subshell exits (no fork unless a call timed out).
_mk_wt_bound() {
  _MK_WT_SECS=1.5
  _MK_WT_DEAD="${TMPDIR:-/tmp}/memokit-wt-dead-$$-$RANDOM$RANDOM"
  trap '[ -e "$_MK_WT_DEAD" ] && rm -f "$_MK_WT_DEAD"' EXIT
}

# _mk_wt_show STR -- STR with every tab, newline and CR replaced by "?".
_mk_wt_show() {
  local s="$1" t nl=$'\n' cr=$'\r'
  t="$(printf '\t')"
  s="${s//$t/?}"; s="${s//$nl/?}"; s="${s//$cr/?}"
  printf '%s' "$s"
}

# _mk_wt_date DIR REV -- committer date of REV, UTC ISO, or "?".
_mk_wt_date() {
  local d
  d="$(TZ=UTC _mk_wt_git -C "$1" log -1 --format=%cd --date=format-local:%Y-%m-%dT%H:%M:%SZ "$2" -- 2>/dev/null)"
  case "$d" in [0-9][0-9][0-9][0-9]-*Z) printf '%s' "$d" ;; *) printf '?' ;; esac
}

# _mk_wt_commit DIR REF -- the commit REF resolves to, or nothing (status 1).
_mk_wt_commit() {
  local c
  # git's own status on failure (a killed bounded call shows as > 128).
  c="$(_mk_wt_git -C "$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null)" || return "$?"
  case "$c" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s' "$c"
}

# _mk_wt_killed RC -- in a bounded lookup (_MK_WT_SECS set), RC is the status
# of a git call that did not run to its end: 124 (refused after an earlier
# timeout) or above 128 (killed by a signal, the bound's TERM among them).
# The caller then fails the lookup instead of reading a partial answer.
_mk_wt_killed() {
  [ -n "${_MK_WT_SECS:-}" ] || return 1
  [ "$1" -eq 124 ] || [ "$1" -gt 128 ]
}

# _mk_wt_merged DIR TIP HEAD_SHA DEFAULT_SHA -- prints "head" or "default" and
# returns 0 when every commit of TIP is reachable from one of the two (either
# may be empty); returns 1 otherwise, on any failure, or when both are empty.
_mk_wt_merged() {
  local dir="$1" tip="$2" h="$3" df="$4" c rc
  [ -n "$tip" ] || return 1
  if [ -n "$h" ]; then
    rc=0
    c="$(_mk_wt_git -C "$dir" rev-list --count "$tip" --not "$h" -- 2>/dev/null)" || { rc=$?; c=""; }
    _mk_wt_killed "$rc" && return 1
    [ "$c" = 0 ] && { printf 'head'; return 0; }
  fi
  if [ -n "$df" ]; then
    c="$(_mk_wt_git -C "$dir" rev-list --count "$tip" --not "$df" -- 2>/dev/null)" || return 1
    [ "$c" = 0 ] && { printf 'default'; return 0; }
  fi
  return 1
}

# _mk_wt_sizes TICKS PATH... -- prints one "<kb>" or "?" line per PATH, in
# order. All du runs start at once; whatever has not finished after TICKS
# polls of 0.02 s is killed and reported as "?". A sleep without fractional
# seconds falls back to 1 s steps that count as 50 ticks, so the bound holds.
_mk_wt_sizes() {
  local ticks="$1" d i n p t left kb tab
  local -a pids
  shift
  tab="$(printf '\t')"
  n=$#
  d="$(mktemp -d "${TMPDIR:-/tmp}/memokit-wt.XXXXXX" 2>/dev/null)" || d=""
  i=0
  for p in "$@"; do
    pids[i]=""
    if [ -n "$d" ] && [ "$ticks" -gt 0 ] && [ -d "$p" ] && [ ! -L "$p" ]; then
      du -sk -- "$p" > "$d/$i" 2>/dev/null &
      pids[i]=$!
    fi
    i=$((i + 1))
  done
  t=0
  while [ "$t" -lt "$ticks" ]; do
    left=0; i=0
    while [ "$i" -lt "$n" ]; do
      if [ -n "${pids[i]}" ] && kill -0 "${pids[i]}" 2>/dev/null; then left=1; break; fi
      i=$((i + 1))
    done
    [ "$left" -eq 1 ] || break
    if sleep 0.02 2>/dev/null; then t=$((t + 1)); else sleep 1; t=$((t + 50)); fi
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    kb="?"
    if [ -n "${pids[i]}" ]; then
      if kill -0 "${pids[i]}" 2>/dev/null; then
        kill "${pids[i]}" 2>/dev/null
        wait "${pids[i]}" 2>/dev/null
      else
        # du's total counts even when it also reported an unreadable subdir
        # (nonzero exit): the size is then a lower bound, still worth showing.
        wait "${pids[i]}" 2>/dev/null
        kb="$(head -n 1 "$d/$i" 2>/dev/null)"; kb="${kb%%"$tab"*}"
        case "$kb" in ''|*[!0-9]*) kb="?" ;; esac
      fi
    fi
    printf '%s\n' "$kb"
    i=$((i + 1))
  done
  [ -n "$d" ] && rm -rf "$d" 2>/dev/null
  return 0
}

# Per-worktree helpers, shared by _mk_wt_run and mk_wt_removable /
# mk_wt_branch_removable. They read and set plain globals (wl_*, n, cur, act,
# wr, hc, dc, st, mi), which only ever exist inside those functions'
# subshells.

# _mk_wt_field FIELD -- one `git worktree list --porcelain` field into the
# parallel wl_* arrays (one entry per worktree).
_mk_wt_field() {
  case "$1" in
    "worktree "*)
      cur=$n; n=$((n + 1))
      wl_path[cur]="${1#worktree }"; wl_head[cur]=""; wl_br[cur]=""
      wl_det[cur]=0; wl_lock[cur]=0; wl_prune[cur]=0; wl_bare[cur]=0 ;;
    "HEAD "*) [ "$cur" -ge 0 ] && wl_head[cur]="${1#HEAD }" ;;
    "branch "*) [ "$cur" -ge 0 ] && wl_br[cur]="${1#branch }" ;;
    detached) [ "$cur" -ge 0 ] && wl_det[cur]=1 ;;
    bare) [ "$cur" -ge 0 ] && wl_bare[cur]=1 ;;
    locked|"locked "*) [ "$cur" -ge 0 ] && wl_lock[cur]=1 ;;
    prunable|"prunable "*) [ "$cur" -ge 0 ] && wl_prune[cur]=1 ;;
  esac
  return 0
}

# _mk_wt_parse DIR -- `git worktree list --porcelain` of DIR into the wl_*
# arrays and n (entry 0 is the main worktree). -z keeps a path with a newline
# in one field; older git (no -z) falls back to lines. 1 when nothing was
# listed.
#
# Bounded (_MK_WT_SECS set): the parent decides from git's exit status, which
# the process substitution appends as a last record "mk-rc <status>" (no git
# field starts with "mk-rc "; a field cut short by a kill has no NUL and
# swallows the record). Anything but a status-0 record means a listing that
# did not run to its end: fail, and no newline fallback (git < 2.36 thus
# never gets the code-free cleanup). It does not rely on the timeout marker.
_mk_wt_parse() {
  local f wl zrc=""
  wl_path=(); wl_head=(); wl_br=(); wl_det=(); wl_lock=(); wl_prune=(); wl_bare=()
  n=0; cur=-1
  while IFS= read -r -d '' f; do
    case "$f" in "mk-rc "*) zrc="${f#mk-rc }"; continue ;; esac
    _mk_wt_field "$f"
  done < <(_mk_wt_git -C "$1" worktree list --porcelain -z 2>/dev/null; printf 'mk-rc %s\0' "$?")
  if [ -n "${_MK_WT_SECS:-}" ]; then
    [ "$zrc" = 0 ] && [ "$n" -gt 0 ]
    return
  fi
  if [ "$n" -eq 0 ]; then
    wl="$(_mk_wt_git -C "$1" worktree list --porcelain 2>/dev/null)" || return 1
    while IFS= read -r f; do _mk_wt_field "$f"; done <<EOF
$wl
EOF
  fi
  [ "$n" -gt 0 ]
}

# _mk_wt_actives -- act: the ids of the active runs, from the ledgers of every
# listed worktree (header). Needs globbing.
_mk_wt_actives() {
  local i lg r
  act=()
  i=0
  while [ "$i" -lt "$n" ]; do
    for lg in "${wl_path[i]}"/.claude/memokit/runs/*/ledger.md; do
      [ -f "$lg" ] || continue
      r="${lg%/ledger.md}"; r="${r##*/}"
      case "$r" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      _mk_wt_ledger_active "$lg" && act[${#act[@]}]="$r"
    done
    i=$((i + 1))
  done
  return 0
}

# _mk_wt_run_of PATH BRANCH -- 0 and wr=<run> when the lane (worktree basename
# mk-<run>-*, or branch refs/heads/mk/<run>/*) belongs to an active run (act).
# No subshell: it runs per row.
_mk_wt_run_of() {
  local a b="${1##*/}"
  wr=""
  for a in ${act[@]+"${act[@]}"}; do
    case "$b" in "mk-$a-"?*) wr="$a"; return 0 ;; esac
    case "$2" in "refs/heads/mk/$a/"?*) wr="$a"; return 0 ;; esac
  done
  return 1
}

# _mk_wt_refs DIR [main] -- the merge references, resolved once: hc = DIR's
# HEAD commit (with "main": the main worktree's, wl_head[0], parsed already),
# dc = the default branch's (header); either empty when unresolved. dref is
# the default branch's ref ("" when none resolves).
# Bounded: a call that did not run to its end (_mk_wt_killed) clears all three
# and returns 1 -- a killed origin/HEAD lookup must not quietly make main the
# default. Unbounded (mk_wt_list): always 0, as before.
_mk_wt_refs() {
  local od c rc
  if [ "${2:-}" = main ]; then
    hc="${wl_head[0]:-}"
    case "$hc" in *[!0-9a-f]*) hc="" ;; esac
    [ "${wl_bare[0]:-1}" -eq 0 ] || hc=""
  else
    rc=0
    hc="$(_mk_wt_commit "$1" HEAD)" || { rc=$?; hc=""; }
    if _mk_wt_killed "$rc"; then hc=""; dc=""; dref=""; return 1; fi
  fi
  dc=""; dref=""
  rc=0
  od="$(_mk_wt_git -C "$1" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" || { rc=$?; od=""; }
  if _mk_wt_killed "$rc"; then hc=""; return 1; fi
  for c in "$od" refs/heads/main refs/heads/master; do
    [ -n "$c" ] || continue
    rc=0
    dc="$(_mk_wt_commit "$1" "$c")" || rc=$?
    if [ "$rc" -eq 0 ]; then dref="$c"; break; fi
    dc=""
    if _mk_wt_killed "$rc"; then hc=""; return 1; fi
  done
  return 0
}

# _mk_wt_status DIR I -- st and mi of worktree entry I: the status and
# merged-into columns of a worktree row (header; active-run first, then
# prunable, dirty, locked, detached, merged-clean, unmerged). Reads wl_*,
# act, hc, dc.
_mk_wt_status() {
  local i="$2" p h so sr
  p="${wl_path[i]}"; h="${wl_head[i]}"
  mi="-"
  case "$h" in *[!0-9a-f]*) h="" ;; esac
  if _mk_wt_run_of "$p" "${wl_br[i]}"; then
    st=active-run
  elif [ "${wl_prune[i]}" -eq 1 ] || [ ! -d "$p" ] || [ -L "$p" ] || [ ! -f "$p/.git" ]; then
    st=prunable
  else
    so="$(_mk_wt_git -C "$p" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)"
    sr=$?
    if [ "$sr" -ne 0 ] || [ -n "$so" ]; then st=dirty
    elif [ "${wl_lock[i]}" -eq 1 ]; then st=locked
    elif [ "${wl_det[i]}" -eq 1 ]; then st=detached
    elif mi="$(_mk_wt_merged "$1" "$h" "$hc" "$dc")"; then st=merged-clean
    else st=unmerged; mi="-"
    fi
  fi
  return 0
}

# _mk_wt_run MODE DIR TICKS EXCLUDE_DIR... -- the shared body (MODE list or
# count). It runs in a subshell: the unset git variables and the parser state
# never leak into the caller; stderr (job notices included) is discarded.
_mk_wt_run() (
  mode="$1"; dir="${2:-${MK_ROOT:-}}"; ticks="${3:-100}"
  shift 3 2>/dev/null || shift $#
  case "$ticks" in ''|*[!0-9]*) ticks=100 ;; esac
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then exit 0; fi
  command -v git >/dev/null 2>&1 || exit 0
  tab="$(printf '\t')"

  # Parse `git worktree list --porcelain` (_mk_wt_parse).
  _mk_wt_parse "$dir" || exit 0

  # Candidates: worktrees under <W>/.claude/worktrees/ of any listed W, minus
  # DIR's own and each EXCLUDE_DIR's. With only the main worktree there is
  # nothing to look at (and no rev-parse).
  bases=(); i=0
  while [ "$i" -lt "$n" ]; do bases[i]="${wl_path[i]}/.claude/worktrees"; i=$((i + 1)); done
  cand=()
  if [ "$n" -gt 1 ]; then
    top="$(_mk_wt_git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
    [ -n "$top" ] || exit 0
    tops=("$top")
    for x in "$@"; do
      if [ -z "$x" ] || [ ! -d "$x" ]; then continue; fi
      t="$(_mk_wt_git -C "$x" rev-parse --show-toplevel 2>/dev/null)" || continue
      [ -n "$t" ] && tops[${#tops[@]}]="$t"
    done
    i=1
    while [ "$i" -lt "$n" ]; do
      p="${wl_path[i]}"
      ok=0
      for b in "${bases[@]}"; do
        case "$p" in "$b"/?*) ok=1; break ;; esac
        if [ "${p##*/}" != "$p" ] && [ "${p%/*}" -ef "$b" ]; then ok=1; break; fi
      done
      [ "${wl_bare[i]}" -eq 0 ] || ok=0
      for t in "${tops[@]}"; do [ "$p" -ef "$t" ] && ok=0; done
      [ "$ok" -eq 1 ] && cand[${#cand[@]}]=$i
      i=$((i + 1))
    done
  fi

  # Orphan mk/* branches: one for-each-ref, empty in the common case.
  orphans=()
  refs="$(_mk_wt_git -C "$dir" for-each-ref --format='%(refname)' refs/heads/mk/ 2>/dev/null)"
  if [ -n "$refs" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      used=0; i=0
      while [ "$i" -lt "$n" ]; do
        [ "${wl_br[i]}" = "$r" ] && { used=1; break; }
        i=$((i + 1))
      done
      [ "$used" -eq 0 ] && orphans[${#orphans[@]}]="$r"
    done <<EOF
$refs
EOF
  fi
  [ "${#cand[@]}" -gt 0 ] || [ "${#orphans[@]}" -gt 0 ] || exit 0

  # Active runs: the ledgers of every listed worktree (_mk_wt_actives).
  _mk_wt_actives
  # Split the rows: live = leftover candidates, lorph = leftover orphans,
  # nact = active-run rows, aruns = their distinct run ids.
  live=(); lorph=(); nact=0; aruns=""
  _wt_note_run() { nact=$((nact + 1)); case ", $aruns, " in *", $wr, "*) ;; *) aruns="${aruns:+$aruns, }$wr" ;; esac; }
  for i in ${cand[@]+"${cand[@]}"}; do
    if _mk_wt_run_of "${wl_path[i]}" "${wl_br[i]}"; then _wt_note_run; else live[${#live[@]}]=$i; fi
  done
  for r in ${orphans[@]+"${orphans[@]}"}; do
    if _mk_wt_run_of "" "$r"; then _wt_note_run; else lorph[${#lorph[@]}]="$r"; fi
  done

  # Sizes of every worktree row at once, within the budget (a missing or
  # symlinked directory is not measured: "?"). Count mode skips active-run rows.
  sizep=()
  if [ "$mode" = count ]; then
    for i in ${live[@]+"${live[@]}"}; do sizep[${#sizep[@]}]="${wl_path[i]}"; done
  else
    for i in ${cand[@]+"${cand[@]}"}; do sizep[${#sizep[@]}]="${wl_path[i]}"; done
  fi
  sizes=""
  [ "${#sizep[@]}" -gt 0 ] && sizes="$(_mk_wt_sizes "$ticks" "${sizep[@]}")"
  kbs=()
  while IFS= read -r kb; do [ -n "$kb" ] && kbs[${#kbs[@]}]="$kb"; done <<EOF
$sizes
EOF

  if [ "$mode" = count ]; then
    tot=0; unm=0
    for kb in ${kbs[@]+"${kbs[@]}"}; do
      case "$kb" in ''|*[!0-9]*) unm=$((unm + 1)) ;; *) tot=$((tot + kb)) ;; esac
    done
    printf '%s\t%s\t%s\t%s\t%s\n' "$(( ${#live[@]} + ${#lorph[@]} ))" "$tot" "$unm" "$nact" "$aruns"
    exit 0
  fi

  # The merge references, resolved once (_mk_wt_refs).
  _mk_wt_refs "$dir"

  # Classify the worktrees (_mk_wt_status).
  k=0
  for i in ${cand[@]+"${cand[@]}"}; do
    p="${wl_path[i]}"; h="${wl_head[i]}"; br="${wl_br[i]#refs/heads/}"
    [ "${wl_det[i]}" -eq 1 ] && br="-"
    [ -n "$br" ] || br="-"
    case "$h" in *[!0-9a-f]*) h="" ;; esac
    _mk_wt_status "$dir" "$i"
    if [ -n "$h" ]; then last="$(_mk_wt_date "$dir" "$h")"; else last="?"; fi
    printf 'worktree\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "${kbs[k]:-?}" "$last" "$(_mk_wt_show "$p")" "$(_mk_wt_show "$br")" "$mi"
    k=$((k + 1))
  done

  # Classify the orphan branches.
  for r in ${orphans[@]+"${orphans[@]}"}; do
    b="${r#refs/heads/}"
    # shellcheck disable=SC2030  # st is meant to stay in this subshell (as in mk_wt_removable's)
    if _mk_wt_run_of "" "$r"; then st=active-run; mi="-"
    elif mi="$(_mk_wt_merged "$dir" "$r" "$hc" "$dc")"; then st=merged-clean; else st=orphan-branch; mi="-"; fi
    printf 'branch\t%s\t0\t%s\t%s\t%s\t%s\n' "$st" "$(_mk_wt_date "$dir" "$r")" "$b" "$b" "$mi"
  done
  exit 0
) 2>/dev/null

# _mk_wt_phys PATH -- wp: the absolute PATH with its deepest existing
# directory resolved by cd -P (builtin, no fork; it changes the cwd of the
# calling subshell) and the missing rest appended, so a listed worktree whose
# directory is gone still resolves through its existing parents. 1 for a
# relative PATH, or a missing rest holding "." or ".." (fail closed).
_mk_wt_phys() {
  local d="$1" rest=""
  case "$d" in /*) ;; *) return 1 ;; esac
  while :; do
    if [ -d "$d" ] && cd -P -- "$d" 2>/dev/null; then
      case "$rest" in */.|*/./*|*/..|*/../*) return 1 ;; esac
      if [ "$PWD" = / ]; then wp="${rest:-/}"; else wp="$PWD$rest"; fi
      return 0
    fi
    case "$d" in
      /*/*) rest="/${d##*/}$rest"; d="${d%/*}" ;;
      /?*) rest="$d$rest"; d=/ ;;
      *) return 1 ;;
    esac
  done
}

# mk_wt_removable PATH CWD [EXCLUDE_DIR...] -- 0 when the lane worktree PATH
# may be removed without an approval code (spec 0.8 Part D, main session; the
# caller is lib/careful.sh). All of:
#   - PATH is an absolute path to a directory that is no symlink;
#   - `git worktree list` of CWD (the payload cwd: the repository the command
#     runs in) lists it (-ef), and it is not the main (first) or a bare one;
#   - it is a lane: its physical parent (cd -P) is <W>/.claude/worktrees of
#     a listed worktree W (-ef), i.e. PATH is a direct child of it; a manual
#     worktree elsewhere (../manual, <repo>/inrepo) never qualifies;
#   - no other listed worktree lies inside it (a nested lane of a session
#     that ran in it), and neither CWD nor any EXCLUDE_DIR (the project dir)
#     does (each one and every ancestor compared with -ef; no fork);
#   - its status by the rules of mk_wt_list is merged-clean, "merged" judged
#     against the MAIN worktree's HEAD or the default branch, never the HEAD
#     of a lane the cwd may be in.
# Gitignored files do not block (the dirty check does not list them); an
# unregistered nested repository in an ignored directory is not seen either
# (README Limitations). 1 otherwise, also for an empty or relative PATH or
# CWD, a missing git and any git error. Every git call is bounded
# (_mk_wt_bound: 1.5 s, one timeout ends the whole lookup) and fails closed.
# Read-only; a subshell, stderr discarded.
mk_wt_removable() (
  p="${1:-}"; cwd="${2:-}"
  shift 2 2>/dev/null || shift $#
  set +f
  LC_ALL=C
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  _mk_wt_bound
  case "$p" in /*) ;; *) exit 1 ;; esac
  case "$cwd" in /*) ;; *) exit 1 ;; esac
  if [ ! -d "$p" ] || [ -L "$p" ] || [ ! -d "$cwd" ]; then exit 1; fi
  command -v git >/dev/null 2>&1 || exit 1
  _mk_wt_parse "$cwd" || exit 1
  k=-1; i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${wl_path[i]}" -ef "$p" ]; then k=$i; break; fi
    i=$((i + 1))
  done
  [ "$k" -ge 1 ] || exit 1
  [ "${wl_bare[k]}" -eq 0 ] || exit 1
  # A lane: the physical parent is some listed W's .claude/worktrees.
  cd -P -- "$p" 2>/dev/null || exit 1
  pp="${PWD%/*}"
  [ -n "$pp" ] || exit 1
  lane=0; j=0
  while [ "$j" -lt "$n" ]; do
    if [ "$pp" -ef "${wl_path[j]}/.claude/worktrees" ]; then lane=1; break; fi
    j=$((j + 1))
  done
  [ "$lane" -eq 1 ] || exit 1
  # No other listed worktree inside PATH: its path, resolved like PATH
  # (_mk_wt_phys: git keeps a path as recorded, which may run through a
  # symlink into this lane), or any ancestor of that is PATH. The resolved
  # path has no symlink left, so its string ancestors are real directories.
  j=0
  while [ "$j" -lt "$n" ]; do
    if [ "$j" -ne "$k" ]; then
      _mk_wt_phys "${wl_path[j]}" || exit 1
      d="$wp"
      while :; do
        [ "$d" -ef "$p" ] && exit 1
        case "$d" in /?*) d="${d%/*}" ;; *) break ;; esac
      done
    fi
    j=$((j + 1))
  done
  # Neither CWD nor an EXCLUDE_DIR may lie in PATH: each one's physical path
  # (cd -P sets PWD; no fork) and every ancestor of it is compared with -ef.
  for x in "$cwd" "$@"; do
    [ -n "$x" ] || continue
    cd -P -- "$x" 2>/dev/null || exit 1
    d="$PWD"
    while :; do
      [ "$d" -ef "$p" ] && exit 1
      case "$d" in /?*) d="${d%/*}" ;; *) break ;; esac
    done
  done
  _mk_wt_actives
  _mk_wt_refs "$cwd" main || exit 1
  _mk_wt_status "$cwd" "$k"
  # shellcheck disable=SC2031  # st is set by _mk_wt_status in this same subshell
  [ "$st" = merged-clean ]
) 2>/dev/null

# mk_wt_branch_removable NAME CWD [GONE_PATH...] -- 0 when branch NAME
# ([A-Za-z0-9._/-], not starting with "-") may be deleted without an
# approval code (spec 0.8 Part D, main session; caller lib/careful.sh). All of:
#   - refs/heads/NAME exists spelled exactly so (`for-each-ref refs/heads/`
#     lists it verbatim: on a case-insensitive file system MK/LANE would
#     otherwise resolve to mk/lane);
#   - NAME is not, in any case, the default branch (origin/HEAD's local
#     name, main, master) or the branch the main worktree has checked out;
#   - no worktree `git worktree list` of CWD shows checks out NAME in any
#     case -- except one checking out exactly NAME that is among GONE_PATH,
#     the lanes mk_wt_removable accepted for an earlier `git worktree remove`
#     of the same command (git itself refuses to delete a branch still
#     checked out, should that removal not happen);
#   - its tip is merged: every commit reachable from the MAIN worktree's
#     HEAD or the default branch (mk_wt_list's "merged"; `git branch
#     --merged` gives the same set for those two).
# 1 otherwise and on any git error; git calls bounded as in mk_wt_removable.
mk_wt_branch_removable() (
  b="${1:-}"; cwd="${2:-}"
  shift 2 2>/dev/null || shift $#
  set +f
  LC_ALL=C
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  _mk_wt_bound
  bnl='
'
  case "$b" in ''|-*|*[!A-Za-z0-9._/-]*) exit 1 ;; esac
  case "$cwd" in /*) ;; *) exit 1 ;; esac
  [ -d "$cwd" ] || exit 1
  command -v git >/dev/null 2>&1 || exit 1
  _mk_wt_parse "$cwd" || exit 1
  refs="$(_mk_wt_git -C "$cwd" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)" || exit 1
  case "$bnl$refs$bnl" in *"${bnl}refs/heads/$b$bnl"*) ;; *) exit 1 ;; esac
  _mk_wt_refs "$cwd" main || exit 1
  case "$dref" in
    refs/remotes/origin/?*) dloc="refs/heads/${dref#refs/remotes/origin/}" ;;
    *) dloc="$dref" ;;
  esac
  shopt -s nocasematch
  for r in refs/heads/main refs/heads/master "$dloc" "${wl_br[0]}"; do
    if [ -n "$r" ] && [[ "refs/heads/$b" == "$r" ]]; then exit 1; fi
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    if [[ "${wl_br[i]}" == "refs/heads/$b" ]]; then
      [ "${wl_br[i]}" = "refs/heads/$b" ] || exit 1
      gone=0
      if [ "$i" -ge 1 ]; then
        for x in "$@"; do
          if [ -n "$x" ] && [ "${wl_path[i]}" -ef "$x" ]; then gone=1; break; fi
        done
      fi
      [ "$gone" -eq 1 ] || exit 1
    fi
    i=$((i + 1))
  done
  shopt -u nocasematch
  tip="$(_mk_wt_commit "$cwd" "refs/heads/$b")" || exit 1
  _mk_wt_merged "$cwd" "$tip" "$hc" "$dc" >/dev/null
) 2>/dev/null

mk_wt_list() { _mk_wt_run list "${1:-}" "${2:-}" "${@:3}"; }
mk_wt_count() { _mk_wt_run count "${1:-}" "${2:-}" "${@:3}"; }
