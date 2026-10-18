#!/usr/bin/env bats
load helpers
@test "example passes common.sh validation" {
  mk_project "$(cat "$MK_REPO/examples/memokit.json")"
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_load_config && echo ok"
  [ "$output" = "ok" ]
}
@test "schema lists exactly the known keys" {
  run jq -r '.properties | keys | join(",")' "$MK_REPO/schema/memokit.schema.json"
  [ "$output" = '$schema,careful,contextBudget,disk,graph,guardedDirs,hints,language,parallel,project,review,scratch,sessionStart,stateStale,version' ]
}
@test "example enables the code graph" {
  jq -e '.graph.root == "src"' "$MK_REPO/examples/memokit.json"
}
@test "example has a careful pattern" {
  jq -e '.careful.patterns[0].label == "kubectl-mutate"' "$MK_REPO/examples/memokit.json"
}
@test "final M6: maxCoders is the cap at once, not per wave" {
  d="$(jq -r '.properties.parallel.properties.maxCoders.description' "$MK_REPO/schema/memokit.schema.json")"
  printf '%s' "$d" | grep -qF 'at once'
  lacks "$d" 'wave'
}
