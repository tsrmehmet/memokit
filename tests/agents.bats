#!/usr/bin/env bats
load helpers
fm() { sed -n '/^---$/,/^---$/p' "$MK_REPO/agents/$1.md"; }
@test "coder frontmatter" { fm coder | grep -q '^name: coder$'; fm coder | grep -q '^model: sonnet$'; }
@test "reviewer frontmatter" { fm reviewer | grep -q '^name: reviewer$'; fm reviewer | grep -q '^model: opus$'; }
@test "all agents read overlays and report it" {
  for a in coder reviewer analyst; do
    grep -q ".claude/memokit/$a.md" "$MK_REPO/agents/$a.md"
    grep -q 'Okunan ek dosya' "$MK_REPO/agents/$a.md"
    grep -q 'WORKING-MODEL.md §3' "$MK_REPO/agents/$a.md"
  done
}
@test "no project-specific rules" {
  run grep -Eqi 'ROADMAP|KVKK|mockup|/api/v1|secret/' "$MK_REPO/agents/coder.md" "$MK_REPO/agents/reviewer.md" "$MK_REPO/agents/analyst.md"
  [ "$status" -ne 0 ]
}
GATE_DESC='Only in projects that have .claude/memokit.json — '
GATE_STEP='If `.claude/memokit.json` does not exist in the project root, stop'
@test "agents are gated on .claude/memokit.json: description prefix and step 0 before the first step" {
  for a in coder reviewer analyst; do
    f="$MK_REPO/agents/$a.md"
    fm "$a" | grep -qF "description: $GATE_DESC" || { echo "$a: description not gated"; false; }
    g="$(grep -nF "$GATE_STEP" "$f" | head -n1 | cut -d: -f1)"
    s="$(grep -n '^## First step' "$f" | head -n1 | cut -d: -f1)"
    [ -n "$g" ] || { echo "$a: no step 0 gate"; false; }
    [ "$g" -lt "$s" ] || { echo "$a: gate after first step"; false; }
  done
}
@test "bugfix slices are red before green" {
  grep -qF 'Red before green' "$MK_REPO/agents/reviewer.md"
  grep -qF 'red output' "$MK_REPO/agents/coder.md"
  grep -qF 'WORKING-MODEL.md §2' "$MK_REPO/agents/coder.md"
}
@test "both agents point to §7" {
  for a in coder reviewer; do grep -qF 'Temp space (WORKING-MODEL.md §7)' "$MK_REPO/agents/$a.md" || { echo "$a"; false; }; done
  grep -qF 'mutation' "$MK_REPO/agents/reviewer.md"
}
@test "analyst frontmatter" { fm analyst | grep -q '^name: analyst$'; fm analyst | grep -q '^model: sonnet$'; }
@test "analyst reads its overlay and CLAUDE.md in the first step" {
  sec="$(sed -n '/^## First step/,/^## /p' "$MK_REPO/agents/analyst.md")"
  printf '%s' "$sec" | grep -qF '.claude/memokit/analyst.md'
  printf '%s' "$sec" | grep -qF 'CLAUDE.md'
}
@test "analyst is read-only" {
  f="$MK_REPO/agents/analyst.md"
  for w in 'Read-only' 'No Edit' 'no Write' 'no git write commands' 'no package installs' 'no test runs' 'Never decide for the user'; do
    grep -qF "$w" "$f" || { echo "missing: $w"; false; }
  done
}
@test "analyst report fields" {
  f="$MK_REPO/agents/analyst.md"
  for w in '`touches:`' '`depends_on:`' '`risk: high|normal`' '`questions:`' 'WORKING-MODEL.md §2' 'gates.md missing'; do
    grep -qF "$w" "$f" || { echo "missing: $w"; false; }
  done
  for w in security authorization 'tenant isolation' 'personal data' migrations concurrency 'shared libraries' 'cross-service contracts' 'guard/hook code'; do
    grep -qF "$w" "$f" || { echo "risk category missing: $w"; false; }
  done
}
@test "coder returns DONE, NEEDS_DECISION or BLOCKED" {
  f="$MK_REPO/agents/coder.md"
  grep -qF 'Status: DONE | NEEDS_DECISION | BLOCKED' "$f"
  grep -F 'NEEDS_DECISION' "$f" | grep -qF 'exactly one question'
  grep -qF 'lane id and task id' "$f"
  grep '^6\. ' "$f" | grep -qF 'NEEDS_DECISION'
}
@test "coder runs Tier 1 only, in the foreground; Tier 2 is the orchestrator's" {
  r3="$(grep '^3\. ' "$MK_REPO/agents/coder.md")"
  for w in 'Tier 1 only' 'WORKING-MODEL.md §9' 'build' 'unit tests of the touched projects' 'FOREGROUND' 'Never return `DONE` with a red Tier 1' 'report the current Tier-1 state as is' 'never run Tier 2' 'no Docker' 'Testcontainers' 'no integration' 'E2E' 'coverage' 'merge gate' 'explicit approval' 'orchestrator'; do
    printf '%s' "$r3" | grep -qF "$w" || { echo "rule 3 missing: $w"; false; }
  done
}
@test "coder's red-first step is not 'returning red'" {
  r9="$(grep '^9\. ' "$MK_REPO/agents/coder.md")"
  printf '%s' "$r9" | grep -qF 'deliberate'
}
@test "coder takes Tier 1 commands from gates.md and never asks the user when it is missing" {
  f="$MK_REPO/agents/coder.md"
  grep -qF '.claude/memokit/gates.md' "$f"
  grep -qF 'gates.md missing' "$f"
  grep -qF 'never ask the user' "$f"
}
@test "coder reports gate-pending, never done" {
  f="$MK_REPO/agents/coder.md"
  grep -qF 'Tier 1 green — gate-pending' "$f"
  grep -qF 'never claim "done"' "$f"
  run grep -niE '(slice|task|work) (is|as) done|counts as done' "$f"
  [ "$status" -ne 0 ]
}
@test "coder works only in the brief's working directory, no untracked files or secrets" {
  f="$MK_REPO/agents/coder.md"
  grep -qF 'working directory named in your brief' "$f"
  grep -qF 'untracked' "$f"
  grep -qF 'secrets' "$f"
}
@test "SOLID + KISS/YAGNI in coder and reviewer (§8)" {
  for a in coder reviewer; do
    l="$(grep -F 'SOLID' "$MK_REPO/agents/$a.md")"
    for w in KISS YAGNI 'WORKING-MODEL.md §8'; do printf '%s' "$l" | grep -qF "$w" || { echo "$a: $w"; false; }; done
  done
  grep -F 'SOLID' "$MK_REPO/agents/reviewer.md" | grep -qF 'over-engineering'
  grep -F 'SOLID' "$MK_REPO/agents/reviewer.md" | grep -qF 'file:line'
}
@test "reviewer on Sonnet escalates high-risk concerns" {
  f="$MK_REPO/agents/reviewer.md"
  grep -qF 'ESCALATE: opus — <reason>' "$f"
  grep -F 'ESCALATE' "$f" | grep -qF 'Sonnet'
}
@test "init templates include analyst and gates overlay skeletons" {
  t="$MK_REPO/skills/init/templates"
  grep -qF 'memokit:analyst' "$t/analyst.md"
  grep -qF 'cannot loosen it' "$t/analyst.md"
  for w in '## Tier 1' '## Tier 2' 'only after the user'; do grep -qF "$w" "$t/gates.md" || { echo "gates: $w"; false; }; done
}
@test "fix1 I2/I3: no fallback; gates.md missing or without Tier-1 command -> BLOCKED" {
  f="$MK_REPO/agents/coder.md"
  run grep -F 'test commands from `.claude/memokit/coder.md`' "$f"; [ "$status" -ne 0 ]
  grep '^3\. ' "$f" | grep -qF 'no Tier-1 command, return `BLOCKED` with `gates.md missing`'
  grep -qF 'no Tier-1 command' "$MK_REPO/agents/analyst.md"
}
@test "fix1 I4: reviewer runs only Tier-1 commands, never Tier 2" {
  r1="$(grep '^1\. ' "$MK_REPO/agents/reviewer.md")"
  for w in 'only Tier-1 commands from `.claude/memokit/gates.md`' 'never Tier 2' 'Docker' 'Testcontainers' 'E2E' 'merge gate'; do
    printf '%s' "$r1" | grep -qF "$w" || { echo "missing: $w"; false; }
  done
}
@test "fix1 I5/M3: analyst read-only covers MCP tools; status without locks" {
  f="$MK_REPO/agents/analyst.md"
  for w in 'every tool, MCP included' 'no ticket comments' 'transitions' 'design-tool edits' 'no messages' 'git --no-optional-locks status'; do
    grep -qF "$w" "$f" || { echo "missing: $w"; false; }
  done
}
@test "fix1 I6: overlays may arrive as text in the brief" {
  for a in coder reviewer analyst; do grep -qF "\`.claude/memokit/$a.md\` if it exists, or its text in your brief" "$MK_REPO/agents/$a.md" || { echo "$a"; false; }; done
  for a in coder analyst; do grep -qF '`.claude/memokit/gates.md` (or its text in your brief)' "$MK_REPO/agents/$a.md" || { echo "$a gates"; false; }; done
}
@test "fix1 minors: temp dir, optional lane id, ESCALATE instead of APPROVE, secret-free Tier 1, §5 list" {
  grep -qF 'except your §7 temp dir' "$MK_REPO/agents/coder.md"
  grep -qF 'lane id and task id from your brief (if given; never invent one)' "$MK_REPO/agents/coder.md"
  grep -F 'ESCALATE' "$MK_REPO/agents/reviewer.md" | grep -qF 'instead of `APPROVE`'
  grep -qF 'without secrets' "$MK_REPO/skills/init/templates/gates.md"
  sed -n '/^## §5/,/^## §6/p' "$MK_REPO/WORKING-MODEL.md" | grep -F '`analyst.md`' | grep -qF '`gates.md`'
}
@test "polish: overlay report line offers brief text; coder overlay holds no test commands" {
  for a in coder reviewer analyst; do
    grep -F '`Overlay read:`' "$MK_REPO/agents/$a.md" | grep -F '`brief text`' | grep -qF '`none (not present)`' || { echo "$a"; false; }
  done
  l="$(grep -F 'Read `.claude/memokit/coder.md`' "$MK_REPO/agents/coder.md")"
  run grep -F 'test commands and' <<<"$l"; [ "$status" -ne 0 ]
  grep -qF 'test commands live in `gates.md`' <<<"$l"
}
