#!/usr/bin/env bats
load helpers
fm() { sed -n '/^---$/,/^---$/p' "$MK_REPO/agents/$1.md"; }
@test "coder frontmatter" { fm coder | grep -q '^name: coder$'; fm coder | grep -q '^model: sonnet$'; }
@test "reviewer frontmatter" { fm reviewer | grep -q '^name: reviewer$'; fm reviewer | grep -q '^model: opus$'; }
@test "both read overlays and report it" {
  for a in coder reviewer; do
    grep -q ".claude/memokit/$a.md" "$MK_REPO/agents/$a.md"
    grep -q 'Okunan ek dosya' "$MK_REPO/agents/$a.md"
    grep -q 'WORKING-MODEL.md §3' "$MK_REPO/agents/$a.md"
  done
}
@test "no project-specific rules" {
  run grep -Eqi 'ROADMAP|KVKK|mockup|/api/v1|secret/' "$MK_REPO/agents/coder.md" "$MK_REPO/agents/reviewer.md"
  [ "$status" -ne 0 ]
}
GATE_DESC='Only in projects that have .claude/memokit.json — '
GATE_STEP='If `.claude/memokit.json` does not exist in the project root, stop'
@test "agents are gated on .claude/memokit.json: description prefix and step 0 before the first step" {
  for a in coder reviewer; do
    f="$MK_REPO/agents/$a.md"
    fm "$a" | grep -qF "description: $GATE_DESC" || { echo "$a: description not gated"; false; }
    g="$(grep -nF "$GATE_STEP" "$f" | head -n1 | cut -d: -f1)"
    s="$(grep -n '^## First step' "$f" | head -n1 | cut -d: -f1)"
    [ -n "$g" ] || { echo "$a: no step 0 gate"; false; }
    [ "$g" -lt "$s" ] || { echo "$a: gate after first step"; false; }
  done
}
