#!/usr/bin/env bats
load helpers
# Single home of the project-name list; this file is excluded from the scan.
@test "no project names outside docs/" {
  run bash -c "cd '$MK_REPO' && git ls-files | grep -v '^docs/' | grep -v '^tests/repo-hygiene.bats\$' | xargs grep -Eil 'shiftbox|brightfuture|smartvision|insanvesirlari|sırları|shushadiamond|shusha|smartstore|redevents' || true"
  [ -z "$output" ]
}
@test "no legacy env prefixes" {
  run bash -c "cd '$MK_REPO' && git ls-files | grep -v '^docs/' | grep -v '^tests/repo-hygiene.bats\$' | xargs grep -En '\b(IVS|SBX|SD|BF)_[A-Z]' || true"
  [ -z "$output" ]
}
@test "README covers install, init, config, kill switch" {
  for s in '/plugin marketplace add tsrmehmet/memokit' '/plugin install memokit@memokit' 'claude plugin enable memokit@memokit --scope local' '/memokit:init' 'memokit.json' 'MEMOKIT_GUARD_OFF' 'Türkçe'; do
    grep -q "$s" "$MK_REPO/README.md" || { echo "missing: $s"; false; }
  done
}
@test "README documents only env vars that exist in hooks" {
  for v in $(grep -oE 'MEMOKIT_[A-Z_]+' "$MK_REPO/README.md" | sort -u); do
    grep -rq "$v" "$MK_REPO/hooks" || { echo "unknown env var: $v"; false; }
  done
}
@test "README install is per project and warns against user-level enablement" {
  f="$MK_REPO/README.md"
  grep -qF 'enabledPlugins["memokit@memokit"]' "$f" || { echo "no enabledPlugins note"; false; }
  grep -qF 'defaultEnabled' "$f" || { echo "no defaultEnabled note"; false; }
  grep -qi 'user level' "$f" || { echo "no user-level warning"; false; }
}
@test "README: MEMOKIT_NO_INIT_HINT row describes when the hint fires (M1)" {
  row="$(grep -F '`MEMOKIT_NO_INIT_HINT=1`' "$MK_REPO/README.md")"
  lacks "$row" 'once-per-session'
  printf '%s' "$row" | grep -qF 'every SessionStart' || { echo "row: $row"; false; }
  printf '%s' "$row" | grep -qF '.claude/hooks' || { echo "row: $row"; false; }
}
@test "version bump rule is documented in README and CHANGELOG (I5)" {
  grep -qF 'bumps `version` in `.claude-plugin/plugin.json`' "$MK_REPO/README.md"
  sed -n '1,4p' "$MK_REPO/CHANGELOG.md" | grep -qF '.claude-plugin/plugin.json'
}
@test "no references into docs/ from shipped files" {
  run bash -c "cd '$MK_REPO' && git ls-files | grep -v '^docs/' | grep -v '^tests/repo-hygiene.bats\$' | xargs grep -n 'docs/specs\|docs/plans'; test \$? -eq 1"
  [ "$status" -eq 0 ]
}
