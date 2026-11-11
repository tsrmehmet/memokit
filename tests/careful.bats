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

load_remote() {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_load_config; printf '%s|%s|%s|%s' \"\$MK_REMOTE_ENABLED\" \"\$MK_REMOTE_HOSTS\" \"\$MK_REMOTE_WINDOW_MIN\" \"\$MK_REMOTE_RUNBOOKS_DIR\""
}

@test "remote config: loads with defaults; absent → disabled" {
  mk_project "$(cfg '"remote":{"deployBranches":["deploy"],"hosts":["31.210.53.162","*"]}')"
  load_remote   # prints ENABLED|HOSTS|WINDOW|RUNBOOKS
  [ "$output" = "1|31.210.53.162
*|30|.claude/memokit/runbooks" ]
  mk_project; load_remote; [ "${output%%|*}" = "0" ]
}
@test "remote config: bad shapes are rejected with field remote" {
  for c in '"remote":[]' '"remote":{"x":1}' '"remote":{"hosts":[""]}' '"remote":{"deployBranches":["a b"]}' \
           '"remote":{"windowMinutes":0}' '"remote":{"windowMinutes":241}' '"remote":{"readOnlyFirstWords":["a-b-c"]}' \
           '"remote":{"runbooksDir":"../x"}'; do
    mk_project "$(cfg "$c")"; load_cfg; [ "${output%%|*}" = "remote" ] || { echo "$c -> $output"; false; }
  done
}
@test "careful pattern target: optional, validated like a label" {
  mk_project "$(cfg '"careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]}')"
  load_cfg; [ "${output%%|*}" = "" ]
  mk_project "$(cfg '"careful":{"patterns":[{"match":"x","label":"a","target":"Bad Target"}]}')"
  load_cfg; [ "${output%%|*}" = "careful" ]
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
git-worktree-force|git worktree remove --force .claude/worktrees/mk-r1-a
git-worktree-force|git worktree remove -f x
git-worktree-force|git worktree remove -ff x
git-worktree-force|git -C repo worktree remove --force x
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
git worktree remove .claude/worktrees/mk-r1-a
git worktree list
git worktree add ../x -b y
git branch -d mk/r1/a
git worktree remove .claude/worktrees/mk-r1-L1-fix
git branch -d mk/r1/L1-fix
git worktree remove x --force-later
git worktree prune
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

# The 0.7.1 computed-word cases stay denied (fail closed).
@test "0.7.2: a computed command word is still rm" {
  mk_project
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'XEOF'
rm-recursive|$RM -rf x
rm-recursive|${RM} -rf x
rm-recursive|"$RM" -rf x
rm-recursive|/bin/r? -rf x
rm-recursive|sudo $RM -rf x
rm-recursive|sudo -n $RM -rf x
rm-recursive|/usr/bin/sudo -n $RM -rf x
rm-recursive|env A=1 $RM -rf x
rm-recursive|A=1 $RM -rf x
rm-recursive|A=1 B=2 $RM -rf x
rm-recursive|LC_ALL=C sudo $RM -rf x
rm-recursive|xargs $RM -rf
rm-recursive|xargs -0 $RM -rf
rm-recursive|command $RM -rf x
rm-recursive|nohup $RM -rf x
rm-recursive|builtin $RM -rf x
rm-recursive|exec $RM -rf x
rm-recursive|time $RM -rf x
rm-recursive|ls; $RM -rf x
rm-recursive|true && $RM -rf x
rm-recursive|false || $RM -rf x
rm-recursive|find . | xargs $RM -rf
rm-recursive|for f in a; do $RM -rf "$f"; done
rm-recursive|! $RM -rf x
rm-recursive|{ $RM -rf x; }
rm-recursive|( $RM -rf x )
rm-recursive|($RM -rf x)
rm-recursive|x=$($RM -rf x)
rm-recursive|echo "$($RM -rf x)"
rm-recursive|echo `$RM -rf x`
rm-recursive|cat <($RM -rf x)
rm-recursive|case a in a) $RM -rf x;; esac
rm-recursive|f() { $RM -rf x; }
rm-recursive|trap '$RM -rf x' EXIT
rm-recursive|ssh host $RM -rf x
rm-recursive|docker exec c $RM -rf x
rm-recursive|kubectl exec p -- $RM -rf x
rm-recursive|find . -execdir $RM -r {} +
rm-recursive|$'\x72m' -rf x
rm-recursive|'a'$RM -rf x
XEOF
  # Documented false positives (README, Limitations): a computed word that is
  # not a command, outside a read-only first word.
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'XEOF'
rm-recursive|"$EDITOR" -R notes.md
rm-recursive|sudo grep -n "$p" -r src
XEOF
}

# 0.7.2 (BL-449), approach A: a computed word + recursive option anywhere in a
# segment is rm-recursive (as in 0.7.1), except in a segment whose first word
# is exactly a read-only tool, with no substitution or grouping.
@test "0.7.2: computed word in places the command-position rule missed is rm" {
  mk_project
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; false; }
  done <<'XEOF'
rm-recursive|case x in a)$RM -rf y;; esac
rm-recursive|a) "$RM" -rf y
rm-recursive|function f { $RM -rf x; }
rm-recursive|f() { "${RM}" -rf x; }
rm-recursive|gtimeout 5 $RM -rf x
rm-recursive|pkexec $RM -rf x
rm-recursive|fakeroot $RM -rf x
rm-recursive|busybox $RM -rf x
rm-recursive|$SHELL -c "$RM -rf x"
rm-recursive|$SHELL -c '$RM -rf x'
rm-recursive|grep x $($RM -rf y)
rm-recursive|grep x `$RM -rf y`
rm-recursive|grep x <($RM -rf y)
rm-recursive|grep x >($RM -rf y)
rm-recursive|grep x; $RM -rf y
rm-recursive|grep x && "$RM" -rf y
rm-recursive|grep x | xargs $RM -rf
rm-recursive|grep x&$RM -rf y
rm-recursive|grep() { $RM -rf "$1"; }
rm-recursive|/tmp/grep $RM -rf x
rm-recursive|"grep" $RM -rf x
rm-recursive|grep2 $RM -rf x
rm-recursive|/usr/bin/grep -n "a.*" -r x
rm-recursive|LC_ALL=C grep -n "a.*b" -r src
rm-recursive|X=1 jq '.a[]' -r f.json
rm-recursive|grep -nE "^(foo|bar)$" -r src
rm-recursive|tar --to-command="$RM" -rf a.tar
rm-recursive|tar --use-compress-program "$RM" -rf a.tar
rm-recursive|tar --use-c=$RM -rf a.tar
rm-recursive|tar -I "$RM" -rf a.tar
rm-recursive|tar -xIf $RM -rf a.tar
rm-recursive|tar --checkpoint-action=exec=x -C "$d" -rf a.tar
rm-recursive|git grep -O"$RM" -r x
rm-recursive|rg --pre "$RM" -r x f
rm-recursive|sed -n "s/$X/y/" -r f
rm-recursive|awk "BEGIN{system(\"$X\")}" -r f
rm-recursive|grep -rn "func(.*)" -r .
rm-recursive|git ls-files | grep -n "x.*" -r
rm-recursive|X="a;grep x" $RM -rf y
rm-recursive|X='a|grep x' $RM -rf y
rm-recursive|X=$'a;grep x' $RM -rf y
rm-recursive|env X="a;grep x" $RM -rf y
rm-recursive|sudo -u "a;grep x" $RM -rf y
rm-recursive|exec -a "a;grep x" $RM -rf y
rm-recursive|>"a;grep x" $RM -rf y
rm-recursive|2>'a|ls x' "$RM" -rf y
rm-recursive|X="a;tar x" /bin/r? -rf y
rm-recursive|X="a;git log x" $RM -rf y
rm-recursive|X="a;grep x" $RM -r -f y
rm-recursive|X="a;grep x" $RM --recursive y
rm-recursive|if grep -q "a;grep x" $RM -rf y; then :; fi
rm-recursive|X="a\";grep x" $RM -rf y
rm-recursive|X="a;grep x" $RM -rf y "b;c"
rm-recursive|ag --pager "$RM -rf y" x
rm-recursive|ag --pager="$RM -rf y" x
rm-recursive|tar -C "$d" --remove-files -rf a.tar src
rm-recursive|tar --remove-files -C "$d" -rvf a.tar .
rm-recursive|tar --recursive-unlink -C "$d" -rxf a.tar
rm-recursive|tar --rsh-command "$RM" -rf a.tar
rm-recursive|tar --rmt-command "$RM" -rf a.tar
rm-recursive|tar --new-volume-script "$RM" -rf a.tar
rm-recursive|tar --info-script "$RM" -rf a.tar
rm-recursive|tar -F "$RM" -rf a.tar
rm-recursive|tar "-I$RM" -rf a.tar
rm-recursive|tar "--to-command=$RM" -rf a.tar
rm-recursive|git grep --open-files-in-pager="$RM" -r x
rm-recursive|rg --hostname-bin "$RM" -r x f
rm-recursive|tar $'--to-command=x' "$RM" -rf a.tar
rm-recursive|tar $"--to-command=x" "$RM" -rf a.tar
rm-recursive|tar $'--use-compress-program' "$RM" -rf a.tar
rm-recursive|tar -C "$d" $'--remove-files' -rf a.tar src
rm-recursive|tar -C "$d" $'--recursive-unlink' -rxf a.tar
rm-recursive|tar -C "$d" $'--rem' -rf a.tar src
rm-recursive|rg $'--pre' "$RM" -r x f
rm-recursive|rg $"--pre" "$RM" -r x f
rm-recursive|git grep $'-O' "$RM" -r x
rm-recursive|git grep $'--open-files-in-pager' "$RM" -r x
rm-recursive|grep -n 'x$' -r src
rm-recursive|tar -C "$d"/--rem -rf a.tar src
rm-recursive|rg -n x/--pre "$RM" -r f
rm-recursive|grep x `$RM '' -rf y`
rm-recursive|grep x `$RM "" -rf y`
rm-recursive|grep x `"$RM" '' -rf y`
rm-recursive|grep x `$RM '' -r -f y`
rm-recursive|grep x `$RM ''  --recursive y`
rm-recursive|grep x `$RM \  -rf y`
rm-recursive|grep x `$RM {} -rf y`
rm-recursive|grep x $(  $RM '' -rf y )
rm-recursive|ls `$RM '' -rf y`
rm-recursive|jq . `$RM "" -Rf y`
rm-recursive|grep x ${z:="a[\$${BASH_VERSION:6:1}\$RM -rf y${BASH_VERSION:8:1}]"} $[z] f.txt
rm-recursive|grep x $[x] -r .
rm-recursive|grep x ${~x} -r .
rm-recursive|grep x $=x -r .
rm-recursive|grep x ${x?msg} -r .
rm-recursive|grep x $((1+1)) -r .
rm-recursive|grep x $$ -r .
rm-recursive|grep x $1 -r .
rm-recursive|grep x $@ -r .
rm-recursive|grep -n "${p}" -r src
rm-recursive|grep -n "x$" -r src
rm-recursive|yq --security-enable-system-operator "$EXPR" -r f
rm-recursive|yq --security-enable-system-operator --from-file e.yq "$f" -r
rm-recursive|yq '.a[]' -r f.yaml
rm-recursive|tar -C "$d" -rvf a.tar
rm-recursive|rg "a.*b" -r x f
rm-recursive|git grep -n "a.*" -r
rm-recursive|git log --grep "a.*" -r
rm-recursive|tar -${u}-to-command=$RM -xRf a.tar
rm-recursive|tar ${u:--}-to-command=$RM -xRf a.tar
rm-recursive|tar --t${u}o-command=$RM -xRf a.tar
rm-recursive|tar --t$u'o'-command=$RM -xRf a.tar
rm-recursive|tar -{-to-command=$RM,v} -xRf a.tar
rm-recursive|tar --t{o-command=$RM,otals} -xRf a.tar
rm-recursive|tar -${u}-use-compress-program=$RM -xRf a.tar
rm-recursive|tar -${u}-remove-files -C "$d" -rf a.tar src
rm-recursive|tar -{-remove-files,v} -C "$d" -rf a.tar src
rm-recursive|tar ${u:--}-rem -C "$d" -rf a.tar src
rm-recursive|git grep -${u}-open-files-in-pager=$RM -r x
rm-recursive|git grep -{-open-files-in-pager=$RM,n} -r x
rm-recursive|rg -${u}-pre=$RM -r x f
rm-recursive|rg -{-pre=$RM,n} -r x f
rm-recursive|rg ${u:--}-pre=$RM -r x f
rm-recursive|rg -${u}-hostname-bin=$RM -r x f
rm-recursive|tar	-${u}-to-command=$RM -xRf a.tar
rm-recursive|git	grep -{-open-files-in-pager=$RM,n} -r x
XEOF
  # A quoted newline is a segment break too.
  labels "$(printf 'X="a\ngrep x" $RM -rf y')"
  printf '%s\n' "$output" | grep -qx rm-recursive || { echo "newline form -> [$output]"; false; }
}

@test "0.7.2: a computed operand of a read-only first word is not rm (BL-449)" {
  mk_project
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    labels "$cmd"
    [ -z "$output" ] || { echo "false positive: $cmd -> [$output]"; false; }
  done <<'XEOF'
grep -n "Send.*Key" -r tests
jq '.items[]' -r f.json
ls tests/*.cs -R
cp src/*.cs -r dst
cp "$src"/* -r dst
cp $SRC -r dst
grep x {$RM,'',-rf,y}
ls -la tests/*.cs -R
egrep -n "a.*b" -r src
diff -r a/*.txt b
head -n 3 *.log -R
XEOF
}

# Security review round 5: in a double-byte locale a lead byte + backtick is
# one character, so the exemption's [^$`<>&()] swallowed the backtick. The
# match is byte-wise, and the exemption exists only in C/POSIX/UTF-8 locales
# (anywhere else the plain 0.7.1 rule runs over every view).
labels_in() {
  run env -u LANG -u LC_CTYPE LC_ALL="$1" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels \"\$1\"" _ "$2"
}

# has_locale NAME -- C always; others only when `locale -a` lists them
# (case-insensitive: names vary, en_US.utf8 vs en_US.UTF-8).
has_locale() {
  [ "$1" = C ] || locale -a 2>/dev/null | grep -qix "$1"
}

# want_rm LOCALE CMD -- labels_in, then rm-recursive must be among the labels.
want_rm() {
  labels_in "$1" "$2"
  printf '%s\n' "$output" | grep -qx rm-recursive || { echo "$1: $2 -> [$output]"; false; }
}

# want_clean LOCALE CMD -- labels_in, then no label at all.
want_clean() {
  labels_in "$1" "$2"
  [ -z "$output" ] || { echo "$1: $2 -> [$output]"; false; }
}

# gate_ok ENV... -- run the locale-name gate under exactly these variables.
gate_ok() {
  run env -u LC_ALL -u LC_CTYPE -u LANG "$@" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; _mk_cf_exempt 'grep x \$RM -rf y'"
}

# skip_no_dbcs -- skip (explicitly) when the machine has no double-byte locale.
skip_no_dbcs() {
  local loc
  for loc in zh_TW.Big5 zh_CN.GBK zh_CN.GB18030; do
    has_locale "$loc" && return 0
  done
  skip "no double-byte locale (Big5/GBK/GB18030) installed"
}

# labels_mixed CTYPE LANG CMD -- LC_ALL unset, LC_CTYPE=CTYPE, LANG=LANG.
labels_mixed() {
  run env -u LC_ALL LC_CTYPE="$1" LANG="$2" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels \"\$1\"" _ "$3"
}

@test "0.7.2: round-5 repro, a double-byte lead byte does not hide a backtick substitution" {
  skip_no_dbcs
  mk_project
  cmd=$'grep x \xe2\xa1\xa1`$RM -rf y \xe2\xa1\xa1`'
  for loc in zh_TW.Big5 zh_CN.GBK zh_CN.GB18030 en_US.UTF-8 C; do
    has_locale "$loc" || continue
    want_rm "$loc" "$cmd"
  done
}

@test "0.7.2: backslash lines joined by bash only in UTF-8, not after a double-byte lead byte" {
  skip_no_dbcs
  mk_project
  for loc in zh_TW.Big5 zh_CN.GBK zh_CN.GB18030 en_US.UTF-8; do
    has_locale "$loc" || continue
    want_rm "$loc" $'echo x \\\ny \xe2\xa1\xa1\\\nrm -rf z'
    # continuation lines are never exempt (accepted false positive in UTF-8,
    # where bash joins them into one grep; a real command in a double-byte locale)
    want_rm "$loc" $'grep x \\\ny \xe2\xa1\xa1\\\n$RM -rf z'
  done
}

@test "0.7.2: round-7 repro, a nonexistent UTF-8 LC_CTYPE name falls back to a double-byte LANG" {
  skip_no_dbcs
  mk_project
  cmd=$'grep x \\\ny \xe2\xa1\xa1\\\n$RM -rf z'
  for lang in zh_TW.Big5 zh_CN.GBK; do
    has_locale "$lang" || continue
    for ct in en_US.utf8 xx_XX.UTF-8 en_US.UTF-8@euro; do
      labels_mixed "$ct" "$lang" "$cmd"
      printf '%s\n' "$output" | grep -qx rm-recursive || { echo "$ct/$lang -> [$output]"; false; }
    done
  done
}

@test "0.7.2: round-9 pin, the byte-wise LC_ALL=C in _mk_cf_exempt holds in the mixed env (gate passes by name, bash uses the double-byte LANG)" {
  skip_no_dbcs
  mk_project
  cmd=$'grep x \xe2\xa1\xa1`$RM -rf y \xe2\xa1\xa1`'
  local ran=0
  for lang in zh_TW.Big5 zh_CN.GBK zh_CN.GB18030; do
    has_locale "$lang" || continue
    ran=1
    labels_mixed en_US.utf8 "$lang" "$cmd"
    printf '%s\n' "$output" | grep -qx rm-recursive || { echo "$lang -> [$output]"; false; }
  done
  [ "$ran" = 1 ]
}

@test "0.7.2: benign single-line commands stay unlabelled with a nonexistent UTF-8 LC_CTYPE" {
  mk_project
  for lang in C en_US.UTF-8; do
    has_locale "$lang" || continue
    labels_mixed en_US.utf8 "$lang" 'grep x $RM -rf y'
    [ -z "$output" ] || { echo "$lang: [$output]"; false; }
    labels_mixed en_US.utf8 "$lang" 'grep -n "Send.*Key" -r tests'
    [ -z "$output" ] || { echo "$lang: [$output]"; false; }
  done
}

@test "0.7.2: a real continuation line after an exempt-looking command is rm-recursive" {
  mk_project
  if has_locale en_US.UTF-8; then
    want_rm en_US.UTF-8 $'grep x $RM -rf y \\\n; $RM -rf z'
  fi
  want_rm C $'grep x $RM -rf y \\\n; $RM -rf z'
}

@test "0.7.2: benign read-only commands are exempt in C and UTF-8 locales only" {
  mk_project
  for loc in C en_US.UTF-8 C.UTF-8; do
    has_locale "$loc" || continue
    want_clean "$loc" 'grep x $RM -rf y'
    want_clean "$loc" 'grep -n "Send.*Key" -r tests'
  done
  if has_locale zh_TW.Big5; then
    # accepted false positive: no exemption outside UTF-8/C, as in 0.7.1
    want_rm zh_TW.Big5 'grep x $RM -rf y'
    want_rm zh_TW.Big5 'grep -n "Send.*Key" -r tests'
  fi
}

# Round 8: the exemption modelled redirections and was fooled by escaping
# (`a\>&"$RM" -rf y`: \> is a literal, & is the background operator, "$RM" runs).
# Option A: redirections are never exempt; no backslash, < > or & at all.
@test "0.7.2: round-8 repros, an escaped redirection does not hide a computed command word" {
  mk_project
  for loc in C en_US.UTF-8; do
    has_locale "$loc" || continue
    want_rm "$loc" 'grep x a\>&"$RM" -rf y'
    want_rm "$loc" 'grep x \>&"$RM" -rf y'
    want_rm "$loc" 'grep x a\<&"$RM" -rf y'
    want_rm "$loc" 'grep -r x a\>&"$RM" -r y'
    want_rm "$loc" 'jq . f\>&"$RM" -rf y'
    want_rm "$loc" 'grep x a\>&/bin/r? -rf y'
  done
}

@test "0.7.2: round-8, redirections are never exempt (accepted false positives)" {
  mk_project
  for loc in C en_US.UTF-8; do
    has_locale "$loc" || continue
    # computed word directly followed by a recursive option, plus a redirection
    # anywhere: no longer exempt, asks for approval (accepted false positive)
    want_rm "$loc" 'grep x $D -r >out'
    want_rm "$loc" 'grep x $D -r 2>/dev/null'
    want_rm "$loc" 'cat *.txt -r 2>&1'
    # a redirection BETWEEN the word and the option, or the recursive option
    # BEFORE the computed word, is no rm shape (DYNRM): unlabelled, not an FP
    want_clean "$loc" 'cat *.txt 2>&1 -r'
    want_clean "$loc" 'grep -rn x $D 2>/dev/null'
    want_clean "$loc" 'grep -rn x $D >out'
  done
}

@test "0.7.2: round-8, benign commands stay unlabelled in C, en_US.UTF-8 and C.UTF-8" {
  mk_project
  for loc in C en_US.UTF-8 C.UTF-8; do
    has_locale "$loc" || continue
    want_clean "$loc" 'grep x $RM -rf y'
    want_clean "$loc" 'grep -n "Send.*Key" -r tests'
    want_clean "$loc" 'jq -r .x $F'
    want_clean "$loc" 'ls -R $D'
    want_clean "$loc" "jq '.items[]' -r f.json"
    want_clean "$loc" 'ls tests/*.cs -R'
  done
}

@test "0.7.2: round-8, mixed env (LC_CTYPE falls back to a double-byte LANG): lead byte hides neither | nor an escaped redirection" {
  skip_no_dbcs
  mk_project
  for lang in zh_TW.Big5 zh_CN.GBK; do
    has_locale "$lang" || continue
    for cmd in $'grep x \xa1\\\\>&"$RM" -rf y' $'grep x \xa1|$RM -rf y'; do
      labels_mixed en_US.utf8 "$lang" "$cmd"
      printf '%s\n' "$output" | grep -qx rm-recursive || { echo "$lang: $cmd -> [$output]"; false; }
    done
  done
}

@test "0.7.2: round-8, _mk_cf_oneseg is byte-wise (a double-byte lead byte does not swallow |)" {
  skip_no_dbcs
  for lang in zh_TW.Big5 zh_CN.GBK; do
    has_locale "$lang" || continue
    run env -u LC_ALL LC_CTYPE=en_US.utf8 LANG="$lang" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; if _mk_cf_oneseg \"\$1\"; then echo true; else echo false; fi" _ $'grep x \xa1|y'
    [ "$output" = false ] || { echo "$lang: oneseg -> [$output]"; false; }
  done
}

@test "0.7.2: locale gate reads the effective LC_CTYPE (LC_ALL, then LC_CTYPE, then LANG)" {
  gate_ok;                                   [ "$status" -eq 0 ]
  gate_ok LANG=tr_TR.UTF-8;                  [ "$status" -eq 0 ]
  gate_ok LANG=en_US.utf8;                   [ "$status" -eq 0 ]
  gate_ok LANG=de_DE.UTF-8@euro;             [ "$status" -eq 0 ]
  gate_ok LC_ALL=POSIX;                      [ "$status" -eq 0 ]
  gate_ok LC_ALL=C LANG=zh_TW.Big5;          [ "$status" -eq 0 ]
  gate_ok LC_ALL= LC_CTYPE=zh_TW.Big5;       [ "$status" -ne 0 ]
  gate_ok LC_ALL= LC_CTYPE= LANG=zh_CN.GBK;  [ "$status" -ne 0 ]
  gate_ok LANG=zh_CN.GB18030;                [ "$status" -ne 0 ]
  gate_ok LC_CTYPE=en_US.ISO8859-1;          [ "$status" -ne 0 ]
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
  run_hook inject-rules.sh "$(prompt_payload 'ONAY ABC123.')"
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
