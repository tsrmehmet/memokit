#!/usr/bin/env bats
load helpers
load careful-remote-helpers

# Review rounds 3 to 5.

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

