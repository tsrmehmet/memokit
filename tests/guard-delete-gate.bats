#!/usr/bin/env bats
# 0.8.5 coarse delete/move gate (_mk_gs_del_hit in guard-subagent-authority.sh):
# a command that names a delete/move tool passes only when every word of it is
# provably harmless. The e2e tests run the real hook as a subagent; the unit
# tests call the function on its own (extracted from the hook), which pins the
# reason class and the failing word.
load helpers

GUARD=guard-subagent-authority.sh

setup() {
  mk_project '{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en","guardedDirs":["src","tests"]}'
  mk_temp_tree
  TMPDIR="$(mktemp -d "${MK_FIXTMP}/mktmp.XXXXXX")"; export TMPDIR
  ROOT="$PROJ"
  sed -n '/^# --- DEL-GATE BEGIN/,/^# --- DEL-GATE END/p' "$HOOKS/$GUARD" > "$BATS_TEST_TMPDIR/del.sh"
}
teardown() { rm -rf "${TROOT:-/nonexistent-x}" "${PROJ:-/nonexistent-x}" "${TMPDIR:-/nonexistent-x}"; }

# The payload with a transcript, so the scratchpad is known.
sp_payload() {
  bash_payload "$1" agent-1 | jq -c --arg t "$TT_TDIR/$TT_SID.jsonl" --arg s "$TT_SID" '. + {session_id:$s,transcript_path:$t}'
}
# ok CMD -- denied by nothing (or not by this gate's texts).
allowed() {
  run_hook $GUARD "$(sp_payload "$1")"
  [ "$(decision)" != deny ] || { echo "denied: $1 -- $(reason)"; return 1; }
}
# dn CMD MARKER -- denied; the reason holds MARKER (the class text of the new
# gate) or the old config gate's text (0.8.4 denies it for its own reasons).
dn() {
  run_hook $GUARD "$(sp_payload "$1")"
  [ "$(decision)" = deny ] || { echo "not denied: $1"; return 1; }
  case "$(reason)" in
    *"$2"*|*"may NOT change memokit's configuration"*|*"Claude Code settings"*) ;;
    *) echo "wrong reason for: $1 -- $(reason)"; return 1 ;;
  esac
}
# denied CMD -- denied, whatever the reason.
denied() {
  run_hook $GUARD "$(sp_payload "$1")"
  [ "$(decision)" = deny ] || { echo "not denied: $1"; return 1; }
}
# dn_new CMD MARKER WORD -- denied by the new gate itself, naming WORD.
dn_new() {
  run_hook $GUARD "$(sp_payload "$1")"
  [ "$(decision)" = deny ] || { echo "not denied: $1"; return 1; }
  case "$(reason)" in *"$2"*) ;; *) echo "wrong reason for: $1 -- $(reason)"; return 1 ;; esac
  case "$(reason)" in *"$3"*) ;; *) echo "word '$3' missing for: $1 -- $(reason)"; return 1 ;; esac
}
# u CMD WHY WORD [ROOT [CWD [SCR]]] -- the function alone: rc 0, the class, the word.
u() {
  local r="${4:-/Users/u/p}" c="${5:-${4:-/Users/u/p}}" got
  got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=$2; _MK_GS_PROOT=$2; _MK_GS_CWD=$3; _MK_GS_DEL_SCR=$4; _MK_GS_DEL_INIT=1
    _mk_gs_del_hit "$5"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$r" "$c" "${6:-}" "$1")"
  [ "$got" = "0 $2 $3" ] || { echo "unit: $1 -> '$got' (want '0 $2 $3')"; return 1; }
}
# u1 CMD [ROOT [CWD [SCR]]] -- the function alone: rc 1 (passes).
u1() {
  local r="${2:-/Users/u/p}" c="${3:-${2:-/Users/u/p}}" got
  got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=$2; _MK_GS_PROOT=$2; _MK_GS_CWD=$3; _MK_GS_DEL_SCR=$4; _MK_GS_DEL_INIT=1
    _mk_gs_del_hit "$5"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$r" "$c" "${4:-}" "$1")"
  case "$got" in "1 "*) ;; *) echo "unit: $1 -> '$got' (want pass)"; return 1 ;; esac
}

@test "allow: harmless commands pass, scratch cleanup included" {
  local c
  for c in "rm -rf dist" "mv src/a.ts src/b.ts" "git rm src/old.ts" \
    "find src -name '*.tmp' -delete" "find src -name '*.tmp' -exec rm {} +" \
    "rm -f build/out.log 2>/dev/null" "rm $ROOT/src/a.ts" "rm -rf $TT_SP/coder-s3" \
    "rm -rf $TROOT_LOGICAL/claude-$TT_UID/$TT_SLUG/$TT_SID/scratchpad/coder-s3" \
    "find . -name '*.ts' -exec grep -l foo {} +" "docker run --rm img" "npm run format" "ls *.bak | head"; do
    allowed "$c" || return 1
  done
}

@test "deny EXPANSION: variables, loops, backquotes, ~ and braces" {
  local c
  for c in 'rm -rf "$TMPDIR/x"' 'for f in a b; do rm "$f"; done' 'rm `cat list`' 'rm ~/x' 'rm -rf dist/{a,b}'; do
    dn "$c" "expands at run time" || return 1
  done
  dn_new 'rm -rf "$TMPDIR/x"' "expands at run time" '$TMPDIR/x' || return 1
  dn_new 'rm ~/x' "expands at run time" '~/x' || return 1
}

@test "deny OUTSIDE: paths outside the project, the root, its ancestors, .." {
  local c alt=""
  for c in "rm /etc/hosts.bak" "mv a ../b" "cd src && rm -f a.o && cd .." "rm -rf $ROOT" "rm -rf $ROOT//" \
    "find $ROOT/. -delete" "rsync -a --delete e/ $ROOT/./" "rm -rf $(dirname "$ROOT")"; do
    dn "$c" "is outside them" || return 1
  done
  case "$ROOT" in /private/*) alt="${ROOT#/private}" ;; /var/*|/tmp/*) alt="/private$ROOT" ;; esac
  if [ -n "$alt" ]; then dn "rm -rf $alt" "is outside them" || return 1; fi
  dn_new "rm /etc/hosts.bak" "is outside them" /etc/hosts.bak || return 1
}

@test "deny BARE: ., globs that can match .claude, find without a start dir" {
  local c
  for c in "rm -rf ." "rm -rf ./." "rm -rf .//." "rm -rf *" "rm -rf .c*" "find . -name '*.log' -delete" \
    "find -name x -delete" "git rm -r --cached ." "grep -rw rm ."; do
    dn "$c" "is too broad" || return 1
  done
  dn_new "rm -rf *" "is too broad" '*' || return 1
}

@test "deny PIPE: xargs, parallel and cd without a path" {
  local c
  for c in "echo a | xargs rm -f" "ls *.bak | xargs -I{} mv {} backup/" "cd && rm -rf build" "cd - ; rm -rf build" "popd; rm x"; do
    dn "$c" "hides what is touched" || return 1
  done
  dn_new "echo a | xargs rm -f" "hides what is touched" xargs || return 1
}

@test "deny CWD: a cwd outside the project and the scratchpad" {
  local p
  p="$(bash_payload "rm -rf build" agent-1 | jq -c --arg cwd "$(dirname "$ROOT")" '.cwd = $cwd')"
  run_hook $GUARD "$p"
  [ "$(decision)" = deny ]
  case "$(reason)" in *"working directory inside"*) ;; *) echo "$(reason)"; return 1 ;; esac
  case "$(reason)" in *"$(dirname "$ROOT")"*) ;; *) echo "cwd missing: $(reason)"; return 1 ;; esac
}

@test "README spellings of a delete on the root are all denied" {
  local c nl=$'\n'
  for c in '/bin/mv $PWD /tmp/x' '/usr/bin/nice mv $PWD /tmp/x' 'sudo -u root mv $PWD /tmp/x' \
    'env -C / mv $PWD /tmp/x' 'busybox mv $PWD /tmp/x' 'gtimeout 5 mv $PWD /tmp/x' '> "x find" mv $PWD /tmp/x' \
    'echo `find . -delete`' 'function f { mv $PWD /tmp/x; }; f' 'coproc mv $PWD /tmp/x' 'MV $PWD /tmp/x' \
    'FIND . -delete' "sh -c 'rm -rf .'" "sh <<'EOF'${nl}rm -rf .${nl}EOF"; do
    denied "$c" || return 1
  done
}

@test "unit: class and word per failure" {
  u 'rm -rf "$TMPDIR/x"' EXPANSION '$TMPDIR/x'
  u 'rm ~/notes.bak' EXPANSION '~/notes.bak'
  u 'rm -rf dist/{a,b}' EXPANSION 'dist/{a,b}'
  u 'rm -rf a/{{}}' EXPANSION 'a/{{}}'
  u 'rm -f /etc/hosts.bak' OUTSIDE /etc/hosts.bak
  u 'mv a ../b' OUTSIDE ../b
  u 'rm -rf /Users/u/p' OUTSIDE /Users/u/p
  u 'rm -rf /Users/u/p//' OUTSIDE /Users/u/p//
  u 'rm -rf /Users/u' OUTSIDE /Users/u
  u 'rm -rf .' BARE .
  u 'rm -rf .//.' BARE './/.'
  u 'rm -rf .C*' BARE '.C*'
  u 'rm -rf ?claude' BARE '?claude'
  u 'rm -rf *e' BARE '*e'
  u 'rm -rf [.]claude' BARE '[.]claude'
  u 'find -name x -delete' BARE -name
  u 'find src -name x -delete; find' BARE find
  u 'cd - ; rm x' PIPE cd
  u 'echo a | xargs rm' PIPE xargs
  u 'rm x' CWD /Users/u "/Users/u/p" /Users/u
  # first failing word decides; CWD only when nothing else fails
  u 'rm -rf $A /etc/x' EXPANSION '$A'
  u 'rm /etc/x ; cd' OUTSIDE /etc/x
  u 'xargs rm /nowhere' OUTSIDE /nowhere
  u 'xargs rm dist' PIPE xargs /Users/u/p /Users/u
}

@test "unit: harmless words pass" {
  u1 'rm -rf dist'
  u1 'rm -rf /Users/u/p/dist'
  u1 'rm -rf *.tmp src/*.ts'
  u1 'sed s/a/b/ x ; mv a b 2>/dev/null'
  u1 'rm -rf /dev/null /dev/stdout /dev/stderr'
  u1 'rm -rf {} -I{}'
  u1 'cd src && rm -f a.o'
  u1 'rm -rf /sp/coder-s3' /Users/u/p /Users/u/p /sp
  u1 'rm -rf dist' /Users/u/p /sp/lane /sp
  u1 'if [ -d build ]; then rm -rf build; fi'
  u1 'git status'
  u1 'find src -name x'
}

@test "unit: a temp tree is harmless unless the root or cwd lies in it" {
  u1 'rm -rf /tmp/build-x'
  u1 'rm -rf /private/tmp/build-x'
  u1 'rm -rf /var/folders/ab/cd/T/x'
  u 'rm -rf /tmp' OUTSIDE /tmp
  u 'rm -rf /tmp/' OUTSIDE /tmp/
  u 'rm -rf /tmp/other-x' OUTSIDE /tmp/other-x /tmp/proj
  u 'rm -rf /private/tmp/other-x' OUTSIDE /private/tmp/other-x /tmp/proj
  u 'rm -rf /tmp/other-x' OUTSIDE /tmp/other-x /Users/u/p /tmp/lane
  u 'rm -rf /var/folders/a/b' OUTSIDE /var/folders/a/b /private/var/folders/q/proj
  u1 'rm -rf /tmp/proj/x' /tmp/proj
}

@test "unit: no scratchpad known means only project paths" {
  u 'rm -rf /sp/coder-s3' OUTSIDE /sp/coder-s3
}

@test "scratchpad unknown: no transcript_path, the lookup fails quietly and only project paths pass" {
  run_hook $GUARD "$(bash_payload 'rm -rf dist' agent-1)"
  [ "$(decision)" != deny ] || { echo "$(reason)"; return 1; }
  run_hook $GUARD "$(bash_payload 'rm -rf dist /etc/x' agent-1)"
  [ "$(decision)" = deny ]
  case "$(reason)" in *"is outside them"*) ;; *) echo "$(reason)"; return 1 ;; esac
  case "$(reason)" in */etc/x*) ;; *) echo "word missing: $(reason)"; return 1 ;; esac
  [ -z "$(printf '%s' "$output" | grep -i 'crash\|could not finish')" ]
}

# --- fix round 1 ---
@test "C1: a glued option value, a host: prefix, and a root without its leading slash are not harmless" {
  local b="${ROOT#/}"
  u 'env -C.. rm -rf p' OUTSIDE '-C..'
  u 'env -C/ rm -rf Users/u/p' OUTSIDE '-C/'
  u 'env -C.. find p -delete' OUTSIDE '-C..'
  u 'sudo -D.. rm -rf p' OUTSIDE '-D..'
  u 'git -C.. rm -r p' OUTSIDE '-C..'
  u 'rsync -a --delete e/ localhost:/Users/u/p/' OUTSIDE 'localhost:/Users/u/p/'
  u 'rm -rf host:dir' OUTSIDE 'host:dir'
  denied "env -C.. rm -rf $(basename "$ROOT")" || return 1
  denied "env -C/ rm -rf $b" || return 1
  u1 'if mv a b; then :; fi'
}
@test "C2: a glob in a dot component can match .. and is bare" {
  u 'rsync -a --delete e/ src/.?/' BARE 'src/.?/'
  u 'mv src/.* x' BARE 'src/.*'
  u 'rm -rf src/.[.]' BARE 'src/.[.]'
  u 'find src -name .*.swp -delete' BARE '.*.swp'
  u 'rm -rf /Users/u/p/src/.*' BARE '/Users/u/p/src/.*'
  denied "rsync -a --delete e/ src/.?/" || return 1
}
@test "C3: an absolute path below the root judges its first component like a relative word" {
  u 'rm -rf /Users/u/p/*' BARE '/Users/u/p/*'
  u 'rm -rf /Users/u/p/.c*' BARE '/Users/u/p/.c*'
  u 'rm -rf /Users/u/p/.claude' BARE '/Users/u/p/.claude'
  u1 'rm -rf /Users/u/p/src/*.ts'
  denied "rm -rf $ROOT/*" || return 1
  denied "rm -rf $ROOT/.c*" || return 1
}
@test "still harmless: dots inside names, literal dot components, redirects" {
  u1 'git rm src/old.ts'
  u1 'rm -f src/a.b.c'
  u1 'rm -rf src/.cache'
  u1 'mv src/a..b src/c'
  u1 'rm -rf build 2>/dev/null'
}
@test "I1: the prefilter starts no awk for a command without a trigger word" {
  local shim="$BATS_TEST_TMPDIR/shim" real c
  real="$(command -v awk)"
  mkdir -p "$shim"
  printf '#!/bin/sh\necho run >> "%s/awk.log"\nexec %s "$@"\n' "$BATS_TEST_TMPDIR" "$real" > "$shim/awk"
  chmod +x "$shim/awk"
  for c in 'git log --format=%H -1' 'terraform plan' 'ls src' 'echo format' 'git commit -m term'; do
    : > "$BATS_TEST_TMPDIR/awk.log"
    PATH="$shim:$PATH" "$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=/Users/u/p; _MK_GS_PROOT=/Users/u/p; _MK_GS_CWD=/Users/u/p; _MK_GS_DEL_INIT=1
      _mk_gs_del_hit "$2"; exit $?' _ "$BATS_TEST_TMPDIR/del.sh" "$c" && { echo "rc 0 for $c"; return 1; }
    [ ! -s "$BATS_TEST_TMPDIR/awk.log" ] || { echo "awk ran for: $c"; return 1; }
  done
  for c in '/bin/rm x' 'RM x' "r''m x" 'x=rm' 'a;rm b' 'find . -delete' "find . -de'l'ete" 'find . -"delete"' 'find . -de\lete' '`rm x`' 'x=`rm x`'; do
    : > "$BATS_TEST_TMPDIR/awk.log"
    PATH="$shim:$PATH" "$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=/Users/u/p; _MK_GS_PROOT=/Users/u/p; _MK_GS_CWD=/Users/u/p; _MK_GS_DEL_INIT=1
      _mk_gs_del_hit "$2"; exit 0' _ "$BATS_TEST_TMPDIR/del.sh" "$c"
    [ -s "$BATS_TEST_TMPDIR/awk.log" ] || { echo "awk did not run for: $c"; return 1; }
  done
}

@test "main session: not judged by this hook" {
  run_hook $GUARD "$(bash_payload 'rm -rf "$TMPDIR/x"')"
  [ "$(decision)" != deny ]
}

@test "fix round 2: a quote-glued -delete and a backquote-wrapped command are judged" {
  u "find /etc/x -de'l'ete" OUTSIDE /etc/x
  u 'find ../x -"delete"' OUTSIDE ../x
  u 'find /Users -de\lete' OUTSIDE /Users
  u '`rm -rf .`' BARE .
  u 'x=`rm -rf .`' BARE .
  u 'rm `cat list`' EXPANSION '`cat'
  u '$(rm -rf .)' EXPANSION '$'
  dn "find /etc/x -de'l'ete" "is outside them" || return 1
  dn 'find . -"delete"' "is too broad" || return 1
  dn 'x=`rm -rf .`' "is too broad" || return 1
  denied 'echo `rm -rf .`' || return 1
}

# Found by the 0.8.4 differential (0.8.5 task 3): spellings the old segment
# parser denied that the first version of the gate let through.
@test "deny: an expansion glued to the tool name, and a glob find start directory" {
  denied 'rm${IFS}-rf${IFS}`pwd`' || return 1
  denied 'rm${IFS}-rf${IFS}$PWD' || return 1
  denied 'rm$x -rf src' || return 1
  denied 'find src/* -delete' || return 1
  denied 'find src/a?/b -delete' || return 1
  allowed "find src -name '*.tmp' -delete" || return 1
  allowed "find src -delete" || return 1
}

# Fix round 1, finding 1: an expansion glued to the tool name after a path.
@test "fix round 1: rm\$x/abs, /bin/rm\$x/abs and find\$x are triggers" {
  u 'x=" -rf "; rm$x/Users/u/p' EXPANSION 'rm$x/Users/u/p' || return 1
  u 'x=" -rf "; /bin/rm$x/Users/u/p' EXPANSION '/bin/rm$x/Users/u/p' || return 1
  u 'x=" "; find$x . -delete' EXPANSION 'find$x' || return 1
  u 'x=" "; find$x. -delete' EXPANSION 'find$x.' || return 1
  u 'x=" "; find$x/Users -delete' EXPANSION 'find$x/Users' || return 1
  u 'find$x . -delete' EXPANSION 'find$x' || return 1
}
@test "fix round 1: a glued expansion on rm of an ancestor of the root is denied end to end" {
  denied "x=' -rf '; rm\$x$(dirname "$ROOT")" || return 1
}

# 0.8.5 task 5: a temp tree is harmless only below its top level, and never
# inside a Claude tree that is not the session's own scratchpad.
@test "unit: a glob at the top of a temp tree, with a literal prefix that cannot start claude-, is BARE" {
  u 'rm -f /tmp/mk-*.tmp' BARE '/tmp/mk-*.tmp' || return 1
  u 'rm -rf /private/tmp/b*' BARE '/private/tmp/b*' || return 1
  u 'rm -rf /tmp/a?b' BARE '/tmp/a?b' || return 1
  u 'rm -rf /var/folders/7n/abc/T*' BARE '/var/folders/7n/abc/T*' || return 1
  u 'rm -rf /var/folders/7n/abc/T/x*' BARE '/var/folders/7n/abc/T/x*' || return 1
}
@test "unit: a glob that can name a claude- directory is OUTSIDE at any depth" {
  local w
  for w in '/tmp/*' '/private/tmp/*' '/private/tmp/cl*' '/tmp/[ab]x' '/var/folders/*/x' '/var/folders/7n/*/T' \
    '/var/folders/7n/abc/T/*' '/var/folders/7n/abc/T/cl*' '/var/folders/7n/abc/T/x/*' '/tmp/x/Cl*' \
    '/tmp/build-x/*' '/tmp/build-x/*.o' '/tmp/build-x/c?x' '/tmp/claude-notes'; do
    u "rm -rf $w" OUTSIDE "$w" || return 1
  done
}
@test "unit: a plain temp name, or a glob whose prefix cannot start claude-, passes below the top" {
  u1 'rm -rf /tmp/build-x' || return 1
  u1 'rm -f /tmp/build-x/out-*.o' || return 1
  u1 'rm -rf /private/tmp/build-x' || return 1
}
@test "unit: grouping and extended glob syntax cannot pass" {
  u "bash -O extglob -c 'rm -rf /private/tmp/c@(laude-501)'" BARE '/private/tmp/c@(' || return 1
  u "bash -O extglob -c 'rm -rf /private/tmp/@(claude-501|x)'" BARE '/private/tmp/@(' || return 1
  u "bash -O extglob -c 'rm -rf /tmp/!(zzz)'" BARE '/tmp/!(' || return 1
  u 'rm -rf /private/tmp/claude(-)501/other/sess/scratchpad' BARE '/private/tmp/claude(' || return 1
  u "bash -O extglob -c 'rm -rf /Users/u/p/.c@(laude)'" BARE '/Users/u/p/.c@(' || return 1
  u 'f() { rm -f a.o; }; f' BARE 'f(' || return 1
  u "zsh -o extendedglob -c 'rm -rf /private/tmp/^keep'" OUTSIDE '/private/tmp/^keep' || return 1
  u "zsh -o extendedglob -c 'rm -rf /private/tmp/c#laude-501/other/sess/scratchpad'" OUTSIDE '/private/tmp/c#laude-501/other/sess/scratchpad' || return 1
  u 'rm -rf ^src' BARE '^src' || return 1
  u 'rm -f notes#1.txt' BARE 'notes#1.txt' || return 1
  u 'rm -rf /Users/u/p/^x' BARE '/Users/u/p/^x' || return 1
}
@test "unit: a comment marker is not a glob" {
  u1 'rm -rf dist # clean' || return 1
  u1 'rm -rf dist #clean' || return 1
}
@test "unit: with no scratchpad known, the cleanup path of the own scratchpad is OUTSIDE" {
  u 'rm -rf /private/tmp/claude-501/x/y/scratchpad/coder-s1' OUTSIDE /private/tmp/claude-501/x/y/scratchpad/coder-s1 || return 1
}
@test "task 5 e2e: without transcript_path the own scratchpad cleanup is denied" {
  run_hook $GUARD "$(bash_payload "rm -rf $TT_SP/coder-s1" agent-1)"
  [ "$(decision)" = deny ]
}
@test "unit: a Claude tree below a temp tree is OUTSIDE unless it is the own scratchpad" {
  u 'rm -rf /tmp/claude-501' OUTSIDE /tmp/claude-501 || return 1
  u 'rm -rf /tmp/a/Claude-x/b' OUTSIDE /tmp/a/Claude-x/b || return 1
  u 'rm -rf /private/tmp/claude-501/other/sess/scratchpad/x' OUTSIDE /private/tmp/claude-501/other/sess/scratchpad/x /Users/u/p /Users/u/p /private/tmp/claude-501/x/y/scratchpad || return 1
  u 'rm -rf /private/tmp/claude-501/x/*' OUTSIDE '/private/tmp/claude-501/x/*' || return 1
  u1 'rm -rf /private/tmp/claude-501/x/y/scratchpad/coder-s1' /Users/u/p /Users/u/p /private/tmp/claude-501/x/y/scratchpad || return 1
  u1 'rm -rf /private/tmp/claude-501/x/y/scratchpad/coder-*' /Users/u/p /Users/u/p /private/tmp/claude-501/x/y/scratchpad || return 1
}
@test "unit: with the root under /tmp, a plain /tmp path is still OUTSIDE" {
  u 'rm -rf /tmp/x' OUTSIDE /tmp/x /tmp/proj || return 1
}
# The class is pinned by a marker text unique to it ("is too broad" is BARE,
# "may only name paths" is OUTSIDE) wherever $PROJ lies outside the temp trees.
# Where it lies inside one (Linux /tmp, macOS /var/folders) the root drops that
# tree and the delete gate denies every word as OUTSIDE, so only the denial is
# checked there.
@test "task 5 e2e: top-level globs and other sessions' Claude trees are denied" {
  local c w
  for c in 'rm -f /tmp/mk-*.tmp' 'rm -rf /private/tmp/b*'; do
    w="${c#rm -* }"
    case "$PROJ" in
      /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) denied "$c" || return 1 ;;
      *) dn_new "$c" 'is too broad' "$w" || return 1 ;;
    esac
  done
  for c in 'rm -rf /tmp/*' 'rm -rf /private/tmp/*' 'rm -rf /private/tmp/cl*' 'rm -rf /var/folders/*/x' \
    'rm -rf /tmp/claude-501' 'rm -rf /private/tmp/claude-501/other/sess/scratchpad/x' \
    'rm -rf /tmp/a/Claude-x/b' 'rm -rf /tmp/build-x/*' 'rm -rf /tmp/x/Cl*'; do
    w="${c#rm -* }"
    case "$PROJ" in
      /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) denied "$c" || return 1 ;;
      *) dn_new "$c" 'may only name paths' "$w" || return 1 ;;
    esac
  done
}
@test "task 5 e2e: the own scratchpad, glob included, still passes after the lookup" {
  allowed "rm -rf $TT_SP/coder-s1" || return 1
  allowed "rm -rf $TT_SP/coder-*" || return 1
  allowed "rm -rf $TROOT_LOGICAL/claude-$TT_UID/$TT_SLUG/$TT_SID/scratchpad/coder-*" || return 1
}

# Fix round 2 (task 5).
@test "unit: a group that starts a word, with its closing parenthesis glued to text, is BARE" {
  u 'rm -rf (.c|x)laude' BARE '(.c|x)laude' || return 1
  u 'rm -rf (.c|)laude' BARE '(.c|)laude' || return 1
  u 'rm -rf (#a1).claudx' BARE '#a1' || return 1
  u 'rm -rf (#a1)/private/tmp/xlaude-501/other/sess/scratchpad' BARE '#a1' || return 1
}
@test "unit: parentheses that are separators stay allowed" {
  u1 'find src \( -name a -o -name b \) -delete' || return 1
  u1 '(cd src && rm -f a.o)' || return 1
  u1 '(cd src; rm -f a.o) && ls' || return 1
  u1 'if (rm -f a.o); then :; fi' || return 1
}
@test "unit: a # is a comment only at the start of a shell word" {
  u1 'rm -rf dist # clean' || return 1
  u1 'rm -rf dist #clean' || return 1
  u1 "$(printf '# cleanup\nrm -rf dist')" || return 1
  u "zsh -o extendedglob -c 'rm -rf /private/tmp/claude=#-501/other/sess/scratchpad'" BARE '#-501/other/sess/scratchpad' || return 1
  u 'rm -rf /private/tmp/c=#laude-501/other/sess/scratchpad' BARE '#laude-501/other/sess/scratchpad' || return 1
  u 'rm -rf .claud=#e' BARE '#e' || return 1
  u 'rm -rf /Users/u/p/.claud=#e' BARE '#e' || return 1
  u 'rm -rf dist;#clean' BARE '#clean' || return 1
  u 'rm -rf dist&&#x' BARE '#x' || return 1
  u 'rm -rf .claud\ #e' BARE '#e' || return 1
  u "rm -rf 'a '#b" BARE '#b' || return 1
  u 'rm -rf dist ## clean' BARE '#' || return 1
}
@test "unit: a find start directory with ^ is BARE" {
  u 'find src/^x -delete' BARE 'src/^x' || return 1
}

# Fix round 3 (task 5).
@test "unit: a marker byte in the view denies as BARE, and no control byte is reported" {
  local stx=$'\002' etx=$'\003' c
  for c in "rm -rf dist ${stx}#.claude" "rm -rf dist ${etx}#.claude" "zsh -o extendedglob -c 'rm -rf dist ${stx}#.claude'" "rm -rf dist #(foo)"; do
    got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=/Users/u/p; _MK_GS_PROOT=/Users/u/p; _MK_GS_CWD=/Users/u/p; _MK_GS_DEL_SCR=; _MK_GS_DEL_INIT=1
      _mk_gs_del_hit "$2"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$c")"
    case "$got" in "0 BARE "*) ;; *) echo "unit: '$c' -> '$got'"; return 1 ;; esac
    case "$got" in *[[:cntrl:]]*) echo "control byte in the word of: $c"; return 1 ;; esac
  done
}
@test "unit: ~ inside a word is a glob character" {
  u "zsh -o extendedglob -c 'rm -rf (.claude~x)'" BARE '.claude~x' || return 1
  u "zsh -o extendedglob -c 'rm -rf (.claude~x|zzz)'" BARE '.claude~x' || return 1
  u "zsh -o extendedglob -c 'mv (.claude~x) src/'" BARE '.claude~x' || return 1
  u "zsh -o extendedglob -c 'rm -rf .claude~x/*'" BARE '.claude~x/*' || return 1
  u 'rm -f notes.txt~' BARE 'notes.txt~' || return 1
  u 'rm -rf ~/x' EXPANSION '~/x' || return 1
}

# Final fix wave. C1: a lane under .claude/worktrees is an ordinary project path.
@test "unit: a path below a lane is ordinary; the lane root and a Claude name below it are not" {
  local L=/Users/u/p/.claude/worktrees/L
  u1 "mv $L/src/a.ts $L/src/b.ts" || return 1
  u1 "rm -f $L/src/old.ts" || return 1
  u1 'rm -rf .claude/worktrees/L/dist' || return 1
  u1 "cd $L/src && rm -f a.o" || return 1
  u "git -C $L mv src/a.ts src/b.ts" OUTSIDE "$L" || return 1
  u "cd $L && rm -rf dist" OUTSIDE "$L" || return 1
  u "rm -rf $L" OUTSIDE "$L" || return 1
  u 'rm -rf .claude/worktrees/L' OUTSIDE .claude/worktrees/L || return 1
  u 'rm -rf .claude/worktrees' BARE .claude/worktrees || return 1
  u 'rm -rf /Users/u/p/.claude/worktrees' BARE /Users/u/p/.claude/worktrees || return 1
  u 'rm -rf /Users/u/p/.claude/worktrees/*/src' BARE '/Users/u/p/.claude/worktrees/*/src' || return 1
  u "rm -rf $L/.claude" BARE "$L/.claude" || return 1
  u "rm -rf $L/.cl*" BARE "$L/.cl*" || return 1
  u "rm -rf $L/src/../x" OUTSIDE "$L/src/../x" || return 1
  u "rm -rf $L/.CLAUDE/x" BARE "$L/.CLAUDE/x" || return 1
  u "rm -rf $L/src/*" BARE "$L/src/*" || return 1
  u 'rm -rf .claude/worktrees/L/.claude/x' BARE .claude/worktrees/L/.claude/x || return 1
  u 'rm -rf .claude/worktrees/L/*' BARE '.claude/worktrees/L/*' || return 1
  u 'rm -rf .claude/worktrees/*/x' BARE '.claude/worktrees/*/x' || return 1
  u 'rm -rf .Claude/worktrees/L/x' BARE .Claude/worktrees/L/x || return 1
}
@test "e2e: a lane of a parallel run can move and delete below itself" {
  local L="$ROOT/.claude/worktrees/mk-r1-a" c
  git -C "$ROOT" worktree add -q "$L" -b mk-r1-a 2>/dev/null || mkdir -p "$L"
  mkdir -p "$L/src" "$L/dist"
  for cwd in "$ROOT" "$L"; do
    for c in "mv $L/src/a.ts $L/src/b.ts" "rm -f $L/src/old.ts" "rm -rf .claude/worktrees/mk-r1-a/dist" "git mv src/a.ts src/b.ts"; do
      [ "$cwd" = "$ROOT" ] && [ "$c" = "git mv src/a.ts src/b.ts" ] && continue
      [ "$cwd" = "$L" ] && [ "${c#rm -rf .claude}" != "$c" ] && continue
      run_hook $GUARD "$(sp_payload "$c" | jq -c --arg cwd "$cwd" '.cwd = $cwd')"
      [ "$(decision)" != deny ] || { echo "denied (cwd $cwd): $c -- $(reason)"; return 1; }
    done
  done
  for c in "rm -rf $L" "rm -rf $ROOT/.claude/worktrees" "rm -rf .claude/worktrees/mk-r1-a" "rm -rf $ROOT/.claude/worktrees/*/src" \
    "rm -rf $L/../x" "rm -rf $L/.claude" "cd $L && rm -rf dist" "git -C $L mv src/a.ts src/b.ts"; do
    denied "$c" || return 1
  done
}

# I1: after a directory change into a temp tree (or with any word harmless only
# through one), a relative word is judged by the Claude-tree tests too.
@test "unit: a relative Claude-tree name after a directory change into a temp tree is OUTSIDE" {
  u 'cd /tmp/x && rm -rf claude-501' OUTSIDE claude-501 || return 1
  u 'cd /tmp/x && rm -rf Claude-501' OUTSIDE Claude-501 || return 1
  u 'cd /tmp/x && rm -rf c*' OUTSIDE 'c*' || return 1
  u 'cd /tmp/x && rm -rf claude-*' OUTSIDE 'claude-*' || return 1
  u 'pushd /tmp/x; rm -rf claude-501/a/b/scratchpad' OUTSIDE claude-501/a/b/scratchpad || return 1
  u 'cd /tmp/x && cd claude-501 && rm -rf a' OUTSIDE claude-501 || return 1
  u 'git -C /tmp/x rm -rf claude-501' OUTSIDE claude-501 || return 1
  u 'git -C /var/folders/zz/abc/T rm -rf claude-501' OUTSIDE claude-501 || return 1
  u 'cd /var/folders/zz/abc/T && rm -rf claude-*' OUTSIDE 'claude-*' || return 1
  u 'rm -rf /tmp/x/a claude-501' OUTSIDE claude-501 || return 1
  u 'rm -rf /tmp/x/a c*' OUTSIDE 'c*' || return 1
  u1 'cd src && rm -f claude-notes.md' || return 1
  u1 'rm -f claude-notes.md' || return 1
  u1 'cd src && rm -rf out/*' || return 1
  u1 'cd /Users/u/p/src && rm -f claude-notes.md' || return 1
  u1 'git -C src rm claude-notes.md' || return 1
  u1 'cd /tmp/build-x && rm -rf out' || return 1
  u1 'cd /tmp/build-x && rm -rf out/dist x.o' || return 1
  u1 'git -C /tmp/build-x rm -rf out' || return 1
  u1 'rm -rf /tmp/build-x/out' || return 1
}
@test "e2e: cd into a temp tree, then a Claude-tree name, is denied" {
  local c
  # (Whether /tmp or /var/folders is a harmless tree here depends on where the
  # fixture root lies; the unit test above pins the class.)
  for c in "cd /tmp/x && rm -rf claude-$TT_UID" "cd /var/folders/zz/abc/T && rm -rf claude-*" \
    "git -C /var/folders/zz/abc/T rm -rf claude-$TT_UID" "cd /tmp/x && cd claude-$TT_UID && rm -rf a"; do
    denied "$c" || return 1
  done
  allowed "cd $ROOT/src && rm -rf out" || return 1
}
# D1
@test "unit: a SOH byte in the view denies as BARE" {
  u $'find src \001 -delete' BARE '(control byte)' || return 1
  u $'rm -rf dist \001 x' BARE '(control byte)' || return 1
}
# M1
@test "unit: a trigger name spelled with a dollar-quote is a trigger" {
  u "\$'rm' -rf x" EXPANSION '$rm' || return 1
  u '$"rm" -rf .' EXPANSION '$rm' || return 1
  u "\$'find' . -delete" EXPANSION '$find' || return 1
  u1 "echo \$'plain'" || return 1
  u1 'ls $rm' || return 1
}

# Closing round. R1: dollar-quoted trigger names and -delete.
@test "unit: a dollar-quoted trigger name or -delete is seen" {
  local c
  for c in "find . \$'-delete'" 'find . $"-delete"' "find . -de\$'l'ete" "find . -delete\$''" "find src \$'-delete'" \
    "\$'r'\$'m' -rf ." '$"r"$"m" -rf .' "\$'rm'\$'dir' /Users/u/p/src" "r\$'m' -rf ."; do
    got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=/Users/u/p; _MK_GS_PROOT=/Users/u/p; _MK_GS_CWD=/Users/u/p; _MK_GS_DEL_SCR=; _MK_GS_DEL_INIT=1
      _mk_gs_del_hit "$2"; echo "$? $_MK_GS_DEL_WHY"' _ "$BATS_TEST_TMPDIR/del.sh" "$c")"
    case "$got" in "0 "*) ;; *) echo "unit: $c -> '$got' (want a hit)"; return 1 ;; esac
  done
  u1 "find src -name '*.pyc' -delete" || return 1
  u1 'echo $HOME' || return 1
  u1 "echo \$form \$'x'" || return 1
  u "find src \$'-delete'" EXPANSION '$-delete' || return 1
  u '$"r"$"m" -rf x' EXPANSION '$r$m' || return 1
  u1 'git commit -m "costs $5"' || return 1
  u1 "echo \$'plain'" || return 1
}
@test "e2e: a dollar-quoted -delete or trigger name is denied; plain dollar commands pass" {
  local c
  for c in "find . \$'-delete'" 'find . $"-delete"' "find . -de\$'l'ete" "find . -delete\$''" "\$'r'\$'m' -rf ." \
    "\$'rm'\$'dir' $ROOT/src" "r\$'m' -rf ."; do
    denied "$c" || return 1
  done
  allowed 'echo $HOME' || return 1
  allowed 'echo "costs $5"' || return 1
  allowed "find src -name '*.pyc' -delete" || return 1
}
@test "unit: the lane root is OUTSIDE (the cd/-C sentence), .claude/worktrees is BARE" {
  u 'rm -rf .claude/worktrees/L' OUTSIDE .claude/worktrees/L || return 1
  u 'rm -rf /Users/u/p/.claude/worktrees/L' OUTSIDE /Users/u/p/.claude/worktrees/L || return 1
  u 'rm -rf .claude/worktrees' BARE .claude/worktrees || return 1
  u 'rm -rf .claude/worktrees/*' BARE '.claude/worktrees/*' || return 1
  dn_new 'cd .claude/worktrees/L && rm -rf dist' "drop the" .claude/worktrees/L || return 1
}
