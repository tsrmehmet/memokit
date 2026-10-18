#!/usr/bin/env bats
load helpers

# 0.5.2: every rule also runs on a flat view of the command (quotes and
# backslashes deleted, grouping characters blanked, glued operators split),
# so a quoted, escaped, prefixed or grouped command word no longer hides a
# destructive command. Labels are only ever added to the 0.5.1 result.

labels() {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels \"\$1\"" _ "$1"
}

# want_labels: stdin is "label|command" lines; each command must carry label.
want_labels() {
  local want cmd
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    labels "$cmd"
    printf '%s\n' "$output" | grep -qx "$want" || { echo "missed $want: $cmd -> [$output]"; return 1; }
  done
}

# no_labels: stdin is one command per line; none may be labelled.
no_labels() {
  local cmd
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    labels "$cmd"
    [ -z "$output" ] || { echo "false positive: $cmd -> [$output]"; return 1; }
  done
}

@test "0.5.2: quoted, escaped and prefixed rm is labelled" {
  mk_project
  want_labels <<'XEOF'
rm-recursive|"rm" -rf src
rm-recursive|'rm' -rf src
rm-recursive|r""m -rf src
rm-recursive|r''m -rf src
rm-recursive|\rm -rf src
rm-recursive|r\m -rf src
rm-recursive|"r"m -rf src
rm-recursive|$'rm' -rf src
rm-recursive|$'\x72m' -rf src
rm-recursive|$'\162m' -rf src
rm-recursive|"/bin/rm" -rf src
rm-recursive|'/usr/bin/rm' -rf src
rm-recursive|/bin/"rm" -rf src
rm-recursive|"rm" "-rf" "src"
rm-recursive|rm \-rf src
rm-recursive|rm -r""f src
rm-recursive|command "rm" -rf src
rm-recursive|command -p 'rm' -rf src
rm-recursive|builtin "rm" -rf src
rm-recursive|exec 'rm' -rf src
rm-recursive|nohup "rm" -rf src
rm-recursive|time "rm" -rf src
rm-recursive|env "rm" -rf src
rm-recursive|env -i X=1 Y=2 r""m -rf src
rm-recursive|sudo rm -rf src
rm-recursive|sudo -u root "rm" -rf src
rm-recursive|sudo -- "rm" -rf src
rm-recursive|doas -u root 'rm' -rf src
rm-recursive|timeout 5 rm -rf src
rm-recursive|timeout 5 "rm" -rf src
rm-recursive|timeout -s KILL 5 'rm' -rf src
rm-recursive|stdbuf -o0 "rm" -rf src
rm-recursive|ionice -c3 "rm" -rf src
rm-recursive|chrt -f 10 "rm" -rf src
rm-recursive|caffeinate "rm" -rf src
rm-recursive|nice -n 5 "rm" -rf src
rm-recursive|flock /tmp/l "rm" -rf src
rm-recursive|setsid "rm" -rf src
rm-recursive|xargs -0 "rm" -rf
rm-recursive|xargs -I {} "rm" -rf {}
rm-recursive|find . -name x -exec "rm" -rf {} +
rm-recursive|find . -execdir 'rm' -r {} \;
rm-recursive|X=1 "rm" -rf src
rm-recursive|X="a b" r''m -rf src
rm-recursive|X="a\"b" "rm" -rf src
rm-recursive|X="a; b" "rm" -rf src
rm-recursive|X=a\ b "rm" -rf src
rm-recursive|\command \rm -rf src
rm-recursive|echo x; "rm" -rf src
rm-recursive|true && 'rm' -rf src
rm-recursive|x=$("rm" -rf src)
rm-recursive|bash -c '"rm" -rf src'
rm-recursive|sh -c "'rm' -rf src"
rm-recursive|eval '"rm" -rf src'
rm-recursive|=rm -rf src
rm-recursive|"=rm" -rf src
rm-recursive|$(echo rm) -rf src
rm-recursive|`echo rm` -rf src
rm-recursive|$(which rm) -rf src
rm-recursive|> out "rm" -rf src
rm-recursive|2>/dev/null "rm" -rf src
rm-recursive|&>log 'rm' -rf src
rm-recursive|rm>/dev/null -rf src
rm-recursive|rm</dev/null -rf src
rm-recursive|if true; then "rm" -rf src; fi
rm-recursive|rm -R src
rm-recursive|rm --r src
rm-recursive|rm --rec src
rm-recursive|rm --recurs src
rm-recursive|"rm" --recursive src
XEOF
}

@test "0.5.2: grouped rm (braces, subshells, zsh glob qualifiers) is labelled" {
  mk_project
  want_labels <<'XEOF'
rm-recursive|{rm,-rf,src}
rm-recursive|{rm,} -rf src
rm-recursive|{"rm",-rf,src}
rm-recursive|(rm -rf src)
rm-recursive|("rm" -rf src)
rm-recursive|(cd x && "rm" -rf src)
rm-recursive|{ "rm" -rf src; }
rm-recursive|/bin/rm(N) -rf src
rm-recursive|/bin/rm(.) -rf src
rm-recursive|/usr/bin/rm(N) -r src
rm-recursive|echo "$("rm" -rf src)"
XEOF
}

@test "0.5.2: a computed command word followed by rm's recursive option is labelled (no safelist)" {
  mk_project
  want_labels <<'XEOF'
rm-recursive|$RM -rf src
rm-recursive|"$RM" -rf src
rm-recursive|${RM} -rf src
rm-recursive|${RM:-rm} -rf src
rm-recursive|"${RM:-/bin/rm}" -r src
rm-recursive|$RM -rf node_modules
rm-recursive|$RM -f -r src
rm-recursive|$RM --recursive src
rm-recursive|$RM --rec src
rm-recursive|sudo -u root $RM -rf src
rm-recursive|env X=1 "${RM}" -rf src
rm-recursive|X="a b" $RM -rf src
rm-recursive|X="$(echo "a b")" $RM -rf src
rm-recursive|nice -n 5 $RM -rf src
rm-recursive|doas -u root $RM -rf src
rm-recursive|timeout 5 $RM -rf src
rm-recursive|2>/dev/null $RM -rf src
rm-recursive|if true; then $RM -rf src; fi
rm-recursive|xargs -I {} $RM -rf {}
rm-recursive|find . -exec "$RM" -rf {} \;
rm-recursive|bash -c "$RM -rf src"
rm-recursive|sh -c '$RM -rf src'
rm-recursive|eval "$RM -rf src"
rm-recursive|/bin/r? -rf src
rm-recursive|/bin/r[m] -rf src
rm-recursive|/bin/r* -rf src
XEOF
}

@test "0.5.2: quoted, prefixed and grouped git/kubectl/helm/docker/ef/sql words are labelled" {
  mk_project
  want_labels <<'XEOF'
git-force-push|"git" push --force
git-force-push|'git' push -f
git-force-push|g""it push --force
git-force-push|\git push --force
git-force-push|git "push" --force
git-force-push|git push "--force"
git-force-push|git push origin "+main"
git-force-push|"/usr/bin/git" push -f
git-force-push|/usr/bin/git(N) push -f
git-force-push|sudo "git" push -f
git-force-push|timeout 60 "git" push -f
git-force-push|env GIT_TRACE=1 "git" push -f
git-force-push|=git push -f
git-force-push|$'git' push -f
git-force-push|$(command -v git) push -f
git-force-push|"${GIT:-git}" push --force
git-force-push|git push -f&
git-force-push|git push -f&echo done
git-force-push|git push -f>/dev/null
git-force-push|git push -f 2>&1|cat
git-force-push|(git push -f)
git-force-push|{git,push,-f}
git-force-push|git push --fo
git-force-push|git push --for origin main
git-force-push|git push --forc
git-reset-hard|"git" reset --hard
git-reset-hard|git 'reset' "--hard"
git-reset-hard|g\it reset --hard
git-reset-hard|X=1 "git" reset --hard
git-reset-hard|nohup 'git' reset --hard HEAD~1
git-reset-hard|(cd src && git reset --hard)
git-reset-hard|(git reset --hard)&
git-reset-hard|git reset --ha
git-reset-hard|git reset --har HEAD~1
git-clean|"git" clean -fdx
git-clean|git clean --fo -d
git-branch-delete|"git" branch -D old
git-worktree-force|"git" worktree remove --force x
git-worktree-force|sudo git worktree remove -f x
git-discard-all|"git" checkout -- .
git-discard-all|(git restore .)
kubectl-delete|"kubectl" delete ns x
kubectl-delete|k''ubectl delete ns x
kubectl-delete|(kubectl delete ns x)
helm-uninstall|"helm" uninstall api
helm-uninstall|helm un api
helm-uninstall|helm del api
helm-uninstall|"helm" "uninstall" api
docker-prune|"docker" system prune -af
docker-prune|docker volume remove data
docker-prune|docker "volume" rm data
ef-database-drop|"dotnet" ef database drop
sql-destructive|p""sql -c "DROP TABLE users"
sql-destructive|sudo -u postgres "psql" -c 'drop table x'
careful-state|cat /tmp/memokit-1-careful-gr""ants
careful-state|cat /tmp/memokit-1-careful-gr\ants
XEOF
}

@test "0.5.2: everyday commands keep their 0.5.1 labels (none)" {
  mk_project
  no_labels <<'XEOF'
"rm" -rf node_modules
'rm' -rf node_modules dist
"rm" file.txt
rm -rf "node_modules"
rm -rf ./web/dist/ 2>/dev/null
rm -rf node_modules >/dev/null 2>&1
(cd web && rm -rf node_modules)
{ rm -rf dist; }
rm -f *.log
git rm -r --cached .
git "rm" -r --cached .
"git" status
"git" push origin main
git push -u origin feat/x
git push --force-with-lease
git push --follow-tags
git reset --soft HEAD~1
git reset HEAD file.txt
git clean -n
git branch -d merged
git checkout -- src/a.cs
git restore --staged .
git log --oneline -5
git diff --stat
git commit -m "fix: handle (edge) cases, see #12"
git commit -m 'feat: add {x,y} options'
git commit -m 'it is "fine"' && "git" push -u origin feat/x
git clone --recursive https://example.com/r.git
GIT_SSH_COMMAND="ssh -i k" git clone --recursive u
git submodule update --init --recursive
grep -rn "DROP TABLE" src
grep -r "$pat" .
grep -rn --include='*.sh' foo .
ls -R "$dir"
ls -laR
x=$(ls -R)
cp -r "$src" "$dst"
cp -R a/ b/
chmod -R u+w build
chown -R "$USER" .
rsync -av --delete-after src/ dst/
rsync -r a b
scp -r dir host:/tmp
zip -r out.zip dir
diff -r a b
find . -type f -print
find "$d" -type f -print
find . -name '*.pyc' -print0
pip install -r requirements.txt
"$VENV/bin/pip" install -r requirements.txt
$PIP install -r req.txt
"$PYTHON" -m pytest -ra
$PY -m pytest -rP
$GREP -rn x .
"$GIT" reset --soft HEAD~1
$GIT push origin main
echo "$GIT push -f is banned"
[ -r file ] && echo ok
[[ -r file ]] && echo ok
while read -r line; do echo "$line"; done < f
jq -r '.a' f.json
curl -fsSL https://example.com/x | jq -r .tag
sed -E 's/(a|b)/c/g' f
awk '{print $1}' f
dotnet build -c Release
dotnet test --no-build
npm ci && npm run build
docker build -t x .
docker run --rm -it ubuntu:24.04 bash
docker compose up -d
docker volume ls
docker rm abc
kubectl get pods -A
helm upgrade --install api ./chart
helm list
psql -c "select 1"
echo "done" > /tmp/x 2>&1
printf '%s\n' "$x" | tr -d '\r'
sort -r f | uniq -c
make -j8
eval "$(ssh-agent -s)"
timeout 30 npm test -- -r
X="a b" ls -R x
bash -c 'ls -R'
XEOF
}

@test "0.5.2: documented false positive -- a quoted message that spells a destructive command" {
  mk_project
  # Quotes are deleted in the flat view, so prose inside quotes is matched
  # too (README, Limitations). Asking for an approval here is accepted.
  labels 'git commit -m "push --force later"'
  [ "$output" = "git-force-push" ]
  labels 'git commit -m "docs: never git reset --hard"'
  [ "$output" = "git-reset-hard" ]
}

@test "0.5.2: documented open forms stay unlabelled (README, Limitations)" {
  mk_project
  # The command name exists only at run time; text matching cannot see it.
  # If one of these starts to be labelled, update the README limitation.
  no_labels <<'XEOF'
/bin/r(m|x) -rf src
$X push -f
$GIT push -f
psql -c "DROP${IFS}TABLE users"
$RM src -rf
$(printf %s r m) -rf src
XEOF
}

@test "0.5.2: mk_careful_flat output" {
  in='"g"it '\''push'\'' r""m \rm -rf src;x {rm,-rf,a} ${RM:-rm} (cd a&&git reset --hard)&b 2>&1 x>f &>g rm>/dev/null'
  want='git push rm rm -rf src ; x  rm -rf a  $RM rm   cd a &&git reset --hard & b 2>&1 x >f &>g rm >/dev/null'
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_careful_flat \"\$1\"" _ "$in"
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ] || { printf 'got:  [%s]\nwant: [%s]\n' "$output" "$want"; false; }
  # a comma outside braces is kept (rm -rf a,b names one file)
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_careful_flat 'rm -rf a,b'"
  [ "$output" = "rm -rf a,b" ]
}

@test "0.5.2: a flat view that cannot be computed fails closed (unparsed)" {
  mk_project
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/sed"; chmod +x "$stub/sed"
  run env PATH="$stub:$PATH" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels 'ls -la'"
  [ "$output" = "unparsed" ] || { echo "got [$output]"; false; }
  printf '#!/bin/sh\ncat >/dev/null\n' > "$stub/sed"
  run env PATH="$stub:$PATH" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels 'ls -la'"
  [ "$output" = "unparsed" ] || { echo "got [$output]"; false; }
}

# guard_file FILE -- run the guard on the command in FILE under a 5 s CPU
# limit; sets output/status and ms (wall time of the hook run).
guard_file() {
  local pl t0 t1
  pl="$BATS_TEST_TMPDIR/payload.json"
  jq -Rs --arg cwd "$PROJ" '{tool_name:"Bash",tool_input:{command:.},cwd:$cwd}' < "$1" > "$pl"
  t0="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  # stdout only: the decision is parsed from it (stderr is checked separately)
  run "$MK_BASH" -c 'ulimit -t 5; "$0" "$1" < "$2" 2>"$3"' "$MK_BASH" "$HOOKS/guard-destructive.sh" "$pl" "$BATS_TEST_TMPDIR/stderr"
  t1="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
  ms=$((t1 - t0))
}
rep() { s="$1" awk -v n="$2" 'BEGIN { s = ENVIRON["s"]; for (i = 0; i < n; i++) printf "%s", s }'; }

@test "0.5.2: pathological input finishes in under a second and is labelled correctly" {
  mk_project
  d="$BATS_TEST_TMPDIR"; nl='
'
  rep 'a\"b' 1125 > "$d/word4k5"
  { printf 'X="'; rep a 2048; printf '" "rm" -rf src'; } > "$d/assign2k"
  { rep '"${a:-' 3000; printf ' git "push" -f'; } > "$d/nest3000"
  { printf 'cat > f.txt <<EOF\n'; rep "plain text line number forty-seven$nl" 8600; printf 'EOF'; } > "$d/heredoc300k"
  { printf "python -c '"; rep "print(1)$nl" 11000; printf "'"; } > "$d/python100k"
  rep 'echo hello world; ' 3900 > "$d/cmd70k"
  rep "\\$nl" 32000 > "$d/cont64k"
  rep "x\\$nl" 21000 > "$d/xcont63k"
  rep 'a&' 32000 > "$d/amp64k"
  rep 'x>' 32000 > "$d/redir64k"
  rep '"rm" -rf a/node_modules && git status | grep x
' 1300 > "$d/quotedrm64k"
  rep 'rm -rf a1/node_modules
' 900 | awk '{ sub(/a1/, "a" NR); print }' > "$d/rmsafe900"
  rep 'rm -rf "a1/node_modules"
' 2300 | awk '{ sub(/a1/, "a" NR); print }' > "$d/rmsafe2300"
  while read -r f want; do
    guard_file "$d/$f"
    echo "$f: ${ms} ms" >&3
    [ "$status" -eq 0 ] || { echo "$f: status $status (CPU limit?)"; false; }
    if [ "$want" = none ]; then
      [ -z "$output" ] || { echo "$f: expected allow -> $(reason | cut -c1-200)"; false; }
    else
      [ "$(decision)" = "deny" ] || { echo "$f: expected deny ($want)"; false; }
      reason | grep -q "$want" || { echo "$f: no $want in $(reason | cut -c1-200)"; false; }
    fi
    # Target < 1 s (measured and reported locally); the hard bound here is
    # well inside the 5 s hook timeout so a slow CI runner does not flake.
    [ "$ms" -lt 3000 ] || { echo "$f: ${ms} ms"; false; }
  done <<'XEOF'
word4k5 none
assign2k rm-recursive
nest3000 git-force-push
heredoc300k too-large
python100k too-large
cmd70k too-large
cont64k none
xcont63k none
amp64k none
redir64k none
quotedrm64k none
rmsafe900 none
rmsafe2300 too-large
XEOF
}

@test "0.5.2: too-large denies with its own message and the approval code still works" {
  mk_project
  f="$BATS_TEST_TMPDIR/big"
  rep 'echo hello world; ' 3900 > "$f"
  guard_file "$f"
  [ "$(decision)" = "deny" ]
  reason | grep -q 'too-large'
  reason | grep -q '64 KiB'
  code="$(reason | grep -oE "'(onay|approve) [0-9a-f]{6}'" | grep -oE '[0-9a-f]{6}')"
  [ -n "$code" ]
  run_hook inject-rules.sh "$(prompt_payload "onay $code")"
  guard_file "$f"
  [ -z "$output" ] || { echo "expected allow after approval -> $output"; false; }
  # exactly 64 KiB is still checked normally
  rep a 65536 > "$f"
  guard_file "$f"
  [ -z "$output" ]
}

# Fix round 1: too-large is approvable, careful-state never is; a big command
# must not hide a touch of the approval (grant) file.
@test "0.5.2 fix 1: too-large never hides careful-state (labels)" {
  mk_project
  pad="$(rep 'echo hello world; ' 3900)"
  nl='
'
  for t in 'cat /tmp/memokit-1-careful-grants' 'cat /tmp/memokit-1-"careful"-grants' \
           'cat /tmp/memokit-1-careful-gr\ants' "cat /tmp/memokit-1-careful-gr\\${nl}ants"; do
    labels "$pad$t"
    printf '%s\n' "$output" | grep -qx 'careful-state' || { echo "no careful-state: $t -> [$output]"; false; }
    printf '%s\n' "$output" | grep -qx 'too-large' || { echo "no too-large: $t -> [$output]"; false; }
  done
  labels "$pad"
  [ "$output" = "too-large" ]
  # the 1000-rm-segment too-large path keeps careful-state too
  labels "$(rep 'rm -rf "a1/node_modules"
' 1100 | awk '{ sub(/a1/, "a" NR); print }')cat /tmp/memokit-1-careful-grants"
  printf '%s\n' "$output" | grep -qx 'careful-state' || { echo "rm cap: [$output]"; false; }
  printf '%s\n' "$output" | grep -qx 'too-large' || { echo "rm cap: [$output]"; false; }
}

@test "0.5.2 fix 1: a big command touching the grant file is denied and no approval code opens it" {
  mk_project
  f="$BATS_TEST_TMPDIR/big"
  { rep 'echo hello world; ' 3900; printf 'cat /tmp/memokit-1-"careful"-grants'; } > "$f"
  code="$("$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_careful_code \"\$(cat \"\$1\")\"" _ "$f")"
  [ -n "$code" ]
  run_hook inject-rules.sh "$(prompt_payload "onay $code")"
  guard_file "$f"
  [ "$(decision)" = "deny" ] || { echo "expected deny -> $output"; false; }
  lacks "$(reason)" 'too-large'
  if reason | grep -qE "'(onay|approve) [0-9a-f]{6}'"; then echo "offers a code: $(reason)"; false; fi
}

# Fix round 2: a broken awk (or one that prints nothing) must never turn
# into "no labels" = allow.
@test "0.5.2 fix 2: a failing awk fails closed (unparsed), careful-state stays non-approvable" {
  mk_project
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  for body in 'exit 2' 'cat >/dev/null; exit 0'; do
    printf '#!/bin/sh\n%s\n' "$body" > "$stub/awk"; chmod +x "$stub/awk"
    for c in 'git reset --hard' 'ls'; do
      run env PATH="$stub:$PATH" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels \"\$1\"" _ "$c"
      printf '%s\n' "$output" | grep -qx 'unparsed' || { echo "awk '$body': $c -> [$output]"; false; }
      run env PATH="$stub:$PATH" "$MK_BASH" -c 'printf "%s" "$2" | "$0" "$1"' "$MK_BASH" "$HOOKS/guard-destructive.sh" "$(bash_payload "$c")"
      [ "$(decision)" = "deny" ] || { echo "awk '$body': guard allowed $c"; false; }
      reason | grep -q 'unparsed' || { echo "awk '$body': $c -> $(reason)"; false; }
    done
    # the raw text still carries its rule: git reset --hard keeps its label
    run env PATH="$stub:$PATH" "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels 'git reset --hard'"
    printf '%s\n' "$output" | grep -qx 'git-reset-hard' || { echo "awk '$body': [$output]"; false; }
    # careful-state survives, also quoted, and no approval code opens it
    c='cat /tmp/memokit-1-"careful"-grants'
    code="$("$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_careful_code \"\$1\"" _ "$c")"
    run_hook inject-rules.sh "$(prompt_payload "onay $code")"
    run env PATH="$stub:$PATH" "$MK_BASH" -c 'printf "%s" "$2" | "$0" "$1"' "$MK_BASH" "$HOOKS/guard-destructive.sh" "$(bash_payload "$c")"
    [ "$(decision)" = "deny" ] || { echo "awk '$body': grant file touch allowed"; false; }
    if reason | grep -qE "'(onay|approve) [0-9a-f]{6}'"; then echo "awk '$body': offers a code: $(reason)"; false; fi
  done
}

@test "0.5.2 fix 2: a grep error counts as a match in a rule, never as no match" {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'
    _mk_cf_rule 'git status' '(' && echo rule-err
    _mk_cf_rule 'git status' 'git' '!(' && echo neg-err
    _mk_cf_rule 'git status' 'push' || echo no-match
    _mk_cf_has '(' 'x' && echo has-err"
  [ "$output" = "rule-err
neg-err
no-match
has-err" ] || { echo "$output"; false; }
}

# Fix round 3: no broken tool may turn into "allow", in the library or in
# the guard; careful-state is never approvable.
# guard_stub TOOL BODY CMD -- run the guard with a stub TOOL first on PATH.
guard_stub() {
  local stub="$BATS_TEST_TMPDIR/stub-$1"
  mkdir -p "$stub"
  printf '#!/bin/sh\n%s\n' "$2" > "$stub/$1"; chmod +x "$stub/$1"
  run env PATH="$stub:$PATH" "$MK_BASH" -c 'printf "%s" "$2" | "$0" "$1"' "$MK_BASH" "$HOOKS/guard-destructive.sh" "$3"
}

@test "0.5.2 fix 3: a broken awk, sed, grep, tr or jq never lets the guard allow" {
  mk_project
  g='cat /tmp/memokit-1-"careful"-grants'
  code="$("$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_careful_code \"\$1\"" _ "$g")"
  for tool in awk sed grep tr jq; do
    for body in 'exit 2' 'cat >/dev/null; exit 0' 'cat >/dev/null; printf .'; do
      for c in 'git reset --hard' 'ls' 'rm -rf src' "$g"; do
        # a grant for the grant-file command is waiting: it must not be used
        run_hook inject-rules.sh "$(prompt_payload "onay $code")"
        guard_stub "$tool" "$body" "$(bash_payload "$c")"
        # A stub that prints plausible output (".") can only be caught where
        # an invariant breaks; for a harmless ls, allowing is the right answer.
        [ "$c" = ls ] && [ "$body" = 'cat >/dev/null; printf .' ] && continue
        [ "$(decision)" = "deny" ] || { echo "$tool '$body': allowed: $c [$output]"; false; }
        if [ "$c" = "$g" ] && reason | grep -qE "'(onay|approve) [0-9a-f]{6}'"; then
          echo "$tool '$body': grant-file command offers a code: $(reason)"; false
        fi
      done
    done
  done
}

@test "0.5.2 fix 3: wrapper -n, case and .exe spellings, more SQL tools" {
  mk_project
  want_labels <<'XEOF'
git-clean|nice -n 10 git clean -fdx
git-clean|sudo -n git clean -fdx
git-clean|git clean -n -f
git-clean|nice -n 10 git clean -nf
rm-recursive|RM -rf myproject
rm-recursive|/bin/RM -rf src
rm-recursive|sudo Rm -r src
git-force-push|Git push -f
git-reset-hard|GIT reset --hard
kubectl-delete|KubeCtl delete ns prod
kubectl-delete|kubectl.exe delete ns prod
git-force-push|git.exe push -f
git-force-push|C:/tools/Git.EXE push --force
helm-uninstall|helm.exe uninstall api
docker-prune|Docker system prune -af
sql-destructive|dropdb prod
sql-destructive|sudo -u postgres dropdb -h db shop
sql-destructive|mysqladmin -u root drop shop
sql-destructive|mysqladmin -u root -f DROP shop
sql-destructive|pgcli -e "DROP TABLE x"
XEOF
  no_labels <<'XEOF'
rm -rf __pycache__ .pytest_cache
rm -rf src/__pycache__ ./.pytest_cache/
mysqladmin -u root status
pgcli -e "select 1"
echo GIT_DIR is set
XEOF
}

# Fix round 4.
@test "0.5.2 fix 4: a plausible-output awk or tr with continuations still fails closed" {
  mk_project
  for tool in awk tr; do
    for c in "$(printf 'git reset \\\n --hard')" "$(printf 'rm -rf \\\n src')" "$(printf 'psql -c \\\n "DROP TABLE users"')" 'psql -c "DROP TABLE users"'; do
      guard_stub "$tool" 'cat >/dev/null; printf .' "$(bash_payload "$c")"
      [ "$(decision)" = "deny" ] || { echo "$tool: allowed: $c [$output]"; false; }
    done
  done
}

@test "0.5.2 fix 4: git clean -f is labelled even with a dry-run flag (no parser differential)" {
  mk_project
  want_labels <<'XEOF'
git-clean|git clean -fdx -e -nx
git-clean|git clean -nf
git-clean|git clean --dry-run --force
git-clean|git clean -fd --dry-run
XEOF
  no_labels <<'XEOF'
git clean -n
git clean --dry-run -d
XEOF
}

@test "0.5.2 fix 4: grant-file protection is case- and glob-aware" {
  mk_project
  want_labels <<'XEOF'
careful-state|cat /tmp/memokit-1-CAREFUL-GRANTS
careful-state|cat /tmp/memokit-1-Careful-Grants
careful-state|cat /tmp/memokit-*-careful-grants
careful-state|cat /tmp/memokit-1-careful?grants
careful-state|cat /tmp/memokit-1-careful*grants
careful-state|cat /tmp/memokit-*-careful-g*
careful-state|cat /tmp/memokit-*/*grants*
careful-state|echo x >> /tmp/MEMOKIT-1-careful-gr[a]nts
careful-state|ls /tmp/memokit-*
careful-state|ls /private/tmp/memokit-*
careful-state|ls /var/folders/xy/T/memokit-?
careful-state|cat "$TMPDIR"/memokit-*
careful-state|cat ${TMPDIR}/memokit-1-*
careful-state|cat $TMPDIR/Memokit-*
careful-state|cat memokit-*-careful*
careful-state-glob|cat /tmp/careful*
careful-state-glob|ls ../memokit-*
careful-state-glob|ls ~/Documents/GitHub/memokit-*
careful-state-glob|cd /tmp && ls memokit-*
XEOF
  # the broad glob forms are approvable: no careful-state
  for c in 'ls ../memokit-*' 'ls ~/Documents/GitHub/memokit-*' 'cat /tmp/careful*'; do
    labels "$c"
    if printf '%s\n' "$output" | grep -qx 'careful-state'; then echo "non-approvable: $c -> [$output]"; false; fi
  done
  no_labels <<'XEOF'
ls -la /tmp
cat ../project/.memokit-keep
find . -name .memokit-keep
grep -rn careful src
echo "be careful" > notes.txt
XEOF
  # Edit/Write: the case-insensitive file system reaches the same file
  run_hook guard-destructive.sh "$(write_payload /tmp/memokit-1-CAREFUL-GRANTS)"
  [ "$(decision)" = "deny" ]
}

@test "0.5.2 fix 4b: a broad memokit- glob is approvable; grant-file names never are" {
  mk_project
  run_hook guard-destructive.sh "$(bash_payload 'ls ../memokit-*')"
  [ "$(decision)" = "deny" ]
  reason | grep -q 'careful-state-glob'
  code="$(reason | grep -oE "'(onay|approve) [0-9a-f]{6}'" | grep -oE '[0-9a-f]{6}')"
  [ -n "$code" ] || { echo "no code: $(reason)"; false; }
  run_hook inject-rules.sh "$(prompt_payload "onay $code")"
  run_hook guard-destructive.sh "$(bash_payload 'ls ../memokit-*')"
  [ -z "$output" ] || { echo "approval did not work: $output"; false; }
  for c in 'cat /tmp/memokit-*-careful-grants' 'echo x > /tmp/MEMOKIT-1-CAREFUL-GRANTS'; do
    k="$("$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_careful_code \"\$1\"" _ "$c")"
    run_hook inject-rules.sh "$(prompt_payload "onay $k")"
    run_hook guard-destructive.sh "$(bash_payload "$c")"
    [ "$(decision)" = "deny" ] || { echo "allowed: $c"; false; }
    if reason | grep -qE "'(onay|approve) [0-9a-f]{6}'"; then echo "offers a code: $c -> $(reason)"; false; fi
  done
}

@test "0.5.2 fix 4c: the deny message lists every label" {
  mk_project
  run_hook guard-destructive.sh "$(bash_payload 'rm -rf ../memokit-* src')"
  [ "$(decision)" = "deny" ]
  reason | grep -q 'careful-state-glob' || { echo "$(reason)"; false; }
  reason | grep -q 'rm-recursive' || { echo "$(reason)"; false; }
  f="$BATS_TEST_TMPDIR/big"
  { rep 'echo hello world; ' 3900; printf 'git push -f; ls ../memokit-*'; } > "$f"
  guard_file "$f"
  reason | grep -q 'too-large' || { echo "$(reason)"; false; }
  reason | grep -q 'careful-state-glob' || { echo "$(reason)"; false; }
}

# 0.5.3: lowercasing a command word must not skip the next one.
@test "0.5.3: case normalisation does not skip adjacent command words" {
  mk_project
  want_labels <<'XEOF'
rm-recursive|echo rm;RM -rf x
git-force-push|true;Git push -f
rm-recursive|a|RM -rf x
rm-recursive|x&&RM -rf y
rm-recursive|RM RM -rf x
rm-recursive|echo git;RM -rf x
kubectl-delete|helm;KUBECTL delete ns x
docker-prune|git|DOCKER system prune -af
XEOF
  no_labels <<'XEOF'
Dockerfile build
echo RMDIR GITLAB HELMET Dotnetty
make Gitlab-ci
XEOF
}

# 0.5.3: GitHub Actions runs jobs with SIGPIPE ignored. grep -q stops reading
# at its first match, and the printf feeding it then reported "write error:
# Broken pipe" on stderr (CI: test "deny message lists every label").
@test "0.5.3: with SIGPIPE ignored, an early grep -q match writes nothing to stderr" {
  mk_project
  f="$BATS_TEST_TMPDIR/big"
  { rep 'echo hello world; ' 3900; printf 'git push -f; ls ../memokit-*'; } > "$f"
  jq -Rs --arg cwd "$PROJ" '{tool_name:"Bash",tool_input:{command:.},cwd:$cwd}' < "$f" > "$BATS_TEST_TMPDIR/pl.json"
  "$MK_BASH" -c 'trap "" PIPE; "$0" "$1" < "$2" > "$3" 2> "$4"' "$MK_BASH" "$HOOKS/guard-destructive.sh" \
    "$BATS_TEST_TMPDIR/pl.json" "$BATS_TEST_TMPDIR/out" "$BATS_TEST_TMPDIR/err"
  [ ! -s "$BATS_TEST_TMPDIR/err" ] || { cat "$BATS_TEST_TMPDIR/err"; false; }
  jq -e '.hookSpecificOutput.permissionDecision == "deny"' "$BATS_TEST_TMPDIR/out" >/dev/null
  # the library alone, and the prompt hook
  run "$MK_BASH" -c "trap '' PIPE; . '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels \"\$(cat \"\$1\")\" 2>&1 >/dev/null" _ "$f"
  [ -z "$output" ] || { echo "$output"; false; }
  big="$(rep 'approve all of this please ' 6000)"
  "$MK_BASH" -c 'trap "" PIPE; printf "%s" "$1" | "$0" "$2" > /dev/null 2> "$3"' "$MK_BASH" "$(prompt_payload "$big")" "$HOOKS/inject-rules.sh" "$BATS_TEST_TMPDIR/err2"
  [ ! -s "$BATS_TEST_TMPDIR/err2" ] || { cat "$BATS_TEST_TMPDIR/err2"; false; }
}
