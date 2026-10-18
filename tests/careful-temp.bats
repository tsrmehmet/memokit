#!/usr/bin/env bats
load helpers

# guard-destructive.sh lets a recursive rm through without an approval code
# only inside the current session's scratchpad/ or of a whole stale sibling
# temp entry, and only when the whole command is one simple rm invocation.

# tp CMD -- Bash payload carrying the fixture session's id and transcript.
tp() {
  jq -nc --arg c "$1" --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s,transcript_path:$t}'
}
allowed() {
  run_hook guard-destructive.sh "$(tp "$1")"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "expected allow: $1 -> $output"; return 1; }
}
denied() {
  run_hook guard-destructive.sh "$(tp "$1")"
  [ "$(decision)" = "deny" ] || { echo "expected deny: $1 -> [$output]"; return 1; }
  reason | grep -q 'rm-recursive' || { echo "no rm-recursive label: $1 -> $(reason)"; return 1; }
}
uuid() { printf '%08d-aaaa-bbbb-cccc-%012d' "$1" "$1"; }

setup() {
  mk_project
  mk_temp_tree
  mkdir -p "$TT_SP/rv10a/sub" "$TT_SP/mut.1" "$TT_SP/mut.2" "$TT_SP/real/Documents" "$TROOT/outside"
  : > "$TT_SP/rv10a/sub/f"
  STALE="$(uuid 1)"; FRESH="$(uuid 2)"; OTHER="$(uuid 3)"
  mkdir -p "$TT_PROJ/$STALE/scratchpad" "$TT_PROJ/$FRESH/scratchpad" "$TT_ROOT/-other-proj/$OTHER/scratchpad/x"
  : > "$TT_TDIR/$STALE.jsonl"; touch -t 202001010000 "$TT_TDIR/$STALE.jsonl"
  : > "$TT_TDIR/$FRESH.jsonl"; touch -t 203001010000 "$TT_TDIR/$FRESH.jsonl"
}

@test "temp rm: direct scratchpad children, globs in the name, a stale sibling, quoted, continued" {
  allowed "rm -rf $TT_SP/rv10a"
  allowed "rm -rf $TT_SP/mut.*"
  allowed "rm -rf $TT_SP/rv10a $TT_SP/mut.1"
  allowed "rm -rf $TT_SP/rv1?a $TT_SP//rv10a"
  allowed "rm -rf $TT_PROJ/$STALE"
  allowed "rm -rf \"$TT_SP/rv10a\""
  allowed "rm -rf '$TT_SP/rv10a'"
  allowed "/bin/rm -r -f -- $TT_SP/rv10a"
  allowed "rm --recursive --force $TT_SP/rv10a"
  allowed "$(printf 'rm -rf \\\n  %s' "$TT_SP/rv10a")"
  allowed "  rm -rf $TT_SP/rv10a  "
  # the logical spelling of the temp root ($MEMOKIT_TEMP_ROOT, through symlinks)
  allowed "rm -rf $MEMOKIT_TEMP_ROOT/$TT_SLUG/$TT_SID/scratchpad/rv10a"
  # a guard only: nothing was deleted
  [ -f "$TT_SP/rv10a/sub/f" ]; [ -d "$TT_PROJ/$STALE" ]
}

@test "temp rm: the /tmp spelling of a /private/tmp temp root" {
  # A fixture of our own directly under /tmp (never under claude-<uid>).
  BATS_TMPDIR=/tmp mk_temp_tree
  mkdir -p "$TT_SP/rv10a"
  case "$TT_SP" in
    /private/tmp/*) t="/tmp/${TT_SP#/private/tmp/}" ;;
    *) t="$TT_SP" ;;
  esac
  ok=0; allowed "rm -rf $t/rv10a" && allowed "rm -rf $TT_SP/rv10a" && ok=1
  rm -rf "$TROOT"
  [ "$ok" -eq 1 ]
}

@test "temp rm: unsafe targets are still denied" {
  touch -t 202001010000 "$TT_TDIR/$TT_SID.jsonl"
  # shellcheck disable=SC2016
  for c in \
    "rm -rf $TT_SP/rv10a $PROJ/src" \
    'rm -rf "$S"/mut.*' \
    "rm -rf \$S/mut.*" \
    "rm -rf $TT_SESS" \
    "rm -rf $TT_SESS/" \
    "rm -rf $TT_SESS/tasks" \
    "rm -rf $TT_SP" \
    "rm -rf $TT_SP/" \
    "rm -rf $TT_PROJ" \
    "rm -rf $TT_ROOT" \
    "rm -rf $TT_PROJ/$FRESH" \
    "rm -rf $TT_PROJ/$STALE/*" \
    "rm -rf $TT_PROJ/$STALE/" \
    "rm -rf $TT_PROJ/*" \
    "rm -rf $TT_SP/../../.." \
    "rm -rf $TT_SP/rv10a/../../tasks" \
    "rm -rf $TT_ROOT/-other-proj/$OTHER/scratchpad/x" \
    "rm -rf $TT_ROOT/-other-proj/$OTHER" \
    "rm -rf ~/x" \
    "rm -rf $TT_SP/~x" \
    "rm -rf scratchpad/x" \
    "rm -rf -- -x $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a -x" \
    "rm -rf $TT_SP/{rv10a,..}" \
    "rm -rf \"$TT_SP/rv10a\"x" \
    "rm -rf \"$TT_SP/rv10a" \
    "rm -rf \"\"" \
    "rm -rf"; do
    denied "$c"
  done
}

@test "temp rm: compound commands never get the exemption (S3)" {
  # The symlink swap: every target passes a check of the current filesystem,
  # yet the last rm would follow the new link out of the scratchpad.
  denied "rm -rf $TT_SP/real && ln -s ~ $TT_SP/real && rm -rf $TT_SP/real/Documents"
  denied "rm -rf $TT_SP/real && ln -s $TROOT/outside $TT_SP/real && rm -rf $TT_SP/real/Documents"
  # the direct child as a lone rm is allowed; the deeper target never is
  # (an earlier background job could swap real/ for a link at any time)
  allowed "rm -rf $TT_SP/real"
  denied "rm -rf $TT_SP/real/Documents"
  # shellcheck disable=SC2016
  for c in \
    "rm -rf $TT_SP/rv10a && echo done" \
    "rm -rf $TT_SP/rv10a; echo done" \
    "echo x; rm -rf $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a || true" \
    "rm -rf $TT_SP/rv10a | cat" \
    "rm -rf $TT_SP/rv10a &" \
    "rm -rf $TT_SP/rv10a&" \
    "$(printf 'rm -rf %s\necho x' "$TT_SP/rv10a")" \
    "$(printf 'rm -rf %s\nrm -rf %s' "$TT_SP/rv10a" "$TT_SP/mut.1")" \
    "$(printf '\nrm -rf %s' "$TT_SP/rv10a")" \
    "(rm -rf $TT_SP/rv10a)" \
    "{ rm -rf $TT_SP/rv10a; }" \
    "echo \$(rm -rf $TT_SP/rv10a)" \
    "echo \`rm -rf $TT_SP/rv10a\`" \
    "rm -rf $TT_SP/rv10a > /dev/null" \
    "rm -rf $TT_SP/rv10a >/dev/null" \
    "rm -rf $TT_SP/rv10a 2>/dev/null" \
    "rm -rf $TT_SP/rv10a < /dev/null" \
    "rm -rf <(true) $TT_SP/rv10a" \
    "xargs rm -rf $TT_SP/rv10a" \
    "find $TT_SP -name rv10a -exec rm -rf $TT_SP/rv10a \\;" \
    "env rm -rf $TT_SP/rv10a" \
    "sudo rm -rf $TT_SP/rv10a" \
    "command rm -rf $TT_SP/rv10a" \
    "builtin rm -rf $TT_SP/rv10a" \
    "exec rm -rf $TT_SP/rv10a" \
    "X=1 rm -rf $TT_SP/rv10a" \
    "\\rm -rf $TT_SP/rv10a" \
    "./rm -rf $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a # note" \
    "! rm -rf $TT_SP/rv10a" \
    "rm -rf $TT_SP/rv10a \\\\" \
    "$(printf "rm -rf '%s\\\\\nx'" "$TT_SP/rv10a")"; do
    denied "$c"
  done
}

@test "temp rm: without transcript_path, or no temp tree found, behaviour is unchanged" {
  for p in \
    "$(jq -nc --arg c "rm -rf /tmp/x" --arg cwd "$PROJ" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}')" \
    "$(jq -nc --arg c "rm -rf $TT_SP/rv10a" --arg cwd "$PROJ" --arg s "$TT_SID" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s}')" \
    "$(jq -nc --arg c "rm -rf $TT_SP/rv10a" --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID.jsonl" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,transcript_path:$t}')"; do
    run_hook guard-destructive.sh "$p"
    [ "$(decision)" = "deny" ] || { echo "expected deny: $p"; false; }
  done
  # another session's id: that session's scratchpad is not ours
  run_hook guard-destructive.sh "$(jq -nc --arg c "rm -rf $TT_SP/rv10a" --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$FRESH" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s,transcript_path:$t}')"
  [ "$(decision)" = "deny" ]
  # temp root not found
  MEMOKIT_TEMP_ROOT="$TROOT/nowhere" run_hook guard-destructive.sh "$(tp "rm -rf $TT_SP/rv10a")"
  [ "$(decision)" = "deny" ]
  # safelisted build dirs and the approval flow still work as before
  allowed "rm -rf node_modules dist"
  run_hook guard-destructive.sh "$(tp "rm -rf $PROJ/src")"
  [ "$(decision)" = "deny" ]
  code="$(reason | grep -oE "'(onay|approve) [0-9a-f]{6}'" | grep -oE '[0-9a-f]{6}')"
  run_hook inject-rules.sh "$(prompt_payload "onay $code")"
  allowed "rm -rf $PROJ/src"
}

@test "temp rm: other destructive labels in the same command still deny" {
  run_hook guard-destructive.sh "$(tp "rm -rf $TT_SP/careful-grants")"
  [ "$(decision)" = "deny" ]
  mk_project "$(printf '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en","careful":{"patterns":[{"match":"rv10a","label":"no-rv"}]}}')"
  run_hook guard-destructive.sh "$(tp "rm -rf $TT_SP/rv10a")"
  [ "$(decision)" = "deny" ]; reason | grep -q 'no-rv'
}

@test "temp rm: the exemption needs the single-rm check, not only an initialised temp tree" {
  # Library level: mk_careful_labels after mk_temp_init still refuses a
  # compound command, and _mk_cf_rm on its own never consults the exemption.
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; . '$HOOKS/lib/temp.sh'
    mk_resolve_root '{}'; mk_load_config >/dev/null; mk_temp_init \"\$1\" || exit 9
    echo \"A[\$(mk_careful_labels \"rm -rf \$2/rv10a\")]\"
    echo \"B[\$(mk_careful_labels \"rm -rf \$2/rv10a; true\")]\"
    _mk_cf_rm \"rm -rf \$2/rv10a\" && echo C" _ "$TT_PAYLOAD" "$TT_SP"
  [ "$status" -eq 0 ]
  [ "$output" = "A[]
B[rm-recursive]
C" ]
}

@test "temp rm (fix 1): only direct scratchpad children; no zsh ^ negation, no [ ] class" {
  mkdir -p "$TT_SP/^x/y" "$TT_PROJ/^stale" "$TT_PROJ/zzz"
  ln -s "$TROOT/outside" "$TT_SP/link"
  touch -t 202001010000 "$TT_PROJ/^stale" "$TT_PROJ/zzz"
  for c in \
    "rm -rf $TT_SP/rv10a/sub" \
    "rm -rf $TT_SP/rv10a/" \
    "rm -rf $TT_SP/rv10a//" \
    "rm -rf $TT_SP/real/Documents" \
    "rm -rf $TT_SP/link/Documents" \
    "rm -rf $TT_SP/*/sub" \
    "rm -rf $TT_SP/^x" \
    "rm -rf $TT_SP/^x/y" \
    "rm -rf $TT_SP/^foo/Documents" \
    "rm -rf $TT_SP/rv^x" \
    "rm -rf $TT_SP/[r]v10a" \
    "rm -rf $TT_SP/**" \
    "rm -rf $TT_SP/***" \
    "rm -rf $TT_SP/rv**" \
    "rm -rf $TT_PROJ/^stale" \
    "rm -rf $TT_PROJ/^zzz" \
    "rm -rf $TT_PROJ/[z]zz"; do
    denied "$c"
  done
  allowed "rm -rf $TT_SP/link"
}

@test "temp rm (fix 3): a NUL in the command is denied" {
  for c in "rm -rf $TT_SESS" "rm -rf $TT_SP/rv10a" "ls"; do
    run_hook guard-destructive.sh "$(jq -nc --arg c "$c" --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" \
      '{tool_name:"Bash",tool_input:{command:($c + "\u0000/scratchpad/a")},cwd:$cwd,session_id:$s,transcript_path:$t}')"
    [ "$(decision)" = "deny" ] || { echo "expected deny for NUL after: $c -> [$output]"; false; }
    reason | grep -q 'NUL' || { echo "reason: $(reason)"; false; }
  done
}

@test "temp rm (fix 2): no '=' (zsh EQUALS / MAGIC_EQUAL_SUBST) and no '!' (history) in targets" {
  mkdir -p "$TT_PROJ/x==y" "$TT_PROJ/a!b"
  touch -t 202001010000 "$TT_PROJ/x==y" "$TT_PROJ/a!b"
  for c in \
    "rm -rf $TT_SP/x==cmd" \
    "rm -rf $TT_SP/=cmd" \
    "rm -rf $TT_SP/a=b" \
    "rm -rf $TT_SP/x=" \
    "rm -rf $TT_PROJ/x==y" \
    "rm -rf $TT_SP/x!!" \
    "rm -rf $TT_SP/!x" \
    "rm -rf $TT_PROJ/a!b"; do
    denied "$c"
  done
  allowed "rm -rf $TT_SP/rv10a $TT_SP/mut.*"
}

@test "temp rm: a subagent-shaped transcript_path keeps the exemption" {
  mkdir -p "$TT_TDIR/$TT_SID/subagents"
  : > "$TT_TDIR/$TT_SID/subagents/agent-a1b2c3.jsonl"
  sp() {
    jq -nc --arg c "$1" --arg cwd "$PROJ" --arg t "$TT_TDIR/$TT_SID/subagents/agent-a1b2c3.jsonl" --arg s "$TT_SID" \
      '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s,transcript_path:$t,agent_id:"a1b2c3"}'
  }
  run_hook guard-destructive.sh "$(sp "rm -rf $TT_SP/rv10a")"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "expected allow -> $output"; false; }
  run_hook guard-destructive.sh "$(sp "rm -rf $TT_PROJ/$STALE")"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "expected allow stale -> $output"; false; }
  # still not a blank cheque
  for c in "rm -rf $TT_SP" "rm -rf $TT_PROJ/$FRESH" "rm -rf $TT_SP/rv10a/sub" "rm -rf $TT_TDIR"; do
    run_hook guard-destructive.sh "$(sp "$c")"
    [ "$(decision)" = "deny" ] || { echo "expected deny: $c -> [$output]"; false; }
  done
}

@test "temp rm: a world-writable temp root disables the exemption" {
  allowed "rm -rf $TT_SP/rv10a"
  chmod 777 "$TT_ROOT"
  denied "rm -rf $TT_SP/rv10a"
  chmod 700 "$TT_ROOT"
  allowed "rm -rf $TT_SP/rv10a"
}
