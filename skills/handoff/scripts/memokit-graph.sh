#!/usr/bin/env bash
# memokit code-graph helper.
#   status   print the graph's staleness; exit 0 fresh, 1 stale, 2 unknown, 3 no graph
#   refresh  build or incrementally refresh the graph; exit 0 done (or nothing
#            to do), 1 refresh failed (previous graph kept), 2 precondition missing
# Both exit 0 with a one-line notice when .claude/memokit.json has no `graph`.
#
# The builtin refresh runs `graphify update <graph.root>` from the repo root:
# code files only, AST extraction, no LLM. Lessons it encodes (measured on
# graphify 0.9.1):
# - GRAPHIFY_OUT is pinned to an ABSOLUTE <root>/graphify-out. graphify places
#   graph.json next to the scanned path but manifest.json relative to the CWD;
#   a relative GRAPHIFY_OUT splits them and the marker lands next to a graph
#   that was never refreshed.
# - No --force: when the node count drops sharply graphify refuses, and only a
#   human can tell a refactor from a lost corpus.
# - The marker moves only after graphify exited 0 AND graph.json has nodes.
#   "graph.json unchanged" is NOT a failure: graphify leaves outputs untouched
#   when an edit changed no topology (e.g. a function body).
set -u
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/common.sh
. "$SELF_DIR/../../../hooks/lib/common.sh"
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/graph.sh
. "$MK_LIB_DIR/graph.sh"

CMD="${1:-}"
case "$CMD" in
  status|refresh) ;;
  *) mk_load_messages en; mk_msg GR_USAGE >&2; printf '\n' >&2; exit 2 ;;
esac

say() { mk_msg "$@"; printf '\n'; }

mk_resolve_root "$(jq -nc --arg c "$PWD" '{cwd:$c}' 2>/dev/null || printf '{}')"
if ! mk_active; then mk_load_messages en; say GR_NO_CONFIG; exit 2; fi
if ! mk_load_config; then say GR_CONFIG_INVALID "$MK_CONFIG_ERR"; exit 2; fi
if [ -z "$MK_GRAPH_ROOT" ]; then say GR_OFF; exit 0; fi

if [ "$CMD" = "status" ]; then
  mk_graph_status; rc=$?
  printf '%s\n' "$MK_GRAPH_LINE"
  exit "$rc"
fi

# --- refresh -----------------------------------------------------------------
if [ -n "$MK_GRAPH_REFRESH_SCRIPT" ]; then
  (cd "$MK_ROOT" && bash "$MK_GRAPH_REFRESH_SCRIPT"); rc=$?
  if [ "$rc" -ne 0 ]; then say GR_SCRIPT_FAILED "$MK_GRAPH_REFRESH_SCRIPT" "$rc"; exit 1; fi
  say GR_SCRIPT_OK "$MK_GRAPH_REFRESH_SCRIPT"
  exit 0
fi

command -v graphify >/dev/null 2>&1 || { say GR_NO_GRAPHIFY; exit 2; }
[ -d "$MK_ROOT/$MK_GRAPH_ROOT" ] || { say GR_ROOT_MISSING "$MK_GRAPH_ROOT"; exit 2; }
# A path inside the dir: a dir-only pattern ("graphify-out/") cannot match a
# directory that does not exist yet.
git -C "$MK_ROOT" check-ignore -q graphify-out/graph.json 2>/dev/null || { say GR_NOT_IGNORED; exit 2; }

mk_graph_status
if [ "$MK_GRAPH_BEHIND" = "0" ]; then say GR_UP_TO_DATE "$MK_GRAPH_ROOT"; exit 0; fi

OUT="$MK_ROOT/graphify-out"
LOG="$(mktemp "${TMPDIR:-/tmp}/memokit-graph.XXXXXX")"
trap 'rm -f "$LOG"' EXIT
started="$(date +%s)"
(cd "$MK_ROOT" && GRAPHIFY_OUT="$OUT" graphify update "$MK_GRAPH_ROOT") > "$LOG" 2>&1; rc=$?
elapsed=$(( $(date +%s) - started ))
if [ "$rc" -ne 0 ]; then
  tail -n 8 "$LOG"
  say GR_FAILED "$rc"
  exit 1
fi
nodes="$(jq -r '(.nodes // []) | length' "$OUT/graph.json" 2>/dev/null)" || nodes=""
case "$nodes" in ''|*[!0-9]*|0) tail -n 8 "$LOG"; say GR_EMPTY; exit 1 ;; esac
git -C "$MK_ROOT" rev-parse HEAD > "$OUT/.graph_commit" || exit 1
say GR_REFRESHED "$nodes" "$elapsed" "$(git -C "$MK_ROOT" rev-parse --short HEAD)"
exit 0
