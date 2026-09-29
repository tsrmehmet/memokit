#!/usr/bin/env bats
load helpers
INIT() { "$MK_BASH" "$MK_REPO/skills/init/scripts/memokit-init.sh" "$@"; }
legacy_project() {
  mk_project none; mkdir -p "$PROJ/.claude/hooks" "$PROJ/.claude/agents" "$PROJ/.claude/skills/handoff"
  cp "$MK_REPO"/tests/fixtures/legacy/*.sh "$PROJ/.claude/hooks/"
  printf 'x' > "$PROJ/.claude/agents/coder.md"; printf 'x' > "$PROJ/.claude/skills/handoff/SKILL.md"
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR/.claude/hooks/check-state-stale.sh\""}]}]}}' > "$PROJ/.claude/settings.json"
  git -C "$PROJ" -c user.email=t@t -c user.name=t add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm legacy
  # extract-legacy compares vendored skills against $HOME/.claude/skills: never the real one.
  export HOME="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkhome.XXXXXX")"
}
@test "extract-legacy proposal" {
  legacy_project
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.tag=="ABC" and .name=="Acme" and .guardedDirs==["src","tests","web"] and .contextLimit==250000 and .maxCommitsBehind==null'
  printf '%s' "$output" | jq -e '.docsRaw == "CLAUDE.md · Yol haritası: docs/ROADMAP.md."'
  printf '%s' "$output" | jq -e '.rulesRaw == "[ABC-KURAL] 1) x. 2) y."'
  printf '%s' "$output" | jq -e '.healthScript == null and .vendoredSkills == [] and .agents == ["coder.md"] and .skills == ["handoff"]'
  printf '%s' "$output" | jq -e '.hints | length == 2'
  printf '%s' "$output" | jq -e '[.hints[] | select(.covered)] | length == 1'
  printf '%s' "$output" | jq -e '.builtinCovered | index("debugging")'
}
@test "extract-legacy: healthScript when executable" {
  legacy_project; mkdir -p "$PROJ/scripts"; printf '#!/bin/sh\n' > "$PROJ/scripts/knowledge-health.sh"; chmod +x "$PROJ/scripts/knowledge-health.sh"
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.healthScript == "scripts/knowledge-health.sh"'
}
@test "extract-legacy: if-block hint form" {
  legacy_project; cp "$MK_REPO/tests/fixtures/legacy-ifblock/inject-rules.sh" "$PROJ/.claude/hooks/inject-rules.sh"
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hints | length == 2'
  printf '%s' "$output" | jq -e '.hints[0].match == "where|depends on|call graph" and .hints[0].covered'
  printf '%s' "$output" | jq -e '.hints[0].text | startswith("[SKILL] Code question -> graphify.")'
  printf '%s' "$output" | jq -e '.hints[1].match == "schema|migration" and (.hints[1].covered|not)'
  printf '%s' "$output" | jq -e '.builtinCovered == ["graphify"]'
}
@test "extract-legacy: vendored skill identical to HOME copy" {
  legacy_project
  mkdir -p "$PROJ/.claude/skills/same" "$PROJ/.claude/skills/differs" "$HOME/.claude/skills/same" "$HOME/.claude/skills/differs"
  printf 'a' > "$PROJ/.claude/skills/same/SKILL.md"; printf 'a' > "$HOME/.claude/skills/same/SKILL.md"
  printf 'a' > "$PROJ/.claude/skills/differs/SKILL.md"; printf 'b' > "$HOME/.claude/skills/differs/SKILL.md"
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.vendoredSkills == ["same"]'
}
@test "remove-legacy refuses when a legacy path is dirty" {
  # Each probe dirties exactly one legacy path; every one must refuse with 4
  # and leave the legacy hooks in place.
  for probe in 'echo x >> .claude/hooks/guard-edit.sh' 'echo x > .claude/hooks/new.sh' \
               'echo y >> .claude/agents/coder.md' 'echo z > .claude/skills/handoff/extra.md' \
               'echo "{}" > .claude/settings.json'; do
    legacy_project
    (cd "$PROJ" && eval "$probe")
    run INIT remove-legacy "$PROJ"
    [ "$status" -eq 4 ] || { echo "not refused: $probe (status $status)"; false; }
    [ -d "$PROJ/.claude/hooks" ] || { echo "hooks removed despite refusal: $probe"; false; }
  done
}
@test "remove-legacy ignores dirt outside the legacy paths" {
  legacy_project; echo x > "$PROJ/dirty"
  run INIT remove-legacy "$PROJ"; [ "$status" -eq 0 ]; [ ! -d "$PROJ/.claude/hooks" ]; [ -f "$PROJ/dirty" ]
}
@test "remove-legacy removes hooks, agents, skills and wiring only" {
  legacy_project
  head_before="$(git -C "$PROJ" rev-parse HEAD)"
  run INIT remove-legacy "$PROJ"; [ "$status" -eq 0 ]
  [ ! -d "$PROJ/.claude/hooks" ]; [ ! -f "$PROJ/.claude/agents/coder.md" ]; [ ! -d "$PROJ/.claude/skills/handoff" ]
  jq -e '(.hooks // {}) | length == 0' "$PROJ/.claude/settings.json"
  jq -e '.enabledPlugins["memokit@memokit"]' "$PROJ/.claude/settings.json"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$head_before" ]   # nothing committed by the script
}
@test "documented migration sequence completes end to end (SKILL.md steps 1-6)" {
  legacy_project
  printf '# Acme\n\n## Working model\nlegacy text\n\n## Project notes\nkeep me\n' > "$PROJ/CLAUDE.md"
  git -C "$PROJ" -c user.email=t@t -c user.name=t add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm claude-md
  head_before="$(git -C "$PROJ" rev-parse HEAD)"
  # step 1: extract-legacy
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  # steps 2-4: rules.md and overlay files
  mkdir -p "$PROJ/.claude/memokit"
  printf 'PROJECT-RULE\n' > "$PROJ/.claude/memokit/rules.md"
  printf 'coder overlay\n' > "$PROJ/.claude/memokit/coder.md"
  printf 'handoff overlay\n' > "$PROJ/.claude/memokit/handoff.md"
  # step 5: CLAUDE.md edit
  printf '# Acme\n\nSee WORKING-MODEL.md.\n\n## Project notes\nkeep me\n' > "$PROJ/CLAUDE.md"
  # step 6: write-config, then remove-legacy
  cfg="$(mktemp "${BATS_TMPDIR:-/tmp}/mkcfg.XXXXXX")"
  printf '%s' '{"version":1,"project":{"name":"Acme","tag":"ABC"},"language":"tr","guardedDirs":["src","tests","web"]}' > "$cfg"
  run INIT write-config "$PROJ" "$cfg"; [ "$status" -eq 0 ]
  run INIT remove-legacy "$PROJ"
  [ "$status" -eq 0 ] || { echo "remove-legacy: status $status: $output"; false; }
  [ ! -d "$PROJ/.claude/hooks" ]; [ ! -f "$PROJ/.claude/agents/coder.md" ]; [ ! -d "$PROJ/.claude/skills/handoff" ]
  [ -f "$PROJ/.claude/memokit.json" ]; [ -f "$PROJ/.claude/memokit/rules.md" ]; [ -f "$PROJ/.claude/memokit/handoff.md" ]
  grep -q 'See WORKING-MODEL.md.' "$PROJ/CLAUDE.md"
  jq -e '.enabledPlugins["memokit@memokit"]' "$PROJ/.claude/settings.json"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$head_before" ]   # nothing committed by the script
}
@test "extract-legacy: multi-line RULES with escaped single quote" {
  legacy_project; cp "$MK_REPO/tests/fixtures/legacy-multiline/inject-rules.sh" "$PROJ/.claude/hooks/inject-rules.sh"
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.rulesRaw == "[XYZ-KURAL] 1) a.\n2) it'"'"'s b.\n3) c."'
  printf '%s' "$output" | jq -e '.tag == "XYZ"'
}
@test "extract-legacy: escaped double quotes in hint text (pair and if-block forms)" {
  legacy_project; cp "$MK_REPO/tests/fixtures/legacy-quotes/inject-rules.sh" "$PROJ/.claude/hooks/inject-rules.sh"
  run INIT extract-legacy "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hints[0].text == "[SKILL] uses \"quoted\" word -> x."'
  printf '%s' "$output" | jq -e '.hints[1].text == "[SKILL] block \"q\" -> graphify."'
}
