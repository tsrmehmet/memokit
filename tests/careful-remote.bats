#!/usr/bin/env bats
load helpers

# 0.8.0 Part A: lib/remote.sh labels remote commands (deploy-push,
# remote-mutate, k8s-mutate, runbook, project patterns with a target) and
# extracts their targets. Active only with a "remote" object in the config.

RCFG='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]},
"remote":{"deployBranches":["deploy","public-release"],"hosts":["31.210.53.162","prod.example.com"],"readOnlyFirstWords":["pm2-list"]}}'
RB=.claude/memokit/runbooks/deploy.sh

# rlib CODE ARG... -- run CODE with common.sh, careful.sh and remote.sh loaded.
rlib() {
  local code="$1"; shift
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; . '$HOOKS/lib/remote.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; $code" _ "$@"
}
labels()  { rlib 'mk_careful_labels "$1"' "$1"; }
targets() { rlib 'mk_remote_targets "$1"' "$1"; }
strip()   { rlib 'mk_remote_strip_covered "$1" "$2"' "$1" "$2"; }
valid()   { rlib 'mk_remote_target_valid "$1"' "$1"; }

rb_sha() { { sha256sum 2>/dev/null || shasum -a 256; } < "$PROJ/$RB" | cut -d' ' -f1; }
mk_runbook() {
  mkdir -p "$PROJ/.claude/memokit/runbooks"
  printf '#!/bin/sh\necho deploy "$1"\n' > "$PROJ/$RB"
}

# check_table: stdin lines "label|targets|command" (targets space-separated,
# sorted; label "none" = no remote label and no target). @SHA in a line is
# the runbook's sha256.
check_table() {
  local want tg cmd got sha=""
  [ -f "$PROJ/$RB" ] && sha="$(rb_sha)"
  while IFS='|' read -r want tg cmd; do
    [ -z "$cmd" ] && continue
    tg="${tg//@SHA/@$sha}"
    targets "$cmd"
    got="$(printf '%s' "$output" | tr '\n' ' ')"; got="${got% }"
    [ "$got" = "$tg" ] || { echo "targets: $cmd -> [$got], want [$tg]"; return 1; }
    labels "$cmd"
    if [ "$want" = none ]; then
      if printf '%s\n' "$output" | grep -qxE 'deploy-push|remote-mutate|k8s-mutate|runbook'; then
        echo "label: $cmd -> [$output], want no remote label"; return 1
      fi
    else
      printf '%s\n' "$output" | grep -qx "$want" || { echo "label: $cmd -> [$output], want $want"; return 1; }
    fi
  done
}

@test "deploy-push: refspecs, gh merge/workflow, dry-run and other branches" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy|git push origin deploy
deploy-push|branch:deploy|git push -u origin HEAD:deploy
deploy-push|branch:public-release|git push origin main:refs/heads/public-release
deploy-push|branch:deploy|git push --force origin deploy
git-force-push|branch:deploy|git push --force origin deploy
deploy-push|branch:deploy branch:public-release|gh pr merge 12 --squash
deploy-push|branch:deploy branch:public-release|gh workflow run deploy.yml
deploy-push|branch:deploy|git -C sub push origin +deploy
deploy-push|branch:deploy|Git push origin deploy
deploy-push|branch:deploy|git push origin deploy 2>&1
none||git push origin feature
none||git push --dry-run origin deploy
EOF
}

@test "deploy-push: no refspec looks up HEAD and upstream, fails closed" {
  mk_project "$RCFG"
  git -C "$PROJ" checkout -q -b feature
  git -C "$PROJ" remote add origin /nonexistent
  git -C "$PROJ" update-ref refs/remotes/origin/feature HEAD
  git -C "$PROJ" config branch.feature.remote origin
  git -C "$PROJ" config branch.feature.merge refs/heads/feature
  check_table <<'EOF'
none||git push
none||git push origin
deploy-push|branch:deploy branch:public-release|git -C nowhere push
EOF
  git -C "$PROJ" checkout -q -b deploy
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release|git push
EOF
}

@test "remote-mutate: hosts in every spelling; read-only, download and dry-run exempt" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:31.210.53.162|ssh root@31.210.53.162 'systemctl restart app'
remote-mutate|host:31.210.53.162|rsync -az ./ 'root@31.210.53.162:/opt/app/'
remote-mutate|host:prod.example.com|scp build.tgz prod.example.com:/tmp/
remote-mutate|host:prod.example.com|ssh -p 2222 -o StrictHostKeyChecking=no prod.example.com 'pm2 restart app'
remote-mutate|host:prod.example.com|ssh prod.example.com 'systemctl status app; rm -rf /srv'
remote-mutate|host:prod.example.com|ssh prod.example.com "cat \$(find / -name x)"
remote-mutate|host:prod.example.com|SSH PROD.example.com reboot
remote-mutate|host:prod.example.com|ssh ssh://admin@prod.example.com:2222 reboot
remote-mutate|host:prod.example.com|ssh -o Hostname=prod.example.com alias reboot
remote-mutate|host:prod.example.com|ssh prod.example.com
remote-mutate|host:prod.example.com|rsync -az ./ rsync://prod.example.com/app
remote-mutate|host:prod.example.com|rsync --remove-source-files prod.example.com:/x ./
remote-mutate|host:prod.example.com|sftp prod.example.com
none||ssh prod.example.com 'systemctl status app'
none||ssh prod.example.com docker ps -a
none||ssh prod.example.com pm2 list
none||ssh prod.example.com docker compose ps
remote-mutate|host:prod.example.com|ssh -T prod.example.com
none||ssh -N prod.example.com
none||ssh -O check prod.example.com
none||ssh prod.example.com uptime | grep load
none||rsync -az --exclude .git prod.example.com:/opt/ ./
remote-mutate|host:prod.example.com|rsync -e ssh prod.example.com:/a ./b
none||sftp prod.example.com:/var/log/app.log ./app.log
none||scp prod.example.com:/var/log/app.log ./log/
none||rsync -n -az ./ prod.example.com:/opt/app/
none||ssh other.host 'rm -rf /'
EOF
}

@test "k8s-mutate: context target; dry-run and diff exempt" {
  mk_project "$RCFG"
  check_table <<'EOF'
k8s-mutate|k8s:staging|kubectl --context staging apply -f k.yaml
k8s-mutate|k8s:staging|kubectl apply --context=staging -f k.yaml
k8s-mutate|k8s|helm upgrade app ./chart
k8s-mutate|k8s:prod|helm --kube-context prod rollback app 2
k8s-mutate|k8s|kubectl delete pod x
none||kubectl apply --dry-run=server -f k.yaml
none||kubectl diff -f k.yaml
none||kubectl get pods
EOF
}

@test "runbook: run by path or through a shell; piped into a shell is not one" {
  mk_project "$RCFG"
  mk_runbook
  check_table <<EOF
runbook|runbook:$RB@SHA|bash $RB prod
runbook|runbook:$RB@SHA|$RB
runbook|runbook:$RB@SHA|./$RB
runbook|runbook:$RB@SHA|sh $PROJ/$RB
none||cat $RB | bash
EOF
}

@test "project pattern with a target: label and pattern target" {
  mk_project "$RCFG"
  check_table <<'EOF'
fly|pattern:fly-prod|flyctl deploy --app x
EOF
  rlib 'mk_remote_scan "$1"' 'flyctl deploy --app x'
  [ "$output" = "$(printf 'fly\tpattern:fly-prod\tflyctl deploy --app x')" ]
}

@test "remote labels are off without a remote block" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en","careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]}}'
  mk_runbook
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    labels "$cmd"
    if printf '%s\n' "$output" | grep -qxE 'deploy-push|remote-mutate|k8s-mutate|runbook'; then
      echo "label without remote: $cmd -> [$output]"; false
    fi
    targets "$cmd"; [ -z "$output" ] || { echo "target without remote: $cmd -> [$output]"; false; }
  done <<EOF
git push origin deploy
gh pr merge 12 --squash
ssh root@31.210.53.162 'systemctl restart app'
kubectl --context staging apply -f k.yaml
helm upgrade app ./chart
bash $RB prod
EOF
  labels 'flyctl deploy --app x'
  [ "$output" = "fly" ]
}

@test "hosts: * matches any host" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["*"]}}'
  check_table <<'EOF'
remote-mutate|host:any.host|ssh any.host 'systemctl restart app'
remote-mutate|host:web-1|scp app.tgz deploy@web-1:/srv/
remote-mutate|host:any.host|ssh -p 22 Any.Host reboot
none||ssh any.host uptime
none||scp web-1:/var/log/x ./
none||rsync -az ./a ./b
EOF
}

@test "MK_REMOTE_NO_EXEMPT=1 labels the read-only ssh" {
  mk_project "$RCFG"
  for c in "ssh prod.example.com 'systemctl status app'" 'ssh -N prod.example.com' \
           'scp prod.example.com:/var/log/app.log ./log/' 'rsync -n -az ./ prod.example.com:/opt/app/'; do
    rlib 'MK_REMOTE_NO_EXEMPT=1 mk_remote_targets "$1"' "$c"
    [ "$output" = "host:prod.example.com" ] || { echo "$c -> [$output]"; false; }
  done
  rlib 'MK_REMOTE_NO_EXEMPT=1 mk_remote_targets "$1"' 'git push --dry-run origin deploy'
  [ "$output" = "branch:deploy" ]
  rlib 'MK_REMOTE_NO_EXEMPT=1 mk_remote_scan "$1"' "ssh prod.example.com 'systemctl status app'"
  [ "${output%%	*}" = "remote-mutate" ]
}

@test "strip_covered removes only covered segments" {
  mk_project "$RCFG"
  trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
  strip 'rm -rf ./build && ssh prod.example.com "systemctl restart app"' 'host:prod.example.com'
  [ "$(trim "$output")" = 'rm -rf ./build' ]
  strip 'ssh prod.example.com reboot && git push origin deploy' 'host:prod.example.com'
  [ "$(trim "$output")" = 'git push origin deploy' ]
  strip 'ssh prod.example.com reboot && git push origin deploy' 'host:prod.example.com
branch:deploy'
  [ -z "$(trim "$output")" ]
  strip 'ssh 31.210.53.162 reboot' 'host:prod.example.com'
  [ "$(trim "$output")" = 'ssh 31.210.53.162 reboot' ]
}

@test "target_valid accepts configured, rejects unknown and bad spelling" {
  mk_project "$RCFG"
  mk_runbook
  sha="$(rb_sha)"
  ok()  { valid "$1"; [ "$status" -eq 0 ] || { echo "rejected: $1"; return 1; }; }
  bad() { valid "$1"; [ "$status" -eq 1 ] || { echo "accepted: $1 ($status)"; return 1; }; }
  ok host:prod.example.com
  ok host:PROD.example.com
  ok host:31.210.53.162
  bad host:evil
  ok branch:deploy
  bad branch:main
  ok k8s
  ok k8s:x
  bad 'k8s:a b'
  ok "runbook:$RB@$sha"
  bad "runbook:$RB@0000000000000000000000000000000000000000000000000000000000000000"
  bad "runbook:$RB"
  bad "runbook:.claude/memokit/runbooks/../../../etc/passwd@$sha"
  ok pattern:fly-prod
  bad pattern:other
  bad foo
  bad ''
  rlib 'mk_remote_runbook_target "$1"' "$RB"
  [ "$output" = "runbook:$RB@$sha" ]
  rlib 'mk_remote_runbook_target "$1"' .claude/memokit/runbooks/missing.sh
  [ "$status" -eq 1 ]
}

@test "careful.sh loads remote.sh itself; fail closed when it cannot" {
  mk_project "$RCFG"
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; mk_careful_labels 'ssh prod.example.com reboot'"
  [ "$output" = "remote-mutate" ]
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; MK_LIB_DIR=/nonexistent; mk_careful_labels 'ssh prod.example.com reboot'"
  [ "$output" = "unparsed" ]
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; MK_LIB_DIR=; mk_careful_labels 'ssh prod.example.com reboot'"
  [ "$output" = "unparsed" ]
  # I6: a scan that dies half way is unparsed, not "no remote label".
  rlib 'mk_remote_scan() { exit 3; }; mk_careful_labels "$1"' 'ls -la'
  [ "$output" = "unparsed" ]
}

# Review round 1: every bypass shape the review found is labelled now.
@test "round 1: rsync/scp/sftp downloads fail closed (C1, C2)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|rsync -az ./ prod.example.com:/opt/ --exclude .git
remote-mutate|host:prod.example.com|rsync -az ./ prod.example.com:/opt/ -e ssh
remote-mutate|host:prod.example.com|rsync --exclude -n ./ prod.example.com:/opt/
remote-mutate|host:prod.example.com|rsync -e ssh\ -n ./ prod.example.com:/opt/
remote-mutate|host:prod.example.com|rsync --rsync-path='sudo /usr/local/bin/wipe' prod.example.com:/a ./b
remote-mutate|host:prod.example.com|rsync -e "ssh prod.example.com 'systemctl stop app'" other.host:/a ./b
remote-mutate|host:prod.example.com|rsync --server prod.example.com:/a ./b
remote-mutate|host:prod.example.com|scp -S ./evil prod.example.com:/a ./b
remote-mutate|host:prod.example.com|scp -o ProxyCommand=x prod.example.com:/a ./b
remote-mutate|host:prod.example.com|sftp -b batch prod.example.com:/a ./b
EOF
}

@test "round 1: ssh stdin, command options and options after the host (C3)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|echo 'rm -rf /srv' | ssh -T prod.example.com
remote-mutate|host:prod.example.com|cat x | ssh prod.example.com cat
remote-mutate|host:prod.example.com|ssh -T prod.example.com < script.sh
remote-mutate|host:prod.example.com|ssh -T prod.example.com <<'EOS'
remote-mutate|host:prod.example.com|ssh prod.example.com -T
remote-mutate|host:prod.example.com|ssh -T -o RemoteCommand=reboot prod.example.com
remote-mutate|host:prod.example.com|ssh -N -oProxyCommand=x prod.example.com
remote-mutate|host:prod.example.com|ssh -N -o 'LocalCommand reboot' prod.example.com
remote-mutate|host:prod.example.com|ssh -N -F ./cfg prod.example.com
remote-mutate|host:prod.example.com|ssh prod.example.com -F ./cfg uptime
EOF
}

@test "round 1: dry-run must be the effective last flag (C4)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy|git push origin deploy # --dry-run
deploy-push|branch:deploy|git push origin deploy -- --dry-run
deploy-push|branch:deploy|git push --dry-run --dry-run=no origin deploy
k8s-mutate|k8s|kubectl apply -f k.yaml --dry-run=client --dry-run=none
k8s-mutate|k8s|kubectl apply -f k.yaml --field-manager --dry-run=server
k8s-mutate|k8s|kubectl exec app -- sh -c reboot --dry-run=server
k8s-mutate|k8s|kubectl exec app --dry-run=server -- reboot
k8s-mutate|k8s|helm upgrade app ./chart --description --dry-run=server
k8s-mutate|k8s|kubectl apply -f k.yaml # --dry-run=server
k8s-mutate|k8s|kubectl apply -f k.yaml --dry-run
none||kubectl apply -f k.yaml --dry-run=server
none||helm upgrade app ./chart --dry-run=client
EOF
}

@test "round 1: push destinations, host spellings (C5, C6, I9)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy|git push origin main:heads/deploy
deploy-push|branch:deploy|git push origin main:refs/heads/deploy
deploy-push|branch:deploy|git push origin x:foo/deploy
remote-mutate|host:prod.example.com|ssh a@b@prod.example.com reboot
remote-mutate|host:31.210.53.162|scp f root@[31.210.53.162]:/tmp/
remote-mutate|host:prod.example.com|sftp -o Hostname=prod.example.com x
remote-mutate|host:prod.example.com|sftp -oHostname=prod.example.com x:/a ./b
remote-mutate|host:prod.example.com|ssh prod.example.com. reboot
EOF
}

@test "round 1: computed command word, every tool word, diff position (I1-I3)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|$'ssh' prod.example.com reboot
deploy-push|branch:deploy|$'git' push origin deploy
remote-mutate|host:prod.example.com|/usr/bin/ss? prod.example.com reboot
remote-mutate|host:prod.example.com|S=ssh; $S prod.example.com reboot
remote-mutate|host:prod.example.com|sudo -u root $SSH prod.example.com reboot
remote-mutate|host:prod.example.com|env -u ssh ssh -o Hostname=prod.example.com cat reboot
k8s-mutate|k8s|kubectl -n diff apply -f k.yaml
k8s-mutate|k8s|kubectl run x --image=busybox
k8s-mutate|k8s|kubectl debug node/x -it --image=busybox
none||$EDITOR notes.txt
none||kubectl --context=staging diff -f k.yaml
EOF
}

@test "round 1: read-only list trimmed (I7/I8)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|ssh prod.example.com env reboot
remote-mutate|host:prod.example.com|ssh prod.example.com find /srv -delete
remote-mutate|host:prod.example.com|ssh prod.example.com curl -X POST localhost/reset
remote-mutate|host:prod.example.com|ssh prod.example.com date -s 2020-01-01
remote-mutate|host:prod.example.com|ssh prod.example.com git log
none||ssh prod.example.com git status
none||ssh prod.example.com systemctl is-active app
EOF
}

@test "round 1: runbook paths via \$PWD and doubled slashes (I4)" {
  mk_project "$RCFG"
  mk_runbook
  check_table <<EOF
runbook|runbook:$RB@SHA|bash "\$PWD/$RB"
runbook|runbook:$RB@SHA|bash \$PWD/$RB
runbook|runbook:$RB@SHA|bash \${PWD}/$RB
runbook|runbook:$RB@SHA|bash .claude//memokit/runbooks/deploy.sh
runbook|runbook:$RB@SHA|./.claude/./memokit/runbooks/deploy.sh
runbook|runbook:$RB@unreadable|bash /elsewhere/$RB
runbook|runbook:$RB@unreadable|~/other/$RB
runbook|runbook:$RB@SHA|env bash $RB
runbook|runbook:$RB@SHA|sudo bash $RB
none||sudo -u deploy bash $RB
none||env X=1 bash $RB
EOF
}

@test "round 1: strip_covered keeps a segment whose scan was unparsed (I5)" {
  mk_project "$RCFG"
  rlib 'mk_careful_flat() { return 1; }; mk_remote_strip_covered "$1" "$2"' 'ssh prod.example.com reboot' 'host:prod.example.com'
  [ "$output" = 'ssh prod.example.com reboot' ]
}

@test "fail closed: too many segments, fork budget, foreign locale" {
  mk_project "$RCFG"
  big="ssh prod.example.com uptime"
  i=0; while [ "$i" -lt 600 ]; do big="$big
ssh prod.example.com uptime $i"; i=$((i + 1)); done
  # over MK_RM_MAX_CHARS (8 KiB): too-large, not parsed
  labels "$big"
  printf '%s\n' "$output" | grep -qx too-large
  # under 8 KiB but more than MK_RM_MAX_SEGS (40) segments, with a tool word
  # (round 4b: without one the command is not scanned at all): too-large
  # (round 4; it was unparsed past 500 before)
  big="ssh h0;"; i=1; while [ "$i" -lt 600 ]; do big="${big}echo h$i;"; i=$((i + 1)); done
  [ "${#big}" -le 8192 ]
  labels "$big"
  printf '%s\n' "$output" | grep -qx too-large
  # the same without any remote word: not bounded by remote.sh
  big=""; i=0; while [ "$i" -lt 600 ]; do big="${big}echo h$i;"; i=$((i + 1)); done
  labels "$big"
  lacks "$output" too-large
  mkdir -p "$PROJ/.claude/memokit/runbooks"
  cmd=""; i=0
  while [ "$i" -lt 10 ]; do
    printf 'echo %s\n' "$i" > "$PROJ/.claude/memokit/runbooks/r$i.sh"
    cmd="${cmd}bash .claude/memokit/runbooks/r$i.sh; "; i=$((i + 1))
  done
  targets "$cmd"
  [ "$(printf '%s\n' "$output" | grep -c '@unreadable$')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c '@[0-9a-f]\{64\}$')" -eq 8 ]
  # a foreign (non-UTF-8) locale, only where the machine has it: a missing
  # locale makes bash print a setlocale warning into the output instead
  if locale -a 2>/dev/null | grep -qi '^zh_TW\.big5$'; then
    rlib 'LC_ALL=zh_TW.Big5 mk_remote_targets "$1"' "ssh prod.example.com 'systemctl status app'"
    [ "$output" = "host:prod.example.com" ]
  fi
}

# Review round 2.
@test "round 2: download exemption needs one raw segment and no remote shell (C2)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|rsync --rsync-path='systemctl stop app && rsync' prod.example.com:/a ./b
remote-mutate|host:prod.example.com|rsync --rsync-path="reboot;rsync" prod.example.com:/a ./b
remote-mutate|host:prod.example.com|rsync --rsync-path='reboot | rsync' prod.example.com:/a ./b
remote-mutate|host:prod.example.com|rsync -n --rsync-path='reboot ; rsync' prod.example.com:/a ./b
remote-mutate|host:prod.example.com|rsync -avze ssh prod.example.com:/a ./b
remote-mutate|host:prod.example.com|scp prod.example.com:/a ./b; echo done
remote-mutate|host:prod.example.com|RSYNC_RSH="ssh prod.example.com systemctl stop app ;" rsync prod.example.com:/a ./b
remote-mutate|host:prod.example.com|X=1 scp prod.example.com:/a ./b
remote-mutate|host:prod.example.com|scp -O 'prod.example.com:/x$(reboot)' ./b
remote-mutate|host:prod.example.com|rsync 'prod.example.com:/a$(reboot)' ./b
remote-mutate|host:prod.example.com|scp 'prod.example.com:/x`reboot`' ./b
remote-mutate|host:prod.example.com|scp prod.example.com:/x ./b $X
none||scp prod.example.com:/var/log/*.log ./log/
EOF
}

@test "round 2: computed word anywhere plus a named host or branch (I1)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|S=ssh; $S -o Hostname=prod.example.com x reboot
remote-mutate|host:prod.example.com|$S -oHostName=prod.example.com x reboot
remote-mutate|host:prod.example.com|timeout 5 $S prod.example.com reboot
remote-mutate|host:prod.example.com|timeout -s KILL -k 3 5 $S prod.example.com reboot
remote-mutate|host:prod.example.com|setsid $S prod.example.com reboot
remote-mutate|host:prod.example.com|stdbuf -oL $S prod.example.com reboot
remote-mutate|host:prod.example.com|exec -a x $S prod.example.com reboot
remote-mutate|host:prod.example.com|ionice -c 3 $S prod.example.com reboot
remote-mutate|host:prod.example.com|chrt 0 $S prod.example.com reboot
remote-mutate|host:prod.example.com|doas $S prod.example.com reboot
remote-mutate|host:prod.example.com|caffeinate $S "root@prod.example.com" reboot
remote-mutate|host:prod.example.com|env -u rsync $S prod.example.com reboot
deploy-push|branch:deploy|nice -n 5 $GIT push origin deploy
deploy-push|branch:deploy|$G push origin deploy
deploy-push|branch:deploy branch:public-release|$G pr merge 12
remote-mutate|host:prod.example.com|ssh prod.example.com 'cat $HOME/app.log'
none||grep -r deploy src/*.ts
none||find . -name '*.yml' | xargs grep deploy
deploy-push|branch:deploy|echo $X deploy
EOF
}

@test "round 2: -e belongs to rsync only; --no-dry-run; a:b@host (3, 4, 5)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|xargs -e ssh prod.example.com reboot
remote-mutate|host:prod.example.com|xterm -e ssh prod.example.com reboot
remote-mutate|host:prod.example.com|foo --rsh ssh prod.example.com reboot
remote-mutate|host:prod.example.com|rsync -e ssh prod.example.com:/a ./b ; xargs -e ssh prod.example.com reboot
deploy-push|branch:deploy|git push --dry-run --no-dry-run origin deploy
remote-mutate|host:prod.example.com|rsync --dry-run --no-dry-run prod.example.com:/a ./b
k8s-mutate|k8s|kubectl apply -f k.yaml --dry-run=server --no-dry-run
remote-mutate|host:prod.example.com|ssh a:b@prod.example.com reboot
EOF
}

@test "round 2: \"\$PWD\"/ runbook path gives one hashed target (6)" {
  mk_project "$RCFG"
  mk_runbook
  check_table <<EOF
runbook|runbook:$RB@SHA|bash "\$PWD"/$RB
runbook|runbook:$RB@SHA|bash "\${PWD}"/$RB
runbook|runbook:$RB@SHA runbook:$RB@unreadable|bash '\$PWD'/$RB
EOF
  # ('$PWD' is a literal directory: the raw view gives @unreadable, which is
  # never valid, so the command is never covered; the flat view drops quotes.)
}

# Review round 3.
@test "round 3: computed verbs and subcommands (A, C)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release k8s|$G $P origin deploy
deploy-push|branch:deploy branch:public-release k8s|G=git; P=push; $G $P origin deploy
deploy-push|branch:deploy|sudo $G $P origin deploy
deploy-push|branch:deploy branch:public-release|$G push
deploy-push|branch:deploy branch:public-release|$G push --all
deploy-push|branch:deploy branch:public-release|git $P origin deploy
deploy-push|branch:deploy branch:public-release|gh pr $M 12
deploy-push|branch:deploy branch:public-release|gh $X merge 12
k8s-mutate|k8s|kubectl $V -f k.yaml
k8s-mutate|k8s|kubectl --insecure-skip-tls-verify $V -f k.yaml
k8s-mutate|k8s|helm $V app ./chart
remote-mutate|branch:deploy branch:public-release host:prod.example.com|git -c alias.x='!ssh prod.example.com reboot' x
deploy-push|branch:deploy branch:public-release|git -c core.sshCommand='ssh -i k' fetch
deploy-push|branch:deploy branch:public-release|GIT_SSH_COMMAND='ssh -i k' git fetch
none||grep -r deploy src/*.ts
none||"$CC" $CFLAGS -o x
none||$K $V -f k.yaml
none||$G $P
k8s-mutate|k8s|$K apply -f k.yaml
k8s-mutate|k8s|$K rollout restart deploy/x
none||git log --oneline
none||kubectl diff -f k.yaml
none||git push --dry-run origin deploy
none||git push origin feature
EOF
  # No deploy branch configured: a computed git verb names nothing.
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["prod.example.com"]}}'
  check_table <<'EOF'
none||git $P origin deploy
EOF
}

@test "round 3: < > and backslash in a remote download operand (B)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|scp -O 'prod.example.com:/x>/etc/passwd' ./b
remote-mutate|host:prod.example.com|scp -O "prod.example.com:/x>/etc/passwd" ./b
remote-mutate|host:prod.example.com|scp -O prod.example.com:/x\>/etc/passwd ./b
remote-mutate|host:prod.example.com|rsync 'prod.example.com:/a>/etc/passwd' ./b
remote-mutate|host:prod.example.com|rsync 'prod.example.com:/a</dev/zero' ./b
none||scp prod.example.com:/var/log/*.log ./log/
none||rsync -n -az ./ prod.example.com:/opt/app/
none||rsync -az --exclude .git prod.example.com:/a ./b
EOF
}

@test "round 3: hosts * with Hostname= and user@host behind a computed word (D)" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["*"]}}'
  check_table <<'EOF'
remote-mutate|host:x.y|S=ssh; $S -o Hostname=x.y z reboot
remote-mutate|host:x.y|$S -oHostName=x.y z reboot
remote-mutate|host:x.y|timeout 5 $S root@x.y reboot
EOF
}

@test "round 3: \$ outside single quotes ends the ssh read-only exemption (E)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|X='a;reboot'; ssh prod.example.com uptime $X
remote-mutate|host:prod.example.com|ssh prod.example.com "uptime $X"
remote-mutate|host:prod.example.com|ssh prod.example.com uptime $X
remote-mutate|host:prod.example.com|ssh prod.example.com 'cat $HOME/app.log'
none||ssh prod.example.com 'systemctl status app'
none||ssh -N prod.example.com
EOF
}

# Review round 4.
@test "round 4: no \$ at all in a read-only ssh command (1, 2)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|ssh prod.example.com 'cat $HOME/x'
remote-mutate|host:prod.example.com|ssh prod.example.com "cat $HOME/x"
remote-mutate|host:prod.example.com|X='a;reboot' sh -c 'ssh prod.example.com uptime $X'
remote-mutate|host:prod.example.com|X='a;reboot' bash -c 'ssh prod.example.com uptime $X'
remote-mutate|host:prod.example.com|X='a;reboot' eval 'ssh prod.example.com uptime $X'
remote-mutate|host:prod.example.com|ssh prod.example.com 'uptime' $'\x3b' reboot
remote-mutate|host:prod.example.com|ssh prod.example.com 'uptime' \; reboot
none||ssh prod.example.com 'systemctl status app'
none||ssh prod.example.com docker ps -a
none||ssh prod.example.com 'cat /var/log/app.log'
EOF
  # A # comment or a heredoc body cannot be told from quoted text (1).
  targets "X='a;reboot' # don't
ssh prod.example.com uptime \$X"
  [ "$output" = host:prod.example.com ] || { echo "comment: [$output]"; false; }
  targets "cat <<'EOS' >/dev/null
it's
EOS
X='a;reboot'; ssh prod.example.com uptime \$X"
  [ "$output" = host:prod.example.com ] || { echo "heredoc: [$output]"; false; }
}

@test "round 4: git config and env vectors (3)" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|branch:deploy branch:public-release host:prod.example.com|git -c alias.x='ssh prod.example.com reboot' x
deploy-push|branch:deploy branch:public-release|git -c alias.p=push p origin deploy
deploy-push|branch:deploy branch:public-release|git -calias.p=push p origin deploy
deploy-push|branch:deploy branch:public-release|git -c Alias.p=push p origin deploy
deploy-push|branch:deploy branch:public-release|git --config-env=alias.p=P p origin deploy
deploy-push|branch:deploy branch:public-release|git --config-env alias.p=P p origin deploy
deploy-push|branch:deploy branch:public-release|git -c core.gitProxy=./evil fetch
deploy-push|branch:deploy branch:public-release|git -c CORE.SSHCOMMAND=./evil fetch
deploy-push|branch:deploy branch:public-release|git -c remote.origin.uploadpack=./evil fetch
deploy-push|branch:deploy branch:public-release|git -c remote.origin.receivepack=./evil push origin feature
deploy-push|branch:deploy branch:public-release|git -c protocol.ext.allow=always fetch
deploy-push|branch:deploy branch:public-release|git -c protocol.allow=always fetch
deploy-push|branch:deploy branch:public-release|git -c $CFG push origin feature
deploy-push|branch:deploy branch:public-release|git --exec-path=./evil fetch
deploy-push|branch:deploy branch:public-release|GIT_CONFIG_PARAMETERS="'alias.p=push'" git p origin deploy
deploy-push|branch:deploy branch:public-release|GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push git p origin deploy
deploy-push|branch:deploy branch:public-release|env GIT_CONFIG_KEY_0=alias.p git p origin deploy
deploy-push|branch:deploy branch:public-release|GIT_ASKPASS=./evil git fetch
deploy-push|branch:deploy branch:public-release|GIT_EXEC_PATH=./evil git fetch
deploy-push|branch:deploy branch:public-release|GIT_EXTERNAL_DIFF=./evil git diff
deploy-push|branch:deploy branch:public-release|GIT_SSH=./evil git fetch
deploy-push|branch:deploy branch:public-release|GIT_PROXY_COMMAND=./evil git fetch
deploy-push|branch:deploy branch:public-release|git -c core.hookspath=/tmp/h push origin feature
deploy-push|branch:deploy branch:public-release|git -c core.fsmonitor=./evil status
deploy-push|branch:deploy branch:public-release|git -c core.pager=./evil log
deploy-push|branch:deploy branch:public-release|git -c credential.helper= clone x
deploy-push|branch:deploy branch:public-release|git -c url.x.insteadOf=y fetch
deploy-push|branch:deploy branch:public-release|git -c include.path=/x status
deploy-push|branch:deploy branch:public-release|git -c gpg.program=./evil commit -m x
deploy-push|branch:deploy branch:public-release|git -c gpg.x509.program=./evil commit -m x
deploy-push|branch:deploy branch:public-release|GIT_DIR=/x git push origin feature
deploy-push|branch:deploy branch:public-release|GIT_PAGER=./evil git log
deploy-push|branch:deploy branch:public-release|GIT_CONFIG_GLOBAL=/x git fetch
none||git -c color.ui=false log
none||git -c user.name=x commit -m x
none||git -c user.email=t@t commit -m x
none||git -c user.email=t@t -c user.name=t commit -m x
none||git -c User.Email=t@t -c advice.detachedHead=false -c core.autocrlf=false -c commit.gpgsign=false -c gpg.format=ssh -c log.showSignature=false -c status.short=true -c i18n.commitEncoding=utf-8 -c column.ui=never -c core.quotepath=off status
none||git --no-pager log --oneline
none||git fetch origin
none||git push origin feature
EOF
}

@test "round 4: a computed word anywhere after an unknown option (4)" {
  mk_project "$RCFG"
  check_table <<'EOF'
k8s-mutate|k8s|kubectl --insecure-skip-tls-verify x $V -f k.yaml
k8s-mutate|k8s|kubectl --foo bar baz $V
k8s-mutate|k8s|kubectl --foo bar baz *.yaml
k8s-mutate|k8s|helm --debug x $V app ./chart
k8s-mutate|k8s|kubectl $V -f k.yaml
deploy-push|branch:deploy branch:public-release|git --foo x $P origin deploy
deploy-push|branch:deploy branch:public-release|git --foo x origin $B
deploy-push|branch:deploy branch:public-release|git --no-pager --foo $P origin deploy
deploy-push|branch:deploy|git --foo push origin deploy
deploy-push|branch:deploy|git --foo val push origin deploy
deploy-push|branch:deploy branch:public-release|git $P origin deploy
deploy-push|branch:deploy branch:public-release|gh --foo x $M 12
deploy-push|branch:deploy branch:public-release|gh --foo issue list $X
none||kubectl -n ns get pods $NAME
none||kubectl --context staging get pods $NAME
none||git --no-pager log $REV
none||git -c color.ui=false log $REV
none||git -C sub log $REV
none||gh issue list --repo $R
none||gh -R x issue list $X
EOF
}

@test "round 4: gh pr / workflow with a computed verb behind options (5)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release|gh pr --repo x $M 12
deploy-push|branch:deploy branch:public-release|gh --repo x pr $M 12
deploy-push|branch:deploy branch:public-release|gh -R x workflow $W deploy.yml
deploy-push|branch:deploy branch:public-release|gh pr -R x --body "$B" merge 12
deploy-push|branch:deploy branch:public-release|gh pr --repo x merge 12
deploy-push|branch:deploy branch:public-release|gh workflow --repo x run deploy.yml
deploy-push|branch:deploy branch:public-release|gh pr view $N
deploy-push|branch:deploy branch:public-release|gh pr $M 12
none||gh pr list
none||gh pr view 12
none||gh workflow list
none||gh issue list --repo $R
EOF
}

@test "round 4: rule C verbs as substrings, command substitution, hosts by shape (6, 7)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release k8s|$(cat cmd) origin deploy
deploy-push|branch:deploy branch:public-release k8s|`cat cmd` origin deploy
deploy-push|branch:deploy branch:public-release k8s|$(cat cmd) -o x
deploy-push|branch:deploy branch:public-release k8s|"$(cat cmd)" $X
deploy-push|branch:deploy branch:public-release k8s|$G $P -o "(push)"
none||$G $P -m 'merge:' x
deploy-push|branch:deploy branch:public-release k8s|$K $V -f k.yaml "(scale)"
none||$K $V -f k.yaml x=delete
k8s-mutate|k8s|$K "delete" pod x
k8s-mutate|k8s|$K 'scale' deploy/x --replicas=0
k8s-mutate|k8s|$K patch deploy/x -p '{}'
k8s-mutate|k8s|$K exec app -- reboot
k8s-mutate|k8s|$H upgrade app ./chart
k8s-mutate|k8s|$H uninstall app
k8s-mutate|k8s|$K apply -f k.yaml
remote-mutate|host:prod.example.com|$S -oHostName=prod.example.com z reboot
remote-mutate|branch:deploy branch:public-release host:prod.example.com k8s|$S -oHostName=prod.example.com $Z reboot
deploy-push|branch:deploy branch:public-release k8s|$G $P origin deploy
none||"$CC" $CFLAGS -o x
none||$K $V -f k.yaml
none||$G $P
EOF
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["*"]}}'
  check_table <<'EOF'
remote-mutate|host:x.y k8s|$S -oHostName=x.y $Z reboot
remote-mutate|host:x.y k8s|$S $O root@x.y reboot
remote-mutate|host:x.y|S=ssh; $S -o Hostname=x.y z reboot
EOF
}

# Review round 5.
@test "round 5: exact git config allowlist; program-like keys always label (1)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release host:prod.example.com|git -c gpg.ssh.defaultKeyCommand='ssh prod.example.com reboot' commit -S -m x
deploy-push|branch:deploy branch:public-release|git -c gpg.format=ssh -c gpg.ssh.defaultKeyCommand=./evil commit -S -m x
deploy-push|branch:deploy branch:public-release|git -c GPG.SSH.DefaultKeyCommand=./evil commit -S -m x
deploy-push|branch:deploy branch:public-release|git -c gpg.ssh.program=./evil commit -S -m x
deploy-push|branch:deploy branch:public-release|git -c gpg.openpgp.program=./evil commit -m x
deploy-push|branch:deploy branch:public-release|git -c user.useConfigOnly=true commit -m x
deploy-push|branch:deploy branch:public-release|git -c sequence.editor=./evil rebase -i HEAD~2
deploy-push|branch:deploy branch:public-release|git -c diff.external=./evil diff
deploy-push|branch:deploy branch:public-release|git -c core.hookspath=/tmp/h push origin feature
deploy-push|branch:deploy branch:public-release|git -c core.sshCommand=./evil fetch
none||git -c user.email=t@t -c user.name=t commit -qm x
none||git -C repo -c user.email=t@t commit
none||git -c user.signingkey=ABC -c gpg.format=ssh -c gpg.mintrustlevel=marginal -c gpg.ssh.allowedsignersfile=/x -c gpg.ssh.revocationfile=/y -c commit.gpgsign=true -c core.quotepath=off -c core.autocrlf=false -c core.safecrlf=warn -c color.ui=auto -c advice.detachedHead=false -c log.date=iso -c status.short=true -c i18n.logOutputEncoding=utf-8 -c column.ui=never commit -m x
none||git push origin feature
EOF
}

@test "round 5: any NAME=value before git or gh labels, a few harmless names excepted (2)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release|HOME=/x git p origin deploy
deploy-push|branch:deploy branch:public-release|XDG_CONFIG_HOME=/x git push origin feature
deploy-push|branch:deploy branch:public-release|PATH=/x:$PATH git push origin feature
deploy-push|branch:deploy branch:public-release|PREFIX=/x git push origin feature
deploy-push|branch:deploy branch:public-release|SSH_AUTH_SOCK=/x git fetch
deploy-push|branch:deploy branch:public-release|EDITOR=./evil git commit
deploy-push|branch:deploy branch:public-release|env HOME=/x git log
deploy-push|branch:deploy branch:public-release|GIT_PAGER=./evil git log
deploy-push|branch:deploy branch:public-release|GIT_PAGER=cat HOME=/x git log
deploy-push|branch:deploy branch:public-release|HOME=/x gh pr list
deploy-push|branch:deploy branch:public-release|GH_CONFIG_DIR=/x gh issue list
none||LANG=C git push origin feature
none||LC_ALL=C.UTF-8 TZ=UTC TERM=dumb COLUMNS=80 LINES=24 NO_COLOR=1 git log
none||GIT_TRACE=1 GIT_TRACE_SETUP=1 git status
none||GIT_PAGER=cat git log
none||TZ=UTC gh pr list
none||git push origin feature
EOF
}

@test "round 5: --git-dir and --work-tree are GIT_DIR (3)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release|git --git-dir=/x push origin feature
deploy-push|branch:deploy branch:public-release|git --work-tree=/x push origin feature
deploy-push|branch:deploy branch:public-release|git --git-dir /x push origin feature
deploy-push|branch:deploy branch:public-release|git --work-tree /x status
deploy-push|branch:deploy branch:public-release|GIT_DIR=/x git push origin feature
none||git -C sub status
EOF
}

@test "round 5: a command substitution as the first word after a wrapper is strict (4)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release k8s|sudo $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|env $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|nice `cat cmd` origin x
deploy-push|branch:deploy branch:public-release k8s|command $(cat cmd) -o x
deploy-push|branch:deploy branch:public-release k8s|sudo -u root $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|sudo -E env -i $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|timeout 5 $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|timeout -s KILL -k 3 5 `cat cmd` origin x
deploy-push|branch:deploy branch:public-release k8s|nice -n 5 $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|chrt 0 $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|exec -a x $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|stdbuf -oL $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|X=1 sudo $(cat cmd) origin x
deploy-push|branch:deploy branch:public-release k8s|$(cat cmd) origin x
none||sudo -u root cat $(find / -name x)
none||make -j $(nproc)
EOF
}

@test "round 5: unknown git subcommands next to a deploy branch; git config writes (5)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy|git p origin deploy
deploy-push|branch:deploy branch:public-release|git config alias.p push; git p origin deploy
deploy-push|branch:deploy|export GIT_CONFIG_PARAMETERS="'alias.p=push'"; git p origin deploy
deploy-push|branch:deploy|export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push; git p origin deploy
deploy-push|branch:deploy|git p origin HEAD:deploy
deploy-push|branch:public-release|git lfs push origin public-release
deploy-push|branch:deploy branch:public-release|git p origin deploy.yml
deploy-push|branch:deploy|git send-pack origin deploy
deploy-push|branch:deploy branch:public-release|git config alias.p push
deploy-push|branch:deploy branch:public-release|git config --global alias.p push
deploy-push|branch:deploy branch:public-release|git config set alias.p push
deploy-push|branch:deploy branch:public-release|git config --global core.sshCommand ./evil
deploy-push|branch:deploy branch:public-release host:prod.example.com|git config core.sshCommand 'ssh -J prod.example.com'
deploy-push|branch:deploy branch:public-release|git config core.hooksPath /tmp/h
deploy-push|branch:deploy branch:public-release|git config --add url.x.insteadOf y
deploy-push|branch:deploy branch:public-release|git config --unset alias.p
deploy-push|branch:deploy branch:public-release|git config --remove-section alias
deploy-push|branch:deploy branch:public-release|git config -f ./cfg alias.p push
deploy-push|branch:deploy branch:public-release|git config --global --edit
deploy-push|branch:deploy branch:public-release|git config --global $KEY push
deploy-push|branch:deploy branch:public-release|git config alias.p 'push get'
deploy-push|branch:deploy branch:public-release|git config alias.p push --list
deploy-push|branch:deploy branch:public-release|git config --get alias.p push
deploy-push|branch:deploy branch:public-release|git config set --global alias.p push
none||git config list
none||git config user.name x
none||git config --global user.email t@t
none||git config --get alias.p
none||git config --get-regexp alias
none||git config --list
none||git config -l
none||git config get alias.p
none||git config list --global
none||git config --global --list
none||git p origin feature
none||git p
none||git foo
none||git log --oneline
none||git checkout deploy
none||git branch -D deploy
none||git merge deploy
none||git push origin feature
EOF
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["prod.example.com"]}}'
  check_table <<'EOF'
none||git p origin deploy
none||git config alias.p push
EOF
}

@test "round 5: gh api writes and write-shaped paths (6)" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy branch:public-release|gh api -X PUT repos/o/r/pulls/12/merge
deploy-push|branch:deploy branch:public-release|gh api --method put repos/o/r/pulls/12/merge
deploy-push|branch:deploy branch:public-release|gh api -XPOST repos/o/r/dispatches
deploy-push|branch:deploy branch:public-release|gh api --method=DELETE repos/o/r/git/refs/heads/x
deploy-push|branch:deploy branch:public-release|gh api -X Patch repos/o/r/pulls/12
deploy-push|branch:deploy branch:public-release|gh api repos/o/r/pulls/12/merge
deploy-push|branch:deploy branch:public-release|gh api -X GET repos/o/r/pulls/12/merge
deploy-push|branch:deploy branch:public-release|gh api repos/o/r/merges
deploy-push|branch:deploy branch:public-release|gh api repos/o/r/dispatches
deploy-push|branch:deploy branch:public-release|gh api repos/o/r/actions/workflows/deploy.yml/dispatches
deploy-push|branch:deploy branch:public-release|gh api repos/o/r/git/refs
deploy-push|branch:deploy branch:public-release|gh api -f ref=main repos/o/r/git/refs
deploy-push|branch:deploy branch:public-release|gh api -F ref=@f repos/o/r
deploy-push|branch:deploy branch:public-release|gh api --field ref=main repos/o/r
deploy-push|branch:deploy branch:public-release|gh api --raw-field q=x graphql
deploy-push|branch:deploy branch:public-release|gh api --input body.json repos/o/r
deploy-push|branch:deploy branch:public-release|gh api --input=body.json repos/o/r
deploy-push|branch:deploy branch:public-release|gh api -X $M repos/o/r/pulls/12
deploy-push|branch:deploy branch:public-release|gh api repos/o/r "$@"
deploy-push|branch:deploy branch:public-release|gh -R o/r api -X PUT pulls/12/merge
deploy-push|branch:deploy branch:public-release|gh --foo api $X
none||gh api repos/o/r/pulls
none||gh api repos/o/r/pulls/12
none||gh api --jq .name repos/o/r
none||gh api -H 'Accept: x' repos/o/r/issues
none||gh api --paginate repos/o/r/issues
none||gh api "repos/$OWNER/$REPO/pulls"
EOF
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["prod.example.com"]}}'
  check_table <<'EOF'
none||gh api -X PUT repos/o/r/pulls/12/merge
EOF
}

@test "round 5: rule C verbs match whole words only (7)" {
  mk_project "$RCFG"
  check_table <<'EOF'
none||$EDITOR src/push.ts
none||$PYTHON scripts/apply_migrations.py
none||"$CC" $CFLAGS -o patch_tool main.c
none||$RM delete.txt
none||$CC -o patch.o patch.c
none||$X mypush
none||cp *.txt pushes/x
none||$G $P -m 'merge:' x
none||$K $V -f k.yaml x=delete
k8s-mutate|k8s|$K "delete" pod x
k8s-mutate|k8s|$K 'scale' deploy/x --replicas=0
k8s-mutate|k8s|$K delete, pod x
k8s-mutate|k8s|$K delete\ pod x
deploy-push|branch:deploy branch:public-release k8s|$G $P -o "(push)"
deploy-push|branch:deploy branch:public-release k8s|$G $P -o {push}
deploy-push|branch:deploy branch:public-release k8s|$G $P -o [push]
deploy-push|branch:deploy branch:public-release k8s|$(cat cmd) origin deploy
deploy-push|branch:deploy|$G push origin deploy
EOF
}

@test "round 3: a separator inside quotes cannot hide a host" {
  mk_project "$RCFG"
  local c
  for c in "ssh -o 'User=x;' prod.example.com 'systemctl restart x'" \
           "ssh -o 'ProxyCommand=x|y' prod.example.com z" \
           "scp 'a;b' prod.example.com:/x" \
           "rsync -e 'ssh -p 22; rm -rf /' ./ prod.example.com:/x" \
           "ssh -o \"User=x&&y\" prod.example.com 'systemctl restart x'" \
           "ssh -o 'User=x
y' prod.example.com 'systemctl restart x'"; do
    targets "$c"
    [ "$output" = host:prod.example.com ] || { echo "targets: $c -> [$output]"; false; }
    labels "$c"
    printf '%s\n' "$output" | grep -qx remote-mutate || { echo "labels: $c -> [$output]"; false; }
  done
  # quotes that do not close around a quoted separator: unparsed (fail closed)
  labels "ssh -o 'User=x;' prod.example.com 'x"
  printf '%s\n' "$output" | grep -qx unparsed
  # no quoted separator: the second pass does not run, read-only stays exempt
  labels "ssh prod.example.com 'systemctl status app' && ls"
  lacks "$output" remote-mutate
}

# --- fix round 4: structural bounds, escaped separators, scanner gaps ---

@test "round 4: a backslash-escaped separator cannot hide a host" {
  mk_project "$RCFG"
  local c
  for c in "ssh -o User=x\\; prod.example.com 'systemctl restart x'" \
           "ssh prod.example.com\\; x" \
           "ssh -o User=x\\& prod.example.com 'systemctl restart x'" \
           "ssh -o 'User=x;' prod.example.com 'systemctl restart x'"; do
    targets "$c"
    [ "$output" = host:prod.example.com ] || { echo "targets: $c -> [$output]"; false; }
    labels "$c"
    printf '%s\n' "$output" | grep -qx remote-mutate || { echo "labels: $c -> [$output]"; false; }
  done
}

@test "round 4: structural bounds give too-large (tool words, quotes, segments)" {
  mk_project "$RCFG"
  # 33 tool words in 1.6 KB: too-large, not parsed
  c="rm -rf ./data; echo"; i=0; while [ "$i" -lt 33 ]; do c="$c ssh"; i=$((i + 1)); done
  labels "$c"
  printf '%s\n' "$output" | grep -qx too-large || { echo "33 tool words: [$output]"; false; }
  # 32 tool words (any case, a path or quotes around one): parsed normally
  c="rm -rf ./data; echo"; i=0; while [ "$i" -lt 30 ]; do c="$c ssh"; i=$((i + 1)); done
  c="$c SSH '/usr/bin/scp'"
  labels "$c"
  lacks "$output" too-large
  printf '%s\n' "$output" | grep -qx rm-recursive
  # 65 quote characters
  c="ssh prod.example.com x"; i=0; while [ "$i" -lt 32 ]; do c="$c ''"; i=$((i + 1)); done
  labels "$c"
  lacks "$output" too-large
  c="$c '"
  labels "$c"
  printf '%s\n' "$output" | grep -qx too-large || { echo "65 quotes: [$output]"; false; }
  # 41 segments (newlines count), under 8 KiB
  c="ssh prod.example.com 'systemctl restart x'"; i=0; while [ "$i" -lt 39 ]; do c="$c
echo $i"; i=$((i + 1)); done
  labels "$c"
  lacks "$output" too-large
  printf '%s\n' "$output" | grep -qx remote-mutate
  c="$c
echo last"
  labels "$c"
  printf '%s\n' "$output" | grep -qx too-large || { echo "41 segments: [$output]"; false; }
  # the 4 KB single segment of tool words from the review: too-large, fast
  c="ssh prod.example.com touch"; while [ "${#c}" -lt 4080 ]; do c="$c ssh"; done
  s=$SECONDS
  labels "$c"
  [ $((SECONDS - s)) -le 2 ] || { echo "took $((SECONDS - s)) s"; false; }
  printf '%s\n' "$output" | grep -qx too-large
}

@test "round 4b: the bounds apply only when a remote label is possible (heredocs stay unlabelled)" {
  mk_project "$RCFG"
  # a 60-line heredoc writing a file: no tool word, no host, no branch, no
  # runbook dir, so remote.sh neither scans nor bounds it
  c="cat > docs/x.md <<'EOF'"; i=0
  while [ "$i" -lt 60 ]; do c="$c
# line $i: 'quoted' \"text\" with; separators && pipes | and words"; i=$((i + 1)); done
  c="$c
EOF"
  labels "$c"
  [ -z "$output" ] || { echo "heredoc labelled: [$output]"; false; }
  targets "$c"
  [ -z "$output" ]
  # round 5: a computed-word character ($ ` * ? [) is a trigger, so the same
  # heredoc with a $var is scanned and, past 40 segments, too-large
  labels "${c//words/\$vars}"
  printf '%s\n' "$output" | grep -qx too-large
  # the same heredoc with one remote line: labelled or too-large, never clean
  labels "ssh prod.example.com reboot
$c"
  printf '%s\n' "$output" | grep -qxE 'remote-mutate|too-large' || { echo "[$output]"; false; }
  # a long printf of 20 KB with no remote word: no remote label (careful's
  # own 64 KiB bound is untouched)
  pad="$(head -c 20000 /dev/zero | tr '\0' a)"
  labels "printf '%s' '$pad' > docs/big.txt"
  lacks "$output" too-large
  lacks "$output" unparsed
  # a deploy branch name or a host name alone makes the command relevant
  c="echo deploy"; i=0; while [ "$i" -lt 41 ]; do c="$c
echo $i"; i=$((i + 1)); done
  labels "$c"
  printf '%s\n' "$output" | grep -qx too-large
  # a computed word next to a verb is relevant too (rule C still labels it)
  labels '$K apply -f k.yaml'
  printf '%s\n' "$output" | grep -qx k8s-mutate
}

@test "round 5: the relevance gate sees the normalised text (quotes, backslashes, .exe, continuations)" {
  mk_project "$RCFG"
  mkdir -p "$PROJ/.claude/memokit/runbooks"
  printf '#!/bin/sh\nsystemctl restart x\n' > "$PROJ/.claude/memokit/runbooks/restart.sh"
  rsha="$({ sha256sum 2>/dev/null || shasum -a 256; } < "$PROJ/.claude/memokit/runbooks/restart.sh" | cut -d' ' -f1)"
  check_table <<EOF
remote-mutate|host:prod.example.com|s\\sh pro\\d.example.com 'systemctl restart x'
remote-mutate|host:prod.example.com|s""sh pr""od.example.com 'systemctl restart x'
remote-mutate|host:31.210.53.162|s\\sh 31.210.53\\.162 'systemctl restart x'
deploy-push|branch:deploy|gi\\t push origin de\\ploy
deploy-push|branch:deploy|g""it push origin dep""loy
deploy-push|branch:deploy|gi\\t push origin HEAD:refs/heads/dep""loy
deploy-push|branch:deploy branch:public-release|g\\h pr merge 12
k8s-mutate|k8s|kube\\ctl apply -f k.yaml
k8s-mutate|k8s:staging|kube""ctl --context staging apply -f k.yaml
k8s-mutate|k8s|he\\lm upgrade app ./chart
k8s-mutate|k8s|kubectl.exe apply -f k.yaml
k8s-mutate|k8s|helm.exe upgrade app ./chart
runbook|runbook:.claude/memokit/runbooks/restart.sh@$rsha|bash .claude//memokit/runbooks/restart.sh
runbook|runbook:.claude/memokit/runbooks/restart.sh@$rsha|bash .claude/./memokit/runbooks/restart.sh
runbook|runbook:.claude/memokit/runbooks/restart.sh@$rsha|sh ./.claude//memokit/runbooks/restart.sh
runbook|runbook:.claude/memokit/runbooks/restart.sh@$rsha|.claude//memokit/runbooks/restart.sh
EOF
  # a backslash-newline continuation splitting the tool word and the host
  targets "ss\\
h pro\\
d.example.com 'systemctl restart x'"
  [ "$output" = host:prod.example.com ] || { echo "continuation: [$output]"; false; }
  labels "ss\\
h pro\\
d.example.com 'systemctl restart x'"
  printf '%s\n' "$output" | grep -qx remote-mutate
  # a 63 KB heredoc with none of the triggers: not scanned, fast
  pad="$(head -c 63000 /dev/zero | tr '\0' a)"
  s=$SECONDS
  labels "cat > docs/big.md <<'EOF'
$pad
EOF"
  [ $((SECONDS - s)) -le 1 ] || { echo "took $((SECONDS - s)) s"; false; }
  lacks "$output" too-large
  lacks "$output" unparsed
}

@test "round 5: ANSI-C quoting is decoded before matching" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|$'\x73sh' $'prod\x2eexample.com' 'systemctl restart x'
remote-mutate|host:prod.example.com|$'\163sh' prod.example.com 'systemctl restart x'
k8s-mutate|k8s|$'ku\x62ectl' apply -f k.yaml
deploy-push|branch:deploy branch:public-release|$'g\x69t' push origin $'dep\x6coy'
EOF
  # (the last row: the decoded view names deploy, and the raw view's
  # computed command word still names every deploy branch, fail closed)
}

@test "round 4: the parse is bounded inside the structural bounds (32 tool words, 2000 tokens)" {
  mk_project "$RCFG"
  c="rsync"; i=0; while [ "$i" -lt 31 ]; do c="$c rsync"; i=$((i + 1)); done
  while [ "${#c}" -lt 4090 ]; do c="$c a"; done
  c="$c prod.example.com:/x"
  s=$SECONDS
  labels "$c"
  [ $((SECONDS - s)) -le 2 ] || { echo "took $((SECONDS - s)) s"; false; }
  printf '%s\n' "$output" | grep -qxE 'remote-mutate|unparsed|too-large' || { echo "[$output]"; false; }
}

@test "round 4: scanner labels sudo bash <runbook> and case-insensitive deploy branches" {
  mk_project "$RCFG"; mk_runbook
  check_table <<'EOF'
runbook|runbook:.claude/memokit/runbooks/deploy.sh@SHA|sudo bash .claude/memokit/runbooks/deploy.sh
runbook|runbook:.claude/memokit/runbooks/deploy.sh@SHA|env sh .claude/memokit/runbooks/deploy.sh
runbook|runbook:.claude/memokit/runbooks/deploy.sh@SHA|sudo .claude/memokit/runbooks/deploy.sh
deploy-push|branch:public-release|git push origin deploy:PUBLIC-RELEASE
deploy-push|branch:deploy|git push origin DEPLOY
deploy-push|branch:deploy|git push origin HEAD:refs/heads/Deploy
EOF
}

# --- 0.8.0 final wave ---

@test "final C3: a single-quoted string ending in a dollar sign is text, not an ANSI-C span" {
  mk_project "$RCFG"
  local c
  for c in "grep 'foo\$' file.txt" "grep -c 'end\$' README.md" "grep -n 'x\$' -r src" \
           "sed -n '/x\$/p' f" "echo \"\$'x\" 'y'" "grep 'a\$' f && echo 'b\$'"; do
    labels "$c"
    lacks "$output" unparsed || { echo "$c -> [$output]"; return 1; }
    if printf '%s\n' "$output" | grep -qxE 'deploy-push|remote-mutate|k8s-mutate|runbook'; then echo "$c -> [$output]"; return 1; fi
  done
  # ANSI-C spans outside quotes are still decoded
  check_table <<'EOF'
remote-mutate|host:prod.example.com|ssh $'\x70rod.example.com' reboot
remote-mutate|host:prod.example.com|$'\x73sh' prod.example.com reboot
remote-mutate|host:prod.example.com|grep 'x$' f; ssh $'prod\x2eexample.com' reboot
EOF
  # an escaped dollar sign does not open a span
  labels "echo \\\$'x' y"
  lacks "$output" unparsed
}

@test "final C3 addendum: the quote-aware view never hides a remote command" {
  mk_project "$RCFG"
  local c nl='
'
  # 1: a quote inside a # comment does not swallow the next line
  c="echo \$'a' #'${nl}ssh prod.example.com 'rm -rf /tmp/x'"
  labels "$c"
  printf '%s\n' "$output" | grep -qx remote-mutate || { echo "comment: [$output]"; false; }
  run_hook guard-destructive.sh "$(bash_payload "$c")"
  [ "$(decision)" = deny ]
  # the comment is skipped by the decoder: no open quote, no unparsed
  rlib '_mk_rm_ansi "$1" TOK 1 | tail -n 1' "$c"
  [ "$output" = TOK ]
  # 2: a lone quote in a heredoc body, a remote command after the terminator
  c="cat > f <<'EOF'${nl}it's \$'x'${nl}EOF${nl}ssh prod.example.com 'rm -rf /tmp/x'"
  labels "$c"
  printf '%s\n' "$output" | grep -qx remote-mutate || { echo "heredoc: [$output]"; false; }
  run_hook guard-destructive.sh "$(bash_payload "$c")"
  [ "$(decision)" = deny ]
  # an open quote at the end: the quote-aware decoder fails closed
  rlib '_mk_rm_ansi "$1" TOK 1 | tail -n 1' "it's \$'x'"
  [ "$output" != TOK ]
  # 3: what the quote-unaware decoding labels stays labelled when the
  # quote-aware view reads the span as quoted text (an apostrophe in an
  # unquoted heredoc body balances the quotes)
  c="cat <<EOF${nl}it's${nl}EOF${nl}ssh \$'\\x70rod.example.com' reboot 'x"
  targets "$c"
  printf '%s\n' "$output" | grep -qx host:prod.example.com || { echo "old view: [$output]"; false; }
  run_hook guard-destructive.sh "$(bash_payload "$c")"
  [ "$(decision)" = deny ]
}

@test "final C3 addendum 2: escaped # is no comment, a cut hiding a span fails closed, a failed pass is unparsed" {
  mk_project "$RCFG"
  local c stub
  # 1: a # after an escaped blank is not a comment: the quote after it counts
  c="echo \$'q' a\\ #'; ssh prod.example.com 'rm -rf /tmp/x'"
  rlib '_mk_rm_ansi "$1" TOK 1 | tail -n 1' "$c"
  [ "$output" != TOK ] || { echo "escaped # read as a comment"; false; }
  labels "$c"
  printf '%s\n' "$output" | grep -qx remote-mutate || { echo "[$output]"; false; }
  run_hook guard-destructive.sh "$(bash_payload "$c")"
  [ "$(decision)" = deny ]
  # an unescaped one still is (the quote inside it does not count)
  rlib '_mk_rm_ansi "$1" TOK 1 | tail -n 1' "echo \$'q' a #'"
  [ "$output" = TOK ]
  # 2: a comment cut that leaves a dollar-quote behind fails closed
  rlib '_mk_rm_ansi "$1" TOK 1 | tail -n 1' "ls # \$'\\x70rod.example.com'"
  [ "$output" != TOK ]
  labels "ssh x # \$'\\x70rod.example.com'"
  printf '%s\n' "$output" | grep -qx unparsed || { echo "[$output]"; false; }
  # 3: an awk that fails in the quote-unaware pass alone gives unparsed;
  # a span that pass cannot close (grep 'foo$') is no failure
  stub="$BATS_TEST_TMPDIR/stub"; mkdir -p "$stub"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = qa=0 ] && exit 1; done\nexec %s "$@"\n' "$(command -v awk)" > "$stub/awk"
  chmod +x "$stub/awk"
  PATH="$stub:$PATH" labels "ssh \$'\\x70rod.example.com' reboot"
  printf '%s\n' "$output" | grep -qx unparsed || { echo "stub: [$output]"; false; }
  labels "grep 'foo\$' file.txt"
  lacks "$output" unparsed
}

@test "final C3: guard-destructive lets the grep anchor through with remote configured" {
  mk_project "$RCFG"
  local c
  for c in "grep 'foo\$' file.txt" "grep -c 'end\$' README.md"; do
    run_hook guard-destructive.sh "$(bash_payload "$c")"
    [ -z "$output" ] || { echo "$c -> $(reason | cut -c1-120)"; return 1; }
  done
}

@test "final I4: ANSI-C \\u, \\U and NUL are decoded as bash decodes them; unknown escapes fail closed" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|ssh $'\u0070rod.example.com' reboot
remote-mutate|host:prod.example.com|ssh $'\U00000070rod.example.com' reboot
remote-mutate|host:prod.example.com|ssh $'prod.example.com\0junk' reboot
remote-mutate|host:prod.example.com|ssh $'prod.example.com\x00junk' reboot
remote-mutate|host:prod.example.com|ssh $'prod.example.com\u0000x' reboot
EOF
  # with "*" the decoded host itself is a target (the NUL ends it); the raw
  # $'...' spelling is shell-built text, host:(computed), so no window holds it
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["*"]}}'
  check_table <<'EOF'
remote-mutate|host:(computed) host:x.y|ssh $'x.y\0junk' reboot
remote-mutate|host:(computed) host:x.y|ssh $'x\x2ey\x00junk' reboot
EOF
  mk_project "$RCFG"
  local c
  for c in "ssh \$'\\cprod.example.com' reboot" "ssh \$'\\u00e7prod.example.com' reboot" \
           "ssh \$'\\qprod.example.com' reboot" "ssh \$'\\xprod.example.com' reboot"; do
    labels "$c"
    printf '%s\n' "$output" | grep -qx unparsed || { echo "$c -> [$output]"; return 1; }
  done
}

@test "final I1: with hosts * a computed ssh/scp/rsync destination is a non-coverable remote target (host:(computed))" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"remote":{"hosts":["*"]}}'
  check_table <<'EOF'
remote-mutate|host:(computed)|ssh $H reboot
remote-mutate|host:(computed)|ssh "$H" reboot
remote-mutate|host:(computed)|ssh root@$H reboot
remote-mutate|host:(computed)|ssh $(cat h) reboot
remote-mutate|host:(computed)|ssh ${H} reboot
remote-mutate|host:(computed)|ssh $H cat /etc/x
remote-mutate|host:(computed)|scp app.tgz $H:/srv/
remote-mutate|host:(computed)|rsync -az ./ root@$H:/opt/app/
remote-mutate|host:any.host|ssh any.host reboot
EOF
  valid "host:(computed)"
  [ "$status" -ne 0 ]
  # the guard denies with the ordinary code (one exact re-run), never a
  # window plan
  run_hook guard-destructive.sh "$(bash_payload 'ssh $H reboot')"
  [ "$(decision)" = deny ]
  reason | grep -qF 'remote-mutate: destructive command blocked' || { echo "$(reason | cut -c1-160)"; false; }
  run_hook guard-subagent-authority.sh "$(bash_payload 'ssh $H reboot' agent-1)"
  [ "$(decision)" = deny ]
  # a configured host list keeps the documented text-matching limit
  mk_project "$RCFG"
  check_table <<'EOF'
none||ssh $H reboot
EOF
}

@test "final I2: subtree push, http-push, send-pack and p4 submit are pushes" {
  mk_project "$RCFG"
  check_table <<'EOF'
deploy-push|branch:deploy|git subtree push --prefix=x origin deploy
deploy-push|branch:deploy|git subtree push -P x origin deploy
deploy-push|branch:deploy|git send-pack origin deploy
deploy-push|branch:deploy branch:public-release|git http-push https://x/y.git deploy
deploy-push|branch:deploy branch:public-release|git p4 submit
none||git subtree split --prefix=x
none||git p4 sync
EOF
}

@test "final M9: the read-only ssh rule needs one segment; a quoted or escaped separator is not read-only" {
  mk_project "$RCFG"
  check_table <<'EOF'
remote-mutate|host:prod.example.com|ssh prod.example.com cat x '&&' rm -rf /srv
remote-mutate|host:prod.example.com|ssh prod.example.com cat x '|' sh
remote-mutate|host:prod.example.com|ssh prod.example.com cat x \; rm -rf /srv
remote-mutate|host:prod.example.com|ssh prod.example.com cat x ';' rm -rf /srv
remote-mutate|host:prod.example.com|ssh prod.example.com "cat x && rm -rf /srv"
none||ssh prod.example.com cat /etc/hostname
EOF
}

@test "final I3: NAME+=value before git counts as an environment word (no dry-run exemption)" {
  mk_project "$RCFG"
  labels "GIT_SSH_COMMAND+='; touch /tmp/pwn' git push --dry-run origin deploy"
  printf '%s\n' "$output" | grep -qx deploy-push || { echo "[$output]"; false; }
  targets "GIT_SSH_COMMAND+='; touch /tmp/pwn' git push --dry-run origin deploy"
  printf '%s\n' "$output" | grep -qx branch:deploy || { echo "[$output]"; false; }
  labels "GIT_SSH_COMMAND='x' git push --dry-run origin deploy"
  printf '%s\n' "$output" | grep -qx deploy-push
}
