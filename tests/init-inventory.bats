#!/usr/bin/env bats
load helpers
INIT() { "$MK_BASH" "$MK_REPO/skills/init/scripts/memokit-init.sh" "$@"; }

put() { mkdir -p "$(dirname "$PROJ/$1")"; printf '%s' "${2:-x}" > "$PROJ/$1"; }
inv() { run INIT inventory "$PROJ"; [ "$status" -eq 0 ]; }
# src PATH JQ-EXPR -- assert on the entry for PATH
src() { printf '%s' "$output" | jq -e --arg p "$1" ".sources[] | select(.path == \$p) | $2" >/dev/null; }

@test "inventory: bare repo has no sources and is not adoptable" {
  mk_project none; inv
  printf '%s' "$output" | jq -e '.sources == [] and .adoptable == false and .hooks == [] and .legacy == null and .settingsError == false'
}

@test "inventory: groups and tools for one file per group" {
  mk_project none
  put CLAUDE.md; put CLAUDE.local.md; put AGENTS.md; put .cursor/rules/a.mdc
  put .github/copilot-instructions.md; put docs/superpowers/specs/x.md; put .mcp.json
  inv
  src CLAUDE.md '.group == "claude" and .tool == "claude-code" and .kind == "file"'
  src CLAUDE.local.md '.group == "personal" and .tool == "claude-code"'
  src AGENTS.md '.group == "shared" and .tool == "agents-md"'
  src .cursor/rules/a.mdc '.group == "other" and .tool == "cursor"'
  src .github/copilot-instructions.md '.group == "other" and .tool == "copilot"'
  src docs/superpowers '.group == "framework" and .tool == "superpowers" and .kind == "dir" and .bytes == null'
  src .mcp.json '.group == "aux" and .tool == "mcp"'
  printf '%s' "$output" | jq -e '.adoptable == true'
}

@test "inventory: remaining table paths are classified" {
  mk_project none
  put .claude/CLAUDE.md; put .claude/rules/sub/r.md; put .claude/agents/a.md; put .claude/commands/c.md
  put .claude/skills/s/SKILL.md; put .claude/skills/s/deep/SKILL.md; put .claude/hooks/h.sh
  put .claude/settings.local.json; put .claude/output-styles/o.md; put .claude/AGENTS.md
  put .cursorrules; put .github/instructions/b.instructions.md; put .github/agents/x.agent.md
  put .github/prompts/p.prompt.md; put .windsurfrules; put .windsurf/rules/w.md; put .devin/rules/d.md
  put .cline/rules/c.md; put .roo/rules-code/sub/r.md; put .roorules; put .roomodes
  put GEMINI.md; put AGENTS.override.md; put .kiro/steering/k.md; put .continue/rules/c.md
  put .junie/guidelines.md; put .junie/AGENTS.md; put .rules; put CONVENTIONS.md; put .aider.conf.yml
  put .specify/x; put _bmad/x; put _bmad-output/x; put .bmad-core/x; put .taskmaster/x; put openspec/x; put .planning/x
  put .clinerules/one.md
  inv
  src .claude/CLAUDE.md '.group == "claude"'
  src .claude/rules/sub/r.md '.group == "claude"'
  src .claude/agents/a.md '.group == "claude"'
  src .claude/commands/c.md '.group == "claude"'
  src .claude/skills/s/SKILL.md '.group == "claude"'
  src .claude/hooks '.group == "claude" and .kind == "dir"'
  src .claude/settings.local.json '.group == "personal"'
  src .claude/output-styles/o.md '.group == "aux"'
  src .claude/AGENTS.md '.group == "shared"'
  src .cursorrules '.tool == "cursor"'
  src .github/instructions/b.instructions.md '.tool == "copilot"'
  src .github/agents/x.agent.md '.tool == "copilot"'
  src .github/prompts/p.prompt.md '.tool == "copilot"'
  src .windsurfrules '.tool == "windsurf"'
  src .windsurf/rules/w.md '.tool == "windsurf"'
  src .devin/rules/d.md '.tool == "devin"'
  src .clinerules/one.md '.tool == "cline"'
  src .cline/rules/c.md '.tool == "cline"'
  src .roo/rules-code/sub/r.md '.tool == "roo"'
  src .roorules '.tool == "roo"'
  src .roomodes '.tool == "roo"'
  src GEMINI.md '.tool == "gemini"'
  src AGENTS.override.md '.tool == "codex" and .group == "other"'
  src .kiro/steering/k.md '.tool == "kiro"'
  src .continue/rules/c.md '.tool == "continue"'
  src .junie/guidelines.md '.tool == "junie"'
  src .junie/AGENTS.md '.tool == "junie" and .group == "other"'
  src .rules '.tool == "zed"'
  src CONVENTIONS.md '.tool == "aider"'
  src .aider.conf.yml '.tool == "aider"'
  src .specify '.tool == "spec-kit" and .group == "framework"'
  src _bmad '.tool == "bmad"'
  src _bmad-output '.tool == "bmad"'
  src .bmad-core '.tool == "bmad"'
  src .taskmaster '.tool == "taskmaster"'
  src openspec '.tool == "openspec"'
  src .planning '.tool == "gsd"'
  # too deep for .claude/skills/*/SKILL.md
  run bash -c 'printf "%s" "$1" | jq -e "[.sources[] | select(.path == \".claude/skills/s/deep/SKILL.md\")] | length == 0"' _ "$output"
  [ "$status" -eq 0 ]
}

@test "inventory: frontmatter keys" {
  mk_project none
  put .cursor/rules/a.mdc $'---\ndescription: API\nglobs: src/**/*.ts, lib/*.ts\nalwaysApply: false\nother: no\n---\nbody'
  put .github/instructions/b.instructions.md $'---\napplyTo: "**/*.cs"\n---\nbody'
  inv
  src .cursor/rules/a.mdc '.frontmatter.globs == "src/**/*.ts, lib/*.ts" and .frontmatter.alwaysApply == "false" and .frontmatter.description == "API" and (.frontmatter | has("other") | not)'
  src .github/instructions/b.instructions.md '.frontmatter.applyTo == "**/*.cs"'
}

@test "inventory: YAML list frontmatter is joined" {
  mk_project none
  put .claude/rules/r.md $'---\npaths:\n  - "src/**"\n  - "tests/**"\n---\nbody'
  inv
  src .claude/rules/r.md '.frontmatter.paths == "src/**,tests/**"'
}

@test "inventory: broken frontmatter does not crash" {
  mk_project none
  put .claude/rules/open.md $'---\nname: x\nno closing line'
  put .claude/rules/crlf.md $'---\r\nname: crlf\r\ndescription: hi\r\n---\r\nbody'
  inv
  src .claude/rules/open.md '.frontmatter == {}'
  src .claude/rules/crlf.md '.frontmatter.name == "crlf" and .frontmatter.description == "hi"'
}

@test "inventory: tracked and ignored flags" {
  mk_project none
  put .claude/agents/dev.md
  git -C "$PROJ" -c user.email=t@t -c user.name=t add -A
  git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm agents
  printf '.claude/commands/\n' > "$PROJ/.gitignore"
  put .claude/commands/x.md
  inv
  src .claude/agents/dev.md '.tracked == true and .ignored == false'
  src .claude/commands/x.md '.tracked == false and .ignored == true'
}

@test "inventory: outside git both flags are false" {
  PROJ="$(mktemp -d "${BATS_TMPDIR:-/tmp}/nogit.XXXXXX")"
  put CLAUDE.md
  inv
  src CLAUDE.md '.tracked == false and .ignored == false'
}

@test "inventory: symlinks recorded, dangling and looping links do not fail" {
  mk_project none
  put AGENTS.md
  ln -s AGENTS.md "$PROJ/CLAUDE.md"
  ln -s nope.md "$PROJ/GEMINI.md"
  ln -s b "$PROJ/.cursorrules"; ln -s .cursorrules "$PROJ/b"
  inv
  src CLAUDE.md '.linkTarget == "AGENTS.md"'
  src AGENTS.md '.linkTarget == null'
  src GEMINI.md '.linkTarget == "nope.md"'
  src .cursorrules '.linkTarget == "b"'
}

@test "inventory: nested files found, pruned dirs skipped" {
  mk_project none
  put pkg/api/CLAUDE.md; put node_modules/x/CLAUDE.md; put .claude/worktrees/w/AGENTS.md
  put vendor/v/GEMINI.md; put src/build/CLAUDE.md; put a/worktrees/AGENTS.md; put .git-not/CLAUDE.md
  put pkg/api/CONVENTIONS.md
  inv
  src pkg/api/CLAUDE.md '.group == "claude"'
  src .git-not/CLAUDE.md '.group == "claude"'
  run bash -c 'printf "%s" "$1" | jq -e "[.sources[].path] | map(select(test(\"node_modules|worktrees|vendor|build|CONVENTIONS\"))) | length == 0"' _ "$output"
  [ "$status" -eq 0 ]
}

@test "inventory: paths with spaces and unicode round-trip" {
  mk_project none
  put ".cursor/rules/api rules.mdc"; put "docs/ÖZEL/AGENTS.md"
  inv
  printf '%s' "$output" | jq -e .
  src ".cursor/rules/api rules.mdc" '.tool == "cursor"'
  src "docs/ÖZEL/AGENTS.md" '.group == "shared"'
}

@test "inventory: writes nothing" {
  mk_project none
  put CLAUDE.md; put .cursor/rules/a.mdc $'---\nglobs: a\n---\n'
  before="$(git -C "$PROJ" status --porcelain)"
  stamp="$(mktemp "${BATS_TMPDIR:-/tmp}/stamp.XXXXXX")"
  inv
  [ -z "$(find "$PROJ" -newer "$stamp")" ]
  [ "$(git -C "$PROJ" status --porcelain)" = "$before" ]
}

@test "inventory: bad root exits 2" {
  run INIT inventory /nonexistent/dir
  [ "$status" -eq 2 ]
  run INIT inventory
  [ "$status" -eq 2 ]
}

@test "inventory: single-level locations do not match deeper paths" {
  mk_project none
  for f in .windsurf/rules .devin/rules .kiro/steering .continue/rules .cline/rules .clinerules; do put "$f/sub/deep.md"; done
  put .github/agents/sub/x.agent.md; put .github/prompts/sub/p.prompt.md; put .claude/output-styles/sub/o.md
  put .windsurf/rules/ok.md
  inv
  src .windsurf/rules/ok.md '.tool == "windsurf"'
  [ "$(printf '%s' "$output" | jq '.sources | length')" -eq 1 ]
}

@test "inventory: symlinked directories at table locations are listed, not followed" {
  mk_project none
  mkdir -p "$PROJ/.agents/skills/foo" "$PROJ/shared/rules" "$PROJ/.claude/skills"
  put .agents/skills/foo/SKILL.md; put shared/rules/r.md
  ln -s ../../.agents/skills/foo "$PROJ/.claude/skills/foo"
  ln -s ../shared/rules "$PROJ/.claude/rules"
  ln -s . "$PROJ/.claude/commands"   # loop
  inv
  src .claude/skills/foo '.kind == "dir" and .group == "claude" and .tool == "claude-code" and .linkTarget == "../../.agents/skills/foo" and .bytes == null and .frontmatter == {}'
  src .claude/rules '.kind == "dir" and .group == "claude" and .linkTarget == "../shared/rules"'
  src .claude/commands '.kind == "dir" and .linkTarget == "."'
  [ "$(printf '%s' "$output" | jq '[.sources[] | select(.path | startswith(".claude/rules/"))] | length')" -eq 0 ]
}

@test "inventory: cost does not grow with repo size" {
  mk_project none
  mkdir -p "$PROJ/big"
  seq 1 6000 | (cd "$PROJ/big" && xargs touch)
  put CLAUDE.md
  s=$SECONDS
  inv
  [ $((SECONDS - s)) -le 2 ]
  src CLAUDE.md '.group == "claude"'
}

@test "inventory: whole-dir link .claude/skills is listed, deeper links are not" {
  mk_project none
  mkdir -p "$PROJ/.agents/skills/foo" "$PROJ/shared" "$PROJ/.claude2/skills/foo"
  put .agents/skills/foo/SKILL.md
  ln -s ../.agents/skills "$PROJ/.claude/skills"
  inv
  src .claude/skills '.kind == "dir" and .group == "claude" and .linkTarget == "../.agents/skills"'
  rm "$PROJ/.claude/skills"; mkdir -p "$PROJ/.claude/skills/foo"
  ln -s ../../../shared "$PROJ/.claude/skills/foo/references"
  inv
  [ "$(printf '%s' "$output" | jq '.sources | length')" -eq 0 ]
}

@test "inventory: nested basenames match at any depth under single-level dirs" {
  mk_project none
  put .github/agents/sub/AGENTS.md; put .windsurf/rules/sub/CLAUDE.md
  inv
  src .github/agents/sub/AGENTS.md '.group == "shared"'
  src .windsurf/rules/sub/CLAUDE.md '.group == "claude"'
}

@test "inventory: settings hooks listed with scriptPath and injectsContext" {
  mk_project none
  put scripts/remind.sh '#!/bin/sh'
  put .claude/settings.json '{"hooks":{"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"npx prettier --write"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR/scripts/remind.sh\""},{"type":"prompt","prompt":"hi"}]}],"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/scripts/remind.sh"},{"type":"command","command":"$CLAUDE_PROJECT_DIR/../x.sh"},{"type":"command","command":"/etc/passwd"}]}]}}'
  inv
  printf '%s' "$output" | jq -e '.hooks | length == 6'
  printf '%s' "$output" | jq -e '.hooks[] | select(.event == "PostToolUse") | .matcher == "Edit" and .command == "npx prettier --write" and .scriptPath == null and .injectsContext == false and .legacy == false'
  printf '%s' "$output" | jq -e '.hooks[] | select(.event == "UserPromptSubmit" and .type == "command") | .matcher == null and .scriptPath == "scripts/remind.sh" and .injectsContext == true'
  printf '%s' "$output" | jq -e '[.hooks[] | select(.event == "Stop") | .scriptPath] == ["scripts/remind.sh", null, null]'
  printf '%s' "$output" | jq -e '.hooks[] | select(.type == "prompt") | .event == "UserPromptSubmit" and .command == null and .scriptPath == null and .legacy == false and .injectsContext == true'
  printf '%s' "$output" | jq -e '[.hooks[] | select(.type == "command")] | length == 5'
  printf '%s' "$output" | jq -e '.adoptable == true and .settingsError == false'
}

@test "inventory: settingsTracked/settingsIgnored for tracked, ignored and absent settings.json" {
  mk_project none
  inv
  printf '%s' "$output" | jq -e '.settingsTracked == false and .settingsIgnored == false'
  put .claude/settings.json '{}'
  inv
  printf '%s' "$output" | jq -e '.settingsTracked == false and .settingsIgnored == false'
  git -C "$PROJ" add .claude/settings.json
  inv
  printf '%s' "$output" | jq -e '.settingsTracked == true and .settingsIgnored == false'
  git -C "$PROJ" rm -q --cached .claude/settings.json
  printf '.claude/\n' > "$PROJ/.gitignore"
  inv
  printf '%s' "$output" | jq -e '.settingsTracked == false and .settingsIgnored == true'
}

@test "inventory: legacy hook entries flagged and legacy extract embedded" {
  legacy_project
  inv
  printf '%s' "$output" | jq -e '.legacy.tag != null'
  printf '%s' "$output" | jq -e '.hooks[] | select(.command | contains(".claude/hooks/")) | .legacy == true and .scriptPath == ".claude/hooks/check-state-stale.sh"'
}

@test "inventory: invalid settings.json" {
  mk_project none
  printf '{bad' > "$PROJ/.claude/settings.json"
  inv
  printf '%s' "$output" | jq -e '.settingsError == true and .hooks == []'
}

@test "inventory: non-object settings.json is a settings error" {
  local v
  for v in '[]' '"x"' '1'; do
    mk_project none
    printf '%s' "$v" > "$PROJ/.claude/settings.json"
    inv
    printf '%s' "$output" | jq -e '.settingsError == true and .hooks == []'
  done
}

@test "inventory: project's own .claude/hooks is not memokit legacy" {
  mk_project none
  put .claude/hooks/fmt.sh '#!/bin/sh'
  put .claude/settings.json '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"./.claude/hooks/fmt.sh x"}]}]}}'
  inv
  printf '%s' "$output" | jq -e '.legacy == null and .adoptable == true'
  printf '%s' "$output" | jq -e '.hooks[0] | .legacy == false and .scriptPath == ".claude/hooks/fmt.sh"'
}

@test "inventory: symlinked script and symlinked dir are not inside the root" {
  mk_project none
  mkdir -p "$PROJ/scripts"; ln -s /etc/hosts "$PROJ/scripts/remind.sh"
  ln -s /etc "$PROJ/etcdir"
  put .claude/settings.json '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"scripts/remind.sh"},{"type":"command","command":"etcdir/hosts"}]}]}}'
  inv
  printf '%s' "$output" | jq -e '[.hooks[].scriptPath] == [null, null]'
}
