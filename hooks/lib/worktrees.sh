#!/usr/bin/env bash
# memokit leftover-worktree library. Sourced after common.sh, never executed.
# bash 3.2-safe; BSD (macOS) and GNU (Linux) du/sleep; git >= 2.7 (2.36+ for
# NUL-separated `worktree list -z`, with a newline fallback below it).
# Consumers: session-start.sh (mk_wt_count, one report line) and the sweep CLI
# (skills/sweep/scripts/memokit-temp.sh worktrees, mk_wt_list).
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

# _mk_wt_git ARGS... -- git for reads only.
_mk_wt_git() { git --no-optional-locks "$@"; }

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
  c="$(_mk_wt_git -C "$1" rev-parse -q --verify "$2^{commit}" 2>/dev/null)" || return 1
  case "$c" in ''|*[!0-9a-f]*) return 1 ;; esac
  printf '%s' "$c"
}

# _mk_wt_merged DIR TIP HEAD_SHA DEFAULT_SHA -- prints "head" or "default" and
# returns 0 when every commit of TIP is reachable from one of the two (either
# may be empty); returns 1 otherwise, on any failure, or when both are empty.
_mk_wt_merged() {
  local dir="$1" tip="$2" h="$3" df="$4" c
  [ -n "$tip" ] || return 1
  if [ -n "$h" ]; then
    c="$(_mk_wt_git -C "$dir" rev-list --count "$tip" --not "$h" -- 2>/dev/null)" || c=""
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

  # Parse `git worktree list --porcelain` into parallel arrays (one entry per
  # worktree). -z keeps a path with a newline in one field; older git (no -z)
  # falls back to lines.
  wl_path=(); wl_head=(); wl_br=(); wl_det=(); wl_lock=(); wl_prune=(); wl_bare=()
  n=0; cur=-1
  _wt_field() {
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
  while IFS= read -r -d '' f; do _wt_field "$f"; done \
    < <(_mk_wt_git -C "$dir" worktree list --porcelain -z 2>/dev/null)
  if [ "$n" -eq 0 ]; then
    wl="$(_mk_wt_git -C "$dir" worktree list --porcelain 2>/dev/null)" || exit 0
    while IFS= read -r f; do _wt_field "$f"; done <<EOF
$wl
EOF
  fi
  [ "$n" -gt 0 ] || exit 0

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

  # Active runs: the ledgers of every listed worktree.
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
  # _wt_run_of PATH BRANCH -- 0 and wr=<run> when the lane (worktree basename
  # mk-<run>-*, or branch refs/heads/mk/<run>/*) belongs to an active run.
  # No subshell: it runs per row.
  _wt_run_of() {
    local a b="${1##*/}"
    wr=""
    for a in ${act[@]+"${act[@]}"}; do
      case "$b" in "mk-$a-"?*) wr="$a"; return 0 ;; esac
      case "$2" in "refs/heads/mk/$a/"?*) wr="$a"; return 0 ;; esac
    done
    return 1
  }
  # Split the rows: live = leftover candidates, lorph = leftover orphans,
  # nact = active-run rows, aruns = their distinct run ids.
  live=(); lorph=(); nact=0; aruns=""
  _wt_note_run() { nact=$((nact + 1)); case ", $aruns, " in *", $wr, "*) ;; *) aruns="${aruns:+$aruns, }$wr" ;; esac; }
  for i in ${cand[@]+"${cand[@]}"}; do
    if _wt_run_of "${wl_path[i]}" "${wl_br[i]}"; then _wt_note_run; else live[${#live[@]}]=$i; fi
  done
  for r in ${orphans[@]+"${orphans[@]}"}; do
    if _wt_run_of "" "$r"; then _wt_note_run; else lorph[${#lorph[@]}]="$r"; fi
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

  # The merge references, resolved once.
  hc="$(_mk_wt_commit "$dir" HEAD)" || hc=""
  dc=""
  od="$(_mk_wt_git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" || od=""
  for c in "$od" refs/heads/main refs/heads/master; do
    [ -n "$c" ] || continue
    dc="$(_mk_wt_commit "$dir" "$c")" && break
    dc=""
  done

  # Classify the worktrees.
  k=0
  for i in ${cand[@]+"${cand[@]}"}; do
    p="${wl_path[i]}"; h="${wl_head[i]}"; br="${wl_br[i]#refs/heads/}"
    [ "${wl_det[i]}" -eq 1 ] && br="-"
    [ -n "$br" ] || br="-"
    mi="-"
    case "$h" in *[!0-9a-f]*) h="" ;; esac
    if _wt_run_of "$p" "${wl_br[i]}"; then
      st=active-run
    elif [ "${wl_prune[i]}" -eq 1 ] || [ ! -d "$p" ] || [ -L "$p" ] || [ ! -f "$p/.git" ]; then
      st=prunable
    else
      so="$(_mk_wt_git -C "$p" status --porcelain --untracked-files=normal --ignore-submodules=none 2>/dev/null)"
      sr=$?
      if [ "$sr" -ne 0 ] || [ -n "$so" ]; then st=dirty
      elif [ "${wl_lock[i]}" -eq 1 ]; then st=locked
      elif [ "${wl_det[i]}" -eq 1 ]; then st=detached
      elif mi="$(_mk_wt_merged "$dir" "$h" "$hc" "$dc")"; then st=merged-clean
      else st=unmerged; mi="-"
      fi
    fi
    if [ -n "$h" ]; then last="$(_mk_wt_date "$dir" "$h")"; else last="?"; fi
    printf 'worktree\t%s\t%s\t%s\t%s\t%s\t%s\n' "$st" "${kbs[k]:-?}" "$last" "$(_mk_wt_show "$p")" "$(_mk_wt_show "$br")" "$mi"
    k=$((k + 1))
  done

  # Classify the orphan branches.
  for r in ${orphans[@]+"${orphans[@]}"}; do
    b="${r#refs/heads/}"
    if _wt_run_of "" "$r"; then st=active-run; mi="-"
    elif mi="$(_mk_wt_merged "$dir" "$r" "$hc" "$dc")"; then st=merged-clean; else st=orphan-branch; mi="-"; fi
    printf 'branch\t%s\t0\t%s\t%s\t%s\t%s\n' "$st" "$(_mk_wt_date "$dir" "$r")" "$b" "$b" "$mi"
  done
  exit 0
) 2>/dev/null

mk_wt_list() { _mk_wt_run list "${1:-}" "${2:-}" "${@:3}"; }
mk_wt_count() { _mk_wt_run count "${1:-}" "${2:-}" "${@:3}"; }
