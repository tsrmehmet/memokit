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
  for s in '/plugin marketplace add tsrmehmet/memokit' '/plugin install memokit@memokit' 'claude plugin install memokit@memokit --scope user' '/memokit:init' 'memokit.json' 'MEMOKIT_GUARD_OFF' 'Türkçe'; do
    grep -q "$s" "$MK_REPO/README.md" || { echo "missing: $s"; false; }
  done
}
@test "README documents only env vars that exist in hooks" {
  for v in $(grep -oE 'MEMOKIT_[A-Z_]+' "$MK_REPO/README.md" | sort -u); do
    grep -rq "$v" "$MK_REPO/hooks" || { echo "unknown env var: $v"; false; }
  done
}
@test "README install is at user level, without the old per-project warning" {
  f="$MK_REPO/README.md"
  grep -qF 'enabledPlugins["memokit@memokit"]' "$f" || { echo "no enabledPlugins note"; false; }
  grep -qF '"defaultEnabled": true' "$f" || { echo "no defaultEnabled note"; false; }
  ! grep -qF -e 'Do not enable memokit at user level' -e '--scope local' -e 'etkinleştirmeyin' "$f" || { echo "old per-project install text left"; false; }
}
@test "README: MEMOKIT_INIT_HINT row describes when the hint fires (M1)" {
  row="$(grep -F '`MEMOKIT_INIT_HINT=1`' "$MK_REPO/README.md")"
  lacks "$row" 'once-per-session'
  printf '%s' "$row" | grep -qF 'every SessionStart' || { echo "row: $row"; false; }
  printf '%s' "$row" | grep -qF '.claude/hooks' || { echo "row: $row"; false; }
}
@test "version bump rule is documented in README and CHANGELOG (I5)" {
  grep -qF 'bumps `version` in `.claude-plugin/plugin.json`' "$MK_REPO/README.md"
  sed -n '1,4p' "$MK_REPO/CHANGELOG.md" | grep -qF '.claude-plugin/plugin.json'
}
@test "readme: Remote changes section documents memokit-window.sh request" {
  sec="$(awk '/^## Remote changes/{p=1;next} /^## /{p=0} p' "$MK_REPO/README.md")"
  [ -n "$sec" ]
  for w in 'memokit-window.sh' 'request' 'change window' 'onaylıyorum' 'remote.log' 'close-window.sh'; do
    printf '%s' "$sec" | grep -qF -- "$w" || { echo "$w"; false; }
  done
  grep -qF '`remote.hosts[]`' "$MK_REPO/README.md"
  grep -qF '`careful.patterns[].target`' "$MK_REPO/README.md"
}
@test "changelog: 0.8.1 entry matches plugin.json version" {
  v="$(jq -r .version "$MK_REPO/.claude-plugin/plugin.json")"
  [ "$v" = "0.8.1" ]
  sed -n '5,12p' "$MK_REPO/CHANGELOG.md" | grep -qF "## $v "
  sec="$(awk '/^## 0\.8\.1/{p=1;next} /^## /{p=0} p' "$MK_REPO/CHANGELOG.md")"
  for w in 'Flow' 'Agents' 'Hardening' 'Tests' 'Measured' 'parallel.auto' 'snapshot'; do
    printf '%s' "$sec" | grep -qF -- "$w" || { echo "$w"; false; }
  done
}
@test "changelog: 0.8.0 entry is still present" {
  grep -qF '## 0.8.0 ' "$MK_REPO/CHANGELOG.md"
}
@test "no references into docs/ from shipped files" {
  run bash -c "cd '$MK_REPO' && git grep -n -e 'docs/specs' -e 'docs/plans' -- . ':!docs/' ':!tests/repo-hygiene.bats'; test \$? -eq 1"
  [ "$status" -eq 0 ]
}
@test "tests leave no memokit state in the real temp dir" {
  # Live sessions write memokit-* files there too, so count nothing: assert
  # that nothing carries THIS fixture project's hash (or the 'none' hash).
  mk_project
  run_hook guard-destructive.sh "$(bash_payload 'rm -rf src')"
  run_hook session-start.sh "$(jq -nc --arg cwd "$PROJ" '{source:"startup",session_id:"hyg1",cwd:$cwd}')"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  hn="$(printf '%s' none | cksum | cut -d' ' -f1)"
  run bash -c 'ls "$1" | grep -E "^memokit-($2|$3)-" || true' _ "$MK_REAL_TMPDIR" "$h" "$hn"
  [ -z "$output" ]
  # And the state really did land in the private per-test dir.
  [ -n "$(ls "$TMPDIR" | grep "^memokit-$h-")" ]
}
@test "test fixtures live in bats's run dir, never loose in the real temp dir" {
  # Earlier runs may have left mkproj.* there; judge only this test's own
  # fixtures, by name, and the helpers that make them.
  local f p rd bin
  rd="$(cd -P "$BATS_RUN_TMPDIR" && pwd -P)"
  mk_project; p="$PROJ"
  legacy_project
  wt_repo
  mk_temp_tree
  bin="$(path_without jq)"
  for f in "$p" "$PROJ" "$HOME" "$R" "$TROOT_LOGICAL" "$bin"; do
    case "$(cd -P "$f" && pwd -P)/" in "$rd"/*) ;; *) echo "fixture outside the bats run dir: $f"; false ;; esac
    [ ! -e "${MK_REAL_TMPDIR%/}/${f##*/}" ] || { echo "left in the real temp dir: $f"; false; }
  done
  # No test builds a path directly under BATS_TMPDIR (the real temp dir).
  run grep -nE '\$\{?BATS_TMPDIR(:-/tmp)?\}?/' "$MK_REPO"/tests/*.bats "$MK_REPO"/tests/*.bash
  [ -z "$output" ] || { echo "$output"; false; }
}
