#!/usr/bin/env bats
load helpers

@test "plugin.json is valid and named memokit" {
  run jq -r '.name' "$MK_REPO/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
  [ "$output" = "memokit" ]
}

@test "marketplace lists memokit from repo root" {
  run jq -r '.plugins[0].name + " " + .plugins[0].source' "$MK_REPO/.claude-plugin/marketplace.json"
  [ "$output" = "memokit ./" ]
}

@test "license is MIT" {
  run head -1 "$MK_REPO/LICENSE"
  [ "$output" = "MIT License" ]
}

@test "helpers build a git project with config" {
  mk_project
  [ -f "$PROJ/.claude/memokit.json" ]
  run git -C "$PROJ" rev-parse --is-inside-work-tree
  [ "$output" = "true" ]
}

@test "plugin is default-disabled (enabled per project via enabledPlugins)" {
  run jq -r '.defaultEnabled' "$MK_REPO/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}
