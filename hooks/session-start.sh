#!/usr/bin/env bash
# SessionStart hook: inject docs/STATE.md, a knowledge-health summary, the
# tracked-docs list, standing notes, missing-file/unknown-key warnings, an
# optional WORKING-MODEL.md overlay and an optional settings risk scan.
#
# This hook deviates from the canonical non-guard preamble (see
# hooks/lib/README.md): every other hook gates on `mk_active` and exits 0
# silently when the project has no .claude/memokit.json. session-start.sh
# instead prints a one-line, opt-out init hint in that case (see the
# "not active" branch below) -- the ONE exception to the activation gate --
# so a project that never ran /memokit:init still hears about it once per
# session, without memokit ever running its own setup unprompted.
#
# MUST NEVER BLOCK THE SESSION: every branch below ends in `exit 0`. A
# missing health script, an invalid config, a missing WORKING-MODEL.md or a
# jq failure all degrade to a smaller (or absent) additionalContext, never
# to a nonzero exit or a hung hook.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_debug_dump "session-start" "$PAYLOAD"

# emit_ctx: build the SessionStart JSON from a plain-text context string and
# print it, or fall back to a static, hand-escaped, ALREADY-valid JSON
# literal on any jq failure (missing binary, corrupt install, OOM, ...).
# STATE.md and a health script's output land in $1 VERBATIM (neither is
# written by this file), so they can contain absolutely anything --
# including raw control characters (ESC 0x1B, 0x01, ...). Hand-rolled
# escaping that only covers `\ " \n \r \t` is not enough: JSON requires
# EVERY byte in U+0000-U+001F to be escaped, and Claude Code silently
# discards unparseable hook output, so one unescaped control byte would
# lose the whole injection with nothing telling the operator it failed.
# jq's --arg does full RFC 8259 escaping of the whole control-character
# range, which is why this never hand-escapes $1 itself -- only the fixed,
# quote-free _STATIC fallback message below is ever hand-written.
emit_ctx() {
  CTX_JSON="$(jq -n --arg ctx "$1" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' 2>/dev/null)"
  # shellcheck disable=SC2181  # $? here is jq's, from the command
  # substitution just above -- see guard-edit.sh's deny() for the same
  # pattern and why `if jq ...; then` alone cannot also check `-n`.
  if [ $? -eq 0 ] && [ -n "$CTX_JSON" ]; then
    printf '%s\n' "$CTX_JSON"
  else
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": "%s"\n  }\n}\n' "$(mk_msg SS_FALLBACK_STATIC)"
  fi
  exit 0
}

# True when the project carries a legacy .claude/hooks setup, either at
# MK_ROOT or at the git top level. The second check matters for a launch from
# a repo subdirectory: with no memokit.json to climb to, mk_resolve_root leaves
# MK_ROOT at that subdirectory, where .claude/hooks never is. The top level is
# reached via --show-cdup (logical form, as in mk_resolve_root).
legacy_hooks_present() {
  local cdup top
  [ -d "$MK_ROOT/.claude/hooks" ] && return 0
  cdup="$(git -C "$MK_ROOT" rev-parse --show-cdup 2>/dev/null)" || return 1
  [ -n "$cdup" ] || return 1
  top="$(cd "$MK_ROOT" && cd "$cdup" && pwd)" || return 1
  [ -n "$top" ] && [ -d "$top/.claude/hooks" ]
}

if ! mk_active; then
  # Init hint: only in a project that (a) hasn't opted out, (b) has a
  # resolvable root, (c) is actually a git work tree, and (d) has no legacy
  # .claude/hooks (at the root or the git top level) -- a project already
  # carrying a legacy hook setup gets no unsolicited suggestion. This is the
  # sole codepath that runs without an active memokit.json; everything below
  # this block requires mk_active.
  if [ "${MEMOKIT_NO_INIT_HINT:-0}" != "1" ] && [ -n "$MK_ROOT" ] \
     && git -C "$MK_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && ! legacy_hooks_present; then
    lang="en"
    case "${LANG:-}" in tr*) lang="tr" ;; esac
    # mk_load_config (which normally loads messages) is never reached on
    # this branch, so messages are loaded explicitly here first -- calling
    # mk_msg before this would just render an empty string.
    mk_load_messages "$lang"
    jq -n --arg ctx "$(mk_msg SS_INIT_HINT)" \
      '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' 2>/dev/null
  fi
  exit 0
fi

mk_load_config
CONFIG_OK=$?

STATE="$(cat "$MK_ROOT/docs/STATE.md" 2>/dev/null || mk_msg SS_STATE_UNREADABLE)"
nl=$'\n'

# Settings risk scan (Task 8): optional and sourced only if present, so this
# file works standalone before hooks/lib/risk-scan.sh ships and afterwards
# without any further change here. Computed before the invalid-config branch
# below and used by BOTH paths: a project's settings.json/settings.local.json
# can carry a leaked secret or an over-broad permission rule regardless of
# whether .claude/memokit.json itself happens to be valid right now, so this
# warning must never be gated on config validity.
RISK=""
if [ -f "$MK_LIB_DIR/risk-scan.sh" ]; then
  # shellcheck source-path=SCRIPTDIR source=lib/risk-scan.sh
  . "$MK_LIB_DIR/risk-scan.sh"
  RISK="$(risk_scan "$MK_ROOT")"
fi

if [ "$CONFIG_OK" -ne 0 ]; then
  # Invalid config: still inject STATE so the session stays usable (the
  # alternative -- exiting with nothing -- would hide docs/STATE.md behind a
  # config typo), plus the risk scan (computed above, config-independent) and
  # the always-on resume note. Health/docs/missing/unknown-key reporting all
  # read config-derived values (MK_HEALTH_SCRIPT, MK_SESSION_DOCS, ...), which
  # mk_load_config already reset to empty defaults before it started parsing,
  # so skipping those here loses nothing they would have shown anyway -- only
  # RISK and SS_RESUME_NOTE are config-independent enough to still run.
  emit_ctx "$(mk_msg SS_CONFIG_INVALID "$MK_CONFIG_ERR")${nl}${nl}${STATE}${RISK:+${nl}${nl}${RISK}}${nl}${nl}$(mk_msg SS_RESUME_NOTE)"
fi

# Health: MK_HEALTH_SCRIPT is a project-relative path from memokit.json
# (sessionStart.healthScript). Tolerant of the script being absent or not
# executable -- ported forward-compatible from a legacy project that had no
# scripts/ directory of its own yet: a missing script degrades to a plain
# note (and is recorded as a missing file, see MISSING_LIST below) instead
# of a raw "No such file or directory" stderr line masquerading as a health
# result.
HEALTH=""
MISSING_LIST=""
if [ -n "$MK_HEALTH_SCRIPT" ]; then
  if [ -x "$MK_ROOT/$MK_HEALTH_SCRIPT" ]; then
    HEALTH="$(if cd "$MK_ROOT"; then MEMOKIT_KH_SMOKE=0 bash "$MK_HEALTH_SCRIPT" --fast 2>&1 || true; fi)"
  else
    HEALTH="$(mk_msg SS_HEALTH_SKIPPED)"
    MISSING_LIST="$MK_HEALTH_SCRIPT"
  fi
else
  HEALTH="$(mk_msg SS_HEALTH_SKIPPED)"
fi

# Docs: MK_SESSION_DOCS is memokit.json's sessionStart.docs, one entry per
# line (see config.jq). Each entry is either a bare path or "path — note"
# (an em dash, spaced); only the path half is checked for existence. Overlay
# files (rules/coder/reviewer/handoff/resume) are never required and never
# reported missing here -- only files actually referenced by config
# (healthScript, sessionStart.docs) are.
DOCS=""
if [ -n "$MK_SESSION_DOCS" ]; then
  DOCS="$(mk_msg SS_DOCS_HEADER)"
  while IFS= read -r docline; do
    [ -z "$docline" ] && continue
    docpath="${docline%% — *}"
    if [ ! -f "$MK_ROOT/$docpath" ]; then
      MISSING_LIST="${MISSING_LIST}${MISSING_LIST:+$nl}${docpath}"
    fi
    DOCS="${DOCS}${nl}· ${docline}"
  done <<EOF
$MK_SESSION_DOCS
EOF
fi

MISSING_TXT=""
if [ -n "$MISSING_LIST" ]; then
  missing_joined="$(printf '%s' "$MISSING_LIST" | paste -sd, - | sed 's/,/, /g')"
  MISSING_TXT="${nl}${nl}$(mk_msg SS_MISSING "$missing_joined")"
fi

WARN_TXT=""
if [ -n "$MK_CONFIG_WARN" ]; then
  WARN_TXT="${nl}${nl}$(mk_msg SS_UNKNOWN_KEYS "$MK_CONFIG_WARN")"
fi
# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$MK_LIB_DIR/careful.sh"
BAD_CF="$(mk_careful_bad_patterns | paste -sd, - | sed 's/,/, /g')"
if [ -n "$BAD_CF" ]; then
  WARN_TXT="${WARN_TXT}${nl}${nl}$(mk_msg SS_CAREFUL_BAD_REGEX "$BAD_CF")"
fi

NOTES=""
if [ -f "$MK_ROOT/docs/HISTORY.md" ]; then
  NOTES="${nl}${nl}$(mk_msg SS_HISTORY_NOTE)"
fi
NOTES="${NOTES}${nl}${nl}$(mk_msg SS_RESUME_NOTE)"

# Auto-clean (0.6.1, user decision): stale temp entries of earlier sessions
# and merged, clean leftover worktrees are removed here, in one detached
# background job so a multi-GB removal cannot outlast the hook timeout.
# MEMOKIT_AUTOCLEAN_OFF=1 restores report-only; MEMOKIT_AUTOCLEAN_SYNC=1 (test
# seam) runs the removals before the hook returns.
AUTOCLEAN=1
[ "${MEMOKIT_AUTOCLEAN_OFF:-0}" = "1" ] && AUTOCLEAN=0
# _ss_bg FN ARGS... -- FN in the background, every fd detached from the hook.
_ss_bg() {
  if [ "${MEMOKIT_AUTOCLEAN_SYNC:-0}" = "1" ]; then "$@" >/dev/null 2>&1; return 0; fi
  ( trap '' HUP; "$@" ) </dev/null >/dev/null 2>&1 &
  return 0
}
# _ss_h KB -- KB human readable (mk_human_kb prints "0 MB" below 1 MB).
_ss_h() { if [ "$1" -lt 1024 ]; then printf '%s KB' "$1"; else mk_human_kb "$1"; fi; }
# _ss_rm_all PATH... -- one literal rm per entry (each checked by mk_temp_rm_safe).
# shellcheck disable=SC2317,SC2329  # invoked through _ss_bg
_ss_rm_all() { local p; for p in "$@"; do rm -rf -- "$p"; done; }

# Leftover temp entries of earlier sessions and the low-disk floor. Both are
# best effort and silent on any failure; the leftover total is cached for
# check-disk.sh's Stop message (same sanitised session id, same state-file
# safety rules: no symlink, owned by us, umask-077 temp file + mv). An entry
# is auto-removed only when mk_temp_rm_safe passes it as a whole stale
# sibling and nothing under it holds .memokit-keep; the rest is reported.
LEFT_TXT=""
TEMP_LIB=0
# shellcheck source-path=SCRIPTDIR source=lib/temp.sh
. "$MK_LIB_DIR/temp.sh" 2>/dev/null && TEMP_LIB=1
if [ "${MEMOKIT_SCRATCH_OFF:-0}" != "1" ] && [ "$TEMP_LIB" -eq 1 ] \
   && mk_temp_init "$PAYLOAD" >/dev/null 2>&1; then
  ss_list="$(mk_temp_stale_list 3 2>/dev/null)" && {
    ss_n=0; ss_kb=0; ss_trunc=""; ss_rm=(); ss_rm_kb=0
    while IFS= read -r ss_line; do
      case "$ss_line" in
        TRUNCATED) ss_trunc="≥ " ;;
        [0-9]*)
          ss_e_kb="${ss_line%%"$(printf '\t')"*}"; ss_e="${ss_line#*"$(printf '\t')"}"
          if [ "$AUTOCLEAN" -eq 1 ] && mk_temp_rm_safe "$ss_e" \
             && [ -z "$(find "$ss_e" -name .memokit-keep -print -quit 2>/dev/null)" ]; then
            ss_rm[${#ss_rm[@]}]="$ss_e"; ss_rm_kb=$((ss_rm_kb + ss_e_kb))
          else
            ss_n=$((ss_n + 1)); ss_kb=$((ss_kb + ss_e_kb))
          fi ;;
      esac
    done <<EOF2
$ss_list
EOF2
    if [ "${#ss_rm[@]}" -gt 0 ]; then
      _ss_bg _ss_rm_all "${ss_rm[@]}"
      LEFT_TXT="${nl}${nl}$(mk_msg SS_TEMP_AUTOCLEAN "${#ss_rm[@]}" "$(_ss_h "$ss_rm_kb")")"
    fi
    ss_sid="$(printf '%s' "$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null)" | tr -c 'A-Za-z0-9_-' _)"
    [ -n "$ss_sid" ] || ss_sid="unknown"
    ss_f="$(mk_tmp "temp-leftover-${ss_sid}")"
    if [ ! -L "$ss_f" ] && { [ ! -e "$ss_f" ] || { [ -f "$ss_f" ] && [ -O "$ss_f" ]; }; }; then
      ss_t="$(umask 077; mktemp "$ss_f.XXXXXX" 2>/dev/null)" && {
        if printf '%s' "$ss_kb" > "$ss_t" 2>/dev/null; then mv -f "$ss_t" "$ss_f" 2>/dev/null || rm -f "$ss_t"; else rm -f "$ss_t"; fi
      }
    fi
    if [ "$ss_n" -gt 0 ] && [ "$ss_kb" -ge $(( MK_SCRATCH_REPORT_MIN_MB * 1024 )) ]; then
      LEFT_TXT="${LEFT_TXT}${nl}${nl}$(mk_msg SS_TEMP_LEFTOVER "$ss_n" "${ss_trunc}$(mk_human_kb "$ss_kb")")"
    fi
  }
fi
if [ "${MEMOKIT_DISK_OFF:-0}" != "1" ] && [ "$MK_DISK_MIN_FREE_GB" -gt 0 ] \
   && [ "$TEMP_LIB" -eq 1 ]; then
  ss_free="$(mk_disk_free_kb 2>/dev/null)" || ss_free=""
  case "$ss_free" in
    ''|*[!0-9]*) ;;
    *) if [ "$ss_free" -lt $(( MK_DISK_MIN_FREE_GB * 1048576 )) ]; then
         LEFT_TXT="${LEFT_TXT}${nl}${nl}$(mk_msg SS_DISK_LOW "$(mk_human_kb "$ss_free")" "$MK_DISK_MIN_FREE_GB")"
       fi ;;
  esac
fi

# Leftover worktrees under .claude/worktrees/ and mk/* branches without one
# (parallel lanes, Claude Code agent worktrees). Unrelated to the temp
# leftovers above (Claude Code scratch dirs under /tmp). mk_wt_count is
# read-only and silent outside git; with nothing to report it costs two git
# calls, otherwise it adds only a du bounded to about 2 s (no status, so a
# huge worktree cannot stall the hook). The payload cwd's own worktree is
# not counted. Some size not measured -> the total is a lower bound. Lanes of
# an active parallel run (ledger `status: active`) are not leftovers: they
# get their own line naming the run, which /memokit:resume continues.
WT_TXT=""
# Auto-clean of leftover worktrees (0.6.1). Classifying needs a status per
# worktree (and an ignored-file scan), which the hook itself must not wait
# for, so a detached job does it: it takes the sweep CLI's `worktrees` rows
# (the classification /memokit:sweep offers) and removes only `merged-clean`
# ones:
# - a worktree that looks unused: its index is older than
#   scratch.staleAfterHours (a fresh one may be a live agent's that has not
#   changed anything yet), no Claude Code transcript for its path was written
#   within that time, and no process has its cwd in it (lsof, when present).
#   Right before the removal its status (ignored files included) must still be
#   empty, since `git worktree remove` deletes ignored files without asking.
#   Then `git worktree remove` (never --force) and `git branch -d` for an mk/*
#   branch;
# - an mk/* branch without a worktree, merged into HEAD: `git branch -d`.
# git's own refusal stays final. Needs git >= 2.31 (rev-parse --path-format);
# older git removes nothing. The job writes "<removed> <left>" to a
# per-project result file. When the leftover count equals the last result's
# <left>, the session start prints the usual report line (they need the user)
# and restarts the job only when that result is over an hour old; otherwise it
# starts the job (one at a time: a lock dir) and says so instead.
# _ss_wt_job ROOT FROM RESULT LOCK
# shellcheck disable=SC2317,SC2329  # invoked through _ss_bg
_ss_wt_job() {
  local root="$1" from="$2" res="$3" lock="$4" tab rows kind st kb name br mi idx t now old rmd=0 left=0 tmp cwds="" tdir
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
  tab="$(printf '\t')"; now="$(date +%s)"; old=$((MK_SCRATCH_STALE_HOURS * 3600))
  # Every process's cwd, once (lsof -Fn prints "n<path>" lines).
  if command -v lsof >/dev/null 2>&1; then cwds="$(lsof -nP -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"; fi
  rows="$(cd "$from" 2>/dev/null && "$BASH" "$MK_HOOKS_DIR/../skills/sweep/scripts/memokit-temp.sh" worktrees 2>/dev/null)" || rows=""
  while IFS="$tab" read -r st kind kb _ _ name br mi _; do
    [ -n "$kind" ] || continue
    [ "$st" = active-run ] && continue
    if [ "$st" = merged-clean ] && [ "$kind" = worktree ]; then
      idx="$(git -C "$name" rev-parse --path-format=absolute --git-path index 2>/dev/null)" || idx=""
      t=""; [ -n "$idx" ] && t="$(mk_temp_mtime "$idx")"
      case "$t" in
        ''|*[!0-9]*) ;;
        *) tdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$name" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
           if [ $((now - t)) -gt "$old" ] \
              && [ -z "$(find "$tdir" -name '*.jsonl' -mmin -$((MK_SCRATCH_STALE_HOURS * 60)) -print -quit 2>/dev/null)" ] \
              && ! printf '%s\n' "$cwds" | MK_P="$name" awk 'BEGIN { p = ENVIRON["MK_P"] } $0 == p || index($0, p "/") == 1 { f = 1 } END { exit !f }' \
              && [ -z "$(git -C "$name" --no-optional-locks status --porcelain --ignored --untracked-files=normal 2>&1)" ] \
              && git -C "$root" worktree remove "$name"; then
             case "$br" in mk/?*) git -C "$root" branch -d "$br" ;; esac
             rmd=$((rmd + 1)); continue
           fi ;;
      esac
    elif [ "$st" = merged-clean ] && [ "$kind" = branch ] && [ "$mi" = head ]; then
      case "$br" in mk/?*) if git -C "$root" branch -d "$br"; then rmd=$((rmd + 1)); continue; fi ;; esac
    fi
    left=$((left + 1))
  done <<EOF4
$rows
EOF4
  if [ ! -L "$res" ] && { [ ! -e "$res" ] || { [ -f "$res" ] && [ -O "$res" ]; }; }; then
    tmp="$(umask 077; mktemp "$res.XXXXXX" 2>/dev/null)" && {
      if printf '%s %s\n' "$rmd" "$left" > "$tmp"; then mv -f "$tmp" "$res" || rm -f "$tmp"; else rm -f "$tmp"; fi
    }
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}
# _ss_wt_autoclean -- sets WT_AUTO_TXT, and WT_REPORT=0 when the job runs.
_ss_wt_autoclean() {
  local res lock r_left="" t from known=0
  res="$(mk_tmp wt-autoclean)"; lock="$res.lock"
  if [ -f "$res" ] && [ ! -L "$res" ] && [ -O "$res" ]; then
    read -r _ r_left < "$res" 2>/dev/null || true
    case "$r_left" in
      ''|*[!0-9]*) ;;
      *) if [ "$r_left" -eq "$wt_n" ]; then
           # The last check left exactly these: report them as before.
           known=1
           t="$(mk_temp_mtime "$res")" || t=0
           [ $(( $(date +%s) - t )) -lt 3600 ] && return 0
         fi ;;
    esac
  fi
  # A lock older than an hour is from a job that died.
  if [ -d "$lock" ] && [ ! -L "$lock" ]; then
    t="$(mk_temp_mtime "$lock")" || t=0
    [ $(( $(date +%s) - t )) -ge 3600 ] && rmdir "$lock" 2>/dev/null
  fi
  mkdir "$lock" 2>/dev/null || return 0
  from="$MK_ROOT"; [ -n "$wt_cwd" ] && [ -d "$wt_cwd" ] && from="$wt_cwd"
  _ss_bg _ss_wt_job "$MK_ROOT" "$from" "$res" "$lock"
  [ "$known" -eq 1 ] && return 0
  WT_AUTO_TXT="${nl}${nl}$(mk_msg SS_WT_AUTOCLEAN "$wt_n" "$MK_SCRATCH_STALE_HOURS")"
  WT_REPORT=0
}
WT_AUTO_TXT=""; WT_REPORT=1
# shellcheck source-path=SCRIPTDIR source=lib/worktrees.sh
if . "$MK_LIB_DIR/worktrees.sh" 2>/dev/null; then
  wt_cwd="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)" || wt_cwd=""
  wt_c="$(mk_wt_count "$MK_ROOT" "" "$wt_cwd" 2>/dev/null)"
  wt_n=""; wt_kb=""; wt_un=""; wt_an=""; wt_runs=""
  [ -n "$wt_c" ] && IFS="$(printf '\t')" read -r wt_n wt_kb wt_un wt_an wt_runs <<EOF3
$wt_c
EOF3
  case "$wt_n$wt_kb$wt_un$wt_an" in
    ''|*[!0-9]*) ;;
    *) if [ "$wt_n" -gt 0 ] && [ "$AUTOCLEAN" -eq 1 ] && [ "$TEMP_LIB" -eq 1 ]; then
         _ss_wt_autoclean
       fi
       if [ "$wt_n" -gt 0 ] && [ "$WT_REPORT" -eq 1 ]; then
         wt_ge=""; [ "$wt_un" -gt 0 ] && wt_ge="≥ "
         if [ "$wt_kb" -lt 1024 ]; then wt_h="$wt_kb KB"
         else wt_h=""; [ "$TEMP_LIB" -eq 1 ] && wt_h="$(mk_human_kb "$wt_kb")"; fi
         [ -n "$wt_h" ] || wt_h="$wt_kb KB"
         WT_TXT="${nl}${nl}$(mk_msg SS_WT_LEFTOVER "$wt_n" "${wt_ge}${wt_h}")"
       fi
       case "$wt_runs" in
         ''|*[!A-Za-z0-9._,\ -]*) ;;
         *) [ "$wt_an" -gt 0 ] && WT_TXT="${WT_TXT}${nl}${nl}$(mk_msg SS_WT_ACTIVE_RUN "$wt_an" "$wt_runs")" ;;
       esac ;;
  esac
fi

# WORKING-MODEL.md is a plugin-shipped doc (sibling of hooks/, i.e.
# $MK_HOOKS_DIR/..), not a project file -- it does not exist yet (see Task
# 14), so this must tolerate its absence forever, not just until it ships.
WM=""
if [ -f "$MK_HOOKS_DIR/../WORKING-MODEL.md" ]; then
  WM="[memokit WORKING-MODEL]${nl}${nl}$(cat "$MK_HOOKS_DIR/../WORKING-MODEL.md")"
fi

# RISK was already computed above (before the invalid-config branch), since
# it does not depend on config validity.
ctx="$(mk_msg SS_HEADER "$MK_NAME")${nl}${nl}${STATE}${nl}${nl}[knowledge-health] ${HEALTH}${nl}${nl}${DOCS}${NOTES}${MISSING_TXT}${WARN_TXT}${LEFT_TXT}${WT_AUTO_TXT}${WT_TXT}${RISK:+${nl}${RISK}}${WM:+${nl}${nl}${WM}}"
emit_ctx "$ctx"
