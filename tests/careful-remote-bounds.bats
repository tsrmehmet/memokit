#!/usr/bin/env bats
load helpers
load careful-remote-helpers

# Fix round 4: structural bounds, escaped separators, scanner gaps.

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

