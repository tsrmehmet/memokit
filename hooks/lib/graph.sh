#!/usr/bin/env bash
# memokit code-graph (graphify) staleness. Sourced after mk_load_config, never
# executed. bash 3.2-safe. Used by inject-rules.sh (the codebase-question hint)
# and skills/handoff/scripts/memokit-graph.sh (status/refresh), so both read
# the same definition of "stale".
#
# The graph lives in <root>/graphify-out; graphify-out/.graph_commit holds the
# HEAD sha of the last successful refresh. Staleness = commits touching
# graph.root since that sha. A marker is trusted only when it is a full 40-hex
# sha that git resolves to a commit: "HEAD" or a branch name would always
# measure 0 commits behind, however old the graph is.
# shellcheck disable=SC2034

# Absolute path of the helper that builds/refreshes the graph; messages name it
# so the model can run it verbatim.
MK_GRAPH_HELPER="$(cd "$MK_HOOKS_DIR/.." && pwd)/skills/handoff/scripts/memokit-graph.sh"

# mk_graph_status -- sets MK_GRAPH_LINE (one line, no quotes) and
# MK_GRAPH_BEHIND (commit count, empty when unknown); returns
# 0 fresh, 1 stale, 2 unknown/invalid marker, 3 no graph.
mk_graph_status() {
  local out="$MK_ROOT/graphify-out" marker behind
  MK_GRAPH_LINE=""; MK_GRAPH_BEHIND=""
  if [ ! -f "$out/graph.json" ]; then
    MK_GRAPH_LINE="$(mk_msg GR_MISSING "$MK_GRAPH_HELPER")"; return 3
  fi
  if [ ! -f "$out/.graph_commit" ]; then
    MK_GRAPH_LINE="$(mk_msg GR_NO_MARKER "$MK_GRAPH_HELPER")"; return 2
  fi
  if ! command -v git >/dev/null 2>&1; then
    MK_GRAPH_LINE="$(mk_msg GR_NO_GIT)"; return 2
  fi
  marker="$(tr -d ' \t\r\n' < "$out/.graph_commit" 2>/dev/null)"
  if ! printf '%s' "$marker" | grep -Eq '^[0-9a-fA-F]{40}$' ||
     ! git -C "$MK_ROOT" cat-file -e "${marker}^{commit}" 2>/dev/null; then
    MK_GRAPH_LINE="$(mk_msg GR_BAD_MARKER "$MK_GRAPH_HELPER")"; return 2
  fi
  behind="$(git -C "$MK_ROOT" rev-list --count "${marker}..HEAD" -- "$MK_GRAPH_ROOT" 2>/dev/null)" || behind=""
  case "$behind" in ''|*[!0-9]*) MK_GRAPH_LINE="$(mk_msg GR_NO_GIT)"; return 2 ;; esac
  MK_GRAPH_BEHIND="$behind"
  if [ "$behind" -gt "$MK_GRAPH_MAX_BEHIND" ]; then
    MK_GRAPH_LINE="$(mk_msg GR_STALE "$behind" "$MK_GRAPH_ROOT" "$MK_GRAPH_MAX_BEHIND" "$MK_GRAPH_HELPER")"; return 1
  fi
  MK_GRAPH_LINE="$(mk_msg GR_FRESH "$behind" "$MK_GRAPH_ROOT")"
  return 0
}
