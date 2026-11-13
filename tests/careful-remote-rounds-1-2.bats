#!/usr/bin/env bats
load helpers
load careful-remote-helpers

# Review rounds 1 and 2.

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

