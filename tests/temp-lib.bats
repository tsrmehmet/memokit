#!/usr/bin/env bats
load helpers

# tl SNIPPET -- run SNIPPET after sourcing common.sh + temp.sh and running
# mk_temp_init on $TLP (default: the fixture's own payload). $HOURS sets
# MK_SCRATCH_STALE_HOURS (default 24), as mk_load_config would.
tl() {
  "$MK_BASH" -c ". \"\$0/lib/common.sh\"; . \"\$0/lib/temp.sh\"
    MK_SCRATCH_STALE_HOURS=\${HOURS:-24}
    mk_temp_init \"\$1\" || { echo INIT_FAIL; exit 9; }
    $1" "$HOOKS" "${TLP:-$TT_PAYLOAD}"
}
# rs TARGET... -- prints "ok|no <target>" per target from mk_temp_rm_safe.
rs() {
  local snippet='' t
  for t in "$@"; do
    snippet="$snippet
if mk_temp_rm_safe '$t'; then echo 'ok $t'; else echo 'no $t'; fi"
  done
  tl "$snippet"
}
# verdicts V N -- $output holds exactly N lines, all starting with "V ".
verdicts() {
  printf '%s\n' "$output"
  [ "${#lines[@]}" -eq "$2" ] && [ "$(printf '%s\n' "$output" | grep -c "^$1 ")" -eq "$2" ]
}
uuid() { printf '%08d-aaaa-bbbb-cccc-%012d' "$1" "$1"; }
teardown() { [ -n "${TROOT:-}" ] && rm -rf "$TROOT"; return 0; }

@test "init finds the project temp dir from transcript_path and sanitises slug/session" {
  mk_temp_tree
  run tl 'printf "%s\n" "$MK_TEMP_UID" "$MK_TEMP_ROOT_DIR" "$MK_TEMP_SLUG" "$MK_TEMP_PROJECT_DIR" "$MK_TEMP_SESSION_ID" "$MK_TEMP_SESSION_DIR" "$MK_TEMP_TRANSCRIPT_DIR"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$TT_UID" ]
  [ "${lines[1]}" = "$TT_ROOT" ]
  [ "${lines[2]}" = "$TT_SLUG" ]
  [ "${lines[3]}" = "$TT_PROJ" ]
  [ "${lines[4]}" = "$TT_SID" ]
  [ "${lines[5]}" = "$TT_SESS" ]
  [ "${lines[6]}" = "$TT_TDIR" ]

  # Hostile ids: a slug with a non-[A-Za-z0-9-] char maps like Claude Code's
  # own slug rule; a session id cannot climb out of the project temp dir.
  mkdir -p "$TROOT/projects/-fix.proj"
  for sid in '../x' 'a/b' '../../..'; do
    TLP="$(jq -nc --arg t "$TROOT/projects/-fix.proj/s.jsonl" --arg s "$sid" '{session_id:$s,transcript_path:$t}')" \
      run tl 'printf "%s\n" "$MK_TEMP_SLUG" "$MK_TEMP_SESSION_ID" "$MK_TEMP_SESSION_DIR"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "-fix-proj" ]
    case "${lines[1]}" in *[!A-Za-z0-9-]*|'') echo "bad sid: ${lines[1]}"; false ;; esac
    [ "${lines[2]}" = "$TT_PROJ/${lines[1]}" ]
    lacks "${lines[2]}" ".."
  done
}

@test "init fails silently when the tree is missing" {
  mk_temp_tree
  for p in \
    "$(jq -nc --arg t "$TROOT/projects/-no-such-proj/s.jsonl" '{session_id:"s1",transcript_path:$t}')" \
    "$(jq -nc --arg s "$TT_SID" '{session_id:$s}')" \
    "$(jq -nc --arg t "$TT_TDIR/$TT_SID.jsonl" '{transcript_path:$t}')" \
    '' 'not json'; do
    run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/temp.sh'
      mk_temp_init \"\$1\" && echo INIT_OK
      printf '%s' \"\$MK_TEMP_ROOT_DIR\$MK_TEMP_SLUG\$MK_TEMP_PROJECT_DIR\$MK_TEMP_SESSION_ID\$MK_TEMP_SESSION_DIR\"" _ "$p"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "payload [$p] -> [$output]"; false; }
  done
}

@test "footprint counts only entries born after start" {
  mk_temp_tree
  mk_blob "$TT_SP/old/blob" 3072
  sleep 1
  START="$(date +%s)"
  mk_blob "$TT_SP/new/blob" 2048
  run tl "mk_temp_footprint $START"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${output#*	}" = "$TT_SP/new" ]
  kb="${output%%	*}"
  [ "$kb" -ge 2048 ] && [ "$kb" -lt 3072 ]
}

@test "footprint does not double count a new dir's children" {
  mk_temp_tree
  sleep 1
  START="$(date +%s)"
  mk_blob "$TT_SP/new/a/b/f" 1024
  mk_blob "$TT_SP/new/x" 1024
  mk_blob "$TT_SP/new-sib" 512
  run tl "mk_temp_footprint $START"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]#*	}" = "$TT_SP/new" ]
  [ "${lines[1]#*	}" = "$TT_SP/new-sib" ]
  [ "${lines[0]%%	*}" -ge 2048 ]
}

@test "footprint descends into a pre-existing dir and counts its new child" {
  mk_temp_tree
  mk_blob "$TT_SP/old/keep-me" 1024
  mkdir -p "$TT_SP/old/a"
  sleep 1
  START="$(date +%s)"
  mk_blob "$TT_SP/old/newchild/f" 1024
  mk_blob "$TT_SP/old/a/deep" 512
  run tl "mk_temp_footprint $START"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]#*	}" = "$TT_SP/old/newchild" ]
  [ "${lines[1]#*	}" = "$TT_SP/old/a/deep" ]
  lacks "$output" "$TT_SP/old	"
}

@test "footprint skips .memokit-keep and tasks/" {
  mk_temp_tree
  mkdir -p "$TT_SP/old/a/b"
  sleep 1
  START="$(date +%s)"
  mk_blob "$TT_SP/kept/f" 1024; : > "$TT_SP/kept/.memokit-keep"
  # a pre-existing kept dir: its new children are excluded too
  : > "$TT_SP/old/.memokit-keep"; mk_blob "$TT_SP/old/a/new" 512
  mk_blob "$TT_SESS/tasks/huge.output" 2048
  run tl "mk_temp_footprint $START"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # without the outer marker the new child counts, but a depth-3 new dir whose
  # marker sits at depth 4 (beyond the walk) is still excluded
  rm "$TT_SP/old/.memokit-keep"
  mk_blob "$TT_SP/old/a/b2/f" 512; : > "$TT_SP/old/a/b2/.memokit-keep"
  run tl "mk_temp_footprint $START"
  [ "$status" -eq 0 ]
  [ "$output" = "$(du -sk "$TT_SP/old/a/new")" ]
}

@test "footprint on 2000 files finishes under 2 s" {
  mk_temp_tree
  i=0; while [ $i -lt 20 ]; do mkdir -p "$TT_SP/d$i"; i=$((i + 1)); done
  sleep 1
  START="$(date +%s)"
  i=0; while [ $i -lt 20 ]; do
    (cd "$TT_SP/d$i" && j=0 && while [ $j -lt 100 ]; do printf x > "f$j"; j=$((j + 1)); done)
    i=$((i + 1))
  done
  run tl "s=\$SECONDS; out=\$(mk_temp_footprint $START); printf '%s %s\n' \"\$(printf '%s\n' \"\$out\" | grep -c .)\" \$((SECONDS - s))"
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "2000" ]
  [ "${output##* }" -lt 2 ]
}

@test "stale: session by transcript age; missing transcript by birth; loose entry by birth; current session never" {
  mk_temp_tree
  OLDT="$(uuid 1)"; FRESHT="$(uuid 2)"; NOT="$(uuid 3)"
  mkdir -p "$TT_PROJ/$OLDT/scratchpad" "$TT_PROJ/$FRESHT/scratchpad" "$TT_PROJ/$NOT/tasks" "$TT_PROJ/xfix"
  : > "$TT_TDIR/$OLDT.jsonl";   touch -t 202001010000 "$TT_TDIR/$OLDT.jsonl"
  : > "$TT_TDIR/$FRESHT.jsonl"; touch -t 203001010000 "$TT_TDIR/$FRESHT.jsonl"
  touch -t 202001010000 "$TT_TDIR/$TT_SID.jsonl"
  # dir mtimes in the future must not matter (birth is used, never mtime)
  touch -t 203001010000 "$TT_PROJ/$NOT" "$TT_PROJ/xfix"
  sleep 1
  st() { HOURS="$1" run tl "for n in $OLDT $FRESHT $NOT xfix $TT_SID; do if mk_temp_is_stale \"\$n\"; then echo \"\$n:y\"; else echo \"\$n:n\"; fi; done"; }
  # 24 h: only the session whose transcript is old; dirs born just now are not.
  st 24
  [ "$status" -eq 0 ]
  [ "$output" = "$OLDT:y
$FRESHT:n
$NOT:n
xfix:n
$TT_SID:n" ]
  # 0 h: anything born >= 1 s ago is stale by birth; a future transcript keeps
  # its session fresh; the current session is never stale.
  st 0
  [ "$output" = "$OLDT:y
$FRESHT:n
$NOT:y
xfix:y
$TT_SID:n" ]
  HOURS=0 run tl 'for n in "" . .. "a/b" no-such-entry; do mk_temp_is_stale "$n" && echo "stale:$n"; done; true'
  [ -z "$output" ]
}

@test "stale_list sorts largest first, omits 0 KB skeletons" {
  mk_temp_tree
  A="$(uuid 1)"; B="$(uuid 2)"; SKEL="$(uuid 3)"; LIVE="$(uuid 4)"
  mk_blob "$TT_PROJ/$A/scratchpad/f" 1024
  mk_blob "$TT_PROJ/$B/scratchpad/f" 3072
  mkdir -p "$TT_PROJ/$SKEL/tasks"
  mk_blob "$TT_PROJ/f64b-B/x" 2048
  mk_blob "$TT_PROJ/$LIVE/scratchpad/f" 4096
  : > "$TT_TDIR/$LIVE.jsonl"; touch -t 203001010000 "$TT_TDIR/$LIVE.jsonl"
  mk_blob "$TT_SP/current" 5120
  sleep 1
  HOURS=0 run tl 'mk_temp_stale_list'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]#*	}" = "$TT_PROJ/$B" ]
  [ "${lines[1]#*	}" = "$TT_PROJ/f64b-B" ]
  [ "${lines[2]#*	}" = "$TT_PROJ/$A" ]
  [ "${lines[0]%%	*}" -ge 3072 ]
  lacks "$output" "$SKEL"
  lacks "$output" "TRUNCATED"
  # budget spent before the first du: nothing summed, TRUNCATED last
  HOURS=0 run tl 'mk_temp_stale_list 0'
  [ "$status" -eq 0 ]
  [ "$output" = "TRUNCATED" ]
}

@test "rm_safe allows direct children of the current scratchpad, both spellings, * and ? in the name" {
  mk_temp_tree
  mkdir -p "$TT_SP/x/y"
  LSP="$MEMOKIT_TEMP_ROOT/$TT_SLUG/$TT_SID/scratchpad"
  run rs "$TT_SP/x" "$TT_SP//x" "$TT_SP/new-not-yet" "$LSP/x" "$TT_SP/mut-*" "$TT_SP/x?"
  [ "$status" -eq 0 ]
  verdicts ok 6
  # deeper paths, a trailing "/", [ ] classes and zsh ^ negation are not exempt
  run rs "$TT_SP/x/y" "$TT_SP/x/" "$TT_SP/x//y/" "$LSP/x/" "$TT_SP/x/y?" "$TT_SP/[ab]*"
  [ "$status" -eq 0 ]
  verdicts no 6
  # The literal /tmp -> /private/tmp mapping applies when the root lives under
  # /private/tmp (macOS). Pure string check of the lexical half: nothing below
  # exists or is needed (the fixture itself cannot live in /private/tmp).
  run tl "MK_TEMP_ROOT_DIR=/private/tmp/claude-$TT_UID
    for t in /tmp/claude-$TT_UID/s/x /tmp//claude-$TT_UID/s/x/ /private/tmp/claude-$TT_UID/s/x /tmpx/claude-$TT_UID/s/x /tmp; do
      _mk_temp_rm_norm \"\$t\"; echo
    done
    MK_TEMP_ROOT_DIR=/var/claude-$TT_UID; _mk_temp_rm_norm /tmp/claude-$TT_UID/x"
  [ "$status" -eq 0 ]
  [ "$output" = "/private/tmp/claude-$TT_UID/s/x
/private/tmp/claude-$TT_UID/s/x
/private/tmp/claude-$TT_UID/s/x
/tmpx/claude-$TT_UID/s/x
/private/tmp
/tmp/claude-$TT_UID/x" ]
}

@test "rm_safe allows a whole stale sibling and a stale loose entry" {
  mk_temp_tree
  SIB="$(uuid 1)"
  mkdir -p "$TT_PROJ/$SIB/scratchpad" "$TT_PROJ/xfix"
  : > "$TT_TDIR/$SIB.jsonl"; touch -t 202001010000 "$TT_TDIR/$SIB.jsonl"
  sleep 1
  HOURS=24 run rs "$TT_PROJ/$SIB" "$TT_PROJ//$SIB"
  [ "$status" -eq 0 ]
  verdicts ok 2
  HOURS=0 run rs "$TT_PROJ/xfix" "$MEMOKIT_TEMP_ROOT/$TT_SLUG/xfix"
  [ "$status" -eq 0 ]
  verdicts ok 2
  # a trailing "/" on a whole entry is never exempt: rm follows whatever
  # symlink an earlier segment may have put there
  HOURS=0 run rs "$TT_PROJ/$SIB/" "$TT_PROJ/$SIB//" "$TT_PROJ/xfix/" "$MEMOKIT_TEMP_ROOT/$TT_SLUG/xfix/"
  [ "$status" -eq 0 ]
  verdicts no 4
  # the loose entry is not stale under 24 h (born just now)
  HOURS=24 run rs "$TT_PROJ/xfix"
  verdicts no 1
}

@test "rm_safe rejects: temp root, project dir, current session dir, current tasks/, non-stale sibling, other project, .. traversal, \$VAR, ~, backtick, glob at session level" {
  mk_temp_tree
  FRESH="$(uuid 1)"; STALE="$(uuid 2)"; OTHER="$(uuid 3)"
  mkdir -p "$TT_PROJ/$FRESH/scratchpad" "$TT_PROJ/$STALE/scratchpad" "$TT_ROOT/-other-proj/$OTHER/scratchpad"
  : > "$TT_TDIR/$FRESH.jsonl"; touch -t 203001010000 "$TT_TDIR/$FRESH.jsonl"
  : > "$TT_TDIR/$STALE.jsonl"; touch -t 202001010000 "$TT_TDIR/$STALE.jsonl"
  touch -t 202001010000 "$TT_TDIR/$TT_SID.jsonl"
  mkdir -p "$TROOT/outside/keep" "$TT_SP/real"
  # a stale loose entry literally named "x*": rm -rf would still glob it
  mkdir -p "$TT_PROJ/x*" "$TT_PROJ/xother"
  ln -s "$TROOT/outside" "$TT_SP/link"
  sleep 1
  # shellcheck disable=SC2016
  HOURS=0 run rs \
    "$TT_ROOT" "$TT_ROOT/" "$TT_PROJ" "$TT_PROJ/" "$TT_SESS" "$TT_SESS/" \
    "$TT_SESS/tasks" "$TT_SESS/tasks/x" "$TT_SP" "$TT_SP/" "$TT_SP/." "$TT_SP/./" \
    "$TT_PROJ/$FRESH" "$TT_PROJ/$FRESH/scratchpad/x" "$TT_PROJ/$STALE/scratchpad" \
    "$TT_ROOT/-other-proj/$OTHER" "$TT_ROOT/-other-proj/$OTHER/scratchpad/x" \
    "$TT_SP/../tasks" "$TT_SP/a/../../tasks" "$TT_SP/.." "$TT_PROJ/$STALE/.." \
    "$TT_SP/\$X" '$HOME/x' "\$TMPDIR/claude-$TT_UID/$TT_SLUG/$STALE" \
    '~/x' "$TT_SP/~x" "$TT_SP/\`id\`" \
    "$TT_PROJ/*" "$TT_PROJ/$(printf %.4s "$STALE")*" "$TT_PROJ/$STALE?" "$TT_PROJ/x*" "$TT_SESS/scr*" "$TT_SESS/*/x" "$TT_ROOT/*/$STALE" \
    "$TT_SP/*/x" "$TT_SP/a{,/../..}" "$TT_SP/a b" "scratchpad/x" "" "/" \
    "$TT_SP/link/keep" "$TT_SP/link/" "$TT_SP/l*/"
  [ "$status" -eq 0 ]
  verdicts no 43
  # sanity: the same fixture does allow the stale sibling and a plain symlink
  HOURS=0 run rs "$TT_PROJ/$STALE" "$TT_SP/link" "$TT_SP/real"
  verdicts ok 3
}

@test "iso_epoch parses a transcript timestamp with and without fractional seconds" {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/temp.sh'
    mk_temp_iso_epoch 2026-10-17T12:30:01.123Z; echo
    mk_temp_iso_epoch 2026-10-17T12:30:01Z; echo
    mk_temp_iso_epoch 'not a date' && echo BAD; mk_temp_iso_epoch '' && echo BAD; true"
  [ "$status" -eq 0 ]
  [ "$output" = "1792240201
1792240201" ]
}

@test "disk_free_kb is a positive integer" {
  mk_temp_tree
  run tl 'MK_ROOT="$TT_ROOT"; mk_disk_free_kb'
  [ "$status" -eq 0 ]
  case "$output" in ''|*[!0-9]*) echo "not an integer: $output"; false ;; esac
  [ "$output" -gt 0 ]
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/temp.sh'; mk_disk_free_kb && echo BAD; true"
  [ -z "$output" ]
}

@test "disk_free_kb honours the MEMOKIT_DF_KB test seam only for a non-negative integer" {
  mk_temp_tree
  MEMOKIT_DF_KB=12345 run tl 'mk_disk_free_kb'
  [ "$output" = "12345" ]
  MEMOKIT_DF_KB=0 run tl 'mk_disk_free_kb'
  [ "$output" = "0" ]
  for bad in abc -5 '1 2' ''; do
    MEMOKIT_DF_KB="$bad" run tl 'mk_disk_free_kb'
    [ "$status" -eq 0 ]
    case "$output" in ''|*[!0-9]*) echo "[$bad] -> [$output]"; false ;; esac
    [ "$output" -gt 0 ]
  done
}

@test "human_kb prints GB with one decimal and whole MB" {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/temp.sh'
    LC_ALL=tr_TR.UTF-8 mk_human_kb 19922944; echo
    mk_human_kb 524288; echo
    mk_human_kb 1048576; echo
    mk_human_kb 0; echo
    mk_human_kb x && echo BAD; true"
  [ "$status" -eq 0 ]
  [ "$output" = "19.0 GB
512 MB
1.0 GB
0 MB" ]
}

@test "rm_safe rejects case-variant names of the current session, a running sibling and the scratchpad prefix" {
  CUR="abcdef01-2222-3333-4444-5555555555cc"
  mk_temp_tree -fix-proj "$CUR"
  RUN="$(uuid 7)"; STALE="$(uuid 8)"
  mkdir -p "$TT_PROJ/$RUN/tasks" "$TT_PROJ/$STALE/tasks" "$TT_SP/x"
  : > "$TT_TDIR/$RUN.jsonl";   touch -t 203001010000 "$TT_TDIR/$RUN.jsonl"
  : > "$TT_TDIR/$STALE.jsonl"; touch -t 202001010000 "$TT_TDIR/$STALE.jsonl"
  touch -t 202001010000 "$TT_TDIR/$CUR.jsonl"
  up() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }
  UCUR="$(up "$CUR")"; URUN="$(up "$RUN")"; MIX="AbCdef01-2222-3333-4444-5555555555cc"
  sleep 1
  # HOURS=0: every dir born >= 1 s ago would be stale by birth time.
  HOURS=0 run rs \
    "$TT_PROJ/$UCUR" "$TT_PROJ/$UCUR/" "$TT_PROJ/$MIX" "$TT_PROJ/$MIX/" \
    "$TT_PROJ/$URUN" "$TT_PROJ/$URUN/" "$TT_PROJ/$(up "$STALE")" \
    "$TT_PROJ/$UCUR/scratchpad/x" "$TT_PROJ/$UCUR/scratchpad/x/" \
    "$TT_SESS/SCRATCHPAD/x" "$TT_SESS/Scratchpad/x/" \
    "$TT_ROOT/-FIX-PROJ/$CUR/scratchpad/x" "$TT_ROOT/-FIX-PROJ/$STALE"
  [ "$status" -eq 0 ]
  verdicts no 13
  # ... while the canonical spellings keep their verdicts
  HOURS=0 run rs "$TT_PROJ/$STALE" "$TT_SP/x"
  verdicts ok 2
  HOURS=0 run rs "$TT_PROJ/$CUR" "$TT_PROJ/$RUN"
  verdicts no 2
  # mk_temp_is_stale itself never calls a case variant stale
  HOURS=0 run tl "for n in $UCUR $MIX $URUN; do mk_temp_is_stale \"\$n\" && echo \"stale:\$n\"; done; true"
  [ -z "$output" ]
}

@test "rm_safe below scratchpad: direct children only (no intermediate component, no trailing slash)" {
  mk_temp_tree
  mkdir -p "$TT_SP/real/sub"
  mkdir -p "$TROOT/outside/Documents"
  ln -s "$TROOT/outside" "$TT_SP/link"
  # absent intermediate (could be created as a symlink earlier in the same
  # command: ln -s ~ sp/x && rm -rf sp/x/Documents), absent final with "/",
  # existing intermediate symlink, symlink final with "/"
  # ... and, since an earlier background job could swap a real dir for a link
  # at any time, not through existing real dirs either
  run rs "$TT_SP/x/Documents" "$TT_SP/real/nope/f" "$TT_SP/nope/" "$TT_SP/real/nope/" \
         "$TT_SP/link/Documents" "$TT_SP/real/../link/Documents" "$TT_SP/link/" \
         "$TT_SP/real/sub" "$TT_SP/real/sub/" "$TT_SP/real/sub/f" "$TT_SP/real/absent" "$TT_SP/real/"
  [ "$status" -eq 0 ]
  verdicts no 12
  # a plain direct child: a real dir, absent, or a link (rm -rf unlinks it)
  run rs "$TT_SP/real" "$TT_SP/absent" "$TT_SP/link"
  verdicts ok 3
  # no scratchpad dir at all: nothing below it is exempt
  rm -rf "$TT_SP"
  run rs "$TT_SP/x"
  verdicts no 1
}

@test "rm_safe rejects zsh EXTENDED_GLOB ^ negation, [ ] classes and ** in scratchpad children and whole entries" {
  mk_temp_tree
  mkdir -p "$TT_SP/^x/y" "$TT_PROJ/^stale" "$TT_PROJ/zzz" "$TT_PROJ/[z]zz"
  sleep 1
  # HOURS=0: every loose entry born >= 1 s ago is stale by birth time
  HOURS=0 run rs "$TT_SP/^x" "$TT_SP/^x/y" "$TT_SP/a^b" "$TT_SP/^*" "$TT_SP/[x]" \
    "$TT_PROJ/^stale" "$TT_PROJ/^zzz" "$TT_PROJ/[z]zz" "$TT_PROJ/z^" \
    "$TT_SP/**" "$TT_SP/***" "$TT_SP/a**b"
  [ "$status" -eq 0 ]
  verdicts no 12
  HOURS=0 run rs "$TT_PROJ/zzz" "$TT_SP/x"
  verdicts ok 2
}

@test "rm_safe rejects '=' (zsh EQUALS / MAGIC_EQUAL_SUBST) and '!' (history expansion) anywhere" {
  mk_temp_tree
  mkdir -p "$TT_PROJ/x==y" "$TT_PROJ/=y" "$TT_PROJ/a!b" "$TT_PROJ/zzz" "$TT_SP/x="
  sleep 1
  HOURS=0 run rs "$TT_SP/x==cmd" "$TT_SP/=cmd" "$TT_SP/a=b" "$TT_SP/x=" "$TT_SP/x!!" "$TT_SP/!x" \
    "$TT_PROJ/x==y" "$TT_PROJ/=y" "$TT_PROJ/a!b"
  [ "$status" -eq 0 ]
  verdicts no 9
  HOURS=0 run rs "$TT_PROJ/zzz" "$TT_SP/x" "$TT_SP/a@b+c,d:e%f"
  verdicts ok 3
}

@test "init: a subagent's own transcript path maps to the parent session's slug and transcript dir" {
  mk_temp_tree
  show='printf "%s\n" "$MK_TEMP_SLUG" "$MK_TEMP_PROJECT_DIR" "$MK_TEMP_SESSION_ID" "$MK_TEMP_SESSION_DIR" "$MK_TEMP_TRANSCRIPT_DIR"'
  # main session transcript: <projects>/<slug>/<session>.jsonl
  run tl "$show"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$TT_SLUG" "$TT_PROJ" "$TT_SID" "$TT_SESS" "$TT_TDIR")" ]
  # subagent transcript: <projects>/<slug>/<session>/subagents/agent-<id>.jsonl
  mkdir -p "$TT_TDIR/$TT_SID/subagents"
  : > "$TT_TDIR/$TT_SID/subagents/agent-a1b2c3.jsonl"
  TLP="$(jq -nc --arg t "$TT_TDIR/$TT_SID/subagents/agent-a1b2c3.jsonl" --arg s "$TT_SID" '{session_id:$s,transcript_path:$t,agent_id:"a1b2c3"}')" \
    run tl "$show"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' "$TT_SLUG" "$TT_PROJ" "$TT_SID" "$TT_SESS" "$TT_TDIR")" ]
}

@test "init: a 'subagents' dir that is not below a session uuid is not special" {
  mk_temp_tree
  # <projects>/<slug>/not-a-uuid/subagents/x.jsonl -> slug "subagents": no such temp dir
  for mid in not-a-uuid ABCDEF01-2222-3333-4444-555555555555 1111111-2222-3333-4444-555555555555; do
    mkdir -p "$TT_TDIR/$mid/subagents"
    TLP="$(jq -nc --arg t "$TT_TDIR/$mid/subagents/agent-x.jsonl" --arg s "$TT_SID" '{session_id:$s,transcript_path:$t}')" \
      run tl 'echo "$MK_TEMP_SLUG"'
    [ "$status" -eq 9 ] && [ "$output" = "INIT_FAIL" ] || { echo "$mid -> $output"; false; }
  done
  # a project slug literally named "subagents" keeps the main-transcript rule
  mkdir -p "$TT_ROOT/subagents/$TT_SID" "$TROOT/projects/subagents"
  TLP="$(jq -nc --arg t "$TROOT/projects/subagents/$TT_SID.jsonl" --arg s "$TT_SID" '{session_id:$s,transcript_path:$t}')" \
    run tl 'printf "%s\n" "$MK_TEMP_SLUG" "$MK_TEMP_TRANSCRIPT_DIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' subagents "$TROOT/projects/subagents")" ]
}

@test "rm_safe rejects a dot-name with a glob in a scratchpad child; a plain dot-name stays allowed" {
  mk_temp_tree
  mkdir -p "$TT_SP/.hid"
  run rs "$TT_SP/.*" "$TT_SP/.?*" "$TT_SP/..*" "$TT_SP/.?" "$TT_SP/.h*" "$TT_SP/.hi?" "$TT_SP/.*x"
  [ "$status" -eq 0 ]
  verdicts no 7
  run rs "$TT_SP/.hid" "$TT_SP/.x.y" "$TT_SP/a.*" "$TT_SP/x?"
  verdicts ok 4
}

# --- ownership / mode of the temp dirs (shared /tmp on multi-user Linux) -----
# mk_temp_init and mk_temp_rm_safe require -O (owned by the current user) and
# no group/world write bit. Ownership by ANOTHER user cannot be simulated
# without root, so only the mode half is exercised here; -O is a plain test.

@test "init: a group- or world-writable temp root is refused" {
  mk_temp_tree
  for m in 777 770 707 720 702; do
    chmod "$m" "$TT_ROOT"
    run tl 'echo X'
    [ "$status" -eq 9 ] || { echo "mode $m accepted: $output"; false; }
    [[ $output == *INIT_FAIL* ]]
  done
  chmod 700 "$TT_ROOT"
  run tl 'echo X'
  [ "$status" -eq 0 ]
  chmod 750 "$TT_ROOT"; chmod 755 "$TT_ROOT"
  run tl 'echo X'
  [ "$status" -eq 0 ]
}

@test "init: a group/world-writable <root>/<slug> is refused" {
  mk_temp_tree
  chmod 777 "$TT_PROJ"
  run tl 'echo X'
  [ "$status" -eq 9 ]
  chmod 770 "$TT_PROJ"
  run tl 'echo X'
  [ "$status" -eq 9 ]
}

@test "init: an unusable root falls through to the next candidate" {
  mk_temp_tree
  chmod 777 "$TT_ROOT"
  # no other candidate holds the slug dir, so init fails closed (not by accident)
  run tl 'echo X'
  [ "$status" -eq 9 ]
}

@test "init: the /tmp -> /private/tmp style symlink root is judged on its target" {
  mk_temp_tree
  ln -s "$TT_ROOT" "$TROOT/link-root"
  MEMOKIT_TEMP_ROOT="$TROOT/link-root" run tl 'printf "%s" "$MK_TEMP_ROOT_DIR"'
  [ "$status" -eq 0 ]
  [ "$output" = "$TT_ROOT" ]
  chmod 777 "$TT_ROOT"
  MEMOKIT_TEMP_ROOT="$TROOT/link-root" run tl 'echo X'
  [ "$status" -eq 9 ]
}

@test "rm_safe: a group/world-writable session dir or scratchpad is never exempt" {
  mk_temp_tree
  mkdir -p "$TT_SP/a"
  run rs "$TT_SP/a"
  verdicts ok 1
  chmod 777 "$TT_SESS"
  run rs "$TT_SP/a"
  verdicts no 1
  chmod 700 "$TT_SESS"; chmod 775 "$TT_SP"
  run rs "$TT_SP/a"
  verdicts no 1
  chmod 700 "$TT_SP"
  run rs "$TT_SP/a"
  verdicts ok 1
}

@test "rm_safe: a stale sibling is not exempt when the root turns group-writable after init" {
  mk_temp_tree
  mkdir -p "$TT_PROJ/$(uuid 1)/scratchpad/f"
  touch -t 200001010000 "$TT_PROJ/$(uuid 1)" "$TT_TDIR/$(uuid 1).jsonl" 2>/dev/null || true
  run tl "chmod 770 '$TT_ROOT'; mk_temp_rm_safe '$TT_PROJ/$(uuid 1)' && echo ok || echo no"
  [ "${lines[0]}" = "no" ]
}
