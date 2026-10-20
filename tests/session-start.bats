#!/usr/bin/env bats
load helpers

@test "no init hint by default" {
  mk_project none
  run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "init hint in git repo without config when opted in" {
  mk_project none
  LANG=tr_TR.UTF-8 MEMOKIT_INIT_HINT=1 run_hook session-start.sh '{}'
  ctx | grep -q '/memokit:init'
}
@test "no hint in legacy project" {
  mk_project none; mkdir -p "$PROJ/.claude/hooks"
  MEMOKIT_INIT_HINT=1 run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "no hint outside git" {
  d="$(mktemp -d)"; export CLAUDE_PROJECT_DIR="$d"
  MEMOKIT_INIT_HINT=1 run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "legacy MEMOKIT_NO_INIT_HINT=1 wins over MEMOKIT_INIT_HINT=1" {
  mk_project none
  MEMOKIT_INIT_HINT=1 MEMOKIT_NO_INIT_HINT=1 run_hook session-start.sh '{}'; [ -z "$output" ]
}
@test "injects header, STATE and resume note" {
  mk_project
  run_hook session-start.sh '{}'
  ctx | grep -q '\[Demo — oturum açılışı\]'
  ctx | grep -q 'Sıradaki adım: demo'
  ctx | grep -q '/memokit:resume'
}
@test "health script output included; missing script reported" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","sessionStart":{"healthScript":"scripts/kh.sh"}}'
  run_hook session-start.sh '{}'; ctx | grep -q 'scripts/kh.sh'
  mkdir -p "$PROJ/scripts"; printf '#!/bin/sh\necho HEALTH-OK\n' > "$PROJ/scripts/kh.sh"; chmod +x "$PROJ/scripts/kh.sh"
  run_hook session-start.sh '{}'; ctx | grep -q 'HEALTH-OK'
}
mk_outside_script() {
  out="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkout.XXXXXX")"; out="$(cd "$out" && pwd)"
  printf '#!/bin/sh\ntouch "%s/RAN"\n' "$out" > "$out/kh.sh"; chmod +x "$out/kh.sh"
}
@test "health script outside the project root is not run" {
  mk_outside_script
  mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"language\":\"tr\",\"sessionStart\":{\"healthScript\":\"../$(basename "$out")/kh.sh\"}}"
  # mk_project and the outside dir share BATS_TMPDIR, so ../<out> reaches it.
  [ "$(dirname "$PROJ")" = "$(dirname "$out")" ]
  run_hook session-start.sh '{}'
  [ ! -e "$out/RAN" ]
  ctx | grep -q 'proje kökünün dışına'
}
@test "health script under a symlinked dir that leaves the root is not run" {
  mk_outside_script
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","sessionStart":{"healthScript":"scripts/kh.sh"}}'
  ln -s "$out" "$PROJ/scripts"
  run_hook session-start.sh '{}'
  [ ! -e "$out/RAN" ]
  ctx | grep -q 'proje kökünün dışına'
}
@test "symlinked health script file is not run" {
  mk_outside_script
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en","sessionStart":{"healthScript":"scripts/kh.sh"}}'
  mkdir -p "$PROJ/scripts"; ln -s "$out/kh.sh" "$PROJ/scripts/kh.sh"
  run_hook session-start.sh '{}'
  [ ! -e "$out/RAN" ]
  ctx | grep -q 'outside the project root'
}
@test "missing docs are reported" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","sessionStart":{"docs":["docs/RULES.md — kurallar"]}}'
  run_hook session-start.sh '{}'
  ctx | grep -q 'docs/RULES.md'
  ctx | grep -qi 'eksik'
}
@test "unknown key warned" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","colour":1}'
  run_hook session-start.sh '{}'; ctx | grep -q 'colour'
}
@test "control characters in STATE still yield valid json" {
  mk_project; printf 'a\033b\001c\n' > "$PROJ/docs/STATE.md"
  run_hook session-start.sh '{}'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "invalid config still injects STATE with warning" {
  mk_project '{"version":1,"project":{"name":"D","tag":"bad"}}'
  run_hook session-start.sh '{}'
  ctx | grep -q 'memokit.json'; ctx | grep -q 'Sıradaki adım'
}
@test "invalid config still runs the risk scan without leaking the secret" {
  mk_project '{"version":1,"project":{"name":"D","tag":"bad"}}'
  printf '%s' '{"permissions":{"allow":["Bash(sshpass -p hunter2pass ssh root@203.0.113.9 uptime)"]}}' > "$PROJ/.claude/settings.local.json"
  run_hook session-start.sh '{}'
  ctx | grep -q 'memokit.json'
  ctx | grep -q 'Sıradaki adım'
  ctx | grep -q 'sshpass-p'
  lacks "$output" 'hunter2pass'
}

# --- 0.5.0: temp leftovers + low disk ---------------------------------------
lo_setup() {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en","scratch":{"reportMinMB":1}}'
  mk_temp_tree
  export TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkss.XXXXXX")"
  unset MEMOKIT_SCRATCH_OFF MEMOKIT_DISK_OFF
  export MEMOKIT_DF_KB=$((500*1048576))
  # report-only (0.6.0) behaviour; the auto-clean tests unset it
  export MEMOKIT_AUTOCLEAN_OFF=1
  OLDS="aaaaaaaa-0000-0000-0000-000000000001"
  mk_blob "$TT_PROJ/$OLDS/scratchpad/f" 2048
  : > "$TT_TDIR/$OLDS.jsonl"; touch -t 202001010000 "$TT_TDIR/$OLDS.jsonl"
  touch -t 202001010000 "$TT_TDIR/$TT_SID.jsonl"
}
lo_cleanup() { rm -rf "$TMPDIR" "${TROOT_LOGICAL:-}"; unset MEMOKIT_DF_KB MEMOKIT_AUTOCLEAN_OFF MEMOKIT_AUTOCLEAN_SYNC; }

@test "stale leftovers >= reportMinMB give one line naming /memokit:sweep" {
  lo_setup
  run_hook session-start.sh "$TT_PAYLOAD"
  [ "$status" -eq 0 ]
  [ "$(ctx | grep -c '/memokit:sweep')" -eq 1 ]
  ctx | grep -q '2 MB'
  lo_cleanup
}
@test "leftovers below reportMinMB give no line" {
  lo_setup
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en","scratch":{"reportMinMB":50}}'
  run_hook session-start.sh "$TT_PAYLOAD"
  ! ctx | grep -q '/memokit:sweep'
  lo_cleanup
}
@test "non-stale sibling is not counted" {
  lo_setup
  touch -t 203001010000 "$TT_TDIR/$OLDS.jsonl"
  run_hook session-start.sh "$TT_PAYLOAD"
  ! ctx | grep -q '/memokit:sweep'
  lo_cleanup
}
@test "leftover total is cached for check-disk (same file path)" {
  lo_setup
  run_hook session-start.sh "$TT_PAYLOAD"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  f="$TMPDIR/memokit-$h-temp-leftover-$TT_SID"
  [ -f "$f" ]
  [ "$(cat "$f")" -ge 2048 ]
  # check-disk's Stop path reads it
  pl="$(jq -nc --arg s "$TT_SID" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg cwd "$PROJ" '{hook_event_name:"Stop",session_id:$s,transcript_path:$t,cwd:$cwd}')"
  MEMOKIT_DF_KB=$((20*1048576)) run_hook check-disk.sh "$pl"
  printf '%s' "$output" | jq -r '.systemMessage' | grep -q 'other leftovers: 2 MB'
  lo_cleanup
}
@test "cache write refuses a symlink target" {
  lo_setup
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  echo keep > "$TMPDIR/victim"; ln -s "$TMPDIR/victim" "$TMPDIR/memokit-$h-temp-leftover-$TT_SID"
  run_hook session-start.sh "$TT_PAYLOAD"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMPDIR/victim")" = keep ]
  lo_cleanup
}
@test "MEMOKIT_SCRATCH_OFF=1 suppresses line and cache" {
  lo_setup
  MEMOKIT_SCRATCH_OFF=1 run_hook session-start.sh "$TT_PAYLOAD"
  ! ctx | grep -q '/memokit:sweep'
  ! ls "$TMPDIR"/memokit-*-temp-leftover-* >/dev/null 2>&1
  lo_cleanup
}
@test "no temp tree leaves output without leftover line" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  export MEMOKIT_DF_KB=$((500*1048576))
  run_hook session-start.sh '{"session_id":"s","transcript_path":"/nonexistent/x/s.jsonl"}'
  [ "$status" -eq 0 ]
  ! ctx | grep -q '/memokit:sweep'
  unset MEMOKIT_DF_KB
}
@test "free space below the floor adds the low-disk line; above or off does not" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  MEMOKIT_DF_KB=$((10*1048576)) run_hook session-start.sh '{}'
  [ "$status" -eq 0 ]
  ctx | grep -q '10.0 GB'; ctx | grep -q '30 GB'
  MEMOKIT_DF_KB=$((100*1048576)) run_hook session-start.sh '{}'
  ! ctx | grep -q 'DMO-DISK'
  MEMOKIT_DISK_OFF=1 MEMOKIT_DF_KB=$((10*1048576)) run_hook session-start.sh '{}'
  ! ctx | grep -q 'DMO-DISK'
}
@test "leftover worktrees and mk/ branches give one line naming /memokit:sweep" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  export MEMOKIT_DF_KB=$((500*1048576)) MEMOKIT_AUTOCLEAN_OFF=1
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/mk-r1-a" -b mk/r1/a
  git -C "$PROJ" branch mk/r1/b
  run_hook session-start.sh '{}'
  [ "$status" -eq 0 ]
  ctx | grep -F 'DMO-WORKTREES'
  [ "$(ctx | grep -c 'DMO-WORKTREES')" -eq 1 ]
  ctx | grep 'DMO-WORKTREES' | grep -qF '2 leftover'
  ctx | grep 'DMO-WORKTREES' | grep -qF '/memokit:sweep'
  ctx | grep 'DMO-WORKTREES' | grep -Eq '[0-9] (KB|MB|GB)'
  lacks "$(ctx)" 'DMO-DISK'
  [ -d "$PROJ/.claude/worktrees/mk-r1-a" ]; git -C "$PROJ" rev-parse -q --verify refs/heads/mk/r1/b
  unset MEMOKIT_DF_KB MEMOKIT_AUTOCLEAN_OFF
}
@test "no leftover worktrees or mk/ branches: no worktree line" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  git -C "$PROJ" branch feature/x
  run_hook session-start.sh '{}'
  [ "$status" -eq 0 ]
  ctx | grep -q 'Sıradaki adım: demo'
  lacks "$(ctx)" 'WORKTREES'
}
@test "worktree line is in Turkish for a tr project" {
  mk_project
  git -C "$PROJ" branch mk/r1/b
  MEMOKIT_AUTOCLEAN_OFF=1 run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -qF '/memokit:sweep'
  ctx | grep 'DMO-WORKTREES' | grep -qF 'kendin silme'
}
@test "worktree line skips the session's own worktree (payload cwd) and runs no status/rev-list/log" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/agent-me" -b feature/me
  SHIM="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkshim.XXXXXX")"
  real="$(command -v git)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/log"\nexec "%s" "$@"\n' "$SHIM" "$real" > "$SHIM/git"
  chmod +x "$SHIM/git"
  pl="$(jq -nc --arg c "$PROJ/.claude/worktrees/agent-me" '{cwd:$c}')"
  PATH="$SHIM:$PATH" run_hook session-start.sh "$pl"
  [ "$status" -eq 0 ]
  lacks "$(ctx)" 'WORKTREES'
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/mk-r1-a" -b mk/r1/a
  : > "$SHIM/log"
  PATH="$SHIM:$PATH" run_hook session-start.sh "$pl"
  ctx | grep 'DMO-WORKTREES' | grep -qF '1 leftover'
  cat "$SHIM/log"
  [ "$(grep -cE '(^| )(status|rev-list|log)( |$)' "$SHIM/log")" -eq 0 ]
  rm -rf "$SHIM"
}
@test "lanes of an active run are not leftovers: the line names the run and /memokit:resume (final review I1)" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  mkdir -p "$PROJ/.claude/memokit/runs/20261018-1200"
  printf 'status: active\n' > "$PROJ/.claude/memokit/runs/20261018-1200/ledger.md"
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/mk-20261018-1200-L1" -b mk/20261018-1200/L1
  git -C "$PROJ" branch mk/20261018-1200/L2
  run_hook session-start.sh '{}'
  [ "$status" -eq 0 ]
  ctx | grep 'DMO-WORKTREES'
  lacks "$(ctx)" 'leftover worktrees'
  ctx | grep 'DMO-WORKTREES' | grep -F '20261018-1200' | grep -F '/memokit:resume' | grep -qF '2 worktrees or mk/ branches'
  # One more, unrelated lane: both lines, the leftover count excludes the run.
  git -C "$PROJ" branch mk/r9/x
  run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -qF '1 leftover'
  [ "$(ctx | grep -c 'DMO-WORKTREES')" -eq 2 ]
  # Stopped: reported as ordinary leftovers again.
  printf 'status: stopped\n' > "$PROJ/.claude/memokit/runs/20261018-1200/ledger.md"
  run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -qF '3 leftover'
  [ "$(ctx | grep -c 'DMO-WORKTREES')" -eq 1 ]
}
@test "active-run line is in Turkish for a tr project" {
  mk_project
  mkdir -p "$PROJ/.claude/memokit/runs/r1"; printf 'status: active\n' > "$PROJ/.claude/memokit/runs/r1/ledger.md"
  git -C "$PROJ" branch mk/r1/b
  run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -F '/memokit:resume' | grep -qF 'etkin'
}
@test "leftovers under 1 MB are shown in KB, and the line names /memokit:sweep worktrees (final review M2, M8)" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/mk-r1-a" -b mk/r1/a
  run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES'
  ctx | grep 'DMO-WORKTREES' | grep -Eq 'hold [0-9]+ KB of disk'
  lacks "$(ctx)" '0 MB'
  ctx | grep 'DMO-WORKTREES' | grep -qF '/memokit:sweep worktrees'
  mk_project
  git -C "$PROJ" branch mk/r1/b
  run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -qF '/memokit:sweep worktrees'
}

# --- 0.6.1: auto-clean at session start --------------------------------------
@test "auto-clean removes a stale temp entry at session start and says so; nothing left to sweep" {
  lo_setup; unset MEMOKIT_AUTOCLEAN_OFF
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh "$TT_PAYLOAD"
  [ "$status" -eq 0 ]
  [ ! -e "$TT_PROJ/$OLDS" ]
  [ -d "$TT_SESS" ]
  ctx | grep 'DMO-DISK' | grep -qF 'removing 1 stale temp'
  ctx | grep 'DMO-DISK' | grep -qF '2 MB'
  ! ctx | grep -q '/memokit:sweep'
  lo_cleanup
}
@test "auto-clean keeps a stale entry holding .memokit-keep and a fresh one; the kept one is reported" {
  lo_setup; unset MEMOKIT_AUTOCLEAN_OFF
  : > "$TT_PROJ/$OLDS/scratchpad/.memokit-keep"
  S2="aaaaaaaa-0000-0000-0000-000000000002"; F3="aaaaaaaa-0000-0000-0000-000000000003"
  mk_blob "$TT_PROJ/$S2/scratchpad/f" 1024
  : > "$TT_TDIR/$S2.jsonl"; touch -t 202001010000 "$TT_TDIR/$S2.jsonl"
  mk_blob "$TT_PROJ/$F3/scratchpad/f" 1024
  : > "$TT_TDIR/$F3.jsonl"; touch -t 203001010000 "$TT_TDIR/$F3.jsonl"
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh "$TT_PAYLOAD"
  [ "$status" -eq 0 ]
  [ ! -e "$TT_PROJ/$S2" ]
  [ -f "$TT_PROJ/$OLDS/scratchpad/f" ] && [ -f "$TT_PROJ/$F3/scratchpad/f" ]
  ctx | grep -qF 'removing 1 stale temp'
  [ "$(ctx | grep -c '/memokit:sweep')" -eq 1 ]
  ctx | grep '/memokit:sweep' | grep -qF '1 old temp'
  lo_cleanup
}
@test "MEMOKIT_AUTOCLEAN_OFF=1 deletes no temp entry" {
  lo_setup
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh "$TT_PAYLOAD"
  [ -f "$TT_PROJ/$OLDS/scratchpad/f" ]
  ! ctx | grep -qF 'removing'
  lo_cleanup
}
# wt_old WT -- age WT's index past staleAfterHours.
wt_old() { touch -t 202001010000 "$(git -C "$1" rev-parse --path-format=absolute --git-path index)"; }
@test "auto-clean removes old merged-clean worktrees (mk/ branch too) and merged mk/ branches; keeps fresh, dirty and unmerged ones" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  export MEMOKIT_DF_KB=$((500*1048576)) TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkss.XXXXXX")"; unset MEMOKIT_AUTOCLEAN_OFF
  W="$PROJ/.claude/worktrees"
  git -C "$PROJ" worktree add -q "$W/mk-r1-a" -b mk/r1/a; wt_old "$W/mk-r1-a"
  git -C "$PROJ" worktree add -q "$W/agent-x" -b worktree-agent-x; wt_old "$W/agent-x"
  git -C "$PROJ" worktree add -q "$W/mk-r1-fresh" -b mk/r1/fresh
  git -C "$PROJ" worktree add -q "$W/mk-r1-dirty" -b mk/r1/dirty; printf 'wip\n' > "$W/mk-r1-dirty/new.txt"; wt_old "$W/mk-r1-dirty"
  git -C "$PROJ" worktree add -q "$W/mk-r1-un" -b mk/r1/un
  printf 'x\n' > "$W/mk-r1-un/x.txt"; git -C "$W/mk-r1-un" add x.txt
  git -C "$W/mk-r1-un" -c user.email=t@t -c user.name=t commit -qm x; wt_old "$W/mk-r1-un"
  git -C "$PROJ" branch mk/r1/b
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh '{}'
  [ "$status" -eq 0 ]
  [ ! -e "$W/mk-r1-a" ]; ! git -C "$PROJ" rev-parse -q --verify refs/heads/mk/r1/a
  [ ! -e "$W/agent-x" ]; git -C "$PROJ" rev-parse -q --verify refs/heads/worktree-agent-x
  ! git -C "$PROJ" rev-parse -q --verify refs/heads/mk/r1/b
  [ -d "$W/mk-r1-fresh" ] && [ -f "$W/mk-r1-dirty/new.txt" ] && [ -f "$W/mk-r1-un/x.txt" ]
  # this start launched the check: one line, no sweep suggestion yet
  ctx | grep 'DMO-WORKTREES' | grep -qF '6 leftover'
  ctx | grep 'DMO-WORKTREES' | grep -qF 'checking them in the background'
  ! ctx | grep -qF '/memokit:sweep'
  # the next start has a fresh result for the 3 left: the usual report line
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -qF '3 leftover'
  ctx | grep 'DMO-WORKTREES' | grep -qF '/memokit:sweep worktrees'
  ! ctx | grep -qF 'checking them'
  [ -d "$W/mk-r1-fresh" ]
  # a day later (result over an hour old): still the report line; the check reruns quietly
  touch -t 202001010000 "$TMPDIR"/memokit-*-wt-autoclean
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh '{}'
  ctx | grep 'DMO-WORKTREES' | grep -qF '/memokit:sweep worktrees'
  ! ctx | grep -qF 'checking them'
  rm -rf "$TMPDIR"; unset MEMOKIT_DF_KB
}
@test "auto-clean keeps an old merged-clean worktree that a process runs in or that has a recent transcript" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  export TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkss.XXXXXX")" CLAUDE_CONFIG_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkcc.XXXXXX")"; unset MEMOKIT_AUTOCLEAN_OFF
  W="$(cd -P "$PROJ" && pwd -P)/.claude/worktrees"
  git -C "$PROJ" worktree add -q "$W/mk-r1-t" -b mk/r1/t; wt_old "$W/mk-r1-t"
  slug="$(printf '%s' "$W/mk-r1-t" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$slug"; : > "$CLAUDE_CONFIG_DIR/projects/$slug/s.jsonl"
  pid=""
  if command -v lsof >/dev/null 2>&1; then
    git -C "$PROJ" worktree add -q "$W/mk-r1-p" -b mk/r1/p; wt_old "$W/mk-r1-p"
    (cd "$W/mk-r1-p" && exec sleep 60) & pid=$!
  fi
  MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh '{}'
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  [ -d "$W/mk-r1-t" ]
  if [ -n "$pid" ]; then [ -d "$W/mk-r1-p" ]; fi
  rm -rf "$TMPDIR" "$CLAUDE_CONFIG_DIR"
}
@test "MEMOKIT_AUTOCLEAN_OFF=1 removes no worktree or branch" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en"}'
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/mk-r1-a" -b mk/r1/a; wt_old "$PROJ/.claude/worktrees/mk-r1-a"
  MEMOKIT_AUTOCLEAN_OFF=1 MEMOKIT_AUTOCLEAN_SYNC=1 run_hook session-start.sh '{}'
  [ -d "$PROJ/.claude/worktrees/mk-r1-a" ]
  ! ctx | grep -qF 'removing'
}
