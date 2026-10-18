#!/usr/bin/env bats
load helpers

cfg() { printf '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",%s}' "$1"; }
load_cfg() {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_load_config; printf '%s|%s' \"\$MK_CONFIG_ERR\" \"\$MK_CAREFUL_PATTERNS_JSON\""
}

@test "careful config: patterns load; absent field defaults to []" {
  mk_project "$(cfg '"careful":{"patterns":[{"match":"kubectl apply","label":"kubectl-mutate"}]}')"
  load_cfg
  [ "${output%%|*}" = "" ]
  [ "$(printf '%s' "${output#*|}" | jq -r '.[0].label')" = "kubectl-mutate" ]
  mk_project
  load_cfg
  [ "$output" = "|[]" ]
}

@test "careful config: bad shapes are rejected with field careful" {
  for c in '"careful":[]' '"careful":{"patterns":{}}' '"careful":{"patterns":[{"match":"x"}]}' \
           '"careful":{"patterns":[{"match":"","label":"a"}]}' '"careful":{"patterns":[{"match":"x","label":"Bad Label"}]}' \
           '"careful":{"patterns":[{"match":1,"label":"a"}]}' '"careful":{"patterns":["x"]}'; do
    mk_project "$(cfg "$c")"
    load_cfg
    [ "${output%%|*}" = "careful" ] || { echo "$c -> $output"; false; }
  done
}

labels() {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels \"\$1\"" _ "$1"
}

@test "builtin patterns catch destructive commands" {
  mk_project
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'EOF'
git-force-push|git push --force origin main
git-force-push|git push -f
git-force-push|git push origin +main
git-force-push|cd repo && git -C sub push --force
git-reset-hard|git reset --hard HEAD~1
git-clean|git clean -fd
git-branch-delete|git branch -D old
git-discard-all|git checkout -- .
git-discard-all|git restore .
rm-recursive|rm -rf src
rm-recursive|rm -fr ./data
rm-recursive|rm --recursive docs
rm-recursive|rm -rf node_modules src
rm-recursive|rm -rf /
sql-destructive|psql -h db -c "DROP TABLE users"
sql-destructive|mysql -e 'delete from orders'
sql-destructive|sqlite3 app.db "truncate t"
ef-database-drop|dotnet ef database drop --force
kubectl-delete|kubectl -n prod delete pod api-1
kubectl-delete|ssh root@h 'kubectl delete ns x'
helm-uninstall|helm uninstall api -n prod
helm-uninstall|helm delete api
docker-prune|docker system prune -af
docker-prune|docker volume rm data
careful-state|cat /tmp/memokit-123-careful-grants
EOF
}

@test "builtin patterns leave safe commands alone" {
  mk_project
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    labels "$cmd"
    [ -z "$output" ] || { echo "false positive: $cmd -> [$output]"; false; }
  done <<'EOF'
git push --force-with-lease
git push origin main
git push -u origin feat/x
git reset --soft HEAD~1
git clean -n
git branch -d merged
git checkout -- src/a.cs
rm -rf node_modules
rm -rf bin obj
rm -rf ./web/dist/
rm -rf node_modules 2>/dev/null
rm file.txt
rm -f a.log
grep -rn "DROP TABLE" src
dotnet ef migrations add Init
kubectl get pods
helm list
docker ps
docker rm abc
EOF
}

@test "SQL in a heredoc body is caught" {
  mk_project
  labels "$(printf 'psql -h db <<SQL\nDROP TABLE users;\nSQL')"
  printf '%s\n' "$output" | grep -qx 'sql-destructive'
}

@test "labels are de-duplicated" {
  mk_project
  labels 'git push -f && git push --force'
  [ "$output" = "git-force-push" ]
}

@test "project patterns: case-insensitive, invalid regex only disables itself" {
  mk_project "$(cfg '"careful":{"patterns":[{"match":"(","label":"broken"},{"match":"kubectl[[:space:]]+apply","label":"kubectl-mutate"}]}')"
  labels 'KUBECTL APPLY -f x.yaml'
  [ "$output" = "kubectl-mutate" ]
  labels 'ls -la'
  [ -z "$output" ]
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_bad_patterns"
  [ "$output" = "broken" ]
}

@test "fix round 1: extra destructive forms are caught" {
  mk_project
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'XEOF'
git-discard-all|git restore --staged --worktree .
rm-recursive|rm -rf src/rm tmp
rm-recursive|rm -rf src & rm -rf node_modules
rm-recursive|/bin/rm -rf src
docker-prune|docker --context prod system prune -f
sql-destructive|/usr/local/bin/psql -c "drop table x"
careful-state|cat $TMPDIR/memokit-*-careful-grants
git-branch-delete|git branch -d -f old
git-branch-delete|git branch --delete --force old
rm-recursive|echo $(rm -rf src)
rm-recursive|echo `rm -rf src`
rm-recursive|\rm -rf src
rm-recursive|{ rm -rf src; }
rm-recursive|echo "$(rm -rf src)"
XEOF
}

@test "fix round 1: extra safe forms are left alone" {
  mk_project
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    labels "$cmd"
    [ -z "$output" ] || { echo "false positive: $cmd -> [$output]"; false; }
  done <<'XEOF'
git rm -r --cached .
git restore --staged .
rm -rf node_modules 2> /dev/null
rm -rf node_modules &> /dev/null
grep -rn "DROP TABLE" src/mysql/
git branch -d merged
XEOF
}

@test "long heredoc of ordinary code is fast and unlabelled" {
  mk_project
  body="cat > f.py <<EOF"
  i=0
  while [ "$i" -lt 400 ]; do body="$body
    x = format(y)  # perform step $i"; i=$((i + 1)); done
  body="$body
EOF"
  start=$SECONDS
  labels "$body"
  [ -z "$output" ] || { echo "labels: $output"; false; }
  echo "elapsed $((SECONDS - start))s" >&3
  [ $((SECONDS - start)) -lt 2 ]
}

@test "fix round 2: boundary, sql, quoted redirection, fallback, branch clusters" {
  mk_project
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'XEOF'
rm-recursive|true&rm -rf src
rm-recursive|sleep 1 &rm -rf src
rm-recursive|echo x 2>&1&rm -rf src
git-force-push|true&git push --force
git-reset-hard|make&git reset --hard
kubectl-delete|true&kubectl delete ns prod
helm-uninstall|true&helm uninstall api
docker-prune|true&docker system prune -af
ef-database-drop|true&dotnet ef database drop -f
sql-destructive|./psql -c "drop table x"
sql-destructive|mysql<<<'drop table x'
sql-destructive|echo "DROP TABLE users" | psql;
sql-destructive|x=$(echo "DROP TABLE users" | psql)
rm-recursive|rm -rf node_modules ">" src
rm-recursive|rm -rf node_modules '2>' src
rm-recursive|x=$(rm -rf src)
rm-recursive|x=`rm -rf src`
git-branch-delete|git branch -df old
git-branch-delete|git branch -fd old
XEOF
  labels "$(printf 'psql<<SQL\nDROP TABLE users;\nSQL')"
  printf '%s\n' "$output" | grep -qx 'sql-destructive'
}

@test "long heredoc where every line mentions tools is fast and unlabelled" {
  mk_project
  body="cat > notes.txt <<EOF"
  i=0
  while [ "$i" -lt 400 ]; do body="$body
# run git status then rm stale files and helm list $i"; i=$((i + 1)); done
  body="$body
EOF"
  start=$SECONDS
  labels "$body"
  [ -z "$output" ] || { echo "labels: $output"; false; }
  echo "elapsed $((SECONDS - start))s" >&3
  [ $((SECONDS - start)) -lt 2 ]
}

lib() { "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; $1" _ "${2:-}"; }
grants() { lib 'mk_careful_grants_file'; }

@test "code: 6 hex, deterministic, bound to the command and the project root" {
  mk_project
  a="$(lib 'mk_careful_code "$1"' 'git push -f')"; b="$(lib 'mk_careful_code "$1"' 'git push -f')"
  c="$(lib 'mk_careful_code "$1"' 'git push -f ')"
  printf '%s' "$a" | grep -Eqx '[0-9a-f]{6}'
  [ "$a" = "$b" ]; [ "$a" != "$c" ]
  mk_project
  d="$(lib 'mk_careful_code "$1"' 'git push -f')"
  [ "$a" != "$d" ]
}

@test "grant is single use and expired lines are dropped" {
  mk_project
  lib 'mk_careful_grant abc123'
  lib 'mk_careful_consume abc123'
  run lib 'mk_careful_consume abc123'; [ "$status" -ne 0 ]
  printf 'def456 1\n' >> "$(grants)"
  run lib 'mk_careful_consume def456'; [ "$status" -ne 0 ]
  lacks "$(cat "$(grants)")" 'def456'
}

@test "approval at the start of the message records a grant" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'ONAY ABC123 lütfen devam')"
  ctx | grep -q 'abc123'
  grep -q '^abc123 ' "$(grants)"
  run_hook inject-rules.sh "$(prompt_payload "$(printf 'approve 0a1b2c\nand then continue')")"
  grep -q '^0a1b2c ' "$(grants)"
}

@test "approval quoted mid-message, on a later line, or with 7 hex does not count" {
  mk_project
  for p in 'rapor: kullanıcı onay abc123 yazmalı' "$(printf 'hello\nonay abc123')" 'onay abc1234' 'onaylandı abc123'; do
    run_hook inject-rules.sh "$(prompt_payload "$p")"
    [ "$status" -eq 0 ]
    [ -n "$(ctx)" ]
    lacks "$(ctx)" 'CAREFUL'
  done
  [ ! -s "$(grants)" ]
}

@test "grants file: a symlink is never followed, a fresh file is mode 600" {
  mk_project
  f="$(grants)"
  printf 'keep\n' > "$BATS_TEST_TMPDIR/target"
  rm -f "$f"; ln -s "$BATS_TEST_TMPDIR/target" "$f"
  run lib 'mk_careful_grant abc123'; [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = "keep" ]
  run lib 'mk_careful_consume abc123'; [ "$status" -ne 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = "keep" ]
  rm -f "$f"
  lib 'mk_careful_grant abc123'
  [ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]
  lib 'mk_careful_grant def456'
  lib 'mk_careful_consume abc123'
  [ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]
}

code_of() { reason | grep -oE "'(onay|approve) [0-9a-f]{6}'" | grep -oE '[0-9a-f]{6}'; }

@test "guard: silent without config, for non-Bash tools and for safe commands" {
  mk_project none
  run_hook guard-destructive.sh "$(bash_payload 'git push -f')"; [ "$status" -eq 0 ]; [ -z "$output" ]
  mk_project
  run_hook guard-destructive.sh "$(write_payload "$PROJ/docs/x.md")"; [ -z "$output" ]
  run_hook guard-destructive.sh "$(bash_payload 'git status')"; [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "guard: deny with label and code; approval lets the exact command through once" {
  mk_project
  run_hook guard-destructive.sh "$(bash_payload 'git push --force origin main')"
  [ "$(decision)" = "deny" ]; reason | grep -q '^\[DMO-CAREFUL\] git-force-push'
  code="$(code_of)"; [ -n "$code" ]
  run_hook inject-rules.sh "$(prompt_payload "onay $code")"
  run_hook guard-destructive.sh "$(bash_payload 'git push --force origin main')"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run_hook guard-destructive.sh "$(bash_payload 'git push --force origin main')"
  [ "$(decision)" = "deny" ]
}

@test "guard: a grant for one command does not open another; two grants coexist" {
  mk_project
  run_hook guard-destructive.sh "$(bash_payload 'git reset --hard')"; c1="$(code_of)"
  run_hook guard-destructive.sh "$(bash_payload 'git clean -fd')"; c2="$(code_of)"
  run_hook inject-rules.sh "$(prompt_payload "onay $c1")"
  run_hook guard-destructive.sh "$(bash_payload 'git reset --hard HEAD')"; [ "$(decision)" = "deny" ]
  run_hook inject-rules.sh "$(prompt_payload "onay $c2")"
  run_hook guard-destructive.sh "$(bash_payload 'git clean -fd')"; [ -z "$output" ]
  run_hook guard-destructive.sh "$(bash_payload 'git reset --hard')"; [ -z "$output" ]
}

@test "guard: same rules for subagents; English message uses approve" {
  mk_project "$(cfg '"careful":{"patterns":[]}')"
  run_hook guard-destructive.sh "$(bash_payload 'kubectl delete ns x' agent-1)"
  [ "$(decision)" = "deny" ]; reason | grep -qE "'approve [0-9a-f]{6}'"
}

@test "guard: touching the grant file is denied without a code" {
  mk_project
  run_hook guard-destructive.sh "$(bash_payload "echo x >> $(grants)")"
  [ "$(decision)" = "deny" ]; lacks "$(reason)" "'onay "
}

@test "guard: Write/Edit/NotebookEdit to the grant file is denied without a code" {
  mk_project
  run_hook guard-destructive.sh "$(write_payload "$(grants)")"
  [ "$(decision)" = "deny" ]; lacks "$(reason)" "'onay "; lacks "$(reason)" "'approve "
  run_hook guard-destructive.sh "$(jq -nc --arg p "$(grants)" --arg cwd "$PROJ" '{tool_name:"Edit",tool_input:{file_path:$p},cwd:$cwd}')"
  [ "$(decision)" = "deny" ]
  run_hook guard-destructive.sh "$(jq -nc --arg p "$(grants)" --arg cwd "$PROJ" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p},cwd:$cwd}')"
  [ "$(decision)" = "deny" ]
}

@test "guard: kill switches" {
  mk_project
  export MEMOKIT_CAREFUL_OFF=1
  run_hook guard-destructive.sh "$(bash_payload 'git push -f')"; [ -z "$output" ]
  unset MEMOKIT_CAREFUL_OFF; export MEMOKIT_GUARD_OFF=1
  run_hook guard-destructive.sh "$(bash_payload 'git push -f')"; [ -z "$output" ]
  unset MEMOKIT_GUARD_OFF
}

@test "guard: invalid config and unparseable payload deny" {
  mk_project "$(cfg '"careful":[]')"
  run_hook guard-destructive.sh "$(bash_payload 'ls')"
  [ "$(decision)" = "deny" ]; reason | grep -qF '.claude/memokit.json'
  mk_project
  run_hook guard-destructive.sh '{not json'
  [ "$(decision)" = "deny" ]
}

@test "guard: Write through a symlink to the grant file is denied (also chained, relative)" {
  mk_project
  ln -s "$(grants)" "$PROJ/lnk1"
  run_hook guard-destructive.sh "$(write_payload "$PROJ/lnk1")"
  [ "$(decision)" = "deny" ]; lacks "$(reason)" "'onay "
  ln -s lnk1 "$PROJ/lnk2"
  run_hook guard-destructive.sh "$(write_payload "$PROJ/lnk2")"
  [ "$(decision)" = "deny" ]
  ln -s "$PROJ/docs/x.md" "$PROJ/lnk3"
  run_hook guard-destructive.sh "$(write_payload "$PROJ/lnk3")"
  [ -z "$output" ]
  ln -s loop2 "$PROJ/loop1"; ln -s loop1 "$PROJ/loop2"
  run_hook guard-destructive.sh "$(write_payload "$PROJ/loop1")"
  [ "$(decision)" = "deny" ]
}

@test "session start names project patterns with an invalid regex" {
  mk_project "$(cfg '"careful":{"patterns":[{"match":"(","label":"broken"},{"match":"ok","label":"fine-one"}]}')"
  run_hook session-start.sh '{}'
  ctx | grep -q 'careful.patterns'; ctx | grep -q 'broken'
  lacks "$(ctx)" 'fine-one'
}

@test "final review: backslash-newline continuations are joined (builtins and project pattern)" {
  mk_project "$(cfg '"careful":{"patterns":[{"match":"kubectl[[:space:]]+apply","label":"kubectl-mutate"}]}')"
  bs='\'
  while IFS='|' read -r want a b; do
    [ -z "$want" ] && continue
    cmd="$(printf '%s %s\n%s' "$a" "$bs" "$b")"
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'XEOF'
kubectl-delete|kubectl --context prod -n app| delete deployment api
helm-uninstall|helm| uninstall api
git-reset-hard|git reset| --hard origin/main
rm-recursive|rm| -rf src
docker-prune|docker| system prune -af
ef-database-drop|dotnet ef| database drop -f
git-clean|git clean| -fdx
git-force-push|git push| --force
git-branch-delete|git branch| -D old
git-discard-all|git checkout| -- .
kubectl-mutate|kubectl| apply -f x.yaml
XEOF
  labels "$(printf 'psql <<SQL\nDELETE\nFROM users;\nSQL')"
  printf '%s\n' "$output" | grep -qx 'sql-destructive'
  labels "$(printf 'rm -rf node_modules %s\n  bin' "$bs")"
  [ -z "$output" ] || { echo "false positive: [$output]"; false; }
}

@test "continuation join follows bash: odd backslash run joins without a space; even run is literal" {
  mk_project
  # even run (\\) is a literal backslash: next line is a separate command
  labels "$(printf 'printf %%s -n foo\\\\\ngit clean -fdx')"
  printf '%s\n' "$output" | grep -qx 'git-clean' || { echo "even1: [$output]"; false; }
  labels "$(printf 'echo --staged x\\\\\ngit restore .')"
  printf '%s\n' "$output" | grep -qx 'git-discard-all' || { echo "even2: [$output]"; false; }
  # odd run: bash deletes backslash-newline, no space inserted
  labels "$(printf 'git push --for\\\nce')"
  printf '%s\n' "$output" | grep -qx 'git-force-push' || { echo "split1: [$output]"; false; }
  labels "$(printf 'kub\\\nectl delete ns x')"
  printf '%s\n' "$output" | grep -qx 'kubectl-delete' || { echo "split2: [$output]"; false; }
  labels "$(printf 'cat /tmp/memokit-1-careful-\\\ngrants')"
  printf '%s\n' "$output" | grep -qx 'careful-state' || { echo "split3: [$output]"; false; }
  # space-led continuation still caught
  labels "$(printf 'rm \\\n -rf src')"
  printf '%s\n' "$output" | grep -qx 'rm-recursive' || { echo "spaceled: [$output]"; false; }
  # three backslashes: literal + continuation
  labels "$(printf 'echo a\\\\\\\n && rm -rf src')"
  printf '%s\n' "$output" | grep -qx 'rm-recursive' || { echo "three: [$output]"; false; }
  # stays safe
  labels "$(printf 'rm -rf node_modules \\\n  bin')"
  [ -z "$output" ] || { echo "false positive: [$output]"; false; }
}

@test "continuation join is linear on a long run of continued lines" {
  mk_project
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'
    body=\$(awk 'BEGIN { for (i = 0; i < 3000; i++) { printf \"echo step %d \", i; for (j = 0; j < 80; j++) printf \"x\"; print \"\\\\\" } print \"done\" }')
    start=\$SECONDS
    out=\$(mk_careful_join \"\$body\")
    printf 'lines=%s elapsed=%s\n' \"\$(printf '%s\n' \"\$out\" | wc -l | tr -d ' ')\" \$((SECONDS - start))"
  echo "$output" >&3
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "lines=1" ]
  el="${output##*elapsed=}"
  [ "$el" -lt 2 ]
}

@test "comments, single quotes and quoted heredocs are not continued by bash: still caught" {
  mk_project
  while IFS='|' read -r want a b; do
    [ -z "$want" ] && continue
    labels "$(printf '%s\\\n%s' "$a" "$b")"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $a / $b -> [$output]"; false; }
  done <<'XEOF'
rm-recursive|# cleanup|rm -rf src
git-clean|# x|git clean -fdx
kubectl-delete|# x|kubectl delete ns x
git-clean|# --dry-run |git clean -fd
git-discard-all|# --staged |git restore .
git-clean|echo ok # -n |git clean -fdx
XEOF
  labels "$(printf "psql <<'SQL'\nDROP%s\nTABLE x;\nSQL" '\')"
  printf '%s\n' "$output" | grep -qx 'sql-destructive' || { echo "quoted heredoc: [$output]"; false; }
  for c in 'rm -rf \\\n  node_modules dist' 'rm -rf \\\n  node_modules \\\n  dist \\\n  build' 'rm -rf node_modules \\\n  bin'; do
    labels "$(printf "$c")"
    [ -z "$output" ] || { echo "false positive: $c -> [$output]"; false; }
  done
}

@test "final review: continuation join keeps the approval code on the raw command" {
  mk_project
  raw="$(printf 'git reset %s\n --hard' '\')"
  run_hook guard-destructive.sh "$(bash_payload "$raw")"
  [ "$(decision)" = "deny" ]
  [ "$(code_of)" = "$(lib 'mk_careful_code "$1"' "$raw")" ]
}

@test "final review: consume leaves no temp file behind" {
  mk_project
  f="$(grants)"
  lib 'mk_careful_grant abc123'
  lib 'mk_careful_consume abc123'
  [ "$(ls "$f".* 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
}

@test "final review: guard denies with jq missing and with empty stdin" {
  mk_project
  run env PATH="$(path_without jq)" "$MK_BASH" -c 'printf "%s" "$1" | "$0"' "$HOOKS/guard-destructive.sh" "$(bash_payload 'git status')"
  [ "$(decision)" = "deny" ]
  run_hook guard-destructive.sh ''
  [ "$(decision)" = "deny" ]
}
