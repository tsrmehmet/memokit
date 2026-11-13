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
# subagent payload when AGENT is given); sets output/status, ms (wall) and
# cpu: the hook's user+sys CPU time in ms, its children included (the bash
# time keyword, TIMEFORMAT='%U %S'). The 2 s bounds below are on cpu: they
# exist to catch a superlinear pattern blow-up (seconds of CPU), and a busy
# machine stretches wall time without one. 2 s: the heaviest payloads take
# 750-970 ms of CPU on an M4 Max (more under load, more on a Docker
# runner), half the hook's own 4 s CPU budget.
hook_file() {
  local pl="$BATS_TEST_TMPDIR/payload.json" tf="$BATS_TEST_TMPDIR/cpu.txt" t0 t1
  jq -Rs --arg cwd "$PROJ" --arg a "${3:-}" \
    '{tool_name:"Bash",tool_input:{command:.},cwd:$cwd,session_id:"s1"} + (if $a == "" then {} else {agent_id:$a} end)' < "$2" > "$pl"
  rm -f "$tf"
  t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  run perl -e 'alarm 10; exec @ARGV' "$MK_BASH" -c 'TIMEFORMAT="%U %S"; { time "$0" "$1" < "$2" 2>/dev/null; } 2> "$3"' \
    "$MK_BASH" "$HOOKS/$1" "$pl" "$tf"
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  ms=$((t1 - t0))
  cpu="$(tr ',' '.' < "$tf" 2>/dev/null | LC_ALL=C awk 'NF == 2 { printf "%d", ($1 + $2) * 1000 }')"
  cpu="${cpu:-99999}"
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

# 0.8.1 (spec 3b): the settings-file match on a 64 KiB command, the matching
# word near the end, decides within 2 s of CPU (tr_TR.UTF-8 when listed, setup()).
@test "settings: the subagent guard decides a 64 KiB command naming a settings file within 2 s of CPU" {
  mk_project "$BCFG"
  HOME="$(mktemp -d "${MK_FIXTMP}/mkhome.XXXXXX")"
  export HOME
  mkdir -p "$HOME/.claude"
  printf '{}\n' > "$HOME/.claude/settings.json"
  printf '{}\n' > "$PROJ/.claude/settings.local.json"
  ln "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/hl"
  local d="$BATS_TEST_TMPDIR" nl='
' f
  { rep "ls src/a.cs$nl" 5300; printf 'echo x > ~/.claude/settings.json'; } > "$d/set_tail"
  { awk 'BEGIN { for (i = 0; i < 2000; i++) printf "cat .claude/settings.json.%d\n", i }'; printf 'cp /tmp/x .claude/settings.local.json'; } > "$d/set_words"
  { awk 'BEGIN { for (i = 0; i < 7200; i++) printf "ls w%d\n", i }'; printf "echo x > %s" "$d/hl"; } > "$d/set_inode"
  { rep "ls src/a.cs$nl" 5300; printf 'cat .claude/settings.json'; } > "$d/set_read"
  # fix round 1: computed/glob words, home-mapped device:inode words, ~user,
  # and the 2>/dev/null / git read allowlist
  ln "$HOME/.claude/settings.json" "$HOME/hl2"
  # fix round 2: a CLAUDE_CONFIG_DIR spelling named near the end enables the
  # glob trigger (a fixed-string pass over the text); a comma in a link name
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  ln "$HOME/.claude/settings.json" "$d/h,l"
  { awk 'BEGIN { for (i = 0; i < 3800; i++) printf "ls src/a%d*.cs\n", i }'; printf 'cp x %s/s*.json' "$CLAUDE_CONFIG_DIR"; } > "$d/set_ccd"
  { awk 'BEGIN { for (i = 0; i < 6200; i++) printf "ls a,%d\n", i }'; printf 'echo x > %s' "$d/h,l"; } > "$d/set_comma"
  # fix round 3: the expansion/glob pass on every command (an expansion
  # word ending in settings.json; computed .json names under a settings dir;
  # // in a CLAUDE_CONFIG_DIR spelling); and the same glob words allowed
  { awk 'BEGIN { for (i = 0; i < 3800; i++) printf "ls src/a%d*.cs\n", i }'; printf 'cp x $OUT/settings.json'; } > "$d/set_b2"
  { awk 'BEGIN { for (i = 0; i < 3300; i++) printf "ls src/a%d*.json\n", i }'; printf 'cp x $CLAUDE_CONFIG_DIR/$F.json'; } > "$d/set_dname"
  { awk 'BEGIN { for (i = 0; i < 3800; i++) printf "ls src/a%d*.cs\n", i }'; printf 'cp x %s//%s/s*.json' "${CLAUDE_CONFIG_DIR%/*}" "${CLAUDE_CONFIG_DIR##*/}"; } > "$d/set_ccd2"
  { awk 'BEGIN { for (i = 0; i < 3300; i++) printf "ls src/a%d*.json\n", i }'; printf 'ls x'; } > "$d/set_globs_ok"
  # fix round 4: each distinct directory part of a .json glob is resolved
  # physically (cd -P, test -ef): 3800 existing directories, then a glob in
  # a symlink to ~/.claude
  mkdir "$PROJ/t"
  (cd "$PROJ/t" && awk 'BEGIN { for (i = 0; i < 3400; i++) print "d" i }' | xargs mkdir)
  ln -s "$HOME/.claude" "$d/sl"
  { awk 'BEGIN { for (i = 0; i < 3400; i++) printf "ls t/d%d/a*.json\n", i }'; printf 'cp x %s/sl/s*.json' "$d"; } > "$d/set_phys"
  # fix round 5: 3800 .json globs in directories not on disk (each fails
  # cd -P), then ln near the end (the ln regex runs over the whole text)
  { awk 'BEGIN { for (i = 0; i < 3800; i++) printf "ls n%d/a*.json\n", i }'; printf 'ln -s $D %s/l5 && cp x %s/l5/$F.json' "$d" "$d"; } > "$d/set_ln"
  { awk 'BEGIN { for (i = 0; i < 3800; i++) printf "ls src/a%d*.cs\n", i }'; printf 'cp x ~/.claude/s*.json'; } > "$d/set_glob"
  { awk 'BEGIN { for (i = 0; i < 5800; i++) printf "ls ~/w%d\n", i }'; printf 'echo x > $HOME/hl2'; } > "$d/set_home"
  { awk 'BEGIN { for (i = 0; i < 5100; i++) printf "ls ~u%d/x\n", i }'; printf 'echo x > ~root/.claude/settings.json'; } > "$d/set_user"
  { awk 'BEGIN { for (i = 0; i < 1200; i++) printf "grep -e x f%d a%d b%d c%d d%d 2>/dev/null 2>&1\n", i, i, i, i, i }'; printf 'cat .claude/settings.json 2>&1 | head'; } > "$d/set_ro"
  for f in set_tail set_words set_inode set_glob set_home set_user set_ccd set_comma set_b2 set_dname set_ccd2 set_phys set_ln; do
    n="$(wc -c < "$d/$f")"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-subagent-authority.sh "$d/$f" agent-1
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    [ "$(decision)" = deny ] || { echo "$f: expected deny, got [${output:0:200}]"; false; }
    reason | grep -qF 'may NOT change Claude Code settings' || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  for f in set_read set_ro; do
    n="$(wc -c < "$d/$f")"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-subagent-authority.sh "$d/$f" agent-1
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    [ -z "$output" ] || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  # 3300 glob lines: the remote scan of this config (BCFG) denies them as a
  # remote change at base too; the settings and config gates must not.
  hook_file guard-subagent-authority.sh "$d/set_globs_ok" agent-1
  echo "set_globs_ok: ${ms} ms wall, ${cpu} ms cpu" >&3
  lacks "$(reason)" 'Claude Code settings'
  lacks "$(reason)" 'configuration'
  [ "$cpu" -lt 2000 ] || { echo "set_globs_ok: ${cpu} ms cpu (${ms} ms wall)"; false; }
}

# 0.8.1 (spec 3c): the computed-write state check on a 64 KiB command, the
# matching word near the end, decides within 2 s of CPU (tr_TR.UTF-8 when listed,
# setup()); long single lines of write-position words that never complete a
# match do too.
@test "state: guard-destructive decides a 64 KiB command with a computed state write within 2 s of CPU" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR" nl='
' f n
  { rep "ls src/a.cs$nl" 5400; printf 'cp f /tmp/memokit-`cksum<<<x`-y'; } > "$d/st_tail"
  { printf 'cp'; rep ' $x/memokit-a' 5000; printf ' /tmp/memokit-$h'; } > "$d/st_cpline"
  { printf 'echo x | tee'; rep ' -a $x/memokit' 4600; printf ' "$T/careful-$s"'; } > "$d/st_teeline"
  { rep "echo x >> \$T/memokit.log$nl" 2500; printf 'dd if=f of=$TMPDIR/memokit-{1,2}-z'; } > "$d/st_dd"
  # fix round 1: a cp destination followed by redirections (I2)
  { printf 'cp f /tmp/memokit-$h-y'; rep ' 2>/dev/null' 5400; } > "$d/st_cpredir"
  for f in st_tail st_cpline st_teeline st_dd st_cpredir; do
    n="$(wc -c < "$d/$f")"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-destructive.sh "$d/$f"
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    [ "$(decision)" = deny ] || { echo "$f: expected deny, got [${output:0:200}]"; false; }
    reason | grep -qF 'approval files are blocked' || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  # near misses on one long line: cp sources, tee words without an
  # expansion, > targets without memokit-/careful-
  { printf 'cp'; rep ' $x/memokit-a' 5000; printf ' ./dst'; } > "$d/st_cpsrc"
  { printf 'echo x | tee'; rep ' -a /x/memokit-' 4300; printf ' out'; } > "$d/st_teelit"
  { rep 'echo x > $T/memokit; ' 3100; printf 'ls'; } > "$d/st_gt"
  { printf 'cp /tmp/memokit-$h-y'; rep ' 2>/dev/null' 5400; printf ' ./dst'; } > "$d/st_redirsrc"
  for f in st_cpsrc st_teelit st_gt st_redirsrc; do
    n="$(wc -c < "$d/$f")"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-destructive.sh "$d/$f"
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    lacks "$(reason)" 'approval files are blocked'
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
}

# Fix round 1 (I1): past 64 KiB (too-large, approvable) a computed state
# write is still careful-state, never approvable; within the budget.
@test "state: a command past 64 KiB with a computed state write is careful-state within 2 s of CPU" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR" nl='
' f n
  { rep "ls src/a.cs$nl" 6000; printf 'cp f /tmp/memokit-`cksum<<<x`-y'; } > "$d/big_tail"
  { printf 'cp'; rep ' $x/memokit-a' 5600; printf ' /tmp/memokit-$h 2>/dev/null'; } > "$d/big_cpline"
  # fix round 2: a form the write ERE misses ($( ... ) with a blank) is
  # careful-state past the cap all the same (literal, fail-closed test)
  { rep "ls src/a.cs$nl" 6000; printf 'cp f memokit-$(id -u)'; } > "$d/big_dollar"
  for f in big_tail big_cpline big_dollar; do
    n="$(wc -c < "$d/$f")"; [ "$n" -gt 65536 ] && [ "$n" -le 80000 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-destructive.sh "$d/$f"
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    [ "$(decision)" = deny ] || { echo "$f: expected deny, got [${output:0:200}]"; false; }
    reason | grep -qF 'approval files are blocked' || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  # fix round 2: past the cap the check is literal (memokit-/careful- and
  # any $, backtick or {), fail closed; without an expansion only too-large
  { rep "ls src/a.cs$nl" 6000; printf 'npm pack > memokit-1.tgz'; } > "$d/big_lit"
  hook_file guard-destructive.sh "$d/big_lit"
  echo "big_lit: ${ms} ms wall, ${cpu} ms cpu" >&3
  [ "$(decision)" = deny ]
  lacks "$(reason)" 'approval files are blocked'
  lacks "$(reason)" 'careful-state'
  reason | grep -qF 'too-large' || { echo "big_lit: $(reason | cut -c1-200)"; false; }
  [ "$cpu" -lt 2000 ] || { echo "big_lit: ${cpu} ms cpu (${ms} ms wall)"; false; }
}

# 0.8.1 (spec 4): careful-config (the session-start snapshot) is a literal
# state name: careful-state within 2 s of CPU at 64 KiB, and past the cap too.
@test "state: a command naming careful-config is careful-state within 2 s of CPU, at 64 KiB and past the cap" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR" nl='
' f n
  { rep "ls src/a.cs$nl" 5400; printf 'echo {} > /x/memokit-1-careful-config-s1'; } > "$d/cfg_tail"
  { rep "ls src/a.cs$nl" 6000; printf 'cat /x/memokit-1-Careful-Config-s1'; } > "$d/cfg_big"
  for f in cfg_tail cfg_big; do
    n="$(wc -c < "$d/$f" | tr -d ' ')"
    hook_file guard-destructive.sh "$d/$f"
    echo "$f ($n bytes): ${ms} ms wall, ${cpu} ms cpu" >&3
    [ "$(decision)" = deny ] || { echo "$f: expected deny, got [${output:0:200}]"; false; }
    reason | grep -qF 'approval files are blocked' || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  [ "$(wc -c < "$d/cfg_tail")" -le 65536 ]
  [ "$(wc -c < "$d/cfg_big")" -gt 65536 ]
}

# 0.8.1 (spec 8): the integrity check's records and alert markers
# (careful-integrity-*) are literal state names too.
@test "state: a command naming careful-integrity or careful-armed is careful-state within 2 s of CPU, at 64 KiB and past the cap" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR" nl='
' f n
  { rep "ls src/a.cs$nl" 5400; printf 'rm -f /x/memokit-1-careful-integrity-alert-s1'; } > "$d/ig_tail"
  { rep "ls src/a.cs$nl" 6000; printf 'cat /x/memokit-1-Careful-Integrity-s1-t1'; } > "$d/ig_big"
  { rep "ls src/a.cs$nl" 5400; printf 'rm /x/memokit-1-careful-armed-s1-a1'; } > "$d/armed_tail"
  for f in ig_tail ig_big armed_tail; do
    n="$(wc -c < "$d/$f" | tr -d ' ')"
    hook_file guard-destructive.sh "$d/$f"
    echo "$f ($n bytes): ${ms} ms wall, ${cpu} ms cpu" >&3
    [ "$(decision)" = deny ] || { echo "$f: expected deny, got [${output:0:200}]"; false; }
    reason | grep -qF 'approval files are blocked' || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  [ "$(wc -c < "$d/ig_tail")" -le 65536 ]
  [ "$(wc -c < "$d/ig_big")" -gt 65536 ]
}

# Task 6 fix round 1 (I2): the session-start rule (grep + the read-shape
# regex, LC_ALL=C) on 64 KiB: a run near the end denies, a long plain read
# passes, both within 2 s of CPU.
@test "session-start: the subagent guard decides a 64 KiB command naming session-start.sh within 2 s of CPU" {
  mk_project "$BCFG"
  local d="$BATS_TEST_TMPDIR" nl='
' f n
  { rep "ls src/a.cs$nl" 5400; printf 'bash hooks/session-start.sh'; } > "$d/ss_tail"
  { printf 'cat'; rep ' hooks/session-start.sh' 2800; printf ' | grep -n x | head -5'; } > "$d/ss_read"
  { printf 'cat'; rep ' hooks/session-start.sh' 2800; printf ' | bash'; } > "$d/ss_pipe"
  for f in ss_tail ss_read ss_pipe; do
    n="$(wc -c < "$d/$f" | tr -d ' ')"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-subagent-authority.sh "$d/$f" agent-1
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    case "$f" in
      ss_read) [ "$(decision)" = allow ] || { echo "$f: $(reason | cut -c1-200)"; false; } ;;
      *) [ "$(decision)" = deny ] || { echo "$f: expected deny"; false; }
         reason | grep -qF 'session-start hook' || { echo "$f: $(reason | cut -c1-200)"; false; } ;;
    esac
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
  # Final review (item 4): one awk over the glob/expansion words reads the
  # last component of each as a wildcard pattern (whole-component
  # substitutions, at most 16 fixed characters reach the regex). Near the
  # end: a glob that could name session-start.sh; 64 KiB of glob words that
  # cannot; one 64 KiB component of wildcards, alone and ending in a
  # session-start.s? tail.
  { awk 'BEGIN { for (i = 0; i < 3700; i++) printf "ls src/a%d*.cs\n", i }'; printf 'bash hooks/*tart.sh'; } > "$d/ss_glob"
  { awk 'BEGIN { for (i = 0; i < 3700; i++) printf "ls src/a%d*.cs\n", i }'; printf 'ls x'; } > "$d/ss_words"
  { printf 'echo x/'; rep '${a}[b]?*' 7000; } > "$d/ss_long"
  { printf 'bash x/'; rep '$x' 32000; printf 'session-start.s?'; } > "$d/ss_longhit"
  # $( or a backquote with start.sh or session anywhere (two fixed-string
  # greps): a substitution early and session-start spelled through one at
  # the end; substitutions without either word
  { rep 'echo $(a $(b `c`)) ' 3200; printf 'bash hooks/$(echo session)-start.sh'; } > "$d/ss_cs"
  { rep 'echo $(a $(b `c`)) ' 3200; printf 'ls x'; } > "$d/ss_csok"
  for f in ss_glob ss_words ss_long ss_longhit ss_cs ss_csok; do
    n="$(wc -c < "$d/$f" | tr -d ' ')"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-subagent-authority.sh "$d/$f" agent-1
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    case "$f" in
      ss_glob|ss_longhit|ss_cs) reason | grep -qF 'session-start hook' || { echo "$f: $(reason | cut -c1-200)"; false; } ;;
      # (the remote scan of BCFG may deny 3700 glob lines; this rule must not)
      *) lacks "$(reason)" 'session-start hook' ;;
    esac
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
}

# 0.8.1 (spec 7): the plugin gate joins every word of a command that does not
# only read to the cwd and the cd targets (one awk), resolves each distinct
# directory part physically (builtin cd -P) and tests each path for a
# symlink. The hook runs from a copy in a temp plugin root; the write into it
# comes at the end of 64 KiB: after plain writes, after 5600 distinct words,
# after 3400 existing directories or 10 500 words on one line (then through
# a symlinked directory), after comma words and two cd targets. The same
# shapes without the write pass, and 7800 quoted words (the flat view has the
# same words: the gate runs once).
@test "plugins: the subagent guard decides a 64 KiB command writing a plugin file within 2 s of CPU" {
  mk_project "$BCFG"
  HOME="$BATS_TEST_TMPDIR/home"
  export HOME
  mkdir -p "$HOME/.claude/plugins"
  local d="$BATS_TEST_TMPDIR" nl='
' f n p
  p="$d/plug"
  mkdir -p "$p"
  cp -R "$MK_REPO/hooks" "$p/hooks"
  HOOKS="$p/hooks"
  mkdir "$PROJ/t"
  (cd "$PROJ/t" && awk 'BEGIN { for (i = 0; i < 3400; i++) print "d" i }' | xargs mkdir)
  ln -s "$p/hooks" "$PROJ/src/ldir"
  { rep "echo x > src/a.cs$nl" 3500; printf 'sed -i s/a/b/ %s/hooks/lib/common.sh' "$p"; } > "$d/pl_tail"
  { awk 'BEGIN { for (i = 0; i < 5600; i++) printf "cp x w%d\n", i }'; printf 'echo x > %s/hooks/a.sh' "$p"; } > "$d/pl_words"
  { awk 'BEGIN { for (i = 0; i < 3400; i++) printf "cp x t/d%d/a.cs\n", i }'; printf 'echo x > src/ldir/a.sh'; } > "$d/pl_phys"
  { awk 'BEGIN { for (i = 0; i < 3400; i++) printf "cp x t/d%d/a.cs\n", i }'; printf 'echo x > src/b.cs'; } > "$d/pl_ok"
  { awk 'BEGIN { for (i = 0; i < 3400; i++) printf "cp a,%d b,%d x\n", i, i }'; printf 'cp x a,%s/hooks/a.sh' "$p"; } > "$d/pl_comma"
  { printf 'cd src && cd ../t\n'
    awk 'BEGIN { for (i = 0; i < 5200; i++) printf "touch n%d\n", i }'; printf 'touch %s/hooks/a.sh' "$p"; } > "$d/pl_cd"
  { rep "cat $p/hooks/guard-edit.sh$nl" $((62000 / (${#p} + 24))); } > "$d/pl_read"
  { awk 'BEGIN { printf "echo"; for (i = 0; i < 10500; i++) printf " w%d", i }'; printf ' > src/b.cs'; } > "$d/pl_many"
  { awk 'BEGIN { printf "echo"; for (i = 0; i < 10500; i++) printf " w%d", i }'; printf ' > src/ldir/a.sh'; } > "$d/pl_manyhit"
  { awk 'BEGIN { printf "echo"; for (i = 0; i < 7800; i++) printf " \"w%d\"", i }'; printf ' > "src/b.cs"'; } > "$d/pl_quoted"
  # fix round 2: words holding a paren or an expansion are also read whole
  { awk 'BEGIN { for (i = 0; i < 4800; i++) printf "cp x f(%d)\n", i }'; printf 'cp x %s/hooks/(a)' "$p"; } > "$d/pl_paren"
  for f in pl_tail pl_words pl_phys pl_ok pl_comma pl_cd pl_read pl_many pl_manyhit pl_quoted pl_paren; do
    n="$(wc -c < "$d/$f" | tr -d ' ')"; [ "$n" -gt 60000 ] && [ "$n" -le 65536 ] || { echo "$f: $n bytes"; false; }
    hook_file guard-subagent-authority.sh "$d/$f" agent-1
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    case "$f" in
      pl_ok|pl_read|pl_many|pl_quoted) lacks "$(reason)" 'installed files' ;;
      *) [ "$(decision)" = deny ] || { echo "$f: expected deny"; false; }
         reason | grep -qF 'installed files' || { echo "$f: $(reason | cut -c1-200)"; false; } ;;
    esac
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
}

# Final review (item 3): the guard splits words unquoted (set -- $SEG, the
# cd and config loops); without set -f each */* was globbed against the
# hook's cwd. A project of 20 000 directories with two files each: one
# ls */* and 40 segments of it, and 300 case arms (glob command words:
# follow-up R2, decided once per distinct word), are ordinary, decided
# within 2 s of CPU and never a budget deny. The default config: with BCFG's remote block
# the remote scan denies 40 glob segments as a remote change (as it does in
# an empty directory; not a globbing cost).
@test "noglob: the subagent guard does not glob the command against a 20 000-directory project" {
  mk_project
  local d="$BATS_TEST_TMPDIR" f
  (cd "$PROJ" && awk 'BEGIN { for (i = 0; i < 20000; i++) print "d" i }' | xargs mkdir &&
    awk 'BEGIN { for (i = 0; i < 20000; i++) print "d" i "/a\nd" i "/b" }' | xargs touch)
  printf 'ls */*' > "$d/ng_one"
  rep 'ls */* ; ' 40 > "$d/ng_40"
  { printf 'case $x in'; awk 'BEGIN { for (i = 0; i < 150; i++) printf " a%d|*) echo %d ;; g%d*) ;;", i, i, i }'; printf ' esac'; } > "$d/ng_case"
  cd "$PROJ"
  for f in ng_one ng_40 ng_case; do
    hook_file guard-subagent-authority.sh "$d/$f" agent-1
    echo "$f: ${ms} ms wall, ${cpu} ms cpu" >&3
    [ "$status" -eq 0 ] || { echo "$f: status $status"; false; }
    [ -z "$output" ] || [ "$(decision)" = allow ] || { echo "$f: $(reason | cut -c1-200)"; false; }
    [ "$cpu" -lt 2000 ] || { echo "$f: ${cpu} ms cpu (${ms} ms wall)"; false; }
  done
}
