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
  jq -e '.enabledPlugins["memokit@memokit"] == true' "$PROJ/.claude/settings.json"
  jq -e '.extraKnownMarketplaces.memokit.source.repo == "tsrmehmet/memokit"' "$PROJ/.claude/settings.json"
  jq -e '(.hooks.Stop // []) | length == 0' "$PROJ/.claude/settings.json"
  jq -e '.hooks.Notification | length == 1' "$PROJ/.claude/settings.json"
}
@test "settings creates .claude/settings.json when absent" {
  mk_project none
  run INIT settings "$PROJ"; [ "$status" -eq 0 ]
  jq -e '.enabledPlugins["memokit@memokit"] == true' "$PROJ/.claude/settings.json"
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
