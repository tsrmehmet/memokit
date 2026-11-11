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
  _gs_jq_deny "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")"
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

# --- Rule 2: no commit / merge / branch deletion / history rewrite / remote
#     mutation / stash. --------------------------------------------------------
# --- Rule 2a: no edit of the project config (the remote block lives there). ---
# The path is normalised first; naming <root>/.claude or its memokit.json
# denies. Symlink chains are followed (max 10 hops, as guard-destructive.sh
# does for the grant file); any hop naming memokit.json, or a link that cannot
# be resolved, denies. Other paths are untouched.
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    FPATH="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // empty)' 2>/dev/null)" || \
      deny "$(mk_msg GS_CMD_EXTRACT_FAILED)"
    [ -n "$FPATH" ] || exit 0
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
# Is the payload cwd physically under <root>/.claude (a worktree lane)?
_MK_GS_INCL=0
_MK_GS_PROOT="$(cd -P "$MK_ROOT" 2>/dev/null && pwd -P)" || _MK_GS_PROOT="$MK_ROOT"
if _mk_gs_pcwd="$(cd -P "$_MK_GS_CWD" 2>/dev/null && pwd -P)"; then
  case "$_mk_gs_pcwd/" in "$_MK_GS_PROOT/.claude/"*) _MK_GS_INCL=1 ;; esac
fi
# A word naming the config or <root>/.claude by device:inode (a symlink or a
# hard link of either). Relative words resolve against the payload cwd and
# every literal cd target. `test -ef` is a builtin: no fork per word.
_mk_gs_ef() {
  local w="$1" b
  case "$w" in
    /*) [ "$w" -ef "$MK_ROOT/.claude/memokit.json" ] || [ "$w" -ef "$MK_ROOT/.claude" ]; return ;;
  esac
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$b/$w" -ef "$MK_ROOT/.claude/memokit.json" ] && return 0
    [ "$b/$w" -ef "$MK_ROOT/.claude" ] && return 0
  done <<EOF
$_mk_gs_bases
EOF
  return 1
}
# _mk_gs_ef_any -- stdin: words, one per line; 0 when a literal one (no $,
# backtick or glob character; a glued short option -Xpath also as path)
# names the config or <root>/.claude by device:inode, as _mk_gs_ef does per
# word. 0.8.0 final wave: one awk builds every path (each relative word
# against every base in _mk_gs_bases) and ONE xargs stat reads them all; the
# per-word loop took 4 s for 9 000 words and 9 cd targets. When the two ids
# cannot be read (no stat), the per-word builtin loop runs instead.
_mk_gs_ef_any() {
  local fmt ids w n paths
  if stat -L -c %d:%i / >/dev/null 2>&1; then fmt="-c"; else fmt="-f"; fi
  ids="$(stat -L "$fmt" %d:%i "$MK_ROOT/.claude/memokit.json" "$MK_ROOT/.claude" 2>/dev/null)" || ids=""
  case "$ids" in
    *:*"$_MK_GS_NL"*:*) ;;
    *)
      while IFS= read -r w; do
        [ -n "$w" ] || continue
        case "$w" in *'$'*|*'`'*|*'*'*|*'?'*|*'['*) continue ;; esac
        n=""
        case "$w" in -[!-]?*) n="${w#-?}" ;; esac
        if _mk_gs_ef "$w" || { [ -n "$n" ] && _mk_gs_ef "$n"; }; then return 0; fi
      done
      return 1 ;;
  esac
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
    grep -qxF -e "${ids%%"$_MK_GS_NL"*}" -e "${ids#*"$_MK_GS_NL"}"
}
_MK_GS_NL='
'
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
# _mk_gs_fold BASE -- stdin: one path per line; stdout: each joined to BASE
# when relative and folded lexically (empty and . components dropped, ..
# folds its parent), as _mk_gs_abs does for one path; one awk, linear.
_mk_gs_fold() {
  MK_GS_FOLD_BASE="$1" LC_ALL=C awk '
    BEGIN { b = ENVIRON["MK_GS_FOLD_BASE"] }
    { p = $0; if (substr(p, 1, 1) != "/") p = b "/" p
      n = split(p, c, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (c[i] == "" || c[i] == ".") continue
        if (c[i] == "..") { if (k > 0) k--; continue }
        st[++k] = c[i] }
      o = ""; for (i = 1; i <= k; i++) o = o "/" st[i]
      print (o == "" ? "/" : o) }'
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
# _mk_gs_cfg_hit VIEW -- 0: VIEW references the project config (or
# <root>/.claude) outside the read-only allowlist; 1: it does not; 2: it is
# too large to check (the bounds above).
_mk_gs_cfg_hit() {
  local view="$1" lview segs seg w a n ref=0 cand=0 hascl=0 hasup=0 up
  local re_a re_b re_c re_d re_f re_o re_g re_u re_x upw="" altlist="" cnt nb=0 talt=0
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
  # shellcheck disable=SC2020  # a set-to-set translation, duplicates intended
  segs="$(printf '%s' "$view" | LC_ALL=C tr '\n;|&(){}' '\n\n\n\n\n\n\n\n')"
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
  re_x='\{[^{}]*(,|\.\.)[^{}]*\}'
  # A word holding a brace expansion is NON-LITERAL, like one holding $: each
  # alternative is judged; naming .claude makes a reference, naming memokit
  # denies, a .. component climbs. Alternatives are expanded in the word's
  # own case (they are also tested by device:inode below, p17) and judged
  # lower-cased; the .. ones are folded together after the loop.
  upw=""
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [[ "$w" =~ $re_x ]] || continue
    if ! _mk_gs_brace "$w"; then ref=1; continue; fi
    talt=$((talt + _MK_GS_NALT))
    [ "$talt" -le "$MK_GS_MAX_ALTS" ] || { ref=1; break; }
    altlist="$altlist$_MK_GS_ALTS"
    # In a lane, a brace glob is an expansion glob.
    [ "$_MK_GS_INCL" = 1 ] && case "$w" in *[*?[]*) ref=1 ;; esac
  done <<EOF
$(printf '%s' "$view" | LC_ALL=C tr -d "\"'\\\\" | LC_ALL=C tr ';|&<>[:space:]' '\n' | LC_ALL=C grep -F '{' | LC_ALL=C sort -u)
EOF
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
    # cd/pushd targets (options -P -L -e -@ -- skipped). In a lane, a target
    # holding an expansion ($, backtick, brace) may climb: a reference.
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
      esac
      [[ "$a" =~ $re_u ]] && [ "$_MK_GS_INCL" = 1 ] && ref=1
      case "$a" in
        *'$'*|*'`'*|*'{'*) [ "$_MK_GS_INCL" = 1 ] && ref=1; continue ;;
        *'*'*|*'?'*|*'['*) continue ;;
        /*) ;;
        *) a="$_MK_GS_CWD/$a" ;;
      esac
      nb=$((nb + 1))
      [ "$nb" -le "$MK_GS_MAX_BASES" ] || { ref=1; break; }
      _mk_gs_bases="$_mk_gs_bases
$a"
    done <<EOF
$(printf '%s' "$view" | LC_ALL=C tr -d "\"'" | LC_ALL=C tr ';|&' '\n' | LC_ALL=C grep -E '(^|[^[:alnum:]_-])(cd|pushd)([^[:alnum:]_-]|$)' | LC_ALL=C sort -u)
EOF
    if [ "$ref" = 0 ]; then
      { printf '%s' "$view" | LC_ALL=C tr -d "\"'" | LC_ALL=C tr "\`;|&(){}<>=[:space:]" '\n' | LC_ALL=C sort -u
        printf '%s' "$altlist"; } | _mk_gs_ef_any
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
  # shellcheck disable=SC2016  # regex, not an expansion
  printf '%s' "$view" | LC_ALL=C grep -qE '[>$`]' 2>/dev/null && return 0
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    # shellcheck disable=SC2086  # intentional word splitting
    set -- $seg
    while [ $# -gt 0 ]; do case "$1" in *=*) shift ;; *) break ;; esac; done
    case "${1:-}" in
      ''|cat|less|head|tail|jq|grep|diff|wc|ls|stat|file) ;;
      *) return 0 ;;
    esac
  done <<EOF
$(printf '%s' "$segs" | LC_ALL=C sort -u)
EOF
  return 1
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
  _mk_gs_cfg_hit "$view"; rc=$?
  [ "$rc" = 2 ] && deny "$(mk_msg GS_TOO_LARGE "$first")"
  [ "$rc" = 0 ] && deny "$(mk_msg GS_CONFIG_EDIT "$first")"
  if ! command -v mk_careful_flat >/dev/null 2>&1 || ! flat="$(mk_careful_flat "$view" 2>/dev/null)"; then
    deny "$(mk_msg GS_WINDOW_REQUEST "$first")"
  fi
  # (A flat view equal to the view was checked just above.)
  if [ "$flat" != "$view" ]; then
    if _mk_gs_win_hit "$flat"; then deny "$(mk_msg GS_WINDOW_REQUEST "$first")"; fi
    _mk_gs_cfg_hit "$flat"; rc=$?
    [ "$rc" = 2 ] && deny "$(mk_msg GS_TOO_LARGE "$first")"
    [ "$rc" = 0 ] && deny "$(mk_msg GS_CONFIG_EDIT "$first")"
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
