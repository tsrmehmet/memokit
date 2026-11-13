# shellcheck shell=bash
# memokit hook library: the hard time budget shared by the PreToolUse guards
# (guard-destructive.sh, guard-subagent-authority.sh, guard-edit.sh).
# bash 3.2-safe. Sourced after lib/common.sh (mk_msg).
#
# Claude Code kills a hook after 5 s (hooks.json) and then runs the command
# unchecked, so a guard must decide first, whatever the command does to its
# scanner (fix round 4 for guard-destructive.sh; 0.8.0 final wave for the
# other two):
# - a wall-clock watchdog (a background subshell) sends TERM to the hook
#   after WALL seconds and then TERMs every descendant (a trap only runs once
#   the foreground child the hook is waiting on has ended; pgrep lists the
#   tree where present, else the CPU limit ends them); the TERM trap prints
#   the static deny DENY_KEY;
# - ulimit -t CPU (CPU seconds, soft) backs it: XCPU in the hook runs the
#   same trap; in a child it ends the child, which the sentinels around a
#   $(...) turn into a fail-closed result;
# - the EXIT trap stops the watchdog and denies (CRASH_KEY) when the hook
#   ends before a decision was printed: always in mode "strict"; in mode
#   "zero" only for a non-zero exit status, because there a bare "exit 0"
#   with no output is the hook's way of letting the command through.
# Measured 2026-11-11 (macOS /bin/bash 3.2): trap XCPU and trap TERM both
# fire; a TERM while waiting on a $(...) child is deferred until that child
# ends, hence the tree kill. Measured 2026-11-11 (final wave): once the hook
# itself has waited on a foreground child (a pipeline or an external
# command run outside $(...)), the CPU limit no longer interrupts a loop of
# builtins in the hook process (an explicit kill -XCPU still runs the
# trap); the wall-clock watchdog is the bound that always holds, the CPU
# limit backs it in children and before the first such wait.
#
# Two states keep a decision printed exactly once. mk_budget_decided: a deny
# was chosen, TERM/XCPU are ignored from here on (set in that order), its
# text is not printed yet; mk_budget_printed: the deny JSON was printed, or
# the command was let through. The budget trap prints its deny unless
# MK_BUDGET_PRINTED is set; the EXIT trap as above. A hook that ends
# between the two states still denies.
# Test modes (MEMOKIT_TEST_BURN, tests only): late2 waits past the watchdog
# in mk_budget_decided (decided, not printed), late in mk_budget_printed
# (printed); neither may change the output. cpu arms no watchdog (the XCPU
# trap alone).

# shellcheck disable=SC2034  # the state is read by a human in a debug dump, not by the code
MK_BUDGET_DECIDED=0
MK_BUDGET_PRINTED=0
MK_BUDGET_WD=""
MK_BUDGET_DENY_KEY=""
MK_BUDGET_CRASH_KEY=""
MK_BUDGET_MODE=strict
# 0.8.1 (check-integrity.sh): MK_BUDGET_EVENT PreToolUse (default) prints a
# deny; Quiet (SubagentStop) prints nothing; any other event (PostToolUse,
# PostToolUseFailure) prints {"decision":"block","reason":...}.
# MK_BUDGET_ON_STATIC names a function
# run once, after the decision and before a static deny/block is printed
# (fail-closed side effects; builtins only: the watchdog's tree kill may hit
# a child it starts).
MK_BUDGET_EVENT=PreToolUse
MK_BUDGET_ON_STATIC=""

# mk_budget_decided -- called right before the output of a deny and before
# the exit of a pass (never earlier: a decision not yet chosen must stay
# interruptible by the budget deny).
mk_budget_decided() {
  trap '' TERM XCPU
  # shellcheck disable=SC2034  # state for a reader of a debug dump; the traps key on MK_BUDGET_PRINTED
  MK_BUDGET_DECIDED=1
  [ "${MEMOKIT_TEST_BURN:-}" = late2 ] && sleep 3.6
  return 0
}
# mk_budget_printed -- right after the deny was printed (or before a pass).
mk_budget_printed() {
  MK_BUDGET_PRINTED=1
  [ "${MEMOKIT_TEST_BURN:-}" = late ] && sleep 3.6
  return 0
}
# mk_budget_static_deny KEY -- the deny JSON (a block for a PostToolUse
# event, MK_BUDGET_EVENT) for message KEY, printed with printf (no jq): for
# the budget, crash and jq-failure paths. Marks the decision (decided,
# printed).
mk_budget_static_deny() {
  local msg
  # The budget can fire before mk_load_config loaded the messages (a jq that
  # stalls there): load them without jq (mk_lang_guess greps the config).
  if ! msg="$(mk_msg "$1")"; then
    mk_load_messages "$(mk_lang_guess 2>/dev/null)" 2>/dev/null
    msg="$(mk_msg "$1")" || msg="memokit: denied ($1)"
  fi
  [ -n "$msg" ] || msg="memokit: denied ($1)"
  mk_budget_decided
  if [ -n "$MK_BUDGET_ON_STATIC" ]; then "$MK_BUDGET_ON_STATIC" 2>/dev/null; fi
  case "$MK_BUDGET_EVENT" in
    PreToolUse)
      printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$msg" ;;
    Quiet) ;;
    *) printf '{\n  "decision": "block",\n  "reason": "%s"\n}\n' "$msg" ;;
  esac
  mk_budget_printed
}
# mk_budget_deny_json JSON -- print an already built deny JSON once.
mk_budget_deny_json() {
  mk_budget_decided
  printf '%s\n' "$1"
  mk_budget_printed
}

# shellcheck disable=SC2329  # run by the traps set in mk_budget_arm
_mk_budget_trap() {
  trap '' TERM XCPU
  [ "$MK_BUDGET_PRINTED" = 1 ] && exit 0
  mk_budget_static_deny "$MK_BUDGET_DENY_KEY"
  exit 0
}
# shellcheck disable=SC2329  # run by the EXIT trap set in mk_budget_arm
_mk_budget_exit() {
  local rc=$?
  trap '' TERM XCPU
  [ -n "$MK_BUDGET_WD" ] && kill "$MK_BUDGET_WD" 2>/dev/null
  if [ "$MK_BUDGET_PRINTED" != 1 ]; then
    if [ "$MK_BUDGET_MODE" = strict ] || [ "$rc" != 0 ]; then
      mk_budget_static_deny "$MK_BUDGET_CRASH_KEY"
    fi
  fi
  exit 0
}
# _mk_budget_killtree PID SELF -- TERM to every descendant of PID but SELF.
_mk_budget_killtree() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    [ "$c" = "$2" ] && continue
    _mk_budget_killtree "$c" "$2"
    kill -TERM "$c" 2>/dev/null
  done
}
# mk_budget_test_burn -- tests only (MEMOKIT_TEST_BURN): 1 spins in the
# hook process (the watchdog), sub inside a command substitution the hook
# waits on (the tree kill), cpu in the hook with no watchdog (the XCPU trap
# alone), crash ends the hook early (set -u); anything else returns.
mk_budget_test_burn() {
  local burn
  case "${MEMOKIT_TEST_BURN:-}" in
    1|cpu) while :; do :; done ;;
    sub) burn="$(while :; do :; done)"; : "$burn" ;;
    crash) : "$MEMOKIT_TEST_UNBOUND_VARIABLE" ;;
  esac
  return 0
}
# mk_budget_arm WALL CPU DENY_KEY CRASH_KEY [MODE] -- arm the budget in the
# calling hook (not in a subshell): the CPU limit, the TERM/XCPU and EXIT
# traps and the watchdog. MODE is strict (default) or zero (see the header).
mk_budget_arm() {
  MK_BUDGET_DENY_KEY="$3"
  MK_BUDGET_CRASH_KEY="$4"
  MK_BUDGET_MODE="${5:-strict}"
  ulimit -S -t "$2" 2>/dev/null || true
  trap _mk_budget_trap XCPU TERM
  trap _mk_budget_exit EXIT
  if [ "${MEMOKIT_TEST_BURN:-}" != cpu ]; then
    # The watchdog's sleep is its own child, killed with it (its TERM trap),
    # so a hook that decided early leaves no sleep behind (every guard arms
    # before its first jq call, also in projects without memokit). Only that
    # TERM (sent by the hook's EXIT trap) disarms it: a sleep that ends for
    # any other reason (killed from outside, a signal) still TERMs the hook
    # and its tree (fail closed).
    # shellcheck disable=SC2016  # $PPID / $s are read when the child sh / the trap runs
    ( _mk_wd_stop=0; trap '_mk_wd_stop=1; kill "$s" 2>/dev/null' TERM
      sleep "$1" & s=$!; wait "$s"
      [ "$_mk_wd_stop" = 1 ] && exit 0
      me="$(sh -c 'echo $PPID')"; kill -TERM "$$" 2>/dev/null; _mk_budget_killtree "$$" "$me" ) >/dev/null 2>&1 </dev/null &
    MK_BUDGET_WD=$!
  fi
  return 0
}
