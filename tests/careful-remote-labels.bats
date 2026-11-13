#!/usr/bin/env bats
load helpers
load careful-remote-helpers

# 0.8.0 Part A: remote labels and targets (lib/remote.sh basics).

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
