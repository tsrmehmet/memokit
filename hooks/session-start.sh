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

NOTES=""
if [ -f "$MK_ROOT/docs/HISTORY.md" ]; then
  NOTES="${nl}${nl}$(mk_msg SS_HISTORY_NOTE)"
fi
NOTES="${NOTES}${nl}${nl}$(mk_msg SS_RESUME_NOTE)"

# WORKING-MODEL.md is a plugin-shipped doc (sibling of hooks/, i.e.
# $MK_HOOKS_DIR/..), not a project file -- it does not exist yet (see Task
# 14), so this must tolerate its absence forever, not just until it ships.
WM=""
if [ -f "$MK_HOOKS_DIR/../WORKING-MODEL.md" ]; then
  WM="[memokit WORKING-MODEL]${nl}${nl}$(cat "$MK_HOOKS_DIR/../WORKING-MODEL.md")"
fi

# RISK was already computed above (before the invalid-config branch), since
# it does not depend on config validity.
ctx="$(mk_msg SS_HEADER "$MK_NAME")${nl}${nl}${STATE}${nl}${nl}[knowledge-health] ${HEALTH}${nl}${nl}${DOCS}${NOTES}${MISSING_TXT}${WARN_TXT}${RISK:+${nl}${RISK}}${WM:+${nl}${nl}${WM}}"
emit_ctx "$ctx"
