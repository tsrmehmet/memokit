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
