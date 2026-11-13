#!/usr/bin/env bash
# PreToolUse hook: block subagents from exceeding their authority.
#
# Subagents may NOT commit, merge, delete branches, rewrite history, touch the
# remote, or delegate work to another agent (WORKING-MODEL.md §1,
# agents/coder.md rule 0 (memokit:coder)). Those rules were written as TEXT
# first and violated 7 times anyway -- twice AFTER the rules were in place
# (a real incident in a production repo: one agent committed + merged to
# master + deleted its branch without permission, another delegated and
# returned early). Text did not hold; this is the mechanism. Sibling of
# guard-edit.sh, which enforces the inverse rule (main session may not write
# src/ or tests/).
#
# The orchestrator (main session) is unaffected -- it is the one that IS
# supposed to commit and to spawn agents.
set -u
# No pathname expansion anywhere (final review): the command is split into
# words unquoted (set -- $SEG, the cd and config loops), and each * in it
# was globbed against the hook's cwd (20 000 directories: ls */* took 1 s,
# 40 segments of it 3.5 s and a budget deny). The libraries that glob on
# purpose turn it on locally (careful.sh runs mk_temp_rm_safe under set +f).
set -f
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/budget.sh
. "$(dirname "$0")/lib/budget.sh"
PAYLOAD="$(cat)"
# Hard kill-switch for emergencies, same lever as guard-edit.sh. Hooks run as
# a process separate from the Claude Code session, so this variable must be
# in the environment Claude Code itself passes to hooks -- e.g. "env":
# {"MEMOKIT_GUARD_OFF": "1"} in .claude/settings.local.json, or exported
# before launching `claude`; exporting it inside a Bash tool call does not
# reach hooks. Checked before anything else, including the empty-payload
# branch right below, so the kill switch is a true unconditional override.
mk_guard_off && exit 0

# Hard budget (0.8.0 final wave; lib/budget.sh, as guard-destructive.sh),
# armed before the first jq call (re-review N1: a jq that stalled in
# mk_load_config kept this hook past the 5 s timeout): a command or a tool
# that keeps the checks below busy past MK_GS_BUDGET_WALL s (or
# MK_GS_BUDGET_CPU s of CPU) is denied with GS_BUDGET_STATIC before Claude
# Code's 5 s hook timeout would let it run unchecked. Mode "zero": an
# "exit 0" with no output still lets a command through; a crash (a non-zero
# exit before a decision) denies with GS_CRASH_STATIC. Every deny below is
# printed through the helper (once).
MK_GS_BUDGET_WALL=3.3
MK_GS_BUDGET_CPU=4
mk_budget_arm "$MK_GS_BUDGET_WALL" "$MK_GS_BUDGET_CPU" GS_BUDGET_STATIC GS_CRASH_STATIC zero
# _gs_jq_deny REASON -- the deny JSON for REASON, printed once; a jq that
# fails gives the static jq-failure deny.
_gs_jq_deny() {
  local out
  if out="$(jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)" && [ -n "$out" ]; then
    mk_budget_deny_json "$out"
  else
    mk_budget_static_deny GS_JQ_FAILED_STATIC
  fi
  exit 0
}

mk_resolve_root "$PAYLOAD"
if ! mk_active; then
  # A config that vanished mid-session (marker from session-start.sh) denies
  # a subagent; any other inactive project stays silent.
  mk_config_vanished "$PAYLOAD" || exit 0
  mk_load_messages "$(mk_lang_guess)"
  _gs_jq_deny "$(mk_msg GS_CONFIG_MISSING)"
fi
mk_debug_dump "guard-subagent" "$PAYLOAD"
if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then
    mk_budget_static_deny CONFIG_NO_JQ_STATIC
    exit 0
  fi
  _gs_jq_deny "$(mk_config_invalid_msg)"
fi

# Empty stdin used to be treated as "the knowledge-health smoke test, nothing
# to classify". That premise was checked and is false: knowledge-health-style
# fallback fixtures for hooks without a dedicated case send `{}`, not empty
# stdin, and this hook has no dedicated case of its own either way. So this
# branch protected nothing and only ever fired when stdin genuinely could not
# be read (a broken pipe, `cat` missing from PATH, ...) -- the same failure
# mode guard-edit.sh had, confirmed live there. Empty stdin now denies. The
# only sanctioned way to get the old "stay silent" behaviour is the explicit
# MEMOKIT_KH_SMOKE=1 escape hatch, kept as a documented, explicit-opt-in
# escape rather than an implicit one.
# This message is fixed text with nothing interpolated, so a hand-escaped
# static JSON literal is safe here -- deny() is not defined yet at this point
# and itself depends on jq, which is exactly the kind of dependency an
# "stdin could not be read" path should not add.
if [ -z "$PAYLOAD" ]; then
  if [ "${MEMOKIT_KH_SMOKE:-0}" = "1" ]; then
    exit 0
  fi
  mk_budget_static_deny GS_EMPTY_STDIN_STATIC
  exit 0
fi

deny() {
  # $1: localized (mk_msg-rendered) reason shown to the operator. May embed
  # the offending command, which is model-controlled text, so it MUST be
  # JSON-escaped by jq rather than interpolated with printf %s -- an embedded
  # double quote would produce unparseable JSON, and Claude Code silently
  # ignores unparseable hook output, which would lose the deny and let the
  # action through. Same reasoning and same fallback as guard-edit.sh's
  # deny().
  DENY_JSON="$(jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null)"
  # shellcheck disable=SC2181  # $? here is jq's, from the command
  # substitution just above -- checking it directly would require
  # restructuring this into `if DENY_JSON=$(jq ...); then`, losing the
  # ability to also check `[ -n "$DENY_JSON" ]` in the same condition.
  # Printed once through lib/budget.sh (decided, then printed), so the
  # budget trap never adds a second deny.
  if [ $? -eq 0 ] && [ -n "$DENY_JSON" ]; then
    mk_budget_deny_json "$DENY_JSON"
  else
    mk_budget_static_deny GS_JQ_FAILED_STATIC
  fi
  exit 0
}

# Fail-closed: non-empty stdin that is not valid JSON -- cannot classify, so
# cannot allow. (Inside $(...): see lib/budget.sh on foreground children.)
# shellcheck disable=SC2034  # only the exit status counts
if ! _mk_gs_v="$(printf '%s' "$PAYLOAD" | jq -e 'if . then 1 else null end' 2>/dev/null)"; then
  deny "$(mk_msg GS_INVALID_JSON)"
fi

# Subagent detection. Identical discriminator to guard-edit.sh: the main-thread
# payload carries no agent_id, a subagent payload carries the id the Agent tool
# returned. agent_type is deliberately NOT used -- a subagent could name itself
# anything, while agent_id is assigned by the harness.
IS_SUB="$(printf '%s' "$PAYLOAD" | jq -r 'if (.agent_id // "") != "" then "sub" else "main" end' 2>/dev/null)" || \
  deny "$(mk_msg GS_SUBAGENT_CHECK_FAILED)"

# The orchestrator is allowed to do all of this -- that is its job.
[ "$IS_SUB" = "main" ] && exit 0

# Test-only (MEMOKIT_TEST_BURN, lib/budget.sh; the budget is armed above).
mk_budget_test_burn

TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null)" || \
  deny "$(mk_msg GS_TOOL_NAME_EXTRACT_FAILED)"

# --- Rule 1: no delegation. A subagent must do its own work. -----------------
# Observed failure: agent spawns a child, reports "started in the background",
# returns with an empty working tree. Worse, the parent then re-does the work
# -- a real incident: two writers raced on the same files.
# SendMessage is included alongside Agent/Task: it resumes an EXISTING agent
# with its full context intact, which is the same "hand my work to another
# agent" action this rule blocks -- only the entry point differs (spawning a
# new one vs. continuing one that already exists).
case "$TOOL" in
  Agent|Task|SendMessage)
    deny "$(mk_msg GS_NO_DELEGATION)"
    ;;
esac

# The payload cwd anchors relative paths (Rule 2a and the Bash config gate).
_MK_GS_CWD="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null)"
case "$_MK_GS_CWD" in /*) ;; *) _MK_GS_CWD="$MK_ROOT" ;; esac
# Lexical normalisation, as the file tools resolve a path: relative paths join
# the payload cwd, empty and . components drop, .. folds its parent.
_mk_gs_abs() {
  local p="$1" out="" c
  case "$p" in /*) ;; *) p="$_MK_GS_CWD/$p" ;; esac
  p="$p/"
  while [ -n "$p" ]; do
    c="${p%%/*}"; p="${p#*/}"
    case "$c" in ''|.) ;; ..) out="${out%/*}" ;; *) out="$out/$c" ;; esac
  done
  printf '%s' "${out:-/}"
}
# ASCII only (LC_ALL=C, p18): no locale may map I to a dotless i.
_mk_gs_lc() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
_MK_GS_NL='
'
# Claude Code's settings files (0.8.1): settings.json and settings.local.json
# of the project, of the user, and of $CLAUDE_CONFIG_DIR when it is set, by
# EXACT path. No basename rule (any other settings.json, a lane's
# .claude/settings.json among them, is ordinary) and the directories
# themselves are not protected. _mk_gs_set_init (once, only on the Edit/Write
# and Bash paths) sets _MK_GS_SET_FILES: the paths, one per line, and
# _MK_GS_SET_LC: every lower-cased spelling of them (each directory as named,
# physically resolved, and below its physical parent).
_MK_GS_SET_DONE=0; _MK_GS_SET_FILES=""; _MK_GS_SET_LC=""; _MK_GS_CCD_LC=""
# _MK_GS_SDIR_P / _MK_GS_SDIR_U: lower-cased spellings of the directories
# that hold them, <root>/.claude and ~/.claude plus $CLAUDE_CONFIG_DIR;
# _MK_GS_SDIR_PD / _MK_GS_SDIR_UA: the same directories as named (absolute),
# for the device:inode test of _mk_gs_dir_phys.
_MK_GS_SDIR_P=""; _MK_GS_SDIR_U=""; _MK_GS_SDIR_PD=""; _MK_GS_SDIR_UA=()
_mk_gs_set_init() {
  local d s e first=1
  [ "$_MK_GS_SET_DONE" = 1 ] && return 0
  _MK_GS_SET_DONE=1
  while IFS= read -r d; do
    [ -n "$d" ] || { first=0; continue; }
    d="$(_mk_gs_abs "$d")"
    s="$d"
    e="$(cd -P "$d" 2>/dev/null && pwd -P)" && s="$s$_MK_GS_NL$e"
    e="$(cd -P "$(dirname "$d")" 2>/dev/null && pwd -P)" && s="$s$_MK_GS_NL${e%/}/$(basename "$d")"
    _MK_GS_SET_FILES="$_MK_GS_SET_FILES$d/settings.json$_MK_GS_NL$d/settings.local.json$_MK_GS_NL"
    # $CLAUDE_CONFIG_DIR's own spellings (it is the last line read):
    # naming one of them enables the expansion/glob trigger of _mk_gs_set_hit.
    [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$d" = "$(_mk_gs_abs "$CLAUDE_CONFIG_DIR")" ] && _MK_GS_CCD_LC="$(_mk_gs_lc "$s")"
    if [ "$first" = 1 ]; then _MK_GS_SDIR_P="$(_mk_gs_lc "$s")"; _MK_GS_SDIR_PD="$d"
    else _MK_GS_SDIR_U="$_MK_GS_SDIR_U$(_mk_gs_lc "$s")$_MK_GS_NL"; _MK_GS_SDIR_UA+=("$d"); fi
    first=0
    while IFS= read -r e; do
      _MK_GS_SET_LC="$_MK_GS_SET_LC$e/settings.json$_MK_GS_NL$e/settings.local.json$_MK_GS_NL"
    done <<EOF
$s
EOF
  done <<EOF
$MK_ROOT/.claude
${HOME:+$HOME/.claude}
${CLAUDE_CONFIG_DIR:-}
EOF
  _MK_GS_SET_LC="$(printf '%s' "$_MK_GS_SET_LC" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u)"
}
# _mk_gs_set_deny PATH -- denies (GS_SETTINGS_EDIT, naming FPATH) when PATH
# spells a settings file or is one by device:inode (a hard link, or a
# symlink: test -ef follows it).
_mk_gs_set_deny() {
  local l f
  l="$(_mk_gs_lc "$1")"
  while IFS= read -r f; do
    [ -n "$f" ] && [ "$l" = "$f" ] && deny "$(mk_msg GS_SETTINGS_EDIT "$FPATH")"
  done <<EOF
$_MK_GS_SET_LC
EOF
  while IFS= read -r f; do
    [ -n "$f" ] && [ -e "$f" ] && [ "$1" -ef "$f" ] && deny "$(mk_msg GS_SETTINGS_EDIT "$FPATH")"
  done <<EOF
$_MK_GS_SET_FILES
EOF
  return 0
}

# _mk_gs_snap_deny PATH -- denies (GS_SNAPSHOT_EDIT) when PATH's last
# component names careful-config (any case: every session's config snapshot,
# existing or not, lib/common.sh) or PATH is this session's snapshot by
# device:inode (a hard link, or a symlink: test -ef follows it).
# Accepted trade-off: a project file whose name holds careful-config is denied too.
# Task 23: any other memokit state file too (GS_STATE_EDIT): a last
# component (any case) memokit-<digits>-careful-..., the whole careful-
# family under the temp dir (integrity records, armed stamps, permission
# records, markers, active stamps, windows). One anchored regex on the
# basename; Bash writes to them are careful-state already (lib/careful.sh).
# Release fix d: also anything below a directory of that family (any
# component, any case: the markitdown cache memokit-<n>-careful-convert/
# <key>/<name>.md, which the orchestrator's next Read of that document
# returns). One bash regex on the whole path, no fork.
_MK_GS_SNAP=""
_mk_gs_state_name() { local LC_ALL=C re='^memokit-[0-9]+-careful-'; [[ $1 =~ $re ]]; }
_mk_gs_state_below() {
  local LC_ALL=C re='(^|/)[Mm][Ee][Mm][Oo][Kk][Ii][Tt]-[0-9]+-[Cc][Aa][Rr][Ee][Ff][Uu][Ll]-[^/]*/'
  [[ $1 =~ $re ]]
}
_mk_gs_snap_deny() {
  local b
  b="$(basename "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$b" in
    *careful-config*) deny "$(mk_msg GS_SNAPSHOT_EDIT "$FPATH")" ;;
  esac
  _mk_gs_state_name "$b" && deny "$(mk_msg GS_STATE_EDIT "$FPATH")"
  _mk_gs_state_below "$1" && deny "$(mk_msg GS_STATE_EDIT "$FPATH")"
  if [ -n "$_MK_GS_SNAP" ] && [ -e "$_MK_GS_SNAP" ] && [ "$1" -ef "$_MK_GS_SNAP" ]; then
    deny "$(mk_msg GS_SNAPSHOT_EDIT "$FPATH")"
  fi
  return 0
}
# _mk_gs_state_hard PATH -- denies (GS_STATE_EDIT) when PATH is a file with
# more than one link and ANY name with its inode directly under
# ${TMPDIR:-/tmp} starts with memokit- (a hard link made elsewhere, src/x, to
# a record or marker). One find (-maxdepth 1, by inode); no cap and no
# second filter, so decoy names cannot crowd a state file out. A find that
# fails denies too. Release fix d: also any name one or two levels inside a
# memokit-<digits>-careful-* directory there (the markitdown cache entries):
# a second find runs one more find in each such directory (the hook runs
# under set -f: no glob); an inner find that fails prints the directory,
# which denies.
_mk_gs_state_hard() {
  local n i out d="${TMPDIR:-/tmp}"
  [ -f "$1" ] || return 0
  if stat -c %h / >/dev/null 2>&1; then n="$(stat -c '%h %i' "$1" 2>/dev/null)"
  else n="$(stat -f '%l %i' "$1" 2>/dev/null)"; fi
  i="${n#* }"; n="${n%% *}"
  case "$n" in ''|*[!0-9]*|0|1) return 0 ;; esac
  case "$i" in ''|*[!0-9]*) return 0 ;; esac
  out="$(find -H "$d" -maxdepth 1 -name 'memokit-*' -inum "$i" 2>/dev/null)" || deny "$(mk_msg GS_STATE_EDIT "$FPATH")"
  [ -z "$out" ] || deny "$(mk_msg GS_STATE_EDIT "$FPATH")"
  out="$(find -H "$d" -mindepth 1 -maxdepth 1 -type d -name 'memokit-[0-9]*-careful-*' \
    \( -exec find {} -mindepth 1 -maxdepth 2 -inum "$i" \; -o -print \) 2>/dev/null)" || deny "$(mk_msg GS_STATE_EDIT "$FPATH")"
  [ -z "$out" ] || deny "$(mk_msg GS_STATE_EDIT "$FPATH")"
  return 0
}

# Installed plugin files (0.8.1): the plugin root this hook runs from
# ($MK_HOOKS_DIR/..), $CLAUDE_PLUGIN_ROOT when set, ~/.claude/plugins (every
# installed plugin and the marketplace clones) and $CLAUDE_CONFIG_DIR/plugins
# when set are protected DIRECTORY prefixes: a target that is one of them or
# lies below one (any case). A root that is the harness project or lies
# above it (by device:inode, from the project's named and physical spelling)
# does not cover the project tree: memokit run with --plugin-dir on its own
# checkout, or a project that is a worktree inside a plugin checkout, keeps
# its own files, and the root still protects everything outside the project.
# The project tree is matched by EXACT spelling (as named and physically
# resolved; no case folding). There is no exemption at all when
# CLAUDE_PROJECT_DIR is unset or does not resolve to <root>, or when <root>
# lies in ~/.claude/plugins or $CLAUDE_CONFIG_DIR/plugins; a root strictly
# inside the project tree (the project is $HOME, a vendored plugin dir) is
# never exempt.
# _mk_gs_plug_init (once, only on the Edit/Write and Bash paths) sets
# _MK_GS_PLUG_LCX / _MK_GS_PLUG_LCN: every lower-cased spelling of the
# exempt-capable roots and of the others (as named and folded, physically
# resolved, and below the physical parent), one per line; _MK_GS_PLUG_PX:
# the project's spellings as given (empty: no exemption); _MK_GS_PLUG_DA and
# _MK_GS_PLUG_DX: the roots as named and their exempt-capable flags, for the
# device:inode tests. A root or project spelling that is / is skipped.
_MK_GS_PLUG_DONE=0; _MK_GS_PLUG_LCX=""; _MK_GS_PLUG_LCN=""; _MK_GS_PLUG_PX=""
_MK_GS_PLUG_DA=(); _MK_GS_PLUG_DX=()
# _mk_gs_plug_spell DIR -- DIR folded, physically resolved and below its
# physical parent, one per line (/ left out).
_mk_gs_plug_spell() {
  local d e p
  d="$(_mk_gs_abs "$1")"
  [ "$d" = / ] && return 0
  printf '%s\n' "$d"
  if e="$(cd -P "$d" 2>/dev/null && pwd -P)" && [ "$e" != / ]; then printf '%s\n' "$e"; fi
  p="${d%/*}"
  if e="$(cd -P "${p:-/}" 2>/dev/null && pwd -P)"; then printf '%s\n' "${e%/}/${d##*/}"; fi
}
# _mk_gs_plug_above DIR PATH... -- 0 when one of the PATHs or one of their
# ancestors is DIR (device:inode).
_mk_gs_plug_above() {
  local d="$1" a
  shift
  for a in "$@"; do
    while [ -n "$a" ]; do
      [ "$a" -ef "$d" ] && return 0
      [ "$a" = / ] && break
      a="${a%/*}"; a="${a:-/}"
    done
  done
  return 1
}
_mk_gs_plug_init() {
  local d s mp="" cl cp x=0 i
  [ "$_MK_GS_PLUG_DONE" = 1 ] && return 0
  _MK_GS_PLUG_DONE=1
  # mk_resolve_root falls back to the payload cwd or the git top level when
  # CLAUDE_PROJECT_DIR is unset or holds no config: such a root is not the
  # harness project and gets no exemption.
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -n "$MK_ROOT" ] && mp="$(cd -P "$MK_ROOT" 2>/dev/null && pwd -P)"; then
    cl="$(cd "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd)" || cl=""
    cp="$(cd -P "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)" || cp=""
    if [ "$cl" = "$MK_ROOT" ] || [ "$cp" = "$mp" ]; then x=1; fi
  fi
  if [ "$x" = 1 ]; then
    # Never inside an installed cache or marketplace clone.
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if _mk_gs_plug_above "$d" "$MK_ROOT" "$mp"; then x=0; continue; fi
      s="$(_mk_gs_plug_spell "$d" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      while IFS= read -r cl; do
        [ -n "$cl" ] || continue
        case "$(_mk_gs_lc "$MK_ROOT")/" in "$cl"/*) x=0 ;; esac
        case "$(_mk_gs_lc "$mp")/" in "$cl"/*) x=0 ;; esac
      done <<EOF2
$s
EOF2
    done <<EOF
${HOME:+$HOME/.claude/plugins}
${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/plugins}
EOF
  fi
  [ "$x" = 1 ] && _MK_GS_PLUG_PX="$(_mk_gs_plug_spell "$MK_ROOT"; printf '%s\n' "$mp")"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d="$(_mk_gs_abs "$d")"
    [ "$d" = / ] && continue
    i=0
    if [ "$x" = 1 ] && _mk_gs_plug_above "$d" "$MK_ROOT" "$mp"; then i=1; fi
    s="$(_mk_gs_plug_spell "$d")"
    if [ "$i" = 1 ]; then _MK_GS_PLUG_LCX="$_MK_GS_PLUG_LCX$s$_MK_GS_NL"
    else _MK_GS_PLUG_LCN="$_MK_GS_PLUG_LCN$s$_MK_GS_NL"; fi
    _MK_GS_PLUG_DA+=("$d"); _MK_GS_PLUG_DX+=("$i")
  done <<EOF
$MK_HOOKS_DIR/..
${CLAUDE_PLUGIN_ROOT:-}
${HOME:+$HOME/.claude/plugins}
${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/plugins}
EOF
  _MK_GS_PLUG_LCX="$(printf '%s' "$_MK_GS_PLUG_LCX" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u)"
  _MK_GS_PLUG_LCN="$(printf '%s' "$_MK_GS_PLUG_LCN" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u)"
}
# _mk_gs_plug_inpx PATH -- 0 when PATH, as spelled, is a project spelling or
# lies below one (case-exact; never when there is no exemption).
_mk_gs_plug_inpx() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$1" in "$p"|"$p"/*) return 0 ;; esac
  done <<EOF
$_MK_GS_PLUG_PX
EOF
  return 1
}
# _mk_gs_plug_deny PATH -- denies (GS_PLUGIN_EDIT, naming FPATH) when PATH
# (absolute) is a plugin root or lies below one by lower-cased spelling, or
# one of its existing ancestors is a root by device:inode (test -ef: another
# spelling of the same directory), unless that root is exempt-capable and
# PATH lies in the project tree by exact spelling (_mk_gs_plug_inpx). Every
# test runs; each hit is judged by its own root.
_mk_gs_plug_deny() {
  local l r a i
  l="$(_mk_gs_lc "$1")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$l" in "$r"|"$r"/*) deny "$(mk_msg GS_PLUGIN_EDIT "$FPATH")" ;; esac
  done <<EOF
$_MK_GS_PLUG_LCN
EOF
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$l" in
      "$r"|"$r"/*) _mk_gs_plug_inpx "$1" || deny "$(mk_msg GS_PLUGIN_EDIT "$FPATH")" ;;
    esac
  done <<EOF
$_MK_GS_PLUG_LCX
EOF
  a="$1"
  while [ -n "$a" ] && [ "$a" != / ]; do
    if [ -d "$a" ]; then
      for ((i = 0; i < ${#_MK_GS_PLUG_DA[@]}; i++)); do
        [ "$a" -ef "${_MK_GS_PLUG_DA[i]}" ] || continue
        if [ "${_MK_GS_PLUG_DX[i]}" != 1 ] || ! _mk_gs_plug_inpx "$1"; then deny "$(mk_msg GS_PLUGIN_EDIT "$FPATH")"; fi
      done
    fi
    a="${a%/*}"
  done
  return 0
}
# _mk_gs_plug_hard PATH -- denies (GS_PLUGIN_EDIT) when PATH is a file with
# more than one link and one of them lies below a plugin root and is not
# exempt from it: one stat per call; only for a hard link one find -inum per
# root, each match confirmed by test -ef (same device).
_mk_gs_plug_hard() {
  local n i f k
  { [ "${#_MK_GS_PLUG_DA[@]}" -gt 0 ] && [ -f "$1" ]; } || return 0
  if stat -c %h / >/dev/null 2>&1; then n="$(stat -c '%h %i' "$1" 2>/dev/null)"
  else n="$(stat -f '%l %i' "$1" 2>/dev/null)"; fi
  i="${n#* }"; n="${n%% *}"
  case "$n" in ''|*[!0-9]*|0|1) return 0 ;; esac
  case "$i" in ''|*[!0-9]*) return 0 ;; esac
  for ((k = 0; k < ${#_MK_GS_PLUG_DA[@]}; k++)); do
    while IFS= read -r f; do
      { [ -n "$f" ] && [ "$f" -ef "$1" ]; } || continue
      if [ "${_MK_GS_PLUG_DX[k]}" != 1 ] || ! _mk_gs_plug_inpx "$f"; then deny "$(mk_msg GS_PLUGIN_EDIT "$FPATH")"; fi
    done <<EOF
$(find -H "${_MK_GS_PLUG_DA[k]}" -xdev -inum "$i" 2>/dev/null | head -n 64)
EOF
  done
  return 0
}

# --- Rule 2: no commit / merge / branch deletion / history rewrite / remote
#     mutation / stash. --------------------------------------------------------
# --- Rule 2a: no edit of the project config (the remote block lives there). ---
# The path is normalised first; naming <root>/.claude or its memokit.json
# denies. Symlink chains are followed (max 10 hops, as guard-destructive.sh
# does for the grant file); any hop naming memokit.json, or a link that cannot
# be resolved, denies. Other paths are untouched.
# The settings files (0.8.1) are checked at the same points by exact path
# (_mk_gs_set_deny): the physical resolution, every hop of the symlink walk,
# the device:inode test and the existing prefix of a missing parent; the
# config snapshot (0.8.1, _mk_gs_snap_deny) at the same points.
# The plugin roots (0.8.1, _mk_gs_plug_deny) at the same points, by prefix;
# the resolved file also by its other links (_mk_gs_plug_hard).
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    FPATH="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // empty)' 2>/dev/null)" || \
      deny "$(mk_msg GS_CMD_EXTRACT_FAILED)"
    [ -n "$FPATH" ] || exit 0
    _mk_gs_set_init
    _mk_gs_plug_init
    _MK_GS_SNAP="$(mk_config_snapshot_file "$PAYLOAD")"
    # A leading ~ names the home directory, as the file tools read it.
    if [ -n "${HOME:-}" ]; then
      case "$FPATH" in \~|\~/*) FPATH="$HOME${FPATH#"~"}" ;; esac
    fi
    _mk_gs_pr="$(_mk_gs_lc "$(cd -P "$MK_ROOT" 2>/dev/null && pwd -P)")"
    if printf '%s' "$FPATH" | grep -qiE '\.claude.*/\.\.(/|$)' 2>/dev/null; then
      deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")"
    fi
    # Physical resolution of the UNFOLDED path (the kernel walks .. after a
    # symlink physically, the lexical fold does not): cd -P on its parent plus
    # the basename. Either resolution landing on the config or the .claude dir
    # denies. A .. after a symlink component denies unless both resolutions
    # name the same directory.
    case "$FPATH" in /*) _mk_gs_raw="$FPATH" ;; *) _mk_gs_raw="$_MK_GS_CWD/$FPATH" ;; esac
    _mk_gs_cfgf="$MK_ROOT/.claude/memokit.json"
    _mk_gs_pdir="$(cd -P "$(dirname "$_mk_gs_raw")" 2>/dev/null && pwd -P)" || _mk_gs_pdir=""
    if [ -n "$_mk_gs_pdir" ]; then
      _mk_gs_phys="$_mk_gs_pdir/$(basename "$_mk_gs_raw")"
      _mk_gs_set_deny "$_mk_gs_phys"
      _mk_gs_snap_deny "$_mk_gs_phys"
      _mk_gs_plug_deny "$_mk_gs_phys"
      if [ "$_mk_gs_phys" -ef "$_mk_gs_cfgf" ] || [ "$_mk_gs_phys" -ef "$MK_ROOT/.claude" ]; then
        deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")"
      fi
      case "$(_mk_gs_lc "$_mk_gs_phys")" in
        "$_mk_gs_pr/.claude"|"$_mk_gs_pr/.claude/memokit.json"|"$_mk_gs_pr/.claude/."|"$_mk_gs_pr/.claude/memokit.json/.") deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")" ;;
      esac
    fi
    _mk_gs_pre=""; _mk_gs_sl=0; _mk_gs_rest="$_mk_gs_raw/"
    while [ -n "$_mk_gs_rest" ]; do
      _mk_gs_c="${_mk_gs_rest%%/*}"; _mk_gs_rest="${_mk_gs_rest#*/}"
      case "$_mk_gs_c" in ''|.) continue ;; esac
      if [ "$_mk_gs_c" = .. ] && [ "$_mk_gs_sl" = 1 ]; then
        # A .. after a directory that does not exist: no kernel walk can
        # pass it, only the lexical fold (checked below, with its longest
        # existing prefix resolved physically; I7, p19).
        [ -d "$_mk_gs_pre" ] || break
        _mk_gs_ldir="$(dirname "$(_mk_gs_abs "$_mk_gs_raw")")"
        [ -n "$_mk_gs_pdir" ] && [ "$_mk_gs_pdir" -ef "$_mk_gs_ldir" ] && break
        deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")"
      fi
      _mk_gs_pre="$_mk_gs_pre/$_mk_gs_c"
      [ -L "$_mk_gs_pre" ] && _mk_gs_sl=1
    done
    FPATH="$(_mk_gs_abs "$FPATH")"
    _mk_gs_roots="$(_mk_gs_lc "$MK_ROOT")
$(_mk_gs_lc "$(cd -P "$MK_ROOT" 2>/dev/null && pwd -P)")"
    hops=0
    while :; do
      _mk_gs_lp="$(_mk_gs_lc "$FPATH")"
      while IFS= read -r _mk_gs_r; do
        [ -n "$_mk_gs_r" ] || continue
        case "$_mk_gs_lp" in
          "$_mk_gs_r/.claude"|"$_mk_gs_r/.claude/memokit.json") deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")" ;;
        esac
      done <<EOF
$_mk_gs_roots
EOF
      case "$(basename "$FPATH" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
        memokit.json) deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")" ;;
      esac
      _mk_gs_set_deny "$FPATH"
      _mk_gs_snap_deny "$FPATH"
      _mk_gs_plug_deny "$FPATH"
      [ -L "$FPATH" ] || break
      hops=$((hops + 1))
      if [ "$hops" -gt 10 ] || ! LNK="$(readlink "$FPATH" 2>/dev/null)" || [ -z "$LNK" ]; then
        deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")"
      fi
      case "$LNK" in
        /*) FPATH="$(_mk_gs_abs "$LNK")" ;;
        *) FPATH="$(_mk_gs_abs "$(dirname "$FPATH")/$LNK")" ;;
      esac
    done
    # Second trigger: the same device:inode as the config (hard links,
    # directory symlinks). The directory is resolved with cd -P (no readlink
    # -f); GNU stat is probed first because BSD's -f means something else.
    _mk_gs_stat() {
      if stat -c %d:%i / >/dev/null 2>&1; then stat -c %d:%i "$1" 2>/dev/null
      else stat -f %d:%i "$1" 2>/dev/null; fi
    }
    _mk_gs_dir="$(dirname "$FPATH")"
    if _mk_gs_real="$(cd -P "$_mk_gs_dir" 2>/dev/null && pwd -P)"; then
      _mk_gs_set_deny "$_mk_gs_real/$(basename "$FPATH")"
      _mk_gs_snap_deny "$_mk_gs_real/$(basename "$FPATH")"
      _mk_gs_plug_deny "$_mk_gs_real/$(basename "$FPATH")"
      _mk_gs_plug_hard "$_mk_gs_real/$(basename "$FPATH")"
      _mk_gs_state_hard "$_mk_gs_real/$(basename "$FPATH")"
      _mk_gs_tgt="$(_mk_gs_stat "$_mk_gs_real/$(basename "$FPATH")")" || _mk_gs_tgt=""
      _mk_gs_cfg="$(_mk_gs_stat "$MK_ROOT/.claude/memokit.json")" || _mk_gs_cfg=""
      if [ -n "$_mk_gs_tgt" ] && [ -n "$_mk_gs_cfg" ] && [ "$_mk_gs_tgt" = "$_mk_gs_cfg" ]; then
        deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")"
      fi
    else
      # An unresolvable parent (a directory not created yet). FPATH is the
      # lexical fold (a .. after a symlink was denied above unless both
      # resolutions agree), so the fold comes first (I7, p19: a missing
      # parent plus .. used to deny every such path); then its longest
      # existing prefix is resolved physically and the rest appended. Either
      # spelling holding a .claude component outside a .claude/<sub>/ lane
      # denies; a new subdirectory below a lane is ordinary.
      _mk_gs_e="$(dirname "$FPATH")"
      while [ -n "$_mk_gs_e" ] && [ ! -d "$_mk_gs_e" ]; do _mk_gs_e="${_mk_gs_e%/*}"; done
      _mk_gs_ep="$(cd -P "${_mk_gs_e:-/}" 2>/dev/null && pwd -P)" || deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")"
      _mk_gs_ep="${_mk_gs_ep%/}${FPATH#"$_mk_gs_e"}"
      _mk_gs_set_deny "$_mk_gs_ep"
      _mk_gs_snap_deny "$_mk_gs_ep"
      _mk_gs_plug_deny "$_mk_gs_ep"
      for _mk_gs_lp in "$(_mk_gs_lc "$FPATH")" "$(_mk_gs_lc "$_mk_gs_ep")"; do
        case "$_mk_gs_lp" in
          "$_mk_gs_pr/.claude"|"$_mk_gs_pr/.claude/memokit.json") deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")" ;;
          */.claude/*/*) ;;
          */.claude|*/.claude/*) deny "$(mk_msg GS_CONFIG_EDIT "$FPATH")" ;;
        esac
      done
    fi
    exit 0
    ;;
esac

[ "$TOOL" = "Bash" ] || exit 0

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)" || \
  deny "$(mk_msg GS_CMD_EXTRACT_FAILED)"
[ -z "$CMD" ] && exit 0

# Heredoc BODY lines are DATA, not commands -- a subagent writing a doc or a
# test fixture via `cat > docs/x.md <<'EOF' ... EOF` can legitimately contain
# example text such as "git commit -m x" inside the body purely as
# illustration. Without stripping heredoc bodies first, the segment-based
# scan below would treat that documentation text as a real command and
# false-positive deny it. Detects `<<MARKER`, `<<-MARKER`, `<<'MARKER'`, `<<"MARKER"`,
# `<<\MARKER` and drops every line from the one after the opener up to (and
# re-including) the line that is exactly the bare marker (leading tabs
# stripped first when the `<<-` form was used, matching real shell
# semantics). Heuristic gap, accepted: a marker containing shell
# metacharacters beyond the ones stripped here, or two heredocs opened on the
# same line, are not specially handled -- under-detection only (a body line
# that happens to look exactly like a real ban-worthy command would then
# still be scanned), never an over-denial.
strip_heredoc_bodies() { mk_strip_heredoc_bodies "$1"; }
CMD_ORIG="$CMD"
CMD="$(strip_heredoc_bodies "$CMD")"

# `bash -c "..."` / `sh -c "..."` / `zsh -c "..."` / `dash -c "..."` run their
# argument as a nested command line -- `bash -c "git commit -m x"` must be
# caught exactly like a bare `git commit -m x`. Extracted here (once, on the
# whole command) rather than during segment tokenization below, because the
# inner command's own internal spaces would otherwise be destroyed by the
# same whitespace-only tokenization used to find it. The extracted text is
# appended as extra lines so it goes through the exact same segment/tokenize/
# git-detect pass as everything else, INCLUDING its own `;`/`&&`/heredocs.
# Heuristic, not a parser: only the first `-c ` occurrence on the whole
# command is honoured, and only one layer of surrounding quote is stripped
# (an escaped same-type quote INSIDE the inner command, e.g.
# `bash -c "git \"commit\""`, is not specially unescaped). Under-detection
# only -- a form this misses simply is not scanned, it is never wrongly
# flagged as a result of this step.
extract_dash_c_inner() {
  c="$1"
  # `bash`, `zsh`, and `dash` all happen to END in "sh", so a single
  # substring check for "sh -c " already covers `bash -c `, `zsh -c `,
  # `dash -c ` and plain `sh -c ` -- listing them separately would be dead
  # pattern duplication (shellcheck SC2221/SC2222 flagged exactly this).
  # Trade-off: any OTHER command ending in "sh" followed by " -c " (a custom
  # script literally named "*sh") would also match; harmless false-trigger,
  # since it only leads to scanning some extra text that will not contain a
  # `git` invocation.
  case "$c" in
    *'sh -c '*) : ;;
    *) printf '%s' ""; return ;;
  esac
  # The text after the first "-c "; when it opens with a quote, up to the
  # next same quote. One awk (0.8.0 final wave: ${c#*-c } took 5.8 s on
  # 100 KB under a UTF-8 locale, past the hook timeout).
  printf '%s\n' "$c" | LC_ALL=C awk '
    { if (!f) {
        i = index($0, "-c "); if (!i) next
        f = 1; s = substr($0, i + 3); q = substr(s, 1, 1)
        if (q == "\"" || q == "\047") s = substr(s, 2); else q = ""
      } else s = $0
      if (q != "" && (j = index(s, q))) { printf "%s%s", sep, substr(s, 1, j - 1); exit }
      printf "%s%s", sep, s; sep = "\n" }'
}
INNER_CMD="$(extract_dash_c_inner "$CMD")"
[ -n "$INNER_CMD" ] && CMD="$CMD
$INNER_CMD"

# --- Rule 3 (0.8.0): no remote target, no change-window request. -------------
# Remote targets (a configured host, a deploy branch, a cluster, a runbook, a
# project pattern with a target) and the window request script belong to the
# orchestrator, which asks the user (WORKING-MODEL.md section 10). A subagent
# gets no read-only/download/dry-run exemption: MK_REMOTE_NO_EXEMPT=1 for the
# scan. Identity is the verified payload agent_id (IS_SUB above), never the
# environment. The rule runs on the ORIGINAL command (heredoc bodies included:
# `bash <<EOF ... ssh host ... EOF` runs its body) and on the stripped one;
# either view hitting denies (fail closed; a doc body naming a remote command
# is an accepted false positive).
# A subagent has no business with the installed plugin: deny the request
# script under any spelling, any reference to the plugin root or its install
# location, and a glob/expansion inside a word that names the request script.
# A memokit checkout (its hooks/, tests/) is ordinary.
_mk_gs_rx='memokit-window(\.sh)?([^[:alnum:]_.-]|$)'
# Install locations: the plugin cache, .claude/plugins, memokit/<version>.
_mk_gs_rx_dir='plugins/cache|\.claude/plugins|memokit/[0-9]+\.[0-9]+'
# Writing position on the project config (the remote block lives there).
_mk_gs_rx_wr='>|(^|[^[:alnum:]_-])(tee|cp|mv|rm|ln|truncate|install)([^[:alnum:]_-]|$)|(sed|perl)[[:space:]]+-[^[:space:]]*i|--in-place'
# A command substitution (which can hold spaces) followed by such a name later
# on the line counts too.
# shellcheck disable=SC2016  # regex, not an expansion
_mk_gs_rx_glob='(^|[[:space:]])[^[:space:]]*([*?[$`{][^[:space:]]*kit-w|kit-w[^[:space:]]*[*?[$`{])|(\$\(|`).*kit-w'
_mk_gs_win_hit() {
  printf '%s' "$1" | grep -qiE "$_mk_gs_rx" 2>/dev/null && return 0
  printf '%s' "$1" | grep -qiE 'CLAUDE_PLUGIN_ROOT' 2>/dev/null && return 0
  printf '%s' "$1" | grep -qiE "$_mk_gs_rx_dir" 2>/dev/null && return 0
  printf '%s' "$1" | grep -qiE "$_mk_gs_rx_glob" 2>/dev/null && return 0
  return 1
}
# A subagent may not run memokit's session-start.sh (0.8.1): it rewrites,
# or with an invalid config removes, this session's config snapshot. No
# filesystem resolution (copies sit in old plugin caches and checkouts, and
# cd/find/xargs make the base unknowable): only the text. A hit:
# - session-start.sh anywhere in the text (any case; the flat view undoes
#   quoting);
# - a $( or a backquote together with start.sh or session anywhere in the
#   text (any case);
# - a word (quotes and backslashes dropped; split on blanks, ; | & < > ( )
#   and =) whose last component (after the final /) holds a glob or an
#   expansion and could match session-start.sh with each construct read as a
#   wildcard ($NAME, ${...}, a backquote run and {...} as .*, * as .*, ? and
#   [...] as one character). A component made of wildcards only ($D, *, {}),
#   or of wildcards and then only a tail of .sh (*.sh, $name.sh, ${n}.sh),
#   says nothing about the name and is no hit. One awk.
# A hit passes when the whole command is a plain read: one read verb
# (shellcheck counts: it never runs the script; sed and git do not: sed e
# and git's diff/filter drivers can run commands), optionally piped into
# read filters, holding no ; & < > $ ` ( ) \ or newline. Byte-wise
# (LC_ALL=C); a grep or awk error is a hit.
_mk_gs_ss_hit() {
  local LC_ALL=C rc=0 w ro nl='
'
  printf '%s' "$1" 2>/dev/null | grep -qiF 'session-start.sh' 2>/dev/null || rc=$?
  if [ "$rc" -eq 1 ]; then
    # A command substitution can assemble the name (hooks/$(echo
    # session)-start.sh): a text holding $( or a backquote that also names
    # start.sh or session is a hit (two fixed-string greps, no grammar).
    # shellcheck disable=SC2016  # fixed strings, not expansions
    if printf '%s' "$1" | grep -qF -e '$(' -e '`' && printf '%s' "$1" | grep -qiF -e 'start.sh' -e 'session'; then
      rc=0
    else
      # Linear: whole-component substitutions only (W = a .* wildcard, Q =
      # one character; the component is lower-cased first, so neither occurs
      # in it), at most 16 fixed characters reach the regex.
      # shellcheck disable=SC2016  # awk program, not an expansion
      printf '%s\n' "$1" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr ';|&<>()=[:space:]' '\n' |
        LC_ALL=C grep -E '[*?[$`{]' | LC_ALL=C awk '
      { l = $0; sub(/^.*\//, "", l); l = tolower(l)
        gsub(/\$\{[^}]*\}?/, "W", l); gsub(/\$[a-z0-9_]*/, "W", l); gsub(/`[^`]*`?/, "W", l)
        gsub(/\{[^}]*\}?/, "W", l); gsub(/\[[^]]*\]?/, "Q", l); gsub(/\*/, "W", l); gsub(/\?/, "Q", l)
        if (l ~ /[^a-z0-9_.WQ-]/ || l !~ /[a-z0-9_.-]/) next
        # wildcards then only a tail of .sh (*.sh, ${n}.sh): any script
        if (l ~ /^[WQ]+(\.sh|sh|h)$/) next
        gsub(/W+/, "W", l); t = l; gsub(/W/, "", t)
        if (length(t) > 16) next
        gsub(/\./, "[.]", l); gsub(/W/, ".*", l); gsub(/Q/, ".", l)
        if ("session-start.sh" ~ ("^" l "$")) { f = 1; exit } }
      END { exit !f }'
      [ $? -eq 1 ] || rc=0
    fi
  fi
  [ "$rc" -eq 1 ] && return 1
  [ "$rc" -eq 0 ] || return 0
  w="[^|;&<>\$\`()\\\\${nl}]"
  ro="^[[:space:]]*(cat|grep|egrep|fgrep|head|tail|wc|ls|diff|stat|file|shellcheck)[ 	]${w}*([|][ 	]*(grep|egrep|fgrep|head|tail|wc|sort|uniq|cat|nl)([ 	]${w}*)?)*\$"
  [[ $1 =~ $ro ]] && return 1
  return 0
}
# Is the payload cwd physically under <root>/.claude (a worktree lane)?
_MK_GS_INCL=0
_MK_GS_PROOT="$(cd -P "$MK_ROOT" 2>/dev/null && pwd -P)" || _MK_GS_PROOT="$MK_ROOT"
if _mk_gs_pcwd="$(cd -P "$_MK_GS_CWD" 2>/dev/null && pwd -P)"; then
  case "$_mk_gs_pcwd/" in "$_MK_GS_PROOT/.claude/"*) _MK_GS_INCL=1 ;; esac
fi
# _mk_gs_ef WORD TARGET... -- 0 when WORD names one of the TARGETs by
# device:inode (a symlink or a hard link). Relative words resolve against the
# payload cwd and every literal cd target. `test -ef` is a builtin: no fork
# per word.
_mk_gs_ef() {
  local w="$1" b t
  shift
  case "$w" in
    /*) for t in "$@"; do [ "$w" -ef "$t" ] && return 0; done; return 1 ;;
  esac
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    for t in "$@"; do [ "$b/$w" -ef "$t" ] && return 0; done
  done <<EOF
$_mk_gs_bases
EOF
  return 1
}
# _mk_gs_ef_any TARGET... -- stdin: words, one per line; 0 when a literal
# one (no $, backtick or glob character; a glued short option -Xpath also as
# path) names one of the TARGETs by device:inode, as _mk_gs_ef does per
# word. 0.8.0 final wave: one awk builds every path (each relative word
# against every base in _mk_gs_bases) and ONE xargs stat reads them all; the
# per-word loop took 4 s for 9 000 words and 9 cd targets. When the targets'
# ids cannot all be read (no stat), the per-word builtin loop runs instead.
_mk_gs_ef_any() {
  local fmt ids w n=0 paths
  if stat -L -c %d:%i / >/dev/null 2>&1; then fmt="-c"; else fmt="-f"; fi
  ids="$(stat -L "$fmt" %d:%i "$@" 2>/dev/null)" || ids=""
  while IFS= read -r w; do case "$w" in *:*) n=$((n + 1)) ;; esac; done <<EOF
$ids
EOF
  if [ "$n" != "$#" ]; then
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      case "$w" in *'$'*|*'`'*|*'*'*|*'?'*|*'['*) continue ;; esac
      n=""
      case "$w" in -[!-]?*) n="${w#-?}" ;; esac
      if _mk_gs_ef "$w" "$@" || { [ -n "$n" ] && _mk_gs_ef "$n" "$@"; }; then return 0; fi
    done
    return 1
  fi
  # More than MK_GS_MAX_PATHS distinct paths: 2 (too large to check).
  paths="$(MK_GS_BASES="$_mk_gs_bases" LC_ALL=C awk -v m="$MK_GS_MAX_PATHS" '
    BEGIN { nb = split(ENVIRON["MK_GS_BASES"], b, "\n") }
    function emit(x,   i) {
      if (substr(x, 1, 1) == "/") { out(x); return }
      for (i = 1; i <= nb; i++) if (b[i] != "") out(b[i] "/" x) }
    function out(p) { if (seen[p]++) return; if (++n > m) exit 3; print p }
    $0 == "" || /[$`*?[]/ { next }
    { emit($0); if ($0 ~ /^-[^-]./) emit(substr($0, 3)) }')"
  case $? in 0) ;; 3) return 2 ;; *) return 0 ;; esac
  [ -n "$paths" ] || return 1
  printf '%s\n' "$paths" | LC_ALL=C tr '\n' '\000' | xargs -0 stat -L "$fmt" %d:%i 2>/dev/null |
    grep -qxF -e "$ids"
}
# Bounds of the config gate (0.8.0 final wave, C1: every per-word loop below
# forked per word, and a cheap command of a few thousand such words kept the
# hook past the 5 s timeout, after which Claude Code ran it unchecked).
# Every word list is de-duplicated and filtered by one pipeline before a
# bash loop sees it, .. paths are folded by one awk for all words, and no
# loop forks per word. Past a bound the command is too large to check
# (GS_TOO_LARGE, fail closed): more than MK_GS_MAX_CHARS bytes, or more
# than MK_GS_MAX_SPECIAL words holding .., words holding $ or a backtick,
# or words holding a brace group with a comma or a range (counted before
# de-duplication). A brace word longer than MK_GS_MAX_BRACE_LEN bytes, or
# whose expansion would pass MK_GS_MAX_BRACE_ALTS alternatives, is not
# expanded: it is a config reference (fail closed), and so are more than
# MK_GS_MAX_ALTS alternatives over all words and more than MK_GS_MAX_BASES
# literal cd/pushd targets. More than MK_GS_MAX_PATHS distinct paths for the
# device:inode test (words times cd targets): too large.
MK_GS_MAX_CHARS=65536
MK_GS_MAX_SPECIAL=512
MK_GS_MAX_BRACE_LEN=256
MK_GS_MAX_BRACE_ALTS=64
MK_GS_MAX_ALTS=1024
MK_GS_MAX_PATHS=16384
MK_GS_MAX_BASES=8
# _mk_gs_fold BASES -- stdin: one path per line; stdout: each joined to every
# base of BASES (one per line) when relative and folded lexically (empty and
# . components dropped, .. folds its parent), as _mk_gs_abs does for one
# path; one awk, linear.
_mk_gs_fold() {
  MK_GS_FOLD_BASE="$1" LC_ALL=C awk '
    BEGIN { nb = split(ENVIRON["MK_GS_FOLD_BASE"], b, "\n") }
    function fold(p,   n, c, i, k, st, o) {
      n = split(p, c, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (c[i] == "" || c[i] == ".") continue
        if (c[i] == "..") { if (k > 0) k--; continue }
        st[++k] = c[i] }
      o = ""; for (i = 1; i <= k; i++) o = o "/" st[i]
      print (o == "" ? "/" : o) }
    { if (substr($0, 1, 1) == "/") { fold($0); next }
      for (j = 1; j <= nb; j++) if (b[j] != "") fold(b[j] "/" $0) }'
}
# _mk_gs_brace W -- sets _MK_GS_ALTS to the brace expansion of W ({a,b},
# {x..y}), one alternative per line, without running anything (pure bash,
# no eval). A numeric range keeps its first number (digits cannot spell
# .claude or memokit); a {body} with neither a comma nor a range stays
# literal. Returns 1 (the caller fails closed: a config reference) for a
# word longer than MK_GS_MAX_BRACE_LEN, more than 8 groups, a product above
# MK_GS_MAX_BRACE_ALTS, a letter range, or a brace group left unexpanded (a
# nested one).
_mk_gs_brace() {
  local w="$1" pre body rest="$1" a l g=0 n=1 i
  local re='^([^{]*)\{([^{}]*)\}(.*)$' rx='\{[^{}]*(,|\.\.)[^{}]*\}'
  local rnum='^-?[0-9]+\.\.-?[0-9]+(\.\.-?[0-9]+)?$'
  local -a cur nxt parts
  _MK_GS_ALTS=""; _MK_GS_NALT=0
  [ "${#w}" -le "$MK_GS_MAX_BRACE_LEN" ] || return 1
  cur=("")
  while [[ $rest =~ $re ]]; do
    pre="${BASH_REMATCH[1]}"; body="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    parts=()
    case "$body" in
      *,*)
        g=$((g + 1)); [ "$g" -le 8 ] || return 1
        while :; do
          case "$body" in
            *,*) parts[${#parts[@]}]="${body%%,*}"; body="${body#*,}" ;;
            *) parts[${#parts[@]}]="$body"; break ;;
          esac
        done ;;
      *..*)
        [[ $body =~ $rnum ]] || return 1
        parts=("${body%%..*}") ;;
      *) parts=("{$body}") ;;
    esac
    n=$((n * ${#parts[@]})); [ "$n" -le "$MK_GS_MAX_BRACE_ALTS" ] || return 1
    nxt=()
    for l in "${cur[@]}"; do
      for a in "${parts[@]}"; do nxt[${#nxt[@]}]="$l$pre$a"; done
    done
    cur=("${nxt[@]}")
  done
  [[ $rest =~ $rx ]] && return 1
  _MK_GS_NALT=${#cur[@]}
  for ((i = 0; i < ${#cur[@]}; i++)); do
    _MK_GS_ALTS="$_MK_GS_ALTS${cur[i]}$rest
"
  done
  return 0
}
# _mk_gs_alts VIEW -- sets _MK_GS_ALTLIST to the brace alternatives of every
# brace word of VIEW (_mk_gs_brace, in the word's own case); 1 (a reference
# for the caller) when a word cannot be expanded, the total passes
# MK_GS_MAX_ALTS, or a brace word in a lane globs. Memoised on VIEW: the
# config and the settings checks read the same view.
_MK_GS_ALTS_V=""; _MK_GS_ALTS_RC=""; _MK_GS_ALTLIST=""
_mk_gs_alts() {
  local view="$1" w talt=0 rc=0 re_x='\{[^{}]*(,|\.\.)[^{}]*\}'
  if [ -n "$_MK_GS_ALTS_RC" ] && [ "$view" = "$_MK_GS_ALTS_V" ]; then return "$_MK_GS_ALTS_RC"; fi
  _MK_GS_ALTLIST=""
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [[ "$w" =~ $re_x ]] || continue
    if ! _mk_gs_brace "$w"; then rc=1; continue; fi
    talt=$((talt + _MK_GS_NALT))
    [ "$talt" -le "$MK_GS_MAX_ALTS" ] || { rc=1; break; }
    _MK_GS_ALTLIST="$_MK_GS_ALTLIST$_MK_GS_ALTS"
    # In a lane, a brace glob is an expansion glob.
    [ "$_MK_GS_INCL" = 1 ] && case "$w" in *[*?[]*) rc=1 ;; esac
  done <<EOF
$(printf '%s' "$view" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr ';|&<>[:space:]' '\n' | LC_ALL=C grep -F '{' | LC_ALL=C sort -u)
EOF
  _MK_GS_ALTS_V="$view"; _MK_GS_ALTS_RC=$rc
  return "$rc"
}
# _mk_gs_glob1 WORD [BASES] -- the hook runs with set -f; this expands one
# glob word on purpose (compgen -G does its own matching; a relative word
# against each of BASES, one per line, default the payload cwd; a leading ~/
# is the home directory). Sets _MK_GS_GLOB to the matches, one per line
# (empty: none); 1 when there are more than MK_GS_MAX_GLOB (the caller fails
# closed).
MK_GS_MAX_GLOB=64
_mk_gs_glob1() {
  local w="$1" bs="${2:-$_MK_GS_CWD}" b ps=""
  case "$w" in
    /*) bs="/"; w="${w#/}" ;;
    \~/*) bs="${HOME:-}"; w="${w#\~/}" ;;
  esac
  # The patterns are built out here: a case inside $(...) does not parse in
  # bash 3.2 (its ) closes the substitution).
  while IFS= read -r b; do
    [ -n "$b" ] && ps="$ps${b%/}/$w$_MK_GS_NL"
  done <<EOF
$bs
EOF
  _MK_GS_GLOB="$(printf '%s' "$ps" | while IFS= read -r b; do compgen -G "$b"; done 2>/dev/null |
    head -n "$((MK_GS_MAX_GLOB + 1))")"
  [ "$(printf '%s' "$_MK_GS_GLOB" | grep -c '^')" -le "$MK_GS_MAX_GLOB" ]
}
# _mk_gs_cd_bases VIEW -- sets _mk_gs_bases to the payload cwd plus every
# literal cd/pushd target of VIEW (options -P -L -e -@ -- skipped; a leading
# ~ is the home directory) and every directory a glob target (*, ?, [)
# matches (_mk_gs_glob1); 1 (a reference for the caller) when there are
# more than MK_GS_MAX_BASES targets or MK_GS_MAX_GLOB matches, or, in a
# lane, a target climbs or holds an expansion ($, backtick, brace).
# Memoised on VIEW.
_MK_GS_CDB_V=""; _MK_GS_CDB_RC=""
_mk_gs_cd_bases() {
  local view="$1" seg a m nb=0 rc=0 ov=0 re_u='(^|/)\.\.(/|$)'
  if [ -n "$_MK_GS_CDB_RC" ] && [ "$view" = "$_MK_GS_CDB_V" ]; then return "$_MK_GS_CDB_RC"; fi
  _mk_gs_bases="$_MK_GS_CWD"
  while IFS= read -r seg; do
    # shellcheck disable=SC2086  # intentional word splitting
    set -- $seg
    while [ $# -gt 0 ]; do case "$1" in *=*|'('|'{'|'!'|then|do|else) shift ;; *) break ;; esac; done
    case "${1:-}" in '('*) set -- "${1#(}" "${@:2}" ;; esac
    case "${1:-}" in cd|pushd) shift ;; *) continue ;; esac
    while [ $# -gt 0 ]; do case "$1" in --) shift; break ;; -[PLe@]*) shift ;; *) break ;; esac; done
    a="${1:-}"; a="${a%%)*}"
    [ -n "$a" ] || continue
    # $CLAUDE_PROJECT_DIR is the harness-set project root: not a climb.
    case "$a" in
      "\$CLAUDE_PROJECT_DIR"*) a="$MK_ROOT${a#\$CLAUDE_PROJECT_DIR}" ;;
      "\${CLAUDE_PROJECT_DIR}"*) a="$MK_ROOT${a#\$\{CLAUDE_PROJECT_DIR\}}" ;;
      \~|\~/*) [ -n "${HOME:-}" ] && a="$HOME${a#"~"}" ;;
    esac
    [[ "$a" =~ $re_u ]] && [ "$_MK_GS_INCL" = 1 ] && rc=1
    case "$a" in
      *'$'*|*'`'*|*'{'*) [ "$_MK_GS_INCL" = 1 ] && rc=1; continue ;;
      *'*'*|*'?'*|*'['*)
        _mk_gs_glob1 "$a" || { rc=1; ov=1; break; }
        while IFS= read -r m; do
          { [ -n "$m" ] && [ -d "$m" ]; } || continue
          nb=$((nb + 1))
          [ "$nb" -le "$MK_GS_MAX_BASES" ] || { rc=1; ov=1; break; }
          _mk_gs_bases="$_mk_gs_bases
$m"
        done <<EOF2
$_MK_GS_GLOB
EOF2
        [ "$ov" = 0 ] || break
        continue ;;
      /*) ;;
      *) a="$_MK_GS_CWD/$a" ;;
    esac
    nb=$((nb + 1))
    [ "$nb" -le "$MK_GS_MAX_BASES" ] || { rc=1; break; }
    _mk_gs_bases="$_mk_gs_bases
$a"
  done <<EOF
$(printf '%s' "$view" | LC_ALL=C tr -d "\"'" | LC_ALL=C tr ';|&' '\n' | LC_ALL=C grep -E '(^|[^[:alnum:]_-])(cd|pushd)([^[:alnum:]_-]|$)' | LC_ALL=C sort -u)
EOF
  _MK_GS_CDB_V="$view"; _MK_GS_CDB_RC=$rc
  return "$rc"
}
# _mk_gs_ro VIEW -- 0 when VIEW only reads: no redirection other than
# 2>/dev/null and 2>&1 (whole words, dropped), no expansion, and every
# command (after VAR= words) one of the plain read commands below. git is
# not one: it runs repo-configured programs (diff.external, textconv,
# core.pager, --ext-diff). A command that names the config or a settings
# file passes only so. One awk, linear (no line is rebuilt): segments end at
# a newline or at ; | & ( ) { }.
_mk_gs_ro() {
  # shellcheck disable=SC2016  # awk program, not an expansion
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { split("cat less head tail jq grep diff wc ls stat file", r, " ")
      for (i in r) ok[r[i]] = 1 }
    function seg() { st = 0 }
    function word(x) {
      if (st == 0) {
        if (index(x, "=")) return
        if (x in ok) st = 1; else bad = 1 } }
    { seg(); n = split($0, f, /[ \t]+/)
      for (i = 1; i <= n && !bad; i++) {
        w = f[i]
        if (match(w, /^2>(\/dev\/null|&1)/)) {
          t = substr(w, RLENGTH + 1); if (t == "" || t ~ /^[;|&)]/) w = t }
        if (w ~ /[>$`]/) { bad = 1; break }
        k = split(w, pc, /[;|&(){}]/)
        for (q = 1; q <= k && !bad; q++) { if (q > 1) seg(); if (pc[q] != "") word(pc[q]) } }
      if (!bad) seg()
      if (bad) exit }
    END { exit bad }'
}
# _mk_gs_set_map -- stdin: words, one per line; stdout: each word with a
# leading ~, $HOME, ${HOME}, $CLAUDE_PROJECT_DIR, $CLAUDE_CONFIG_DIR or
# $CLAUDE_PLUGIN_ROOT (any case; the last also as a whole word) spelled out,
# and a glued short option -Xpath also as path; one awk.
_mk_gs_set_map() {
  MK_GS_H="${HOME:-}" MK_GS_R="$MK_ROOT" MK_GS_C="${CLAUDE_CONFIG_DIR:-}" MK_GS_P="${CLAUDE_PLUGIN_ROOT:-}" LC_ALL=C awk '
    BEGIN { h = ENVIRON["MK_GS_H"]; r = ENVIRON["MK_GS_R"]; c = ENVIRON["MK_GS_C"]; pr = ENVIRON["MK_GS_P"] }
    function pre(w, p, v) {
      if (v != "" && tolower(substr(w, 1, length(p))) == p) { o = v substr(w, length(p)); return 1 }
      return 0 }
    function m(w) {
      if (h != "" && (w == "~" || substr(w, 1, 2) == "~/")) return h substr(w, 2)
      if (pre(w, "$home/", h) || pre(w, "${home}/", h) || pre(w, "$claude_project_dir/", r) \
        || pre(w, "${claude_project_dir}/", r) || pre(w, "$claude_config_dir/", c) \
        || pre(w, "${claude_config_dir}/", c) || pre(w, "$claude_plugin_root/", pr) \
        || pre(w, "${claude_plugin_root}/", pr)) return o
      if (pr != "" && (tolower(w) == "$claude_plugin_root" || tolower(w) == "${claude_plugin_root}")) return pr
      return w }
    { print m($0); if ($0 ~ /^-[^-]./) print m(substr($0, 3)) }'
}
# _mk_gs_dir_phys DIRS PDIR UDIR... -- DIRS: absolute directories, one per
# line, NOT folded (a .. after a symlink is the link target's parent, as the
# kernel resolves it). Changes directory and turns globbing off: run it only
# in $(...). For each one that exists, prints its physical spelling when it
# differs (builtin cd -P; no fork and no read per line), then "=u" when it
# is the same directory as a UDIR and "=p" when it is PDIR (device:inode,
# test -ef; a link to one of them included); "=x" for one that cannot be
# resolved. A line marked with a leading ! (the word itself climbs with ..)
# that cannot be resolved also prints "=n" when the part before its last ..
# is not on disk: once the command makes that directory, the .. lands where
# neither the folded nor the unfolded spelling can tell (a .. after a
# symlink).
_mk_gs_dir_phys() {
  local d s q k l="$1" p="$2" IFS="$_MK_GS_NL"
  shift 2
  set -f
  for d in $l; do
    k=0
    case "$d" in '!'*) d="${d#!}"; k=1 ;; esac
    if ! cd -P -- "$d" 2>/dev/null; then
      printf '=x\n'
      if [ "$k" = 1 ]; then q="$d/"; q="${q%/../*}"; [ -d "$q" ] || printf '=n\n'; fi
      continue
    fi
    [ "$PWD" = "$d" ] || printf '%s\n' "$PWD"
    for s in "$@"; do
      if [ "$d" -ef "$s" ]; then printf '=u\n'; fi
    done
    if [ -n "$p" ] && [ "$d" -ef "$p" ]; then printf '=p\n'; fi
  done
}
# _mk_gs_makes_link VIEW -- 0 when VIEW may make a symlink itself (one not
# on disk while the hook checks): ln or gln as a whole word anywhere (env
# ln, sudo ln, xargs ln, busybox ln, /bin/ln), cp with a -s or
# --symbolic-link option word in the same segment, or symlink (os.symlink,
# fs.symlinkSync); any case, quotes and backslashes dropped first. One
# regex over the text. mkdir, mv and cd do not count.
_mk_gs_makes_link() {
  # shellcheck disable=SC2016  # regex, not an expansion
  printf '%s\n' "$1" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C grep -qiE \
    '(^|[^[:alnum:]_.-])g?ln([^[:alnum:]_.-]|$)|symlink|(^|[^[:alnum:]_.-])g?cp[[:space:]]+([^;&|]*[[:space:]])?(-[[:alnum:]]*s[[:alnum:]]*|--symbolic-link)([[:space:]]|$)'
}
# _mk_gs_set_hit VIEW -- 0: VIEW writes a settings file (it names one and
# does not only read, _mk_gs_ro); 1: it does not; 2: too large to check; 3:
# VIEW does not only read and may write one: a glob that matches a settings
# file and memokit.json alike (second rule below), or a bound of
# _mk_gs_alts or _mk_gs_cd_bases was hit (a reference, as in
# _mk_gs_cfg_hit). 3 yields to the config gate's message (rm -rf .claude/*
# stays a config edit). A word names a settings file when:
# - mapped (_mk_gs_set_map), folded against the cwd and each literal cd
#   target, it is one of the exact spellings in _MK_GS_SET_LC (brace
#   alternatives too), or it is ~user/.claude/settings[.local].json;
# - it holds an expansion or a glob ($, backtick, ), *, ?, [) and either
#   contains "setting" and "json" or its last component is a glob that matches
#   settings.json or settings.local.json, while the command also names claude
#   or a home spelling (~, $HOME, ${HOME}; $CLAUDE_CONFIG_DIR names claude);
#   a glob that matches memokit.json too needs more than a bare claude
#   (.claude, a home spelling, $CLAUDE_CONFIG_DIR, a cwd or cd target in a
#   settings directory);
# - mapped, it is one of the existing files by device:inode (_mk_gs_ef_any).
_mk_gs_set_hit() {
  local view="$1" words lw ew cw bl dirs raw jd b hit=0 bnd=0 f rc st=0 ss=0 lt=0
  _mk_gs_set_init
  [ -n "$_MK_GS_SET_LC" ] || return 1
  _mk_gs_alts "$view" || bnd=1
  _mk_gs_cd_bases "$view" || bnd=1
  # Split as the config gate splits words, but not on braces (${HOME} stays
  # whole; brace expansions come from _MK_GS_ALTLIST). The name checks split
  # them on commas too (an interpreter's open(".claude/settings.json","w"));
  # the device:inode pass reads both forms (a link named /abs/a,b, and
  # open("src/link.json","w")).
  words="$({ printf '%s' "$view" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr "\`;|&()<>=[:space:]" '\n'
    printf '%s' "$_MK_GS_ALTLIST"; } | LC_ALL=C sort -u)"
  lw="$(printf '%s\n' "$words" | LC_ALL=C grep -iF settings | LC_ALL=C tr ',' '\n' | LC_ALL=C grep -iF settings)"
  if [ -n "$lw" ]; then
    # ~user/... folded first (empty and . components dropped, .. pops).
    if printf '%s\n' "$lw" | LC_ALL=C awk '
      substr($0, 1, 1) == "~" { n = split($0, c, "/"); k = 1; st[1] = c[1]
        for (i = 2; i <= n; i++) {
          if (c[i] == "" || c[i] == ".") continue
          if (c[i] == "..") { if (k > 1) k--; continue }
          st[++k] = c[i] }
        o = st[1]; for (i = 2; i <= k; i++) o = o "/" st[i]; print o }' |
      LC_ALL=C grep -qiE '^~[^/]*/\.claude/settings(\.local)?\.json$'; then hit=1; fi
    if [ "$hit" = 0 ] && printf '%s\n' "$lw" | _mk_gs_set_map | LC_ALL=C tr '[:upper:]' '[:lower:]' |
      _mk_gs_fold "$(_mk_gs_lc "$_mk_gs_bases")" | LC_ALL=C grep -qxF -e "$_MK_GS_SET_LC"; then hit=1; fi
  fi
  # Expansion and glob words: coarse words (quotes dropped; split on
  # separators, redirections, whitespace and =) holding $, a backtick, ),
  # *, ? or [, and brace alternatives.
  # shellcheck disable=SC2016  # regex, not an expansion
  cw="$({ printf '%s' "$view" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr ';|&<>=[:space:]' '\n'
    printf '%s' "$_MK_GS_ALTLIST"; } | LC_ALL=C grep -E '[$`)*?[]' | LC_ALL=C sort -u)"
  if [ "$hit" = 0 ] && [ -n "$cw" ]; then
    # The trigger (st): the command names claude, a home spelling, or
    # $CLAUDE_CONFIG_DIR by any spelling (any case; // and /./ folded on
    # both sides), or the cwd or a cd target (folded, and physically
    # resolved) lies in ~/.claude or $CLAUDE_CONFIG_DIR, or is <root>/.claude
    # itself. Below <root>/.claude/<sub>/ (a lane) only a word that climbs
    # with .. is triggered (lt). Every source but a bare "claude" is strong
    # (ss); a glob that matches settings.json and memokit.json alike needs a
    # strong one (the scratchpad, /private/tmp/claude-501/..., names claude:
    # cp dist/*.json there is ordinary).
    # shellcheck disable=SC2016  # regex, not an expansion
    if printf '%s' "$view" | LC_ALL=C grep -qiE '\.claude|~|\$\{?(home|claude_config_dir)\}?([^[:alnum:]_]|$)'; then st=1; ss=1
    elif [ -n "$_MK_GS_CCD_LC" ] && printf '%s\n' "$view" | MK_GS_CCD="$_MK_GS_CCD_LC" LC_ALL=C awk '
      BEGIN { n = split(ENVIRON["MK_GS_CCD"], d, "\n") }
      { l = tolower($0); while (gsub(/\/\.\//, "/", l)) ; gsub(/\/\/+/, "/", l)
        for (i = 1; i <= n; i++) if (d[i] != "" && index(l, d[i])) { f = 1; exit } }
      END { exit !f }'; then st=1; ss=1
    fi
    if [ "$ss" = 0 ]; then
      bl="$(printf '%s\n' "$_mk_gs_bases" | _mk_gs_fold /)"
      while IFS= read -r b; do
        [ -n "$b" ] || continue
        f="$(cd -P "$b" 2>/dev/null && pwd -P)" && bl="$bl$_MK_GS_NL$f"
      done <<EOF
$_mk_gs_bases
$bl
EOF
      case "$(printf '%s\n' "$bl" | LC_ALL=C tr '[:upper:]' '[:lower:]' | MK_GS_P="$_MK_GS_SDIR_P" MK_GS_U="$_MK_GS_SDIR_U" LC_ALL=C awk '
        BEGIN { np = split(ENVIRON["MK_GS_P"], p, "\n"); nu = split(ENVIRON["MK_GS_U"], u, "\n") }
        { for (i = 1; i <= nu; i++) if (u[i] != "" && ($0 == u[i] || index($0, u[i] "/") == 1)) { s = 1 }
          for (i = 1; i <= np; i++) if (p[i] != "") {
            if ($0 == p[i]) s = 1; else if (index($0, p[i] "/") == 1) l = 1 } }
        END { print (s ? "st" : (l ? "lt" : "")) }')" in
        st) st=1; ss=1 ;; lt) lt=1 ;;
      esac
      # A bare "claude" (weak): only a word that spells setting and json,
      # or a glob that matches a settings name but not memokit.json.
      if [ "$st" = 0 ] && printf '%s' "$view" | LC_ALL=C grep -qiF claude; then st=1; fi
    fi
    printf '%s\n' "$cw" | LC_ALL=C awk -v st="$st" -v ss="$ss" -v lt="$lt" '
      # g2re: the glob as an anchored regex, or "" when it cannot be built.
      function g2re(x,   i, ch, out, j) {
        out = ""
        for (i = 1; i <= length(x); i++) {
          ch = substr(x, i, 1)
          if (ch == "*") out = out ".*"
          else if (ch == "?") out = out "."
          else if (ch == "[") {
            j = index(substr(x, i + 1), "]")
            if (j < 2) return ""
            b = substr(x, i + 1, j - 1); if (substr(b, 1, 1) == "!") b = "^" substr(b, 2)
            out = out "[" b "]"; i += j }
          else if (ch == ".") out = out "[.]"
          else if (ch ~ /[a-z0-9_-]/) out = out ch
          else return "" }
        return "^" out "$" }
      { w = tolower($0); n = split(w, p, "/"); last = p[n]
        # An expansion word whose literal last component is a settings
        # name: a hit whatever the trigger.
        if (w ~ /[$`)]/ && (last == "settings.json" || last == "settings.local.json")) { f = 2; exit }
        cl = lt && w ~ /(^|\/)\.\.(\/|$)/
        if (!st && !cl) next
        # A glob that matches memokit.json too: only on a strong trigger.
        sw = ss || cl
        if (index(w, "setting") && index(w, "json")) { f = 2; exit }
        if (last !~ /[*?[]/) next
        re = g2re(last)
        if (re == "") {
          # Untranslatable ([[:alpha:]], []x]): settings-shaped when the
          # literal tail after the last glob character can end a settings
          # name; then a hit (fail closed), yielding to the config gate
          # when it can also end memokit.json.
          t = last; sub(/^.*[]*?]/, "", t)
          if (t == "" || substr("settings.json", 14 - length(t)) == t || substr("settings.local.json", 20 - length(t)) == t) {
            if (t == "" || substr("memokit.json", 13 - length(t)) == t) { if (sw) f = 1 } else { f = 2; exit } }
          next }
        if ("settings.json" ~ re || "settings.local.json" ~ re) {
          if ("memokit.json" ~ re) { if (sw) f = 1 } else { f = 2; exit } } }
      END { exit (f == 2 ? 0 : (f == 1 ? 3 : 1)) }'
    # 0: a word naming settings (a hit); 3: a glob that also matches
    # memokit.json (its message yields to the config gate's); 1: none;
    # anything else (an awk that failed) is a reference (fail closed).
    case $? in 0) hit=1 ;; 1) ;; *) bnd=1 ;; esac
    # A computed name that can end in .json directly in a settings
    # directory: the word's directory part, mapped (_mk_gs_set_map), is one
    # of them. Folded against the cwd and each cd target it is compared as
    # spelled (lower-cased); joined to them unfolded it is resolved by
    # _mk_gs_dir_phys (physical spelling, device:inode: a symlinked
    # directory, a .. after a link), and so is the folded form of a part
    # holding .. (a directory the command makes first: mkdir nope && cp x
    # nope/../link/$F.json); a .. after a directory not on disk is a hit
    # (=n). A directory part that still holds an
    # expansion or a glob is not resolved; one that does not exist is no
    # hit, unless the command may make a symlink (_mk_gs_makes_link: a link
    # made by the command itself is not on disk yet; fail closed). More
    # than MK_GS_MAX_PATHS distinct directories: too large (2). Under
    # <root>/.claude it may be memokit.json too (yields to the config gate).
    if [ "$hit" = 0 ]; then
      # shellcheck disable=SC2016  # awk program, not an expansion
      raw="$(printf '%s\n' "$cw" | _mk_gs_set_map | LC_ALL=C awk '
        { w = $0; n = split(w, p, "/"); x = tolower(p[n])
          gsub(/\$\{[^}]*\}/, "*", x); gsub(/\$[a-z0-9_]+/, "*", x); gsub(/[$`(){}]/, "*", x)
          t = x; sub(/^.*[]*?]/, "", t)
          if (!(t ~ /\.json$/ || substr(".json", 6 - length(t)) == t)) next
          if (n == 1) d = "."; else { d = substr(w, 1, length(w) - length(p[n]) - 1); if (d == "") d = "/" }
          if (d ~ /[$`*?[(){}]/) next
          print d }' | LC_ALL=C sort -u)"
      if [ -n "$raw" ]; then
        dirs="$(printf '%s\n' "$raw" | _mk_gs_fold "$_mk_gs_bases" | LC_ALL=C sort -u |
          LC_ALL=C awk -v m="$MK_GS_MAX_PATHS" 'NR > m { exit 3 } { print }')"
        [ $? = 3 ] && return 2
        jd="$(printf '%s\n' "$raw" | MK_GS_BASES="$_mk_gs_bases" LC_ALL=C awk -v m="$MK_GS_MAX_PATHS" '
          BEGIN { nb = split(ENVIRON["MK_GS_BASES"], b, "\n") }
          function out(x) { if (seen[x]++) return; if (++n > m) exit 3; print x }
          function fold(p,   q, c, i, k, st, o) {
            q = split(p, c, "/"); k = 0
            for (i = 1; i <= q; i++) {
              if (c[i] == "" || c[i] == ".") continue
              if (c[i] == "..") { if (k > 0) k--; continue }
              st[++k] = c[i] }
            o = ""; for (i = 1; i <= k; i++) o = o "/" st[i]
            return (o == "" ? "/" : o) }
          # A joined path holding .. (in the word or in the cd target) is
          # marked with ! (=n, _mk_gs_dir_phys) and also resolved folded:
          # after mkdir nope, nope/../link is link, while the unfolded
          # spelling does not resolve while the hook checks.
          function emit(x) {
            if (x ~ /(^|\/)\.\.(\/|$)/) { out("!" x); out(fold(x)) } else out(x) }
          substr($0, 1, 1) == "/" { emit($0); next }
          { for (j = 1; j <= nb; j++) if (b[j] != "") emit(b[j] "/" $0) }')"
        [ $? = 3 ] && return 2
        f="$(_mk_gs_dir_phys "$jd" "$_MK_GS_SDIR_PD" ${_MK_GS_SDIR_UA[@]+"${_MK_GS_SDIR_UA[@]}"})"
        dirs="$(printf '%s\n%s\n' "$dirs" "$f" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
        # =n (a .. after a directory not on disk) is a reference: it denies,
        # with the config gate's message when that gate also hits.
        if printf '%s\n' "$f" | LC_ALL=C grep -qxF '=u'; then hit=1
        elif [ -n "$_MK_GS_SDIR_U" ] && printf '%s\n' "$dirs" | LC_ALL=C grep -qxF -e "$_MK_GS_SDIR_U"; then hit=1
        elif printf '%s\n' "$f" | LC_ALL=C grep -qxF '=x' && _mk_gs_makes_link "$view"; then hit=1
        elif printf '%s\n' "$dirs" | LC_ALL=C grep -qxF -e "$_MK_GS_SDIR_P" -e '=p' -e '=n'; then bnd=1; fi
      fi
    fi
  fi
  if [ "$hit" = 0 ] && [ "$bnd" = 0 ]; then
    set --
    while IFS= read -r f; do
      [ -n "$f" ] && [ -e "$f" ] && set -- "$@" "$f"
    done <<EOF
$_MK_GS_SET_FILES
EOF
    if [ $# -gt 0 ]; then
      # A word holding .. is also read folded (mkdir nope && cp x
      # nope/../link/settings.json: nope is not on disk while the hook
      # checks, so only the folded spelling reaches the file).
      ew="$({ printf '%s\n' "$words"; printf '%s\n' "$words" | LC_ALL=C tr ',' '\n'; } | LC_ALL=C sort -u | _mk_gs_set_map)"
      { printf '%s\n' "$ew"
        printf '%s\n' "$ew" | LC_ALL=C grep -E '(^|/)\.\.(/|$)' | LC_ALL=C grep -v '[$`*?[]' | _mk_gs_fold "$_mk_gs_bases"
      } | _mk_gs_ef_any "$@"
      rc=$?
      [ "$rc" = 2 ] && return 2
      [ "$rc" = 0 ] && hit=1
    fi
  fi
  if [ "$hit" = 1 ]; then
    _mk_gs_ro "$view" && return 1
    return 0
  fi
  if [ "$bnd" = 1 ]; then
    _mk_gs_ro "$view" && return 1
    return 3
  fi
  return 1
}
# _mk_gs_cfg_hit VIEW -- 0: VIEW references the project config (or
# <root>/.claude) outside the read-only allowlist; 1: it does not; 2: it is
# too large to check (the bounds above).
_mk_gs_cfg_hit() {
  local view="$1" lview seg w a n ref=0 cand=0 hascl=0 hasup=0 up
  local re_a re_b re_c re_d re_f re_o re_g re_u upw="" altlist="" cnt
  local cwdl
  [ "${#view}" -le "$MK_GS_MAX_CHARS" ] || return 2
  # Counts of the costly word classes (words split as the brace loop splits
  # them, before de-duplication; one awk, and an awk that fails counts as
  # too large).
  cnt="$(printf '%s\n' "$view" | LC_ALL=C awk -v m="$MK_GS_MAX_SPECIAL" '
    { gsub(/["\047\\]/, ""); k = split($0, w, /[;|&<>[:space:]]+/)
      for (i = 1; i <= k; i++) {
        if (index(w[i], "..")) u++
        if (w[i] ~ /[$`]/) d++
        if (w[i] ~ /\{[^{}]*(,|\.\.)[^{}]*\}/) b++ } }
    END { print ((u > m || d > m || b > m) ? "big" : "ok") }')"
  [ "$cnt" = ok ] || return 2
  # One lower-cased copy (ASCII only: LC_ALL=C, so no locale maps I to a
  # dotless i), and the lower-cased cwd for folding lower-cased words.
  lview="$(printf '%s' "$view" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  cwdl="$(printf '%s' "$_MK_GS_CWD" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  # Removal of the config's directory or an ancestor (rm/mv/rsync with the
  # project root, $CLAUDE_PROJECT_DIR, or rm/rsync with . or .. or a path
  # that climbs to the root or above) switches every hook off. Quotes are
  # dropped from the whole text first (as they were per word); segments are
  # de-duplicated; the .. arguments of rm/rsync are folded together after
  # the loop.
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    # shellcheck disable=SC2086  # intentional word splitting
    set -- $seg
    while [ $# -gt 0 ]; do
      case "$1" in *=*|'{'|'('|'!'|then|do|else|sudo|command|nohup|time|xargs) shift ;; *) break ;; esac
    done
    case "${1:-}" in
      rm|mv|rsync)
        w="$1"
        for a in "$@"; do
          case "$a" in
            "$MK_ROOT"|"$MK_ROOT/") return 0 ;;
            "\$CLAUDE_PROJECT_DIR"|"\$CLAUDE_PROJECT_DIR/"|"\${CLAUDE_PROJECT_DIR}"|"\${CLAUDE_PROJECT_DIR}/") return 0 ;;
            .|./|..|../) [ "$w" = mv ] || return 0 ;;
          esac
          case "/$a/" in
            */../*)
              case "$a" in *'$'*|*'`'*) continue ;; esac
              [ "$w" = mv ] && continue
              upw="$upw$a
" ;;
          esac
        done ;;
    esac
  done <<EOF
$(printf '%s' "$view" | LC_ALL=C tr -d "\"'" | LC_ALL=C tr ';|&()' '\n' | LC_ALL=C sort -u)
EOF
  if [ -n "$upw" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ "$n" = / ] && return 0
      case "$MK_ROOT/" in "$n/"*) return 0 ;; esac
    done <<EOF
$(printf '%s' "$upw" | _mk_gs_fold "$_MK_GS_CWD")
EOF
  fi
  # A config reference is a WORD (split on quotes, separators and =; a glued
  # short option such as -C.claude counts) that is the directory itself
  # (.claude, or a path ending in /.claude), the config (memokit.json, any
  # case), a name starting .claude/memokit with no further slash (also
  # globs), a glob directly under .claude, a .claude path that climbs with
  # /.., a glob in a dot component (.c*, .*), or a literal path that lands on
  # one of those once its .. components are folded against the cwd.
  # A FULLY LITERAL path below .claude/<sub>/ (a worktree lane) is ordinary.
  re_a='(^|/|^-[[:alnum:]]+)\.claude/?$'
  re_b='(^|/|^-[[:alnum:]]+)memokit\.json$'
  re_c='\.claude/memokit[^/]*$'
  re_d='\.claude.*/\.\.(/|$)'
  re_f='\.claude/[^/]*[*?[][^/]*$'
  re_o='\.claude/[^/]+/'
  re_g='(^|/)\.[^/]*[*?[]'
  re_u='(^|/)\.\.(/|$)'
  # A word holding a brace expansion is NON-LITERAL, like one holding $: each
  # alternative is judged; naming .claude makes a reference, naming memokit
  # denies, a .. component climbs. Alternatives are expanded in the word's
  # own case (they are also tested by device:inode below, p17) and judged
  # lower-cased; the .. ones are folded together after the loop.
  upw=""
  _mk_gs_alts "$view" || ref=1
  altlist="$_MK_GS_ALTLIST"
  if [ -n "$altlist" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      case "$a" in *memokit*) return 0 ;; *.claude*) ref=1 ;; esac
      if [[ "$a" =~ $re_a ]] || [[ "$a" =~ $re_f ]] || [[ "$a" =~ $re_g ]]; then ref=1; fi
      if [[ "$a" =~ $re_u ]]; then
        hasup=1
        [ "$_MK_GS_INCL" = 1 ] && ref=1
        case "$a" in *'$'*|*'`'*) ;; *) upw="$upw$a
" ;; esac
      fi
    done <<EOF
$(printf '%s' "$altlist" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u)
EOF
  fi
  # The literal words with a .. component (brace alternatives above and the
  # words of the next loop), folded against the lower-cased cwd at once.
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [[ "$w" =~ $re_u ]] || continue
    case "$w" in *'$'*|*'`'*) ;; *) upw="$upw$w
" ;; esac
  done <<EOF
$(printf '%s' "$lview" | LC_ALL=C tr "\"'\`;|&(){}<>=[:space:]" '\n' | LC_ALL=C grep -F '..' | LC_ALL=C sort -u)
EOF
  if [ -n "$upw" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if [[ "$n" =~ $re_a ]] || [[ "$n" =~ $re_b ]] || [[ "$n" =~ $re_c ]] \
        || [[ "$n" =~ $re_f ]]; then ref=1; break; fi
    done <<EOF
$(printf '%s' "$upw" | _mk_gs_fold "$cwdl" | LC_ALL=C sort -u)
EOF
  fi
  # Every test below needs .claude, memokit.json, a .. or a dot before a glob
  # character in the word: only such words are read.
  [ "$ref" = 0 ] && while IFS= read -r w; do
    [ -n "$w" ] || continue
    if [[ "$w" =~ $re_a ]] || [[ "$w" =~ $re_b ]] || [[ "$w" =~ $re_c ]] \
      || [[ "$w" =~ $re_d ]] || [[ "$w" =~ $re_f ]] || [[ "$w" =~ $re_g ]]; then ref=1; break; fi
    up=0
    [[ "$w" =~ $re_u ]] && { up=1; hasup=1; }
    case "$w" in *.claude*) hascl=1 ;; esac
    case "$w" in
      *.claude*|*memokit.json*) [[ "$w" =~ $re_o ]] || cand=1 ;;
    esac
    # Inside a lane (cwd under <root>/.claude) a climb may reach the config.
    [ "$_MK_GS_INCL" = 1 ] && [ "$up" = 1 ] && { ref=1; break; }
  done <<EOF
$(printf '%s' "$lview" | LC_ALL=C tr "\"'\`;|&(){}<>=[:space:]" '\n' | LC_ALL=C grep -E '\.claude|memokit\.json|\.\.|\.[^/]*[*?[]' | LC_ALL=C sort -u)
EOF
  # A climb split across words: a .claude word and a separate .. word.
  [ "$hascl" = 1 ] && [ "$hasup" = 1 ] && ref=1
  # Coarse words keep expansions whole (quotes dropped, split on whitespace
  # and separators). A .claude word is lane-exempt only when FULLY LITERAL: an
  # expansion, a glob or a .. component makes it a config reference. An
  # expansion in a word that also names .claude or memokit denies (a bare
  # "claude", as in a scratchpad path, does not). An expansion word that
  # climbs with .. and globs is a reference too; in a lane, so is any glob
  # holding an expansion. (Read lower-cased: every test below is on special
  # characters or on lower-case names.)
  if [ "$ref" = 0 ]; then
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      # A ) before .claude closes a command substitution that held a space.
      case "$w" in *')'*.claude*) ref=1; break ;; *')'*) ;; *.claude*) ref=1; break ;; esac
      case "$w" in *'$'*|*'`'*) ;; *) continue ;; esac
      case "$w" in *memokit*) return 0 ;; esac
      case "$w" in
        *'*'*|*'?'*|*'['*)
          [ "$_MK_GS_INCL" = 1 ] && { ref=1; break; }
          [[ "$w" =~ $re_u ]] && { ref=1; break; } ;;
      esac
    done <<EOF
$(printf '%s' "$lview" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr ';|&<>[:space:]' '\n' | LC_ALL=C grep -E '[$`*?[)]|\.\.' | LC_ALL=C sort -u)
EOF
  fi
  # A literal word that IS the config or <root>/.claude by device:inode (a
  # lane symlink or hard link) is a reference; relative words resolve against
  # the cwd and each literal cd/pushd target.
  if [ "$ref" = 0 ]; then
    # cd/pushd targets (_mk_gs_cd_bases).
    _mk_gs_cd_bases "$view" || ref=1
    if [ "$ref" = 0 ]; then
      { printf '%s' "$view" | LC_ALL=C tr -d "\"'" | LC_ALL=C tr "\`;|&(){}<>=[:space:]" '\n' | LC_ALL=C sort -u
        printf '%s' "$altlist"; } | _mk_gs_ef_any "$MK_ROOT/.claude/memokit.json" "$MK_ROOT/.claude"
      case $? in 0) ref=1 ;; 2) return 2 ;; esac
    fi
  fi
  if [ "$ref" = 0 ]; then
    # A word that names .claude or the config next to an expansion (d=.claude;
    # cd $d) is a reference too.
    # shellcheck disable=SC2016  # regex, not an expansion
    [ "$cand" = 1 ] && printf '%s' "$view" | LC_ALL=C grep -qE '[$`]' 2>/dev/null && return 0
    return 1
  fi
  # Allowlist: only plain read commands, no redirection, no expansion.
  if _mk_gs_ro "$view"; then return 1; fi
  return 0
}
# _MK_GS_PLUG_AWK -- awk program over lines of paths, testing each against
# the roots (lower-cased spellings, one per line, at or below one, any case;
# folded first: empty and . components dropped, .. pops) of ENVIRON
# MK_GS_ROOTN (never exempt) and MK_GS_ROOTX (exempt when the path, as
# spelled, lies in the project: at or below a spelling of ENVIRON
# MK_GS_PROJ, case-exact; _mk_gs_plug_deny):
# - mode "lex": a relative line is joined to every base of ENVIRON
#   MK_GS_BASES (an absolute one stands alone); exits 4 on a hit (a word
#   holding $, a backtick, a glob, a paren or a brace is never exempt: its
#   target is unknown; nor is one spelling CLAUDE_PLUGIN_ROOT); prints every
#   joined LITERAL path, unfolded, plus its folded form when it holds ..;
#   exits 3 past m of them.
# - mode "dirs": prints the directory part of each line.
# - mode "phys": a line PATH<TAB>PHYS (_mk_gs_plug_phys) records PHYS for
#   PATH and is tested; any other line is a path, tested as the PHYS of its
#   directory part joined to its last component. Exits 4 on a hit, 3 on a
#   =big line (too many links to follow) and 4 on a =hit line.
# shellcheck disable=SC2016  # awk program, not an expansion
_MK_GS_PLUG_AWK='
  BEGIN { nb = split(ENVIRON["MK_GS_BASES"], b, "\n"); nn = split(ENVIRON["MK_GS_ROOTN"], rn, "\n")
    nx = split(ENVIRON["MK_GS_ROOTX"], rx, "\n"); np = split(ENVIRON["MK_GS_PROJ"], px, "\n") }
  function fold(p,   q, c, i, k, st, o) {
    if (substr(p, 1, 1) == "/" && p !~ /\/\/|\/\.\.?(\/|$)|.\/$/) return p
    q = split(p, c, "/"); k = 0
    for (i = 1; i <= q; i++) {
      if (c[i] == "" || c[i] == ".") continue
      if (c[i] == "..") { if (k > 0) k--; continue }
      st[++k] = c[i] }
    o = ""; for (i = 1; i <= k; i++) o = o "/" st[i]
    return (o == "" ? "/" : o) }
  function at(x, y) { return (x == y || index(x, y "/") == 1) }
  function under(p, strict,   i, j, f, l, ok) {
    f = fold(p); l = tolower(f)
    for (i = 1; i <= nn; i++) if (rn[i] != "" && at(l, rn[i])) return 1
    for (i = 1; i <= nx; i++) {
      if (rx[i] == "" || !at(l, rx[i])) continue
      if (strict) return 1
      ok = 0
      for (j = 1; j <= np; j++) if (px[j] != "" && at(f, px[j])) { ok = 1; break }
      if (!ok) return 1 }
    return 0 }
  function dir(p) { sub(/\/+$/, "", p); sub(/\/[^\/]*$/, "", p); return (p == "" ? "/" : p) }
  function out(x) { if (seen[x]++) return; if (++n > m) exit 3; print x }
  function one(p,   s) {
    s = (p ~ /[$`*?[(){}]/)
    if (index(tolower(p), "claude_plugin_root") || under(p, s)) exit 4
    if (s) return
    out(p); if (p ~ /(^|\/)\.\.(\/|$)/) out(fold(p)) }
  $0 == "" { next }
  mode == "dirs" { d = dir($0); if (!seen[d]++) print d; next }
  mode == "phys" {
    if ($0 == "=big") exit 3
    if ($0 == "=hit") exit 4
    t = index($0, "\t")
    if (t) { ph[substr($0, 1, t - 1)] = substr($0, t + 1); if (under(substr($0, t + 1), 0)) exit 4; next }
    q = $0; sub(/\/+$/, "", q); d = dir(q)
    if (d in ph && ph[d] != d && under(ph[d] "/" substr(q, length(d) + 1), 0)) exit 4
    next }
  substr($0, 1, 1) == "/" { one($0); next }
  { for (j = 1; j <= nb; j++) if (b[j] != "") one(b[j] "/" $0) }'
# MK_GS_MAX_LINKS -- readlink calls the Bash plugin gate may make for one
# command (file symlinks named in it); past it the command is too large.
MK_GS_MAX_LINKS=64
# _mk_gs_plug_phys DIRS PATHS -- both absolute, one per line. Changes
# directory and turns globbing off: run it only in a subshell. Prints
# PATH<TAB>PHYS for each of DIRS, and for each of PATHS that is a symlink
# (builtin test; a plain directory is its parent joined to its name), whose
# link chain is followed first (readlink, at most 10 hops, a relative target
# against the link's own directory; more hops or an unreadable link: =hit;
# past MK_GS_MAX_LINKS readlink calls: =big): PHYS is the path's longest
# existing directory prefix resolved physically (builtin cd -P: a symlinked
# directory, a .. after a link) joined to the rest of the path. No fork and
# no read per line but the readlink of a symlink.
_mk_gs_plug_phys() {
  local o p r l h k=0 n=0 IFS="$_MK_GS_NL" LC_ALL=C
  set -f
  for o in $1 :paths: $2; do
    case "$o" in :paths:) k=1; continue ;; /*) ;; *) continue ;; esac
    p="$o"
    if [ "$k" = 1 ]; then
      [ -L "$o" ] || continue
      h=0
      while [ -L "$p" ]; do
        h=$((h + 1)); n=$((n + 1))
        [ "$n" -le "$MK_GS_MAX_LINKS" ] || { printf '=big\n'; return 0; }
        { [ "$h" -le 10 ] && l="$(readlink "$p" 2>/dev/null)" && [ -n "$l" ]; } || { printf '=hit\n'; return 0; }
        case "$l" in /*) p="$l" ;; *) p="${p%/*}/$l" ;; esac
      done
    fi
    r=""
    until cd -P -- "$p" 2>/dev/null; do
      r="/${p##*/}$r"; p="${p%/*}"; p="${p:-/}"
    done
    printf '%s\t%s%s\n' "$o" "${PWD%/}" "$r"
  done
}
# _mk_gs_plug_hit VIEW -- 0: VIEW does not only read (_mk_gs_ro) and names a
# path at or below a plugin root (_mk_gs_plug_init) that is not exempt; 1:
# it does not; 2: too large to check (more than MK_GS_MAX_PATHS joined
# literal paths or MK_GS_MAX_LINKS readlink calls). Words are split as
# _mk_gs_set_hit splits them (whole and on commas, brace alternatives
# included) and mapped (_mk_gs_set_map); each is judged joined to the cwd
# and every cd target and folded (_MK_GS_PLUG_AWK lex) and, when literal,
# physically (_mk_gs_plug_phys): its directory part resolved and joined to
# its last component, and the path itself, when it is a symlink, by the
# target of its link chain. A hard link named in a command is not followed
# here; the file tools follow it (_mk_gs_plug_hard).
_MK_GS_PLUG_K=""; _MK_GS_PLUG_RC=1
_mk_gs_plug_hit() {
  local view="$1" ws
  _mk_gs_plug_init
  [ "${#_MK_GS_PLUG_DA[@]}" -gt 0 ] || return 1
  _mk_gs_ro "$view" 2>/dev/null && return 1
  # Bounds of both are the settings gate's (it runs first on the same view).
  _mk_gs_alts "$view" || :
  _mk_gs_cd_bases "$view" || :
  # Plus the coarse words that keep an expansion whole (split on blanks,
  # separators, redirections and = only), as _mk_gs_set_hit reads them.
  # shellcheck disable=SC2016  # regex, not an expansion
  ws="$({ printf '%s' "$view" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr "\`;|&()<>=[:space:]" '\n'
    printf '%s' "$view" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr ';|&<>=[:space:]' '\n' | LC_ALL=C grep -E '[$`()]'
    printf '%s' "$_MK_GS_ALTLIST"; } | LC_ALL=C sort -u)"
  # Memoised on the words and the bases: the flat view of a quoted command
  # (quotes dropped above) has the same ones.
  if [ "$ws$_MK_GS_NL$_mk_gs_bases" != "$_MK_GS_PLUG_K" ]; then
    _MK_GS_PLUG_K="$ws$_MK_GS_NL$_mk_gs_bases"
    _mk_gs_plug_words "$ws"; _MK_GS_PLUG_RC=$?
  fi
  return "$_MK_GS_PLUG_RC"
}
# _mk_gs_plug_words WORDS -- _mk_gs_plug_hit's test of its words (0, 1, 2).
_mk_gs_plug_words() {
  local js ds
  js="$({ printf '%s\n' "$1"; printf '%s\n' "$1" | LC_ALL=C grep -F ',' | LC_ALL=C tr ',' '\n'; } |
    _mk_gs_set_map | MK_GS_BASES="$_mk_gs_bases" MK_GS_ROOTN="$_MK_GS_PLUG_LCN" MK_GS_ROOTX="$_MK_GS_PLUG_LCX" \
    MK_GS_PROJ="$_MK_GS_PLUG_PX" LC_ALL=C awk -v mode=lex -v m="$MK_GS_MAX_PATHS" "$_MK_GS_PLUG_AWK")"
  case $? in 0) ;; 3) return 2 ;; *) return 0 ;; esac
  [ -n "$js" ] || return 1
  ds="$(printf '%s\n' "$js" | LC_ALL=C awk -v mode=dirs "$_MK_GS_PLUG_AWK")"
  { _mk_gs_plug_phys "$ds" "$js"; printf '%s\n' "$js"; } |
    MK_GS_ROOTN="$_MK_GS_PLUG_LCN" MK_GS_ROOTX="$_MK_GS_PLUG_LCX" MK_GS_PROJ="$_MK_GS_PLUG_PX" LC_ALL=C \
    awk -v mode=phys "$_MK_GS_PLUG_AWK"
  case $? in 0) return 1 ;; 3) return 2 ;; *) return 0 ;; esac
}
# _mk_gs_cfg_set VIEW FIRST -- the config gate, then the settings gate (its
# bounds are checked first; a settings write is named as such even when the
# config gate also hits, as a $HOME/.claude word does), then the plugin gate.
_mk_gs_cfg_set() {
  local rc src
  _mk_gs_cfg_hit "$1"; rc=$?
  [ "$rc" = 2 ] && deny "$(mk_msg GS_TOO_LARGE "$2")"
  _mk_gs_set_hit "$1"; src=$?
  [ "$src" = 2 ] && deny "$(mk_msg GS_TOO_LARGE "$2")"
  [ "$src" = 0 ] && deny "$(mk_msg GS_SETTINGS_EDIT "$2")"
  [ "$rc" = 0 ] && deny "$(mk_msg GS_CONFIG_EDIT "$2")"
  [ "$src" = 3 ] && deny "$(mk_msg GS_SETTINGS_EDIT "$2")"
  _mk_gs_plug_hit "$1"; src=$?
  [ "$src" = 2 ] && deny "$(mk_msg GS_TOO_LARGE "$2")"
  [ "$src" = 0 ] && deny "$(mk_msg GS_PLUGIN_EDIT "$2")"
  return 0
}
# The flat view undoes quoting (careful.sh); a lib that does not load or a
# view that cannot be made fails closed.
_mk_gs_rule3() {
  local view="$1" first flat out line seg rc
  # The first line, by sed: ${view%%<newline>*} on a 64 KiB view took 0.6 s
  # under a UTF-8 locale (bash 3.2).
  first="$(printf '%s\n' "$view" | sed -n 1p)"
  [ "${#view}" -le "$MK_GS_MAX_CHARS" ] || deny "$(mk_msg GS_TOO_LARGE "$first")"
  if _mk_gs_win_hit "$view"; then deny "$(mk_msg GS_WINDOW_REQUEST "$first")"; fi
  if _mk_gs_ss_hit "$view"; then deny "$(mk_msg GS_SESSION_START "$first")"; fi
  _mk_gs_cfg_set "$view" "$first"
  if ! command -v mk_careful_flat >/dev/null 2>&1 || ! flat="$(mk_careful_flat "$view" 2>/dev/null)"; then
    deny "$(mk_msg GS_WINDOW_REQUEST "$first")"
  fi
  # (A flat view equal to the view was checked just above.)
  if [ "$flat" != "$view" ]; then
    if _mk_gs_win_hit "$flat"; then deny "$(mk_msg GS_WINDOW_REQUEST "$first")"; fi
    if _mk_gs_ss_hit "$flat"; then deny "$(mk_msg GS_SESSION_START "$first")"; fi
    _mk_gs_cfg_set "$flat" "$first"
  fi
  if [ "${MK_REMOTE_ENABLED:-0}" = 1 ]; then
    if command -v mk_remote_scan >/dev/null 2>&1; then
      MK_REMOTE_NO_EXEMPT=1
      if out="$(mk_remote_scan "$view" 2>/dev/null)"; then
        line="${out%%$'\n'*}"
        seg="${line#*$'\t'}"; seg="${seg#*$'\t'}"
        case "$line" in unparsed*) seg="" ;; esac
        [ -n "$out" ] && deny "$(mk_msg GS_REMOTE "${seg:-$first}")"
      else
        deny "$(mk_msg GS_REMOTE "$first")"
      fi
    else
      deny "$(mk_msg GS_REMOTE "$first")"
    fi
  fi
}
# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$MK_LIB_DIR/careful.sh" 2>/dev/null
if [ "${MK_REMOTE_ENABLED:-0}" = 1 ]; then
  # shellcheck source-path=SCRIPTDIR source=lib/remote.sh
  . "$MK_LIB_DIR/remote.sh" 2>/dev/null
fi
_mk_gs_rule3 "$CMD_ORIG"
[ "$CMD" = "$CMD_ORIG" ] || _mk_gs_rule3 "$CMD"

# Split into segments on shell separators so `foo && git commit` is inspected
# as its own command, not as an argument to foo. `(`, `)`, `{`, `}` and a
# backtick are ALSO separators here -- not because they terminate a command
# the way `;`/`|`/`&` do, but because splitting on them has the same net
# effect for detection purposes: `( git commit -m x )`, `{ git commit -m x;
# }`, and `` `git commit -m x` `` all reduce to a segment whose first word is
# `git`, with no extra handling needed. `$(...)` is covered too, since its
# `(` and `)` are among the same separator characters (`echo $(git commit -m
# x)` splits into "echo $" and "git commit -m x"). Measured before this fix:
# 7 of 8 phrasings of `git commit -m x` walked straight through denying only
# the bare form -- `( ... )`, `{ ...; }`, `$(...)`, backticks, `if/then`,
# `bash -c`, and `xargs` all allowed. All 8 are covered now (the `bash -c`
# and `xargs` forms need the extra handling above/below, not just the wider
# separator set).
#
# This remains deliberately coarse: it is a guard against the INSTINCTIVE
# violation, not a sandbox. An agent that actively WANTS to evade it --
# invoking git through a variable, a wrapper script, an alias, or an
# interpreter this scan does not special-case -- still can. The point is
# that the accidental "I'll just finish the job" commit is stopped, not that
# every possible indirection is closed.
# shellcheck disable=SC2020  # intentional: each of \n;|&(){}` is meant to
# map to a newline individually (a set-to-set translation), not as a
# multi-char "word" -- the duplicate targets are the point, not a mistake.
SEGMENTS="$(printf '%s' "$CMD" | tr '\n;|&(){}`' '\n\n\n\n\n\n\n\n\n')"
_MK_GS_CWC=""  # glob command words already decided (word<TAB>git|gh|empty)

while IFS= read -r SEG; do
  [ -z "$SEG" ] && continue
  # Intentional word splitting to tokenize. This is a heuristic,
  # whitespace-only split, not a real shell parser -- a quoted argument
  # containing a space is mis-tokenized. Accepted gap: under-detection here
  # means a missed deny, never a false deny.
  # shellcheck disable=SC2086
  set -- $SEG
  # `git` must be the COMMAND of this segment, not merely a word inside it --
  # otherwise `echo git commit is a phrase` would be denied (measured: it
  # was, before the COMMAND-position check existed). Skip leading VAR=val
  # assignments, the usual wrapper prefixes, `xargs` (so `echo x | xargs git
  # commit -m` is caught -- measured before this fix: it was not), and a
  # handful of shell keywords that can legitimately precede a command word
  # after the `;`/`(`/`{` split above (`if true; then git commit -m x; fi`
  # splits into a segment starting with `then`, which must be skipped past
  # to reach `git`; measured before this fix: it was not caught).
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;                                  # VAR=val prefix
      env)
        # `env` takes its own options before the command (`env -i git
        # commit`, `env -u HOME git commit`): consume them, including the
        # separate value of the ones that take one, so the command word
        # after them is still found. Accepted gap: `env -S 'git commit'`
        # packs the command into one quoted argument, which this
        # whitespace tokenizer cannot see into (under-detection only).
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|-C|-P|-S|--unset|--chdir|--split-string) shift 2 2>/dev/null || shift $# ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        ;;
      sudo|nohup|time|command|builtin|xargs) shift ;;  # wrapper prefixes
      then|do|else|elif|'{'|'('|'!') shift ;;         # shell keywords
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && continue
  # set -f: a glob command word (/usr/bin/g?t) whose last component can match
  # git or gh (a case pattern test, no fork) is judged as git or gh when
  # DIR/git or DIR/gh exists (_mk_gs_glob1 on that path only, relative to the
  # cwd and each cd target; more than MK_GS_MAX_GLOB matches: too large);
  # otherwise literally. Case arms (*), *.json)) split into such words, so
  # each distinct word is decided once (_MK_GS_CWC).
  case "$1" in
    *'*'*|*'?'*|*'['*)
      _mk_gs_cw=""
      case "$_MK_GS_CWC" in
        *"$_MK_GS_NL$1	"*) _mk_gs_cw="${_MK_GS_CWC#*"$_MK_GS_NL$1	"}"; _mk_gs_cw="${_mk_gs_cw%%"$_MK_GS_NL"*}" ;;
        *)
          _mk_gs_l="${1##*/}"; _mk_gs_d=""
          case "$1" in */*) _mk_gs_d="${1%/*}/" ;; esac
          for _mk_gs_m in gh git; do
            # shellcheck disable=SC2254  # the word is a pattern on purpose
            case "$_mk_gs_m" in $_mk_gs_l) ;; *) continue ;; esac
            _mk_gs_cd_bases "$CMD" || :
            _mk_gs_glob1 "$_mk_gs_d$_mk_gs_m" "$_mk_gs_bases" || deny "$(mk_msg GS_TOO_LARGE "$SEG")"
            [ -n "$_MK_GS_GLOB" ] && _mk_gs_cw="$_mk_gs_m"
          done
          _MK_GS_CWC="$_MK_GS_CWC$_MK_GS_NL$1	$_mk_gs_cw" ;;
      esac
      if [ -n "$_mk_gs_cw" ]; then shift; set -- "$_mk_gs_cw" "$@"; fi ;;
  esac
  case "$1" in
    git|*/git) shift ;;   # consume `git` itself
    gh|*/gh)
      # GitHub CLI: merging a pull request merges on the remote -- the same
      # authority as `git merge` + `git push`, which a subagent does not
      # have. Read-only forms (`gh pr view`, `gh pr diff`, ...) stay allowed.
      if [ $# -ge 3 ] && [ "$2" = "pr" ] && [ "$3" = "merge" ]; then
        deny "$(mk_msg GS_GH_PR_MERGE "$SEG")"
      fi
      continue
      ;;
    *) continue ;;        # this segment does not run git -- nothing to check
  esac

  # Skip git's global options so `git -C /repo commit` is caught too. The
  # option forms that take a SEPARATE argument (-C dir, -c key=val, and the
  # separated spellings --git-dir <dir>, --work-tree <dir>, --namespace
  # <name>, --config-env <name>=<env>) must consume that argument as well,
  # or the value would be mistaken for the subcommand.
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env) shift 2 2>/dev/null || shift $# ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-p|--paginate|--no-pager|--bare) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && continue

  SUBCMD="$1"; shift
  case "$SUBCMD" in
    commit)
      # --dry-run / --short / --porcelain are read-only PREVIEWS of what
      # WOULD be committed -- they create no commit. Whitelisted so a
      # subagent can legitimately inspect its own staged changes before
      # reporting back. Any other form of `commit` is still denied.
      case " $* " in
        *' --dry-run '*|*' --short '*|*' --porcelain '*) continue ;;
      esac
      deny "$(mk_msg GS_COMMIT "$SEG")"
      ;;
    merge)
      deny "$(mk_msg GS_MERGE "$SEG")"
      ;;
    push)
      # No read-only form of push exists -- it always mutates the remote.
      # `git push origin --delete feat` deletes a REMOTE branch, strictly
      # worse than the local `branch -d` already blocked below -- measured
      # before this fix: unrestricted (both plain push and --delete allowed).
      deny "$(mk_msg GS_PUSH "$SEG")"
      ;;
    rebase)
      deny "$(mk_msg GS_REBASE "$SEG")"
      ;;
    revert)
      # Creates a new commit (or leaves a half-applied revert in progress).
      deny "$(mk_msg GS_REVERT "$SEG")"
      ;;
    pull)
      # fetch + merge/rebase into the current branch: can create merge
      # commits or rewrite local history, in every form.
      deny "$(mk_msg GS_PULL "$SEG")"
      ;;
    am)
      # Applies a mailbox of patches as commits.
      deny "$(mk_msg GS_AM "$SEG")"
      ;;
    filter-branch)
      deny "$(mk_msg GS_FILTER_BRANCH "$SEG")"
      ;;
    commit-tree)
      # Plumbing that creates a commit object (the building block of a
      # hand-rolled commit together with update-ref).
      deny "$(mk_msg GS_COMMIT_TREE "$SEG")"
      ;;
    reset)
      # memokit:coder's own rule bans `git reset` outright (not just --hard),
      # so this hook is made to match that claim exactly rather than trying
      # to carve out a "soft reset is harmless" exception it does not grant.
      deny "$(mk_msg GS_RESET "$SEG")"
      ;;
    checkout|switch)
      # A subagent switching to (or creating) ANOTHER branch is the exact
      # violation memokit:coder bans ("checkout <other-branch>"). Restoring a
      # FILE from the index/another ref via the `--` end-of-options marker
      # (`git checkout -- path`, `git checkout HEAD~1 -- path`) does not
      # change what branch HEAD points at, so it is allowed -- a local,
      # reversible, single-file operation a coding agent legitimately needs
      # (e.g. to back out its own failed experiment on one file). Measured
      # before this fix: `git checkout other-branch` was allowed outright.
      HAS_DASHDASH=0
      for ARG in "$@"; do
        [ "$ARG" = "--" ] && HAS_DASHDASH=1
      done
      if [ "$HAS_DASHDASH" -eq 1 ] || [ $# -eq 0 ]; then
        continue
      fi
      deny "$(mk_msg GS_BRANCH_SWITCH "$SEG")"
      ;;
    stash)
      # Stash is destructive to parallel subagent work: a second agent's
      # `stash pop` can clobber or hide a first agent's uncommitted changes.
      # Denied in every form (push, pop, apply, drop, list, ...), not just
      # the mutating ones, since a subagent has no legitimate need to touch
      # stash at all. Measured before this fix: allowed outright.
      deny "$(mk_msg GS_STASH "$SEG")"
      ;;
    cherry-pick)
      deny "$(mk_msg GS_CHERRY_PICK "$SEG")"
      ;;
    clean)
      deny "$(mk_msg GS_CLEAN "$SEG")"
      ;;
    tag)
      # Only deletion is blocked; `git tag` (list) and `git tag <name>`
      # (create) are harmless and denying them would break ordinary use.
      for ARG in "$@"; do
        case "$ARG" in
          -d|-D|--delete|--delete=*)
            deny "$(mk_msg GS_TAG_DELETE "$SEG")"
            ;;
        esac
      done
      ;;
    update-ref)
      # Only deletion (-d) is blocked; creating/updating a ref is out of
      # scope for this rule (it is not history rewriting or destruction).
      for ARG in "$@"; do
        case "$ARG" in
          -d) deny "$(mk_msg GS_REF_DELETE "$SEG")" ;;
        esac
      done
      ;;
    worktree)
      # Only `remove` is blocked; `worktree list`/`add` are not destructive.
      if [ $# -gt 0 ] && [ "$1" = "remove" ]; then
        deny "$(mk_msg GS_WORKTREE_REMOVE "$SEG")"
      fi
      ;;
    branch)
      # Deletion, force-moving (-f/--force: `git branch -f main HEAD~3`
      # rewinds main) and renaming (-m/-M/--move) are blocked; `git branch`
      # (list), `git branch -a` and `git branch <name>` are harmless
      # reads/creates, and denying them would break ordinary inspection.
      for ARG in "$@"; do
        case "$ARG" in
          -d|-D|--delete|--delete=*|-dr|-Dr)
            deny "$(mk_msg GS_BRANCH_DELETE "$SEG")"
            ;;
          -f|--force|-m|-M|--move)
            deny "$(mk_msg GS_BRANCH_FORCE "$SEG")"
            ;;
        esac
      done
      ;;
  esac
done <<EOF
$SEGMENTS
EOF

exit 0
