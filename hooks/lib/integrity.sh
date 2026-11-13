# shellcheck shell=bash
# memokit hook library: the runtime integrity check (0.8.1) shared by
# check-integrity.sh (digest, compare, markers, the one-time main-session
# deny) and inject-rules.sh (the one-time prompt notices). bash 3.2-safe.
# Sourced after lib/common.sh (MK_ROOT, MK_HOOKS_DIR, _mk_state_write,
# mk_msg).
#
# State under <TMPDIR>/memokit-<cksum of MK_ROOT>- (as _mk_session_tmp names
# it), careful-state by name (lib/careful.sh), written by the safe writer:
#   careful-integrity-<sid>-<tool_use_id>    the Pre record;
#   careful-integrity-base-<sid>-<agent>     the agent's baseline (its first
#                                            Pre; renewed after a reported
#                                            change), compared at SubagentStop;
#   careful-armed-<sid>-<agent>              the agent has a baseline: a
#                                            missing record or baseline is
#                                            then a change (a name the
#                                            careful-integrity-* glob misses);
#   careful-integrity-perm-<sid>             the allow rules permission prompts
#                                            suggested (record-permission.sh,
#                                            PermissionRequest), one JSON line
#                                            each, the last 64.
# The markers have a root-independent name, <TMPDIR>/memokit-0-careful-
# integrity-KIND-<sid> (written by check-integrity.sh, read by it and by
# inject-rules.sh; the main-session fast path tests the alert by name, with
# no glob over the temp dir):
#   memokit-0-careful-integrity-alert-<sid>  the main-session deny is owed;
#   memokit-0-careful-integrity-notice-<sid> the prompt notice is owed;
#   memokit-0-careful-integrity-allow-<sid>  permission rules added during a
#                                            call (prompt notice only);
#   memokit-0-careful-integrity-broad-<sid>  broad permission rules added
#                                            during a call after a prompt
#                                            (a notice asking to confirm).
# A Pre record is a line "@@t <time>" (jq's now when the Pre hook ran), one
# line "@@settings <JSON>" (a copy of each small settings file,
# mk_integrity_settings_copy) and the digest; a baseline written later
# (mk_integrity_record) has no @@t line. The
# alert and notice markers hold changed paths, one per line ("?": unknown);
# the allow and broad markers "<settings path>|<rule>". Each marker is removed by the
# side that consumed it, so the deny and the notices happen once each, in
# either order.

MK_IG_NL='
'
MK_IG_SMALL_MAX=65536

# _mk_ig_plugin_scope PR -- sets MK_IG_FROOT (the plugin root find starts
# from) and MK_IG_FPRUNE (a directory find skips, or empty). The project tree
# is exempt (memokit run with --plugin-dir on its own checkout, or the
# project is a worktree inside the plugin checkout: its files are the
# project's own source) under the conditions of the plugin gate of
# guard-subagent-authority.sh (_mk_gs_plug_init / _mk_gs_plug_inpx):
# CLAUDE_PROJECT_DIR resolves to MK_ROOT (as named or physically), MK_ROOT
# lies in neither ~/.claude/plugins nor $CLAUDE_CONFIG_DIR/plugins, and the
# root is the project or lies above it (physical paths, case-exact). Then
# find runs on the physical root and skips the physical project tree; the
# rest of the checkout stays protected. Resolved by cd in this shell (no
# fork; it returns to where it started).
_mk_ig_cd() {
  _MK_IG_CD=""
  cd "$_MK_IG_O" 2>/dev/null && cd "$@" 2>/dev/null && _MK_IG_CD="$PWD"
}
_mk_ig_plugin_scope() {
  local mp pp cl cp hp="" dp="" CDPATH='' _MK_IG_O="$PWD" _MK_IG_CD=""
  MK_IG_FROOT="$1"; MK_IG_FPRUNE=""
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -n "$MK_ROOT" ] || return 0
  _mk_ig_cd -P "$MK_ROOT"; mp="$_MK_IG_CD"
  _mk_ig_cd "$CLAUDE_PROJECT_DIR"; cl="$_MK_IG_CD"
  _mk_ig_cd -P "$CLAUDE_PROJECT_DIR"; cp="$_MK_IG_CD"
  _mk_ig_cd -P "$1"; pp="$_MK_IG_CD"
  if [ -n "${HOME:-}" ]; then _mk_ig_cd -P "$HOME/.claude/plugins"; hp="$_MK_IG_CD"; fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then _mk_ig_cd -P "$CLAUDE_CONFIG_DIR/plugins"; dp="$_MK_IG_CD"; fi
  cd "$_MK_IG_O" 2>/dev/null || true
  [ -n "$mp" ] && [ -n "$pp" ] || return 0
  [ "$cl" = "$MK_ROOT" ] || [ "$cp" = "$mp" ] || return 0
  case "$mp/" in "${pp%/}"/*) ;; *) return 0 ;; esac
  case "$mp/" in "${hp:-/nonexistent}"/*|"${dp:-/nonexistent}"/*) return 0 ;; esac
  MK_IG_FROOT="$pp"; MK_IG_FPRUNE="$mp"
  return 0
}

# mk_integrity_settings_paths -- MK_IG_SETS: the settings files of the
# project, the user and $CLAUDE_CONFIG_DIR, one per line (no fork).
mk_integrity_settings_paths() {
  local nl="$MK_IG_NL"
  MK_IG_SETS="$MK_ROOT/.claude/settings.json$nl$MK_ROOT/.claude/settings.local.json"
  [ -z "${HOME:-}" ] || MK_IG_SETS="$MK_IG_SETS$nl$HOME/.claude/settings.json$nl$HOME/.claude/settings.local.json"
  [ -z "${CLAUDE_CONFIG_DIR:-}" ] || MK_IG_SETS="$MK_IG_SETS$nl$CLAUDE_CONFIG_DIR/settings.json$nl$CLAUDE_CONFIG_DIR/settings.local.json"
}

# mk_integrity_copy_args -- MK_IG_JQ_ARGS (an array) and MK_IG_JQ_PROG (a jq
# expression) for a copy of the settings files: {"<path>": "<content>"} for
# each readable regular file of at most MK_IG_SMALL_MAX characters (a larger
# one is left out: no copy, so its change keeps the full alert) and "{}" for
# each absent one (a missing settings file reads as an empty one). The
# program text is built from fixed tokens; the paths are --arg values.
mk_integrity_copy_args() {
  local f i=0
  MK_IG_JQ_ARGS=(); MK_IG_JQ_PROG='{}'
  mk_integrity_settings_paths
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$f" ] && [ -r "$f" ]; then
      MK_IG_JQ_ARGS+=(--arg "p$i" "$f" --rawfile "c$i" "$f")
      MK_IG_JQ_PROG="$MK_IG_JQ_PROG + (if (\$c$i | length) <= $MK_IG_SMALL_MAX then {(\$p$i): \$c$i} else {} end)"
    elif [ ! -e "$f" ] && [ ! -L "$f" ]; then
      MK_IG_JQ_ARGS+=(--arg "p$i" "$f")
      MK_IG_JQ_PROG="$MK_IG_JQ_PROG + {(\$p$i): \"{}\"}"
    fi
    i=$((i + 1))
  done <<EOF
$MK_IG_SETS
EOF
}

# _MK_IG_JOIN -- the awk that builds the digest from cksum's "crc size path"
# lines, a line @@ST, stat's "type:mode:inode:ctime|path" lines, a line
# @@LIST and the protected paths (both commands skip, on stderr, a path they
# cannot read). Prints the number of small settings files (ENVIRON
# MK_IG_SETS_E, cksum succeeded, at most MK_IG_SMALL_MAX bytes), those paths,
# the number of directories and their paths, then the digest; exits 1 when it
# printed an UNREADABLE line. A directory (stat's type "Directory" BSD,
# "directory" GNU; a symlink to one, as stat -L sees it) has no checksum:
# "DIR:<inode>:<ctime>" (mk_integrity_digest then judges the links).
# shellcheck disable=SC2016  # awk program text: $0 and $1 are awk's
_MK_IG_JOIN='
  BEGIN { n = split(ENVIRON["MK_IG_SETS_E"], S, "\n"); for (i = 1; i <= n; i++) if (S[i] != "") isset[S[i]] = 1
          max = ENVIRON["MK_IG_MAX_E"] + 0; m = 0; ns = 0; bad = 0; dig = "" }
  $0 == "@@ST" { m = 1; next }
  $0 == "@@LIST" { m = 2; next }
  m == 0 { p = $0; sub(/^[^ ]* [^ ]* /, "", p); ck[p] = $1 ":" $2; sz[p] = $2 + 0; next }
  m == 1 { i = index($0, "|"); if (!i) next
           p = substr($0, i + 1); s = substr($0, 1, i - 1); j = index(s, ":")
           st[p] = substr(s, j + 1)
           if (tolower(substr(s, 1, j - 1)) == "directory") isdir[p] = 1
           next }
  $0 == "" { next }
  {
    p = $0
    if (p ~ / UNREADABLE$/) { dig = dig p "\n"; bad = 1; next }
    if (!(p in st)) { dig = dig p " ABSENT\n"; next }
    if (p in isdir) { split(st[p], a, ":"); dig = dig p " DIR:" a[2] ":" a[3] "\n"; dirs[++nd] = p; next }
    if (!(p in ck)) { dig = dig p " UNREADABLE\n"; bad = 1; next }
    dig = dig p " " ck[p] ":" st[p] "\n"
    if ((p in isset) && !(p in seen) && sz[p] <= max) { seen[p] = 1; small[++ns] = p }
  }
  END { print ns; for (i = 1; i <= ns; i++) print small[i]
        print nd + 0; for (i = 1; i <= nd; i++) print dirs[i]; printf "%s", dig; exit bad }'

# _MK_IG_LINKS -- the awk that rewrites the digest (stdin) for directory
# links (ENVIRON MK_IG_FIX_E, lines "<path>|<mark>"): mark OUT makes the line
# "<path> UNREADABLE" (exit 1), any other mark is appended to the stamp.
# shellcheck disable=SC2016  # awk program text: $0 is awk's
_MK_IG_LINKS='
  BEGIN { n = split(ENVIRON["MK_IG_FIX_E"], F, "\n"); bad = 0
          for (i = 1; i <= n; i++) if (match(F[i], /\|[^|]*$/)) f[substr(F[i], 1, RSTART - 1)] = substr(F[i], RSTART + 1) }
  { p = $0; sub(/ [^ ]*$/, "", p)
    if (p in f) { if (f[p] == "OUT") { print p " UNREADABLE"; bad = 1 } else print $0 ":" f[p]; next }
    print }
  END { exit bad }'

# _mk_ig_dirlinks DIRS -- MK_IG_FIX: "<path>|<mark>" lines for the symlinks
# among DIRS (directories the digest stamped; a real directory is left as
# is). Each link is resolved (cd -P) and judged in one step. Covered, mark
# "L<crc>.<size>" (cksum of its link text): the target lies inside the
# physical plugin root (case-exact) and, compared lower-cased (a
# case-insensitive volume keeps the link's spelling, TESTS or .Git), not in
# an area find prunes (tests/, .in_use/, .git/ but .git/hooks/, the exempt
# project tree MK_IG_FPRUNE): find lists its files under their real paths.
# Anything else, a target that cannot be resolved or holds a newline
# included, is "OUT". Lower-casing only ever marks more links OUT. Forks per
# link: tr, and readlink and cksum when covered; resolved by cd in this
# shell.
_mk_ig_dirlinks() {
  local p t c rp lr lf lp lc out CDPATH='' _MK_IG_O="$PWD" _MK_IG_CD="" nl="$MK_IG_NL"
  MK_IG_FIX=""
  _mk_ig_cd -P "$MK_IG_FROOT"; rp="$_MK_IG_CD"
  # A root or exempt tree holding a newline: no link is covered.
  case "$rp$nl${MK_IG_FPRUNE:-}" in *"$nl"*"$nl"*) rp="" ;; esac
  lc="$(printf '%s\n%s' "$rp" "${MK_IG_FPRUNE:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  lr="${lc%%"$nl"*}"; lf=""
  [ -z "${MK_IG_FPRUNE:-}" ] || lf="${lc#*"$nl"}"
  while IFS= read -r p; do
    # shellcheck disable=SC2015  # continue is the else of both tests (0.9 flags it)
    [ -n "$p" ] && [ -L "$p" ] || continue
    _mk_ig_cd -P "$p"; t="$_MK_IG_CD"; out=0
    case "$t" in ''|*"$nl"*) out=1 ;; esac
    if [ "$out" = 0 ] && [ -n "$rp" ]; then
      case "$t/" in "$rp"/*) ;; *) out=1 ;; esac
    else
      out=1
    fi
    if [ "$out" = 0 ]; then
      lp="$(printf '%s' "$t" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
      case "$lp/" in
        "$lr"/tests/*|"$lr"/.in_use/*) out=1 ;;
        "$lr"/.git/hooks/*) ;;
        "$lr"/.git/*) out=1 ;;
      esac
      if [ -n "$lf" ]; then
        case "$lp/" in "${lf%/}"/*) out=1 ;; esac
      fi
    fi
    if [ "$out" = 1 ]; then MK_IG_FIX="$MK_IG_FIX$p|OUT$nl"; continue; fi
    t="$(readlink "$p" 2>/dev/null)"
    c="$(printf '%s' "$t" | cksum)"
    MK_IG_FIX="$MK_IG_FIX$p|L${c%% *}.${c#* }$nl"
  done <<EOF
$1
EOF
  cd "$_MK_IG_O" 2>/dev/null || true
}

# mk_integrity_digest SNAPSHOT -- the digest of the protected set: one line
# per path, "<path> <stamp>", in MK_IG_DIGEST (also printed). The set: the
# settings files (mk_integrity_settings_paths), <root>/.claude/memokit.json,
# the session's config snapshot SNAPSHOT, and every file or symlink under
# the plugin root ($MK_HOOKS_DIR/..) except tests/, .in_use/ (Claude Code's
# per-process markers in the plugin cache), the project tree when exempt
# (_mk_ig_plugin_scope) and everything in .git/ but config and hooks/.
# Stamp: <cksum crc>:<size>:<mode>:<inode>:<ctime> of the file (a symlink's
# target): ctime, which a user cannot set (a rename, chmod or in-place
# rewrite with a forged CRC all show), in nanoseconds where stat gives them
# (BSD; GNU: seconds). A directory, or a symlink to one (find lists the
# link), has no content to checksum: DIR:<inode>:<ctime>, so an unchanged one
# compares equal; a link to one adds :L<cksum of its link text> when it
# resolves inside the plugin root, and is UNREADABLE when it resolves outside
# (_mk_ig_dirlinks; files behind it would go undigested). ABSENT: stat cannot reach it (missing, or a symlink
# to nothing); UNREADABLE: stat can but cksum cannot read it, or "<plugin
# root>/ UNREADABLE" when find failed. Exit 1 when there is an UNREADABLE
# line. MK_IG_SMALL: the settings files read whole and of at most
# MK_IG_SMALL_MAX bytes. One find, one cksum, one stat and one awk for the
# whole set: no per-file shell loop.
mk_integrity_digest() {
  local p out n i rc=0 fl="" nl="$MK_IG_NL" IFS="$MK_IG_NL" sf=1 dirs CDPATH='' _MK_IG_O _MK_IG_CD
  local -a files prune
  mk_integrity_settings_paths
  p="${MK_HOOKS_DIR%/*}"
  MK_IG_PR="${p:-/}"
  _mk_ig_plugin_scope "$MK_IG_PR"
  # find starts from the physical root: a root that is itself a symlink
  # (--plugin-dir through a link) would otherwise be listed as that one link
  # and stamped as a directory, its files unchecked. Unresolvable: find
  # fails on the name as given (UNREADABLE).
  _MK_IG_CD=""; _MK_IG_O="$PWD"
  _mk_ig_cd -P "$MK_IG_FROOT"
  cd "$_MK_IG_O" 2>/dev/null || true
  [ -z "$_MK_IG_CD" ] || MK_IG_FROOT="$_MK_IG_CD"
  prune=()
  [ -z "$MK_IG_FPRUNE" ] || prune=(-o -path "$MK_IG_FPRUNE")
  if ! p="$(find "$MK_IG_FROOT" \( -path "$MK_IG_FROOT/tests" -o -path "$MK_IG_FROOT/.in_use" \
        -o \( -path "$MK_IG_FROOT/.git/*" ! -path "$MK_IG_FROOT/.git/hooks" ! -path "$MK_IG_FROOT/.git/hooks/*" ! -path "$MK_IG_FROOT/.git/config" \) \
        ${prune[@]+"${prune[@]}"} \) -prune -o \( -type f -o -type l \) -print 2>/dev/null)"; then
    fl="$MK_IG_FROOT/ UNREADABLE"
  fi
  # Split on newlines only, no globbing (word splitting, no loop).
  case "$-" in *f*) sf=0 ;; esac
  set -f
  # shellcheck disable=SC2206  # split on IFS (newline) on purpose, under set -f
  files=($MK_IG_SETS "$MK_ROOT/.claude/memokit.json" "$1" $p)
  [ "$sf" = 0 ] || set +f
  IFS=' '
  case "${OSTYPE:-}" in
    darwin*|*bsd*)
      out="$( { cksum -- "${files[@]}" 2>/dev/null; echo @@ST; stat -L -f '%HT:%Lp:%i:%Fc|%N' -- "${files[@]}" 2>/dev/null
                echo @@LIST; [ -z "$fl" ] || printf '%s\n' "$fl"; printf '%s\n' "${files[@]}"; } |
              MK_IG_SETS_E="$MK_IG_SETS" MK_IG_MAX_E="$MK_IG_SMALL_MAX" LC_ALL=C awk "$_MK_IG_JOIN")" || rc=1 ;;
    *)
      out="$( { cksum -- "${files[@]}" 2>/dev/null; echo @@ST; stat -L -c '%F:%a:%i:%Z|%n' -- "${files[@]}" 2>/dev/null
                echo @@LIST; [ -z "$fl" ] || printf '%s\n' "$fl"; printf '%s\n' "${files[@]}"; } |
              MK_IG_SETS_E="$MK_IG_SETS" MK_IG_MAX_E="$MK_IG_SMALL_MAX" LC_ALL=C awk "$_MK_IG_JOIN")" || rc=1 ;;
  esac
  MK_IG_SMALL=""; MK_IG_DIGEST=""; dirs=""
  {
    IFS= read -r n
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    i=0
    while [ "$i" -lt "$n" ]; do IFS= read -r p; MK_IG_SMALL="$MK_IG_SMALL$p$nl"; i=$((i + 1)); done
    IFS= read -r n
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    i=0
    while [ "$i" -lt "$n" ]; do IFS= read -r p; dirs="$dirs$p$nl"; i=$((i + 1)); done
    IFS= read -r -d '' MK_IG_DIGEST
  } <<EOF
$out
EOF
  MK_IG_DIGEST="${MK_IG_DIGEST%"$nl"}"
  # Directory links (rare: none in an installed plugin): each gets its link
  # text in the stamp, so a retarget shows; one that resolves outside the
  # plugin root (its files are not digested) is UNREADABLE on every call.
  if [ -n "$dirs" ] && [ -n "$MK_IG_DIGEST" ]; then
    _mk_ig_dirlinks "$dirs"
    if [ -n "$MK_IG_FIX" ]; then
      MK_IG_DIGEST="$(printf '%s\n' "$MK_IG_DIGEST" | MK_IG_FIX_E="$MK_IG_FIX" LC_ALL=C awk "$_MK_IG_LINKS")" || rc=1
    fi
  fi
  [ -n "$MK_IG_DIGEST" ] || { MK_IG_DIGEST="$MK_IG_FROOT/ UNREADABLE"; rc=1; }
  printf '%s\n' "$MK_IG_DIGEST"
  return "$rc"
}

# mk_integrity_settings_copy -- one line of JSON, the copy of the settings
# files (mk_integrity_copy_args). One jq (--rawfile: jq 1.6). Prints null
# when jq fails: no copy, so any settings change keeps the full alert.
mk_integrity_settings_copy() {
  local out
  mk_integrity_copy_args
  if out="$(jq -cn ${MK_IG_JQ_ARGS[@]+"${MK_IG_JQ_ARGS[@]}"} "$MK_IG_JQ_PROG" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s' "$out"
  else
    printf 'null'
  fi
}

# mk_integrity_record SNAPSHOT -- a record (or baseline) of the protected set
# now: the settings line, then the digest; the digest's own lines are in
# MK_IG_DIGEST.
mk_integrity_record() {
  mk_integrity_digest "$1" >/dev/null
  printf '@@settings %s\n%s\n' "$(mk_integrity_settings_copy)" "$MK_IG_DIGEST"
}

# mk_integrity_changed RECORD -- the paths whose line differs between the
# digest of RECORD (its @@ line skipped) and the digest on stdin, plus every
# UNREADABLE path of the digest on stdin (a digest that cannot be computed
# counts as a change); sorted, control characters dropped. A path listed
# twice (CLAUDE_CONFIG_DIR is ~/.claude, the project is $HOME or holds the
# plugin) is compared once.
mk_integrity_changed() {
  LC_ALL=C awk '
    $0 == "" || /^@@/ { next }
    NR == FNR { a[$0] = 1; next }
    $0 in s { next }
    { s[$0] = 1; if ($0 in a) delete a[$0]; else d[$0] = 1 }
    / UNREADABLE$/ { d[$0] = 1 }
    END {
      for (k in a) d[k] = 1
      for (k in d) { p = k; sub(/ [^ ]*$/, "", p); print p }
    }' "$1" - | LC_ALL=C sort -u | LC_ALL=C tr -d '\001-\011\013-\037\177'
}

# mk_integrity_allow_only CHANGED SETTINGS_LINE -- exit 0 and print
# "<path>|<rule>" lines when the only change in CHANGED (paths) is rules
# ADDED to permissions.allow of settings files (what answering a permission
# prompt with "Yes, and don't ask again" writes): every changed path is a
# settings file, its Pre copy (SETTINGS_LINE, the record's @@settings JSON)
# and its current content (a regular file of at most MK_IG_SMALL_MAX bytes)
# are JSON objects equal but for permissions.allow (an empty array under
# permissions, such as the "deny": [] and "ask": [] of a settings file the
# first "don't ask again" creates, counts as absent), the old allow list is
# kept whole and at least one rule was added. Exit 1 otherwise (full alert).
# One jq, run only on the change path.
mk_integrity_allow_only() {
  local p i=0 prog='{}' sets out nl="$MK_IG_NL"
  local -a args
  args=()
  mk_integrity_settings_paths
  sets="$MK_IG_SETS"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$nl$sets$nl" in *"$nl$p$nl"*) ;; *) return 1 ;; esac
    case "$nl$MK_IG_SMALL" in *"$nl$p$nl"*) ;; *) return 1 ;; esac
    args+=(--arg "p$i" "$p" --rawfile "c$i" "$p")
    prog="$prog + {(\$p$i): \$c$i}"
    i=$((i + 1))
  done <<EOF
$1
EOF
  [ "$i" -gt 0 ] || return 1
  out="$(printf '%s' "$2" | jq -r ${args[@]+"${args[@]}"} '
    def norm: del(.permissions.allow)
      | if (.permissions | type) == "object" then .permissions |= with_entries(select(.value != [])) else . end
      | if .permissions == {} then del(.permissions) else . end;
    def allow: (.permissions.allow // []);
    . as $old | ('"$prog"') as $cur
    | [ $cur | keys[] as $p
        | try (
            ($old[$p] | fromjson) as $o | ($cur[$p] | fromjson) as $n
            | if ($o | type) == "object" and ($n | type) == "object"
                 and (($o.permissions // {}) | type) == "object" and (($n.permissions // {}) | type) == "object"
                 and ($o | allow | type) == "array" and ($n | allow | type) == "array"
                 and ($o | norm) == ($n | norm)
                 and ((($o | allow) - ($n | allow)) == [])
                 and ((($n | allow) - ($o | allow)) | length) > 0
              then (($n | allow) - ($o | allow)) | map("\($p)|\(tostring)")
              else null end
          ) catch null ]
    | if length > 0 and all(. != null) then .[][] else "FULL" end' 2>/dev/null)" || return 1
  case "$out" in ''|FULL|*"${nl}FULL"*) return 1 ;; esac
  printf '%s\n' "$out" | LC_ALL=C tr -d '\000-\011\013-\037\177'
}

# mk_integrity_perm_ok RULES PERMFILE PRE_T POST_T DIGEST -- exit 0 only when every
# "<path>|<rule>" line of RULES (mk_integrity_allow_only) is backed by a real
# permission prompt during this call: a line of the permission record
# PERMFILE (careful-integrity-perm-<sid>, written by record-permission.sh on
# PermissionRequest: {"t","tool","dest","rule"} per suggested allow rule)
# with a time after PRE_T (this call's PreToolUse) and not after POST_T (this
# PostToolUse; a future time never matches), the same rule, and a
# destination that writes the path (localSettings: <root>/.claude/
# settings.local.json; projectSettings: <root>/.claude/settings.json;
# userSettings: ~/.claude/settings.json or $CLAUDE_CONFIG_DIR/settings.json).
# The prompt's tool and tool_input do not count: "don't ask again" answered on
# a parallel call of the agent (any tool) writes the file while this call
# runs. Anything uncertain (no record, a record that is not ours, no PRE_T or
# POST_T, a line that does not parse, jq missing) is exit 1: the full alert.
# A record backs every call whose window holds it, but only for one change:
# when first used it is bound ("s") to the settings file's stamp after the
# change (its line in DIGEST, this Post's digest), and a later Post may use
# it only when its own stamp of that file is the same (two parallel calls of
# agents both see the one change; a second edit, or the rule removed and
# added again, has another stamp: the full alert). A record expires 10
# minutes after its time: it backs nothing, and expired lines are pruned on
# read. PERMFILE is rewritten (safe writer, from the snapshot jq read) only
# when lines expired or a record was bound; a binding that cannot be written
# is exit 1. One jq. The read, the decision and the rewrite hold PERMFILE's
# lock (_mk_ig_lock; record-permission.sh's append takes it too); a lock not
# taken in time is exit 1 (fail closed) unless a rule is "full" (exit 2 needs
# no record).
#
# Each rule has a class. "full", exit 2 whatever the record says (the full
# alert, and the caller keeps the baseline): a bare tool name, a pattern of
# only * / : . ~ and blanks (Bash(*), Read(**), Edit(~/**)), and any rule
# naming .claude, settings, memokit, plugins, the CLAUDE_CONFIG_DIR or
# memokit's plugin root (case-insensitive). "broad" (on exit 0 in
# MK_IG_BROAD: the caller gives it a notice of its own that asks the user to
# confirm it): a bounded Edit/Write/MultiEdit/NotebookEdit/Read pattern or a
# WebFetch domain with a * (Edit(src/**), Write(docs/*.md), Read(src/**),
# WebFetch(domain:*.example.com)), a Bash rule whose command has a *
# other than one trailing ":*" (a prefix rule such as Bash(npm run test:*) is
# not broad) or whose first word is not a plain [A-Za-z0-9._/+-] word or is
# (by basename) a shell, interpreter or wrapper (bash, sh, zsh, fish, dash,
# ksh, python*, node, deno, bun, ruby, perl, php, lua, env, xargs, eval,
# exec, sudo, doas, command, nohup, timeout, watch, nice, time, source, .,
# find, awk, gawk, mawk, nawk, sed, gsed, npx, pnpx, bunx, uvx, busybox, gdb,
# lldb, vim, vi, ex, nvim, emacs, osascript, Rscript, tclsh, wish, ssh,
# script, stdbuf, setsid, chroot, unshare, flock, parallel, less, more, man,
# tar: each can run an arbitrary command or edit any file). Any other rule is
# "narrow" (on exit 0 in MK_IG_NARROW). Both lists hold lines of RULES, each
# ending in a newline.
mk_integrity_perm_ok() {
  local rc lk=0
  MK_IG_NARROW=""; MK_IG_BROAD=""
  [ -n "$1" ] || return 1
  if [ -f "$2" ] || [ -L "$2" ]; then
    _mk_ig_lock "$2" && lk=1
  fi
  if [ "$lk" = 1 ]; then
    _mk_ig_perm_ok "$@"; rc=$?
    rmdir "$2.lock" 2>/dev/null
  else
    # No record, or its lock not taken: judge the classes alone.
    _mk_ig_perm_ok "$1" /dev/null "${3:-}" "${4:-}" "${5:-}"; rc=$?
    [ "$rc" = 2 ] || rc=1
    MK_IG_NARROW=""; MK_IG_BROAD=""
  fi
  return "$rc"
}

# _mk_ig_lock FILE -- takes FILE.lock (mkdir): 20 tries 50 ms apart; a lock
# older than 30 s (its holder died) is removed once. Exit 1 when not taken.
_mk_ig_lock() {
  local l="$1.lock" i=0 m n
  while [ "$i" -lt 20 ]; do
    mkdir "$l" 2>/dev/null && return 0
    if [ "$i" = 0 ] && [ -d "$l" ] && [ ! -L "$l" ]; then
      case "${OSTYPE:-}" in
        darwin*|*bsd*) m="$(stat -f %m "$l" 2>/dev/null)" ;;
        *) m="$(stat -c %Y "$l" 2>/dev/null)" ;;
      esac
      n="$(date +%s)"
      case "$m$n" in *[!0-9]*|'') ;; *) [ $((n - m)) -le 30 ] || rmdir "$l" 2>/dev/null ;; esac
    fi
    i=$((i + 1))
    sleep 0.05
  done
  return 1
}

# _mk_ig_perm_ok -- mk_integrity_perm_ok's work, under the lock.
_mk_ig_perm_ok() {
  local out l rest="" px=0 pb=0 nl="$MK_IG_NL" pr="${MK_IG_PR:-}" ev="$2"
  MK_IG_NARROW=""; MK_IG_BROAD=""
  [ -n "$1" ] || return 1
  # No record of ours: no rule is backed, but a "full" rule still says so.
  { [ -f "$ev" ] && [ ! -L "$ev" ] && [ -O "$ev" ]; } || ev=/dev/null
  if [ -z "$pr" ]; then pr="${MK_HOOKS_DIR%/*}"; pr="${pr:-/}"; fi
  out="$(printf '%s' "$1" | jq -Rrs --rawfile ev "$ev" --arg pt "${3:-}" --arg ut "${4:-}" --arg dg "${5:-}" \
      --arg root "$MK_ROOT" --arg home "${HOME:-}" --arg ccd "${CLAUDE_CONFIG_DIR:-}" --arg plug "$pr" '
    def bashbroad($c):
      ($c | sub(":\\*$"; "")) as $cmd
      | ($cmd | capture("^\\s*(?<w>\\S*)").w) as $w
      | ($cmd | contains("*"))
        or ($w | test("^[A-Za-z0-9._/+-]+$") | not)
        or (($w | sub(".*/"; "")) as $b
            | ($b | test("^(bash|sh|zsh|fish|dash|ksh|python[0-9.]*|node|deno|bun|ruby|perl|php|lua|env|xargs|eval|exec|sudo|doas|command|nohup|timeout|watch|nice|time|source|\\.|find|awk|gawk|mawk|nawk|sed|gsed|npx|pnpx|bunx|uvx|busybox|gdb|lldb|vim|vi|ex|nvim|emacs|osascript|Rscript|tclsh|wish|ssh|script|stdbuf|setsid|chroot|unshare|flock|parallel|less|more|man|tar)$")));
    def class($r; $deny):
      ($r | capture("^(?<t>[A-Za-z0-9_]+)\\((?<c>.*)\\)$"; "s")? // null) as $x
      | if $x == null then "full"
        elif ($x.c | test("^[\\s*/:.~]*$")) then "full"
        elif (($r | ascii_downcase) as $lr | any($deny[]; . as $w | $w != "" and ($lr | contains($w)))) then "full"
        elif (($x.t == "Edit" or $x.t == "Write" or $x.t == "MultiEdit" or $x.t == "NotebookEdit"
               or $x.t == "Read" or $x.t == "WebFetch")
              and ($x.c | contains("*"))) then "broad"
        elif $x.t == "Bash" and bashbroad($x.c) then "broad"
        else "narrow" end;
    ([".claude", "settings", "memokit", "plugins", ($ccd | ascii_downcase), ($plug | ascii_downcase)]
     | map(select(. != "" and . != "/"))) as $deny
    | (try ($pt | tonumber) catch null) as $T
    | (try ($ut | tonumber) catch null) as $U
    | (now - 600) as $X
    | ([ $ev | split("\n") | to_entries[] | select(.value | length > 0)
         | {i: .key, s: .value, v: (.value | try fromjson catch null)} ]) as $L
    | [ $L[] | select(.v | type == "object") | select((.v.t | type) == "number" and .v.t > $X) ] as $E
    | [ $L[] | select((.v | type) == "object" and (.v.t | type) == "number" and .v.t <= $X) ] as $old
    | ([ $dg | split("\n")[] | capture("^(?<p>.*) (?<s>[^ ]*)$")? | {(.p): .s} ] | add // {}) as $S
    | ([ {p: ($root + "/.claude/settings.local.json"), dest: "localSettings"},
         {p: ($root + "/.claude/settings.json"), dest: "projectSettings"} ]
       + (if $home != "" then [{p: ($home + "/.claude/settings.json"), dest: "userSettings"}] else [] end)
       + (if $ccd != "" then [{p: ($ccd + "/settings.json"), dest: "userSettings"}] else [] end)) as $map
    | [ split("\n")[] | select(length > 0) | . as $l
        | ([ $map[] | .p as $mp | select($l | startswith($mp + "|")) | $mp ][0]
           // ($l | capture("^(?<p>[^|]*)").p)) as $p
        | ($l | .[($p | length) + 1:]) as $rule
        | ($S[$p] // null) as $sp
        | {l: $l, c: class($rule; $deny), s: $sp,
           i: (if $sp == null then null else
               ([ $map[] | . as $m | select($m.p == $p)
                  | $E[] | select((.v.t | type) == "number" and .v.t > $T and .v.t <= $U
                                  and .v.dest == $m.dest and .v.rule == $rule
                                  and ((.v.s // null) == null or .v.s == $sp))
                  | .i ][0]) end)} ]
    | . as $r
    | (if any($r[]; .c == "full") then "FULL"
       elif $T != null and $U != null and ($r | length) > 0 and all($r[]; .i != null) then "OK"
       else "NO" end) as $st
    | (if $st == "OK" then [ $r[] | {i, s} ] else [] end) as $bind
    | ([ $bind[] | .i as $k | $E[] | select(.i == $k and (.v.s // null) == null) ] | length > 0) as $nb
    | $st,
      (if $st == "OK" then ($r[] | (if .c == "broad" then "B" else "N" end) + .l) else empty end),
      (if $nb then "Y" else empty end),
      (if ($old | length) > 0 or $nb
       then "X", ($L[] | select(.i as $k | any($old[]; .i == $k) | not)
                  | . as $e | ([ $bind[] | select(.i == $e.i) | .s ][0]) as $s
                  | "R" + (if $s == null then $e.s
                           elif ($e.v.s // null) == null then ($e.v + {s: $s} | tojson)
                           else $e.s end))
       else empty end)' 2>/dev/null)" || return 1
  # The added rules and at most 64 record lines: a bounded read loop.
  while IFS= read -r l; do
    case "$l" in
      B*) MK_IG_BROAD="$MK_IG_BROAD${l#B}$nl" ;;
      N*) MK_IG_NARROW="$MK_IG_NARROW${l#N}$nl" ;;
      X) px=1 ;;
      Y) pb=1 ;;
      R*) rest="$rest${l#R}$nl" ;;
    esac
  done <<EOF
${out#*"$nl"}
EOF
  # Rewrite (only when needed) from the snapshot jq read (no second read of
  # the file): without the expired lines, with the stamps of newly bound
  # records. A binding that cannot be written backs nothing: exit 1.
  if [ "$px" = 1 ] && [ "$ev" != /dev/null ]; then
    if ! printf '%s' "$rest" | _mk_state_write "$2" 2>/dev/null; then
      [ "$pb" = 0 ] || return 1
    fi
  fi
  case "${out%%"$nl"*}" in OK) return 0 ;; FULL) return 2 ;; *) return 1 ;; esac
}

# mk_integrity_mark FILE LIST -- adds the lines of LIST to marker FILE (the
# safe writer; at most 50 lines, first seen first). A symlink, FIFO or other
# non-regular file planted at FILE is removed first (rm, never followed); a
# directory stays and the write fails (exit 1; the caller still reports).
mk_integrity_mark() {
  local old=""
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ] && [ ! -d "$1" ]; }; then rm -f "$1" 2>/dev/null; fi
  if [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]; then old="$(head -n 50 "$1")"; fi
  printf '%s\n%s\n' "$old" "$2" | LC_ALL=C awk 'NF && !seen[$0]++' | head -n 50 | _mk_state_write "$1"
}

# mk_integrity_label PATH -- a fixed label for a protected path (S39: never
# the raw path): the settings files, memokit.json, the snapshot by name; a
# plugin file as its path relative to the plugin root, filtered to
# [A-Za-z0-9._/-] and cut to 80 characters; "?" unknown; anything else "a
# protected file".
mk_integrity_label() {
  local r pr="${MK_IG_PR:-}" pp="${MK_IG_FROOT:-}"
  if [ -z "$pr" ]; then r="${MK_HOOKS_DIR%/*}"; pr="${r:-/}"; fi
  [ -n "$pp" ] || pp="$(cd -P "$pr" 2>/dev/null && pwd -P)"
  case "$1" in
    '?') mk_msg IG_FILES_UNKNOWN; return ;;
    "$MK_ROOT/.claude/settings.json") mk_msg IG_L_PROJECT_SETTINGS; return ;;
    "$MK_ROOT/.claude/settings.local.json") mk_msg IG_L_PROJECT_LOCAL; return ;;
    "$MK_ROOT/.claude/memokit.json") mk_msg IG_L_CONFIG; return ;;
  esac
  if [ -n "${HOME:-}" ]; then
    case "$1" in
      "$HOME/.claude/settings.json") mk_msg IG_L_USER_SETTINGS; return ;;
      "$HOME/.claude/settings.local.json") mk_msg IG_L_USER_LOCAL; return ;;
    esac
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    case "$1" in
      "$CLAUDE_CONFIG_DIR/settings.json") mk_msg IG_L_CCD_SETTINGS; return ;;
      "$CLAUDE_CONFIG_DIR/settings.local.json") mk_msg IG_L_CCD_LOCAL; return ;;
    esac
  fi
  case "${1##*/}" in memokit-*-careful-config-*) mk_msg IG_L_SNAPSHOT; return ;; esac
  case "$1" in
    "${pr%/}/"|"${pp%/}/") mk_msg IG_L_PLUGIN_DIR; return ;;
    "${pr%/}"/*) r="${1#"${pr%/}"/}" ;;
    "${pp%/}"/*) r="${1#"${pp%/}"/}" ;;
    *) mk_msg IG_L_OTHER; return ;;
  esac
  r="$(printf '%s' "$r" | LC_ALL=C tr -cd 'A-Za-z0-9._/-' | cut -c1-80)"
  mk_msg IG_L_PLUGIN "${r:-?}"
}

# mk_integrity_list -- the marker lines on stdin (control characters dropped,
# only lines that start with / or are exactly ?) as one phrase: the first 10
# labels joined with ", ", then IG_MORE for the rest.
mk_integrity_list() {
  local l out="" n=0
  while IFS= read -r l; do
    case "$l" in '?'|/*) ;; *) continue ;; esac
    n=$((n + 1))
    [ "$n" -le 10 ] || continue
    out="${out:+$out, }$(mk_integrity_label "$l")"
  done <<EOF
$(LC_ALL=C tr -d '\000-\011\013-\037\177' | head -n 50)
EOF
  [ "$n" -gt 10 ] && out="$out $(mk_msg IG_MORE "$((n - 10))")"
  [ -n "$out" ] || out="$(mk_msg IG_L_OTHER)"
  printf '%s' "$out"
}

# mk_integrity_rules -- the allow marker's lines on stdin ("<path>|<rule>",
# control characters dropped, a path that starts with /) as one phrase:
# "<label>: <rule>" (the rule filtered to a plain charset and cut to 80),
# the first 10 joined with "; ", then IG_MORE.
mk_integrity_rules() {
  local l p r out="" n=0
  while IFS= read -r l; do
    case "$l" in /*'|'*) ;; *) continue ;; esac
    n=$((n + 1))
    [ "$n" -le 10 ] || continue
    p="${l%%|*}"; r="${l#*|}"
    r="$(printf '%s' "$r" | LC_ALL=C tr -cd 'A-Za-z0-9 ._:/*()=@,+~-' | cut -c1-80)"
    out="${out:+$out; }$(mk_integrity_label "$p"): $r"
  done <<EOF
$(LC_ALL=C tr -d '\000-\011\013-\037\177' | head -n 50)
EOF
  [ "$n" -gt 10 ] && out="$out $(mk_msg IG_MORE "$((n - 10))")"
  printf '%s' "$out"
}

# mk_integrity_take FILE [RULES] -- claims marker FILE (a regular file of
# ours, not a symlink) by renaming it, so of two hooks racing for it one
# wins; prints it (mk_integrity_list, or mk_integrity_rules with RULES) and
# removes it. Exit 1 when there was nothing to claim.
mk_integrity_take() {
  local t="$1.$$"
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  mv -f "$1" "$t" 2>/dev/null || return 1
  if [ ! -f "$t" ] || [ -L "$t" ]; then rm -f "$t"; return 1; fi
  if [ -n "${2:-}" ]; then mk_integrity_rules < "$t"; else mk_integrity_list < "$t"; fi
  rm -f "$t"
}
