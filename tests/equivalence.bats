#!/usr/bin/env bats
load helpers
@test "self-comparison: every case same" {
  mk_project none; mkdir -p "$PROJ/.claude/hooks"
  cp "$MK_REPO"/tests/fixtures/legacy/*.sh "$PROJ/.claude/hooks/"
  git -C "$PROJ" -c user.email=t@t -c user.name=t add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm l
  run "$MK_BASH" "$MK_REPO/tests/equivalence/run.sh" "$PROJ" --self
  [ "$status" -eq 0 ]
  lacks "$output" '| diff'
  lacks "$output" '| UNEXPECTED'
}

mk_legacy_project() {
  mk_project none; mkdir -p "$PROJ/.claude/hooks"
  cp "$MK_REPO"/tests/fixtures/legacy/*.sh "$PROJ/.claude/hooks/"
}
commit_all() { git -C "$PROJ" -c user.email=t@t -c user.name=t add -A; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -qm l; }

@test "self-comparison: Q01 fires on dirty guarded dir, Q02 silent" {
  mk_legacy_project; commit_all
  run "$MK_BASH" "$MK_REPO/tests/equivalence/run.sh" "$PROJ" --self
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'Q01 | fired | fired | same'
  echo "$output" | grep -qF 'Q02 | silent | silent | same'
}

@test "a legacy hook that prints garbage and exits 1 is ERROR, not a pass" {
  mk_legacy_project
  printf '#!/bin/bash\necho garbage-not-json\necho boom >&2\nexit 1\n' > "$PROJ/.claude/hooks/guard-subagent-authority.sh"
  commit_all
  run "$MK_BASH" "$MK_REPO/tests/equivalence/run.sh" "$PROJ"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'S05 | ERR |'
  echo "$output" | grep -qF '| ERROR'
  echo "$output" | grep -qF 'S05 legacy rc=1: boom'
}

@test "a missing legacy hook is ERROR" {
  mk_legacy_project; rm "$PROJ/.claude/hooks/inject-rules.sh"; commit_all
  run "$MK_BASH" "$MK_REPO/tests/equivalence/run.sh" "$PROJ"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF 'P07 | ERR |'
}

@test "empty guardedDirs aborts with exit 2" {
  mk_legacy_project; rm "$PROJ/.claude/hooks/guard-edit.sh"; commit_all
  run "$MK_BASH" "$MK_REPO/tests/equivalence/run.sh" "$PROJ" --self
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'no guardedDirs'
}

@test "harness runs every hook with a fresh HOME of its own" {
  mk_legacy_project
  printf '#!/bin/bash\necho "home=$HOME" >&2\nexit 1\n' > "$PROJ/.claude/hooks/guard-subagent-authority.sh"
  commit_all
  real_home="$(mktemp -d "${BATS_TMPDIR:-/tmp}/realhome.XXXXXX")"
  HOME="$real_home" run "$MK_BASH" "$MK_REPO/tests/equivalence/run.sh" "$PROJ"
  line="$(printf '%s\n' "$output" | grep -F 'S05 legacy rc=1: home=' | head -n1)"
  [ -n "$line" ] || { echo "no S05 home line: $output"; false; }
  lacks "$line" "home=$real_home"
  printf '%s' "$line" | grep -q 'home=.*/mk-eq-home\.' || { echo "HOME not a harness temp dir: $line"; false; }
}
