#!/usr/bin/env bats
load helpers

keys() { grep -o '^MK_T_[A-Z0-9_]*' "$HOOKS/messages/$1.sh" | sort; }

@test "en and tr define the same keys" {
  diff <(keys en) <(keys tr)
}

@test "every mk_msg call uses a defined key" {
  for k in $(grep -oh 'mk_msg [A-Z0-9_]*' "$HOOKS"/*.sh 2>/dev/null | awk '{print $2}' | sort -u); do
    grep -q "^MK_T_${k}=" "$HOOKS/messages/en.sh" || { echo "missing $k"; false; }
  done
}

@test "templates are safe" {
  for f in en tr; do
    run grep -nE '^MK_T_[A-Z0-9_]*=.*[$`]' "$HOOKS/messages/$f.sh"
    [ "$status" -ne 0 ]
    # _STATIC templates are printed into hand-written JSON: no backslash (hence no \") allowed.
    run grep -nE '^MK_T_[A-Z0-9_]*_STATIC=.*\\' "$HOOKS/messages/$f.sh"
    [ "$status" -ne 0 ]
  done
}

@test "no Turkish text in hook code outside messages" {
  shopt -s nullglob
  local files=("$HOOKS"/*.sh)
  shopt -u nullglob
  output=""
  if [ "${#files[@]}" -gt 0 ]; then
    # -Hn (not -n): grep only prints a "file:" prefix when given multiple
    # files. With exactly one hooks/*.sh file, plain -n would omit the
    # filename and the "file:line:" exclusion regex below would never
    # match, silently breaking the comment exclusion. -H forces the prefix
    # regardless of file count.
    run bash -c "grep -Hn '[çğıöşüÇĞİÖŞÜ]' \"\$@\" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' | grep -v \"matches '\"" _ "${files[@]}"
  fi
  [ -z "$output" ]
}

@test "invalid-config hint gives a reachable recovery path (both guards, both languages)" {
  for lang in tr en; do
    for hook in guard-edit.sh guard-subagent-authority.sh; do
      mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"language\":\"$lang\",\"guardedDirs\":[\"..\"]}"
      run_hook "$hook" "$(bash_payload 'ls' agent-1)"
      [ "$(decision)" = "deny" ] || { echo "$hook/$lang: not denied"; false; }
      r="$(reason)"
      printf '%s' "$r" | grep -qF '.claude/memokit.json' || { echo "$hook/$lang: no config path: $r"; false; }
      printf '%s' "$r" | grep -qF 'MEMOKIT_GUARD_OFF=1' || { echo "$hook/$lang: no kill switch: $r"; false; }
      printf '%s' "$r" | grep -qF '.claude/settings.local.json' || { echo "$hook/$lang: no settings.local.json: $r"; false; }
      lacks "$r" '/memokit:init'
    done
  done
}

@test "session-start invalid-config line does not send the user to /memokit:init" {
  for lang in tr en; do
    lacks "$(grep '^MK_T_SS_CONFIG_INVALID=' "$HOOKS/messages/$lang.sh")" '/memokit:init'
  done
}

@test "branch-switch message agrees with memokit:coder rule 0 (no git checkout -- <path> advice)" {
  for lang in tr en; do
    mk_project "{\"version\":1,\"project\":{\"name\":\"D\",\"tag\":\"DMO\"},\"language\":\"$lang\"}"
    run_hook guard-subagent-authority.sh "$(bash_payload 'git checkout -b other' agent-1)"
    [ "$(decision)" = "deny" ]
    r="$(reason)"
    lacks "$r" 'git checkout -- <path>'
    printf '%s' "$r" | grep -qF 'memokit:coder' || { echo "$lang: no rule reference: $r"; false; }
  done
  grep '^MK_T_GS_BRANCH_SWITCH=' "$HOOKS/messages/en.sh" | grep -qF 'by hand'
  grep '^MK_T_GS_BRANCH_SWITCH=' "$HOOKS/messages/tr.sh" | grep -qF 'elle'
}
