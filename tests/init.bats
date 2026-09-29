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
