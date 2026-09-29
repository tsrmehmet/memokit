#!/usr/bin/env bats
load helpers

@test "every hook sources common.sh and gates on mk_active" {
  for f in "$HOOKS"/*.sh; do
    grep -q '^\. "$(dirname "$0")/lib/common.sh"$' "$f" || { echo "no source: $f"; false; }
    grep -q 'mk_active' "$f" || { echo "no gate: $f"; false; }
  done
}

@test "guards check kill switch before reading config" {
  for f in guard-edit.sh guard-subagent-authority.sh; do
    a=$(grep -n 'mk_guard_off' "$HOOKS/$f" | head -1 | cut -d: -f1)
    b=$(grep -n 'mk_load_config' "$HOOKS/$f" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "order: $f"; false; }
  done
}
