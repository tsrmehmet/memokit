#!/usr/bin/env bats
load helpers
@test "sections referenced by hooks exist" {
  for s in '## §1' '## §2' '## §3' '## §4' '## §5' '## §6' '## §7'; do grep -q "^$s" "$MK_REPO/WORKING-MODEL.md"; done
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
@test "§7 exists and the rule block cites it in both languages" {
  grep -q '^## §7' "$MK_REPO/WORKING-MODEL.md"
  for l in en tr; do grep '^MK_T_IR_RULES_BASE=' "$HOOKS/messages/$l.sh" | grep -qF 'WORKING-MODEL.md §7' || { echo "$l"; false; }; done
}
@test "§8 and §9 exist and the rule block cites §9 in both languages" {
  grep -q '^## §8 Design quality' "$MK_REPO/WORKING-MODEL.md"
  grep -q '^## §9 Test tiers' "$MK_REPO/WORKING-MODEL.md"
  for l in en tr; do grep '^MK_T_IR_RULES_BASE=' "$HOOKS/messages/$l.sh" | grep -qF 'WORKING-MODEL.md §9' || { echo "$l"; false; }; done
}
@test "§8 states the pragmatic SOLID/KISS/YAGNI balance" {
  sec="$(sed -n '/^## §8/,/^## §9/p' "$MK_REPO/WORKING-MODEL.md")"
  for w in SOLID KISS YAGNI 'second real use' 'docs/PATTERNS.md'; do printf '%s' "$sec" | grep -qF "$w" || { echo "$w"; false; }; done
}
@test "§9 states tiers, approval question, gate-pending and gates.md" {
  sec="$(sed -n '/^## §9/,$p' "$MK_REPO/WORKING-MODEL.md")"
  for w in 'Tier 1' 'Tier 2' 'Tier-2 gates next, or more work first?' 'gate-pending' '.claude/memokit/gates.md' 'never guess'; do printf '%s' "$sec" | grep -qF "$w" || { echo "$w"; false; }; done
}
@test "final M5: overlays cannot loosen any section" {
  grep -F '## §5' -A2 "$MK_REPO/WORKING-MODEL.md" | grep -qF 'They cannot loosen §1–§9.'
}
