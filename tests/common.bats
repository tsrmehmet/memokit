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
  [ "$output" = "en|src,tests|300000|3|debugging decision review handoff resume graphify context7" ]
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
  outer="$(mktemp -d "${MK_FIXTMP}/mkouter.XXXXXX")"; outer="$(cd "$outer" && pwd)"
  mkdir -p "$outer/.claude" "$outer/repo/src"; printf '%s' "$DEFAULT_CONFIG" > "$outer/.claude/memokit.json"
  git -C "$outer/repo" init -q
  export CLAUDE_PROJECT_DIR="$outer/repo/src"
  run lib 'mk_resolve_root "{}"; mk_active && echo on || echo off'
  [ "$output" = "off" ]
}

@test "non-git directory without config stays inactive" {
  d="$(mktemp -d "${MK_FIXTMP}/mknogit.XXXXXX")"; mkdir -p "$d/src"
  export CLAUDE_PROJECT_DIR="$d/src"
  run lib 'mk_resolve_root "{}"; mk_active && echo on || echo off'
  [ "$output" = "off" ]
}

@test "symlinked subdirectory launch does not climb to the symlink's logical parent" {
  mk_project
  outer="$(mktemp -d "${MK_FIXTMP}/mkouter.XXXXXX")"; outer="$(cd "$outer" && pwd)"
  mkdir -p "$outer/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$outer/.claude/memokit.json"
  ln -s "$PROJ/src" "$outer/link"
  export CLAUDE_PROJECT_DIR="$outer/link"
  run lib 'mk_resolve_root "{}"; printf %s "$MK_ROOT"'
  [ "$output" = "$outer/link" ]
}

@test "graph is off by default" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "[%s|%s|%s]" "$MK_GRAPH_ROOT" "$MK_GRAPH_MAX_BEHIND" "$MK_GRAPH_REFRESH_SCRIPT"'
  [ "$output" = "[|20|]" ]
}

@test "graph settings are loaded" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"graph":{"root":"src/app","maxCommitsBehind":5,"refreshScript":"scripts/g.sh"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "%s|%s|%s" "$MK_GRAPH_ROOT" "$MK_GRAPH_MAX_BEHIND" "$MK_GRAPH_REFRESH_SCRIPT"'
  [ "$output" = "src/app|5|scripts/g.sh" ]
}

@test "graph root may be the repository root" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"graph":{"root":"."}}'
  run lib 'mk_resolve_root "{}"; mk_load_config && printf "%s" "$MK_GRAPH_ROOT"'
  [ "$output" = "." ]
}

@test "rejects bad graph settings" {
  for g in '"src"' '{}' '{"root":".."}' '{"root":"/etc"}' '{"root":"src","maxCommitsBehind":-1}' '{"root":"src","refreshScript":"../x.sh"}' '{"root":"src","refreshScript":""}'; do
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"graph\":$g}"
    run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
    [ "$output" = "graph" ] || { echo "accepted: $g -> $output"; false; }
  done
}

@test "scratch/disk defaults when absent" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "%s|%s|%s|%s|%s" "$MK_SCRATCH_AGENT_MAX_MB" "$MK_SCRATCH_STALE_HOURS" "$MK_SCRATCH_REPORT_MIN_MB" "$MK_DISK_MIN_FREE_GB" "$MK_DISK_DROP_WARN_GB"'
  [ "$output" = "1024|24|500|30|10" ]
}

@test "scratch/disk values are read" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"scratch":{"agentMaxMB":5,"staleAfterHours":2,"reportMinMB":0},"disk":{"minFreeGB":0,"dropWarnGB":3}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "%s|%s|%s|%s|%s" "$MK_SCRATCH_AGENT_MAX_MB" "$MK_SCRATCH_STALE_HOURS" "$MK_SCRATCH_REPORT_MIN_MB" "$MK_DISK_MIN_FREE_GB" "$MK_DISK_DROP_WARN_GB"'
  [ "$output" = "5|2|0|0|3" ]
}

@test "scratch/disk invalid values are rejected" {
  for c in 'scratch|{"agentMaxMB":0}' 'scratch|{"staleAfterHours":0}' 'scratch|{"reportMinMB":-1}' \
           'disk|{"minFreeGB":-1}' 'disk|{"dropWarnGB":0}' 'scratch|"x"' 'disk|[]'; do
    k="${c%%|*}"; v="${c#*|}"
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"$k\":$v}"
    run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
    [ "$output" = "$k" ] || { echo "accepted: $c -> $output"; false; }
  done
}

@test "scratch/disk are known keys" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"scratch":{},"disk":{}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "[%s]" "$MK_CONFIG_WARN"'
  [ "$output" = "[]" ]
}

@test "parallel/review defaults when absent" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "%s|%s|%s" "$MK_PARALLEL_MAX_CODERS" "$MK_PARALLEL_MAX_REVIEWERS" "$MK_REVIEW_MODEL"'
  [ "$output" = "3|3|auto" ]
}

@test "parallel/review values are read" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"parallel":{"maxCoders":5,"maxReviewers":1},"review":{"model":"opus"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "%s|%s|%s" "$MK_PARALLEL_MAX_CODERS" "$MK_PARALLEL_MAX_REVIEWERS" "$MK_REVIEW_MODEL"'
  [ "$output" = "5|1|opus" ]
}

@test "parallel/review invalid values are rejected" {
  for c in 'parallel|{"maxCoders":0}' 'parallel|{"maxReviewers":1.5}' 'parallel|"x"' \
           'review|{"model":"haiku"}' 'review|[]' 'review|{"validate":"x"}' 'review|{"validate":true}'; do
    k="${c%%|*}"; v="${c#*|}"
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"$k\":$v}"
    run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
    [ "$output" = "$k" ] || { echo "accepted: $c -> $output"; false; }
  done
}

@test "review.validate: default high, values read" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
  [ "$output" = "" ]
  for v in high always never; do
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"review\":{\"validate\":\"$v\"}}"
    run lib 'mk_resolve_root "{}"; mk_load_config; echo "[$MK_CONFIG_ERR]"'
    [ "$output" = "[]" ]
  done
}

@test "parallel/review are known keys" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"parallel":{},"review":{}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "[%s]" "$MK_CONFIG_WARN"'
  [ "$output" = "[]" ]
}

# --- 0.8.1 (spec 4): session-start config snapshot --------------------------
# libp CODE PAYLOAD -- run CODE after sourcing common.sh, with $1 = PAYLOAD.
libp() { "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; $1" _ "$2"; }

@test "snapshot file: absolute, no //, sanitised session id, with TMPDIR holding a blank or unset" {
  mk_project
  pl='{"session_id":"a/b c.d"}'
  mkdir -p "$BATS_TEST_TMPDIR/a b"
  run env TMPDIR="$BATS_TEST_TMPDIR/a b/" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_config_snapshot_file \"\$1\"" _ "$pl"
  [ "$status" -eq 0 ]
  case "$output" in "$BATS_TEST_TMPDIR/a b/memokit-"*-careful-config-a_b_c_d) ;; *) echo "got [$output]"; false ;; esac
  lacks "$output" '//'
  run env -u TMPDIR "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_config_snapshot_file \"\$1\"" _ "$pl"
  [ "$status" -eq 0 ]
  case "$output" in /tmp/memokit-*-careful-config-a_b_c_d) ;; *) echo "got [$output]"; false ;; esac
  lacks "$output" '//'
  # no session id: the marker's fallback name
  run libp 'mk_resolve_root "{}"; mk_config_snapshot_file "$1"' '{}'
  case "$output" in /*/memokit-*-careful-config-unknown) ;; *) echo "got [$output]"; false ;; esac
}

@test "snapshot: MK_CONFIG is the snapshot only for a subagent payload with the live file and a safe snapshot" {
  mk_project
  run libp 'mk_resolve_root "$1"; mk_config_snapshot_write "$1"' '{"session_id":"s1"}'
  [ "$status" -eq 0 ]
  snap="$(libp 'mk_resolve_root "{}"; mk_config_snapshot_file "$1"' '{"session_id":"s1"}')"
  [ -f "$snap" ]
  cmp -s "$snap" "$PROJ/.claude/memokit.json"
  show='mk_resolve_root "$1"; printf "%s|%s|" "$MK_CONFIG" "$MK_CONFIG_LIVE"; if mk_active; then echo on; else echo off; fi'
  run libp "$show" '{"session_id":"s1","agent_id":"a1"}'
  [ "$output" = "$snap|$PROJ/.claude/memokit.json|on" ]
  # main session, an empty agent_id, another session: the live file
  for pl in '{"session_id":"s1"}' '{"session_id":"s1","agent_id":""}' '{"session_id":"s2","agent_id":"a1"}' 'not json'; do
    run libp "$show" "$pl"
    [ "$output" = "$PROJ/.claude/memokit.json|$PROJ/.claude/memokit.json|on" ] || { echo "$pl -> $output"; false; }
  done
  # live file gone: the live path (inactive), the snapshot is not used
  mv "$PROJ/.claude/memokit.json" "$PROJ/.claude/away.json"
  run libp "$show" '{"session_id":"s1","agent_id":"a1"}'
  [ "$output" = "$PROJ/.claude/memokit.json|$PROJ/.claude/memokit.json|off" ]
  mv "$PROJ/.claude/away.json" "$PROJ/.claude/memokit.json"
  # a symlink or a non-regular file at the snapshot path: the live file
  rm -f "$snap"; ln -s "$PROJ/.claude/memokit.json" "$snap"
  run libp "$show" '{"session_id":"s1","agent_id":"a1"}'
  [ "$output" = "$PROJ/.claude/memokit.json|$PROJ/.claude/memokit.json|on" ]
  rm -f "$snap"; mkdir "$snap"
  run libp "$show" '{"session_id":"s1","agent_id":"a1"}'
  [ "$output" = "$PROJ/.claude/memokit.json|$PROJ/.claude/memokit.json|on" ]
}

@test "snapshot write: refuses a symlink and a non-regular file, writes atomically with mode 600" {
  mk_project
  snap="$(libp 'mk_resolve_root "{}"; mk_config_snapshot_file "$1"' '{"session_id":"s1"}')"
  printf 'keep' > "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$snap"
  run libp 'mk_resolve_root "$1"; mk_config_snapshot_write "$1"' '{"session_id":"s1"}'
  [ "$status" -eq 1 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = keep ]
  [ -L "$snap" ]
  rm -f "$snap"; mkdir "$snap"
  run libp 'mk_resolve_root "$1"; mk_config_snapshot_write "$1"' '{"session_id":"s1"}'
  [ "$status" -eq 1 ]
  rmdir "$snap"
  run libp 'mk_resolve_root "$1"; mk_config_snapshot_write "$1"' '{"session_id":"s1"}'
  [ "$status" -eq 0 ]
  cmp -s "$snap" "$PROJ/.claude/memokit.json"
  [ "$(ls -l "$snap" | cut -c1-10)" = "-rw-------" ]
  [ -z "$(ls "$(dirname "$snap")" | grep -F "$(basename "$snap")." || true)" ]
}

@test "0.8.1: parallel.auto accepts a boolean and rejects a string" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"parallel":{"auto":true}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "[%s][%s]" "$MK_CONFIG_ERR" "$MK_CONFIG_WARN"'
  [ "$output" = "[][]" ]
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"parallel":{"auto":"yes"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
  [ "$output" = "parallel" ]
}

@test "0.8.1: convert.markitdown is a known boolean, default off" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"}}'
  run lib 'mk_resolve_root "{}"; mk_load_config; printf "[%s][%s]" "$MK_CONFIG_ERR" "$MK_CONVERT_MARKITDOWN"'
  [ "$output" = "[][0]" ]
  for v in true false; do
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"convert\":{\"markitdown\":$v}}"
    run lib 'mk_resolve_root "{}"; mk_load_config; printf "[%s][%s][%s]" "$MK_CONFIG_ERR" "$MK_CONFIG_WARN" "$MK_CONVERT_MARKITDOWN"'
    want=0; [ "$v" = true ] && want=1
    [ "$output" = "[][][$want]" ] || { echo "$v -> $output"; false; }
  done
  for c in '{"markitdown":"yes"}' '{"markitdown":1}' '{"other":true}' '"x"' '[]'; do
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"convert\":$c}"
    run lib 'mk_resolve_root "{}"; mk_load_config; echo "$MK_CONFIG_ERR"'
    [ "$output" = "convert" ] || { echo "accepted: $c -> $output"; false; }
  done
}
