#!/usr/bin/env bats
load helpers
INIT() { "$MK_BASH" "$MK_REPO/skills/init/scripts/memokit-init.sh" "$@"; }
GIT() { git -C "$PROJ" -c user.email=t@t -c user.name=t "$@"; }
cfg_file() {
  cfg="$(mktemp "${BATS_TMPDIR:-/tmp}/mkcfg.XXXXXX")"
  printf '%s' '{"version":1,"project":{"name":"Acme","tag":"ABC"},"language":"en","guardedDirs":["src","tests"]}' > "$cfg"
}

@test "adopt: scripted end-to-end keeps other-tool files and hooks byte-identical" {
  mk_project none
  mkdir -p "$PROJ/.cursor/rules" "$PROJ/.claude/agents" "$PROJ/scripts"
  printf '# Acme\n\nA shop backend.\n\n## Commands\n- npm test\n' > "$PROJ/CLAUDE.md"
  printf 'commit straight to main\n' > "$PROJ/AGENTS.md"
  printf -- '---\nglobs: src/**/*.ts\n---\nUse strict types.\n' > "$PROJ/.cursor/rules/x.mdc"
  printf -- '---\nname: dev\n---\nWrite code in src.\n' > "$PROJ/.claude/agents/dev.md"
  printf '#!/bin/sh\necho remind\n' > "$PROJ/scripts/remind.sh"
  printf '%s' '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"prettier --write ."}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"scripts/remind.sh"}]}]}}' > "$PROJ/.claude/settings.json"
  GIT add -A; GIT commit -qm fixture
  cp "$PROJ/AGENTS.md" "$BATS_TMPDIR/agents.before"; cp "$PROJ/.cursor/rules/x.mdc" "$BATS_TMPDIR/x.before"
  head_before="$(git -C "$PROJ" rev-parse HEAD)"

  run INIT inventory "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.adoptable == true and .legacy == null'
  run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.aiSetup == true and .inventoryError == false'

  cfg_file
  run INIT write-config "$PROJ" "$cfg"; [ "$status" -eq 0 ]
  run INIT scaffold "$PROJ" en; [ "$status" -eq 0 ]
  printf 'Use strict types. (source: .cursor/rules/x.mdc)\n' > "$PROJ/.claude/memokit/rules.md"
  mkdir -p "$PROJ/.claude/rules"
  printf -- '---\npaths:\n  - "src/**/*.ts"\n---\nUse strict types. (source: .cursor/rules/x.mdc)\n' > "$PROJ/.claude/rules/x.md"
  printf '## Tier 1\n- npm test\n' > "$PROJ/.claude/memokit/gates.md"
  printf 'Write code in src.\n' > "$PROJ/.claude/memokit/coder.md"
  printf '# Acme\n\n@AGENTS.md\n\nIn this project these AGENTS.md items do not apply to Claude: committing straight to main (memokit WORKING-MODEL §1).\n\nA shop backend.\n' > "$PROJ/CLAUDE.md"

  run INIT settings "$PROJ" --drop-hook UserPromptSubmit remind.sh; [ "$status" -eq 0 ]
  run INIT remove "$PROJ" .claude/agents/dev.md; [ "$status" -eq 0 ]

  cmp "$PROJ/AGENTS.md" "$BATS_TMPDIR/agents.before"
  cmp "$PROJ/.cursor/rules/x.mdc" "$BATS_TMPDIR/x.before"
  jq -e '[.hooks.PostToolUse[].hooks[].command] | any(test("prettier"))' "$PROJ/.claude/settings.json"
  [ "$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?.command] | any(test("remind.sh"))' "$PROJ/.claude/settings.json")" = false ]
  jq -e '.enabledPlugins == null and .extraKnownMarketplaces == null' "$PROJ/.claude/settings.json"   # Team said no: no registration
  [ "$(git -C "$PROJ" diff --cached --name-status -- .claude/agents/dev.md)" = "D	.claude/agents/dev.md" ]
  jq -e . "$PROJ/.claude/memokit.json"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$head_before" ]
  st="$(git -C "$PROJ" status --porcelain)"
  for kept in AGENTS.md .cursor/rules/x.mdc scripts/remind.sh; do
    ! printf '%s\n' "$st" | grep -qF -- "$kept" || { echo "kept path changed: $kept"; false; }
  done
}

@test "adopt: real legacy project follows the SKILL order end to end" {
  legacy_project
  printf -- '---\nname: explorer\n---\nline one\nline two\n' > "$PROJ/.claude/agents/explorer.md"
  GIT add -A; GIT commit -qm explorer
  head_before="$(git -C "$PROJ" rev-parse HEAD)"
  run INIT inventory "$PROJ"; [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.legacy != null and .legacy.tag == "ABC"'

  cfg_file
  run INIT write-config "$PROJ" "$cfg"; [ "$status" -eq 0 ]
  run INIT scaffold "$PROJ" en; [ "$status" -eq 0 ]
  printf 'PROJECT-RULE\n' > "$PROJ/.claude/memokit/rules.md"
  printf 'coder overlay\n' > "$PROJ/.claude/memokit/coder.md"
  # An edit under a legacy path BEFORE remove-legacy makes it refuse (exit 4):
  # the SKILL therefore orders such edits after 7.3.
  printf 'line one\n' > "$PROJ/.claude/agents/explorer.md.new"; mv "$PROJ/.claude/agents/explorer.md.new" "$PROJ/.claude/agents/explorer.md"
  run INIT remove-legacy "$PROJ"; [ "$status" -eq 4 ]
  git -C "$PROJ" checkout -q -- .claude/agents/explorer.md
  run INIT remove-legacy "$PROJ"
  [ "$status" -eq 0 ] || { echo "remove-legacy: $status $output"; false; }
  run INIT settings "$PROJ"; [ "$status" -eq 0 ]
  # Edit of the kept Claude-owned original happens after remove-legacy.
  printf -- '---\nname: explorer\n---\nline one\n' > "$PROJ/.claude/agents/explorer.md"
  [ -f "$PROJ/.claude/agents/explorer.md" ]
  git -C "$PROJ" status --porcelain | grep -q 'explorer.md'

  [ ! -d "$PROJ/.claude/hooks" ]; [ ! -f "$PROJ/.claude/agents/coder.md" ]; [ ! -d "$PROJ/.claude/skills/handoff" ]
  [ -f "$PROJ/.claude/memokit/rules.md" ]
  jq -e '.enabledPlugins["memokit@memokit"]' "$PROJ/.claude/settings.json"
  jq -e '(.hooks // {}) | has("Stop") | not' "$PROJ/.claude/settings.json"
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$head_before" ]
}
