#!/usr/bin/env bash
# PreToolUse(Bash|Edit|Write|MultiEdit|NotebookEdit) hook: destructive commands
# need the user's own approval.
#
# A command matching a builtin or project pattern (lib/careful.sh) is denied
# with a 6-hex approval code. The user approves by STARTING their next
# message with "onay <code>" / "approve <code>"; inject-rules.sh records a
# single-use 10-minute grant, and the exact re-run is let through once.
# File-writing tools are only checked for one thing: they may not touch the
# grant file (approvals come from the user's message, never from the model).
#
# deny, not ask: "ask" does not reliably prompt in auto mode or claude -p,
# deny holds in every mode. This hook never emits "allow" -- that would skip
# Claude Code's own permission flow; "let through" means no output at all.
# Same rules for the main session and subagents, except that only the main
# session gets the temp-cleanup exemption inside compound commands
# (MK_CF_MAIN, lib/careful.sh), the lane-worktree and merged-branch cleanup
# (MK_CF_WT, lib/worktrees.sh) and the remote change windows.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
[ "${MEMOKIT_CAREFUL_OFF:-0}" = "1" ] && exit 0
mk_guard_off && exit 0

# Hard budget (fix round 4; lib/budget.sh, shared with the other guards;
# armed before the first jq call, re-review N1):
# a wall-clock watchdog (MK_GD_BUDGET_WALL s) and a CPU limit
# (MK_GD_BUDGET_CPU s) deny with CF_BUDGET_STATIC; a hook that ends before a
# decision was printed (set -u, a crash) denies with CF_CRASH_STATIC. Every
# deny and the pass go through mk_budget_decided / mk_budget_printed, so a
# decision is printed exactly once. MEMOKIT_TEST_BURN (tests only) spins
# before labelling: 1 in this process, sub in a command substitution, cpu
# in this process with no watchdog (the XCPU trap alone), crash ends the
# hook early; late and late2 wait inside the two states.
# shellcheck source-path=SCRIPTDIR source=lib/budget.sh
. "$MK_LIB_DIR/budget.sh"
static_deny() { mk_budget_static_deny "$1"; }

# deny REASON -- deny JSON from jq; a jq that fails or prints anything but
# the deny object gives a static deny.
deny() {
  local out
  if out="$(jq -n --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null)"; then
    case "$out" in
      '{'*'"permissionDecision": "deny"'*'}') mk_budget_deny_json "$out"; return 0 ;;
    esac
  fi
  static_deny CF_JQ_FAILED_STATIC
}
# pass -- let the command through: no output, exit 0.
pass() { mk_budget_decided; mk_budget_printed; exit 0; }

MK_GD_BUDGET_WALL=3.3
MK_GD_BUDGET_CPU=4
mk_budget_arm "$MK_GD_BUDGET_WALL" "$MK_GD_BUDGET_CPU" CF_BUDGET_STATIC CF_CRASH_STATIC strict

mk_resolve_root "$PAYLOAD"
# A config that vanished mid-session denies a subagent (marker from
# session-start.sh); anything else inactive stays silent (pass: strict mode
# denies any other exit before a decision).
MK_GD_VANISHED=0
if ! mk_active; then
  mk_config_vanished "$PAYLOAD" || pass
  MK_GD_VANISHED=1
fi
mk_debug_dump "guard-destructive" "$PAYLOAD"

if [ "$MK_GD_VANISHED" = 1 ]; then
  mk_load_messages "$(mk_lang_guess)"
  static_deny GS_CONFIG_MISSING
  exit 0
fi

if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then static_deny CONFIG_NO_JQ_STATIC; exit 0; fi
  deny "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")"
  exit 0
fi

if [ -z "$PAYLOAD" ]; then
  [ "${MEMOKIT_KH_SMOKE:-0}" = "1" ] && pass
  static_deny CF_EMPTY_STDIN_STATIC
  exit 0
fi

# "T" sentinel: a jq that fails or prints anything else is not trusted.
if ! tool="$(printf '%s' "$PAYLOAD" | jq -r '"T" + (.tool_name // "" | tostring)' 2>/dev/null)"; then
  deny "$(mk_msg CF_INVALID_JSON)"; exit 0
fi
case "$tool" in
  T*) tool="${tool#T}" ;;
  *) deny "$(mk_msg CF_INVALID_JSON)"; exit 0 ;;
esac

case "$tool" in
  Bash) ;;
  Edit|Write|MultiEdit|NotebookEdit)
    if ! fpath="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // empty)' 2>/dev/null)"; then
      deny "$(mk_msg CF_INVALID_JSON)"; exit 0
    fi
    # Follow symlink chains (max 10 hops; bash 3.2/BSD-safe, no readlink -f).
    # Any hop naming the grant, pending, window or active files, or an
    # unresolvable/looping link, denies.
    hops=0
    while :; do
      case "$fpath" in
        # any case: macOS file systems are case-insensitive
        *[Cc][Aa][Rr][Ee][Ff][Uu][Ll]-[Gg][Rr][Aa][Nn][Tt][Ss]*|\
        *[Cc][Aa][Rr][Ee][Ff][Uu][Ll]-[Pp][Ee][Nn][Dd][Ii][Nn][Gg]*|\
        *[Cc][Aa][Rr][Ee][Ff][Uu][Ll]-[Ww][Ii][Nn][Dd][Oo][Ww]*|\
        *[Cc][Aa][Rr][Ee][Ff][Uu][Ll]-[Aa][Cc][Tt][Ii][Vv][Ee]*) deny "$(mk_msg CF_STATE)"; exit 0 ;;
      esac
      [ -L "$fpath" ] || break
      hops=$((hops + 1))
      if [ "$hops" -gt 10 ] || ! lnk="$(readlink "$fpath" 2>/dev/null)" || [ -z "$lnk" ]; then
        deny "$(mk_msg CF_STATE)"; exit 0
      fi
      case "$lnk" in
        /*) fpath="$lnk" ;;
        *) fpath="$(dirname "$fpath")/$lnk" ;;
      esac
    done
    pass ;;
  *) pass ;;
esac

# jq -r prints a \u0000 in the command as a raw NUL, which $(...) drops: the
# text checked would differ from the command run. One jq call flags it ("N")
# or returns the command behind a "Y" sentinel.
if ! cmd="$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // "" | tostring) as $c
    | if ($c | explode | any(. == 0)) then "N" else "Y" + $c end' 2>/dev/null)"; then
  deny "$(mk_msg CF_INVALID_JSON)"; exit 0
fi
case "$cmd" in
  Y*) cmd="${cmd#Y}" ;;
  N) deny "$(mk_msg CF_NUL)"; exit 0 ;;
  *) deny "$(mk_msg CF_INVALID_JSON)"; exit 0 ;;
esac
[ -n "$cmd" ] || pass

# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$MK_LIB_DIR/careful.sh"
nl='
'
tok="mk-sentinel-$$-$RANDOM-$RANDOM"
# Recursive rm inside this session's scratchpad/ or of a whole stale sibling
# temp entry needs no code (lib/temp.sh, mk_temp_rm_safe): for a command that
# is one simple rm, and, in the main session, also inside a compound command
# with literal targets and only allowlisted commands beside rm
# (lib/careful.sh, _mk_cf_cleanup_ok; spec 0.8 Part D). The
# temp tree is located, and main/sub read, only for a command naming rm. When
# the tree is not found (or the payload has no transcript_path), nothing
# changes. MK_CF_MAIN: as IS_SUB below (agent_id empty), one jq call; a jq
# that fails leaves 0, a subagent's rule.
single_rm=0
mk_careful_single_rm "$cmd" && single_rm=1
# "Naming rm": ONE regex on the raw text, in any case, that tolerates quote
# and backslash characters around and between the letters, so "rm", r''m,
# \rm, r\m, 'r'"m" and {rm,-rf,x} count. No fork, and linear: never a
# ${cmd//pat/} or similar pattern op on the whole command, which bash 3.2
# runs in super-linear time in a UTF-8 locale (a 9 KB quoted command took
# 40 s, past the 5 s hook timeout, so the command ran unchecked). Spellings
# built by the shell ($'\x72m', ${X}m) are missed: too narrow only means the
# temp tree is not looked up, i.e. the command asks for a code; too wide
# only costs the lookup.
_q="[\"'\\\\]*"
re_rmword="(^|[^[:alnum:]_.-])${_q}[Rr]${_q}[Mm]${_q}([^[:alnum:]_.-]|\$)"
if [ "$single_rm" -eq 1 ] || [[ $cmd =~ $re_rmword ]]; then
  if [ "$(printf '%s' "$PAYLOAD" | jq -r 'if (.agent_id // "") != "" then "sub" else "main" end' 2>/dev/null)" = main ]; then
    MK_CF_MAIN=1
  fi
  # shellcheck source-path=SCRIPTDIR source=lib/temp.sh
  . "$MK_LIB_DIR/temp.sh"
  mk_temp_init "$PAYLOAD" || true
fi
# Test-only: burn the budget before labelling (see the budget block above).
mk_budget_test_burn
# ONE remote scan per command (fix round 4): with a remote config the scan
# runs here, in this process, and mk_remote_scan_checked keeps its result;
# mk_careful_labels (a subshell, which inherits the cache) and
# mk_remote_targets below reuse it instead of scanning again.
if [ "${MK_REMOTE_ENABLED:-0}" = 1 ]; then
  if ! command -v mk_remote_scan_checked >/dev/null 2>&1; then
    # shellcheck source-path=SCRIPTDIR source=lib/remote.sh
    . "$MK_LIB_DIR/remote.sh" 2>/dev/null
  fi
  if command -v mk_remote_scan_checked >/dev/null 2>&1; then mk_remote_scan_checked "$cmd" || true; fi
fi
# Sentinel: a labelling that did not run to its end (a child ended by the
# CPU limit) never reads as "no label".
labels="$(mk_careful_labels "$cmd"; printf '%s' "$tok")"
case "$labels" in *"$tok") labels="${labels%"$tok"}" ;; *) labels="unparsed$nl" ;; esac
labels="${labels%"$nl"}"
[ -n "$labels" ] || pass
# Membership in bash, not grep: a failing tool must not read as "absent".
# (labels is short: one line per distinct label.)
case "$nl$labels$nl" in
  *"${nl}careful-state${nl}"*) deny "$(mk_msg CF_STATE)"; exit 0 ;;
esac

# Lane cleanup (spec 0.8 Part D, goals 2-3): a command whose labels are ALL
# lane-cleanup labels (rm-recursive, git-worktree-force, git-branch-delete)
# is, for the main session, labelled a second time with the worktree checks
# on: MK_CF_WT=1, MK_CF_CWD = the payload cwd, lib/worktrees.sh sourced.
# lib/careful.sh then drops what lib/worktrees.sh allows (a merged-clean lane
# removed by git worktree remove or rm -r, a merged branch deleted); what is
# left is denied as usual, with the code of the full command. Cost: none for
# a command without such a label (no fork, worktrees.sh not sourced); one jq,
# the source, the second labelling and the bounded git reads otherwise. A
# subagent (agent_id), a cwd that is not absolute, a jq that fails, or a
# second labelling that does not run to its end (sentinel) keep the first
# labels.
_mk_gd_cleanup_only() {
  local l rl="$1$nl"
  while [ -n "$rl" ]; do
    l="${rl%%"$nl"*}"; rl="${rl#*"$nl"}"
    case "$l" in ''|rm-recursive|git-worktree-force|git-branch-delete) ;; *) return 1 ;; esac
  done
  return 0
}
if _mk_gd_cleanup_only "$labels"; then
  wcwd=""
  # "T<main|sub>C<cwd>E": the E keeps a cwd's trailing newline from being cut.
  wf="$(printf '%s' "$PAYLOAD" | jq -r '"T" + (if (.agent_id // "") != "" then "sub" else "main" end) + "C" + (.cwd // "" | tostring) + "E"' 2>/dev/null)" || wf=""
  case "$wf" in TmainC/*E) wcwd="${wf#TmainC}"; wcwd="${wcwd%E}" ;; esac
  case "$wcwd" in *"$nl"*) wcwd="" ;; esac
  # shellcheck source-path=SCRIPTDIR source=lib/worktrees.sh
  if [ -n "$wcwd" ] && . "$MK_LIB_DIR/worktrees.sh" 2>/dev/null && command -v mk_wt_removable >/dev/null 2>&1; then
    MK_CF_MAIN=1; MK_CF_WT=1; MK_CF_CWD="$wcwd"
    l2="$(mk_careful_labels "$cmd"; printf '%s' "$tok")"
    case "$l2" in
      *"$tok") l2="${l2%"$tok"}"; labels="${l2%"$nl"}"; [ -n "$labels" ] || pass ;;
    esac
  fi
fi
# Nothing is written above this line (a careful-state deny is never
# approvable, so it leaves no pending code either).

# _has LABEL -- LABEL is one of the current labels.
_has() { case "$nl$labels$nl" in *"$nl$1$nl"*) return 0 ;; esac; return 1; }

# Payload fields, one jq call behind a sentinel: main/sub (agent_id, as
# guard-subagent-authority.sh), foreground/background, session_id and
# tool_use_id (ASCII blanks and control characters, one byte each, made "_"
# here so the lines split; the rest sanitised with tr as check-disk.sh does,
# which gives the same name). Each line carries a prefix (T, S, U) so an
# empty field cannot shift the next one into its place. A jq that fails or
# prints anything else leaves the fail-closed defaults: a subagent (no
# pending write, no window pass) running in the background.
IS_SUB="sub"; BG="bg"; SESSION="unknown"; TUID=""
if pf="$(printf '%s' "$PAYLOAD" | jq -r '"T" + (if (.agent_id // "") != "" then "sub" else "main" end)
    + (if (.tool_input.run_in_background // false) == false then " fg" else " bg" end),
    "S" + (.session_id // "unknown" | tostring | explode | map(if . < 33 or . == 127 then 95 else . end) | implode),
    "U" + (.tool_use_id // "" | tostring | explode | map(if . < 33 or . == 127 then 95 else . end) | implode)' 2>/dev/null)"; then
  pf1="${pf%%"$nl"*}"; pf="${pf#*"$nl"}"
  pf2="${pf%%"$nl"*}"; pf3="${pf#*"$nl"}"
  case "$pf1:$pf2:$pf3" in
    *"$nl"*) ;;
    "Tmain fg:S"*":U"*|"Tmain bg:S"*":U"*|"Tsub fg:S"*":U"*|"Tsub bg:S"*":U"*)
      case "$pf2" in S*) ;; *) pf3="" ;; esac
      case "$pf3" in
        U*)
          IS_SUB="${pf1#T}"; IS_SUB="${IS_SUB% *}"; BG="${pf1##* }"
          SESSION="$(printf '%s' "${pf2#S}" | tr -c 'A-Za-z0-9_-' _)"
          TUID="$(printf '%s' "${pf3#U}" | tr -c 'A-Za-z0-9_-' _)" ;;
      esac ;;
  esac
fi
[ -n "$SESSION" ] || SESSION=unknown
# Running-marker key, as check-disk.sh's: the sanitised tool_use_id, or
# c-<session>-<cksum of the command> when the payload has none.
[ -n "$TUID" ] || TUID="c-${SESSION}-$(printf '%s' "$cmd" | cksum | cut -d' ' -f1)"

code="$(mk_careful_code "$cmd")"
# An exact single-use grant passes any command, remote ones included, but is
# consumed only by a main-session foreground call: a subagent or a background
# run never uses it (it stays for the main session; the ordinary flow goes on).
if [ "$IS_SUB" = main ] && [ "$BG" = fg ]; then
  mk_careful_consume "$code" && pass
fi

# Remote changes (spec 0.8 Part A): a command with remote targets passes
# only inside an open change window that holds every target (main session,
# foreground); otherwise it is denied with a change-plan request whose code
# is bound to its targets. Skipped (ordinary path below) when a stage failed
# (unparsed: the targets could be incomplete), for careful-state-glob and
# too-large, and when the scan yields no target.
MK_GD_MAX_STRIP=20
targets=""
if [ "${MK_REMOTE_ENABLED:-0}" = 1 ] && ! _has unparsed && ! _has careful-state-glob &&
   ! _has too-large && command -v mk_remote_targets >/dev/null 2>&1; then
  rmt=0
  if _has deploy-push || _has remote-mutate || _has k8s-mutate || _has runbook; then rmt=1; fi
  case "${MK_CAREFUL_PATTERNS_JSON:-}" in *'"target"'*) rmt=1 ;; esac
  # Sentinel: a scan that dies half way gives no targets (ordinary deny).
  if [ "$rmt" = 1 ]; then
    targets="$(mk_remote_targets "$cmd"; printf '%s' "$tok")"
    case "$targets" in *"$tok") targets="${targets%"$tok"}" ;; *) targets="" ;; esac
    targets="${targets%"$nl"}"
    # A computed destination under hosts "*" (host:(computed), I1) is not
    # a window target: the ordinary deny below, whose code approves this
    # exact command once.
    case "$nl$targets$nl" in *"${nl}host:(computed)$nl"*) targets="" ;; esac
  fi
fi
# _only_remote LIST -- every label of the newline LIST is a remote label (so
# the deny is a plan request, not an ordinary code).
_only_remote() {
  local l rl="$1$nl"
  while [ -n "$rl" ]; do
    l="${rl%%"$nl"*}"; rl="${rl#*"$nl"}"
    case "$l" in ''|deploy-push|remote-mutate|k8s-mutate|runbook) ;; *) return 1 ;; esac
  done
  return 0
}

# plan_deny [SHAPE] -- deny with a change-plan request for the command's
# targets: the targets code goes to the pending file (main session only);
# CF_REMOTE_EXTRA when the open window lacks a target, CF_REMOTE_FAILED once
# after a failed change, else CF_REMOTE. SHAPE=1 adds the hint that this
# command cannot pass a window as written.
plan_deny() {
  local tcode missing="" wt t rl failed hint=""
  [ "${1:-0}" = 1 ] && hint=" $(mk_msg CF_REMOTE_SHAPE)"
  tcode="$(mk_careful_targets_code "$targets")"
  if [ "$IS_SUB" = main ]; then mk_careful_pending_set "$SESSION" "$tcode" "$targets" 2>/dev/null || true; fi
  if [ -n "$wline" ]; then
    wt=" ${wline#* } "; rl="$targets$nl"
    while [ -n "$rl" ]; do
      t="${rl%%"$nl"*}"; rl="${rl#*"$nl"}"
      [ -n "$t" ] || continue
      case "$wt" in *" $t "*) ;; *) missing="$missing${missing:+ }$t" ;; esac
    done
  fi
  if [ -n "$missing" ]; then
    deny "$(mk_msg CF_REMOTE_EXTRA "$missing" "$tcode")$hint"
  elif [ "$IS_SUB" = main ] && failed="$(mk_careful_window_failed "$SESSION")"; then
    deny "$(mk_msg CF_REMOTE_FAILED "$failed" "$rall" "$tcode" "$MK_REMOTE_WINDOW_MIN" "$MK_REMOTE_LOG")$hint"
  else
    deny "$(mk_msg CF_REMOTE "$rall" "$tcode" "$MK_REMOTE_WINDOW_MIN" "$MK_REMOTE_LOG")$hint"
  fi
}

if [ -n "$targets" ]; then
  tlist="$(printf '%s' "$targets" | tr '\n' ' ')"; tlist="${tlist% }"
  rall="${labels//$nl/, } → $tlist"
  wline="$(mk_careful_window_get "$SESSION")" || wline=""
  # No Post event reports a background command's failure: never in a window.
  # The targets code still goes to the pending file (main session only).
  if [ "$BG" != fg ]; then
    if [ "$IS_SUB" = main ]; then
      mk_careful_pending_set "$SESSION" "$(mk_careful_targets_code "$targets")" "$targets" 2>/dev/null || true
    fi
    deny "$(mk_msg CF_REMOTE_BG "$tlist")"; exit 0
  fi
  if [ -z "$wline" ] || [ "$IS_SUB" != main ] || ! mk_careful_window_covers "$SESSION" "$targets"; then
    plan_deny; exit 0
  fi
  # Covered targets. The command passes only when mk_remote_covered_only
  # accepts its shape (rule a: no | & < > beyond && and 2>&1-style fd
  # duplications, no substitution, no environment-changing first word, no
  # unquoted glob) and every segment is either a covered remote tool
  # segment (bare tool word, allowlisted options, a runbook resolved from
  # the payload cwd) or carries no label at all. Scans: the one above
  # (shared by labels and targets) and one per segment in
  # mk_remote_covered_only, whose first output line returns those segments'
  # remote labels so the rest is labelled with careful's rules only (one
  # scan per segment); commands are at most 8 KiB (MK_RM_MAX_CHARS, else
  # too-large). Only a command of at most MK_GD_MAX_STRIP segments (upper
  # bound: 1 + its ; | & and newline bytes; a count that fails counts as
  # too many) is checked; a longer one gets the plan request with the shape
  # hint. Measured 2026-11-11 (fix round 4, macOS bash 3.2): 8 KB in 20
  # covered ssh segments, the worst passing command, 0.9 s hook wall time.
  # Sentinels: a check or a labelling that dies half way never passes.
  shape=0
  nsep="$(set -o pipefail; printf '%s' "$cmd" | LC_ALL=C tr -cd ';|&\n' | sed 's/&&/\&/g' | wc -c)" || nsep=x
  nsep="${nsep//[[:space:]]/}"
  case "$nsep" in ''|*[!0-9]*) nsep=999999 ;; esac
  rest_labels="$labels"
  # The payload cwd (the Bash tool's working directory), "C" sentinel; a
  # runbook path is resolved against it (no cwd: no runbook pass).
  cwd=""
  if pc="$(printf '%s' "$PAYLOAD" | jq -r '"C" + (.cwd // "" | tostring)' 2>/dev/null)"; then
    case "$pc" in C*) cwd="${pc#C}" ;; esac
    case "$cwd" in *"$nl"*) cwd="" ;; esac
  fi
  if [ "${#nsep}" -le 6 ] && [ "$((nsep + 1))" -le "$MK_GD_MAX_STRIP" ]; then
    rest="$(mk_remote_covered_only "$cmd" "${wline#* }" "$cwd"; printf '%s%s' "$tok" "$?")"
    case "$rest" in
      *"${tok}0")
        rest="${rest%"${tok}0"}"
        # first line: the remote labels of the uncovered segments
        rlab="${rest%%"$nl"*}"
        case "$rest" in *"$nl"*) rest="${rest#*"$nl"}" ;; *) rest="" ;; esac
        rest_labels=""
        case "$rest" in
          *[![:space:]]*)
            rest_labels="$(MK_REMOTE_ENABLED=0 mk_careful_labels "$rest"; printf '%s' "$tok")"
            case "$rest_labels" in *"$tok") rest_labels="${rest_labels%"$tok"}" ;; *) rest_labels="unparsed$nl" ;; esac
            [ -z "$rlab" ] || rest_labels="$rest_labels${rlab// /$nl}$nl"
            rest_labels="${rest_labels%"$nl"}" ;;
          *) [ -z "$rlab" ] || rest_labels="${rlab// /$nl}" ;;
        esac ;;
      *) shape=1 ;;
    esac
  else
    shape=1
  fi
  if [ "$shape" = 0 ] && [ -z "$rest_labels" ]; then
    # Pass. The running marker (first line of the command) lets
    # close-window.sh close the window when this command fails; without it
    # the pass is not safe, so a marker that cannot be written denies.
    if _mk_cf_write "$(mk_tmp "careful-window-running-$TUID")" "${cmd%%"$nl"*}" 2>/dev/null; then pass; fi
    rest_labels="$labels"
  fi
  # Only remote labels left (a malformed or uncovered remote shape): a plan
  # request with the shape hint. A local label left: the ordinary deny below
  # with those labels and the code of the full command.
  if [ -n "$rest_labels" ] && _only_remote "$rest_labels"; then plan_deny 1; exit 0; fi
  [ -n "$rest_labels" ] && labels="$rest_labels"
  case "$nl$labels$nl" in
    *"${nl}careful-state${nl}"*) deny "$(mk_msg CF_STATE)"; exit 0 ;;
  esac
fi

# Every message names every label: a special case must not hide the rest.
all="${labels//$nl/, }"
case "$nl$labels$nl" in
  *"${nl}careful-state-glob${nl}"*) deny "$(mk_msg CF_STATE_GLOB "$all" "$code")"; exit 0 ;;
  *"${nl}too-large${nl}"*) deny "$(mk_msg CF_TOO_LARGE "$all" "$code")"; exit 0 ;;
esac
# A recursive rm of a scratchpad path inside a compound command: most often a
# subagent cleaning its own temp dir in a chained command (2026-10 transcripts:
# 140 of 146 such calls were denied, then abandoned). Point at the single-rm
# form that passes; a lone rm that still failed gets no hint.
hint=""
case "$nl$labels$nl" in
  *"${nl}rm-recursive${nl}"*)
    if [ "$single_rm" -eq 0 ]; then case "$cmd" in */scratchpad/*) hint="$(mk_msg CF_SCRATCH_HINT)" ;; esac; fi ;;
esac
# The pending code lets a bare approval (no code typed) grant this deny
# (main session only; careful-state* and too-large returned above).
if [ "$IS_SUB" = main ]; then mk_careful_pending_set "$SESSION" "$code" 2>/dev/null || true; fi
deny "$(mk_msg CF_BLOCKED "$all" "$code")$hint"
exit 0
