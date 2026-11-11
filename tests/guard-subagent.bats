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
