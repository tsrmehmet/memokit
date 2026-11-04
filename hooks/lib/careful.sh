#!/usr/bin/env bash
# memokit destructive-command matcher (and, from Task 3, approval grants).
# Sourced by guard-destructive.sh, inject-rules.sh and session-start.sh after
# lib/common.sh, never executed. bash 3.2-safe.
#
# Matching is text based: accident prevention, not a sandbox. Commands built
# from variables or hidden inside script files are not seen.
#
# Git/rm/kubectl/helm/docker/ef rules run per segment (split on && || ; |
# and newlines) and are case-sensitive (-D is not -d). SQL and project
# patterns run on the whole text, case-insensitive, because a heredoc body
# spans several lines.
#
# Recursive rm is also exempt inside the current session's temp scratchpad
# and for a whole stale sibling temp entry (lib/temp.sh, mk_temp_rm_safe),
# but only when the whole command is one simple rm (mk_careful_single_rm)
# and the caller ran mk_temp_init (guard-destructive.sh does).
#
# Every rule also runs on a flat view (mk_careful_flat) that undoes quoting,
# escaping and grouping, so "rm", r''m, \rm, {rm,-rf,x} or (git reset --hard)
# are seen as the command they run. Views are only ever added: a label found
# in any view stands. Fail closed: a command too long to check in bounded
# time is labelled too-large, a flat view that cannot be built unparsed.

MK_CF_SAFE_RM="node_modules bin obj dist build .next coverage TestResults __pycache__ .pytest_cache"
# Longer commands (in characters), or more distinct rm segments, are not
# matched but labelled too-large: the check stays well inside the hook
# timeout, which would let the command run unchecked.
MK_CF_MAX_CHARS=65536
MK_CF_MAX_RM_SEGS=1000
# Unique prefixes of long options, which git and GNU rm accept as the option:
# --r .. --recursive, --fo .. --force, --ha .. --hard.
MK_CF_RECURSIVE='--r(e(c(u(r(s(i(ve?)?)?)?)?)?)?)?'
MK_CF_FORCE='--fo(r(ce?)?)?'
MK_CF_HARD='--ha(rd?)?'
# A word the shell computes ($VAR, ${VAR}, $'..', a glob such as /bin/r?)
# anywhere in a segment, right before rm's recursive option, after options
# rm also has: it may well be rm, so it counts as one (fail closed, no
# safelist). The word is not parsed as a command position (0.7.2 tried that
# and missed "a)$RM", function heads and unknown wrappers: a blacklist of
# wrappers is never complete).
MK_CF_DYNRM='(^|[[:space:]])[^[:space:]]*([$*?]|\[[^][:space:]]*\])[^[:space:]]*([[:space:]]+(-[dfiIPRrvWx]+|--[[:alnum:]-]+))*[[:space:]]+(-[dfiIPRrvWx]*[rR][dfiIPRrvWx]*|'"$MK_CF_RECURSIVE"')([[:space:]]|$)'
# Exemption (0.7.2, BL-449: grep -n "Send.*Key" -r tests, jq '.[]' -r f and
# ls *.cs -R were denied), decided once on the raw command text (not per
# line, not on the flat view): a command that is ONE
# segment (_mk_cf_oneseg on every view AND on the raw text: no ; | && || " & "
# or newline anywhere, quoted or not, because quotes are not parsed and a
# separator inside quotes would fake a segment starting with grep; the raw
# text is also one line: continuation lines are never exempt), whose
# FIRST word is exactly one of the tools below (bare name + blank: not
# grep(), /tmp/grep, grep2 or "grep"; no absolute path; no leading NAME=value,
# so LC_ALL=C grep stays denied) and which holds no substitution or grouping
# ( ` ( ) < > & or backslash (redirections are never exempt: modelling them
# was fooled by escaping, `a\>&"$RM" -rf y` runs "$RM" in the background), and
# in which every $
# is followed by a letter or _ (plain $NAME, "$NAME"; so no ${..}, $[..],
# $((..)), $(..), $'..', $".." , $1, $@, $=x, $~x, $$ or a trailing $: they
# can run code or spell any option) is not a computed-word rm.
# Premise (README Limitations): in Claude Code's Bash tool grep is a shell
# function running the embedded ugrep, whose --filter/--pager/--view run
# programs; Claude Code's shim falls back to system grep when they appear
# (measured 2026-11-05, ugrep 7.8.4). A shim without that fallback breaks this.
# What was checked (measured on macOS, 2026-11-04): the macOS/BSD man pages/help of
# grep, jq, cp, head, tail, wc, cat, ls and diff were scanned for an option
# that runs a program (diff
# --paginate runs only pr); the GNU variants were NOT measured (documented to
# have no such option). cp --remove-destination/-f replaces a destination
# file by the source. yq is NOT listed (mikefarah's system operator, python
# yq runs jq from PATH). No blacklist of options: a
# command that can run a program is not on the list (0.7.2 tried tar, git
# grep/log and rg with a blacklist and option names built by ${u}, brace
# expansion or quoting slipped through; sed's e, awk's system() and ag's
# --pager are no better). The regex test is byte-wise (LC_ALL=C, _mk_cf_exempt,
# and _mk_cf_oneseg): in a double-byte locale lead byte + backtick is one character.
# Cost: one bash regex test, no fork; when it holds,
# the DYNRM grep pass is skipped.
_mk_cf_exw='(grep|egrep|fgrep|jq|ls|cat|head|tail|wc|diff|cp)'
# shellcheck disable=SC2016  # ERE text: $ and the backtick are literal here
_mk_cf_exu='[^$`<>&()\]|[$][[:alpha:]_]'
MK_CF_DYNEXEMPT="^[[:space:]]*${_mk_cf_exw}[[:space:]]+(${_mk_cf_exu})*\$"
# The approval (grant) file, case-insensitively (macOS file systems are):
# its name, also through a glob that keeps "grant" (careful?grants,
# careful*grants), or a glob on a memokit- path in a word that also names a
# temp location or "careful" (/tmp/memokit-*, $TMPDIR/memokit-*) ->
# careful-state, never approvable. Other globs that may reach it (careful*,
# ../memokit-*) -> careful-state-glob, approvable: memokit-NNN is also a
# common directory name.
_mk_cf_mkglob='memokit-[^[:space:]/.]*[*?[]'
_mk_cf_tmpword='(/tmp/|/private/tmp/|/var/folders/|tmpdir|careful)'
MK_CF_STATE_RE="careful-grants|careful[^[:space:]/.]*[*?[][^[:space:]/.]*grant|${_mk_cf_tmpword}[^[:space:]]*${_mk_cf_mkglob}|${_mk_cf_mkglob}[^[:space:]]*${_mk_cf_tmpword}"
MK_CF_STATE_GLOB_RE='careful[^[:space:]/.]*[*?[]|memokit-[^[:space:]/.]*[*?[]'
# Set (as a local) only by mk_careful_labels; see _mk_cf_rm.
_MK_CF_TEMP_OK=0

# _mk_cf_has ERE TEXT [i] -- ERE test (case-insensitive with "i"), quiet.
# Fail closed: a grep error (exit > 1) counts as a match.
_mk_cf_has() {
  local rc=0
  # grep -q may stop reading at its first match; with SIGPIPE ignored (as in
  # CI runners) printf then reports a write error: not a failure, keep quiet.
  printf '%s' "$2" 2>/dev/null | grep -Eq"${3:-}" -- "$1" 2>/dev/null || rc=$?
  [ "$rc" -ne 1 ]
}

# _mk_cf_empty IN OUT -- true when a stage turned IN into an empty OUT that
# IN does not explain (IN holds more than blanks, quotes, backslashes, ; | &).
_mk_cf_empty() {
  [ -z "$2" ] || return 1
  case "$1" in *[!\\\"\'\;\|\&[:space:]]*) return 0 ;; esac
  return 1
}

# _mk_cf_cmdre WORD SUB-ERE -- ERE: WORD is a command (not part of a longer
# word) and SUB appears later in the segment as a whole word.
_mk_cf_cmdre() {
  printf '%s' "(^|[^[:alnum:]_.-])$1([[:space:]]+[^[:space:]]+)*[[:space:]]+($2)([[:space:]]|\$)"
}

# _mk_cf_rule SEGMENTS ERE... -- true when ONE segment (line) matches every
# ERE; an ERE starting with "!" must NOT match. One grep per ERE over all
# segments, so the fork count does not depend on the number of segments.
_mk_cf_rule() {
  local cur="$1" re rc
  shift
  for re in "$@"; do
    rc=0
    case "$re" in
      '!'*) cur="$(printf '%s\n' "$cur" | grep -Ev -- "${re#!}" 2>/dev/null)" || rc=$? ;;
      *) cur="$(printf '%s\n' "$cur" | grep -E -- "$re" 2>/dev/null)" || rc=$? ;;
    esac
    # grep exits 1 for "no line"; more is an error: fail closed, a match.
    [ "$rc" -gt 1 ] && return 0
  done
  [ -n "$cur" ]
}

# _mk_cf_rm SEGMENT -- recursive rm with at least one target outside the
# build-artifact safelist (and, see mk_careful_labels, the temp exemption),
# or with no target at all. Parsing starts after the FIRST token that is the
# rm command (rm, /bin/rm; not "git rm").
_mk_cf_rm() {
  local t u raw base prev="" started=0 skip=0 recursive=0 targets=0 unsafe=0 _f
  local re_gitrm='git[[:space:]]+rm[[:space:]]'
  local re_rmr='(^|[^[:alnum:]_.-])rm[[:space:]]+(-[^[:space:]]*[rR]|--recursive)'
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  # shellcheck disable=SC2086  # word splitting is intended; globbing is off (set -f)
  for t in $1; do
    if [ "$started" -eq 0 ]; then
      u="$t"
      # Kept for the raw view, which must label what 0.5.1 labelled.
      while :; do
        case "$u" in
          [\(\`\"\'\\\$\{]*) u="${u#?}" ;;
          *) break ;;
        esac
      done
      case "$u" in
        rm|*/rm) [ "$prev" = git ] || started=1 ;;
      esac
      prev="$t"
      continue
    fi
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    raw="$t"
    case "$raw" in
      \"*|\'*) ;;
      '>'|'>>'|[0-9]'>'|[0-9]'>>'|'&>'|'<') skip=1; continue ;;
      [0-9]\>*|[0-9]\<*|\>*|\<*|\&\>*) continue ;;
    esac
    t="${t#\"}"; t="${t#\'}"; t="${t%\)}"; t="${t%\`}"; t="${t%\"}"; t="${t%\'}"
    case "$t" in
      '') continue ;;
      --r*) if [[ --recursive == "$t"* ]]; then recursive=1; fi; continue ;;
      --*) continue ;;
      -*[rR]*) recursive=1; continue ;;
      -*) continue ;;
    esac
    targets=$((targets + 1))
    base="${t%/}"; base="${base##*/}"
    case " $MK_CF_SAFE_RM " in
      *" $base "*) ;;
      *)
        # Temp exemption (lib/temp.sh): only when mk_careful_labels has seen
        # that the whole command is one simple rm (_MK_CF_TEMP_OK, local
        # there) and mk_temp_init found this session's temp tree. Subshell:
        # its entry listing needs globbing, which is off here.
        # Once unsafe, no more subshells: the verdict cannot change.
        if [ "$unsafe" -eq 0 ] && [ "${_MK_CF_TEMP_OK:-0}" = 1 ] && [ -n "${MK_TEMP_PROJECT_DIR:-}" ] &&
           ( set +f; mk_temp_rm_safe "$t" ); then :; else unsafe=1; fi ;;
    esac
  done
  [ "$_f" = 1 ] || set +f
  # Fail closed: a recursive rm we could not tokenize as a command still counts.
  if [ "$started" -eq 0 ]; then
    [[ $1 =~ $re_gitrm ]] && return 1
    [[ $1 =~ $re_rmr ]] && return 0
    return 1
  fi
  [ "$recursive" -eq 1 ] && { [ "$unsafe" -eq 1 ] || [ "$targets" -eq 0 ]; }
}

# mk_careful_join CMD -- join backslash-newline continuation lines the way bash
# does: a line whose trailing run of backslashes has ODD length continues onto
# the next line (that one backslash and the newline are deleted, nothing is
# inserted, so `kub\<nl>ectl` becomes `kubectl`). An EVEN run is literal
# backslashes and the next line is a separate command. The buffer always ends
# in an even run, so only the current line needs matching (linear time).
# It does not parse comments, single quotes or quoted heredocs, where bash does
# not continue; mk_careful_labels also matches the stripped-raw text for those.
# Used for matching only; approval codes stay on the raw command text.
mk_careful_join() {
  printf '%s\n' "$1" | awk 'match($0, /\\+$/) && RLENGTH % 2 == 1 { buf = buf substr($0, 1, length($0) - 1); next } { print buf $0; buf = "" } END { if (buf != "") print buf }'
}

# mk_careful_strip CMD -- like mk_careful_join, except a continuation is NOT
# joined where bash might not continue: a line containing # or ' (comment or
# single quote), or any line once << has been seen (heredoc). The backslash is
# still removed there and the next line stays separate. Matched in union with
# the joined text so such lines are never hidden.
mk_careful_strip() {
  printf '%s\n' "$1" | awk '/<</ { hd = 1 } match($0, /\\+$/) && RLENGTH % 2 == 1 { $0 = substr($0, 1, length($0) - 1); if (!hd && $0 !~ /[#'"'"']/) { buf = buf $0; next } } { print buf $0; buf = "" } END { if (buf != "") print buf }'
}

# mk_careful_flat TEXT -- the flat view, in one linear sed pass (no parser).
# The expressions, in order, with an example each:
#   quotes, backslashes deleted     r""m 'rm' \rm      -> rm rm rm
#   ${ -> $                         "${RM}" -rf x       -> $RM} -rf x
#   :- -> blank                     ${GIT:-git} push    -> $GIT git} push
#   commas on a line with {         {rm,-rf,x}          -> {rm -rf x}
#   ( ) { } ` -> blank              (git reset --hard)  -> " git reset --hard "
#   .exe dropped from a word        kubectl.exe delete  -> kubectl delete
#   rm git kubectl helm docker      RM -rf x, Git push  -> rm -rf x, git push
#     dotnet in any case -> lower   (not after $: $GIT stays a variable)
#     Only the leading boundary is matched, so no separator is consumed and
#     an adjacent word (echo rm;RM) is not skipped. A longer word's prefix
#     is lowercased too (RMDIR -> rmDIR): harmless, as every rule needs the
#     tool word followed by a non-word character.
#   ; | -> blank-padded             x;git push -f|cat   -> x ; git push -f | cat
#   blank before < > after a word   rm>/dev/null -rf x  -> rm >/dev/null -rf x
#     (not after a digit, & < >:    2>&1 2>/dev/null &>f stay whole)
#   blank before a glued &          git push -f&        -> git push -f &
#   blank after that &              true &git push -f   -> true & git push -f
# Quoted prose is flattened too: those false positives are accepted
# (README). A per-call sentinel line proves sed read to the end; exit 1
# otherwise.
mk_careful_flat() {
  local out nl='
' tok="mk-sentinel-$$-$RANDOM-$RANDOM"
  out="$(printf '%s\n%s\n' "$1" "$tok" | LC_ALL=C sed -E -e 's/["'\''\\]//g' -e 's/\$\{/$/g' -e 's/:-/ /g' \
    -e '/[{]/s/,/ /g' -e 's/[`(){}]/ /g' -e 's/\.[Ee][Xx][Ee]([^[:alnum:]_.-]|$)/\1/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Rr][Mm]/\1rm/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Gg][Ii][Tt]/\1git/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Kk][Uu][Bb][Ee][Cc][Tt][Ll]/\1kubectl/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Hh][Ee][Ll][Mm]/\1helm/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Dd][Oo][Cc][Kk][Ee][Rr]/\1docker/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Dd][Oo][Tt][Nn][Ee][Tt]/\1dotnet/g' \
    -e 's/[;|]/ & /g' -e 's/([^0-9&<> ])([<>])/\1 \2/g' \
    -e 's/([^&<> ])&/\1 \&/g' -e 's/ &([^&>])/ \& \1/g')" || return 1
  case "$out" in *"$nl$tok") printf '%s' "${out%"$nl$tok"}" ;; *) return 1 ;; esac
}

# mk_careful_segments CMD -- one shell segment per line. Quotes are not
# parsed: a separator inside quotes makes an extra split. That is harmless for
# the rules that look for something in a segment (the pieces still hold the
# words), but it can fake a segment START (X="a;grep x" $RM -rf y): so a rule
# that depends on a segment's first word (the DYNRM exemption) only applies
# when the whole command is one segment.
mk_careful_segments() {
  printf '%s\n' "$1" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); gsub(/[[:space:]]&[[:space:]]/, "\n"); print }'
}

# _mk_cf_exempt TEXT -- true when TEXT matches MK_CF_DYNEXEMPT, byte-wise: in a
# double-byte locale (Big5, GBK, GB18030) a lead byte + backtick (0x60) is ONE
# character that the bracket class [^$`<>&()\] swallows, so a command
# substitution looked exempt. LC_ALL=C is local to this function (bash 3.2 ok).
# Only in a C/POSIX/UTF-8 locale (_mk_cf_ctype_ok); elsewhere never exempt.
_mk_cf_exempt() {
  _mk_cf_ctype_ok "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" || return 1
  local LC_ALL=C
  [[ $1 =~ $MK_CF_DYNEXEMPT ]]
}

# _mk_cf_ctype_ok NAME -- true when NAME (the effective LC_CTYPE: first
# non-empty of LC_ALL, LC_CTYPE, LANG) is empty, C, POSIX or a UTF-8 locale
# (codeset case-insensitive, optional @modifier). Pure bash, no fork.
_mk_cf_ctype_ok() {
  case "$1" in
    ''|C|POSIX|C@*|POSIX@*) return 0 ;;
    *.[Uu][Tt][Ff]-8|*.[Uu][Tt][Ff]-8@*|*.[Uu][Tt][Ff]8|*.[Uu][Tt][Ff]8@*) return 0 ;;
  esac
  return 1
}

# _mk_cf_oneseg TEXT -- true when mk_careful_segments would not split TEXT:
# no newline, ; | && or blank-& -blank, quoted or not (bash patterns, no fork).
_mk_cf_oneseg() {
  local LC_ALL=C # byte-wise: a double-byte lead byte must not swallow | or ;
  case "$1" in
    *'
'*|*\;*|*\|*|*'&&'*|*[[:space:]]\&[[:space:]]*) return 1 ;;
  esac
  return 0
}

# mk_careful_builtin CMD [ONE] -- builtin labels the command matches, one per line
# (careful-state is checked by mk_careful_labels). A failing stage prints
# unparsed and falls back to the unprocessed text, so no rule is skipped.
mk_careful_builtin() {
  local segs all rmsegs seg flat n rc=0 nl='
' tok="mk-sentinel-$$-$RANDOM-$RANDOM"
  if ! flat="$(printf '%s' "$1" | tr '\n' ' ')" || _mk_cf_empty "$1" "$flat"; then printf 'unparsed\n'; flat="$1"; fi
  if { _mk_cf_has '(^|[^[:alnum:]_])(psql|pgcli|mysql|mariadb|sqlite3|sqlcmd)([^[:alnum:]_./-]|$)' "$1" i &&
       _mk_cf_has '(^|[^[:alnum:]_])(drop[[:space:]]+(table|database|schema)|truncate|delete[[:space:]]+from)([^[:alnum:]_]|$)' "$1$nl$flat" i; } ||
     _mk_cf_has '(^|[^[:alnum:]_.-])(dropdb|mysqladmin([[:space:]]+[^[:space:]]+)*[[:space:]]+drop)([[:space:]]|$)' "$1" i; then
    printf 'sql-destructive\n'
  fi
  # Per-call sentinel lines (first line through the splitter, END line from
  # the filter) prove each awk read the input; no constant output fakes them.
  all="$(mk_careful_segments "$tok$nl$1")"
  case "$all" in
    "$tok") all="" ;;
    "$tok$nl"*) all="${all#"$tok$nl"}" ;;
    *) printf 'unparsed\n'; all="$1" ;;
  esac
  # Only segments naming a tool (or holding a word the shell computes) can
  # match a segment rule; drop the rest and duplicates once, not per rule.
  segs="$(printf '%s\n' "$all" | awk -v s="$tok" '/git|rm|kubectl|helm|docker|dotnet|[$*?]|\[/ && !seen[$0]++ { print } END { print s }')"
  case "$segs" in
    "$tok") segs="" ;;
    *"$nl$tok") segs="${segs%"$nl$tok"}" ;;
    *) printf 'unparsed\n'; segs="$1" ;;
  esac
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git push)" \
       "[[:space:]](-f|$MK_CF_FORCE|-[a-zA-Z]*f[a-zA-Z]*|\\+[^[:space:]]+)([[:space:]]|\$)"; then
    printf 'git-force-push\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git reset)" "[[:space:]]$MK_CF_HARD([[:space:]]|\$)"; then
    printf 'git-reset-hard\n'
  fi
  # No dry-run exemption: "-n" may be an option argument (git clean -f -e -n).
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git clean)" \
       "[[:space:]]($MK_CF_FORCE|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]]|\$)"; then
    printf 'git-clean\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git branch)" '[[:space:]]-[a-zA-Z]*D[a-zA-Z]*([[:space:]]|$)' ||
     _mk_cf_rule "$segs" "$(_mk_cf_cmdre git branch)" '[[:space:]](-d|--delete)([[:space:]]|$)' \
       '[[:space:]](-f|--force)([[:space:]]|$)' ||
     _mk_cf_rule "$segs" "$(_mk_cf_cmdre git branch)" \
       '[[:space:]]-[a-zA-Z]*(d[a-zA-Z]*f|f[a-zA-Z]*d)[a-zA-Z]*([[:space:]]|$)'; then
    printf 'git-branch-delete\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git worktree)" '[[:space:]]remove([[:space:]]|$)' \
       "[[:space:]]($MK_CF_FORCE|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]]|\$)"; then
    printf 'git-worktree-force\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git 'checkout|restore')" '[[:space:]]\.([[:space:]]|$)' \
       '![[:space:]](--staged|-S)([[:space:]]|$)' ||
     _mk_cf_rule "$segs" "$(_mk_cf_cmdre git 'checkout|restore')" '[[:space:]]\.([[:space:]]|$)' \
       '[[:space:]](--staged|-S)([[:space:]]|$)' '[[:space:]](--worktree|-W)([[:space:]]|$)'; then
    printf 'git-discard-all\n'
  fi
  # rm: a computed command word (one grep), else one grep pre-selects
  # segments and the (fork-free) token parser runs, at most
  # MK_CF_MAX_RM_SEGS times (bounded time; fail closed past that).
  # ONE=1 (set by _mk_cf_labels: the raw command is one exempt read-only
  # segment) skips this rule, nothing can run but the first word; absent or
  # anything else: the plain 0.7.1 rule over all views, fail closed.
  if [ "${2:-0}" != 1 ] && _mk_cf_rule "$segs" "$MK_CF_DYNRM"; then printf 'rm-recursive\n'; fi
  rmsegs="$(printf '%s\n' "$segs" | grep -E '(^|[^[:alnum:]_.-])rm[[:space:]]' 2>/dev/null)" || rc=$?
  if [ "$rc" -gt 1 ]; then printf 'unparsed\n'; rmsegs="$segs"; fi
  n=0
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    n=$((n + 1))
    if [ "$n" -gt "$MK_CF_MAX_RM_SEGS" ]; then printf 'too-large\n'; break; fi
    if _mk_cf_rm "$seg"; then printf 'rm-recursive\n'; break; fi
  done <<EOF
$rmsegs
EOF
  if _mk_cf_rule "$segs" '(^|[^[:alnum:]_.-])dotnet[[:space:]]+ef[[:space:]]+database[[:space:]]+drop([[:space:]]|$)'; then
    printf 'ef-database-drop\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre kubectl delete)"; then printf 'kubectl-delete\n'; fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre helm 'uninstall|delete|del|un')"; then printf 'helm-uninstall\n'; fi
  if _mk_cf_rule "$segs" '(^|[^[:alnum:]_.-])docker([[:space:]]+[^[:space:]]+)*[[:space:]]+(system[[:space:]]+prune|volume[[:space:]]+(prune|rm|remove))([[:space:]]|$)'; then
    printf 'docker-prune\n'
  fi
}

# _mk_cf_pattern I FIELD -- field of the I-th project pattern (jq -r adds the newline).
_mk_cf_pattern() { printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq -r ".[$1].$2" 2>/dev/null; }

# mk_careful_project CMD -- labels of matching project patterns. A regex
# grep -E rejects makes grep exit 2, i.e. no match: only that pattern is off
# (session start names it). A failing jq prints unparsed instead.
mk_careful_project() {
  local n i re lab
  n="$(printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq 'length' 2>/dev/null)" || { printf 'unparsed\n'; return 0; }
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    re="$(_mk_cf_pattern "$i" match)" || { printf 'unparsed\n'; return 0; }
    if printf '%s' "$1" 2>/dev/null | grep -Eiq -- "$re" 2>/dev/null; then
      lab="$(_mk_cf_pattern "$i" label)" || lab=unparsed
      printf '%s\n' "${lab:-unparsed}"
    fi
    i=$((i + 1))
  done
}

# mk_careful_single_rm CMD -- 0 only when CMD, after joining backslash-newline
# continuations, is exactly ONE simple rm invocation: "rm" (or /bin/rm,
# /usr/bin/rm) as the first word, then options, then targets that are bare
# words or wrapped whole in one pair of quotes. No other command, separator,
# grouping, substitution, redirection, expansion ($ ` ~ { }), escape,
# comment, assignment or wrapper (env, sudo, xargs, ...). Fail closed: any
# shape it does not recognise is "not single". This is the caller guarantee
# mk_temp_rm_safe needs: it judges the filesystem at check time only, so no
# other command in the same Bash call may create, remove or swap a path first.
mk_careful_single_rm() {
  local c="$1" nl t first=1 targets=0 dd=0 inner _f rc=0
  nl='
'
  # Fail closed and fast: a simple rm is short (each target may cost a
  # subshell in _mk_cf_rm), and ${c//...} below is quadratic in the number of
  # continuations on bash 3.2.
  [ "${#c}" -le 4096 ] || return 1
  case "$c" in *"\\$nl"*) [ "${#c}" -le 1024 ] || return 1 ;; esac
  # A continuation inside single quotes stays literal in bash, while the join
  # below would remove it: refuse that combination.
  case "$c" in *"\\$nl"*) case "$c" in *\'*) return 1 ;; esac ;; esac
  c="${c//\\$nl/}"
  while :; do case "$c" in *"$nl") c="${c%"$nl"}" ;; *) break ;; esac; done
  # Whitelist, spelled out (ranges are locale-dependent in bash patterns):
  # the target characters lib/temp.sh accepts, plus blank, tab and quotes.
  # Excluded among others: newline ; & | < > ( ) { } $ ` \ # ~ ^ = !
  # The executing shell may be zsh with the user's setopts, so this is judged
  # against zsh syntax under any option: ^ # ~ <a-b> ( ) **/ (EXTENDED_GLOB,
  # GLOB_STAR_SHORT), = (EQUALS: a word "=cmd" becomes the path of cmd;
  # MAGIC_EQUAL_SUBST: "x==cmd" becomes "x=/path/of/cmd") and ! (history
  # expansion in an interactive shell, bash or zsh) must all stay excluded
  # (no "/" may follow the scratchpad name, and lib/temp.sh rejects "**"
  # there). The rest stays inert under every option: @ + need "(" (KSH_GLOB),
  # "," needs "{", ":" modifiers need "$", "(" or "!", "%" is no word
  # expansion, and * ? only match within the scratchpad.
  case "$c" in
    *[!]ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/@+,:%*?[\"\'\ \	-]*) return 1 ;;
  esac
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  # shellcheck disable=SC2086  # word splitting is intended; globbing is off (set -f)
  for t in $c; do
    if [ "$first" -eq 1 ]; then
      first=0
      case "$t" in rm|/bin/rm|/usr/bin/rm) continue ;; *) rc=1; break ;; esac
    fi
    case "$t" in
      -*)
        # Options only before the first target and before "--": BSD rm takes
        # a later "-x" as a file name, which _mk_cf_rm would skip as an option.
        if [ "$targets" -ne 0 ] || [ "$dd" -ne 0 ]; then rc=1; break; fi
        case "$t" in
          --) dd=1; continue ;;
          --recursive|--force|--verbose|--dir|--one-file-system) continue ;;
          --*|-) rc=1; break ;;
          *[!dfiIPRrvWx-]*|-*-*) rc=1; break ;;
        esac
        continue ;;
    esac
    case "$t" in
      \"*\") inner="${t#\"}"; inner="${inner%\"}" ;;
      \'*\') inner="${t#\'}"; inner="${inner%\'}" ;;
      *) inner="$t" ;;
    esac
    case "$inner" in ''|-*|*[\"\']*) rc=1; break ;; esac
    targets=$((targets + 1))
  done
  [ "$_f" = 1 ] || set +f
  [ "$rc" -eq 0 ] && [ "$first" -eq 0 ] && [ "$targets" -gt 0 ]
}

# mk_careful_labels CMD -- builtin + project labels, de-duplicated, in order,
# without awk: the de-duplication itself cannot lose a label.
mk_careful_labels() {
  local out l seen=" "
  out="$(_mk_cf_labels "$1")"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$seen" in *" $l "*) continue ;; esac
    seen="$seen$l "
    printf '%s\n' "$l"
  done <<EOF
$out
EOF
}

# _mk_cf_labels CMD -- the labels, possibly repeated. Fail closed: a stage
# that fails or comes back empty prints unparsed and the next stage works on
# the unprocessed text, so a broken tool never turns into "no label".
_mk_cf_labels() {
  local t n tok joined stripped views flat one _MK_CF_TEMP_OK=0 nl='
'
  # careful-state first, before any other stage can fail, and also when the
  # command is too-large (approvable; careful-state never is): one grep -c on
  # the raw text, on it with quotes, backslashes and newlines deleted, and on
  # a sentinel line that must count. A tr or grep that fails or prints
  # nothing gives careful-state too: the check could not be made.
  if ! t="$(printf '%s' "$1" | LC_ALL=C tr -d "\\n\"'\\\\")" || _mk_cf_empty "$1" "$t"; then
    printf 'careful-state\nunparsed\n'; t=""
  fi
  n="$(printf '%s\n%s\ncareful-grants\n' "$1" "$t" | grep -ciE "$MK_CF_STATE_RE")"
  case "$n" in
    1) ;;
    ''|*[!0-9]*|0) printf 'careful-state\nunparsed\n' ;;
    *) printf 'careful-state\n' ;;
  esac
  if _mk_cf_has "$MK_CF_STATE_GLOB_RE" "$1$nl$t" i; then printf 'careful-state-glob\n'; fi
  if [ "${#1}" -gt "$MK_CF_MAX_CHARS" ]; then printf 'too-large\n'; return 0; fi
  # join and strip only change backslash-newline continuations (and a
  # trailing backslash): without one the views are the raw text itself (no
  # awk, nothing to go wrong). With one, a per-call first line must come back
  # first, or the raw text is used instead.
  joined="$1"; stripped="$1"
  case "$1" in *"\\$nl"*|*\\)
    tok="mk-sentinel-$$-$RANDOM-$RANDOM"
    joined="$(mk_careful_join "$tok$nl$1")"
    case "$joined" in
      "$tok") joined="" ;;
      "$tok$nl"*) joined="${joined#"$tok$nl"}" ;;
      *) printf 'unparsed\n'; joined="$1" ;;
    esac
    stripped="$(mk_careful_strip "$tok$nl$1")"
    case "$stripped" in
      "$tok") stripped="" ;;
      "$tok$nl"*) stripped="${stripped#"$tok$nl"}" ;;
      *) printf 'unparsed\n'; stripped="$1" ;;
    esac ;;
  esac
  # Seen by _mk_cf_rm through dynamic scope; never set anywhere else.
  if [ -n "${MK_TEMP_PROJECT_DIR:-}" ] && [ "$joined" = "$stripped" ] &&
     mk_careful_single_rm "$1"; then
    _MK_CF_TEMP_OK=1
  fi
  # All views in one text: every rule is per line or "anywhere in the text",
  # so one pass over it is the union of a pass per view.
  views="$joined"
  [ "$stripped" = "$joined" ] || views="$views$nl$stripped"
  if flat="$(mk_careful_flat "$views")" && ! _mk_cf_empty "$views" "$flat"; then
    [ "$flat" = "$views" ] || views="$views$nl$flat"
  else
    printf 'unparsed\n'
    flat=""
  fi
  if _mk_cf_has "$MK_CF_STATE_RE" "$views" i; then printf 'careful-state\n'; fi
  if _mk_cf_has "$MK_CF_STATE_GLOB_RE" "$views" i; then printf 'careful-state-glob\n'; fi
  # The DYNRM exemption is decided ONCE, on the raw text: every view is ONE
  # segment (fork-free test; a flat view that could not be built: not single)
  # AND the whole raw command matches MK_CF_DYNEXEMPT (bash [[ =~ ]], no
  # fork; a regex error is not a match). The flat view takes no part: it
  # deletes quotes, backslashes, ( ) { } and backticks, the very characters
  # that disqualify, so it could make a non-exempt line look exempt
  # (grep x `$RM '' -rf y`).
  # The RAW text must also be a single line (no newline at all, continuation
  # lines included; they are never exempt): the locale gate checks the locale
  # NAME, but bash may fall back to LANG's charset when LC_CTYPE names a
  # locale that does not exist (en_US.utf8 + LANG=zh_TW.Big5). Without a
  # newline there is no separator byte a double-byte charset could create or
  # hide (_mk_cf_oneseg is byte-wise, LC_ALL=C; double-byte trail bytes may be
  # 0x40-0xFE, so | 0x7C and a backslash 0x5C can be trail bytes, but " ' $
  # never are).
  one=0
  if _mk_cf_oneseg "$1" && _mk_cf_oneseg "$joined" && _mk_cf_oneseg "$stripped" &&
     [ "$flat" != "" ] && _mk_cf_oneseg "$flat" &&
     _mk_cf_exempt "$joined"; then one=1; fi
  mk_careful_builtin "$views" "$one"
  mk_careful_project "$views"
}

# mk_careful_bad_patterns -- labels of project patterns grep -E rejects.
mk_careful_bad_patterns() {
  local n i rc
  n="$(printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq 'length' 2>/dev/null)" || n=0
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    rc=0
    printf '' | grep -E -- "$(_mk_cf_pattern "$i" match)" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then _mk_cf_pattern "$i" label; fi
    i=$((i + 1))
  done
}

MK_CF_TTL=600

_mk_cf_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# mk_careful_code CMD -- approval code bound to this project root and the
# exact command text (one changed character gives another code).
mk_careful_code() {
  printf '%s\n%s' "$MK_ROOT" "$1" | _mk_cf_sha256 | cut -c1-6
}

mk_careful_grants_file() { mk_tmp careful-grants; }

# _mk_cf_unsafe FILE -- true when FILE exists but is a symlink or not ours
# (a pre-planted file in a shared temp dir must never be followed or trusted).
_mk_cf_unsafe() { [ -L "$1" ] || { [ -e "$1" ] && [ ! -O "$1" ]; }; }

# mk_careful_grant CODE -- single-use approval valid for MK_CF_TTL seconds.
mk_careful_grant() {
  local f exp
  f="$(mk_careful_grants_file)"
  _mk_cf_unsafe "$f" && return 1
  exp="$(( $(date +%s) + MK_CF_TTL ))"
  ( umask 077; printf '%s %s\n' "$1" "$exp" >> "$f" )
}

# mk_careful_consume CODE -- exit 0 and remove ONE unexpired line for CODE;
# exit 1 otherwise. Expired and malformed lines are dropped on every call.
mk_careful_consume() {
  local f tmp now c exp found=1
  f="$(mk_careful_grants_file)"
  _mk_cf_unsafe "$f" && return 1
  [ -f "$f" ] || return 1
  now="$(date +%s)"
  tmp="$( umask 077; mktemp "$f.XXXXXX" 2>/dev/null )" || return 1
  [ -n "$tmp" ] || return 1
  while read -r c exp; do
    case "$exp" in ''|*[!0-9]*) continue ;; esac
    [ "$exp" -gt "$now" ] || continue
    if [ "$found" -ne 0 ] && [ "$c" = "$1" ]; then found=0; continue; fi
    printf '%s %s\n' "$c" "$exp" >> "$tmp"
  done < "$f"
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return "$found"
}
