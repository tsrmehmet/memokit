#!/usr/bin/env bats
load helpers

GS_REL="skills/handoff/scripts/memokit-graph.sh"
graph_cfg() {
  printf '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"%s","graph":{"root":"src","maxCommitsBehind":2%s}}' "${1:-en}" "${2:-}"
}
commit_all() { git -C "$PROJ" add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm "${1:-c}"; }
commit_src() { printf '%s\n' "$1" >> "$PROJ/src/a.py"; commit_all "$1"; }

# Stub graphify: logs "<args>|<GRAPHIFY_OUT>|<pwd>" and writes a graph.json.
# STUB_MODE=fail exits 1, STUB_MODE=empty writes a graph without nodes.
setup_graph() {
  mk_project "${1:-$(graph_cfg)}"
  printf 'graphify-out/\n' > "$PROJ/.gitignore"
  printf 'x = 1\n' > "$PROJ/src/a.py"
  commit_all setup
  STUB="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkstub.XXXXXX")"
  STUB_LOG="$STUB/calls.log"; : > "$STUB_LOG"
  cat > "$STUB/graphify" <<'EOF'
#!/bin/sh
printf '%s %s|%s|%s\n' "$1" "$2" "$GRAPHIFY_OUT" "$(pwd)" >> "$STUB_LOG"
case "${STUB_MODE:-ok}" in
  fail) echo "boom-from-graphify" >&2; exit 1 ;;
  empty) mkdir -p "$GRAPHIFY_OUT"; echo '{"nodes":[],"links":[]}' > "$GRAPHIFY_OUT/graph.json"; exit 0 ;;
esac
mkdir -p "$GRAPHIFY_OUT"
echo '{"nodes":[{"id":"a"},{"id":"b"}],"links":[]}' > "$GRAPHIFY_OUT/graph.json"
EOF
  chmod +x "$STUB/graphify"
  export STUB_LOG PATH="$STUB:$PATH"
}
gs() { run "$MK_BASH" "$MK_REPO/$GS_REL" "$@"; }
calls() { wc -l < "$STUB_LOG" | tr -d ' '; }
marker() { cat "$PROJ/graphify-out/.graph_commit" 2>/dev/null; }

@test "usage error on unknown command" {
  setup_graph
  gs frobnicate; [ "$status" -eq 2 ]
  gs;            [ "$status" -eq 2 ]
}
@test "graph not configured: status and refresh are a no-op with exit 0" {
  setup_graph '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  gs status;  [ "$status" -eq 0 ]; printf '%s' "$output" | grep -qi 'not configured'
  gs refresh; [ "$status" -eq 0 ]; [ "$(calls)" = 0 ]
}
@test "missing graph: status rc 3 and names the refresh command" {
  setup_graph
  gs status; [ "$status" -eq 3 ]
  printf '%s' "$output" | grep -qF "$GS_REL refresh"
}
@test "refresh builds the graph from the repo root with an absolute GRAPHIFY_OUT and writes the marker" {
  setup_graph
  gs refresh
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$STUB_LOG")" = "update src|$PROJ/graphify-out|$PROJ" ]
  [ "$(marker)" = "$(git -C "$PROJ" rev-parse HEAD)" ]
  printf '%s' "$output" | grep -q '2 nodes'
}
@test "refresh is a no-op when no commit touched the root since the marker" {
  setup_graph; gs refresh; [ "$status" -eq 0 ]
  printf 'd\n' > "$PROJ/docs/x.md"; commit_all docs
  gs refresh; [ "$status" -eq 0 ]; [ "$(calls)" = 1 ]
}
@test "status counts only commits under the root and applies the threshold" {
  setup_graph; gs refresh
  printf 'd\n' > "$PROJ/docs/x.md"; commit_all docs
  commit_src one; commit_src two
  gs status; [ "$status" -eq 0 ]; printf '%s' "$output" | grep -q '2'
  commit_src three
  gs status; [ "$status" -eq 1 ]; printf '%s' "$output" | grep -q '3'
  printf '%s' "$output" | grep -qF "$GS_REL refresh"
  gs refresh; [ "$status" -eq 0 ]; [ "$(calls)" = 2 ]
  gs status; [ "$status" -eq 0 ]
}
@test "graphify failure: exit 1, marker untouched, graphify output shown" {
  setup_graph; gs refresh; old="$(marker)"
  commit_src change
  STUB_MODE=fail gs refresh
  [ "$status" -eq 1 ]
  [ "$(marker)" = "$old" ]
  printf '%s' "$output" | grep -q 'boom-from-graphify'
}
@test "a graph without nodes is a failure and does not move the marker" {
  setup_graph
  STUB_MODE=empty gs refresh
  [ "$status" -eq 1 ]
  [ -z "$(marker)" ]
}
@test "graphify-out not git-ignored: refuses before running graphify" {
  setup_graph; rm "$PROJ/.gitignore"; commit_all rm-ignore
  gs refresh
  [ "$status" -eq 2 ]; [ "$(calls)" = 0 ]
  printf '%s' "$output" | grep -qF '.gitignore'
}
@test "graphify not installed: exit 2" {
  setup_graph
  run env PATH="$(path_without)" "$MK_BASH" "$MK_REPO/$GS_REL" refresh
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qi 'graphify'
}
@test "missing root directory: exit 2" {
  setup_graph "$(graph_cfg en | sed 's/"root":"src"/"root":"nope"/')"
  gs refresh; [ "$status" -eq 2 ]; [ "$(calls)" = 0 ]
}
@test "a marker that is not a full sha is invalid (rc 2) and refresh repairs it" {
  setup_graph; gs refresh
  printf 'HEAD\n' > "$PROJ/graphify-out/.graph_commit"
  gs status; [ "$status" -eq 2 ]
  gs refresh; [ "$status" -eq 0 ]
  [ "$(marker)" = "$(git -C "$PROJ" rev-parse HEAD)" ]
}
@test "refreshScript overrides the builtin refresh and its exit code decides" {
  setup_graph "$(graph_cfg en ',"refreshScript":"scripts/r.sh"')"
  mkdir -p "$PROJ/scripts"
  printf '#!/bin/sh\npwd > ran.txt\nexit "${R_RC:-0}"\n' > "$PROJ/scripts/r.sh"
  gs refresh
  [ "$status" -eq 0 ]; [ "$(calls)" = 0 ]; [ "$(cat "$PROJ/ran.txt")" = "$PROJ" ]
  R_RC=3 gs refresh
  [ "$status" -eq 1 ]
}
@test "subdirectory launch resolves the project root" {
  setup_graph
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  gs refresh; [ "$status" -eq 0 ]
  [ -f "$PROJ/graphify-out/graph.json" ]
}
@test "messages follow the project language" {
  setup_graph "$(graph_cfg tr)"
  gs status; [ "$status" -eq 3 ]
  printf '%s' "$output" | grep -q 'henüz yok'
}
@test "without memokit config the helper refuses" {
  mk_project none
  gs status; [ "$status" -eq 2 ]
}
@test "fresh line reads correctly in both languages" {
  setup_graph "$(graph_cfg tr)"; gs refresh
  gs status; [ "$status" -eq 0 ]; printf '%s' "$output" | grep -qF '0 commit geride, kapsam src' || { echo "$output"; false; }
  setup_graph "$(graph_cfg en)"; gs refresh
  gs status; [ "$status" -eq 0 ]; printf '%s' "$output" | grep -qF '0 commits behind under src' || { echo "$output"; false; }
}
