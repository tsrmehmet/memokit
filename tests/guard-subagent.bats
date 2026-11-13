#!/usr/bin/env bats
load helpers

@test "silent without config" {
  mk_project none
  run_hook guard-subagent-authority.sh "$(bash_payload 'git push' agent-1)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
@test "subagent push denied" {
  mk_project
  run_hook guard-subagent-authority.sh "$(bash_payload 'git push origin main' agent-1)"
  [ "$(decision)" = "deny" ]; reason | grep -q 'PUSH'
}
@test "main session push allowed" {
  mk_project
  run_hook guard-subagent-authority.sh "$(bash_payload 'git push origin main')"
  [ "$status" -eq 0 ]
  [ "$(decision)" = "allow" ]
}
@test "subagent delegation denied for Agent, Task and SendMessage" {
  mk_project
  for t in Agent Task SendMessage; do
    run_hook guard-subagent-authority.sh "$(tool_payload "$t" agent-1)"
    [ "$(decision)" = "deny" ]
  done
}
@test "subagent commit, rebase, reset, remote delete denied" {
  mk_project
  for c in 'git commit -m x' 'git rebase main' 'git reset HEAD~1' 'git push --delete origin x' 'git checkout -b other'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
}
@test "subagent read-only git allowed, single-file restore allowed" {
  mk_project
  for c in 'git status' 'git diff --stat' 'git log --oneline -3' 'git checkout -- src/a.cs'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$status" -eq 0 ] || { echo "nonzero status: $c"; false; }
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
@test "empty stdin denied" {
  mk_project
  run_hook guard-subagent-authority.sh ""
  [ "$(decision)" = "deny" ]
}
@test "messages reference memokit:coder, never coder.md" {
  mk_project
  run_hook guard-subagent-authority.sh "$(bash_payload 'git push' agent-1)"
  reason | grep -q 'memokit:coder'
  lacks "$(reason)" 'coder.md'
}
@test "english messages when language en" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook guard-subagent-authority.sh "$(bash_payload 'git push origin main' agent-1)"
  [ "$(decision)" = "deny" ]
  reason | grep -q 'may NOT push'
}
@test "commit message with quotes, backslash and percent literals still yields valid json and denies" {
  mk_project
  cmd='git commit -m "it'"'"'s \"q\" \\ %s %n"'
  run_hook guard-subagent-authority.sh "$(bash_payload "$cmd" agent-1)"
  [ "$(decision)" = "deny" ]
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "invalid json payload denied" {
  mk_project
  run_hook guard-subagent-authority.sh "not json"
  [ "$(decision)" = "deny" ]
}
sub_denied() { # $1 command, $2 reason fragment (optional)
  mk_project
  run_hook guard-subagent-authority.sh "$(bash_payload "$1" agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed: $1"; false; }
  if [ -n "${2:-}" ]; then reason | grep -q -- "$2" || { echo "reason lacks '$2': $(reason)"; false; }; fi
}
sub_allowed() { # $1 command
  mk_project
  run_hook guard-subagent-authority.sh "$(bash_payload "$1" agent-1)"
  [ "$status" -eq 0 ] || { echo "nonzero status: $1"; false; }
  [ "$(decision)" = "allow" ] || { echo "denied: $1"; false; }
}
@test "subagent git revert denied" { sub_denied 'git revert HEAD' 'revert'; }
@test "subagent git pull denied" { sub_denied 'git pull' 'pull'; }
@test "subagent git pull --rebase denied" { sub_denied 'git pull --rebase' 'pull'; }
@test "subagent git am denied" { sub_denied 'git am < x.patch' 'git am'; }
@test "subagent gh pr merge denied" { sub_denied 'gh pr merge 1' 'gh pr merge'; }
@test "subagent gh pr merge with repo flag and path-qualified gh denied" { sub_denied '/usr/local/bin/gh pr merge 1 --squash -R o/r'; }
@test "subagent git branch -f denied" { sub_denied 'git branch -f main HEAD~3' 'branch'; }
@test "subagent git branch --force denied" { sub_denied 'git branch --force main HEAD~3'; }
@test "subagent git branch -M denied" { sub_denied 'git branch -M x'; }
@test "subagent git branch -m denied" { sub_denied 'git branch -m old new'; }
@test "subagent git branch --move denied" { sub_denied 'git branch --move old new'; }
@test "subagent git filter-branch denied" { sub_denied 'git filter-branch --tree-filter x HEAD' 'filter-branch'; }
@test "subagent git commit-tree denied" { sub_denied 'git commit-tree HEAD^{tree} -m x' 'commit-tree'; }
@test "subagent env -i git commit denied" { sub_denied 'env -i git commit -m x' 'COMMIT'; }
@test "subagent env -u VAR git commit denied" { sub_denied 'env -u HOME git commit -m x'; }
@test "subagent env with flags and assignment then git push denied" { sub_denied 'env -i PATH=/usr/bin git push'; }
@test "subagent git --git-dir <dir> commit (separated form) denied" { sub_denied 'git --git-dir .git commit -m x' 'COMMIT'; }
@test "subagent git --work-tree <dir> commit (separated form) denied" { sub_denied 'git --work-tree . commit -m x'; }
@test "subagent read-only: git branch allowed" { sub_allowed 'git branch'; }
@test "subagent read-only: git branch -a allowed" { sub_allowed 'git branch -a'; }
@test "subagent read-only: gh pr view allowed" { sub_allowed 'gh pr view 1'; }
@test "subagent read-only: git log allowed" { sub_allowed 'git log'; }
@test "subagent read-only: env -i git status allowed" { sub_allowed 'env -i git status'; }
@test "subagent read-only: git --git-dir .git log allowed" { sub_allowed 'git --git-dir .git log'; }

# --- Rule 3 (0.8.0): subagents never touch remote targets or ask for a window.
SRCFG='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]},
"remote":{"deployBranches":["deploy"],"hosts":["prod.example.com"],"readOnlyFirstWords":["pm2-list"]}}'

sub_denied_with() { # KEY CMD
  run_hook guard-subagent-authority.sh "$(bash_payload "$2" agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed: $2"; false; }
  reason | grep -q "$1" || { echo "wrong reason: $(reason)"; false; }
}

@test "subagent: ssh to a configured host is denied even read-only" {
  mk_project "$SRCFG"
  sub_denied_with 'remote target' "ssh prod.example.com 'ls'"
}
@test "subagent: scp download from a configured host is denied" {
  mk_project "$SRCFG"
  sub_denied_with 'remote target' 'scp prod.example.com:/log ./'
}
@test "subagent: kubectl apply, helm upgrade, runbook, flyctl pattern target are denied" {
  mk_project "$SRCFG"
  for c in 'kubectl apply -f x.yaml' 'helm upgrade r ./c' 'bash .claude/memokit/runbooks/deploy.sh' 'flyctl deploy'; do
    sub_denied_with 'remote target' "$c"
  done
}
@test "subagent: reason carries the blocked segment" {
  mk_project "$SRCFG"
  sub_denied_with 'ssh prod.example.com reboot' 'echo hi && ssh prod.example.com reboot'
}
@test "subagent: memokit-window.sh request is denied, any case and any invocation" {
  mk_project "$SRCFG"
  for c in 'memokit-window.sh request host:x' 'MEMOKIT-WINDOW.SH request host:x' \
    'bash "${CLAUDE_PLUGIN_ROOT}/hooks/memokit-window.sh" request host:x' "bash '\${CLAUDE_PLUGIN_ROOT}/hooks/memokit-window' request a"; do
    sub_denied_with 'change window' "$c"
  done
}
@test "subagent: plugin hooks references, copies, globs and expansions are denied" {
  mk_project "$SRCFG"
  for c in 'memokit-window.sh;request a' 'memokit-window.sh)' 'x=1 memokit-window request a' \
    'cp "$CLAUDE_PLUGIN_ROOT/hooks/memokit-window.sh" /tmp/x' 'cp $CLAUDE_PLUGIN_ROOT/hooks/x /tmp/x' \
    'cat /p/hooks/memokit-window.sh | bash' 'bash ~/.claude/plugins/cache/x/memokit/0.8.0/hooks/mem* request a' 'bash /p/hooks/memokit-w* request a' \
    'bash $P/memokit-window.sh request a' 'bash ~/.claude/plugins/cache/x/MemoKit/0.8.0/Hooks/x.sh' 'bash /p/hooks/mem?kit-window.sh' \
    'bash /p/hooks/memokit-wind[o]w.sh' 'bash `echo /p`/memokit-w*' 'bash $(echo /p)/mem?kit-window'; do
    sub_denied_with 'change window' "$c"
  done
}
@test "subagent: unrelated memokit or hooks words are not denied" {
  mk_project "$SRCFG"
  for c in 'cat .claude/memokit.json' 'ls docs/hooks-notes' 'echo memokit-windows'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
@test "main session is untouched by the hooks-reference rules" {
  mk_project "$SRCFG"
  run_hook guard-subagent-authority.sh "$(bash_payload 'cp "$CLAUDE_PLUGIN_ROOT/hooks/memokit-window.sh" /tmp/x')"
  [ "$(decision)" = "allow" ]
}
@test "subagent: ssh to an unconfigured host passes" {
  mk_project "$SRCFG"
  run_hook guard-subagent-authority.sh "$(bash_payload "ssh other.example.org 'ls'" agent-1)"
  [ "$(decision)" = "allow" ]
}
@test "subagent: a too-large ssh line is denied" {
  mk_project "$SRCFG"
  long="$(head -c 60000 /dev/zero | tr '\0' a)"
  run_hook guard-subagent-authority.sh "$(bash_payload "ssh prod.example.com '$long'" agent-1)"
  [ "$(decision)" = "deny" ]
}
@test "subagent: a heredoc body naming ssh is denied too (the body may be executed)" {
  mk_project "$SRCFG"
  sub_denied_with 'remote target' "cat > docs/x.md <<'EOF'
run ssh prod.example.com reboot
EOF"
  sub_denied_with 'remote target' "bash <<EOF
ssh prod.example.com reboot
EOF"
  sub_denied_with 'remote target' "python - <<EOF
import os; os.system(\"ssh prod.example.com reboot\")
EOF"
  run_hook guard-subagent-authority.sh "$(bash_payload "cat > docs/x.md <<'EOF'
run ssh prod.example.com reboot
EOF")"
  [ "$(decision)" = "allow" ]
}
@test "subagent: copying, linking or entering the plugin hooks dir is denied" {
  mk_project "$SRCFG"
  for c in 'cd ~/.claude/plugins/cache/x/memokit/0.8.0/hooks && cp m* /tmp/w' \
    'cp -r ~/.claude/plugins/cache/x/memokit/0.8.0 /tmp/m' 'ln -s ~/.claude/plugins/x /tmp/h' \
    'cd /p/memokit/0.8.0/hooks; cp *-w* /tmp/w' 'tar cf /tmp/a.tar /x/plugins/cache/m' \
    'rsync -a /home/u/.claude/plugins/x /tmp/y' 'cp -r /p/memokit/1.2 /tmp/z'; do
    sub_denied_with 'change window' "$c"
  done
}
@test "subagent: editing .claude/memokit.json is denied, reading it is not" {
  mk_project "$SRCFG"
  for c in 'echo {} > .claude/memokit.json' 'echo x >> .claude/memokit.json' 'jq . x | tee .claude/memokit.json' \
    "sed -i 's/a/b/' .claude/memokit.json" 'cp /tmp/x .claude/memokit.json' 'mv x .claude/memokit.json' \
    'rm .claude/memokit.json' 'jq .a .claude/memokit.json > /tmp/o' 'truncate -s 0 .claude/MEMOKIT.JSON' \
    'ln -sf /tmp/x .claude/memokit.json' 'install -m 644 /tmp/x .claude/memokit.json' 'echo {} > .claude/memo*.json'; do
    sub_denied_with 'configuration' "$c"
  done
  for c in 'cat .claude/memokit.json' 'jq . .claude/memokit.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
@test "subagent: Edit, Write, MultiEdit, NotebookEdit on memokit.json are denied, other paths not" {
  mk_project "$SRCFG"
  ln -s memokit.json "$PROJ/.claude/alias.json"
  ln -s alias.json "$PROJ/.claude/alias2.json"
  for t in Edit Write MultiEdit NotebookEdit; do
    for p in "$PROJ/.claude/memokit.json" "$PROJ/.claude/alias2.json" ".claude/MemoKit.json"; do
      run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$t" --arg p "$p" --arg cwd "$PROJ" '{tool_name:$t,tool_input:{file_path:$p,notebook_path:$p},cwd:$cwd,agent_id:"a1"}')"
      [ "$(decision)" = "deny" ] || { echo "allowed: $t $p"; false; }
      reason | grep -q 'configuration'
    done
    run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$t" --arg p "$PROJ/src/a.cs" --arg cwd "$PROJ" '{tool_name:$t,tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
    [ "$(decision)" = "allow" ]
    run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$t" --arg p "$PROJ/.claude/memokit.json" --arg cwd "$PROJ" '{tool_name:$t,tool_input:{file_path:$p},cwd:$cwd}')"
    [ "$(decision)" = "allow" ]
  done
}
@test "subagent: config writes through interpreters, expansion, cd and hard links are denied" {
  mk_project "$SRCFG"
  for c in "python3 -c \"open('.claude/memokit.json','w')\"" "cd .claude && printf '{}' > memokit.json" \
    'f=.claude/memokit.json; echo x > $f' 'dd of=.claude/memokit.json' \
    'ln .claude/memokit.json /tmp/h && echo x > /tmp/h' 'perl -e 1 ./.claude/memokit.json' \
    'awk 1 .claude/memokit.json' 'cd .claude; tee memokit.json'; do
    sub_denied_with 'configuration' "$c"
  done
  for c in 'cat .claude/memokit.json' 'ls .claude' 'jq . .claude/memokit.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
@test "subagent: Write to a hard link or a directory symlink of the config is denied" {
  mk_project "$SRCFG"
  ln "$PROJ/.claude/memokit.json" "$PROJ/hard.json"
  ln -s "$PROJ/.claude" "$PROJ/dirlink"
  for p in "$PROJ/hard.json" "$PROJ/dirlink/memokit.json" "$PROJ/.claude/memokit/../x.json"; do
    run_hook guard-subagent-authority.sh "$(jq -nc --arg p "$p" --arg cwd "$PROJ" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  run_hook guard-subagent-authority.sh "$(jq -nc --arg p "$PROJ/src/new.cs" --arg cwd "$PROJ" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
  [ "$(decision)" = "allow" ]
}
@test "subagent: removing or restoring .claude and its ancestors is denied" {
  mk_project "$SRCFG"
  for c in 'mv .claude /tmp/x' 'rm -rf .claude' 'rm -rf .claude/' 'mv .claude/memokit.json x' \
    'rsync --delete /tmp/empty/ .claude/' 'git checkout -- .claude/memokit.json' 'git restore .claude/memokit.json' \
    "git reset -- .claude" "rm -rf $PROJ" "mv $PROJ /tmp/p" 'rm -rf .' 'rsync -a --delete /tmp/e/ ./' \
    'cd src && rm -rf ..' 'echo "$ROOT"/.claude'; do
    sub_denied_with 'configuration' "$c"
  done
}
@test "subagent: the config name allowlist lets plain reads through" {
  mk_project "$SRCFG"
  for c in 'cat .claude/memokit.json' 'jq . .claude/memokit.json' 'ls .claude' 'grep remote .claude/memokit.json | head -3' \
    'wc -l .claude/memokit.json' 'stat .claude/memokit.json' 'diff .claude/memokit.json /tmp/x'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
  sub_denied_with 'configuration' 'cat .claude/memokit.json | tee /tmp/o'
}
@test "subagent: editing memokit.json.bak or a lookalike name is not a config edit" {
  mk_project "$SRCFG"
  for p in "$PROJ/.claude/memokit.json.bak" "$PROJ/docs/my-memokit.json.md"; do
    run_hook guard-subagent-authority.sh "$(jq -nc --arg p "$p" --arg cwd "$PROJ" '{tool_name:"Edit",tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
    [ "$(decision)" = "allow" ] || { echo "denied: $p"; false; }
  done
}

# A config that vanishes mid-session: session-start.sh leaves a marker.
mark_active() { # SESSION
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; cd '$PROJ'; mk_resolve_root '{}'; mk_active_marker_write '{\"session_id\":\"$1\"}'"
  [ "$status" -eq 0 ]
}
sess_payload() { # SESSION [AGENT]
  jq -nc --arg s "$1" --arg a "${2:-}" --arg cwd "$PROJ" \
    '{tool_name:"Bash",tool_input:{command:"ls"},cwd:$cwd,session_id:$s} + (if $a=="" then {} else {agent_id:$a} end)'
}
@test "config vanished: marker + removed config denies a subagent, not the main session" {
  mk_project "$SRCFG"
  mark_active s9
  rm "$PROJ/.claude/memokit.json"
  for h in guard-subagent-authority.sh guard-destructive.sh; do
    run_hook $h "$(sess_payload s9 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed by $h"; false; }
    reason | grep -q 'vanished'
    run_hook $h "$(sess_payload s9)"
    [ -z "$output" ]
    run_hook $h "$(sess_payload other agent-1)"
    [ -z "$output" ]
  done
}
@test "config vanished: no marker means memokit never was active, silence" {
  mk_project "$SRCFG"
  rm "$PROJ/.claude/memokit.json"
  run_hook guard-subagent-authority.sh "$(sess_payload s9 agent-1)"
  [ -z "$output" ]
  run_hook guard-destructive.sh "$(sess_payload s9 agent-1)"
  [ -z "$output" ]
}
@test "session-start writes the active marker" {
  mk_project "$SRCFG"
  run_hook session-start.sh "$(jq -nc --arg cwd "$PROJ" '{cwd:$cwd,session_id:"s7",source:"startup"}')"
  rm "$PROJ/.claude/memokit.json"
  run_hook guard-subagent-authority.sh "$(sess_payload s7 agent-1)"
  [ "$(decision)" = "deny" ]
}
@test "subagent: worktree lanes under .claude/worktrees work as ordinary paths" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W/src" "$W/tests"
  for c in "cd $W && npm test" "bats $W/tests/x.bats" "git -C $W status" "mkdir -p $W/src/x" \
    "echo hi > $W/src/a.txt" 'echo "$CLAUDE_PROJECT_DIR"' 'cd "$CLAUDE_PROJECT_DIR" && npm test' \
    'cp .claude/memokit/a.md /tmp/' "ls $PROJ/.claude/memokit/runs/x"; do
    run_hook guard-subagent-authority.sh "$(jq -nc --arg c "$c" --arg cwd "$W" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,agent_id:"a1"}')"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  run_hook guard-subagent-authority.sh "$(jq -nc --arg p "$W/src/new/a.cs" --arg cwd "$W" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
  [ "$(decision)" = "allow" ]
}
@test "subagent: climbing out of .claude/memokit with /.. is a config reference" {
  mk_project "$SRCFG"
  for c in 'rsync -a --delete /tmp/e/ .claude/memokit/../' 'cd .claude/memokit/.. && tee memo* < /tmp/x' 'rm -rf .claude/*' 'rm .claude/memo*'; do
    sub_denied_with 'configuration' "$c"
  done
}
@test "active marker is careful-state: rm, mv and truncation of it are denied" {
  mk_project "$SRCFG"
  mark_active s5
  f="$(ls "${TMPDIR:-/tmp}"/memokit-*-careful-active-s5 | head -1)"
  [ -f "$f" ]
  for c in "rm -f $f" "mv $f /tmp/z" ": > $f"; do
    run_hook guard-destructive.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  run_hook guard-destructive.sh "$(bash_payload 'rm -f /tmp/other-active' agent-1)"
  [ "$(decision)" = "allow" ]
}
@test "main session is untouched by plugin-dir and config rules" {
  mk_project "$SRCFG"
  for c in 'cd /p/hooks; cp m* /tmp/w' 'echo {} > .claude/memokit.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c")"
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
@test "main session is untouched by Rule 3" {
  mk_project "$SRCFG"
  for c in "ssh prod.example.com 'ls'" 'kubectl apply -f x.yaml' 'memokit-window.sh request host:x'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c")"
    [ "$status" -eq 0 ]
    [ "$(decision)" = "allow" ] || { echo "denied: $c"; false; }
  done
}
@test "without a remote block only the request script is denied" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook guard-subagent-authority.sh "$(bash_payload "ssh prod.example.com 'ls'" agent-1)"
  [ "$(decision)" = "allow" ]
  sub_denied_with 'change window' 'memokit-window.sh request host:x'
}

# --- Fix round 4: a .claude word is lane-exempt only when fully literal. -----
lane_cmd() { # CWD CMD
  run_hook guard-subagent-authority.sh "$(jq -nc --arg c "$2" --arg cwd "$1" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,agent_id:"a1"}')"
}
lane_write() { # CWD PATH
  run_hook guard-subagent-authority.sh "$(jq -nc --arg p "$2" --arg cwd "$1" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
}
@test "subagent: a .claude word holding an expansion, glob or .. is a config candidate" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W/src"
  for c in 'cp /tmp/x `pwd`/.claude/x/' 'cp /tmp/x $(pwd)/.claude/x/y' 'cp /tmp/x $(echo /p)/.claude/x/y' 'cp /tmp/x ${D}/.claude/sub/' \
    'cp /tmp/x "$D"/.claude/worktrees/lane1/../../memokit.json' 'cp /tmp/x .claude/worktrees/../memokit.json' \
    'cp /tmp/x .claude/w*/../memokit.json' 'rm -rf .claude/w?rktrees/x/' 'cp /tmp/x ../../memo*' 'rm -rf ../..' \
    'cp /tmp/x $W/../../memo*' "cp /tmp/x $W/../../m*" 'cd ../.. && tee m* < /tmp/x' 'rm -rf ../../..' 'mv x ../' 'rm ../../m*' \
    'sed -i s/prod/x/ ../../*.json' 'ln -s ../.. up && sed -i s/a/b/ up/*.json' 'cd .. && cd .. && tee memo* < /tmp/x'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  for c in "cd $W && echo \$X" 'bats "$W/tests/x.bats"' "git -C $W status" 'ls .claude/worktrees/lane1/*' \
    'cat ../README.md' "cp /tmp/x $W/src/a.txt" "ls $W/src/../src" 'cp /tmp/x src/a' 'bats ./tests' 'bats tests/*.bats' '(cd src && make)'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "subagent: an expansion inside a word naming claude or memokit is denied" {
  mk_project "$SRCFG"
  for c in 'echo {} > $D/.claude/memokit.json' 'echo {} > ${C}laude/memokit.json' 'echo {} > $(echo .claude)/memokit.json' \
    'cp /tmp/x $HOME/memokit/a' 'rm -rf "$CLAUDE_PROJECT_DIR"' 'rm -rf ${CLAUDE_PROJECT_DIR}/' \
    'cp /tmp/x "$CLAUDE_PROJECT_DIR/.claude/memokit.json"' 'cp /tmp/x $D/.claude/x/y' \
    "cp /tmp/x \$CLAUDE_PROJECT_DIR/\$(echo .claude)"; do
    sub_denied_with 'configuration\|change window' "$c"
  done
  for c in 'echo "$CLAUDE_PROJECT_DIR"' 'cd "$CLAUDE_PROJECT_DIR" && npm test' 'cat "${CLAUDE_PROJECT_DIR}/src/a.cs"' \
    'bats "$CLAUDE_PROJECT_DIR/tests/x.bats"' 'echo $HOME/x'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "subagent: Write paths are normalised before the config checks" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W/src"
  ln -s .claude "$PROJ/cl"
  for p in "$PROJ/nonexist/x/../../.claude" "$PROJ/nonexist/.claude" "$PROJ/cl/memokit.json/x/.." \
    "$PROJ/cl/MEMOKIT.JSON/a/b/../.." "$PROJ/src/nope/../../.claude/memokit.json" "$PROJ/src/nope/../../cl"; do
    lane_write "$PROJ" "$p"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  for p in ../cl/memokit.json/q/.. ../.claude ../cl/x/../; do
    lane_write "$PROJ/src" "$p"
    [ "$(decision)" = "deny" ] || { echo "allowed relative: $p"; false; }
  done
  for p in "$W/src/new/a.cs" "$W/src/new/deep/b.cs" "$W/src/a.cs" "$PROJ/src/new/c.cs" "$PROJ/src/../src/d.cs"; do
    lane_write "$W" "$p"
    [ "$(decision)" = "allow" ] || { echo "denied: $p"; false; }
  done
  lane_write "$W" "src/new/e.cs"
  [ "$(decision)" = "allow" ]
}
@test "subagent: config targets glued to options or behind = are references" {
  mk_project "$SRCFG"
  for c in 'tar --directory=.claude -xf /tmp/e.tar' 'tar -xf /tmp/e.tar -C.claude' 'cp --target-directory=.claude /tmp/e/x' \
    'cd .claude && dd if=/tmp/x of=memokit.json' 'cd .claude && sort --output=memokit.json /tmp/x' 'sort -o.claude/memokit.json /tmp/x' \
    'cp /tmp/x .c*/m*' 'cp /tmp/x .*/memo*'; do
    sub_denied_with 'configuration' "$c"
  done
}
@test "subagent: a climb split across words next to a .claude word is a reference" {
  mk_project "$SRCFG"
  mkdir -p "$PROJ/.claude/worktrees/lane1"
  for c in 'cd .claude/worktrees && cd .. && tee memo* </tmp/x' 'cd .claude/worktrees; cd ..; rm m*'; do
    sub_denied_with 'configuration' "$c"
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'ls .claude/worktrees ../x' agent-1)"
  [ "$(decision)" = "allow" ]
}
@test "subagent: writes through a lane symlink or hard link of the config are denied" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W/src"
  ln -s "$PROJ/.claude/memokit.json" "$W/cfglink"
  ln "$PROJ/.claude/memokit.json" "$W/cfghard"
  ln -s "$PROJ/.claude" "$W/dirlink"
  for c in 'echo x > .claude/worktrees/lane1/cfglink' 'cp /tmp/x .claude/worktrees/lane1/cfghard' \
    "echo x | tee $W/cfglink" 'cd .claude/worktrees/lane1 && echo x > cfglink' 'rm -rf .claude/worktrees/lane1/dirlink/' \
    'dd if=/tmp/x of=.claude/worktrees/lane1/cfghard'; do
    sub_denied_with 'configuration' "$c"
  done
  for c in 'echo x > cfglink' 'cp /tmp/x cfghard'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "deny" ] || { echo "allowed in lane: $c"; false; }
  done
  for c in 'echo x > .claude/worktrees/lane1/src/a' 'cat .claude/worktrees/lane1/cfglink'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "subagent: hook files of a memokit checkout are readable, the install location is not" {
  mk_project "$SRCFG"
  run_hook guard-subagent-authority.sh "$(bash_payload 'cat /Users/x/GitHub/memokit/.claude/worktrees/l1/hooks/careful.sh' agent-1)"
  [ "$(decision)" = "allow" ]
  sub_denied_with 'change window' 'cat ~/.claude/plugins/cache/x/memokit/0.8.0/hooks/memokit-window.sh'
  sub_denied_with 'change window' 'cat /opt/memokit/0.8.0/hooks/careful.sh'
}

# --- Fix round 5. -------------------------------------------------------------
@test "subagent: a brace expansion word is non-literal and judged per alternative" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W/src"
  for c in 'tee {.c,}laude/m{e,}mokit.json </tmp/x' 'sed -i s/prod/x/ {.c,}laude/m{e,}mokit.json' 'rm -rf {.c,x}laude' \
    'cd .claude/worktrees/lane1/.{.,}/.{.,} && tee m* </tmp/x' 'rm -rf .{c..c}laude'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  for c in 'tee .{.,x}/.{.,x}/m{e,}mokit.json </tmp/x' 'cd .{.,}/.{.,} && tee m* </tmp/x' 'tee "${PWD%/*/*}"/m{e,}mokit.json </tmp/x'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "deny" ] || { echo "allowed in lane: $c"; false; }
  done
  for c in 'mkdir -p src/{a,b}' 'cp src/{a,b}.ts /tmp/' 'for i in {1..3}; do echo $i; done'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "subagent: cd and pushd with options still anchor relative link checks" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W"
  ln -s "$PROJ/.claude/memokit.json" "$W/cfglink"
  for c in 'cd -P .claude/worktrees/lane1 && echo x > cfglink' 'cd -- .claude/worktrees/lane1 && echo x > cfglink' \
    'pushd .claude/worktrees/lane1 && echo x > cfglink' 'cd -L -- .claude/worktrees/lane1; echo x > cfglink' \
    '(cd .claude/worktrees/lane1 && echo x > cfglink)'; do
    sub_denied_with 'configuration' "$c"
  done
}
@test "subagent: in a lane, cd or pushd to an expansion is a config candidate" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W"
  for c in 'cd $(dirname $(dirname $PWD)) && tee m* </tmp/x' 'cd `dirname $PWD` && rm m*' 'pushd ${PWD%/*/*} && tee m* </tmp/x' \
    'cd "$CLAUDE_PROJECT_DIR/.." && rm -rf x'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  for c in 'cd "$CLAUDE_PROJECT_DIR" && npm test' 'cd "${CLAUDE_PROJECT_DIR}/src" && ls'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "subagent: Write resolves the path lexically and physically" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W"
  ln -s "$W" "$PROJ/wl"
  for p in "$PROJ/wl/../.." "$PROJ/wl/../../new.json" "$PROJ/wl/../x/new.json"; do
    lane_write "$PROJ" "$p"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  for p in "$PROJ/wl/src/a.cs" "$PROJ/src/../src/d.cs"; do
    lane_write "$PROJ" "$p"
    [ "$(decision)" = "allow" ] || { echo "denied: $p"; false; }
  done
}
@test "final I7 (p19): a missing parent with .. is folded first, then resolved on its existing prefix" {
  mk_project "$SRCFG"
  local T="$BATS_TEST_TMPDIR/mkrev-x"
  # neither T nor T/nope exists: the folded path is an ordinary new file
  for p in "$T/nope/../y.txt" "$T/a/b/../../c/d.txt" "$PROJ/src/nope/deeper/../x.cs"; do
    lane_write "$PROJ" "$p"
    [ "$(decision)" = "allow" ] || { echo "denied: $p: $(reason)"; false; }
  done
  # the folded path still lands on the config or .claude: denied
  for p in "$PROJ/nope/more/../../.claude/memokit.json" "$PROJ/nope/../.claude" "$T/../../$(basename "$(dirname "$BATS_TEST_TMPDIR")")/x/../$(basename "$BATS_TEST_TMPDIR")/q/.claude/x"; do
    lane_write "$PROJ" "$p"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  # the existing prefix is resolved physically: a symlink to .claude below a
  # missing directory chain still denies
  ln -s "$PROJ/.claude" "$BATS_TEST_TMPDIR/cfglink"
  lane_write "$PROJ" "$BATS_TEST_TMPDIR/cfglink/nope/../memokit.json"
  [ "$(decision)" = "deny" ]
  lane_write "$PROJ" "$BATS_TEST_TMPDIR/new/more/../../cfglink"
  [ "$(decision)" = "deny" ]
}

# Final review (set -f): the guard no longer globs every word, so a glob
# command word and a glob cd target are expanded on their own (payload cwd).
@test "noglob: a glob command word is expanded and judged; a glob cd target is a base" {
  mk_settings
  # no remote block: the git and gh rules speak, not the remote scan
  printf '%s' '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  local d="$BATS_TEST_TMPDIR/g"
  mkdir -p "$d/bin" "$d/nomatch"
  printf '#!/bin/sh\n' > "$d/bin/git"; printf '#!/bin/sh\n' > "$d/bin/gh"; chmod +x "$d/bin/git" "$d/bin/gh"
  case "$d" in *[*?[]*) skip "temp path holds a glob character" ;; esac
  for c in "$d/bin/g?t commit -m x" "$d/*/git push" "cd $d && bin/g[i]t commit -m x"; do
    sub_denied_with 'may NOT' "$c"
  done
  lane_cmd "$d" 'b*/gi? commit -m x'
  [ "$(decision)" = "deny" ] || { echo "relative glob allowed"; false; }
  reason | grep -q 'may NOT commit' || { echo "wrong reason: $(reason)"; false; }
  sub_denied_with 'merge a pull request' "$d/bin/g? pr merge 1"
  if [ -x /usr/bin/git ]; then
    for c in '/usr/bin/g?t commit -m x' '/usr/*/git push' '/u*/b*/git commit -m x'; do sub_denied_with 'may NOT' "$c"; done
  fi
  # a glob command word that matches nothing is judged literally
  for c in "$d/nomatch/g?t commit -m x" "$d/bin/zz* push"; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  # a glob cd target into <root>/.claude is a base
  sub_denied_with 'may NOT change Claude Code settings' 'cd .cl*de && echo x > settings.json'
  sub_denied_with 'NOT' 'cd .cl?ude && echo x > memokit.json'
  run_hook guard-subagent-authority.sh "$(bash_payload 'cd s?c && echo x > settings.json' agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: cd s?c: $(reason)"; false; }
}
# Follow-up (R2): case arms split into glob command words (*), *.json)); only
# a word whose last component can match git or gh is expanded, and only as
# DIR/git or DIR/gh.
@test "noglob: case arms are not expanded as command words" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  local d="$BATS_TEST_TMPDIR/j" c
  mkdir -p "$d"
  (cd "$d" && awk 'BEGIN { for (i = 0; i < 80; i++) print "f" i ".json" }' | xargs touch)
  c="case \$x in"; for i in $(seq 1 150); do c="$c a$i|*) echo $i ;; x$i*) ;;"; done; c="$c esac"
  for c in 'case $x in a) echo a ;; *) echo b ;; esac' 'case $f in x) ;; *.json) echo j ;; esac' "$c"; do
    lane_cmd "$d" "$c"
    [ "$(decision)" = "allow" ] || { echo "denied: ${c:0:80}: $(reason)"; false; }
  done
}
@test "subagent: lane globs without an expansion and scratchpad paths are ordinary" {
  mk_project "$SRCFG"
  W="$PROJ/.claude/worktrees/lane1"
  mkdir -p "$W"
  for c in 'cp /tmp/build/*.js dist/' 'rm -f /tmp/mk-*.tmp' 'cp x /private/tmp/claude-501/s/scratchpad/$N'; do
    lane_cmd "$W" "$c"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'cp x /private/tmp/claude-501/s/scratchpad/$N' agent-1)"
  [ "$(decision)" = "allow" ]
  # final review: a *.json glob that matches settings.json and memokit.json
  # alike, next to the scratchpad (its path names claude, not .claude)
  for c in 'cp dist/*.json /private/tmp/claude-501/x/scratchpad/' 'jq . dist/*.json > /private/tmp/claude-501/x/scratchpad/all.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  # the same glob with a home or .claude spelling in the command still denies
  for c in 'cp dist/*.json ~/.claude/' 'cp dist/*.json .claude/'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  lane_cmd "$W" 'for f in $SRC/*.cs; do echo $f; done'
  [ "$(decision)" = "deny" ]
}
@test "subagent: the window glob rule needs the request name or an install location" {
  mk_project "$SRCFG"
  for c in 'shellcheck hooks/*.sh hooks/lib/*.sh' 'cd hooks && ls' 'bats /Users/x/GitHub/memokit/tests/*.bats'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  sub_denied_with 'change window' 'ls ~/.claude/plugins/cache/x/memokit/0.8.0/hooks/mem*'
}

# --- 0.8.1 (spec 3b): the Claude Code settings files, by exact path. --------
# HOME points at a temp dir; the project's and the user's settings.json and
# settings.local.json are protected, no other settings.json is.
mk_settings() {
  mk_project "$SRCFG"
  HOME="$(mktemp -d "${MK_FIXTMP}/mkhome.XXXXXX")"
  HOME="$(cd "$HOME" && pwd)"
  export HOME
  mkdir -p "$HOME/.claude"
  for f in "$PROJ/.claude/settings.json" "$PROJ/.claude/settings.local.json" "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    printf '{}\n' > "$f"
  done
}
tool_write() { # TOOL PATH [AGENT]
  run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$1" --arg p "$2" --arg a "${3-a1}" --arg cwd "$PROJ" \
    '{tool_name:$t,tool_input:{file_path:$p,old_string:"a",new_string:"b",content:"x"},cwd:$cwd} + (if $a=="" then {} else {agent_id:$a} end)')"
}
settings_denied() { # TOOL PATH
  tool_write "$1" "$2"
  [ "$(decision)" = "deny" ] || { echo "allowed: $1 $2"; return 1; }
  reason | grep -qF 'may NOT change Claude Code settings' || { echo "wrong reason for $1 $2: $(reason)"; return 1; }
}
@test "settings: Write and Edit to the four settings files are denied with the settings reason" {
  mk_settings
  for t in Write Edit; do
    for p in "$PROJ/.claude/settings.json" "$PROJ/.claude/settings.local.json" \
      "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
      settings_denied "$t" "$p"
    done
  done
}
@test "settings: symlink, hard link, .. and relative spellings of a settings file are denied" {
  mk_settings
  ln -s "$PROJ/.claude/settings.json" "$PROJ/src/slink.json"
  ln -s "$HOME/.claude/settings.local.json" "$PROJ/src/ulink.json"
  ln "$PROJ/.claude/settings.local.json" "$PROJ/src/hard.json"
  ln "$HOME/.claude/settings.json" "$PROJ/src/uhard.json"
  for t in Write Edit; do
    for p in "$PROJ/src/slink.json" "$PROJ/src/ulink.json" "$PROJ/src/hard.json" "$PROJ/src/uhard.json" \
      "$PROJ/src/../.claude/settings.json" ".claude/settings.local.json" "src/../.claude/settings.json" \
      "$PROJ/.claude/Settings.JSON" "$PROJ/src/../../$(basename "$PROJ")/.claude/settings.local.json" \
      '~/.claude/settings.json'; do
      settings_denied "$t" "$p"
    done
  done
  # a user settings file not created yet is protected too
  rm "$HOME/.claude/settings.local.json"
  settings_denied Write "$HOME/.claude/settings.local.json"
}
@test "settings: Bash write forms on a settings file are denied with the settings reason" {
  mk_settings
  for c in 'echo x > .claude/settings.json' 'tee -a "$HOME/.claude/settings.local.json"' \
    'cp /tmp/s .claude/settings.json' 'jq . a > ~/.claude/settings.json' \
    'jq . a > ${HOME}/.claude/settings.json' "echo x >> $HOME/.claude/settings.local.json" \
    "sed -i '' s/a/b/ $PROJ/.claude/settings.local.json" 'rm .claude/settings.local.json' \
    'mv /tmp/s ./.claude/settings.json' 'cp /tmp/s src/../.claude/settings.json' \
    'python3 -c "open(\".claude/settings.json\",\"w\")"' 'dd of=.claude/settings.json' \
    'cp /tmp/s .claude/settings{,.local}.json' 'cp /tmp/s ~/.claude/settings.local.json' \
    'cd ~ && cp /tmp/s .claude/settings.json' 'echo x > .CLAUDE/SETTINGS.JSON' 'sort -o.claude/settings.json x' \
    'echo x > ~/.claude/../.claude/settings.json' 'cp x "$CLAUDE_PROJECT_DIR/.claude/settings.local.json"' \
    'git checkout -- .claude/settings.json' 'echo x | tee -a ~/.claude/settings.json >/dev/null'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  # a hard link and a symlink made earlier, written by a neutral name
  ln "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/h"
  ln -s "$PROJ/.claude/settings.local.json" "$BATS_TEST_TMPDIR/s"
  sub_denied_with 'may NOT change Claude Code settings' "echo x > $BATS_TEST_TMPDIR/h"
  sub_denied_with 'may NOT change Claude Code settings' "cp /tmp/x $BATS_TEST_TMPDIR/s"
  # from a cwd below the project root
  run_hook guard-subagent-authority.sh "$(jq -nc --arg cwd "$PROJ/src" '{tool_name:"Bash",tool_input:{command:"echo x > ../.claude/settings.json"},cwd:$cwd,agent_id:"a1"}')"
  [ "$(decision)" = "deny" ]; reason | grep -qF 'may NOT change Claude Code settings'
}
@test "settings: other settings.json files, ~/.claude itself and reads stay allowed" {
  mk_settings
  mkdir -p "$PROJ/.vscode" "$PROJ/src/app" "$PROJ/.claude/worktrees/mk-r-a/.claude"
  for p in "$PROJ/.vscode/settings.json" "$PROJ/src/app/settings.json" \
    "$PROJ/.claude/worktrees/mk-r-a/.claude/settings.json" "$PROJ/.claude/worktrees/mk-r-a/.claude/settings.local.json" \
    "$HOME/.claude/notes.md" "$HOME/.claude/settings.json.bak" "$HOME/settings.json"; do
    for t in Write Edit; do
      tool_write "$t" "$p"
      [ "$(decision)" = "allow" ] || { echo "denied: $t $p: $(reason)"; false; }
    done
  done
  for c in 'cat .claude/settings.json' 'jq .hooks ~/.claude/settings.json' "grep env $HOME/.claude/settings.local.json | head -3" \
    'echo x > .vscode/settings.json' 'cp /tmp/s src/app/settings.json' 'echo x > ~/.claude/notes.md' \
    'echo x > .claude/worktrees/mk-r-a/.claude/settings.json' 'tee settings.json < /tmp/x' 'ls ~/.claude' \
    'cat ~/.claude/settings.json' 'cp x ~/.claude/settings.json.bak' 'echo x > src/settings.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  # a lane cwd: its own .claude/settings.json is ordinary
  lane_cmd "$PROJ/.claude/worktrees/mk-r-a" 'echo x > .claude/settings.json'
  [ "$(decision)" = "allow" ] || { echo "lane denied: $(reason)"; false; }
}
@test "settings: the main session is not denied by this hook" {
  mk_settings
  for p in "$PROJ/.claude/settings.local.json" "$HOME/.claude/settings.json"; do
    tool_write Write "$p" ""
    [ "$(decision)" = "allow" ]
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo x > .claude/settings.local.json')"
  [ "$(decision)" = "allow" ]
}
@test "settings fix 1: computed or glob words that could name a settings file deny when the command names claude or home" {
  mk_settings
  for c in 'cp x $CLAUDE_DIR/settings.json' 'D=~/.claude; cp x $D/settings.local.json' 'cp x ~/.claude/setting*' \
    'cp x ~/.claude/s*.json' 'cp x .claude/*.local.json' 'echo x > "$HOME/.claude/$(echo settings).json"' \
    'echo x > $CLAUDE_CONFIG_DIR/settings.json' 'tee ${HOME}/.Claude/Settings.Json < /tmp/x' \
    'cp x .claude/[s]ettings.json' 'cp x ~/.claude/settings.$EXT.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  # with no claude or home mention, a computed settings.json is ordinary
  for c in 'cp $SRC/app.json dist/' 'cp x src/*.json' 'echo x > $OUT/app.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "settings fix 1: CLAUDE_CONFIG_DIR settings files are protected when it is set" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  printf '{}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  settings_denied Write "$CLAUDE_CONFIG_DIR/settings.json"
  settings_denied Edit "$CLAUDE_CONFIG_DIR/settings.local.json"
  sub_denied_with 'may NOT change Claude Code settings' "cp /tmp/x $CLAUDE_CONFIG_DIR/settings.json"
  tool_write Write "$CLAUDE_CONFIG_DIR/notes.md"
  [ "$(decision)" = "allow" ]
}
@test "settings fix 1: a bound hit inside the settings gate fails closed" {
  mk_settings
  # more than MK_GS_MAX_BASES cd targets
  sub_denied_with 'NOT' 'cd a; cd b; cd c; cd d; cd e; cd f; cd g; cd h; cd i; cd j; echo x > settings.json'
}
@test "settings fix 2: a dotfiles symlink named through ~ or \$HOME is denied" {
  mk_settings
  mkdir -p "$HOME/dotfiles"
  mv "$HOME/.claude/settings.local.json" "$HOME/dotfiles/settings.local.json"
  ln -s "$HOME/dotfiles/settings.local.json" "$HOME/.claude/settings.local.json"
  for c in 'echo x > ~/dotfiles/settings.local.json' 'echo x > $HOME/dotfiles/settings.local.json' \
    'cp /tmp/x "${HOME}/dotfiles/settings.local.json"'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  ln "$HOME/.claude/settings.json" "$HOME/dotfiles/s.json"
  sub_denied_with 'may NOT change Claude Code settings' 'echo x > ~/dotfiles/s.json'
}
@test "settings fix 3: ~user spellings of the user settings files are denied" {
  mk_settings
  for c in 'echo x > ~root/.claude/settings.json' 'cp x ~someone/.claude/Settings.Local.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'cp x ~root/src/settings.json' agent-1)"
  [ "$(decision)" = "allow" ]
}
@test "settings fix 4: 2>/dev/null and 2>&1 are reads; git diff/log/show/status naming settings or memokit.json are denied (git runs repo-configured drivers)" {
  mk_settings
  for c in 'grep x .claude/settings.json 2>/dev/null' 'cat ~/.claude/settings.json 2>&1 | head -3' \
    'jq . .claude/memokit.json 2>/dev/null; ls .claude 2>&1' 'grep x .claude/memokit.json 2>/dev/null'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  for c in 'grep x .claude/settings.json 2>/dev/null.txt' 'cat .claude/settings.json 2>/tmp/e' \
    'git diff --output=/tmp/o .claude/settings.json' 'GIT_EXTERNAL_DIFF=/tmp/x git diff .claude/settings.json' \
    'git -c core.pager=x log .claude/settings.json' 'git checkout -- .claude/settings.json' \
    'cat .claude/settings.json 2>&1 > /tmp/o' 'git diff .claude/settings.json' \
    'git --no-pager diff --stat .claude/settings.local.json' 'git log -p ~/.claude/settings.json' \
    'git diff --ext-diff .claude/settings.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  for c in 'git log -p -- .claude/memokit.json' 'git status --short .claude' 'git show HEAD:.claude/memokit.json'; do
    sub_denied_with 'configuration' "$c"
  done
  for c in 'git diff --output=/tmp/o .claude/memokit.json' 'cat .claude/memokit.json 2>/tmp/e'; do
    sub_denied_with 'configuration' "$c"
  done
}
@test "settings fix 2-1: an untranslatable glob in a settings-shaped last component fails closed" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  for c in 'cp x $CLAUDE_CONFIG_DIR/[[:alpha:]]ettings.json' 'cd $CLAUDE_CONFIG_DIR && cp x [[:alpha:]]ettings.json' \
    'cp x ~/.claude/[]s]ettings.local.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  # a glob whose literal tail cannot end a settings name stays ordinary
  run_hook guard-subagent-authority.sh "$(bash_payload 'cp x ~/src/[[:alpha:]]*.cs' agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
}
@test "settings fix 2-2: naming CLAUDE_CONFIG_DIR by its path enables the expansion/glob trigger" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  local phys up
  phys="$(cd -P "$CLAUDE_CONFIG_DIR" && pwd -P)"
  up="$(printf '%s' "$CLAUDE_CONFIG_DIR" | tr '[:lower:]' '[:upper:]')"
  case "$CLAUDE_CONFIG_DIR$phys" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  for c in "cp x $CLAUDE_CONFIG_DIR/s*.json" "cp x $phys/setting?.json" "cp x $up/\$F.settings.json" \
    "cd $CLAUDE_CONFIG_DIR && cp x *.local.json"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  run_hook guard-subagent-authority.sh "$(bash_payload "cp x $BATS_TEST_TMPDIR/s*.json" agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
}
@test "settings fix 2-3: a hard link whose name holds a comma is still found by device:inode" {
  mk_settings
  ln "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/a,b"
  sub_denied_with 'may NOT change Claude Code settings' "echo x > $BATS_TEST_TMPDIR/a,b"
}
@test "settings fix 2-4: ~user spellings are folded before matching" {
  mk_settings
  for c in 'echo x > ~root//.claude/settings.json' 'echo x > ~root/./.claude/settings.local.json' \
    'cp x ~root/x/../.claude/settings.json' 'cp x ~root/.claude//./settings.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
}
@test "settings fix 3-A: interpreter writes through a hard link or symlink of a settings file are denied" {
  mk_settings
  ln "$PROJ/.claude/settings.json" "$PROJ/src/hard.json"
  ln -s "$HOME/.claude/settings.local.json" "$PROJ/src/slink.json"
  for c in "python3 -c 'open(\"src/hard.json\",\"w\").write(\"x\")'" "python3 -c 'open(\"src/slink.json\",\"w\")'" \
    "node -e 'require(\"fs\").writeFileSync(\"src/hard.json\",\"x\")'"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  ln "$HOME/.claude/settings.json" "$BATS_TEST_TMPDIR/a,b"
  sub_denied_with 'may NOT change Claude Code settings' "echo x > $BATS_TEST_TMPDIR/a,b"
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo a,b > out.txt' agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
}
@test "settings fix 3-B: a cwd or cd target inside a settings directory triggers the glob rule; expansion words ending in settings.json deny" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  ln -s "$HOME/.claude" "$BATS_TEST_TMPDIR/uc"
  ln -s "$CLAUDE_CONFIG_DIR" "$BATS_TEST_TMPDIR/cc"
  ln -s "$PROJ/.claude" "$BATS_TEST_TMPDIR/pc"
  case "$BATS_TEST_TMPDIR" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  # payload cwd inside a settings directory
  for d in "$HOME/.claude" "$CLAUDE_CONFIG_DIR"; do
    lane_cmd "$d" 'cp x s*.json'
    [ "$(decision)" = "deny" ] || { echo "allowed from $d"; false; }
    reason | grep -qF 'may NOT change Claude Code settings'
  done
  # a cd target that resolves into one, named through a symlink
  for c in "cd $BATS_TEST_TMPDIR/uc && cp x setting?.json" "pushd $BATS_TEST_TMPDIR/cc; cp x *.local.json" \
    "cd $BATS_TEST_TMPDIR/uc/projects/.. && cp x [s]ettings.json"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  sub_denied_with 'NOT' "cd $BATS_TEST_TMPDIR/pc && cp x s*.json"
  # an expansion word whose literal last component is a settings name
  for c in 'cp x $OUT/settings.json' 'cp x ${D}/Settings.Local.JSON' 'dd of=$X/settings.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  # ordinary work
  for c in 'cp *.json dist/' 'cp $SRC/app.json dist/' 'echo x > .vscode/settings.json' 'echo x > src/settings.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  mkdir -p "$PROJ/.claude/worktrees/mk-r-a/.claude"
  for c in 'echo x > .claude/settings.json' 'cp *.json dist/' 'cp x $F.json'; do
    lane_cmd "$PROJ/.claude/worktrees/mk-r-a" "$c"
    [ "$(decision)" = "allow" ] || { echo "lane denied: $c: $(reason)"; false; }
  done
}
@test "settings fix 3-C: CLAUDE_CONFIG_DIR spellings with // or /./ are folded" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  case "$CLAUDE_CONFIG_DIR" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  for c in "cp x ${CLAUDE_CONFIG_DIR%/*}//${CLAUDE_CONFIG_DIR##*/}/s*.json" "cp x ${CLAUDE_CONFIG_DIR%/*}/./${CLAUDE_CONFIG_DIR##*/}/s*.json" \
    "cp x ${CLAUDE_CONFIG_DIR}//s*.json"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
}
@test "settings fix 3-D: computed .json names directly under a settings directory are denied" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  for c in 'cp x ~/.claude/$F.json' 'cp x $CLAUDE_CONFIG_DIR/$F.json' 'cp x .claude/$F.json' \
    'cp x ${HOME}/.claude/${N}' 'cp x ~/.claude/./$F.js?n'; do
    sub_denied_with 'NOT' "$c"
  done
  sub_denied_with 'may NOT change Claude Code settings' 'cp x ~/.claude/$F.json'
  for c in 'cp x src/$F.json' 'cp x ~/notes/$F.json' 'cp x $CLAUDE_CONFIG_DIR/sub/$F.json' 'cp x $CLAUDE_CONFIG_DIR/$F.md'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "settings fix 4-1: a computed .json name in a symlinked settings directory is denied" {
  mk_settings
  CLAUDE_CONFIG_DIR="$(mktemp -d "${MK_FIXTMP}/mkccd.XXXXXX")"
  export CLAUDE_CONFIG_DIR
  local x="$BATS_TEST_TMPDIR/x"
  mkdir -p "$x/realdir"
  ln -s "$HOME/.claude" "$x/link"
  ln -s "$CLAUDE_CONFIG_DIR" "$x/clink"
  ln -s "$PROJ/.claude" "$x/plink"
  ln -s "$x/link" "$x/link2"
  case "$x$CLAUDE_CONFIG_DIR" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  for c in "cp x $x/link/\$F.json" "cp x $x/link/s*.json" "cp x $x/clink/\$F.json" "cp x $x/clink/s*.json" \
    "cp x $x/link2/./\$F.js?n" "cd $x && cp x link/\$F.json" "cp x $x/realdir/../link/s*.json"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  lane_cmd "$x/link" 'cp x $F.json'
  [ "$(decision)" = "deny" ] || { echo "allowed from cwd $x/link"; false; }
  # the project's .claude through a link: a reference (the config gate's
  # message or the settings one)
  sub_denied_with 'NOT' "cp x $x/plink/\$F.json"
  for c in "cp x $x/realdir/\$F.json" 'cp *.json dist/' "cp x $x/realdir/s*.json" "cp x $x/nodir/\$F.json" \
    "cp x $x/link/sub/\$F.json" "cp x $x/link/\$F.md"; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "settings fix 5-1: .. after a symlinked directory is resolved physically, not folded" {
  mk_settings
  local x="$BATS_TEST_TMPDIR/x"
  mkdir -p "$x/realdir" "$HOME/.claude/projects/p1" "$PROJ/.claude/worktrees"
  ln -s "$HOME/.claude/projects" "$x/link"
  ln -s "$PROJ/.claude/worktrees" "$x/plink"
  case "$x" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  for c in "cp x $x/link/../\$F.json" "cp x $x/link/p1/../../s*.json" "cd $x && cp x link/../\$F.json" \
    "cd $x/realdir && cp x ../link/p1/../../\$F.js?n"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  lane_cmd "$x" 'cp x link/../$F.json'
  [ "$(decision)" = "deny" ] || { echo "allowed from cwd $x"; false; }
  # through a link into <root>/.claude: a reference
  for c in "cp x $x/plink/../\$F.json" "cd $x && cp x plink/../s*.json"; do
    sub_denied_with 'NOT' "$c"
  done
  for c in "cp x $x/realdir/../\$F.json" "cp x $x/link/p1/\$F.json" 'cp *.json dist/'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "settings fix 5-2: when the command may make a symlink, a .json word in a directory not on disk fails closed" {
  mk_settings
  local x="$BATS_TEST_TMPDIR/x"
  mkdir -p "$x"
  case "$x" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  # (~/.c* is a config-gate glob already)
  sub_denied_with 'NOT' "ln -s ~/.c* $x/l && cp x $x/l/\$F.json"
  for c in "ln -s \$D $x/l && cp x $x/l/\$F.json" "cd $x; /bin/ln -s \$D l; cp x l/s*.json" \
    "true || gln -sf \$D $x/l | cp x $x/l/\$F.json"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  # wrappers and other link makers
  for c in "env ln -s \$D $x/l && cp x $x/l/\$F.json" "echo \$D $x/l | xargs ln -s; cp x $x/l/s*.json" \
    "sudo ln -s \$D $x/l; cp x $x/l/\$F.json" "cp -s \$D $x/l && cp x $x/l/\$F.json" \
    "cp --symbolic-link \$D $x/l && cp x $x/l/\$F.json" \
    "python3 -c 'import os; os.symlink(\"/d\", \"$x/l\")' && cp x $x/l/\$F.json" \
    "node -e 'require(\"fs\").symlinkSync(\"/d\", \"$x/l\")'; cp x $x/l/\$F.json"; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  # mkdir, cp, mv and cd do not count; ln with an existing directory passes
  for c in 'mkdir -p out && cp x out/$F.json' "mv a $x/new && cp x $x/new/\$F.json" 'cp *.json dist/' \
    "ln -s a b && cp x $x/\$F.json" 'cp x login/$F.json' 'cp -r a b; ls -s; cp x out/$F.json' 'ls -ln; cp x out/$F.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
@test "settings final 1: a .. after a directory the command makes is checked folded too" {
  mk_settings
  mkdir -p "$HOME/.claude/projects"
  ln -s "$HOME/.claude" "$PROJ/link"
  ln -s "$HOME/.claude/projects" "$PROJ/plink"
  case "$PROJ$HOME" in *[Cc][Ll][Aa][Uu][Dd][Ee]*|*'~'*) skip "temp path names claude" ;; esac
  # the cwd is the project; nope is made by the command (not on disk yet)
  for c in 'mkdir nope && cp x nope/../link/$F.json' 'mkdir nope && cp x ./nope/../link/$F.json' \
    'mkdir nope && cd nope && cp x ../link/$F.json' 'mkdir nope && cp x nope/../link/settings.json' \
    'mkdir nope && echo x > nope/../link/settings.local.json' 'mkdir nope && cp x nope/../plink/../$F.json' \
    'mkdir nope && cd nope/.. && cp x link/$F.json' 'cd nope/../link && cp x $F.json'; do
    sub_denied_with 'may NOT change Claude Code settings' "$c"
  done
  for c in 'mkdir -p out && cp x out/$F.json' 'cp *.json dist/' 'mkdir -p ../out && cp x ../out/$F.json' \
    'mkdir nope && cp x nope/$F.json' 'cd ../sibling && cp x out/$F.json'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}

# --- 0.8.1 (spec 4): subagent hooks judge by the session-start snapshot ------
snap_bash() { # CMD SESSION [AGENT]
  jq -nc --arg c "$1" --arg s "$2" --arg a "${3:-}" --arg cwd "$PROJ" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s} + (if $a=="" then {} else {agent_id:$a} end)'
}
snap_write() { # PATH SESSION [AGENT]
  jq -nc --arg p "$1" --arg s "$2" --arg a "${3:-}" --arg cwd "$PROJ" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:"{}"},cwd:$cwd,session_id:$s} + (if $a=="" then {} else {agent_id:$a} end)'
}
snap_start() { # SESSION
  run_hook session-start.sh "$(jq -nc --arg cwd "$PROJ" --arg s "$1" '{cwd:$cwd,session_id:$s,source:"startup"}')"
  [ "$status" -eq 0 ]
}
snap_file() { "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_config_snapshot_file \"\$1\"" _ "{\"session_id\":\"$1\"}"; }

@test "snapshot: a subagent is judged by the session-start config after the live one was emptied" {
  mk_project "$SRCFG"
  snap_start s1
  # the live config loses its remote block and its careful pattern
  printf '%s' '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en","guardedDirs":["docs"]}' > "$PROJ/.claude/memokit.json"
  # subagent of s1: the snapshot (remote and pattern rules still apply)
  run_hook guard-subagent-authority.sh "$(snap_bash "ssh prod.example.com 'ls'" s1 agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed by the live config"; false; }
  reason | grep -q 'remote target'
  run_hook guard-destructive.sh "$(snap_bash 'flyctl deploy' s1 agent-1)"
  [ "$(decision)" = "deny" ] || { echo "guard-destructive allowed flyctl for the subagent"; false; }
  # the main session follows the live file
  run_hook guard-destructive.sh "$(snap_bash 'flyctl deploy' s1)"
  [ "$(decision)" = "allow" ] || { echo "main: $(reason)"; false; }
  # an empty agent_id is the main session
  run_hook guard-destructive.sh "$(snap_bash 'flyctl deploy' s1 '')"
  [ "$(decision)" = "allow" ]
}
@test "snapshot: no snapshot (another session) behaves exactly as the live config" {
  mk_project "$SRCFG"
  snap_start s1
  run_hook guard-subagent-authority.sh "$(snap_bash "ssh prod.example.com 'ls'" s9 agent-1)"
  [ "$(decision)" = "deny" ]
  printf '%s' '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  run_hook guard-subagent-authority.sh "$(snap_bash "ssh prod.example.com 'ls'" s9 agent-1)"
  [ "$(decision)" = "allow" ]
  run_hook guard-destructive.sh "$(snap_bash 'flyctl deploy' s9 agent-1)"
  [ "$(decision)" = "allow" ]
}
@test "snapshot: a deleted live config still denies subagents as config missing" {
  mk_project "$SRCFG"
  snap_start s1
  [ -f "$(snap_file s1)" ]
  rm "$PROJ/.claude/memokit.json"
  for h in guard-subagent-authority.sh guard-destructive.sh; do
    run_hook $h "$(snap_bash ls s1 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed by $h"; false; }
    reason | grep -q 'vanished'
  done
}
@test "snapshot: a subagent file-tool write to a snapshot is denied, by name, link or hard link" {
  mk_project "$SRCFG"
  snap_start s1
  f="$(snap_file s1)"
  [ -f "$f" ]
  run_hook guard-subagent-authority.sh "$(snap_write "$f" s1 agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed: $f"; false; }
  # another session's snapshot (not created yet) and a case variant
  g="$(snap_file s2)"
  for p in "$g" "$(dirname "$g")/MEMOKIT-1-Careful-Config-x"; do
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  ln -s "$f" "$PROJ/link.json"
  ln "$f" "$PROJ/hard.json"
  for p in "$PROJ/link.json" "$PROJ/hard.json" link.json; do
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  # an ordinary file next to it is not
  run_hook guard-subagent-authority.sh "$(snap_write "$PROJ/src/a.json" s1 agent-1)"
  [ "$(decision)" = "allow" ]
}
@test "state files: a subagent file-tool write to any memokit-<n>-careful-* state file is denied; the main session is not" {
  mk_project "$SRCFG"
  local d h p t
  d="${TMPDIR%/}"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  for p in "$d/memokit-$h-careful-integrity-perm-s1" "$d/memokit-$h-careful-integrity-s1-tu1" \
           "$d/memokit-$h-careful-armed-s1-agent-1" "$d/memokit-$h-careful-integrity-alert-s1" \
           "$d/memokit-0-careful-integrity-alert-s1" "$d/memokit-0-careful-integrity-notice-s1" \
           "$d/memokit-$h-careful-active-s1" "$d/memokit-1-careful-window-x" "$d/MEMOKIT-22-Careful-x"; do
    for t in Write Edit MultiEdit NotebookEdit; do
      run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$t" --arg p "$p" --arg cwd "$PROJ" \
        '{tool_name:$t,tool_input:{file_path:$p,notebook_path:$p,content:"x"},cwd:$cwd,session_id:"s1",agent_id:"agent-1"}')"
      [ "$(decision)" = "deny" ] || { echo "allowed: $t $p"; false; }
      reason | grep -qF 'state file' || { echo "reason: $(reason)"; false; }
    done
    # a link in the project pointing at it
    printf 'x' > "$p"; ln -sf "$p" "$PROJ/st-link"
    run_hook guard-subagent-authority.sh "$(snap_write "$PROJ/st-link" s1 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed via link: $p"; false; }
    rm -f "$p" "$PROJ/st-link"
    # the main session: this rule does not apply
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1)"
    [ "$(decision)" = "allow" ] || { echo "main denied: $p [$output]"; false; }
  done
  # names that only look alike
  for p in "$d/memokit-x-careful-a" "$d/memokit--careful-a" "$PROJ/src/memokit-12-notes.md" "$PROJ/src/careful-12.md"; do
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1 agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $p [$output]"; false; }
  done
}

@test "state files: a hard link in the project to a state file is denied; an ordinary multi-link file is not" {
  mk_project "$SRCFG"
  local d h s
  d="${TMPDIR%/}"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  s="$d/memokit-$h-careful-integrity-perm-s1"
  printf '{}\n' > "$s"
  ln "$s" "$PROJ/src/x"
  for t in Write Edit; do
    run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$t" --arg p "$PROJ/src/x" --arg cwd "$PROJ" \
      '{tool_name:$t,tool_input:{file_path:$p,content:"x"},cwd:$cwd,session_id:"s1",agent_id:"agent-1"}')"
    [ "$(decision)" = "deny" ] || { echo "allowed: $t"; false; }
    reason | grep -qF 'state file'
  done
  # a relative path to it too
  run_hook guard-subagent-authority.sh "$(snap_write src/x s1 agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed: relative"; false; }
  # an ordinary file with two links, one of them in the temp dir under another name
  printf 'a\n' > "$PROJ/src/y"; ln "$PROJ/src/y" "$PROJ/src/y2"; ln "$PROJ/src/y" "$d/notes-$h"
  run_hook guard-subagent-authority.sh "$(snap_write "$PROJ/src/y" s1 agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: [$output]"; false; }
}

@test "state files: decoy memokit-* hard links cannot crowd out or dodge the hard-link check" {
  mk_project "$SRCFG"
  local d h s i
  d="${TMPDIR%/}"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  # many decoys (names a digits-only filter would reject) plus one real state name
  s="$d/memokit-$h-careful-integrity-alert-s1"
  printf 'x\n' > "$PROJ/src/x"
  for i in $(seq 1 80); do ln "$PROJ/src/x" "$d/memokit-0a$i-careful-decoy"; done
  ln "$PROJ/src/x" "$s"
  run_hook guard-subagent-authority.sh "$(snap_write "$PROJ/src/x" s1 agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed with decoys"; false; }
  # decoys alone (no exact state name): any memokit-* name in the temp dir denies
  rm -f "$s"
  run_hook guard-subagent-authority.sh "$(snap_write "$PROJ/src/x" s1 agent-1)"
  [ "$(decision)" = "deny" ] || { echo "allowed with decoys only"; false; }
  reason | grep -qF 'state file'
}

# 0.8.1 release fix d: the markitdown cache (convert-read.sh) is in the
# careful family, memokit-<n>-careful-convert/<key>/<name>.md: a subagent can
# plant no Markdown there for the orchestrator's next Read of that document.
@test "conversion cache: a subagent file-tool write into memokit-<n>-careful-convert is denied; the main session is not" {
  mk_project "$SRCFG"
  local d h c k p t
  d="${TMPDIR%/}"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  c="$d/memokit-$h-careful-convert"
  k="$(printf '%064d' 0)-1234"
  mkdir -p "$c/$k"; printf 'real\n' > "$c/$k/doc.pdf.md"
  for p in "$c/$k/doc.pdf.md" "$c/$k/new.pdf.md" "$c/$(printf '%064d' 1)-9/doc.pdf.md" "$c/$k/.skip" \
           "$d/MEMOKIT-$h-Careful-Convert/$k/doc.pdf.md"; do
    for t in Write Edit MultiEdit NotebookEdit; do
      run_hook guard-subagent-authority.sh "$(jq -nc --arg t "$t" --arg p "$p" --arg cwd "$PROJ" \
        '{tool_name:$t,tool_input:{file_path:$p,notebook_path:$p,content:"x"},cwd:$cwd,session_id:"s1",agent_id:"agent-1"}')"
      [ "$(decision)" = "deny" ] || { echo "allowed: $t $p"; false; }
      reason | grep -qF 'state file' || { echo "reason: $(reason)"; false; }
    done
    # the main session: this rule does not apply
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1)"
    [ "$(decision)" = "allow" ] || { echo "main denied: $p [$output]"; false; }
  done
  # through a project link to the key dir, to the entry, or a hard link to it
  ln -s "$c/$k" "$PROJ/kd"; ln -s "$c/$k/doc.pdf.md" "$PROJ/md-link"; ln "$c/$k/doc.pdf.md" "$PROJ/src/hard.md"
  for p in "$PROJ/kd/doc.pdf.md" "$PROJ/kd/other.md" "$PROJ/md-link" "$PROJ/src/hard.md" src/hard.md; do
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $p"; false; }
  done
  [ "$(cat "$c/$k/doc.pdf.md")" = real ]
  # look-alikes outside the family
  for p in "$PROJ/src/memokit-12-convert/a.md" "$PROJ/src/careful-convert/a.md" "$d/memokit-x-careful-convert/a.md"; do
    run_hook guard-subagent-authority.sh "$(snap_write "$p" s1 agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $p [$output]"; false; }
  done
}

@test "conversion cache: a Bash write into it is careful-state (subagent and main); Read is guarded by no hook but convert-read" {
  mk_project "$SRCFG"
  local d h k a c
  d="${TMPDIR%/}"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  k="$(printf '%064d' 0)-1234"
  for a in agent-1 ''; do
    for c in "echo x > \"\$TMPDIR\"/memokit-$h-careful-convert/$k/doc.pdf.md" \
             "echo x > $d/memokit-$h-careful-convert/$k/doc.pdf.md" \
             "cp /tmp/forged.md $d/memokit-$h-careful-convert/$k/doc.pdf.md" \
             "mkdir -p $d/memokit-$h-careful-convert/$k && printf x > $d/memokit-$h-careful-convert/$k/doc.pdf.md" \
             "ln -s /tmp/forged $d/memokit-$h-careful-convert/$k"; do
      run_hook guard-destructive.sh "$(snap_bash "$c" s1 "$a")"
      [ "$(decision)" = "deny" ] || { echo "allowed (${a:-main}): $c"; false; }
      reason | grep -qF 'approval files are blocked' || { echo "${a:-main} $c: $(reason)"; false; }
    done
  done
  # Read reaches convert-read.sh and the integrity check only (no path rule):
  # the orchestrator's redirected Read of the cache is not blocked.
  [ "$(jq -r '[.hooks.PreToolUse[] | select((.matcher // "") | test("(^|\\|)Read(\\||$)")) | .hooks[].command] | join(" ")' "$MK_REPO/hooks/hooks.json")" = '"${CLAUDE_PLUGIN_ROOT}/hooks/convert-read.sh"' ]
}

@test "snapshot: a Bash write to the snapshot is careful-state for main and subagent" {
  mk_project "$SRCFG"
  snap_start s1
  f="$(snap_file s1)"
  for a in '' agent-1; do
    for c in "echo x > $f" "cp /tmp/x $f" "rm -f $f"; do
      run_hook guard-destructive.sh "$(snap_bash "$c" s1 "$a")"
      [ "$(decision)" = "deny" ] || { echo "allowed (${a:-main}): $c"; false; }
      reason | grep -qF 'approval files are blocked' || { echo "${a:-main} $c: $(reason)"; false; }
    done
  done
}

# --- Task 6 fix round 1 ------------------------------------------------------
# I1: an invalid UTF-8 byte in the payload under a UTF-8 locale must not
# hide agent_id from the snapshot pick.
@test "snapshot: an invalid UTF-8 byte under tr_TR.UTF-8 still picks the snapshot" {
  locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\{0,1\}8$' || skip "tr_TR.UTF-8 not installed"
  mk_project "$SRCFG"
  snap_start s1
  printf '%s' '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  export LANG=tr_TR.UTF-8 LC_ALL=tr_TR.UTF-8
  for hc in 'guard-subagent-authority.sh|ssh prod.example.com ls # X' 'guard-destructive.sh|flyctl deploy # X'; do
    h="${hc%%|*}"; c="${hc#*|}"
    pl="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s\377"},"cwd":"%s","session_id":"s1","agent_id":"a1"}' "$c" "$PROJ")"
    run_hook "$h" "$pl"
    [ "$(decision)" = "deny" ] || { echo "$h allowed: $c"; false; }
  done
}
# I2: a subagent may not re-run session-start.sh (it rewrites the snapshot);
# reading it is fine.
@test "subagent: running memokit's session-start.sh is denied, reading it is not" {
  mk_project "$SRCFG"
  for c in 'hooks/session-start.sh' './hooks/session-start.sh < /tmp/p.json' 'bash hooks/session-start.sh' \
    'sh /p/memokit/hooks/session-start.sh' "printf '{\"source\":\"startup\"}' | bash $PROJ/hooks/session-start.sh" \
    'bash "$CLAUDE_PLUGIN_ROOT/hooks/session-start.sh"' 'cd /p/memokit && bash hooks/session-start.sh' \
    '. hooks/session-start.sh' 'source hooks/session-start.sh' 'cat hooks/session-start.sh | bash' \
    'bash hooks/sess*-start.sh' 'bash hooks/session-st"art".sh' 'x=1 HOOKS/Session-Start.sh' \
    'cat hooks/session-start.sh
bash hooks/session-start.sh'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  for c in 'cat hooks/session-start.sh' 'grep -n snapshot hooks/session-start.sh' \
    'grep -n x hooks/session-start.sh | head -5' 'wc -l hooks/session-start.sh' 'head -40 hooks/session-start.sh' \
    'bash $ROOT/scripts/start.sh' 'sh ${APP}/start.sh --port 3000' './start.sh'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
# Final review (item 4): text only, no filesystem resolution (copies of
# the script live in old plugin caches and checkouts; cd, find and xargs make
# the base unknowable). The last component of a word decides: session-start.sh
# itself, or a glob/expansion that could match it ($..., ${...}, a backquote
# run and {...} as .*, * as .*, ? and [...] as one character). A component of
# wildcards only ($D, *) says nothing about the name.
@test "subagent: a last component that could name session-start.sh is denied, start.sh and plain wildcards are not" {
  mk_project "$SRCFG"
  for c in 'bash hooks/*start.sh' 'bash hooks/*tart.sh' 'bash hooks/s*-*.sh' 'bash hooks/s*' 'bash h*/s[e]ssion*' \
    'sh ./hooks/?ession-st*' 'bash ${D}start.sh' 'bash $X/session-start.sh' 'cd hooks && bash *start.sh' \
    "find . -name 'sess*' -exec bash {} \;" 'bash $P/hooks/*start.sh' 'bash ${D}/hooks/sess*' 'bash `x`/hooks/s*' \
    'bash /srv/old-copy/session-start.sh' 'bash x/sess{ion,}-start.sh' 'X=sess*; bash $X' \
    'bash hooks/$(echo session)-start.sh' 'bash hooks/`echo session`-start.sh' 'bash $(dirname x)/session-start.sh' \
    'bash hooks/$(printf %s $(echo sess))ion-start.sh' 'bash `echo hooks`/s?ss*' \
    'bash x/*t.sh' 'bash hooks/*-start.sh'; do
    sub_denied_with 'session-start hook' "$c"
  done
  for c in 'bash $ROOT/scripts/start.sh' 'bash $P/hooks/build.sh' '[ -x $F ] && ls *' 'cp x $OUT' \
    'for f in $SRC/*.cs; do echo $f; done' 'cp {} $D/' 'bash ${APP}/*.py' 'bash x/*start.shx' \
    'echo $(date) > out.txt' 'echo $((1 + 2)) $(ls (x))' 'bash $(dirname $0)/build.sh' 'bash scripts/start.sh' \
    'chmod +x scripts/*.sh' 'cp src/*.sh dist/' 'rm -f build/*.sh' 'tar czf out.tgz *.sh' \
    'for f in tests/*.sh; do bash -n $f; done' 'bash $DIR/$name.sh' 'bash scripts/${n}.sh'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
}
# M3: an unreadable snapshot names itself, not .claude/memokit.json.
@test "snapshot: an invalid snapshot denies with its own message" {
  mk_project "$SRCFG"
  snap_start s1
  printf '{broken' > "$(snap_file s1)"
  for h in guard-subagent-authority.sh guard-destructive.sh guard-edit.sh; do
    run_hook $h "$(snap_bash ls s1 agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed by $h"; false; }
    reason | grep -qF '/clear' || { echo "$h: $(reason)"; false; }
    lacks "$(reason)" '.claude/memokit.json is invalid'
  done
  # the main session reads the valid live file
  run_hook guard-destructive.sh "$(snap_bash ls s1)"
  [ "$(decision)" = "allow" ]
}
# M5: a main-session file-tool write to the snapshot is careful-state.
@test "snapshot: a main-session Write or Edit to the snapshot is denied" {
  mk_project "$SRCFG"
  snap_start s1
  f="$(snap_file s1)"
  for t in Write Edit; do
    run_hook guard-destructive.sh "$(jq -nc --arg t "$t" --arg p "$f" --arg cwd "$PROJ" '{tool_name:$t,tool_input:{file_path:$p},cwd:$cwd,session_id:"s1"}')"
    [ "$(decision)" = "deny" ] || { echo "allowed: $t"; false; }
    reason | grep -qF 'approval files are blocked'
  done
}
# Fix round 2: the rule names the script with its extension; tests, lint and
# other files named session-start pass, sed and git on it stay denied.
@test "subagent: session-start rule is narrow: bats, shellcheck pass; sed and git on the script deny" {
  mk_project "$SRCFG"
  for c in 'bats tests/session-start.bats' 'bats tests/session-start.bats tests/guard-subagent.bats' \
    'shellcheck hooks/session-start.sh' 'shellcheck -x hooks/*.sh hooks/lib/*.sh' 'echo session-start done' \
    'ls docs/session-start'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  for c in 'sed -n 1,50p hooks/session-start.sh' 'git diff hooks/session-start.sh' 'git add hooks/session-start.sh' \
    'shellcheck hooks/session-start.sh; bash hooks/session-start.sh'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
}

# --- 0.8.1 (spec 7): installed plugin files. ---------------------------------
# The hook runs from a copy in a temp plugin root (its MK_HOOKS_DIR/..);
# CLAUDE_PLUGIN_ROOT is a second temp root and HOME a temp dir holding
# .claude/plugins. No path but the ~/.claude/plugins ones contains "claude".
mk_plugins() {
  mk_project "$SRCFG"
  HOME="$BATS_TEST_TMPDIR/home"
  export HOME
  mkdir -p "$HOME/.claude/plugins/cache/other/p/1.0" "$HOME/.claude/plugins/cache/memokit/memokit/0.8.1/hooks"
  printf 'x\n' > "$HOME/.claude/plugins/cache/other/p/1.0/x.sh"
  printf 'x\n' > "$HOME/.claude/plugins/cache/memokit/memokit/0.8.1/hooks/guard-edit.sh"
  PLUG="$BATS_TEST_TMPDIR/plug"
  mkdir -p "$PLUG/skills/x" "$PROJ/src/plugins"
  cp -R "$MK_REPO/hooks" "$PLUG/hooks"
  printf 'x\n' > "$PLUG/skills/x/SKILL.md"
  HOOKS="$PLUG/hooks"
  CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/cpr"
  export CLAUDE_PLUGIN_ROOT
  mkdir -p "$CLAUDE_PLUGIN_ROOT/agents" "$CLAUDE_PLUGIN_ROOT/hooks"
  printf 'x\n' > "$CLAUDE_PLUGIN_ROOT/agents/coder.md"
  # PLUG spelled relative to the project's src/, climbing to /
  local d="$PROJ" up=""
  while [ "$d" != / ]; do up="$up../"; d="$(dirname "$d")"; done
  PLUG_REL="src/../$up${PLUG#/}"
}
plugin_denied() { # TOOL PATH
  tool_write "$1" "$2"
  [ "$(decision)" = "deny" ] || { echo "allowed: $1 $2"; return 1; }
  reason | grep -qF "another plugin's installed files" || { echo "wrong reason for $1 $2: $(reason)"; return 1; }
}
@test "plugins: Write and Edit to installed plugin files are denied, also through links and .. folding" {
  mk_plugins
  ln -s "$PLUG/hooks/guard-edit.sh" "$PROJ/src/slink.sh"
  ln -s "$HOME/.claude/plugins/cache/other/p/1.0/x.sh" "$PROJ/src/slink2.sh"
  ln "$PLUG/hooks/guard-edit.sh" "$PROJ/src/hard.sh"
  ln "$HOME/.claude/plugins/cache/other/p/1.0/x.sh" "$PROJ/src/hard2.sh"
  ln "$CLAUDE_PLUGIN_ROOT/agents/coder.md" "$PROJ/src/hard3.md"
  ln -s "$PLUG/hooks" "$PROJ/src/ldir"
  for t in Write Edit; do
    for p in "$PLUG/hooks/guard-edit.sh" "$PLUG/hooks/../skills/x/SKILL.md" "$PLUG/hooks/lib/common.sh" \
      "$PLUG/hooks/new.sh" "$PLUG/newdir/sub/x.md" "$PLUG/HOOKS/guard-edit.sh" \
      "$CLAUDE_PLUGIN_ROOT/agents/coder.md" "$HOME/.claude/plugins/cache/other/p/1.0/x.sh" \
      '~/.claude/plugins/cache/other/p/1.0/x.sh' "$HOME/.claude/plugins/cache/memokit/memokit/0.8.1/hooks/guard-edit.sh" \
      "$HOME/.claude/plugins/newdir/x.sh" \
      "$PROJ/src/slink.sh" "$PROJ/src/slink2.sh" "$PROJ/src/hard.sh" "$PROJ/src/hard2.sh" "$PROJ/src/hard3.md" \
      "$PROJ/src/ldir/guard-edit.sh" "$PROJ/src/ldir/new.sh" "src/ldir/x/y.sh" \
      "$PLUG_REL/hooks/guard-edit.sh" "$PROJ/$PLUG_REL/skills/x/SKILL.md"; do
      plugin_denied "$t" "$p"
    done
  done
  # the physical spelling of the temp dir (macOS: /var is /private/var)
  p="$(cd -P "$PLUG" && pwd -P)/hooks/guard-edit.sh"
  plugin_denied Write "$p"
}
@test "plugins: Bash writes to installed plugin files are denied" {
  mk_plugins
  ln -s "$PLUG/hooks" "$PROJ/src/ldir"
  for c in 'echo x > ~/.claude/plugins/cache/memokit/memokit/0.8.1/hooks/guard-edit.sh' \
    'cp x "$CLAUDE_PLUGIN_ROOT/hooks/a.sh"'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  for c in "sed -i s/a/b/ $PLUG/hooks/lib/common.sh" "cp x \"$CLAUDE_PLUGIN_ROOT/hooks/a.sh\"" \
    "echo x >> $PLUG/skills/x/SKILL.md" "cd $PLUG/hooks && echo x > lib/common.sh" \
    'echo x > src/ldir/a.sh' "tee $PLUG_REL/hooks/a.sh < /dev/null" "rm -rf $PLUG/hooks" \
    'mkdir -p src/ldir/a/b && echo x > src/ldir/a/b/c' "python3 -c \"open('$PLUG/hooks/x.sh','w')\"" \
    "cp x $PLUG/hooks/" "cp x $CLAUDE_PLUGIN_ROOT/AGENTS/coder.md" "ln -s x $PLUG/hooks/y.sh" \
    "echo x > $(cd -P "$PLUG" && pwd -P)/hooks/guard-edit.sh"; do
    sub_denied_with "another plugin's installed files" "$c"
  done
}
@test "plugins: reads of plugin files and ordinary project writes stay allowed" {
  mk_plugins
  for c in "cat $PLUG/hooks/guard-edit.sh" "grep -n mk_ $PLUG/hooks/lib/common.sh" \
    "cat $CLAUDE_PLUGIN_ROOT/agents/coder.md | head -3" "ls $PLUG/hooks" \
    'echo x > ~/.claude/notes.md' 'echo x > src/plugins/x.ts' 'mkdir -p src/plugins/a && cp x src/plugins/a/y.ts' \
    "echo x > $PROJ/src/plugins/y.ts" "cp x $PLUG-old/a.sh" 'echo x > src/a.cs'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  for p in "$HOME/.claude/notes.md" "$PROJ/src/plugins/x.ts" 'src/plugins/x.ts' "$PLUG-old/a.sh" \
    "$HOME/.claude/plugins-notes.md" "$PROJ/src/a.cs"; do
    for t in Write Edit; do
      tool_write "$t" "$p"
      [ "$(decision)" = "allow" ] || { echo "denied: $t $p: $(reason)"; false; }
    done
  done
  run_hook guard-subagent-authority.sh "$(jq -nc --arg p "$PLUG/hooks/guard-edit.sh" --arg cwd "$PROJ" \
    '{tool_name:"Read",tool_input:{file_path:$p},cwd:$cwd,agent_id:"a1"}')"
  [ "$(decision)" = "allow" ]
}
@test "plugins: the main session is not denied by this hook" {
  mk_plugins
  for p in "$PLUG/hooks/guard-edit.sh" "$HOME/.claude/plugins/cache/other/p/1.0/x.sh"; do
    tool_write Write "$p" ""
    [ "$(decision)" = "allow" ]
  done
  run_hook guard-subagent-authority.sh "$(bash_payload "sed -i s/a/b/ $PLUG/hooks/lib/common.sh")"
  [ "$(decision)" = "allow" ]
}
# Fix round 1 (I1): the project tree is never a plugin-root hit. memokit run
# with --plugin-dir <project>: the plugin root IS the project.
@test "plugins fix 1: with the project as its own plugin root, project work passes" {
  mk_plugins
  cp -R "$MK_REPO/hooks" "$PROJ/hooks"
  HOOKS="$PROJ/hooks"
  CLAUDE_PLUGIN_ROOT="$PROJ"
  export CLAUDE_PLUGIN_ROOT
  for c in 'echo hi' 'git status' 'bats tests/' 'echo x > src/a.cs' 'sed -i s/a/b/ hooks/lib/common.sh' \
    "cp x $PROJ/hooks/x.sh" 'mkdir -p tests/new && echo x > tests/new/x.bats'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  printf 'x\n' > "$PROJ/hooks/lnk.sh"
  ln "$PROJ/hooks/lnk.sh" "$PROJ/src/lnk2.sh"
  for p in 'tests/x.bats' 'hooks/x.sh' "$PROJ/hooks/lib/common.sh" "$PROJ/src/lnk2.sh" \
    "$(cd -P "$PROJ" && pwd -P)/hooks/x.sh"; do
    for t in Write Edit; do
      tool_write "$t" "$p"
      [ "$(decision)" = "allow" ] || { echo "denied: $t $p: $(reason)"; false; }
    done
  done
  # roots outside the project stay protected
  plugin_denied Write "$HOME/.claude/plugins/cache/other/p/1.0/x.sh"
}
@test "plugins fix 1: a worktree inside the plugin checkout is writable, the checkout outside it is not" {
  mk_plugins
  CK="$BATS_TEST_TMPDIR/ck"
  mkdir -p "$CK"
  cp -R "$MK_REPO/hooks" "$CK/hooks"
  HOOKS="$CK/hooks"
  unset CLAUDE_PLUGIN_ROOT
  PROJ="$CK/.claude/worktrees/x"
  mkdir -p "$PROJ/src" "$PROJ/.claude"
  printf '%s' "$SRCFG" > "$PROJ/.claude/memokit.json"
  git -C "$PROJ" init -q
  CLAUDE_PROJECT_DIR="$PROJ"
  export PROJ CLAUDE_PROJECT_DIR
  for c in 'echo x > src/a.cs' 'echo hi' "cp x $PROJ/src/b.cs"; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  for p in "$PROJ/src/a.cs" 'src/new/b.cs'; do
    tool_write Write "$p"
    [ "$(decision)" = "allow" ] || { echo "denied: $p: $(reason)"; false; }
  done
  plugin_denied Write "$CK/hooks/a.sh"
  # (a .claude path climbing with .. is a config edit first, 0.8.0)
  tool_write Edit "$PROJ/../../../hooks/guard-edit.sh"
  [ "$(decision)" = "deny" ]
  sub_denied_with "another plugin's installed files" "echo x > $CK/hooks/a.sh"
  sub_denied_with "another plugin's installed files" 'echo x > ../../../hooks/a.sh'
}
# Fix round 1 addendum: a root strictly inside the project tree stays
# protected (the project root is $HOME; a project-local config dir).
@test "plugins fix 1: a plugin root inside the project tree is not exempt" {
  mk_plugins
  HOME="$PROJ"
  export HOME
  mkdir -p "$HOME/.claude/plugins/cache/x/1.0"
  printf 'x\n' > "$HOME/.claude/plugins/cache/x/1.0/a.sh"
  ln -s "$HOME/.claude/plugins/cache/x/1.0" "$PROJ/src/lx"
  ln "$HOME/.claude/plugins/cache/x/1.0/a.sh" "$PROJ/src/ha.sh"
  for p in "$HOME/.claude/plugins/cache/x/1.0/a.sh" "$HOME/.claude/plugins/cache/x/1.0/new.sh" \
    "$PROJ/src/lx/a.sh" "$PROJ/src/ha.sh"; do
    plugin_denied Write "$p"
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo x > ~/.claude/plugins/cache/x/1.0/a.sh' agent-1)"
  [ "$(decision)" = "deny" ]
  CLAUDE_CONFIG_DIR="$PROJ/cfg"
  export CLAUDE_CONFIG_DIR
  mkdir -p "$PROJ/cfg/plugins/o"
  printf 'x\n' > "$PROJ/cfg/plugins/o/x.sh"
  plugin_denied Write "$PROJ/cfg/plugins/o/x.sh"
  for c in 'echo x > cfg/plugins/o/x.sh' "cp x $PROJ/cfg/plugins/o/y.sh"; do
    sub_denied_with "another plugin's installed files" "$c"
  done
  # the rest of the project stays writable
  for c in 'echo x > src/a.cs' 'echo x > cfg/notes.md'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "allow" ] || { echo "denied: $c: $(reason)"; false; }
  done
  tool_write Write "$PROJ/src/a.cs"
  [ "$(decision)" = "allow" ]
}
# Fix round 1 (S31): CLAUDE_PLUGIN_ROOT spellings in a writing command. The
# 0.8.0 install-location rule (change-window message) runs first and already
# denies any CLAUDE_PLUGIN_ROOT text; the plugin gate maps the spellings too.
@test "plugins fix 1: CLAUDE_PLUGIN_ROOT spellings in a writing command are denied" {
  mk_plugins
  for c in 'echo x > "$CLAUDE_PLUGIN_ROOT"/hooks/a.sh' 'cp x ${CLAUDE_PLUGIN_ROOT}/$F' 'cp x $CLAUDE_PLUGIN_ROOT'; do
    run_hook guard-subagent-authority.sh "$(bash_payload "$c" agent-1)"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
  done
  unset CLAUDE_PLUGIN_ROOT
  run_hook guard-subagent-authority.sh "$(bash_payload 'cp x ${CLAUDE_PLUGIN_ROOT}/$F' agent-1)"
  [ "$(decision)" = "deny" ]
}
# Fix round 1 (minor 4): $CLAUDE_CONFIG_DIR/plugins when it is set.
@test "plugins fix 1: CLAUDE_CONFIG_DIR/plugins is a plugin root when set" {
  mk_plugins
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/ccd"
  export CLAUDE_CONFIG_DIR
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins/o/p"
  printf 'x\n' > "$CLAUDE_CONFIG_DIR/plugins/o/p/x.sh"
  plugin_denied Write "$CLAUDE_CONFIG_DIR/plugins/o/p/x.sh"
  sub_denied_with "another plugin's installed files" "echo x > $CLAUDE_CONFIG_DIR/plugins/o/p/x.sh"
  run_hook guard-subagent-authority.sh "$(bash_payload "echo x > $CLAUDE_CONFIG_DIR/notes.md" agent-1)"
  [ "$(decision)" = "allow" ]
}
# Fix round 2: the exemption is for the harness project only, judged by the
# physical target and by exact spelling.
mk_dogfood() {
  mk_plugins
  cp -R "$MK_REPO/hooks" "$PROJ/hooks"
  HOOKS="$PROJ/hooks"
  CLAUDE_PLUGIN_ROOT="$PROJ"
  export CLAUDE_PLUGIN_ROOT
}
@test "plugins fix 2: a glob or expansion word under a root is never exempt" {
  mk_dogfood
  for c in 'echo x > hook?/a.sh' 'cp x $D/a.sh' 'echo x > src/*.cs' 'cp x `echo hooks`/a.sh'; do
    sub_denied_with "another plugin's installed files" "$c"
  done
  # literal words keep the exemption
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo x > hooks/a.sh' agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
}
@test "plugins fix 2: a file symlink in the project is judged by its target" {
  mk_dogfood
  ln -s "$HOME/.claude/plugins/cache/other/p/1.0/x.sh" "$PROJ/src/fl.sh"
  ln -s fl.sh "$PROJ/src/fl2.sh"
  printf 'x\n' > "$PROJ/src/real.sh"
  ln -s real.sh "$PROJ/src/fl3.sh"
  for c in 'echo x > src/fl.sh' 'cp x src/fl2.sh' "echo x > $PROJ/src/fl.sh"; do
    sub_denied_with "another plugin's installed files" "$c"
  done
  plugin_denied Write "$PROJ/src/fl.sh"
  plugin_denied Edit "$PROJ/src/fl2.sh"
  # a link to a project file stays a project write
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo x > src/fl3.sh' agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
  tool_write Write "$PROJ/src/fl3.sh"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
}
@test "plugins fix 2: no exemption without CLAUDE_PROJECT_DIR or inside an installed plugin" {
  mk_dogfood
  unset CLAUDE_PROJECT_DIR
  plugin_denied Write "$PROJ/tests/x.bats"
  sub_denied_with "another plugin's installed files" 'echo x > src/a.cs'
  # a marketplace clone as cwd, CLAUDE_PROJECT_DIR unset, hooks from the clone
  M="$HOME/.claude/plugins/marketplaces/m"
  mkdir -p "$M/.claude" "$M/src"
  printf '%s' "$SRCFG" > "$M/.claude/memokit.json"
  git -C "$M" init -q
  cp -R "$MK_REPO/hooks" "$M/hooks"
  HOOKS="$M/hooks"
  CLAUDE_PLUGIN_ROOT="$M"
  PROJ="$M"
  plugin_denied Write "$M/src/a.cs"
  # an installed cache dir named as the project
  C="$HOME/.claude/plugins/cache/x/m/1.0"
  mkdir -p "$C/.claude" "$C/src"
  printf '%s' "$SRCFG" > "$C/.claude/memokit.json"
  cp -R "$MK_REPO/hooks" "$C/hooks"
  HOOKS="$C/hooks"
  CLAUDE_PLUGIN_ROOT="$C"
  CLAUDE_PROJECT_DIR="$C"
  PROJ="$C"
  export CLAUDE_PROJECT_DIR
  plugin_denied Write "$C/src/a.cs"
  sub_denied_with "another plugin's installed files" 'echo x > src/a.cs'
}
@test "plugins fix 2: a case-variant spelling of the project does not widen the exemption" {
  mk_dogfood
  up="$(printf '%s' "$PROJ" | tr '[:lower:]' '[:upper:]')"
  plugin_denied Write "$up/hooks/x.sh"
  sub_denied_with "another plugin's installed files" "echo x > $up/hooks/x.sh"
  # the project's own spelling stays exempt
  tool_write Write "$PROJ/hooks/x.sh"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
}
@test "plugins fix 2: a project reached through a symlinked CLAUDE_PROJECT_DIR inside a plugin checkout" {
  mk_plugins
  CK="$BATS_TEST_TMPDIR/ck"
  mkdir -p "$CK"
  cp -R "$MK_REPO/hooks" "$CK/hooks"
  HOOKS="$CK/hooks"
  unset CLAUDE_PLUGIN_ROOT
  WT="$CK/.claude/worktrees/x"
  mkdir -p "$WT/src" "$WT/.claude"
  printf '%s' "$SRCFG" > "$WT/.claude/memokit.json"
  git -C "$WT" init -q
  ln -s "$WT" "$BATS_TEST_TMPDIR/lp"
  PROJ="$BATS_TEST_TMPDIR/lp"
  CLAUDE_PROJECT_DIR="$PROJ"
  export PROJ CLAUDE_PROJECT_DIR
  for p in "$PROJ/src/a.cs" 'src/b.cs' "$(cd -P "$WT" && pwd -P)/src/c.cs"; do
    tool_write Write "$p"
    [ "$(decision)" = "allow" ] || { echo "denied: $p: $(reason)"; false; }
  done
  run_hook guard-subagent-authority.sh "$(bash_payload 'echo x > src/a.cs' agent-1)"
  [ "$(decision)" = "allow" ] || { echo "denied: $(reason)"; false; }
  plugin_denied Write "$CK/hooks/a.sh"
  sub_denied_with "another plugin's installed files" "echo x > $CK/hooks/a.sh"
}
