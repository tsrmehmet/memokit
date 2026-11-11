#!/usr/bin/env bats
load helpers

# 0.8.0 final wave (C1, C2): every PreToolUse guard decides before the 5 s
# hook timeout, whatever the command does to its scanner. Each payload below
# took 5 to 40+ s (or never finished) before the fix and was then let
# through by Claude Code. Measured under tr_TR.UTF-8, the locale in which
# bash 3.2's pattern operations are slowest.

BCFG='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en","guardedDirs":["src","tests"],
"careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]},
"remote":{"deployBranches":["deploy","public-release"],"hosts":["31.210.53.162","prod.example.com"],"readOnlyFirstWords":["pm2-list"]}}'

# tr_TR.UTF-8 when the machine has it (macOS, the user's locale); a missing
# locale would make bash and perl print setlocale warnings into the hook
# output (Docker ubuntu, CI runners), so fall back to C.UTF-8 there.
setup() {
  if locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\{0,1\}8$'; then
    export LANG=tr_TR.UTF-8 LC_ALL=tr_TR.UTF-8
  else
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
  fi
}

rep() { s="$1" awk -v n="$2" 'BEGIN { s = ENVIRON["s"]; for (i = 0; i < n; i++) printf "%s", s }'; }

# hook_file HOOK FILE [AGENT] -- run HOOK on the Bash command in FILE (a
# subagent payload when AGENT is given); sets output/status and ms.
hook_file() {
  local pl="$BATS_TEST_TMPDIR/payload.json" t0 t1
  jq -Rs --arg cwd "$PROJ" --arg a "${3:-}" \
    '{tool_name:"Bash",tool_input:{command:.},cwd:$cwd,session_id:"s1"} + (if $a == "" then {} else {agent_id:$a} end)' < "$2" > "$pl"
  t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  run perl -e 'alarm 10; exec @ARGV' "$MK_BASH" -c '"$0" "$1" < "$2" 2>/dev/null' "$MK_BASH" "$HOOKS/$1" "$pl"
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  ms=$((t1 - t0))
}

# check HOOK FILE AGENT -- a deny, printed once, in under 3 s.
check() {
  hook_file "$1" "$2" "$3"
  echo "$(basename "$2") $1: ${ms} ms" >&3
  [ "$status" -eq 0 ] || { echo "$2: status $status"; return 1; }
  [ "$(decision)" = deny ] || { echo "$2: expected deny, got [${output:0:200}]"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision":')" -eq 1 ] || { echo "$2: deny printed more than once"; return 1; }
  [ "$ms" -lt 3000 ] || { echo "$2: ${ms} ms"; return 1; }
}

mk_payloads() {
  local d="$BATS_TEST_TMPDIR" nl='
'
  printf 'echo {a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}' > "$d/brace8"
  { rep "<<1$nl" 16000; printf 'git push origin deploy'; } > "$d/heredoc16k"
  rep "ls ../x$nl" 1000 > "$d/dotdot8k"
  rep "ls ../x$nl" 2500 > "$d/dotdot20k"
  rep "echo \$x$nl" 2500 > "$d/dollar20k"
  rep "ls x{a,b}$nl" 2000 > "$d/bracelines20k"
  { printf '$X push '; rep ')' 3900; printf " 'a;b'$nl"; printf '$X push '; rep ')' 3900; printf " 'a;b'"; } > "$d/parens"
  { rep "<<1$nl" 16000; printf 'echo x > src/a.cs'; } > "$d/edit_heredoc16k"
  { rep "<<1$nl" 6000; printf "cp /tmp/x src/y.cs"; } > "$d/edit_heredoc6k"
  rep "echo x > src/a.cs$nl" 3800 > "$d/edit_echo64k"
}

@test "C1: the subagent guard denies the review's slow commands within 3 s" {
  mk_project "$BCFG"
  mk_payloads
  local f bad=0
  for f in brace8 heredoc16k dotdot8k dotdot20k dollar20k bracelines20k parens; do
    check guard-subagent-authority.sh "$BATS_TEST_TMPDIR/$f" agent-1 || bad=1
  done
  [ "$bad" = 0 ]
}

@test "C2: guard-edit decides the review's slow commands within 3 s" {
  mk_project "$BCFG"
  mk_payloads
  local f bad=0
  for f in edit_heredoc16k edit_heredoc6k edit_echo64k; do
    check guard-edit.sh "$BATS_TEST_TMPDIR/$f" || bad=1
  done
  [ "$bad" = 0 ]
  # 3 800 copies of one target are one distinct target: the write deny, not
  # the too-many-targets one
  reason | grep -qF 'Writing under' || { echo "$(reason | cut -c1-160)"; false; }
}

@test "C1 (M4): guard-destructive denies the parenthesis run as a remote change, not as out of time" {
  mk_project "$BCFG"
  mk_payloads
  check guard-destructive.sh "$BATS_TEST_TMPDIR/parens"
  reason | grep -qF 'deploy-push' || { echo "$(reason | cut -c1-200)"; false; }
  lacks "$output" 'ran out of time'
}

# burn HOOK MODE CMD [AGENT] -- run HOOK with the test-only MEMOKIT_TEST_BURN
# hook (lib/budget.sh); sets output/status and the wall time in s.
burn() {
  local s=$SECONDS
  export MEMOKIT_TEST_BURN="$2"
  run_hook "$1" "$(bash_payload "$3" "${4:-}")"
  unset MEMOKIT_TEST_BURN
  secs=$((SECONDS - s))
}

@test "C1/C2: the subagent guard and guard-edit deny when they run out of time or crash" {
  mk_project "$BCFG"
  local h a m
  for h in guard-subagent-authority.sh guard-edit.sh; do
    a=""; [ "$h" = guard-subagent-authority.sh ] && a=agent-1
    for m in 1 sub cpu; do
      burn "$h" "$m" 'ls -la' "$a"
      # the watchdog (1, sub) answers in about 3.3 s; the CPU limit alone
      # (cpu) after 4 s of CPU time, slower in wall time on a busy runner
      lim=5; [ "$m" = cpu ] && lim=9
      [ "$secs" -le "$lim" ] || { echo "$h $m took $secs s"; false; }
      [ "$(decision)" = deny ] || { echo "$h $m: [$output]"; false; }
      [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision":')" -eq 1 ]
      reason | grep -qF 'ran out of time' || { echo "$h $m: $(reason)"; false; }
    done
    burn "$h" crash 'ls -la' "$a"
    printf '%s' "$output" | grep -qF '"permissionDecision": "deny"' || { echo "$h crash: [$output]"; false; }
    printf '%s' "$output" | grep -qF 'could not finish'
    # a decision made before the watchdog fires is kept: a pass stays
    # silent, a deny is printed once
    burn "$h" late 'ls -la' "$a"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$h late pass: [$output]"; false; }
  done
  burn guard-subagent-authority.sh late2 'git commit -m x' agent-1
  [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision":')" -eq 1 ] || { echo "late2: [$output]"; false; }
  reason | grep -qF 'git commit'
  lacks "$output" 'ran out of time'
  burn guard-edit.sh late2 'echo x > src/a.cs'
  [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision":')" -eq 1 ] || { echo "late2: [$output]"; false; }
  lacks "$output" 'ran out of time'
  # without the test hook the same commands are decided as before
  run_hook guard-subagent-authority.sh "$(bash_payload 'ls -la' agent-1)"
  [ -z "$output" ]
  run_hook guard-edit.sh "$(bash_payload 'ls -la')"
  [ -z "$output" ]
}

@test "C1: the subagent bounds deny as too large; under them the same shapes pass" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR" nl='
'
  rep "ls ../x$nl" 600 > "$d/up600"
  hook_file guard-subagent-authority.sh "$d/up600" agent-1
  [ "$(decision)" = deny ]; reason | grep -qF 'too large to check'
  rep "ls ../x$nl" 400 > "$d/up400"
  hook_file guard-subagent-authority.sh "$d/up400" agent-1
  [ -z "$output" ] || { echo "$(reason)"; false; }
  # a long document written with a heredoc (no remote, no config name) passes
  { printf "cat > docs/x.md <<'EOF'\n"; rep "Word is here. Next line, see ../notes and the {draft}.$nl" 400; printf 'EOF\n'; } > "$d/doc"
  hook_file guard-subagent-authority.sh "$d/doc" agent-1
  echo "doc: ${ms} ms" >&3
  [ -z "$output" ] || { echo "$(reason | cut -c1-200)"; false; }
  [ "$ms" -lt 3000 ]
  # more than 64 KiB
  rep "echo hello world$nl" 4000 > "$d/big"
  hook_file guard-subagent-authority.sh "$d/big" agent-1
  [ "$(decision)" = deny ]; reason | grep -qF 'too large to check'
  # a brace word past 64 alternatives is a config reference (fail closed),
  # a small one is expanded and judged
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo {a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}' agent-1)"
  [ "$(decision)" = deny ]; reason | grep -qF 'memokit.json'
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo {a,b}{c,d}' agent-1)"
  [ -z "$output" ]
  run_hook guard-subagent-authority.sh "$(bash_payload 'rm -f .{c,x}laude/memokit.json' agent-1)"
  [ "$(decision)" = deny ]; reason | grep -qF 'memokit.json'
}

@test "C2: guard-edit: more than 64 distinct write targets deny the main session only" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR"
  awk 'BEGIN { for (i = 0; i < 100; i++) printf "echo x > out/f%d.txt\n", i }' > "$d/many"
  hook_file guard-edit.sh "$d/many"
  [ "$(decision)" = deny ]; reason | grep -qF 'more than 64'
  hook_file guard-edit.sh "$d/many" agent-1
  [ -z "$output" ]
  awk 'BEGIN { for (i = 0; i < 50; i++) printf "echo x > out/f%d.txt\n", i }' > "$d/some"
  hook_file guard-edit.sh "$d/some"
  [ -z "$output" ]
}

@test "C1/C2: heredoc bodies are data (one awk pass), bash -c bodies are commands" {
  mk_project "$BCFG"
  local T='	'
  # subagent: a git command in a heredoc body is text; in bash -c it runs
  run_hook guard-subagent-authority.sh "$(bash_payload "cat > docs/x.md <<'EOF'
git commit -m x
EOF" agent-1)"
  [ -z "$output" ] || { echo "$(reason)"; false; }
  run_hook guard-subagent-authority.sh "$(bash_payload "cat > docs/x.md <<-\"END\"
${T}git commit -m x
${T}${T}END
git status" agent-1)"
  [ -z "$output" ] || { echo "$(reason)"; false; }
  run_hook guard-subagent-authority.sh "$(bash_payload "cat > docs/x.md <<EOF
x
EOF
git commit -m y" agent-1)"
  [ "$(decision)" = deny ]
  local c
  for c in 'bash -c "git commit -m x"' "sh -c 'git stash'" 'zsh -c "echo a; git push origin main"'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = deny ] || { echo "allowed: $c"; false; }
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'bash -c "echo git commit is a phrase"' agent-1)"
  [ -z "$output" ]
  # guard-edit (main session): a write in a heredoc body is text, the
  # heredoc's own redirect is a write
  run_hook guard-edit.sh "$(bash_payload "cat > docs/x.md <<'EOF'
cp /tmp/x src/y.cs
EOF")"
  [ -z "$output" ] || { echo "$(reason)"; false; }
  run_hook guard-edit.sh "$(bash_payload "cat > src/x.cs <<EOF
x
EOF")"
  [ "$(decision)" = deny ]
  run_hook guard-edit.sh "$(bash_payload "echo a 2>&1 >| src/z.cs")"
  [ "$(decision)" = deny ]
  run_hook guard-edit.sh "$(bash_payload "echo a 2>&1 > docs/z.md")"
  [ -z "$output" ]
}

@test "N1: a jq that stalls before the first decision still gets the budget deny within 4 s (all three guards)" {
  mk_project "$BCFG"
  local stub="$BATS_TEST_TMPDIR/stalljq" h a pl t0 t1 opath="$PATH"
  mkdir -p "$stub"
  printf '#!/bin/sh\nsleep 20\nexec %s "$@"\n' "$(command -v jq)" > "$stub/jq"
  chmod +x "$stub/jq"
  for h in guard-destructive.sh guard-subagent-authority.sh guard-edit.sh; do
    a=""; [ "$h" = guard-subagent-authority.sh ] && a=agent-1
    pl="$(bash_payload 'ls -la' "$a")"
    export PATH="$stub:$opath"
    t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    run_hook "$h" "$pl"
    t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    export PATH="$opath"
    echo "$h: $((t1 - t0)) ms" >&3
    [ "$((t1 - t0))" -lt 4000 ] || { echo "$h took $((t1 - t0)) ms"; false; }
    [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision": "deny"')" -eq 1 ] || { echo "$h: [$output]"; false; }
    printf '%s' "$output" | grep -qF 'ran out of time' || { echo "$h: [$output]"; false; }
  done
}

@test "Residuals 2: a watchdog whose sleep is killed from outside still denies; an early exit leaves no sleep" {
  mk_project "$BCFG"
  local h a d="$BATS_TEST_TMPDIR" hp c wd sl i t0 t1
  for h in guard-destructive.sh guard-subagent-authority.sh guard-edit.sh; do
    a=""; [ "$h" = guard-subagent-authority.sh ] && a=agent-1
    bash_payload "ssh prod.example.com 'systemctl restart x'" "$a" > "$d/pl.json"
    t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    MEMOKIT_TEST_BURN=1 "$MK_BASH" "$HOOKS/$h" < "$d/pl.json" > "$d/out.json" 2>/dev/null &
    hp=$!
    # the watchdog is the hook's child whose child is a sleep
    wd=""; sl=""; i=0
    while [ -z "$sl" ] && [ "$i" -lt 40 ]; do
      for c in $(pgrep -P "$hp"); do
        sl="$(pgrep -x -P "$c" sleep | head -n 1)"
        [ -n "$sl" ] && { wd="$c"; break; }
      done
      [ -n "$sl" ] || sleep 0.05
      i=$((i + 1))
    done
    [ -n "$sl" ] || { kill "$hp" 2>/dev/null; echo "$h: no watchdog sleep found"; false; }
    sleep 0.5
    kill "$sl"
    wait "$hp" || true
    t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    echo "$h: $((t1 - t0)) ms" >&3
    output="$(cat "$d/out.json")"
    [ "$(decision)" = deny ] || { echo "$h: [$output]"; false; }
    [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision":')" -eq 1 ]
    reason | grep -qF 'ran out of time'
    # the watchdog answered at once, not the CPU limit at 4 s
    [ "$((t1 - t0))" -lt 3000 ] || { echo "$h took $((t1 - t0)) ms"; false; }
  done
  # a hook that decides early stops its watchdog and the watchdog's sleep
  bash_payload 'ls -la' agent-1 > "$d/pl.json"
  "$MK_BASH" "$HOOKS/guard-subagent-authority.sh" < "$d/pl.json" > "$d/out.json" 2>/dev/null &
  hp=$!
  wait "$hp"
  [ ! -s "$d/out.json" ]
  sleep 0.3
  ! pgrep -f "sleep 3.3" >/dev/null || { pgrep -fl "sleep 3.3"; false; }
}
