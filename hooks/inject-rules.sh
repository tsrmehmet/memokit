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
# SAFETY: the prompt is READ but never echoed back. Only fixed strings from
# this file (plus the sanitized graph-staleness gate text, see below) reach
# additionalContext, so nothing in a prompt can break the JSON or smuggle
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
matches() { printf '%s' "$prompt" | grep -qiE "$1" 2>/dev/null; }
HINTS=""
if [ -n "$prompt" ]; then
  hint_on debugging && matches 'bug|hata|çalışmıyor|calismiyor|patlıyor|patliyor|kırmızı|kirmizi|broken|crash|exception|regres|neden böyle|neden boyle|fails?|failing' \
    && HINTS="${HINTS}$(mk_msg IR_HINT_DEBUGGING)"
  if hint_on graphify && matches 'nerede|hangi modül|hangi modul|hangi servis|neye bağlı|neye bagli|kim çağır|kim cagir|bağımlılık|bagimlilik|nasıl akıyor|nasil akiyor|call graph|where is|who calls'; then
    gate=""
    if [ -x "$MK_ROOT/scripts/graph-staleness.sh" ]; then
      # External process output: first line only, strip quotes/backslashes and C0 controls
      # (see rationale in hooks/lib/README.md).
      # shellcheck disable=SC1003  # false positive: '\000-\037' is a literal
      # backslash-digit byte range for `tr -d`, not an attempt to escape a
      # single quote.
      gate="$("$MK_ROOT/scripts/graph-staleness.sh" 2>/dev/null | head -1 | tr -d '"\\' | LC_ALL=C tr -d '\000-\037')"
    fi
    if [ -n "$gate" ]; then HINTS="${HINTS}$(mk_msg IR_HINT_GRAPHIFY_FRESH "$gate")"; else HINTS="${HINTS}$(mk_msg IR_HINT_GRAPHIFY)"; fi
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

jq -n --arg t "${TEXT}${HINTS}" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$t}}'
exit 0
