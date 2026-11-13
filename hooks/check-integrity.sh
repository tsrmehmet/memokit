#!/usr/bin/env bash
# PreToolUse (every tool), PostToolUse and PostToolUseFailure (Bash, Edit,
# Write, MultiEdit, NotebookEdit) and SubagentStop hook: the runtime
# integrity check (0.8.1).
#
# The text gates of guard-subagent-authority.sh cannot see a path the shell
# assembles at run time; this hook sees the result instead. For a subagent
# (non-empty agent_id) on Bash/Edit/Write/MultiEdit/NotebookEdit, PreToolUse
# records the protected set (lib/integrity.sh: the settings files,
# memokit.json, the session's config snapshot, memokit's plugin files) keyed
# by session and tool_use_id; PostToolUse(Failure) recomputes and compares.
# The agent's first Pre also keeps a baseline, compared at SubagentStop (a
# change made later by something the agent left running), and an "armed"
# stamp: while it exists a missing record or baseline is a change (one
# deleted through a path built at run time). On a difference nothing is
# restored (report, not restore): the subagent is blocked with a reason
# naming the files by fixed labels (Post; SubagentStop prints nothing), and
# two markers make the orchestrator's next tool call (any tool) deny once
# and the next user prompt carry the same notice once (inject-rules.sh).
# When the only change is rules ADDED to permissions.allow of a settings
# file (a permission prompt answered "Yes, and don't ask again"), each of
# them suggested for that file by a permission prompt shown while this call
# ran (record-permission.sh records PermissionRequest), there is no block
# and no deny, only a prompt notice listing the rules (broad ones in a
# notice of their own that asks the user to confirm them). A change made by
# the main session or another agent meanwhile is reported the same way:
# "changed during a subagent tool call", not "changed by". A digest that
# cannot be computed counts as a change; a missing record of an agent that
# was never armed (hook added mid-session) is no change.
#
# Cost: this hook runs before every tool call. A main-session payload (no
# "agent_id" text), or a subagent's call of another tool, with no alert
# marker of this session in the temp dir ends after bash regex tests and one
# file test: no jq, no library, no fork.
set -u
PAYLOAD="$(cat)"
# The kill switch (mk_guard_off), checked before the library is loaded.
[ "${MEMOKIT_GUARD_OFF:-0}" = "1" ] && exit 0
# Under LC_ALL=C: in a UTF-8 locale bash 3.2's regexec finds no match in a
# text holding an invalid byte anywhere.
_ig_has() { local LC_ALL=C; [[ $PAYLOAD =~ $1 ]]; }
_ig_sid_ok() { local LC_ALL=C re='^[A-Za-z0-9_-]+$'; [[ $1 =~ $re ]]; }
_ig_unreadable() { local LC_ALL=C re=' UNREADABLE'; [[ $1 =~ $re ]]; }
_IG_RE_STOP='"hook_event_name"[[:space:]]*:[[:space:]]*"SubagentStop"'
# A payload that may be a subagent's on one of the five tools, or its
# SubagentStop, goes on; any other (the main session, a subagent's Read or
# Grep) only when this session's alert marker exists. The alert, notice and
# allow markers have a root-independent name, memokit-0-careful-integrity-
# KIND-<sid> (the 0 keeps them inside the memokit-[0-9]*-* prune pattern and
# the careful-state names), so when the session id is a plain word (a UUID;
# first "session_id" key, which Claude Code writes before tool_input) this
# is one test by name: no glob, which on a temp dir of 200 000 entries costs
# a few hundred ms per call. Another session id falls back to a glob.
if ! _ig_has '"agent_id"' ||
   { ! _ig_has '"tool_name"[[:space:]]*:[[:space:]]*"(Bash|Edit|Write|MultiEdit|NotebookEdit)"' && ! _ig_has "$_IG_RE_STOP"; }; then
  _ig_d="${TMPDIR:-/tmp}"; _ig_d="${_ig_d%/}/memokit-0-careful-integrity-alert-"
  if _ig_has '"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,128})"'; then
    set -- "$_ig_d${BASH_REMATCH[1]}"
  else
    set -- "$_ig_d"*
  fi
  [ -e "$1" ] || [ -L "$1" ] || exit 0
fi

# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/budget.sh
. "$MK_LIB_DIR/budget.sh"
# shellcheck source-path=SCRIPTDIR source=lib/integrity.sh
. "$MK_LIB_DIR/integrity.sh"

# Jq-free first reading of the text (a top-level key never sits inside a
# JSON string; the first match is the top-level one, which Claude Code
# writes before tool_input): the event, and the session and agent ids when
# they are plain words. They let a Post or SubagentStop fail closed (the
# markers, _ig_fire) even before jq ran or when jq is gone (M1, M2).
_ig_gev=Pre
if _ig_has '"hook_event_name"[[:space:]]*:[[:space:]]*"Post'; then _ig_gev=Post
elif _ig_has "$_IG_RE_STOP"; then _ig_gev=Stop; fi
_ig_rsid=""; _ig_ragent=""
if _ig_has '"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,128})"'; then _ig_rsid="${BASH_REMATCH[1]}"; fi
if _ig_has '"agent_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]{1,128})"'; then _ig_ragent="${BASH_REMATCH[1]}"; fi

# Hard budget (lib/budget.sh), armed before the first jq, mode "zero": exit 0
# with no output lets the call through, a crash denies (Pre), blocks (Post)
# or stays quiet (SubagentStop); on Post and SubagentStop the static path
# also leaves the markers (_ig_fire).
MK_IG_BUDGET_WALL=3.3
MK_IG_BUDGET_CPU=4
case "$_ig_gev" in
  Post) MK_BUDGET_EVENT=PostToolUse
    mk_budget_arm "$MK_IG_BUDGET_WALL" "$MK_IG_BUDGET_CPU" IG_POST_FAIL_STATIC IG_POST_FAIL_STATIC zero ;;
  Stop) MK_BUDGET_EVENT=Quiet
    mk_budget_arm "$MK_IG_BUDGET_WALL" "$MK_IG_BUDGET_CPU" IG_POST_FAIL_STATIC IG_POST_FAIL_STATIC zero ;;
  *) mk_budget_arm "$MK_IG_BUDGET_WALL" "$MK_IG_BUDGET_CPU" IG_PRE_BUDGET_STATIC IG_PRE_CRASH_STATIC zero ;;
esac

# The payload only serves for its cwd, needed when CLAUDE_PROJECT_DIR is
# unset; without it mk_resolve_root skips the snapshot pick and its jq.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then mk_resolve_root ""; else mk_resolve_root "$PAYLOAD"; fi
[ -n "$MK_ROOT" ] || exit 0
mk_debug_dump "check-integrity" "$PAYLOAD"
# State paths as _mk_session_tmp names them (the snapshot as session-start.sh
# writes it), with fewer forks: mk_tmp's prefix <TMPDIR>/memokit-<cksum of
# MK_ROOT>- (a doubled slash inside TMPDIR is left as is: the same file).
_ig_h="$(printf '%s' "$MK_ROOT" | cksum)"; _ig_h="${_ig_h%% *}"
_ig_p="${TMPDIR:-/tmp}"; _ig_p="${_ig_p%/}/memokit-$_ig_h-"
# The root-independent prefix of the alert, notice and allow markers (as
# inject-rules.sh names them; see the fast path above).
_ig_m="${TMPDIR:-/tmp}"; _ig_m="${_ig_m%/}/memokit-0-careful-integrity-"
# _ig_paths SID AGENT -- the session's state paths; the session id as is
# when short and [A-Za-z0-9_-] (a UUID), else through the same tr as
# _mk_session_tmp. AGENT is sanitised already.
_ig_paths() {
  _ig_s="$1"
  if [ "${#_ig_s}" -gt 128 ] || ! _ig_sid_ok "$_ig_s"; then
    _ig_s="$(printf '%s' "${1:-unknown}" | tr -c 'A-Za-z0-9_-' _)"
  fi
  _IG_SNAP="${_ig_p}careful-config-$_ig_s"
  _IG_ALERT="${_ig_m}alert-$_ig_s"
  _IG_NOTICE="${_ig_m}notice-$_ig_s"
  _IG_ALLOW="${_ig_m}allow-$_ig_s"
  _IG_BROAD="${_ig_m}broad-$_ig_s"
  _IG_PERM="${_ig_p}careful-integrity-perm-$_ig_s"
  _IG_ARMED=""; _IG_BASE=""
  if [ -n "$2" ]; then
    _IG_ARMED="${_ig_p}careful-armed-$_ig_s-$2"
    _IG_BASE="${_ig_p}careful-integrity-base-$_ig_s-$2"
  fi
}
# _ig_ok FILE -- a regular file of ours, not a symlink.
_ig_ok() { [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]; }
# _ig_fire -- the static block (out of time, crash, jq gone) of an armed
# agent: both markers get a "?" line (unknown files). Builtins only
# (lib/budget.sh); a new file is created exclusively (noclobber), an
# existing marker of ours gets the line appended.
# shellcheck disable=SC2317,SC2329  # run by lib/budget.sh (MK_BUDGET_ON_STATIC)
_ig_fire() {
  local f
  [ -n "${_IG_ARMED:-}" ] && _ig_ok "$_IG_ARMED" || return 0
  umask 077
  for f in "$_IG_ALERT" "$_IG_NOTICE"; do
    [ -L "$f" ] && continue
    if [ -e "$f" ]; then
      _ig_ok "$f" && printf '?\n' >> "$f"
    else
      set -C; printf '?\n' 2>/dev/null > "$f"; set +C
    fi
  done
  return 0
}
if [ "$_ig_gev" != Pre ] && [ -n "$_ig_rsid" ] && [ -n "$_ig_ragent" ]; then
  _ig_paths "$_ig_rsid" "$_ig_ragent"
  MK_BUDGET_ON_STATIC=_ig_fire
fi
mk_budget_test_burn

# One jq: event, agent id (sanitised; empty for the main session), tool,
# tool_use_id (sanitised), session id (raw but for a newline, which becomes
# a blank: _mk_session_tmp's tr turns both into _), the time (jq's now: a
# Pre record's "@@t", which a permission prompt's record must follow), and
# last the settings copy for a subagent's Pre record (mk_integrity_copy_args;
# "-" when not taken here). The long copy line comes last: bash's ${v#*X} on
# a long first line is quadratic.
_ig_parse() {
  _ig_f="$(printf '%s' "$PAYLOAD" | jq -r ${MK_IG_JQ_ARGS[@]+"${MK_IG_JQ_ARGS[@]}"} '(.hook_event_name // "" | tostring | gsub("[^A-Za-z]"; "")),
  (.agent_id // "" | tostring | gsub("[^A-Za-z0-9_-]"; "_")),
  (.tool_name // "" | tostring | gsub("[^A-Za-z0-9_]"; "")),
  (.tool_use_id // "" | tostring | gsub("[^A-Za-z0-9_-]"; "_") | if . == "" then "none" else . end),
  (.session_id // "unknown" | tostring | gsub("\n"; " ")),
  (now | tostring),
  '"$MK_IG_JQ_PROG"'' 2>/dev/null)"
}
MK_IG_JQ_ARGS=(); MK_IG_JQ_PROG='"-"'
if [ "$_ig_gev" = Pre ] && [ -n "$_ig_ragent" ]; then mk_integrity_copy_args; MK_IG_JQ_PROG="($MK_IG_JQ_PROG | tojson)"; fi
# A settings file that went unreadable between the test and jq: parse again
# without the copy (the Pre path takes it separately).
if ! _ig_parse && [ "$MK_IG_JQ_PROG" != '"-"' ]; then MK_IG_JQ_ARGS=(); MK_IG_JQ_PROG='"-"'; _ig_parse; fi
if [ -z "$_ig_f" ]; then
  # jq gone (or the payload unparsable) on the Post or SubagentStop of an
  # armed agent: fail closed (the static block and the markers).
  if [ "$_ig_gev" != Pre ] && [ -n "${_IG_ARMED:-}" ] && _ig_ok "$_IG_ARMED"; then exit 1; fi
  exit 0
fi
_ig_nl="$MK_IG_NL"
_ig_ev="${_ig_f%%"$_ig_nl"*}"; _ig_f="${_ig_f#*"$_ig_nl"}"
_ig_agent="${_ig_f%%"$_ig_nl"*}"; _ig_f="${_ig_f#*"$_ig_nl"}"
_ig_tool="${_ig_f%%"$_ig_nl"*}"; _ig_f="${_ig_f#*"$_ig_nl"}"
_ig_tuid="${_ig_f%%"$_ig_nl"*}"; _ig_f="${_ig_f#*"$_ig_nl"}"
_ig_sid="${_ig_f%%"$_ig_nl"*}"; _ig_f="${_ig_f#*"$_ig_nl"}"
_ig_t="${_ig_f%%"$_ig_nl"*}"; _ig_copy="${_ig_f#*"$_ig_nl"}"
_ig_paths "$_ig_sid" "$_ig_agent"
MK_BUDGET_ON_STATIC=""
case "$_ig_ev" in
  PreToolUse)
    MK_BUDGET_EVENT=PreToolUse; MK_BUDGET_DENY_KEY=IG_PRE_BUDGET_STATIC; MK_BUDGET_CRASH_KEY=IG_PRE_CRASH_STATIC ;;
  PostToolUse|PostToolUseFailure)
    MK_BUDGET_EVENT=PostToolUse; MK_BUDGET_DENY_KEY=IG_POST_FAIL_STATIC; MK_BUDGET_CRASH_KEY=IG_POST_FAIL_STATIC
    [ -z "$_ig_agent" ] || MK_BUDGET_ON_STATIC=_ig_fire ;;
  SubagentStop)
    MK_BUDGET_EVENT=Quiet; MK_BUDGET_DENY_KEY=IG_POST_FAIL_STATIC; MK_BUDGET_CRASH_KEY=IG_POST_FAIL_STATIC
    [ -z "$_ig_agent" ] || MK_BUDGET_ON_STATIC=_ig_fire ;;
  *) exit 0 ;;
esac

# _ig_msgs -- the messages in the project's language: from the config when
# memokit is active (a config that fails to load still loads them), else
# from this session's snapshot (a subagent deleted the config).
_ig_msgs() {
  if mk_active; then
    mk_load_config >/dev/null 2>&1 || true
  else
    MK_CONFIG="$_IG_SNAP"
    MK_LANG="$(mk_lang_guess)"; mk_load_messages "$MK_LANG"
  fi
}
# _ig_print JSON KEY -- prints JSON once; a JSON that jq could not build
# gives the static KEY instead.
_ig_print() {
  if [ -n "$1" ]; then mk_budget_deny_json "$1"; else mk_budget_static_deny "$2"; fi
  exit 0
}
# _ig_write FILE TEXT -- TEXT and a newline to FILE (the safe writer).
_ig_write() {
  _mk_state_write "$1" <<EOF
$2
EOF
}

# --- Main session: the one-time deny. -----------------------------------
if [ -z "$_ig_agent" ]; then
  [ "$_ig_ev" = PreToolUse ] || exit 0
  [ -f "$_IG_ALERT" ] || exit 0
  _ig_msgs
  _ig_list="$(mk_integrity_take "$_IG_ALERT")" || exit 0
  _ig_out="$(jq -n --arg r "$(mk_msg IG_MAIN_DENY "$_ig_list")" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)" || _ig_out=""
  _ig_print "$_ig_out" IG_MAIN_DENY_STATIC
fi

# --- Subagent. -----------------------------------------------------------
if [ "$_ig_ev" != SubagentStop ]; then
  case "$_ig_tool" in Bash|Edit|Write|MultiEdit|NotebookEdit) ;; *) exit 0 ;; esac
fi
_ig_rec="${_ig_p}careful-integrity-$_ig_s-$_ig_tuid"

# Pre: the record; the agent's first one also the baseline, then the armed
# stamp (armed implies a baseline was written). A file that cannot be
# written denies the call (crash path: no record would mean no check).
if [ "$_ig_ev" = PreToolUse ]; then
  mk_active || exit 0
  mk_integrity_digest "$_IG_SNAP" >/dev/null
  [ "$_ig_copy" != "-" ] || _ig_copy="$(mk_integrity_settings_copy)"
  _ig_d="@@t $_ig_t$_ig_nl@@settings $_ig_copy$_ig_nl$MK_IG_DIGEST"
  _ig_write "$_ig_rec" "$_ig_d" || exit 1
  if ! _ig_ok "$_IG_ARMED"; then
    _ig_write "$_IG_BASE" "$_ig_d" || exit 1
    _ig_write "$_IG_ARMED" armed || exit 1
  fi
  exit 0
fi

# _ig_compare FILE -- _ig_changed: the paths changed since record/baseline
# FILE (empty: none), _ig_sl its settings line, _ig_pt its "@@t" time (empty
# for a baseline written by mk_integrity_record). The usual case without a
# fork: the same digest, nothing UNREADABLE.
_ig_compare() {
  local r=""
  _ig_changed=""; _ig_sl=""; _ig_pt=""
  mk_integrity_digest "$_IG_SNAP" >/dev/null
  { IFS= read -r _ig_sl
    case "$_ig_sl" in '@@t '*) _ig_pt="${_ig_sl#@@t }"; IFS= read -r _ig_sl ;; esac
    IFS= read -r -d '' r; } < "$1"
  r="${r%"$_ig_nl"}"
  if [ "$MK_IG_DIGEST" = "$r" ] && ! _ig_unreadable "$MK_IG_DIGEST"; then return 0; fi
  _ig_changed="$(mk_integrity_changed "$1" <<EOF
$MK_IG_DIGEST
EOF
)" || return 1
}

if [ "$_ig_ev" = SubagentStop ]; then
  # Never armed (no protected tool call, or hook added mid-session): nothing.
  _ig_ok "$_IG_ARMED" || exit 0
  if _ig_ok "$_IG_BASE"; then _ig_compare "$_IG_BASE" || exit 1
  else _ig_changed="?"; _ig_sl=""; fi
  rm -f "$_IG_BASE" "$_IG_ARMED"
else
  # Post: the record of this call; a missing one while armed is a change.
  if _ig_ok "$_ig_rec"; then _ig_compare "$_ig_rec" || exit 1
  elif _ig_ok "$_IG_ARMED"; then _ig_changed="?"; _ig_sl=""
  else exit 0; fi
  rm -f "$_ig_rec"
fi
[ -n "$_ig_changed" ] || exit 0

# _ig_rebase -- after a reported change on Post: the baseline becomes the
# state now, so SubagentStop does not report the same change again.
_ig_rebase() {
  [ "$_ig_ev" != SubagentStop ] && _ig_ok "$_IG_ARMED" || return 0
  _ig_write "$_IG_BASE" "$(mk_integrity_record "$_IG_SNAP")" 2>/dev/null || true
}

# Allow rules added by a permission prompt during THIS call, and nothing
# else: prompt notices only, no block, no deny. Only on Post (SubagentStop
# has no call to tie a prompt to), and only when every added rule was
# suggested, for the same settings file, by a PermissionRequest recorded
# between this call's Pre and this Post and less than 10 minutes ago
# (mk_integrity_perm_ok; the prompt may belong to a parallel call, and one
# record backs every call whose window holds it). Narrow rules get the allow notice; broad ones a notice
# of their own that asks the user to confirm them. A rule that names a
# protected path or is unbounded (exit 2) is the full alert even with a
# prompt, and the baseline is not renewed over it (SubagentStop reports it
# again). Any doubt is the full alert.
_ig_pt="${_ig_pt:-}"; _ig_keep=0
if [ "$_ig_changed" != "?" ] && [ "$_ig_ev" != SubagentStop ] && [ -n "$_ig_pt" ] &&
   _ig_rules="$(mk_integrity_allow_only "$_ig_changed" "${_ig_sl#@@settings }")" && [ -n "$_ig_rules" ]; then
  mk_integrity_perm_ok "$_ig_rules" "$_IG_PERM" "$_ig_pt" "$_ig_t" "$MK_IG_DIGEST"
  case $? in
    0)
      [ -z "$MK_IG_NARROW" ] || mk_integrity_mark "$_IG_ALLOW" "$MK_IG_NARROW" 2>/dev/null
      [ -z "$MK_IG_BROAD" ] || mk_integrity_mark "$_IG_BROAD" "$MK_IG_BROAD" 2>/dev/null
      _ig_rebase
      exit 0 ;;
    2) _ig_keep=1 ;;
  esac
fi
# Markers that cannot be written still leave the block below.
mk_integrity_mark "$_IG_ALERT" "$_ig_changed" 2>/dev/null
mk_integrity_mark "$_IG_NOTICE" "$_ig_changed" 2>/dev/null
[ "$_ig_keep" = 1 ] || _ig_rebase
MK_BUDGET_ON_STATIC=""
[ "$_ig_ev" != SubagentStop ] || exit 0
_ig_msgs
_ig_list="$(printf '%s\n' "$_ig_changed" | mk_integrity_list)"
_ig_out="$(jq -n --arg r "$(mk_msg IG_SUBAGENT_BLOCK "$_ig_list")" '{decision:"block",reason:$r}' 2>/dev/null)" || _ig_out=""
_ig_print "$_ig_out" IG_POST_FAIL_STATIC
