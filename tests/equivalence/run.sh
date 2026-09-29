#!/usr/bin/env bash
# Equivalence harness (spec 9.3 step 2): runs the same hook payloads through a
# project's legacy .claude/hooks/ and through memokit's hooks/, classifies each
# result and prints "case | legacy | memokit | verdict".
# Exit 0 iff every difference is listed in allowed-diffs.tsv (tag or "*").
# The project repo is only read via `git archive`; nothing is written into it.
# --self runs the memokit hooks on both sides (mechanics check, no legacy code).
# bash 3.2 compatible.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
MK_REPO="$(cd "$HERE/../.." && pwd)"

P=""; TAG_OVERRIDE=""; SELF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --tag-override) TAG_OVERRIDE="${2:-}"; shift 2 ;;
    --self) SELF=1; shift ;;
    *) P="$1"; shift ;;
  esac
done
[ -n "$P" ] && [ -d "$P" ] || { echo "usage: run.sh <project-root> [--tag-override TAG] [--self]" >&2; exit 2; }
P="$(cd "$P" && pwd)"

SB="$(mktemp -d "${TMPDIR:-/tmp}/mk-eq.XXXXXX")"; SB="$(cd "$SB" && pwd)"
TR="$(mktemp -d "${TMPDIR:-/tmp}/mk-eq-tr.XXXXXX")"
# Fresh, empty HOME for everything below (extract-legacy's vendored-skill
# check and every hook on both sides): a hook must never read or write the
# operator's real ~/.claude while the harness runs.
MK_EQ_HOME="$(mktemp -d "${TMPDIR:-/tmp}/mk-eq-home.XXXXXX")"
export HOME="$MK_EQ_HOME"
trap 'rm -rf "$SB" "$TR" "$MK_EQ_HOME"' EXIT

# Archive only the tracked paths that exist at HEAD.
PATHS=""
for p in .claude docs/STATE.md scripts; do
  [ -n "$(git -C "$P" ls-tree --name-only HEAD -- "$p" 2>/dev/null)" ] || continue
  [ "$p" = scripts ] && [ ! -f "$P/scripts/knowledge-health.sh" ] && continue
  PATHS="$PATHS $p"
done
[ -n "$PATHS" ] || { echo "nothing to archive in $P" >&2; exit 2; }
# shellcheck disable=SC2086
git -C "$P" archive HEAD $PATHS | tar -x -C "$SB"
rm -f "$SB/.claude/memokit.json"
git -C "$SB" init -q
PROPOSAL="$("$MK_REPO/skills/init/scripts/memokit-init.sh" extract-legacy "$SB")" || { echo "extract-legacy failed" >&2; exit 2; }
LEGACY_TAG="$(printf '%s' "$PROPOSAL" | jq -r '.tag // ""')"
# Base commit = the archived legacy files (this is the only commit touching docs/STATE.md).
git -C "$SB" -c user.email=e@e -c user.name=e add -A
git -C "$SB" -c user.email=e@e -c user.name=e commit -qm base --allow-empty
mkdir -p "$SB/.claude"
# Config for the memokit side = proposal + all builtin hints + custom hints from the proposal.
printf '%s' "$PROPOSAL" | jq --arg tag "$TAG_OVERRIDE" '{version:1,
  project:{name:.name, tag:(if $tag != "" then $tag else .tag end)}, language:"tr",
  guardedDirs:.guardedDirs,
  hints:{custom:[.hints[] | select(.covered|not) | {match, text}]}}' > "$SB/.claude/memokit.json"
DIRS="$(printf '%s' "$PROPOSAL" | jq -er '.guardedDirs[]')" || DIRS=""
if [ -z "$DIRS" ]; then
  echo "run.sh: proposal has no guardedDirs; @DIR@ cases would silently vanish. Aborting." >&2
  exit 2
fi
for d in $DIRS; do mkdir -p "$SB/$d"; : > "$SB/$d/.keep"; done
FIRST_DIR="$(printf '%s\n' "$DIRS" | head -n 1)"
git -C "$SB" -c user.email=e@e -c user.name=e add -A
# HEAD is a later commit that does not touch docs/STATE.md (keeps check-state-stale live).
git -C "$SB" -c user.email=e@e -c user.name=e commit -qm sandbox --allow-empty
export CLAUDE_PROJECT_DIR="$SB"

# Transcripts, same shape as tests/context-budget.bats.
mk_transcript() { # $1 file, $2 total tokens
  printf '{"message":{"usage":{"input_tokens":1000,"cache_read_input_tokens":%s,"cache_creation_input_tokens":0}}}\n' "$(( $2 - 1000 ))" > "$1"
  printf '{"message":{"usage":' >> "$1"
}
mk_transcript "$TR/t350" 350000
mk_transcript "$TR/t250" 250000

# classify CLASS OUTPUT -> stdout ("ERR" when the output is not parseable JSON)
classify() {
  local class="$1" out="$2" c m="" first
  if [ -n "$out" ] && ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then printf 'ERR'; return; fi
  case "$class" in
    pre)
      [ -z "$out" ] && { printf 'allow'; return; }
      c="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)" || c="?"
      printf '%s' "${c:-allow}" ;;
    prompt|stop|session)
      c=""
      [ -n "$out" ] && { c="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)" || c=""; }
      case "$class" in
        stop) if [ -n "$c" ]; then printf 'fired'; else printf 'silent'; fi ;;
        session)
          first="$(head -n 1 "$SB/docs/STATE.md" 2>/dev/null)"
          if [ -n "$first" ] && printf '%s' "$c" | grep -qF -- "$first"; then printf 'state'; else printf 'none'; fi ;;
        prompt)
          for pair in systematic-debugging:debugging llm-council:decision code-review:review graphify:graphify andoff:handoff; do
            printf '%s' "$c" | grep -qF -- "${pair%%:*}" && m="$m ${pair##*:}"
          done
          if printf '%s' "$c" | grep -qF -- 'devam et →' || printf '%s' "$c" | grep -qF -- 'memokit:resume'; then m="$m resume"; fi
          m="$(printf '%s' "$m" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')"; m="${m% }"
          printf '%s' "${m:--}" ;;
      esac ;;
  esac
}

# run_side SIDE HOOK PAYLOAD SUFFIX -> sets SIDE_OUT, SIDE_RC, SIDE_ERR (first stderr line)
run_side() {
  local side="$1" hook="$2" payload="$3" sfx="$4" script
  if [ "$side" = legacy ] && [ "$SELF" -eq 0 ]; then script="$SB/.claude/hooks/$hook"; else script="$MK_REPO/hooks/$hook"; fi
  payload="$(printf '%s' "$payload" | sed "s/\"session_id\":\"\\(eq[0-9]*\\)\"/\"session_id\":\"\\1-$sfx$$\"/")"
  if [ "$payload" = "@EMPTY@" ]; then payload=""; fi
  SIDE_OUT=""; SIDE_ERR=""; SIDE_RC=0
  if [ ! -r "$script" ]; then SIDE_RC=127; SIDE_ERR="hook script missing or unreadable: $script"; return; fi
  ( cd "$SB" && printf '%s' "$payload" | /bin/bash "$script" >"$TR/out" 2>"$TR/err" ); SIDE_RC=$?
  SIDE_OUT="$(cat "$TR/out")"
  SIDE_ERR="$(head -n 1 "$TR/err")"
}

# side_class CLASS -> classification of the last run_side result, honouring exit codes
side_class() {
  local class="$1"
  case "$SIDE_RC" in
    0) classify "$class" "$SIDE_OUT" ;;
    2) case "$class" in pre) printf 'deny' ;; stop) printf 'fired' ;; *) printf 'ERR' ;; esac ;;
    *) printf 'ERR' ;;
  esac
}

# allowed ID LEGACY MEMOKIT -> 0 if a row of allowed-diffs.tsv covers it
allowed() {
  local id="$1" pair="$2→$3" tag glob lm _reason
  while IFS="$(printf '\t')" read -r tag glob lm _reason; do
    [ -z "$tag" ] && continue
    case "$tag" in \#*) continue ;; esac
    [ "$tag" = "*" ] || [ "$tag" = "$LEGACY_TAG" ] || continue
    # shellcheck disable=SC2254
    case "$id" in $glob) ;; *) continue ;; esac
    # shellcheck disable=SC2254
    case "$pair" in $lm) return 0 ;; esac
  done < "$HERE/allowed-diffs.tsv"
  return 1
}

NERR=0; ERRS=""; NUNEXP=0; NSAME=0; NALLOW=0
printf 'case | legacy | memokit | verdict\n'
TAB="$(printf '\t')"
while IFS="$TAB" read -r id hook class payload setup; do
  [ -z "$id" ] && continue
  case "$id" in \#*) continue ;; esac
  case "$payload" in *@DIR@*) exp="$DIRS" ;; *) exp="-" ;; esac
  for d in $exp; do
    p="${payload//@ROOT@/$SB}"; p="${p//@T350@/$TR/t350}"; p="${p//@T250@/$TR/t250}"
    label="$id"
    if [ "$d" != "-" ]; then p="${p//@DIR@/$d}"; label="${id}[$d]"; fi
    if [ "$setup" = "dirty-first-dir" ]; then echo x > "$SB/$FIRST_DIR/dirty"; fi
    run_side legacy "$hook" "$p" L; lc="$(side_class "$class")"; lerr="$SIDE_ERR"; lrc="$SIDE_RC"
    run_side memokit "$hook" "$p" M; mc="$(side_class "$class")"; merr="$SIDE_ERR"; mrc="$SIDE_RC"
    if [ "$setup" = "dirty-first-dir" ]; then
      git -C "$SB" checkout -- . >/dev/null 2>&1; git -C "$SB" clean -fdq >/dev/null 2>&1
    fi
    if [ "$lc" = ERR ] || [ "$mc" = ERR ]; then
      v="ERROR"; NERR=$((NERR + 1))
      [ "$lc" = ERR ] && ERRS="${ERRS}${label} legacy rc=${lrc}: ${lerr:-(no stderr)}
"
      [ "$mc" = ERR ] && ERRS="${ERRS}${label} memokit rc=${mrc}: ${merr:-(no stderr)}
"
    elif [ "$lc" = "$mc" ]; then v="same"; NSAME=$((NSAME + 1))
    elif allowed "$id" "$lc" "$mc"; then v="allowed"; NALLOW=$((NALLOW + 1))
    else v="UNEXPECTED"; NUNEXP=$((NUNEXP + 1)); fi
    printf '%s | %s | %s | %s\n' "$label" "$lc" "$mc" "$v"
  done
done < "$HERE/cases.tsv"
[ -n "$ERRS" ] && printf 'ERR details (first stderr line):\n%s' "$ERRS"
printf 'tag=%s same=%s allowed=%s unexpected=%s error=%s\n' "$LEGACY_TAG" "$NSAME" "$NALLOW" "$NUNEXP" "$NERR"
[ "$NUNEXP" -eq 0 ] && [ "$NERR" -eq 0 ]
