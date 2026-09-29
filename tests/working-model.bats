#!/usr/bin/env bats
load helpers
@test "sections referenced by hooks exist" {
  for s in '## §1' '## §2' '## §3' '## §4' '## §5' '## §6'; do grep -q "^$s" "$MK_REPO/WORKING-MODEL.md"; done
}
@test "session start injects the working model" {
  mk_project; run_hook session-start.sh '{}'; ctx | grep -q 'Measure, don'"'"'t assume'
}
@test "hook messages only cite existing sections" {
  for n in $(grep -oh 'WORKING-MODEL.md §[0-9]' "$HOOKS"/messages/*.sh | sort -u | sed 's/.*§//'); do
    grep -q "^## §$n" "$MK_REPO/WORKING-MODEL.md"
  done
}
