#!/usr/bin/env bash
# memokit-window.sh request <target>... -- the model's way to get ONE approval
# code for a multi-target remote plan (0.8 spec, Part A, "Two ways to get a
# code"). Validates every target, replaces the session's pending line with one
# for exactly these targets (a request after a guard deny, or for the same
# targets, replaces silently; a request after a request for other targets flags the line) and prints the code plus the plan template. The
# code equals the one guard-destructive.sh computes for the same target set.
# Exit: 0 ok, 2 unknown target / usage, 3 no session id, 4 subagent,
# 5 remote disabled / config unusable, 6 no targets. Nothing is written on any
# error path.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=lib/careful.sh
. "$MK_LIB_DIR/careful.sh"
# shellcheck source-path=SCRIPTDIR source=lib/remote.sh
. "$MK_LIB_DIR/remote.sh"

mk_resolve_root "$(jq -nc --arg c "$PWD" '{cwd:$c}' 2>/dev/null)"
if ! mk_active || ! mk_load_config; then
  mk_load_messages en
  mk_msg WR_DISABLED >&2; printf '\n' >&2; exit 5
fi

die() { local c=$1; shift; mk_msg "$@" >&2; printf '\n' >&2; exit "$c"; }

[ "${MK_REMOTE_ENABLED:-0}" = 1 ] || die 5 WR_DISABLED
[ "${CLAUDE_CODE_CHILD_SESSION:-0}" = 1 ] && die 4 WR_SUBAGENT
SESSION="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -c 'A-Za-z0-9_-' _)"
[ -n "$SESSION" ] || die 3 WR_NO_SESSION
[ "${1:-}" = request ] || die 2 WR_USAGE
shift
[ "$#" -gt 0 ] || die 6 WR_NO_TARGETS

# allowed_set -- what the config allows, on one line, for the error message.
# Globbing is off while the config words are split ("*" must stay a word).
allowed_set() {
  local out="" h b p
  set -f
  for h in $MK_REMOTE_HOSTS; do
    if [ "$h" = '*' ]; then out="$out host:<any>"; else out="$out host:$h"; fi
  done
  for b in $MK_REMOTE_DEPLOY_BRANCHES; do out="$out branch:$b"; done
  set +f
  out="$out k8s k8s:<context> runbook:$MK_REMOTE_RUNBOOKS_DIR/<file>"
  for p in $(printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq -r '.[] | select(.target) | "pattern:" + .target' 2>/dev/null); do
    out="$out $p"
  done
  printf '%s' "${out# }"
}

# bad ARG -- refuse ARG as an unknown target, control characters masked.
bad() { die 2 WR_UNKNOWN_TARGET "$(printf '%s' "$1" | tr '[:cntrl:]' '?')" "$(allowed_set)"; }

nl='
'
targets=""; n=0
for arg in "$@"; do
  # whitespace / control characters never make a target
  case "$arg" in *[[:space:][:cntrl:]]*) bad "$arg" ;; esac
  t="$arg"
  case "$t" in
    runbook:*@*) ;;
    runbook:?*) t="$(mk_remote_runbook_target "${t#runbook:}")" || bad "$arg" ;;
  esac
  case "$t" in
    host:?*)
      # configured spelling (the host match is case-insensitive)
      _mk_rm_host_target "${t#host:}" 1 || bad "$arg"
      t="$_rm_t" ;;
    *) mk_remote_target_valid "$t" || bad "$arg" ;;
  esac
  case "$t" in *[[:space:][:cntrl:]]*) bad "$arg" ;; esac
  targets="$targets$t$nl"; n=$((n + 1))
done

# one line per validated argument, or something smuggled a newline in
[ "$(printf '%s' "$targets" | grep -c '')" -eq "$n" ] || bad "$*"
targets="$(printf '%s' "$targets" | LC_ALL=C sort -u | sed '/^$/d')"
code="$(mk_careful_targets_code "$targets")"

# Never clear (so the set below flags the line and the user has to answer
# "onay <code>") when an unexpired request record of this session holds a
# different code, or the current line is already flagged, whoever wrote it.
# Otherwise (deny-written line, same targets as the recorded request) the
# line is replaced silently.
keep=0
reqcode="$(mk_careful_pending_req_get "$SESSION")" && [ "$reqcode" != "$code" ] && keep=1
old="$(mk_careful_pending_get "$SESSION")" || old=""
oe="${old#* }"; oe="${oe%% *}"
case "$oe" in *'!') keep=1 ;; esac
# Fail closed: if the request record cannot be written, do not clear (the set
# below then flags whatever is pending). The probe write is safe because with
# keep=0 the old record is absent, expired or holds this very code.
if [ "$keep" = 0 ] && ! mk_careful_pending_req_set "$SESSION" "$code" 2>/dev/null; then keep=1; fi
[ "$keep" = 1 ] || mk_careful_pending_clear "$SESSION"
mk_careful_pending_set "$SESSION" "$code" "$targets" || exit 5
if ! mk_careful_pending_req_set "$SESSION" "$code" 2>/dev/null && [ "$keep" = 0 ]; then
  mk_careful_pending_clear "$SESSION"; exit 5
fi

tlist="$(printf '%s' "$targets" | tr '\n' ' ')"
mk_msg WR_CODE "$code" "${tlist% }" "$MK_REMOTE_WINDOW_MIN"; printf '\n'
mk_msg WR_TEMPLATE "$code"; printf '\n'
