#!/usr/bin/env bats
load helpers

setup() {
  mk_project
  export TMPDIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkdisk.XXXXXX")"
  unset MEMOKIT_DISK_OFF
  GB=1048576
}
teardown() { rm -rf "$TMPDIR" "${TROOT_LOGICAL:-}"; }

pl() { # event session tuid command
  jq -nc --arg e "$1" --arg s "$2" --arg t "$3" --arg c "${4:-echo hi}" --arg cwd "$PROJ" \
    '{hook_event_name:$e,session_id:$s,tool_name:"Bash",tool_input:{command:$c},cwd:$cwd} + (if $t=="" then {} else {tool_use_id:$t} end)'
}
df_hook() { local kb="$1"; shift; MEMOKIT_DF_KB="$kb" run_hook check-disk.sh "$@"; }
sysmsg() { printf '%s' "$output" | jq -r '.systemMessage // empty'; }
marker() { ls "$TMPDIR"/memokit-*-"$1" 2>/dev/null | head -1; }

@test "Pre records, Post with 11 GB less warns; 9 GB less is silent" {
  df_hook $((100*GB)) "$(pl PreToolUse s1 tu1)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  df_hook $((89*GB)) "$(pl PostToolUse s1 tu1)"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUse"' >/dev/null
  [[ "$(ctx)" == *"11.0 GB"* ]]
  df_hook $((100*GB)) "$(pl PreToolUse s1 tu2)"
  df_hook $((91*GB)) "$(pl PostToolUse s1 tu2)"
  [ -z "$output" ]
}

@test "Pre/Post without tool_use_id key on session + command hash" {
  df_hook $((100*GB)) "$(pl PreToolUse s1 '' 'make big')"
  df_hook $((80*GB)) "$(pl PostToolUse s1 '' 'make big')"
  [[ "$(ctx)" == *"20.0 GB"* ]]
  df_hook $((100*GB)) "$(pl PreToolUse s1 '' 'make big')"
  df_hook $((80*GB)) "$(pl PostToolUse s1 '' 'other cmd')"
  [ -z "$output" ]
}

@test "Post without a Pre file is silent" {
  df_hook $((50*GB)) "$(pl PostToolUse s1 nope)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "Pre prints nothing even when below floor" {
  df_hook $((1*GB)) "$(pl PreToolUse s1 tu1)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "drop message shows session temp size, 0 without a temp tree" {
  df_hook $((100*GB)) "$(pl PreToolUse s1 tu1)"
  df_hook $((80*GB)) "$(pl PostToolUse s1 tu1)"
  [[ "$(ctx)" == *"0 MB"* ]]
}

@test "drop message shows session temp size with a temp tree" {
  mk_temp_tree
  mk_blob "$TT_SP/big" 3072
  p() { jq -nc --arg e "$1" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" --arg cwd "$PROJ" '{hook_event_name:$e,session_id:$s,transcript_path:$t,tool_use_id:"tu9",tool_input:{command:"x"},cwd:$cwd}'; }
  df_hook $((100*GB)) "$(p PreToolUse)"
  df_hook $((80*GB)) "$(p PostToolUse)"
  [[ "$(ctx)" == *"3 MB"* ]]
}

@test "floor: Post below floor fires once, silent within 10 min, again after 11 min" {
  df_hook $((100*GB)) "$(pl PreToolUse s1 a)"
  df_hook $((20*GB)) "$(pl PostToolUse s1 a)"
  [[ "$(ctx)" == *"20.0 GB"* ]] && [[ "$(ctx)" == *"30"* ]]
  df_hook $((20*GB)) "$(pl PostToolUse s1 b)"
  [ -z "$output" ]
  m="$(marker disk-floorctx-s1)"; [ -n "$m" ]
  printf '%s' "$(( $(date +%s) - 660 ))" > "$m"
  df_hook $((20*GB)) "$(pl PostToolUse s1 c)"
  [[ "$(ctx)" == *"20.0 GB"* ]]
}

@test "floor: Post back above floor deletes the marker, re-crossing fires at once" {
  df_hook $((20*GB)) "$(pl PostToolUse s1 a)"
  [ -n "$(marker disk-floorctx-s1)" ]
  df_hook $((50*GB)) "$(pl PostToolUse s1 b)"
  [ -z "$(marker disk-floorctx-s1)" ]
  df_hook $((20*GB)) "$(pl PostToolUse s1 c)"
  [ -n "$(ctx)" ]
}

@test "Stop below floor: systemMessage once, silent within 30 min, fires after reset" {
  df_hook $((20*GB)) "$(pl Stop s1 '')"
  [[ "$(sysmsg)" == *"20.0 GB"* ]]
  df_hook $((20*GB)) "$(pl Stop s1 '')"
  [ -z "$output" ]
  df_hook $((50*GB)) "$(pl Stop s1 '')"
  [ -z "$output" ]
  df_hook $((20*GB)) "$(pl Stop s1 '')"
  [ -n "$(sysmsg)" ]
}

@test "Stop message includes the cached leftover total" {
  m="$(MK_ROOT="$PROJ"; . "$HOOKS/lib/common.sh"; MK_ROOT="$PROJ"; mk_tmp temp-leftover-s1)"
  printf '%s' "$((5*GB))" > "$m"
  df_hook $((20*GB)) "$(pl Stop s1 '')"
  [[ "$(sysmsg)" == *"5.0 GB"* ]]
}

@test "minFreeGB:0 disables the floor" {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"tr","guardedDirs":["src"],"disk":{"minFreeGB":0}}'
  df_hook $((1*GB)) "$(pl PostToolUse s1 a)"
  [ -z "$output" ]
  df_hook $((1*GB)) "$(pl Stop s1 '')"
  [ -z "$output" ]
}

@test "MEMOKIT_DISK_OFF=1 is silent everywhere" {
  export MEMOKIT_DISK_OFF=1
  df_hook $((1*GB)) "$(pl Stop s1 '')"; [ -z "$output" ]
  df_hook $((1*GB)) "$(pl PostToolUse s1 a)"; [ -z "$output" ]
  df_hook $((1*GB)) "$(pl PreToolUse s1 a)"; [ -z "$output" ]
  [ -z "$(ls "$TMPDIR")" ]
}

@test "a symlinked Pre file is never followed or overwritten" {
  victim="$TMPDIR/victim"; printf 'keep' > "$victim"
  df_hook $((100*GB)) "$(pl PreToolUse s1 zz)"
  pre="$(marker disk-pre-zz)"; [ -n "$pre" ]
  rm -f "$pre"; ln -s "$victim" "$pre"
  df_hook $((100*GB)) "$(pl PreToolUse s1 zz)"
  [ "$(cat "$victim")" = "keep" ]
  [ -L "$pre" ]
  df_hook $((50*GB)) "$(pl PostToolUse s1 zz)"
  [ -z "$output" ]
  [ "$(cat "$victim")" = "keep" ]
}

@test "symlinked floor marker is not followed" {
  victim="$TMPDIR/victim"; printf 'keep' > "$victim"
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  ln -s "$victim" "$TMPDIR/memokit-$h-disk-floorctx-s1"
  df_hook $((20*GB)) "$(pl PostToolUse s1 a)"
  [ "$(cat "$victim")" = "keep" ]
}

@test "hostile ids are sanitised into the file name" {
  df_hook $((100*GB)) "$(pl PreToolUse '../s' '../../etc/x')"
  [ -z "$(ls "$TMPDIR" | grep -v '^memokit-')" ]
  [ -z "$(ls "$TMPDIR/.." 2>/dev/null | grep -x 'etc')" ] || true
  ls "$TMPDIR" | grep -q 'disk-pre-'
}

@test "Pre prunes only its own old Pre files" {
  h="$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)"
  old="$TMPDIR/memokit-$h-disk-pre-old"; other="$TMPDIR/memokit-$h-context-band-x"
  printf 1 > "$old"; printf 1 > "$other"
  touch -t 202001010000 "$old" "$other"
  df_hook $((100*GB)) "$(pl PreToolUse s1 n)"
  [ ! -e "$old" ] && [ -e "$other" ]
}

@test "Stop message points to /memokit:sweep" {
  df_hook $((20*GB)) "$(pl Stop s1 '')"
  [[ "$(sysmsg)" == *"/memokit:sweep"* ]]
}

@test "silent Post path does not run du" {
  mk_temp_tree
  shim="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkshim.XXXXXX")"
  printf '#!/bin/sh\necho called >> "%s/du.log"\nexec /usr/bin/du "$@"\n' "$shim" > "$shim/du"
  chmod +x "$shim/du"
  p() { jq -nc --arg e "$1" --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" --arg cwd "$PROJ" '{hook_event_name:$e,session_id:$s,transcript_path:$t,tool_use_id:"tq",tool_input:{command:"x"},cwd:$cwd}'; }
  export PATH="$shim:$PATH"
  df_hook $((100*GB)) "$(p PreToolUse)"
  df_hook $((95*GB)) "$(p PostToolUse)"
  [ -z "$output" ]
  [ ! -e "$shim/du.log" ]
  df_hook $((100*GB)) "$(p PreToolUse)"
  df_hook $((80*GB)) "$(p PostToolUse)"
  [ -e "$shim/du.log" ]
  rm -rf "$shim"
}

@test "PostToolUseFailure consumes the Pre record and warns with its own event name" {
  df_hook $((100*GB)) "$(pl PreToolUse s1 tf1)"
  [ -n "$(marker disk-pre-tf1)" ]
  df_hook $((89*GB)) "$(pl PostToolUseFailure s1 tf1)"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUseFailure"' >/dev/null
  [[ "$(ctx)" == *"11.0 GB"* ]]
  [ -z "$(marker disk-pre-tf1)" ]
  # a small drop on a failing command is silent, and still consumes the record
  df_hook $((100*GB)) "$(pl PreToolUse s1 tf2)"
  df_hook $((99*GB)) "$(pl PostToolUseFailure s1 tf2)"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ -z "$(marker disk-pre-tf2)" ]
}

@test "PostToolUseFailure reports the floor crossing like PostToolUse" {
  df_hook $((20*GB)) "$(pl PostToolUseFailure s1 a)"
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName=="PostToolUseFailure"' >/dev/null
  [[ "$(ctx)" == *"20.0 GB"* ]]
  df_hook $((20*GB)) "$(pl PostToolUse s1 b)"
  [ -z "$output" ]
}

@test "free space is measured on the project root AND the session temp root" {
  mk_temp_tree
  shim="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkdfshim.XXXXXX")"
  # Fake df -Pk: the temp root has 5 GB available, anything else 500 GB.
  cat > "$shim/df" <<SH
#!/bin/sh
for a; do d="\$a"; done
printf '%s\n' "\$d" >> "$shim/df.log"
case "\$d" in "$TT_ROOT"*) kb=$((5*GB)) ;; *) kb=$((500*GB)) ;; esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/x 999999999 1 %s 1%% /\n' "\$kb"
SH
  printf '#!/bin/sh\necho called >> "%s/du.log"\nexec /usr/bin/du "$@"\n' "$shim" > "$shim/du"
  chmod +x "$shim/df" "$shim/du"
  p="$(jq -nc --arg e PreToolUse --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" --arg cwd "$PROJ" '{hook_event_name:$e,session_id:$s,transcript_path:$t,tool_use_id:"tr1",tool_input:{command:"x"},cwd:$cwd}')"
  unset MEMOKIT_DF_KB
  PATH="$shim:$PATH" run_hook check-disk.sh "$p"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  cat "$shim/df.log"
  grep -qx "$PROJ" "$shim/df.log"
  grep -qx "$TT_ROOT" "$shim/df.log"
  [ "$(cat "$(marker disk-pre-tr1)")" = "$((5*GB))" ]
  [ ! -e "$shim/du.log" ]
  rm -rf "$shim"
}
