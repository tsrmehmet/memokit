#!/usr/bin/env bats
load helpers
@test "example passes common.sh validation" {
  mk_project "$(cat "$MK_REPO/examples/memokit.json")"
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_load_config && echo ok"
  [ "$output" = "ok" ]
}
@test "schema lists exactly the known keys" {
  run jq -r '.properties | keys | join(",")' "$MK_REPO/schema/memokit.schema.json"
  [ "$output" = '$schema,careful,contextBudget,convert,disk,graph,guardedDirs,hints,language,parallel,project,remote,review,scratch,sessionStart,stateStale,version' ]
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
@test "schema remote paths reject traversal and absolute paths, allow a leading dot" {
  for k in runbooksDir log; do
    p="$(jq -r ".properties.remote.properties.$k.pattern" "$MK_REPO/schema/memokit.schema.json")"
    for bad in '../x' '/abs' 'a/../b' '.gi''t/x'; do
      run jq -en --arg p "$p" --arg v "$bad" '$v | test($p)'
      [ "$output" = "false" ] || { echo "$k accepted $bad"; false; }
    done
    jq -en --arg p "$p" --arg v '.claude/memokit/runbooks' '$v | test($p)'
  done
}
@test "example has a remote block" {
  jq -e '.remote.deployBranches[0] == "deploy"' "$MK_REPO/examples/memokit.json"
}

# cfg_err JSON -- the MK_CONFIG_ERR of a project config (empty: valid).
cfg_err() {
  mk_project "$1"
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; printf '%s' \"\$MK_CONFIG_ERR\""
}
@test "final I8: remote paths and guardedDirs refuse a .git segment at any depth (config.jq and schema)" {
  local v k p
  for v in 'x/.gi''t/y' 'a/.gi''t' '.gi''t/x' 'a/.GI''T/b'; do
    cfg_err "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"remote\":{\"runbooksDir\":\"$v\"}}"
    [ "$output" = remote ] || { echo "runbooksDir $v -> [$output]"; false; }
    cfg_err "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"remote\":{\"log\":\"$v\"}}"
    [ "$output" = remote ] || { echo "log $v -> [$output]"; false; }
    cfg_err "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"guardedDirs\":[\"$v\"]}"
    [ "$output" = guardedDirs ] || { echo "guardedDirs $v -> [$output]"; false; }
  done
  cfg_err '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"runbooksDir":"ops/.github/runbooks","log":"docs/.gitkeep.md"}}'
  [ -z "$output" ]
  for k in runbooksDir log; do
    p="$(jq -r ".properties.remote.properties.$k.pattern" "$MK_REPO/schema/memokit.schema.json")"
    run jq -en --arg p "$p" --arg v 'x/.gi''t/y' '$v | test($p)'
    [ "$output" = "false" ] || { echo "schema $k accepted x/.gi""t/y"; false; }
  done
}
@test "final M1: hosts with blanks or newlines and a fractional windowMinutes are refused" {
  local h
  for h in '" "' '"a b"' '"a\nb"' '"a\tb"'; do
    cfg_err "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"remote\":{\"hosts\":[$h]}}"
    [ "$output" = remote ] || { echo "host $h -> [$output]"; false; }
  done
  cfg_err '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"windowMinutes":2.5}}'
  [ "$output" = remote ]
  cfg_err '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["prod.example.com","*"],"windowMinutes":45}}'
  [ -z "$output" ]
  jq -e '.properties.remote.properties.hosts.items.pattern == "^\\S+$"' "$MK_REPO/schema/memokit.schema.json"
}
@test "0.8.1: parallel.auto is a boolean defaulting to false" {
  jq -e '.properties.parallel.properties.auto | .type == "boolean" and .default == false' "$MK_REPO/schema/memokit.schema.json"
}
@test "schema and example: review.validate high/always/never, default high" {
  jq -e '.properties.review.properties.validate | (.enum == ["high","always","never"]) and (.default == "high")' "$MK_REPO/schema/memokit.schema.json"
  jq -e '.review.validate == "high"' "$MK_REPO/examples/memokit.json"
}
@test "0.8.1: hints.builtin enum lists context7 and the example enables it" {
  jq -e '.properties.hints.properties.builtin.items.enum | index("context7") != null' "$MK_REPO/schema/memokit.schema.json"
  jq -e '.hints.builtin | index("context7") != null' "$MK_REPO/examples/memokit.json"
}
@test "0.8.1: convert.markitdown is a boolean defaulting to false; the example leaves it off" {
  jq -e '.properties.convert | .additionalProperties == false
    and (.properties.markitdown | .type == "boolean" and .default == false)' "$MK_REPO/schema/memokit.schema.json"
  jq -e '.convert.markitdown == false' "$MK_REPO/examples/memokit.json"
}
