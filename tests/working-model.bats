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
@test "§2 defines the decision format" {
  sec="$(sed -n '/^## §2/,/^## §3/p' "$MK_REPO/WORKING-MODEL.md")"
  for s in '**Recommendation**' '**Stakes**' '**Reversibility**' 'one-way door' '**Options**' 'Completeness X/10'; do
    printf '%s' "$sec" | grep -qF "$s" || { echo "missing: $s"; false; }
  done
  grep -qF 'triage.md' "$MK_REPO/WORKING-MODEL.md"
}
@test "rule block points at the §2 format in both languages" {
  for l in en tr; do grep '^MK_T_IR_RULES_BASE=' "$HOOKS/messages/$l.sh" | grep -qF 'WORKING-MODEL.md §2' || { echo "$l"; false; }; done
}
