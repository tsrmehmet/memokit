#!/usr/bin/env bats
load helpers
INIT() { "$MK_BASH" "$MK_REPO/skills/init/scripts/memokit-init.sh" "$@"; }

@test "detect: non-git" { d="$(mktemp -d)"; run INIT detect "$d"; printf '%s' "$output" | jq -e '.git == false'; }
@test "detect: dotnet + node stack, not configured" {
  mk_project none; touch "$PROJ/App.sln"; printf '{}' > "$PROJ/package.json"
  run INIT detect "$PROJ"
  printf '%s' "$output" | jq -e '.git and (.configured|not) and (.stack|index("dotnet")) and (.stack|index("node"))'
}
@test "detect: legacy" { mk_project none; mkdir -p "$PROJ/.claude/hooks"; run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.legacy'; }
@test "detect: aiSetup false for a bare repo and for framework/personal/aux-only repos" {
  mk_project none
  run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.aiSetup == false and .sources == 0'
  for f in docs/superpowers/plans/p.md CLAUDE.local.md .mcp.json; do
    mk_project none; mkdir -p "$PROJ/$(dirname "$f")"; printf 'x\n' > "$PROJ/$f"
    run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.aiSetup == false and .sources == 0'
  done
}
@test "detect: aiSetup true for a lone CLAUDE.md, an AGENTS.md, a Cursor rule, legacy hooks" {
  mk_project none; printf 'x\n' > "$PROJ/CLAUDE.md"
  run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.aiSetup == true and .sources == 1'
  for f in AGENTS.md .cursor/rules/a.mdc .claude/hooks/x.sh; do
    mk_project none; mkdir -p "$PROJ/$(dirname "$f")"; printf 'x\n' > "$PROJ/$f"
    run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.aiSetup == true and .sources >= 1'
  done
}
@test "detect: aiSetup survives non-git and invalid settings.json" {
  d="$(mktemp -d)"; printf 'x\n' > "$d/CLAUDE.md"
  run INIT detect "$d"; [ "$status" -eq 0 ]; printf '%s' "$output" | jq -e '.git == false and .aiSetup == true'
  mk_project none; printf '{bad' > "$PROJ/.claude/settings.json"
  run INIT detect "$PROJ"; [ "$status" -eq 0 ]; printf '%s' "$output" | jq -e 'has("aiSetup") and has("sources")'
}
@test "detect: inventoryError is false when inventory runs (true only on garbled output)" {
  mk_project none
  run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.inventoryError == false'
  printf 'x\n' > "$PROJ/CLAUDE.md"
  run INIT detect "$PROJ"; printf '%s' "$output" | jq -e '.inventoryError == false and .aiSetup == true'
}
@test "detect: inventoryError true when inventory cannot run" {
  run INIT detect /nonexistent-dir-memokit; printf '%s' "$output" | jq -e '.inventoryError == true and .aiSetup == false'
  [ "$(id -u)" -ne 0 ] || skip "root ignores file modes"
  d="$(mktemp -d)"; printf 'x\n' > "$d/AGENTS.md"; chmod 000 "$d/AGENTS.md"
  run INIT detect "$d"; chmod 600 "$d/AGENTS.md"
  printf '%s' "$output" | jq -e '.inventoryError == true and .aiSetup == false'
}
@test "write-config validates and refuses overwrite" {
  mk_project none; f="$(mktemp)"; printf '%s' "$DEFAULT_CONFIG" > "$f"
  run INIT write-config "$PROJ" "$f"; [ "$status" -eq 0 ]; jq -e '.project.tag == "DMO"' "$PROJ/.claude/memokit.json"
  run INIT write-config "$PROJ" "$f"; [ "$status" -eq 3 ]
  printf '{"version":1,"project":{"name":"x","tag":"bad"}}' > "$f"; rm "$PROJ/.claude/memokit.json"
  run INIT write-config "$PROJ" "$f"; [ "$status" -ne 0 ]; [ ! -f "$PROJ/.claude/memokit.json" ]
}
@test "scaffold never overwrites" {
  mk_project none; printf 'MINE' > "$PROJ/CLAUDE.md"
  run INIT scaffold "$PROJ" tr
  [ "$(cat "$PROJ/CLAUDE.md")" = "MINE" ]
  printf '%s' "$output" | grep -q 'kept CLAUDE.md'
  [ -f "$PROJ/docs/DECISIONS.md" ] && [ -f "$PROJ/.claude/memokit/coder.md" ]
  printf '%s' "$output" | grep -q 'kept docs/STATE.md'
}
@test "scaffold creates the analyst and gates overlay skeletons and keeps existing ones" {
  mk_project none; mkdir -p "$PROJ/.claude/memokit"; printf 'MINE' > "$PROJ/.claude/memokit/gates.md"
  run INIT scaffold "$PROJ" en; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qx 'created .claude/memokit/analyst.md'
  printf '%s' "$output" | grep -qx 'kept .claude/memokit/gates.md'
  [ "$(cat "$PROJ/.claude/memokit/gates.md")" = "MINE" ]
  cmp -s "$MK_REPO/skills/init/templates/analyst.md" "$PROJ/.claude/memokit/analyst.md"
  rm "$PROJ/.claude/memokit/gates.md"; run INIT scaffold "$PROJ" en
  printf '%s' "$output" | grep -qx 'created .claude/memokit/gates.md'
  grep -qF '## Tier 1' "$PROJ/.claude/memokit/gates.md"
}
@test "settings merge keeps other keys and drops legacy hooks" {
  mk_project none
  printf '%s' '{"permissions":{"allow":["Bash(git status)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR/.claude/hooks/x.sh\""}]}],"Notification":[{"hooks":[{"type":"command","command":"say hi"}]}]}}' > "$PROJ/.claude/settings.json"
  run INIT settings "$PROJ" --drop-legacy-hooks; [ "$status" -eq 0 ]
  jq -e '.permissions.allow[0] == "Bash(git status)"' "$PROJ/.claude/settings.json"
  jq -e '.enabledPlugins == null and .extraKnownMarketplaces == null' "$PROJ/.claude/settings.json"   # drop never registers
  jq -e '(.hooks.Stop // []) | length == 0' "$PROJ/.claude/settings.json"
  jq -e '.hooks.Notification | length == 1' "$PROJ/.claude/settings.json"
}
@test "settings creates .claude/settings.json when absent" {
  mk_project none
  run INIT settings "$PROJ"; [ "$status" -eq 0 ]
  jq -e '.enabledPlugins["memokit@memokit"] == true' "$PROJ/.claude/settings.json"
  jq -e '.extraKnownMarketplaces.memokit.source.repo == "tsrmehmet/memokit"' "$PROJ/.claude/settings.json"
}
@test "settings --drop-legacy-hooks without settings.json creates nothing" {
  mk_project none
  run INIT settings "$PROJ" --drop-legacy-hooks; [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.claude/settings.json" ]
}

# --- name substitution safety (sed metacharacters) ---

@test "scaffold substitutes a name containing sed metacharacters (& and /) safely" {
  mk_project none
  f="$(mktemp)"; printf '{"version":1,"project":{"name":"AT&T / Ops","tag":"ATT"},"language":"en"}' > "$f"
  run INIT write-config "$PROJ" "$f"; [ "$status" -eq 0 ]
  run INIT scaffold "$PROJ" en; [ "$status" -eq 0 ]
  grep -qF '# AT&T / Ops' "$PROJ/CLAUDE.md"
  lacks "$(cat "$PROJ/CLAUDE.md")" '{{NAME}}'
}

@test "scaffold refuses a name containing a pipe (sed delimiter) without writing partial files" {
  mk_project none
  f="$(mktemp)"; printf '{"version":1,"project":{"name":"Bad|Name","tag":"BAD"},"language":"en"}' > "$f"
  run INIT write-config "$PROJ" "$f"; [ "$status" -eq 0 ]
  run INIT scaffold "$PROJ" en
  [ "$status" -ne 0 ]
  [ ! -f "$PROJ/CLAUDE.md" ]
}

@test "scaffold treats dangling symlinks as existing" {
  mk_project none
  ln -s "/nonexistent/outside/path" "$PROJ/CLAUDE.md"
  [ -L "$PROJ/CLAUDE.md" ] && [ ! -e "$PROJ/CLAUDE.md" ]
  run INIT scaffold "$PROJ" tr; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'kept CLAUDE.md'
  [ -L "$PROJ/CLAUDE.md" ]
  [ ! -e "$PROJ/CLAUDE.md" ]
}

@test "write-config adds an empty careful.patterns when absent, keeps a given one" {
  mk_project none; f="$(mktemp)"; printf '%s' "$DEFAULT_CONFIG" > "$f"
  run INIT write-config "$PROJ" "$f"; [ "$status" -eq 0 ]
  jq -e '.careful.patterns == []' "$PROJ/.claude/memokit.json"
  rm "$PROJ/.claude/memokit.json"
  printf '{"version":1,"project":{"name":"D","tag":"DMO"},"careful":{"patterns":[{"match":"x","label":"y"}]}}' > "$f"
  run INIT write-config "$PROJ" "$f"; [ "$status" -eq 0 ]
  jq -e '.careful.patterns[0].label == "y"' "$PROJ/.claude/memokit.json"
}
@test "deny-tools merges bare tool names into settings.local.json, keeps other keys and ignores the file in git" {
  mk_project none
  printf '%s' '{"permissions":{"allow":["Bash(git status)"],"deny":["Workflow"]},"enabledPlugins":{"x@y":false}}' > "$PROJ/.claude/settings.local.json"
  # Claude Code puts **/.claude/settings.local.json in the user's global git
  # ignore; keep it out of this check.
  export GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$PROJ/.xdg"
  ! git -C "$PROJ" check-ignore -q .claude/settings.local.json
  run INIT deny-tools "$PROJ" Artifact Workflow; [ "$status" -eq 0 ]
  jq -e '.permissions.deny == ["Artifact","Workflow"] and .permissions.allow == ["Bash(git status)"] and .enabledPlugins["x@y"] == false' "$PROJ/.claude/settings.local.json"
  git -C "$PROJ" check-ignore -q .claude/settings.local.json
  printf '%s' "$output" | grep -qx 'ignored .claude/settings.local.json'
  run INIT deny-tools "$PROJ" Artifact; [ "$status" -eq 0 ]
  jq -e '.permissions.deny == ["Artifact","Workflow"]' "$PROJ/.claude/settings.local.json"
  [ "$(grep -c 'settings.local.json' "$PROJ/.gitignore")" -eq 1 ]
}
@test "deny-tools creates settings.local.json and refuses a non-bare tool name without writing" {
  mk_project none
  run INIT deny-tools "$PROJ" Artifact; [ "$status" -eq 0 ]
  jq -e '.permissions.deny == ["Artifact"]' "$PROJ/.claude/settings.local.json"
  for bad in 'Bash(rm *)' 'Art ifact' '' '9Tool'; do
    run INIT deny-tools "$PROJ" "$bad"; [ "$status" -eq 2 ]
  done
  run INIT deny-tools "$PROJ"; [ "$status" -eq 2 ]
  jq -e '.permissions.deny == ["Artifact"]' "$PROJ/.claude/settings.local.json"
}
@test "deny-tools leaves a tracked settings.local.json out of .gitignore and needs a root" {
  mk_project none
  export GIT_CONFIG_GLOBAL=/dev/null XDG_CONFIG_HOME="$PROJ/.xdg"
  printf '{}' > "$PROJ/.claude/settings.local.json"; git -C "$PROJ" add -f .claude/settings.local.json
  run INIT deny-tools "$PROJ" Artifact; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '^tracked .claude/settings.local.json'
  ! grep -qs 'settings.local.json' "$PROJ/.gitignore"
  run INIT deny-tools; [ "$status" -eq 2 ]
  run INIT deny-tools "$PROJ/nope" Artifact; [ "$status" -eq 2 ]
}

GITC() { git -C "$PROJ" -c user.name=t -c user.email=t@t "$@"; }

@test "remove: stages tracked paths, never commits" {
  mk_project none
  mkdir -p "$PROJ/.claude/agents" "$PROJ/.claude/commands"
  printf a > "$PROJ/.claude/agents/dev.md"; printf b > "$PROJ/.claude/commands/x.md"
  GITC add -A; GITC commit -q -m files
  head_before="$(git -C "$PROJ" rev-parse HEAD)"
  run INIT remove "$PROJ" .claude/agents/dev.md .claude/commands/x.md; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qx 'removed .claude/agents/dev.md'
  printf '%s' "$output" | grep -qx 'removed .claude/commands/x.md'
  [ ! -e "$PROJ/.claude/agents/dev.md" ] && [ ! -e "$PROJ/.claude/commands/x.md" ]
  staged="$(git -C "$PROJ" diff --cached --name-only)"
  printf '%s' "$staged" | grep -qx '.claude/agents/dev.md'
  printf '%s' "$staged" | grep -qx '.claude/commands/x.md'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$head_before" ]
}
@test "remove: all-or-nothing on a dirty path" {
  mk_project none
  mkdir -p "$PROJ/.claude/agents"
  printf a > "$PROJ/.claude/agents/a.md"; printf b > "$PROJ/.claude/agents/b.md"
  GITC add -A; GITC commit -q -m files
  printf changed > "$PROJ/.claude/agents/b.md"
  run INIT remove "$PROJ" .claude/agents/a.md .claude/agents/b.md; [ "$status" -eq 4 ]
  printf '%s' "$output" | grep -q '.claude/agents/b.md'
  [ -f "$PROJ/.claude/agents/a.md" ] && [ -f "$PROJ/.claude/agents/b.md" ]
  [ -z "$(git -C "$PROJ" diff --cached --name-only)" ]
}
@test "remove: refuses untracked, outside-root and missing paths" {
  mk_project none
  mkdir -p "$PROJ/.claude/agents"
  printf a > "$PROJ/.claude/agents/a.md"; GITC add -A; GITC commit -q -m files
  printf u > "$PROJ/untracked.md"
  run INIT remove "$PROJ" .claude/agents/a.md untracked.md; [ "$status" -eq 4 ]
  for bad in ../x /etc/passwd a/../../x missing.md . ./ .claude/. ./.; do
    run INIT remove "$PROJ" .claude/agents/a.md "$bad"; [ "$status" -eq 2 ]
  done
  run INIT remove "$PROJ"; [ "$status" -eq 2 ]
  run INIT remove "$PROJ/nope" x; [ "$status" -eq 2 ]
  [ -f "$PROJ/.claude/agents/a.md" ] && [ -f "$PROJ/untracked.md" ]
  [ -z "$(git -C "$PROJ" diff --cached --name-only)" ]
}
@test "remove: path with spaces" {
  mk_project none
  mkdir -p "$PROJ/.claude/agents"
  printf a > "$PROJ/.claude/agents/my agent.md"; GITC add -A; GITC commit -q -m files
  run INIT remove "$PROJ" ".claude/agents/my agent.md"; [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.claude/agents/my agent.md" ]
}
@test "remove: overlapping and duplicate paths are removed atomically" {
  mk_project none
  mkdir -p "$PROJ/.claude/agents"
  printf a > "$PROJ/.claude/agents/dev.md"; printf b > "$PROJ/x.md"; GITC add -A; GITC commit -q -m files
  run INIT remove "$PROJ" .claude/agents .claude/agents/dev.md x.md x.md; [ "$status" -eq 0 ]
  [ ! -e "$PROJ/.claude/agents/dev.md" ] && [ ! -e "$PROJ/x.md" ]
  [ -z "$(git -C "$PROJ" diff --name-only)" ]
}
@test "remove: glob characters in names are literal" {
  mk_project none
  printf a > "$PROJ/a.md"; printf b > "$PROJ/b.md"; GITC add -A; GITC commit -q -m files
  run INIT remove "$PROJ" '*.md'; [ "$status" -eq 2 ]
  [ -f "$PROJ/a.md" ] && [ -f "$PROJ/b.md" ]
}

@test "settings --drop-hook removes one entry and keeps the rest" {
  mk_project none; mkdir -p "$PROJ/.claude"
  printf '%s' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash scripts/remind.sh"}]}],"PostToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"prettier --write"}]}]}}' > "$PROJ/.claude/settings.json"
  run INIT settings "$PROJ" --drop-hook UserPromptSubmit remind.sh; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'dropped 1 hook entries'
  jq -e '.hooks.UserPromptSubmit == null' "$PROJ/.claude/settings.json"
  jq -e '.hooks.PostToolUse[0].hooks[0].command | contains("prettier")' "$PROJ/.claude/settings.json"
  jq -e '.permissions == {"allow":["Bash(ls)"]}' "$PROJ/.claude/settings.json"
  jq -e '.enabledPlugins == null and .extraKnownMarketplaces == null' "$PROJ/.claude/settings.json"   # drop never registers
}
@test "settings --drop-hook with no match exits 3 and writes nothing" {
  mk_project none; mkdir -p "$PROJ/.claude"
  printf '%s' '{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"prettier"}]}]}}' > "$PROJ/.claude/settings.json"
  cp "$PROJ/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  run INIT settings "$PROJ" --drop-hook PostToolUse prettier --drop-hook UserPromptSubmit nope; [ "$status" -eq 3 ]
  printf '%s' "$output" | grep -q 'UserPromptSubmit'
  cmp "$PROJ/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
}
@test "settings --drop-hook repeated pairs and missing argument" {
  mk_project none; mkdir -p "$PROJ/.claude"
  printf '%s' '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"a.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"b.sh"},{"type":"command","command":"keep.sh"}]}]}}' > "$PROJ/.claude/settings.json"
  run INIT settings "$PROJ" --drop-hook UserPromptSubmit a.sh --drop-hook Stop b.sh; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'dropped 2 hook entries'
  jq -e '(.hooks | keys) == ["Stop"] and (.hooks.Stop[0].hooks | length) == 1' "$PROJ/.claude/settings.json"
  run INIT settings "$PROJ" --drop-hook Stop; [ "$status" -eq 2 ]
}

@test "settings --drop-hook rejects empty args and spares non-command hooks" {
  mk_project none; mkdir -p "$PROJ/.claude"
  printf '%s' '{"hooks":{"Stop":[{"hooks":[{"type":"prompt","prompt":"p"},{"type":"command","command":"keep.sh"},{"type":"command","command":"x.sh"}]},{"matcher":"M"}]}}' > "$PROJ/.claude/settings.json"
  cp "$PROJ/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  run INIT settings "$PROJ" --drop-hook Stop ""; [ "$status" -eq 2 ]
  run INIT settings "$PROJ" --drop-hook "" x.sh; [ "$status" -eq 2 ]
  cmp "$PROJ/.claude/settings.json" "$BATS_TEST_TMPDIR/before.json"
  run INIT settings "$PROJ" --drop-hook Stop x.sh; [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'dropped 1 hook entries'
  jq -e '.hooks.Stop[0].hooks | length == 2 and .[0].type == "prompt"' "$PROJ/.claude/settings.json"
}
@test "settings rejects combining --drop-legacy-hooks and --drop-hook" {
  mk_project none; mkdir -p "$PROJ/.claude"; printf '{}' > "$PROJ/.claude/settings.json"
  run INIT settings "$PROJ" --drop-legacy-hooks --drop-hook Stop x; [ "$status" -eq 2 ]
  run INIT settings "$PROJ" --drop-hook Stop x --drop-legacy-hooks; [ "$status" -eq 2 ]
  run INIT settings "$PROJ" --drop-legacy-hooks extra; [ "$status" -eq 2 ]
  [ "$(cat "$PROJ/.claude/settings.json")" = "{}" ]
}

@test "remove: refuses the project root itself and never stages anything" {
  mk_project none
  printf a > "$PROJ/a.md"; GITC add -A; GITC commit -q -m files
  for bad in . ./ .///; do
    run INIT remove "$PROJ" "$bad"; [ "$status" -eq 2 ]
  done
  [ -z "$(git -C "$PROJ" diff --cached --name-only)" ]
}
