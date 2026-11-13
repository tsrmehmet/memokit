#!/usr/bin/env bats
load helpers
load careful-remote-helpers

# 0.8.0 final wave.

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
