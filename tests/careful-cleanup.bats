#!/usr/bin/env bats
load helpers

# Spec 0.8 Part D, goal 1: the main session (payload without agent_id) deletes
# its own and its subagents' temp dirs without an approval code inside any
# command shape (chained, cd ... &&, quoted), as long as every rm target is a
# literal absolute path that mk_temp_rm_safe accepts and every other segment
# is an allowlisted harmless command (cd <literal> echo printf true false :
# test [ ls pwd). Subagents keep the single literal rm -rf <path> form.

# tp CMD [AGENT_ID] -- Bash payload carrying the fixture session's id and
# transcript; with AGENT_ID it is a subagent's call.
tp() {
  jq -nc --arg c "$1" --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" --arg a "${2:-}" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s,transcript_path:$t}
     + (if $a == "" then {} else {agent_id:$a} end)'
}
allowed() {
  run_hook guard-destructive.sh "$(tp "$1" "${2:-}")"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "expected allow: $1 -> $output"; return 1; }
}
denied() {
  run_hook guard-destructive.sh "$(tp "$1" "${2:-}")"
  [ "$(decision)" = "deny" ] || { echo "expected deny: $1 -> [$output]"; return 1; }
  reason | grep -q 'rm-recursive' || { echo "no rm-recursive label: $1 -> $(reason)"; return 1; }
}
# As careful-flat.bats: rep S N prints S N times; guard_tp_file F runs the
# guard on the command in file F (fixture session payload, main session)
# under a 5 s CPU limit and sets ms to the wall time.
rep() { s="$1" awk -v n="$2" 'BEGIN { s = ENVIRON["s"]; for (i = 0; i < n; i++) printf "%s", s }'; }
guard_tp_file() {
  local pl t0 t1
  pl="$BATS_TEST_TMPDIR/payload.json"
  jq -Rs --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" \
    '{tool_name:"Bash",tool_input:{command:.},cwd:$cwd,session_id:$s,transcript_path:$t}' < "$1" > "$pl"
  t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  run "$MK_BASH" -c 'ulimit -t 5; "$0" "$1" < "$2" 2>/dev/null' "$MK_BASH" "$HOOKS/guard-destructive.sh" "$pl"
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  ms=$((t1 - t0))
}
sub_allowed() { allowed "$1" a1b2c3; }
sub_denied() { denied "$1" a1b2c3; }
uuid() { printf '%08d-aaaa-bbbb-cccc-%012d' "$1" "$1"; }

setup() {
  mk_project
  mk_temp_tree
  mkdir -p "$TT_SP/rv10a/sub" "$TT_SP/mut.1" "$TT_SP/real/Documents" "$TROOT/outside"
  : > "$TT_SP/rv10a/sub/f"
  STALE="$(uuid 1)"; FRESH="$(uuid 2)"
  mkdir -p "$TT_PROJ/$STALE/scratchpad" "$TT_PROJ/$FRESH/scratchpad"
  : > "$TT_TDIR/$STALE.jsonl"; touch -t 202001010000 "$TT_TDIR/$STALE.jsonl"
  : > "$TT_TDIR/$FRESH.jsonl"; touch -t 203001010000 "$TT_TDIR/$FRESH.jsonl"
}

@test "main: compound and quoted scratchpad rm pass" {
  allowed "cd $PROJ && rm -rf \"$TT_SP/rv10a\""
  allowed "rm -rf '$TT_SP/mut.1'; echo done"
  allowed "ls && rm -rf $TT_SP/rv10a $TT_PROJ/$STALE"
  allowed "rm -rf '$TT_SP/rv10a'"
  allowed "cd $PROJ && rm -rf \"$TT_SP/rv10a\" && echo done"
  allowed "rm -rf $TT_SP/rv10a; rm -rf $TT_PROJ/$STALE"
  allowed "$(printf 'rm -rf %s\nrm -rf %s' "$TT_SP/rv10a" "$TT_SP/mut.1")"
  allowed "rm -rf $TT_SP/rv10a 2>/dev/null || true"
  allowed "ls $TT_SP && rm -rf $TT_SP/rv10a"
  allowed "pwd; cd /; test -d $TT_SP/rv10a && rm -rf $TT_SP/rv10a; echo ok; printf '%s\n' x; [ -d $TT_SP ] || false; :"
  # a guard only: nothing was deleted
  [ -f "$TT_SP/rv10a/sub/f" ]; [ -d "$TT_PROJ/$STALE" ]
}

@test "main: a variable target still asks" {
  # shellcheck disable=SC2016
  denied "D=$TT_SP/rv10a; rm -rf \"\$D\""
  reason | grep -qF 'rm -rf <'
  # shellcheck disable=SC2016
  for c in \
    "D=$TT_SP; rm -rf \$D/rv10a" \
    "cd $PROJ && rm -rf \${TT}/rv10a" \
    "echo x && rm -rf \$(echo $TT_SP/rv10a)" \
    "echo x && rm -rf \`echo $TT_SP/rv10a\`" \
    "echo x && rm -rf $TT_SP/rv1\\0a" \
    "echo x && rm -rf ~/x" \
    "echo x && rm -rf $TT_SP/~x" \
    "echo x && rm -rf $TT_SP/mut.*" \
    "echo x && rm -rf $TT_SP/rv1?a" \
    "echo x && rm -rf scratchpad/rv10a" \
    "cd $TT_SP && rm -rf rv10a"; do
    denied "$c"
  done
  denied "rm -rf ~/x"
}

@test "main: a non-temp target in the same command still asks" {
  denied "rm -rf $TT_SP/rv10a && rm -rf $PROJ/src"
  denied "rm -rf $TT_SP/rv10a $PROJ/src"
  denied "echo x; rm -rf $TT_SP/rv10a/"
  denied "echo x; rm -rf $TT_SP/real/Documents"
  denied "echo x; rm -rf $TT_PROJ/$FRESH"
  denied "echo x; rm -rf $TT_SP"
  denied "echo x; rm -rf $TROOT/outside"
}

@test "main: any command beside rm outside the allowlist keeps the old rule" {
  denied "mv $TROOT/outside $TT_SP/x && rm -rf $TT_SP/x"
  denied "ln -s /etc $TT_SP/x; rm -rf $TT_SP/x"
  denied "cp -r $TROOT/outside $TT_SP/y && rm -rf $TT_SP/y"
  denied "rsync -a $TROOT/outside/ $TT_SP/y/ ; rm -rf $TT_SP/y"
  denied "python3 -c 'x' && rm -rf $TT_SP/rv10a"
  # shellcheck disable=SC2016
  for c in \
    "tar -xf a.tar -C $TT_SP && rm -rf $TT_SP/y" \
    "install -d $TT_SP/y && rm -rf $TT_SP/y" \
    "rename x y $TT_SP/y && rm -rf $TT_SP/y" \
    "sh -c 'true' && rm -rf $TT_SP/rv10a" \
    "bash -c true; rm -rf $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a | cat" \
    "X=1; rm -rf $TT_SP/rv10a" \
    "\"echo\" x && rm -rf $TT_SP/rv10a" \
    "\$CMD && rm -rf $TT_SP/rv10a" \
    "echo \$(mv $TROOT/outside $TT_SP/y) && rm -rf $TT_SP/y" \
    "echo \`mv $TROOT/outside $TT_SP/y\` && rm -rf $TT_SP/y" \
    "ls <(true) && rm -rf $TT_SP/rv10a" \
    "cd \$HOME && rm -rf $TT_SP/rv10a" \
    "cd $TT_SP/* && rm -rf $TT_SP/rv10a" \
    "$(printf 'cat <<EOF\nx\nEOF\nrm -rf %s' "$TT_SP/rv10a")" \
    "echo 'a; mv x y' && rm -rf $TT_SP/rv10a"; do
    denied "$c"
  done
  for c in \
    "sudo mv $TROOT/outside $TT_SP/x && rm -rf $TT_SP/x" \
    "/bin/mv $TROOT/outside $TT_SP/x && rm -rf $TT_SP/x" \
    "m''v $TROOT/outside $TT_SP/x && rm -rf $TT_SP/x" \
    "\\mv $TROOT/outside $TT_SP/x && rm -rf $TT_SP/x" \
    "MV $TROOT/outside $TT_SP/x && rm -rf $TT_SP/x" \
    "echo x | xargs mv -t $TT_SP && rm -rf $TT_SP/x" \
    "(ln -s ~ $TT_SP/x) && rm -rf $TT_SP/x"; do
    denied "$c"
  done
  # the lone rm keeps passing; the deeper path never did
  allowed "rm -rf $TT_SP/real"
  denied "rm -rf $TT_SP/real && ln -s ~ $TT_SP/real && rm -rf $TT_SP/real/Documents"
}

@test "main: rm must be the segment's own command, without hidden arguments" {
  # shellcheck disable=SC2016
  for c in \
    "echo $TROOT/outside | xargs rm -rf $TT_SP/rv10a" \
    "find $TROOT -name outside -exec rm -rf $TT_SP/rv10a {} +" \
    "echo x; sudo rm -rf $TT_SP/rv10a" \
    "echo x; env rm -rf $TT_SP/rv10a" \
    "echo x; command rm -rf $TT_SP/rv10a" \
    "echo x; \$RM -rf $TT_SP/rv10a" \
    "echo x; rm -rf <(true) $TT_SP/rv10a" \
    "echo x; rm -rf $TT_SP/rv10a \$(cat list)" \
    "echo \$(rm -rf $TT_SP/rv10a)" \
    "(rm -rf $TT_SP/rv10a)" \
    "echo x; rm -rf \"$TT_SP/rv10a" \
    "echo x; rm -rf \"$TT_SP/rv10a\"x" \
    "echo x; rm -rf -- -x $TT_SP/rv10a" \
    "echo x; rm -rf $TT_SP/rv10a -x" \
    "echo x; rm -rf - $TT_SP/rv10a" \
    "echo x; rm -rf -- $TT_SP/rv10a --"; do
    denied "$c"
  done
  allowed "echo x; rm -rf -- $TT_SP/rv10a"
}

@test "main: the S3 and 0.5.2 shapes of careful-temp.bats" {
  # shellcheck disable=SC2016
  for c in \
    "rm -rf $TT_SP/rv10a&" \
    "(rm -rf $TT_SP/rv10a)" \
    "{ rm -rf $TT_SP/rv10a; }" \
    "echo \$(rm -rf $TT_SP/rv10a)" \
    "echo \`rm -rf $TT_SP/rv10a\`" \
    "rm -rf <(true) $TT_SP/rv10a" \
    "xargs rm -rf $TT_SP/rv10a" \
    "find $TT_SP -name rv10a -exec rm -rf $TT_SP/rv10a \\;" \
    "env rm -rf $TT_SP/rv10a" \
    "sudo rm -rf $TT_SP/rv10a" \
    "builtin rm -rf $TT_SP/rv10a" \
    "exec rm -rf $TT_SP/rv10a" \
    "X=1 rm -rf $TT_SP/rv10a" \
    "\\rm -rf $TT_SP/rv10a" \
    "./rm -rf $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a # note" \
    "! rm -rf $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a \\\\" \
    "$(printf "rm -rf '%s\\\\\nx'" "$TT_SP/rv10a")" \
    "\$'rm' -rf $TT_SP/rv10a" \
    "=rm -rf $TT_SP/rv10a" \
    "nohup rm -rf $TT_SP/rv10a" \
    "time rm -rf $TT_SP/rv10a" \
    "timeout 5 rm -rf $TT_SP/rv10a" \
    "\$RM -rf $TT_SP/rv10a" \
    "\$(echo rm) -rf $TT_SP/rv10a" \
    "/bin/rm(N) -rf $TT_SP/rv10a" \
    "> /dev/null rm -rf $TT_SP/rv10a" \
    "(rm -rf $TT_SP/rv10a)&" \
    "find $TT_SP -exec rm -rf {} +" \
    "\"rm\" -rf $TT_SP/rv10a" \
    "r''m -rf $TT_SP/rv10a" \
    "\"/bin/rm\" -rf $TT_SP/rv10a" \
    "{rm,-rf,$TT_SP/rv10a}"; do
    denied "$c"
  done
  # Same effect as rm -rf <literal temp path>, and nothing else runs.
  for c in \
    "rm -rf $TT_SP/rv10a > /dev/null" \
    "rm -rf $TT_SP/rv10a 2>/dev/null" \
    "rm -rf $TT_SP/rv10a < /dev/null" \
    "rm \"-rf\" $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a & echo x"; do
    allowed "$c"
  done
  # a trailing & is not a separator to the splitter: read as a target "&"
  denied "rm -rf $TT_SP/rv10a &"
}

@test "subagent: compound rm still asks" {
  sub_denied "cd $PROJ && rm -rf \"$TT_SP/rv10a\""
  sub_denied "rm -rf '$TT_SP/mut.1'; echo done"
  sub_denied "ls && rm -rf $TT_SP/rv10a $TT_PROJ/$STALE"
  reason | grep -qF 'rm -rf <'
}

@test "the literal single rm keeps passing for both" {
  allowed "rm -rf $TT_SP/rv10a"
  sub_allowed "rm -rf $TT_SP/rv10a"
  allowed "rm -rf $TT_PROJ/$STALE"
  sub_allowed "rm -rf $TT_PROJ/$STALE"
  # single rm keeps today's glob form for both
  allowed "rm -rf $TT_SP/mut.*"
  sub_allowed "rm -rf $TT_SP/mut.*"
  # the trailing slash is denied as today, for both
  denied "rm -rf $TT_SP/rv10a/"
  sub_denied "rm -rf $TT_SP/rv10a/"
}

@test "MEMOKIT_CAREFUL_OFF=1 is unaffected" {
  MEMOKIT_CAREFUL_OFF=1 run_hook guard-destructive.sh "$(tp "rm -rf $TT_SP/rv10a $PROJ/src")"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  MEMOKIT_CAREFUL_OFF=1 run_hook guard-destructive.sh "$(tp "cd $PROJ && rm -rf $TT_SP/rv10a" a1b2c3)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "MK_CF_MAIN is never read from the environment" {
  MK_CF_MAIN=1 run_hook guard-destructive.sh "$(tp "cd $PROJ && rm -rf $TT_SP/rv10a" a1b2c3)"
  [ "$(decision)" = "deny" ]
  run "$MK_BASH" -c "MK_CF_MAIN=1; export MK_CF_MAIN; . '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; echo \"[\$MK_CF_MAIN]\""
  [ "$output" = "[0]" ]
  run "$MK_BASH" -c "MK_CF_WT=1 MK_CF_CWD=/x; export MK_CF_WT MK_CF_CWD; . '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; echo \"[\$MK_CF_WT\$MK_CF_CWD]\""
  [ "$output" = "[0]" ]
}

@test "big commands stay fast in a UTF-8 locale (no super-linear pattern ops on the command)" {
  # bash 3.2 runs ${cmd//pat/} and unanchored case globs in super-linear time
  # in a UTF-8 locale; past the 5 s hook timeout the command runs unchecked.
  export LANG=tr_TR.UTF-8
  d="$BATS_TEST_TMPDIR"
  { rep 'echo hello world; ' 3900; printf 'cat /tmp/memokit-1-"careful"-grants'; } > "$d/grant70k"
  guard_tp_file "$d/grant70k"
  [ "$(decision)" = "deny" ] || { echo "grant70k: expected deny -> $output"; false; }
  reason | grep -qF "onay dosyalar" || { echo "grant70k: not careful-state -> $(reason)"; false; }
  [ "$ms" -lt 3000 ] || { echo "grant70k: $ms ms"; false; }
  # 3900 segments: over 64 KiB, so too-large (approvable), not the budget deny
  { rep 'echo hello world; ' 3900; printf 'rm -rf "%s/x"' "$TT_SP"; } > "$d/rm70k"
  guard_tp_file "$d/rm70k"
  [ "$(decision)" = "deny" ] || { echo "rm70k: expected deny -> $output"; false; }
  reason | grep -q 'too-large' || { echo "rm70k: $(reason)"; false; }
  [ "$ms" -lt 3000 ] || { echo "rm70k: $ms ms"; false; }
  # 3500 segments: under the limit, every check runs, and the cleanup passes
  { rep 'echo hello world; ' 3500; printf 'rm -rf "%s/x"' "$TT_SP"; } > "$d/rm63k"
  guard_tp_file "$d/rm63k"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "rm63k: expected allow -> $output"; false; }
  [ "$ms" -lt 3000 ] || { echo "rm63k: $ms ms"; false; }
  # one huge literal rm target, one huge cd argument, a run of parentheses
  { printf 'echo x; rm -rf "%s/' "$TT_SP"; rep a 60000; printf '"'; } > "$d/word60k"
  guard_tp_file "$d/word60k"
  [ "$ms" -lt 3000 ] || { echo "word60k: $ms ms -> $output"; false; }
  { printf 'cd /'; rep a 60000; printf ' && rm -rf "%s/x"' "$TT_SP"; } > "$d/cd60k"
  guard_tp_file "$d/cd60k"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "cd60k: expected allow -> $output"; false; }
  [ "$ms" -lt 3000 ] || { echo "cd60k: $ms ms"; false; }
  { printf 'echo x; rm -rf '; rep '(' 30000; } > "$d/paren30k"
  guard_tp_file "$d/paren30k"
  [ "$(decision)" = "deny" ] || { echo "paren30k: expected deny -> $output"; false; }
  [ "$ms" -lt 3000 ] || { echo "paren30k: $ms ms"; false; }
  { printf 'echo x; '; rep '(' 30000; printf 'x && rm -rf "%s/x"' "$TT_SP"; } > "$d/lead30k"
  guard_tp_file "$d/lead30k"
  [ "$(decision)" = "deny" ] || { echo "lead30k: expected deny -> $output"; false; }
  [ "$ms" -lt 3000 ] || { echo "lead30k: $ms ms"; false; }
}

@test "review fix 1: zsh =(...), glob qualifiers or any parenthesis disable the exemption" {
  # zsh runs these inside an allowlisted echo/ls/cd (=(cmd) process
  # substitution, (e:'cmd':) glob qualifier); bash rejects them as syntax.
  for c in \
    "echo =(mv $TROOT/outside $TT_SP/z) && rm -rf $TT_SP/z" \
    "ls $TT_SP(e:'mv $TROOT/outside $TT_SP/z':) && rm -rf $TT_SP/z" \
    "cd /tmp(e:'mv $TROOT/outside $TT_SP/z':) && rm -rf $TT_SP/z" \
    "echo x(+f) && rm -rf $TT_SP/rv10a" \
    "echo \"done (ok)\" && rm -rf $TT_SP/rv10a" \
    "echo x) && rm -rf $TT_SP/rv10a"; do
    denied "$c"
  done
}

@test "review fix 2: rm redirections in a compound command take only a literal path or an fd dup" {
  # zsh numeric globs <-> / <1-99> are targets, not redirections
  for c in \
    "rm -rf $TT_SP/rv10a <->" \
    "cd $PROJ && rm -rf $TT_SP/rv10a <->" \
    "cd $PROJ && rm -rf $TT_SP/rv10a <1-99>" \
    "echo x; rm -rf $TT_SP/rv10a > relative.log" \
    "echo x; rm -rf $TT_SP/rv10a >relative.log" \
    "echo x; rm -rf $TT_SP/rv10a 2> \"\$X\"" \
    "echo x; rm -rf $TT_SP/rv10a 2>~/x.log" \
    "echo x; rm -rf $TT_SP/rv10a >&-" \
    "echo x; rm -rf -* $TT_SP/rv10a"; do
    denied "$c"
  done
  for c in \
    "echo x; rm -rf $TT_SP/rv10a 2>/dev/null" \
    "echo x; rm -rf $TT_SP/rv10a 2>&1" \
    "echo x; rm -rf $TT_SP/rv10a >&2" \
    "echo x; rm -rf $TT_SP/rv10a >/tmp/x.log" \
    "echo x; rm -rf $TT_SP/rv10a > /tmp/x.log" \
    "echo x; rm -rf $TT_SP/rv10a >> \"/tmp/x.log\" 2>&1" \
    "echo x; rm -rf $TT_SP/rv10a &>/dev/null" \
    "echo x; rm -rf $TT_SP/rv10a < /dev/null"; do
    allowed "$c"
  done
}

@test "review fix 3: more than 16 rm targets in a compound command ask for a code" {
  export LANG=tr_TR.UTF-8
  t16=""; i=1
  while [ "$i" -le 16 ]; do t16="$t16 $TT_SP/t$i"; i=$((i + 1)); done
  printf 'echo x; rm -rf%s' "$t16" > "$BATS_TEST_TMPDIR/c16"
  guard_tp_file "$BATS_TEST_TMPDIR/c16"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "16: expected allow -> $output"; false; }
  [ "$ms" -lt 3000 ] || { echo "16: $ms ms"; false; }
  denied "echo x; rm -rf$t16 $TT_SP/t17"
  denied "echo x; rm -rf$t16; rm -rf $TT_SP/t17"
  # quotes (raw and flat views differ) do not halve the count
  q=""; i=1
  while [ "$i" -le 17 ]; do q="$q \"$TT_SP/t$i\""; i=$((i + 1)); done
  denied "echo x; rm -rf$q"
  # the single-rm form has its own 4096-char bound and keeps working
  allowed "rm -rf$t16 $TT_SP/t17"
}

@test "&>> names a written file, not an rm target: main and subagent agree" {
  # Task 9 re-review N1: the operand of &>> is written, not deleted.
  allowed "rm -rf build &>> /etc/x"
  sub_allowed "rm -rf build &>> /etc/x"
}

# --- worktrees: spec 0.8 Part D, goals 2 and 3 --------------------------------
# The main session removes a lane worktree (git worktree remove [--force|-f]
# <literal absolute path>, rm -r <literal absolute path>) without a code when
# lib/worktrees.sh classifies it merged-clean (gitignored files do not
# block), and deletes a merged branch no worktree checks out
# (git branch -D|-d|--delete [--force] <literal name>). Never the main
# checkout, the worktree holding the payload cwd, an active run's lane, a
# path git does not list. Subagents: unchanged (asserted on this hook alone).
#
# wt_setup -- the fixture repo R (helpers.bash) is the project and the payload
# cwd; lanes under W:
#   mk-r1-ok     mk/r1/ok     merged-clean, holds a gitignored .env
#   mk-r1-dirty  mk/r1/dirty  a tracked file changed
#   mk-r1-new    mk/r1/new    a commit not in main (unmerged)
#   branches     mk/r1/gone (merged, no worktree), mk/r1/side (unmerged, no worktree)
wt_setup() {
  wt_repo
  printf '.env\n.claude/memokit.json\n' >> "$R/.gitignore"; g commit -qam ignore-env
  mkdir -p "$R/.claude" "$R/src"; printf '%s' "$DEFAULT_CONFIG" > "$R/.claude/memokit.json"
  PROJ="$R"; CLAUDE_PROJECT_DIR="$R"; export PROJ CLAUDE_PROJECT_DIR
  wt_add mk-r1-ok mk/r1/ok; printf 'SECRET=1\n' > "$W/mk-r1-ok/.env"
  wt_add mk-r1-dirty mk/r1/dirty; printf 'x\n' >> "$W/mk-r1-dirty/a.txt"
  wt_add mk-r1-new mk/r1/new; wt_commit "$W/mk-r1-new" lane
  g branch mk/r1/gone main
  wt_add mk-r1-side mk/r1/side; wt_commit "$W/mk-r1-side" side; g worktree remove "$W/mk-r1-side"
}
# wdenied CMD LABEL [AGENT_ID] -- denied with LABEL among the labels.
wdenied() {
  run_hook guard-destructive.sh "$(tp "$1" "${3:-}")"
  [ "$(decision)" = "deny" ] || { echo "expected deny: $1 -> [$output]"; return 1; }
  reason | grep -qF -- "$2" || { echo "no $2 label: $1 -> $(reason)"; return 1; }
}

@test "worktrees main: git worktree remove --force of a merged-clean lane passes (ignored files do not block)" {
  wt_setup
  allowed "git worktree remove --force $W/mk-r1-ok"
  allowed "git worktree remove -f '$W/mk-r1-ok'"
  allowed "git worktree remove --force \"$W/mk-r1-ok\""
  allowed "cd $R && git worktree remove --force $W/mk-r1-ok && echo done"
  # a guard only: nothing was removed
  [ -f "$W/mk-r1-ok/.env" ]
}

@test "worktrees main: git worktree remove --force of a dirty, unmerged or active-run lane asks" {
  wt_setup
  wdenied "git worktree remove --force $W/mk-r1-dirty" git-worktree-force
  wdenied "git worktree remove --force $W/mk-r1-new" git-worktree-force
  ledger "$R" r7 active; wt_add mk-r7-a mk/r7/a
  wdenied "git worktree remove --force $W/mk-r7-a" git-worktree-force
  # one lane passing does not carry another
  wdenied "git worktree remove --force $W/mk-r1-ok && git worktree remove --force $W/mk-r1-new" git-worktree-force
}

@test "worktrees main: the main checkout, the cwd's worktree and unlisted paths ask" {
  wt_setup
  wdenied "git worktree remove --force $R" git-worktree-force
  wdenied "git worktree remove --force $W" git-worktree-force
  wdenied "git worktree remove --force $W/missing" git-worktree-force
  mkdir -p "$W/plain"
  wdenied "git worktree remove --force $W/plain" git-worktree-force
  # the payload cwd inside the lane (or the project dir there) protects it
  mkdir -p "$W/mk-r1-ok/sub"
  PROJ="$W/mk-r1-ok/sub" wdenied "git worktree remove --force $W/mk-r1-ok" git-worktree-force
  PROJ="$W/mk-r1-ok" wdenied "rm -rf $W/mk-r1-ok" rm-recursive
  mkdir -p "$W/mk-r1-ok/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$W/mk-r1-ok/.claude/memokit.json"
  CLAUDE_PROJECT_DIR="$W/mk-r1-ok" wdenied "rm -rf $W/mk-r1-ok" rm-recursive
  # the main worktree, also when neither the cwd nor the project dir is in it:
  # a worktree outside R (R is clean and its branch merged, so only "never
  # the main worktree" holds)
  O="$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)/outside"
  g worktree add -q "$O" -b mk/r1/out main
  mkdir -p "$O/.claude"; printf '%s' "$DEFAULT_CONFIG" > "$O/.claude/memokit.json"
  PROJ="$O" CLAUDE_PROJECT_DIR="$O" wdenied "git worktree remove --force $R" git-worktree-force
  PROJ="$O" CLAUDE_PROJECT_DIR="$O" allowed "git worktree remove --force $W/mk-r1-ok"
}

@test "worktrees main: only the exact literal shape is exempt" {
  wt_setup
  # shellcheck disable=SC2016
  for c in \
    "git worktree remove --force .claude/worktrees/mk-r1-ok" \
    "cd $R && git worktree remove --force .claude/worktrees/mk-r1-ok" \
    "git -C $R worktree remove --force $W/mk-r1-ok" \
    "git worktree remove --force $W/mk-r1-ok $W/mk-r1-new" \
    "git worktree remove --force --force $W/mk-r1-ok" \
    "git worktree remove $W/mk-r1-ok --force" \
    "git worktree remove --force $W/mk-r1-o?" \
    "git worktree remove --force $W/mk-r1-*" \
    "git worktree remove --force \$W/mk-r1-ok" \
    "git worktree remove --force $W/mk-r1-o\\k" \
    "git worktree remove --force ~/mk-r1-ok" \
    "X=1 git worktree remove --force $W/mk-r1-ok" \
    "git worktree remove --force $W/mk-r1-ok && mv a b" \
    "git worktree remove --force $W/mk-r1-ok | cat" \
    "git worktree remove --force $W/mk-r1-ok > /tmp/x" \
    "echo \$(git worktree remove --force $W/mk-r1-ok)" \
    "(git worktree remove --force $W/mk-r1-ok)" \
    "git worktree remove --force \"$W/mk-r1-ok"; do
    run_hook guard-destructive.sh "$(tp "$c")"
    [ "$(decision)" = "deny" ] || { echo "expected deny: $c -> [$output]"; false; }
  done
  # a merged-clean lane whose real name holds a glob character: the shell
  # would expand the word, so it is no literal
  wt_add 'mk-r1-[x]' mk/r1/glob
  wdenied "git worktree remove --force '$W/mk-r1-[x]'" git-worktree-force
  wdenied "rm -rf $W/mk-r1-[x]" rm-recursive
  wdenied "echo x && rm -rf '$W/mk-r1-[x]'" rm-recursive
}

@test "worktrees main: rm -rf of a merged-clean worktree path passes; dirty, unmerged, main or a sub path asks" {
  wt_setup
  allowed "rm -rf $W/mk-r1-ok"
  allowed "rm -rf '$W/mk-r1-ok'"
  allowed "echo x && rm -rf \"$W/mk-r1-ok\""
  wdenied "rm -rf $W/mk-r1-dirty" rm-recursive
  wdenied "rm -rf $W/mk-r1-new" rm-recursive
  wdenied "rm -rf $R" rm-recursive
  wdenied "rm -rf $W" rm-recursive
  mkdir -p "$W/mk-r1-ok/sub"
  wdenied "rm -rf $W/mk-r1-ok/sub" rm-recursive
  wdenied "rm -rf $W/mk-r1-ok $R/src" rm-recursive
  wdenied "cd $W && rm -rf mk-r1-ok" rm-recursive
  wdenied "mv $R/src $W/mk-r1-ok/x && rm -rf $W/mk-r1-ok" rm-recursive
  wdenied "echo x | xargs rm -rf $W/mk-r1-ok" rm-recursive
  [ -f "$W/mk-r1-ok/.env" ]
}

@test "worktrees main: git branch -D of a merged branch passes; unmerged or checked out asks" {
  wt_setup
  allowed "git branch -D mk/r1/gone"
  allowed "git branch -d --force 'mk/r1/gone'"
  allowed "git branch --delete mk/r1/gone"
  wdenied "git branch -D mk/r1/side" git-branch-delete
  wdenied "git branch -D mk/r1/ok" git-branch-delete
  wdenied "git branch -D mk/r1/new" git-branch-delete
  wdenied "git branch -D main" git-branch-delete
  # shellcheck disable=SC2016
  for c in \
    "cd $R && git branch -D mk/r1/gone" \
    "cd /tmp; git branch -D mk/r1/gone" \
    "git branch -D mk/r1/gone mk/r1/side" \
    "git branch -D \$B" \
    "git branch -D 'mk/r1/go*'" \
    "git branch -D -f mk/r1/gone" \
    "git -C $R branch -D mk/r1/gone" \
    "export GIT_DIR=/x; git branch -D mk/r1/gone"; do
    wdenied "$c" git-branch-delete
  done
  git -C "$R" rev-parse -q --verify refs/heads/mk/r1/gone >/dev/null
}

@test "worktrees main: the whole lane cleanup chain passes in one command" {
  wt_setup
  allowed "rm -rf $TT_SP/rv10a && git worktree remove --force $W/mk-r1-ok && git branch -D mk/r1/ok"
  allowed "git worktree remove --force '$W/mk-r1-ok' && git branch -D mk/r1/ok && git branch -D mk/r1/gone"
  # the branch is still checked out where no earlier segment removes its lane
  wdenied "git branch -D mk/r1/ok && git worktree remove --force $W/mk-r1-ok" git-branch-delete
  wdenied "rm -rf $W/mk-r1-ok && git branch -D mk/r1/ok" git-branch-delete
  wdenied "rm -rf $TT_SP/rv10a && git worktree remove --force $W/mk-r1-dirty && git branch -D mk/r1/dirty" git-worktree-force
  wdenied "rm -rf $TT_SP/rv10a && git worktree remove --force $W/mk-r1-ok && git branch -D mk/r1/side" git-branch-delete
}

@test "worktrees subagent: every worktree and branch case still denies (this hook alone)" {
  wt_setup
  for c in \
    "git worktree remove --force $W/mk-r1-ok" \
    "git worktree remove -f '$W/mk-r1-ok'" \
    "git worktree remove --force $W/mk-r1-dirty" \
    "git worktree remove --force $W/mk-r1-new" \
    "git worktree remove --force $R"; do
    wdenied "$c" git-worktree-force a1b2c3
  done
  for c in "rm -rf $W/mk-r1-ok" "echo x && rm -rf '$W/mk-r1-ok'" "rm -rf $W/mk-r1-dirty"; do
    wdenied "$c" rm-recursive a1b2c3
  done
  for c in "git branch -D mk/r1/gone" "git branch -D mk/r1/side" "git branch -D mk/r1/ok"; do
    wdenied "$c" git-branch-delete a1b2c3
  done
  wdenied "rm -rf $TT_SP/rv10a && git worktree remove --force $W/mk-r1-ok && git branch -D mk/r1/ok" git-worktree-force a1b2c3
}

@test "worktrees lib: a git call that does not finish, or a git error, fails closed" {
  wt_setup
  real="$(command -v git)"
  bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" status "*) exec sleep 20 ;; esac\nexec "%s" "$@"\n' "$real" > "$bin/git"
  chmod +x "$bin/git"
  lib='. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"'
  run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" "$3"; echo "rc=$?"' x "$HOOKS" "$W/mk-r1-ok" "$R"
  [ "$output" = "rc=0" ]
  t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  PATH="$bin:$PATH" run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" "$3"; echo "rc=$?"' x "$HOOKS" "$W/mk-r1-ok" "$R"
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  [ "$output" = "rc=1" ]
  [ $((t1 - t0)) -lt 5000 ] || { echo "took $((t1 - t0)) ms"; false; }
  # not a git repository, no cwd: fail closed
  run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" /; echo "rc=$?"; mk_wt_removable "$2" ""; echo "rc=$?"
    mk_wt_branch_removable mk/r1/gone /; echo "rc=$?"; mk_wt_branch_removable mk/r1/gone "$3"; echo "rc=$?"' x "$HOOKS" "$W/mk-r1-ok" "$R"
  [ "$output" = "$(printf 'rc=1\nrc=1\nrc=1\nrc=0')" ]
  # never the main worktree, also from a cwd outside it (lib level; the hook
  # refuses it earlier too: its .git is a directory, a lane's a file)
  O="$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)/outside"
  g worktree add -q "$O" -b mk/r1/out main
  run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" "$3"; echo "rc=$?"; mk_wt_removable "$4" "$3"; echo "rc=$?"' x "$HOOKS" "$R" "$O" "$W/mk-r1-ok"
  [ "$output" = "$(printf 'rc=1\nrc=0')" ]
}

# --- worktrees, task 10 fix round 1 --------------------------------------------

@test "worktrees fix1: only lanes (direct children of <W>/.claude/worktrees/) are exempt" {
  wt_setup
  T="$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)"
  g worktree add -q "$T/manual" -b feat/manual main
  g worktree add -q "$R/inrepo" -b feat/inrepo main
  wdenied "git worktree remove --force $T/manual" git-worktree-force
  wdenied "rm -rf $T/manual" rm-recursive
  wdenied "git worktree remove --force $R/inrepo && git branch -D feat/inrepo" git-worktree-force
  # deeper than a direct child of .claude/worktrees/ is no lane either
  g worktree add -q "$W/deep/mk-r1-deep" -b mk/r1/deep main
  wdenied "git worktree remove --force $W/deep/mk-r1-deep" git-worktree-force
  # lanes still pass, also under a sibling worktree's .claude/worktrees/
  allowed "git worktree remove --force $W/mk-r1-ok"
  g worktree add -q "$T/manual/.claude/worktrees/sub" -b mk/r1/sub main
  allowed "git worktree remove --force $T/manual/.claude/worktrees/sub && git branch -D mk/r1/sub"
}

@test "worktrees fix1: a lane holding another registered worktree asks" {
  wt_setup
  wt_add mk-r1-host mk/r1/host
  I="$W/mk-r1-host/.claude/worktrees/inner"
  g worktree add -q "$I" -b mk/r1/inner main
  printf 'x\n' >> "$I/a.txt"; printf 'new\n' > "$I/new.txt"
  wdenied "rm -rf $W/mk-r1-host" rm-recursive
  wdenied "git worktree remove --force $W/mk-r1-host" git-worktree-force
  wdenied "echo x && rm -rf '$W/mk-r1-host'" rm-recursive
  # also when the nested worktree is clean
  gw "$I" checkout -q -- a.txt; rm -f "$I/new.txt"
  wdenied "git worktree remove --force $W/mk-r1-host" git-worktree-force
}

@test "worktrees fix1: a branch name must match the ref exactly and collide with no checkout in any case" {
  wt_setup
  wt_add mk-r1-lane mk/lane
  wdenied "git branch -D MK/LANE" git-branch-delete
  wdenied "git branch -D Mk/Lane" git-branch-delete
  allowed "git branch -D mk/r1/gone"
  wdenied "git branch -D MK/R1/GONE" git-branch-delete
  wdenied "git branch -D mk/R1/gone" git-branch-delete
  wdenied "git worktree remove --force $W/mk-r1-lane && git branch -D MK/LANE" git-branch-delete
  allowed "git worktree remove --force $W/mk-r1-lane && git branch -D mk/lane"
  # both spellings exist (ZQ/X packed, zq/x loose and checked out): on a
  # case-insensitive file system deleting ZQ/X would hit zq/x's loose ref.
  # (A prefix with no loose directory yet: under an existing refs/heads/mk/
  # the file system would store MK/X as mk/X.)
  g branch ZQ/X main; g pack-refs --all
  g worktree add -q "$W/mk-r1-x" -b zq/x main
  g for-each-ref --format='%(refname)' refs/heads/ | grep -qx 'refs/heads/ZQ/X'
  wdenied "git branch -D ZQ/X" git-branch-delete
}

@test "worktrees fix1: merged means merged into the main worktree's HEAD or the default branch, not the cwd's" {
  wt_setup
  wt_add mk-r1-b mk/r1/b; wt_commit "$W/mk-r1-b" bwork
  g worktree add -q "$W/mk-r1-a" -b mk/r1/a mk/r1/b; wt_commit "$W/mk-r1-a" awork
  PROJ="$W/mk-r1-a" wdenied "git worktree remove --force $W/mk-r1-b" git-worktree-force
  PROJ="$W/mk-r1-a" wdenied "rm -rf $W/mk-r1-b" rm-recursive
  PROJ="$W/mk-r1-a" wdenied "git worktree remove --force $W/mk-r1-b && git branch -D mk/r1/b" git-worktree-force
  g worktree remove "$W/mk-r1-b"
  PROJ="$W/mk-r1-a" wdenied "git branch -D mk/r1/b" git-branch-delete
  # a lane merged into main still passes from a cwd inside another lane
  PROJ="$W/mk-r1-a" allowed "git worktree remove --force $W/mk-r1-ok && git branch -D mk/r1/ok"
}

@test "worktrees fix1: the default branch and the main worktree's branch are never deleted without a code" {
  wt_setup
  g checkout -q --detach main
  wdenied "git branch -D main" git-branch-delete
  wdenied "git branch -d --force main" git-branch-delete
  wdenied "git branch -D MAIN" git-branch-delete
  g branch master main
  wdenied "git branch -D master" git-branch-delete
  # origin/HEAD names the default branch
  g update-ref refs/remotes/origin/trunk main
  g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  g branch trunk main
  wdenied "git branch -D trunk" git-branch-delete
  # the branch the main worktree has checked out
  g checkout -q -b dev main
  wdenied "git branch -D dev" git-branch-delete
  allowed "git branch -D mk/r1/gone"
}

@test "worktrees fix1: a hung git worktree list gives the ordinary code deny within 3 s" {
  wt_setup
  real="$(command -v git)"
  bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" worktree list "*) exec sleep 20 ;; esac\nexec "%s" "$@"\n' "$real" > "$bin/git"
  chmod +x "$bin/git"
  for c in "git worktree remove --force $W/mk-r1-ok" "git branch -D mk/r1/gone"; do
    t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    PATH="$bin:$PATH" run_hook guard-destructive.sh "$(tp "$c")"
    t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
    [ "$(decision)" = "deny" ] || { echo "expected deny: $c -> $output"; false; }
    reason | grep -q "onay [0-9a-f]\{6\}" || { echo "not the code deny: $c -> $(reason)"; false; }
    [ $((t1 - t0)) -lt 3000 ] || { echo "$c: $((t1 - t0)) ms"; false; }
  done
}

@test "worktrees fix1 subagent: the new cases deny for a subagent" {
  wt_setup
  T="$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)"
  g worktree add -q "$T/manual" -b feat/manual main
  wt_add mk-r1-lane mk/lane
  for c in \
    "git worktree remove --force $T/manual" \
    "git worktree remove --force $W/mk-r1-lane && git branch -D mk/lane" \
    "git branch -D MK/LANE" "git branch -D main"; do
    run_hook guard-destructive.sh "$(tp "$c" a1b2c3)"
    [ "$(decision)" = "deny" ] || { echo "expected deny: $c -> $output"; false; }
  done
  wdenied "rm -rf $T/manual" rm-recursive a1b2c3
}

# --- worktrees, task 10 fix round 2 --------------------------------------------

# wt_linked_inner -- a worktree git lists as $T/real/inner whose directory is
# physically inside the merged-clean lane mk-r1-host: registered at a real
# directory, moved into the lane, the old directory replaced by a symlink
# (git >= 2.x resolves a symlink given to `worktree add`, so this is how an
# unresolved listed path arises).
wt_linked_inner() {
  T="$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)"
  wt_add mk-r1-host mk/r1/host
  mkdir -p "$W/mk-r1-host/.claude/worktrees" "$T/real"
  g worktree add -q "$T/real/inner" -b mk/r1/inner main
  mv "$T/real/inner" "$W/mk-r1-host/.claude/worktrees/inner"
  rmdir "$T/real"; ln -s "$W/mk-r1-host/.claude/worktrees" "$T/real"
  g worktree list --porcelain | grep -qx "worktree $T/real/inner"
}

@test "worktrees fix2: a worktree listed through a symlink into a lane makes the lane ask" {
  wt_setup
  wt_linked_inner
  printf 'wip\n' > "$T/real/inner/wip.txt"
  wdenied "rm -rf $W/mk-r1-host" rm-recursive
  wdenied "git worktree remove --force $W/mk-r1-host" git-worktree-force
  wdenied "echo x && rm -rf '$W/mk-r1-host'" rm-recursive
  # a listed worktree whose directory is gone resolves its deepest existing parent
  g worktree add -q "$T/gone" -b mk/r1/gone2 main; rm -rf "$T/gone"
  allowed "git worktree remove --force $W/mk-r1-ok"
}

@test "worktrees fix2: a killed git call fails the lookup even when no timeout marker is written" {
  wt_setup
  real="$(command -v git)"
  lib='. "$1/lib/common.sh"; . "$1/lib/worktrees.sh"'
  run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" "$3"; echo "rc=$?"' x "$HOOKS" "$W/mk-r1-ok" "$R"
  [ "$output" = "rc=0" ]
  # a complete-looking listing, then the git is killed: the parent must see
  # the kill, not the parsed fields (TMPDIR missing: no marker can be made)
  g worktree list --porcelain -z > "$BATS_TEST_TMPDIR/list.z"
  bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" worktree list "*) cat "%s"; exec sleep 20 ;; esac\nexec "%s" "$@"\n' \
    "$BATS_TEST_TMPDIR/list.z" "$real" > "$bin/git"
  chmod +x "$bin/git"
  TMPDIR=/nonexistent/memokit-test PATH="$bin:$PATH" run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" "$3"; echo "rc=$?"; mk_wt_branch_removable mk/r1/gone "$3"; echo "rc=$?"' x "$HOOKS" "$W/mk-r1-ok" "$R"
  [ "$output" = "$(printf 'rc=1\nrc=1')" ]
  # a killed origin/HEAD lookup must not fall back to main as the default
  printf '#!/bin/sh\ncase " $* " in *" symbolic-ref "*) exec sleep 20 ;; esac\nexec "%s" "$@"\n' "$real" > "$bin/git"
  TMPDIR=/nonexistent/memokit-test PATH="$bin:$PATH" run "$MK_BASH" -c "$lib"'; mk_wt_removable "$2" "$3"; echo "rc=$?"; mk_wt_branch_removable mk/r1/gone "$3"; echo "rc=$?"' x "$HOOKS" "$W/mk-r1-ok" "$R"
  [ "$output" = "$(printf 'rc=1\nrc=1')" ]
}

@test "worktrees fix2 subagent: the new cases deny for a subagent" {
  wt_setup
  wt_linked_inner
  wdenied "rm -rf $W/mk-r1-host" rm-recursive a1b2c3
  wdenied "git worktree remove --force $W/mk-r1-host" git-worktree-force a1b2c3
}
