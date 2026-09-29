#!/usr/bin/env bats
load helpers

lib() { "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; $1"; }

@test "resolve root from CLAUDE_PROJECT_DIR" {
  mk_project
  run lib 'mk_resolve_root "{}"; printf %s "$MK_ROOT"'
  [ "$output" = "$PROJ" ]
}

@test "resolve root from payload cwd subdir" {
  mk_project
  unset CLAUDE_PROJECT_DIR
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root \"\$1\"; printf %s \"\$MK_ROOT\"" _ "{\"cwd\":\"$PROJ/src\"}"
  [ "$output" = "$PROJ" ]
}

@test "inactive without config" {
  mk_project none
  run lib 'mk_resolve_root "{}"; mk_active && echo on || echo off'
  [ "$output" = "off" ]
}

@test "loads config with defaults" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "%s|%s|%s|%s|%s" "$MK_LANG" "$(printf %s "$MK_GUARDED_DIRS" | tr "\n" ,)" "$MK_CONTEXT_LIMIT" "$MK_STATE_MAX_BEHIND" "$MK_HINTS_BUILTIN"'
  [ "$status" -eq 0 ]
  [ "$output" = "en|src,tests|300000|3|debugging decision review handoff resume graphify" ]
}

@test "rejects bad tag" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"dmo"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_OK:$MK_CONFIG_ERR"'
  [ "$output" = "0:project.tag" ]
}

@test "rejects hostile guardedDirs" {
  for gd in '[".."]' '["/etc"]' '["src/*"]' '[""]' '[]' '["src/../x"]' '[".git"]'; do
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"guardedDirs\":$gd}"
    run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
    [ "$output" = "guardedDirs" ] || { echo "accepted: $gd"; false; }
  done
}

@test "rejects broken json" {
  mk_project '{"version":1,'
  run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
  [ "$output" = "parse" ]
}

@test "warns on unknown keys" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"colour":"x"}'
  run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_WARN"'
  [ "$output" = "colour" ]
}

@test "tmp names differ per project" {
  mk_project; a="$PROJ"
  run lib 'mk_resolve_root "{}"; mk_tmp band'; t1="$output"
  mk_project; run lib 'mk_resolve_root "{}"; mk_tmp band'; t2="$output"
  [ "$t1" != "$t2" ]
  case "$t1" in */memokit-*-band) ;; *) false ;; esac
}

@test "msg renders tag and args" {
  mk_project
  run lib 'mk_resolve_root "{}"; mk_load_config; mk_msg TEST_ECHO abc'
  [ "$output" = "[DMO] test abc" ]
}

@test "msg rejects bad key" {
  mk_project
  run lib 'mk_resolve_root "{}"; mk_load_config; mk_msg "x;rm"'
  [ "$status" -ne 0 ]
}

@test "lang guess without jq" {
  mk_project
  run lib 'mk_resolve_root "{}"; mk_lang_guess'
  [ "$output" = "tr" ]
}

@test "dirs human" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"guardedDirs":["src","web"]}'
  run lib 'mk_resolve_root "{}"; mk_load_config; mk_dirs_human'
  [ "$output" = "src/, web/" ]
}

@test "subdirectory launch resolves to the git top level holding the config (logical form)" {
  mk_project
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run lib 'mk_resolve_root "{}"; mk_active && printf "on:%s" "$MK_ROOT"'
  [ "$output" = "on:$PROJ" ]
}

@test "a subdirectory that has its own config is used as-is" {
  mk_project
  mkdir -p "$PROJ/src/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$PROJ/src/.claude/memokit.json"
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run lib 'mk_resolve_root "{}"; printf %s "$MK_ROOT"'
  [ "$output" = "$PROJ/src" ]
}

@test "subdirectory of a repo without config stays inactive" {
  mk_project none
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run lib 'mk_resolve_root "{}"; mk_active && echo on || echo off'
  [ "$output" = "off" ]
}

@test "never walks above the git top level" {
  # A config ABOVE the repo must not activate it.
  outer="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkouter.XXXXXX")"; outer="$(cd "$outer" && pwd)"
  mkdir -p "$outer/.claude" "$outer/repo/src"; printf '%s' "$DEFAULT_CONFIG" > "$outer/.claude/memokit.json"
  git -C "$outer/repo" init -q
  export CLAUDE_PROJECT_DIR="$outer/repo/src"
  run lib 'mk_resolve_root "{}"; mk_active && echo on || echo off'
  [ "$output" = "off" ]
}

@test "non-git directory without config stays inactive" {
  d="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mknogit.XXXXXX")"; mkdir -p "$d/src"
  export CLAUDE_PROJECT_DIR="$d/src"
  run lib 'mk_resolve_root "{}"; mk_active && echo on || echo off'
  [ "$output" = "off" ]
}

@test "symlinked subdirectory launch does not climb to the symlink's logical parent" {
  mk_project
  outer="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkouter.XXXXXX")"; outer="$(cd "$outer" && pwd)"
  mkdir -p "$outer/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$outer/.claude/memokit.json"
  ln -s "$PROJ/src" "$outer/link"
  export CLAUDE_PROJECT_DIR="$outer/link"
  run lib 'mk_resolve_root "{}"; printf %s "$MK_ROOT"'
  [ "$output" != "$outer" ]
}
