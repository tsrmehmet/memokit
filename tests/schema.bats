#!/usr/bin/env bats
load helpers
@test "example passes common.sh validation" {
  mk_project "$(cat "$MK_REPO/examples/memokit.json")"
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_load_config && echo ok"
  [ "$output" = "ok" ]
}
@test "schema lists exactly the known keys" {
  run jq -r '.properties | keys | join(",")' "$MK_REPO/schema/memokit.schema.json"
  [ "$output" = '$schema,contextBudget,graph,guardedDirs,hints,language,project,sessionStart,stateStale,version' ]
}
@test "example enables the code graph" {
  jq -e '.graph.root == "src"' "$MK_REPO/examples/memokit.json"
}
