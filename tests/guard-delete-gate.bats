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
    "rm -rf $L/../x" "rm -rf $L/.claude" "true; cd $L && rm -rf dist" "git -C $L mv src/a.ts src/b.ts"; do
    denied "$c" || return 1
  done
  # 0.8.6: the cd that opens the command is excused.
  allowed "cd $L && rm -rf dist" || return 1
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

# 0.8.6: a leading `cd <root>` (or `cd <lane root>`) is excused; nothing else is.
# ul1 CMD [ROOT] -- the lead rule, then the gate: passes.
ul1() {
  local r="${2:-/Users/u/p}" got
  got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=$2; _MK_GS_PROOT=$2; _MK_GS_CWD=$2; _MK_GS_DEL_SCR=; _MK_GS_DEL_INIT=1
    _mk_gs_del_lead "$3"; _mk_gs_del_hit "$3"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$r" "$1")"
  case "$got" in "1 "*) ;; *) echo "unit: $1 -> '$got' (want pass)"; return 1 ;; esac
}
# ul CMD WHY WORD [ROOT] -- the lead rule, then the gate: rc 0, the class, the word.
ul() {
  local r="${4:-/Users/u/p}" got
  got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=$2; _MK_GS_PROOT=$2; _MK_GS_CWD=$2; _MK_GS_DEL_SCR=; _MK_GS_DEL_INIT=1
    _mk_gs_del_lead "$3"; _mk_gs_del_hit "$3"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$r" "$1")"
  [ "$got" = "0 $2 $3" ] || { echo "unit: $1 -> '$got' (want '0 $2 $3')"; return 1; }
}

@test "unit: a leading cd to the root or a lane root is excused" {
  local R=/Users/u/p L=/Users/u/p/.claude/worktrees/mk-1.2_x nl='
'
  ul1 "cd $R && rm -f a.o" || return 1
  ul1 "cd $R&&rm -f a.o" || return 1
  ul1 "cd $R; rm -rf dist" || return 1
  ul1 "cd $R ; mv src/a.ts src/b.ts" || return 1
  ul1 "cd $R${nl}rm -rf dist" || return 1
  ul1 "cd $R ${nl}rm -rf dist" || return 1
  ul1 "cd $R && rm $R/src/a.ts" || return 1
  ul1 "cd $R && find src -name '*.pyc' -delete" || return 1
  ul1 "cd $R && git commit -q -m 'rm the old file' && rm -f \"a b.txt\"" || return 1
  ul1 "cd $L && rm -rf dist" || return 1
  ul1 "cd $L; mv src/a.ts src/b.ts" || return 1
  ul1 "cd /srv/a-b_c.d/@x%+,:1 && rm x" /srv/a-b_c.d/@x%+,:1 || return 1
}

@test "unit: after a leading cd every other word is judged as before" {
  local R=/Users/u/p L=/Users/u/p/.claude/worktrees/L
  ul "cd $R && rm -rf $R" OUTSIDE "$R" || return 1
  ul "cd $R && rm -rf $R/" OUTSIDE "$R/" || return 1
  ul "cd $R && git -C $R rm x" OUTSIDE "$R" || return 1
  ul "cd $R && rm -rf ." BARE . || return 1
  ul "cd $R && rm -rf *" BARE '*' || return 1
  ul "cd $R && rm -rf .claude" BARE .claude || return 1
  ul "cd $R && cd .. && rm -rf p" OUTSIDE .. || return 1
  ul "cd $R; cd /etc && rm x" OUTSIDE /etc || return 1
  ul "cd $R && rm -rf \$HOME/x" EXPANSION '$HOME/x' || return 1
  ul "cd $R && ls | xargs rm" PIPE xargs || return 1
  ul "cd $L && rm -rf $L" OUTSIDE "$L" || return 1
  ul "cd $L && rm -rf .claude" BARE .claude || return 1
  ul "cd $R && cd $L && rm x" OUTSIDE "$L" || return 1
}

@test "unit: a cd to the root that is not the leading one stays denied" {
  local R=/Users/u/p nl='
'
  ul " cd $R && rm x" OUTSIDE "$R" || return 1
  ul "cd  $R && rm x" OUTSIDE "$R" || return 1
  ul "cd $R/ && rm x" OUTSIDE "$R/" || return 1
  ul "cd \"$R\" && rm x" OUTSIDE "$R" || return 1
  ul "cd '$R' && rm x" OUTSIDE "$R" || return 1
  ul "cd $R || rm x" OUTSIDE "$R" || return 1
  ul "cd $R | rm x" OUTSIDE "$R" || return 1
  ul "cd $R & rm x" OUTSIDE "$R" || return 1
  ul "cd $R rm -rf x" OUTSIDE "$R" || return 1
  ul "cd $R -P; rm x" OUTSIDE "$R" || return 1
  ul "cd -P $R; rm x" OUTSIDE "$R" || return 1
  ul "cd $R \\${nl}&& rm x" OUTSIDE "$R" || return 1
  ul "cd $R\\${nl}/.. && rm -rf p" OUTSIDE "$R" || return 1
  ul "pushd $R && rm x" OUTSIDE "$R" || return 1
  ul "CD $R && rm x" OUTSIDE "$R" || return 1
  ul "true; cd $R && rm x" OUTSIDE "$R" || return 1
  ul "rm -rf \"x;cd\" $R" OUTSIDE "$R" || return 1
  ul "rm x >| cd $R" OUTSIDE "$R" || return 1
  ul "rm -rf x${nl}cd $R; rm y" OUTSIDE "$R" || return 1
  ul "cd /Users/u/p2 && rm x" OUTSIDE /Users/u/p2 || return 1
  ul "cd /Users/u && rm -rf p" OUTSIDE /Users/u || return 1
  ul "cd $R/.claude/worktrees/.. && rm -rf x" OUTSIDE "$R/.claude/worktrees/.." || return 1
  ul "cd $R/.claude/worktrees/. && rm -rf L" BARE "$R/.claude/worktrees/." || return 1
  ul "cd $R/.claude/worktrees/ && rm -rf L" BARE "$R/.claude/worktrees/" || return 1
  ul "cd $R/.claude/worktrees/L* && rm -rf x" BARE "$R/.claude/worktrees/L*" || return 1
  ul "cd $R/.claude/worktrees/L/ && rm -rf x" OUTSIDE "$R/.claude/worktrees/L/" || return 1
}

@test "unit: a root the shell would not read literally is not excused" {
  ul 'cd /Users/u/$p && rm x' EXPANSION '/Users/u/$p' '/Users/u/$p' || return 1
  ul 'cd /Users/u/p* && rm x' OUTSIDE '/Users/u/p*' '/Users/u/p*' || return 1
  ul 'cd /Users/u/a=b && rm x' OUTSIDE /Users/u/a '/Users/u/a=b' || return 1
  ul 'cd /Users/u/pé && rm x' OUTSIDE '/Users/u/pé' '/Users/u/pé' || return 1
}

@test "unit: without the lead rule's word the gate is unchanged" {
  u "cd /Users/u/p && rm -f a.o" OUTSIDE /Users/u/p || return 1
}

@test "e2e: a leading cd to the project root or a lane root passes" {
  local c L="$ROOT/.claude/worktrees/mk-1" P
  P="$(cd -P "$ROOT" && pwd -P)"
  mkdir -p "$L"
  for c in "cd $ROOT && rm -rf dist" "cd $ROOT; mv src/a.ts src/b.ts" "cd $P && rm -f src/a.o" \
    "cd $L && rm -rf dist" "cd $ROOT
cat > notes.txt <<'EOF'
rm the old file
EOF"; do
    allowed "$c" || return 1
  done
  for c in "cd $ROOT && rm -rf $ROOT" " cd $ROOT && rm -rf dist" "cd $ROOT && rm -rf ." "true; cd $ROOT && rm x" \
    "cd \"$ROOT\" && rm x" "cd $ROOT \\
&& rm x" "cd $ROOT && rm -rf .claude" "rm -rf \"x;cd\" $ROOT" "git -C $ROOT rm x"; do
    denied "$c" || return 1
  done
}

# 0.8.6: the session scratchpad itself is a harmless word (`rm -rf <sp>/x; ls <sp>`).
@test "unit: the scratchpad itself is harmless; above it and a root inside it are not" {
  local R=/Users/u/p SP=/private/tmp/claude-501/x/y/scratchpad
  u1 "rm -rf $SP/coder-s1; ls $SP" $R $R $SP || return 1
  u1 "ls $SP/; rm -rf $SP/a" $R $R $SP || return 1
  u1 "cd $SP && rm -rf coder-s1" $R $R $SP || return 1
  u1 "rm -rf $SP" $R $R $SP || return 1
  u1 "mv $SP//./ $SP/x" $R $R $SP || return 1
  u "rm -rf $SP/.." OUTSIDE "$SP/.." $R $R $SP || return 1
  u "rm -rf /private/tmp/claude-501/x/y" OUTSIDE /private/tmp/claude-501/x/y $R $R $SP || return 1
  u "rm -rf /private/tmp/claude-501/x/y/scratchpad2" OUTSIDE /private/tmp/claude-501/x/y/scratchpad2 $R $R $SP || return 1
  u "cd $SP && rm -rf *" BARE '*' $R $R $SP || return 1
  u "cd $SP && rm -rf ." BARE . $R $R $SP || return 1
  u "rm -rf $SP" OUTSIDE "$SP" $R $R || return 1
  # A project that lies inside the scratchpad: the root and every ancestor of it stay outside.
  u "rm -rf $SP" OUTSIDE "$SP" $SP/proj $SP/proj $SP || return 1
  u "rm -rf $SP/proj" OUTSIDE "$SP/proj" $SP/proj $SP/proj $SP || return 1
  u "rm -rf $SP/a" OUTSIDE "$SP/a" $SP/a/proj $SP/a/proj $SP || return 1
  u "rm -rf $SP" OUTSIDE "$SP" $SP $SP $SP || return 1
  u1 "rm -rf $SP/proj/dist $SP/other" $SP/proj $SP/proj $SP || return 1
}

@test "e2e: cleaning a scratchpad child and listing the scratchpad passes" {
  allowed "rm -rf $TT_SP/coder-s3; ls $TT_SP" || return 1
  allowed "cd $TT_SP && rm -rf coder-s3" || return 1
  denied "rm -rf $TT_SP/.." || return 1
  denied "rm -rf ${TT_SP%/scratchpad}" || return 1
}

# 0.8.6: the body of a quoted heredoc that feeds python or node is not shell
# text; the delete gate does not judge it. A body that `cat` writes to a file
# is judged (review, 2026-11-18: the same command can run that file).
# ub1 CMD -- the body rule, then the gate: passes.
ub1() {
  local got
  got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=/Users/u/p; _MK_GS_PROOT=/Users/u/p; _MK_GS_CWD=/Users/u/p; _MK_GS_DEL_SCR=; _MK_GS_DEL_INIT=1
    _mk_gs_del_body "$2"; _mk_gs_del_hit "$_MK_GS_DEL_BODY"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$1")"
  case "$got" in "1 "*) ;; *) echo "unit: $1 -> '$got' (want pass)"; return 1 ;; esac
}
# ub CMD WHY WORD -- the body rule, then the gate: rc 0, the class, the word.
ub() {
  local got
  got="$("$MK_BASH" -c 'set -f; . "$1"; MK_ROOT=/Users/u/p; _MK_GS_PROOT=/Users/u/p; _MK_GS_CWD=/Users/u/p; _MK_GS_DEL_SCR=; _MK_GS_DEL_INIT=1
    _mk_gs_del_body "$2"; _mk_gs_del_hit "$_MK_GS_DEL_BODY"; echo "$? $_MK_GS_DEL_WHY $_MK_GS_DEL_WORD"' _ "$BATS_TEST_TMPDIR/del.sh" "$1")"
  [ "$got" = "0 $2 $3" ] || { echo "unit: $1 -> '$got' (want '0 $2 $3')"; return 1; }
}
# ubk CMD -- the body rule keeps CMD whole (nothing is dropped).
ubk() {
  local got
  got="$("$MK_BASH" -c 'set -f; . "$1"; _mk_gs_del_body "$2"; [ "$_MK_GS_DEL_BODY" = "$2" ] && echo same' _ "$BATS_TEST_TMPDIR/del.sh" "$1")"
  [ "$got" = same ] || { echo "unit: a body was dropped from: $1"; return 1; }
}
# hd OPENER BODY [AFTER] -- a command: the opener line, the body, the end line
# END, then AFTER (default: a harmless delete). Built here so that no test
# holds a literal heredoc.
hd() {
  printf '%s\n%s\nEND\n%s' "$1" "$2" "${3-rm -f a.o}"
}
# A body no shell could pass: an expansion, a bare word, a path outside.
BODY='import os; s=open("a").read()
rm -rf ~/x $HOME .. /etc run('
BAD='x = 1
rm -rf ~/x'

@test "unit: a quoted heredoc body for python or node is not judged" {
  local o
  for o in "python3 - <<'END'" "python3 <<'END'" "python - <<'END'" "node - <<'END'" 'node <<"END"' "python3 - << 'END'" \
    "cd src && python3 - <<'END'" "ls; node - <<'END'" "  python3 - <<'END'  "; do
    ub1 "$(hd "$o" "$BODY")" || return 1
  done
  # The trigger word only in the body: nothing to judge.
  ub1 "$(hd "python3 - <<'END'" 'rm -rf ~' '')" || return 1
  # Two bodies, and another tag.
  ub1 "$(printf '%s\n%s\nPY_1\n%s' "python3 - <<'PY_1'" "$BODY" "$(hd "node - <<'END'" "$BODY" 'mv c.txt b.txt')")" || return 1
  # A line that only looks like the end (a blank after it, or before it) is body.
  ub1 "$(hd "python3 - <<'END'" "END $(printf '\n') END$(printf '\n')rm -rf ~/x")" || return 1
}

@test "unit: shell text after a heredoc body is judged as before" {
  ub "$(hd "python3 - <<'END'" 'x = 1' 'rm -rf ~/x')" EXPANSION '~/x' || return 1
  ub "$(hd "node - <<'END'" 'x' 'rm -rf /etc/x')" OUTSIDE /etc/x || return 1
}

@test "unit: a heredoc that is not on the list keeps its body judged" {
  local o
  for o in "python3 - <<END" "bash <<'END'" "sh -s <<'END'" "zsh <<'END'" "python3 -c x <<'END'" "python3 - a <<'END'" "python3 x.py <<'END'" \
    "sudo python3 - <<'END'" "env python3 - <<'END'" "X=1 python3 - <<'END'" "do python3 - <<'END'" "/usr/bin/python3 - <<'END'" "PYTHON3 - <<'END'" \
    "cat <<'END'" "cat <<'END' | sh" "cat - > a.txt <<'END'" "tee a.txt <<'END'" "cat > a.txt b.txt <<'END'" "cat > a.txt <<'END' ; sh a.txt" \
    "cat > notes.txt <<'END'" "cat >> src/a.md <<'END'" "cat <<'END' > src/a.md" "cat >/Users/u/p/src/x.py <<'END'" "ls; cat > a.txt <<'END'" \
    "cat > /dev/stdout <<'END'" "cat > /DEV/stdout <<'END'" "cat > //dev/stdout <<'END'" "cat > /./dev/stdout <<'END'" "cat > /proc/self/fd/1 <<'END'" \
    "cat > ../../dev/stdout <<'END'" "cat > a/../../dev/stdout <<'END'" "cat > ./a.txt <<'END'" 'cat > $f <<'"'END'" "cat >&2 <<'END'" "cat > a* <<'END'" "cat > ~/a <<'END'" \
    "python3 - <<-'END'" "python3 - <<<'END'" "python3 - <<'END' <<'B'" "python3 - <<'E-D'" 'python3 - <<\END' "python3 - <<  'END'" \
    "python3 - <<'END' && true" "python3 - <<'END' | sh" "python3 - <<'END' 2>&1" "python3 - 2>e.log <<'END'" "true & python3 - <<'END'" "true || python3 - <<'END'" \
    'echo "x"; python3 - <<'"'END'" "echo 'x'; python3 - <<'END'" 'echo \x; python3 - <<'"'END'" 'echo `x`; python3 - <<'"'END'" "# python3 - <<'END'" "true # c; python3 - <<'END'" \
    "{ true; cat > a.txt <<'END'" "(python3 - <<'END'" "f() python3 - <<'END'" "true | python3 - <<'END'" "alias python3=sh; python3 - <<'END'" "function python3; python3 - <<'END'"; do
    ubk "$(hd "$o" "$BAD")" || return 1
  done
}

@test "unit: text before the heredoc that could change how the shell reads it switches the rule off" {
  local o nl='
'
  for o in 'echo "open' "echo 'open" 'echo x \' 'true # note' 'alias python3=sh' 'python3() { sh; }' 'true | cat' 'x=`date`' 'bash <<X' "cat <<'X'${nl}X" \
    ': $[ 1 +' 'a[1 +' 'echo $((1 +' '[[ a ==' 'echo $x' 'ls ~' 'echo !x' 'ls [ab]' 'PATH=/tmp/e:/bin' 'path=/tmp/e' 'cdpath=/tmp' 'Path=x' 'export X=1' 'hash -p /bin/sh python3' 'ln -s /bin/sh python3' \
    'BASH_ENV=x true' '. ./env.sh' 'true; . env.sh' 'source env.sh' 'eval x' 'exec 3>a' 'set -k' 'setopt aliases' 'enable -n cd' 'builtin cd src' 'command -p ls' 'trap x 0' 'declare -f' 'café'; do
    ubk "$o${nl}$(hd "python3 - <<'END'" 'rm -rf ~/x')" || return 1
  done
  # A << that the shell reads as a shift, not a heredoc (review, 2026-11-18):
  # the lines after it are commands.
  ubk ": \$[ 1 +${nl}python3 <<\"E\"${nl}] ; rm -rf /Users/u/p${nl}E${nl}echo after" || return 1
  ub ": \$[ 1 +${nl}python3 <<\"E\"${nl}] ; rm -rf /Users/u/p${nl}E${nl}echo after" EXPANSION '$[' || return 1
  ubk "a[1 +${nl}python3 <<\"E\"${nl}]=5 ; rm -rf /Users/u/p${nl}E${nl}echo after" || return 1
  ub "a[1 +${nl}python3 <<\"E\"${nl}]=5 ; rm -rf /Users/u/p${nl}E${nl}echo after" OUTSIDE /Users/u/p || return 1
  # Plain text before the opener keeps the rule on.
  ub1 "ls src; mkdir -p out/a && touch out/a/x.txt >/dev/null 2>&1${nl}$(hd "python3 - <<'END'" 'rm -rf ~/x')" || return 1
  # A body that cat writes to a file is judged, whatever follows it: the
  # command can run the file without naming it as written (review, 2026-11-18).
  for o in 'sh x.sh' 'sh x.s[h]' 'sh X.SH' 'make' 'rm -f y.sh' 'true'; do
    ubk "$(hd "cat > x.sh <<'END'" 'rm -rf ~/x' "$o")" || return 1
    ubk "$(hd "cat <<'END' >> out/x.sh" 'rm -rf ~/x' "$o")" || return 1
  done
  ubk "for i in 1 2; do sh x.sh; $(hd "cat > x.sh <<'END'" 'rm -rf ~/x' 'done')" || return 1
  ubk "for i in 1; do cd /dev; $(hd "cat > stdout <<'END'" 'rm -rf ~/x' 'done | sh')" || return 1
  ub "$(hd "cat > x.sh <<'END'" 'rm -rf ~/x' 'sh x.s[h]')" EXPANSION '~/x' || return 1
  # No end line: nothing is dropped.
  ubk "python3 - <<'END'${nl}rm -rf ~/x${nl}rm -f a.o" || return 1
  ub "python3 - <<'END'${nl}rm -rf ~/x${nl}rm -f a.o" EXPANSION '~/x' || return 1
  ub "python3 - <<'END'${nl}rm -rf ~/x${nl} END${nl}rm -f a.o" EXPANSION '~/x' || return 1
  # After a body, the same conditions hold for the next one.
  ub "$(hd "python3 - <<'END'" 'x' 'echo "y"')${nl}$(hd "python3 - <<'END'" 'rm -rf ~/x')" EXPANSION '~/x' || return 1
}

@test "e2e: a python heredoc body is not judged by the delete gate; a shell's or cat's is" {
  allowed "$(hd "cd $ROOT; python3 - <<'END'" "p='README.md'; s=open(p).read()
s=s.replace('rm old', 'mv new')
open(p,'w').write(s)" 'rm -f README.md.bak')" || return 1
  denied "$(hd "cat > notes.txt <<'END'" 'rm -rf $HOME is what not to run (see ../docs)' 'mv old.txt src/old.txt')" || return 1
  denied "$(hd "cat > x.sh <<'END'" 'rm -rf ~/x' 'sh x.s[h]')" || return 1
  denied "$(hd "cat > Makefile <<'END'" 'all:; rm -rf ~/x' 'make')" || return 1
  denied "$(hd "bash <<'END'" 'rm -rf ~/x' '')" || return 1
  denied "$(hd "python3 - <<END" 'rm -rf ~/x')" || return 1
  denied "$(hd "python3 - <<'END'" 'x = 1' "rm -rf $ROOT")" || return 1
  # The other gates still read the body.
  denied "$(hd "cat > notes.txt <<'END'" 'x' 'rm -f .claude/memokit.json')" || return 1
}

# 0.8.6: a view that ends in a newline is not judged a second time as its flat
# view; the verdicts are those of the same command without the newline.
@test "e2e: a newline at the end, and a backslash-newline, change no verdict" {
  local c nl='
'
  for c in "rm -rf dist" "rm -f src/a.o \\${nl}  src/b.o" "ls src \\${nl}  tests" "mv src/a.ts \\${nl}src/b.ts"; do
    allowed "$c" || return 1
    allowed "$c$nl" || return 1
  done
  for c in "rm -rf $ROOT" "rm -rf \\${nl}$ROOT" "mv -t /tmp/x \\${nl}\$PWD" "rm -rf dist \\${nl}.claude" "rm -rf src/../.." "rm \\${nl}-rf ~/x" "r\\${nl}m -rf $ROOT"; do
    denied "$c" || return 1
    denied "$c$nl" || return 1
    denied "$c$nl$nl" || return 1
  done
}
