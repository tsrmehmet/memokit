#!/usr/bin/env bash
# UserPromptSubmit hook: re-inject the core rule block every turn, PLUS
# keyword-gated skill hints when the prompt looks like work a specific skill
# already exists for. The builtin hint set is configurable per-project via
# memokit.json (hints.builtin); project-specific hints come from
# hints.custom.
#
# Why conditional instead of a table in CLAUDE.md: a permanent skill table
# would be paid by every session forever. A keyword-gated hint costs nothing
# on the turns it does not fire, and a hook cannot be forgotten the way a
# documented rule can.
#
# SAFETY: the prompt is READ but never echoed back, with ONE exception: the
# 6-hex approval code of a valid approval first line (see the phrases below)
# is echoed (it matched [0-9a-f]{6} exactly). The plan's targets and expiry
# in the window message come from memokit's own pending/window files (words
# validated by the careful lib), not from the prompt. Only fixed strings from
# this file (plus the sanitized graph-staleness gate text, see below) reach
# additionalContext, so nothing else in a prompt can break the JSON or smuggle
# instructions through it.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "inject-rules" "$PAYLOAD"

# jq missing must not lose the base rule block entirely: the guard hooks deny
# in this situation, but this hook is fail-open and the rule block is the
# whole point of it firing every turn, so fall back to a hand-written JSON
# literal built from the ASCII-only, quote-free _STATIC message key instead
# of exiting silently.
if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "UserPromptSubmit",\n    "additionalContext": "%s"\n  }\n}\n' "$(mk_msg IR_RULES_BASE_STATIC)"
  fi
  exit 0
fi

prompt="$(printf '%s' "$PAYLOAD" | jq -r '.prompt // empty' 2>/dev/null)" || prompt=""
DIRS="$(mk_dirs_human)"

# Approval (guard-destructive.sh). Only the FIRST LINE counts, so a code
# quoted inside a report or a notification never grants anything. Phrases
# (case-insensitive, EXACT bytes under LC_ALL=C; the dotless i is built from
# an octal escape, never a literal letter, and refusals such as the Turkish
# "do not approve" forms do not match):
#   with a code: onay | the Turkish -iyorum form | approve | approved, then
#     the 6-hex code, then only blanks/punctuation (any other text = no grant);
#   bare (whole line): the same words | "evet onayla" -> the session's single
#     pending code (a flagged line, i.e. two plans were shown, is ambiguous).
# A pending plan with targets opens a change window and the targets
# (validated words from the hook's own pending file) and the expiry time are
# echoed; the code is [0-9a-f]{6}. With remote configured a code that matches
# no unexpired pending line is refused (nothing written); without it the code
# becomes a single-use grant as before.
GRANTED=""
_ir_dotless="$(printf '\304\261')"
_ir_word="([Oo][Nn][Aa][Yy]|[Oo][Nn][Aa][Yy][Ll](${_ir_dotless}|[iI])[Yy][Oo][Rr][Uu][Mm]|[Aa][Pp][Pp][Rr][Oo][Vv][Ee]|[Aa][Pp][Pp][Rr][Oo][Vv][Ee][Dd])"
first="$(printf '%s' "$prompt" | LC_ALL=C sed -n '1p')"
code="$(printf '%s' "$first" | LC_ALL=C sed -nE "s/^[[:space:]]*${_ir_word}[[:space:]]+([0-9a-fA-F]{6})[[:space:][:punct:]]*\$/\\3/p" | tr 'A-F' 'a-f')"
bare=0
if [ -z "$code" ] && printf '%s' "$first" | LC_ALL=C grep -qE "^[[:space:]]*(${_ir_word}|[Ee][Vv][Ee][Tt][[:space:]]+[Oo][Nn][Aa][Yy][Ll][Aa])[[:space:]]*\$"; then
  bare=1
fi
if [ -n "$code" ] || [ "$bare" = 1 ]; then
  # shellcheck source-path=SCRIPTDIR source=lib/careful.sh
  . "$MK_LIB_DIR/careful.sh"
  # Session id exactly as guard-destructive.sh derives it.
  SESSION="$(printf '%s' "$PAYLOAD" | jq -r '(.session_id // "unknown" | tostring | explode | map(if . < 33 or . == 127 then 95 else . end) | implode)' 2>/dev/null)" || SESSION=""
  SESSION="$(printf '%s' "$SESSION" | tr -c 'A-Za-z0-9_-' _)"
  [ -n "$SESSION" ] || SESSION=unknown
  pline=""
  if [ "$bare" = 1 ]; then
    pline="$(mk_careful_pending_get "$SESSION")" || pline=""
    if [ -z "$pline" ]; then
      GRANTED="$(mk_msg IR_CAREFUL_NO_PENDING)"
    else
      read -r code pexp _ <<EOF
$pline
EOF
      case "$pexp" in *!) GRANTED="$(mk_msg IR_CAREFUL_PENDING_AMBIGUOUS "$code")"; code="" ;; esac
    fi
  else
    pline="$(mk_careful_pending_get "$SESSION" "$code")" || pline=""
  fi
  if [ -n "$code" ]; then
    ptargets=""
    if [ -n "$pline" ]; then
      read -r _ _ ptargets <<EOF
$pline
EOF
    fi
    if [ -n "$ptargets" ]; then
      # Window: the plan's targets (newline list); then consume the pending line.
      if mk_careful_window_open "$SESSION" "$MK_REMOTE_WINDOW_MIN" "$(printf '%s' "$ptargets" | tr ' ' '\n')" 2>/dev/null; then
        mk_careful_pending_clear "$SESSION"
        wexp="$(mk_careful_window_get "$SESSION")" || wexp=""
        wexp="${wexp%% *}"
        if date -d @0 +%s >/dev/null 2>&1; then
          until_="$(date -d "@${wexp:-0}" +%H:%M)"
        else
          until_="$(date -r "${wexp:-0}" +%H:%M)"
        fi
        GRANTED="$(mk_msg IR_CAREFUL_WINDOW "$ptargets" "$until_")"
      else
        GRANTED="$(mk_msg IR_CAREFUL_WINDOW_FAILED)"
      fi
    elif [ -n "$pline" ] || [ "${MK_REMOTE_ENABLED:-0}" != 1 ]; then
      # No-target pending line, or remote not configured: single-use grant.
      if mk_careful_grant "$code" 2>/dev/null; then
        [ -z "$pline" ] || mk_careful_pending_clear "$SESSION"
        GRANTED="$(mk_msg IR_CAREFUL_GRANTED "$code")"
      fi
    else
      # Remote configured and nothing pending for this code (unknown or
      # expired): refuse, write nothing.
      GRANTED="$(mk_msg IR_CAREFUL_NO_PENDING)"
    fi
  fi
fi
TEXT="$(mk_msg IR_RULES_BASE "$DIRS")"

RULES_FILE="$MK_ROOT/.claude/memokit/rules.md"
if [ -f "$RULES_FILE" ]; then
  TEXT="${TEXT} $(cat "$RULES_FILE")"
fi

hint_on() { case " $MK_HINTS_BUILTIN " in *" $1 "*) return 0 ;; esac; return 1; }
# stderr is silenced: an invalid ERE (memokit.json hints.custom.match is
# project config, not validated as a regex by config.jq) makes grep print a
# parse-error diagnostic to stderr and exit non-zero -- matches() must still
# just report "no match" via its exit status, with no diagnostic noise ever
# reaching a caller that might merge stdout+stderr (this hook's own stdout,
# read alone, is unaffected either way: the diagnostic never went there).
# printf 2>/dev/null: grep -q may close the pipe early (EPIPE when SIGPIPE is ignored).
matches() { printf '%s' "$prompt" 2>/dev/null | grep -qiE "$1" 2>/dev/null; }
HINTS=""
if [ -n "$prompt" ]; then
  hint_on debugging && matches 'bug|hata|çalışmıyor|calismiyor|patlıyor|patliyor|kırmızı|kirmizi|broken|crash|exception|regres|neden böyle|neden boyle|fails?|failing|flaky|triyaj|triage|red tests?|e2e' \
    && HINTS="${HINTS}$(mk_msg IR_HINT_DEBUGGING)"
  if hint_on graphify && matches 'nerede|hangi modül|hangi modul|hangi servis|neye bağlı|neye bagli|kim çağır|kim cagir|bağımlılık|bagimlilik|nasıl akıyor|nasil akiyor|call graph|where is|who calls'; then
    gate=""
    # shellcheck source-path=SCRIPTDIR source=lib/graph.sh
    . "$MK_LIB_DIR/graph.sh"
    if [ -n "$MK_GRAPH_ROOT" ]; then
      # Configured graph: memokit measures staleness itself. The line is built
      # from fixed message templates plus a commit count and config values
      # that config.jq restricted to a path charset.
      mk_graph_status
      gate="$MK_GRAPH_LINE"
    elif [ -x "$MK_ROOT/scripts/graph-staleness.sh" ]; then
      # External process output: first line only, strip quotes/backslashes and C0 controls
      # (see rationale in hooks/lib/README.md).
      # shellcheck disable=SC1003  # false positive: '\000-\037' is a literal
      # backslash-digit byte range for `tr -d`, not an attempt to escape a
      # single quote.
      gate="$("$MK_ROOT/scripts/graph-staleness.sh" 2>/dev/null | head -1 | tr -d '"\\' | LC_ALL=C tr -d '\000-\037')"
    fi
    if [ -n "$gate" ]; then HINTS="${HINTS}$(mk_msg IR_HINT_GRAPHIFY_FRESH "$gate")"; else HINTS="${HINTS}$(mk_msg IR_HINT_GRAPHIFY "$MK_GRAPH_HELPER")"; fi
  fi
  hint_on decision && matches 'mimari|trade-off|hangisini seç|hangisini sec|a mı b mi|a mi b mi|seçenek|secenek|geri dönüşü zor|geri donusu zor|konsey|council|teknoloji|altyapı|altyapi|yığın|yigin|stack|architecture' \
    && HINTS="${HINTS}$(mk_msg IR_HINT_DECISION)"
  hint_on review && matches 'merge|teslim|review|pr aç|pr ac|push edelim|deploy edelim|tamamlandı mı|tamamlandi mi' \
    && HINTS="${HINTS}$(mk_msg IR_HINT_REVIEW)"
  hint_on handoff && matches 'handoff|hand off|devret|oturumu kapat' \
    && HINTS="${HINTS}$(mk_msg IR_HINT_HANDOFF)"
  hint_on resume && matches '(^|[^a-zA-Z])devam et|(^|[^a-zA-Z])resume|(^|[^a-zA-Z])continue' \
    && HINTS="${HINTS}$(mk_msg IR_HINT_RESUME)"
  # Project hints: match/text come from the project's own trusted config. A
  # match regex that grep -E rejects as invalid (e.g. an unbalanced "[") just
  # makes matches() return non-zero like any other non-match -- grep's own
  # parse error goes to stderr, which is not captured anywhere this JSON is
  # built from, so a bad regex in memokit.json can never crash this hook or
  # corrupt its output, only fail to fire.
  n="$(printf '%s' "$MK_HINTS_CUSTOM_JSON" | jq 'length' 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    re="$(printf '%s' "$MK_HINTS_CUSTOM_JSON" | jq -r ".[$i].match")"
    tx="$(printf '%s' "$MK_HINTS_CUSTOM_JSON" | jq -r ".[$i].text")"
    matches "$re" && HINTS="${HINTS} ${tx}"
    i=$((i + 1))
  done
fi

jq -n --arg t "${TEXT}${HINTS}${GRANTED}" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$t}}'
exit 0
