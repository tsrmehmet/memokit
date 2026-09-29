#!/usr/bin/env bats
load helpers
gitc() { git -C "$PROJ" -c user.email=t@t -c user.name=t "$@"; }

@test "silent without config" { mk_project none; echo x > "$PROJ/src/a"; run_hook check-state-stale.sh '{}'; [ -z "$output" ]; }
# NOTE: mk_project's fixture makes exactly ONE commit, which touches
# docs/STATE.md -- so immediately after mk_project, state_sha == head_sha
# (STATE.md's last-touching commit IS HEAD). The ported check-1 logic
# (faithful to legacy: see check-state-stale.sh's "(b)" comment) treats that
# as "STATE.md is current as of HEAD" and intentionally suppresses the
# warning, exactly as the legacy hook did with the same git history shape --
# confirmed by tracing both. A real "dirty without a STATE update" needs an
# intervening commit that does NOT touch STATE.md (moving head_sha away from
# state_sha) before the guarded dir is dirtied, the same way real repo
# history accumulates commits between STATE.md updates. This one extra
# commit line is a fixture-only deviation from the brief's literal test text
# (documented in task-9-report.md); the hook logic itself matches the brief
# exactly.
@test "dirty guarded dir without STATE update warns" {
  mk_project
  echo x > "$PROJ/docs/note.txt"; gitc add -A; gitc commit -qm "note"
  echo x > "$PROJ/src/a"
  run_hook check-state-stale.sh '{}'; ctx | grep -q '\[DMO-UYARI\]'; ctx | grep -q 'memokit:handoff'
}
@test "only configured dirs count" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","guardedDirs":["web"]}'
  echo x > "$PROJ/src/a"
  run_hook check-state-stale.sh '{}'; [ -z "$output" ]
  echo y > "$PROJ/README.md"; gitc add -A; gitc commit -qm "readme"
  mkdir -p "$PROJ/web"; echo x > "$PROJ/web/a"
  run_hook check-state-stale.sh '{}'; ctx | grep -q 'web/'
}
@test "commits behind threshold warns" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","stateStale":{"maxCommitsBehind":1}}'
  for i in 1 2; do echo $i > "$PROJ/src/f$i"; gitc add -A; gitc commit -qm "c$i"; done
  run_hook check-state-stale.sh '{}'; ctx | grep -q 'eşik 1'
}
@test "clean tree is silent" { mk_project; run_hook check-state-stale.sh '{}'; [ -z "$output" ]; }
