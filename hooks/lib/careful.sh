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
# when the caller ran mk_temp_init (guard-destructive.sh does) and either the
# whole command is one simple rm (mk_careful_single_rm), or the caller is the
# main session (MK_CF_MAIN=1), every other segment on every view is an
# allowlisted harmless command (_mk_cf_cleanup_ok), and every target is a
# literal absolute path of an rm that is its segment's own command
# (_mk_cf_rm, _mk_cf_lit; spec 0.8 Part D).
# Lane cleanup (spec 0.8 Part D, goals 2-3), main session only, in
# guard-destructive.sh's second labelling (MK_CF_WT=1): in the same shapes,
# git-worktree-force and git-branch-delete are not printed and an rm target
# that is a lane worktree is safe, when lib/worktrees.sh accepts the lane
# (mk_wt_removable) or the branch (mk_wt_branch_removable); see
# _mk_cf_gitseg_ok and _mk_cf_wt_skip.
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
MK_CF_STATE_RE="careful-grants|careful-pending|careful-window|careful-active|careful[^[:space:]/.]*[*?[][^[:space:]/.]*grant|${_mk_cf_tmpword}[^[:space:]]*${_mk_cf_mkglob}|${_mk_cf_mkglob}[^[:space:]]*${_mk_cf_tmpword}"
MK_CF_STATE_GLOB_RE='careful[^[:space:]/.]*[*?[]|memokit-[^[:space:]/.]*[*?[]'
# Set (as locals) only by _mk_cf_labels; see _mk_cf_rm.
_MK_CF_TEMP_OK=0; _MK_CF_TEMP_LIT=0
# 1 only when guard-destructive.sh sets it, after sourcing this file, for a
# payload without agent_id (the main session). Reset here so the environment
# can never set it.
MK_CF_MAIN=0
# Lane cleanup (spec 0.8 Part D, goals 2-3): MK_CF_WT=1 only in
# guard-destructive.sh's second labelling of a main-session command whose
# labels are all lane-cleanup labels, after it sourced lib/worktrees.sh;
# MK_CF_CWD is then the payload cwd. Reset here, as MK_CF_MAIN. The memo
# (_mk_cf_wt_ok, _mk_cf_br_ok) lives in one labelling subshell.
MK_CF_WT=0
MK_CF_CWD=""
_MK_CF_WT_K=(); _MK_CF_WT_V=()

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
  local t u raw base prev="" started=0 skip=0 recursive=0 targets=0 unsafe=0 cw=0 dd=0 _f
  # Byte-wise (also for mk_temp_rm_safe, which runs in a subshell from here):
  # in a UTF-8 locale bash 3.2 runs pattern ops such as ${t%x} on a long
  # token in super-linear time (a 60 KB target took seconds).
  local LC_ALL=C
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
      # cw: rm is the segment's own command word, spelled plainly (for the
      # literal rule below: no wrapper such as xargs or find -exec can add
      # targets this parser does not see).
      if [ "$started" -eq 1 ] && [ -z "$prev" ]; then
        case "$t" in rm|/bin/rm|/usr/bin/rm) cw=1 ;; esac
      fi
      prev="$t"
      continue
    fi
    # Literal rule (LIT mode; parentheses and backticks never reach it,
    # _mk_cf_cleanup_ok refuses them): a redirection may only name a literal
    # absolute path or duplicate an fd. Otherwise the word may be no
    # redirection at all: zsh reads <-> and <1-99> as numeric globs, i.e.
    # rm targets in the current directory.
    if [ "$skip" -eq 1 ]; then
      skip=0
      if [ "${_MK_CF_TEMP_LIT:-0}" = 1 ] && ! _mk_cf_lit "$t"; then unsafe=1; fi
      continue
    fi
    raw="$t"
    case "$raw" in
      \"*|\'*) ;;
      '>'|'>>'|[0-9]'>'|[0-9]'>>'|'&>'|'&>>'|'<') skip=1; continue ;;
      [0-9]\>*|[0-9]\<*|\>*|\<*|\&\>*)
        if [ "${_MK_CF_TEMP_LIT:-0}" = 1 ] && ! _mk_cf_redir_ok "$raw"; then unsafe=1; fi
        continue ;;
    esac
    t="${t#\"}"; t="${t#\'}"; t="${t%\)}"; t="${t%\`}"; t="${t%\"}"; t="${t%\'}"
    # Literal rule: a "-..." word after "--" or after a target, or a lone
    # "-", is a file operand (BSD rm stops at the first operand) that the
    # cases below would skip as an option.
    # An option word with a glob character (-*) expands like a target.
    if [ "${_MK_CF_TEMP_LIT:-0}" = 1 ]; then
      case "$t" in
        -*)
          if [ "$dd" -eq 1 ] || [ "$targets" -gt 0 ] || [ "$t" = - ]; then unsafe=1; fi
          case "$t" in *[*?[]*) unsafe=1 ;; esac
          [ "$t" = -- ] && dd=1 ;;
      esac
    fi
    case "$t" in
      '') continue ;;
      --r*) if [[ --recursive == "$t"* ]]; then recursive=1; fi; continue ;;
      --*) continue ;;
      -*[rR]*) recursive=1; continue ;;
      -*) continue ;;
    esac
    targets=$((targets + 1))
    # Last component, from the last 256 bytes only: ${x##*/} is quadratic in
    # the length even byte-wise, and a longer component is never a safelist
    # name anyway.
    base="${t%/}"
    [ "${#base}" -le 256 ] || base="${base:${#base}-256}"
    base="${base##*/}"
    case " $MK_CF_SAFE_RM " in
      *" $base "*) ;;
      *)
        # Temp exemption (lib/temp.sh): only when _mk_cf_labels allowed it
        # (_MK_CF_TEMP_OK, local there) and mk_temp_init found this session's
        # temp tree. Outside the single-rm form (_MK_CF_TEMP_LIT) the target
        # must also be a plain literal of an rm that is the segment's own
        # command (cw). Subshell: its entry listing needs globbing, which is
        # off here. Once unsafe, no more subshells: the verdict cannot change.
        # Lane worktree (spec 0.8 Part D): the same shape (_MK_CF_TEMP_OK),
        # a literal absolute target of an rm that is its segment's own
        # command, accepted by lib/worktrees.sh (_mk_cf_wt_ok: main session,
        # second labelling only).
        if [ "$unsafe" -eq 0 ] && [ "${_MK_CF_TEMP_OK:-0}" = 1 ] && [ -n "${MK_TEMP_PROJECT_DIR:-}" ] &&
           { [ "${_MK_CF_TEMP_LIT:-0}" != 1 ] || { [ "$cw" -eq 1 ] && _mk_cf_lit "$raw"; }; } &&
           ( set +f; mk_temp_rm_safe "$t" ); then :
        elif [ "${MK_CF_WT:-0}" = 1 ] && [ "$unsafe" -eq 0 ] && [ "${_MK_CF_TEMP_OK:-0}" = 1 ] &&
             [ "$cw" -eq 1 ] && _mk_cf_lit "$raw" && _mk_cf_wt_ok "$t"; then :
        else unsafe=1; fi ;;
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

# _mk_cf_lit WORD -- true when WORD, as written in the command, is a literal
# absolute path: no $ ` \ ~ ( ) or glob character (* ? [) at all, and after
# removing ONE pair of surrounding quotes it starts with "/" and holds no
# quote. Pure bash, no fork.
_mk_cf_lit() {
  local w="$1" LC_ALL=C
  case "$w" in *[\$\`\\~*?[\(\)]*) return 1 ;; esac
  case "$w" in
    \"*\") w="${w#\"}"; w="${w%\"}" ;;
    \'*\') w="${w#\'}"; w="${w%\'}" ;;
  esac
  case "$w" in /*) ;; *) return 1 ;; esac
  case "$w" in *[\"\']*) return 1 ;; esac
  return 0
}

# _mk_cf_redir_ok WORD -- LIT mode: WORD is a redirection with its operand
# glued on (>f, 2>>f, &>f, <f, 2>&1, >&2, <&3) whose operand is an fd number
# (a dup) or a literal absolute path (_mk_cf_lit). Anything else, e.g. zsh's
# numeric globs <-> and <1-99>, an fd close >&-, a relative or computed
# operand, is not harmless.
_mk_cf_redir_ok() {
  local w="$1" LC_ALL=C
  case "$w" in [0-9]*) w="${w#?}" ;; esac
  case "$w" in
    '&>>'*) w="${w#???}" ;;
    '&>'*|'>>'*) w="${w#??}" ;;
    '>'*|'<'*) w="${w#?}" ;;
    *) return 1 ;;
  esac
  case "$w" in '&'[0-9]|'&'[0-9][0-9]) return 0 ;; esac
  _mk_cf_lit "$w"
}

# _mk_cf_name WORD -- true when WORD, as written, is a literal branch name:
# after removing ONE pair of surrounding quotes only [A-Za-z0-9._/-], not
# empty, not starting with "-". Pure bash, no fork.
_mk_cf_name() {
  local w="$1" LC_ALL=C
  case "$w" in \"*\"|\'*\') w="${w#?}"; w="${w%?}" ;; esac
  case "$w" in ''|-*|*[!A-Za-z0-9._/-]*) return 1 ;; esac
  return 0
}

# _mk_cf_wt_ok PATH -- the main session's second labelling (MK_CF_WT=1,
# MK_CF_MAIN=1) and lib/worktrees.sh's mk_wt_removable accepts the absolute
# PATH for the payload cwd (MK_CF_CWD), never the worktree holding the
# project dir (MK_ROOT). Fork-free refusals first: a path longer than 4096
# bytes, or one with no .git file in it (every linked worktree has one), is
# no lane. Verdicts are memoised per labelling (each view asks again).
_mk_cf_wt_ok() {
  local i=0 v=1
  [ "${MK_CF_WT:-0}" = 1 ] && [ "${MK_CF_MAIN:-0}" = 1 ] || return 1
  [ "${#1}" -le 4096 ] || return 1
  [ -f "$1/.git" ] && [ ! -L "$1" ] || return 1
  while [ "$i" -lt "${#_MK_CF_WT_K[@]}" ]; do
    if [ "${_MK_CF_WT_K[i]}" = "w$1" ]; then return "${_MK_CF_WT_V[i]}"; fi
    i=$((i + 1))
  done
  if command -v mk_wt_removable >/dev/null 2>&1 &&
     mk_wt_removable "$1" "${MK_CF_CWD:-}" ${MK_ROOT:+"$MK_ROOT"}; then v=0; fi
  _MK_CF_WT_K[i]="w$1"; _MK_CF_WT_V[i]=$v
  return "$v"
}

# _mk_cf_br_ok NAME GONE_PATH... -- as _mk_cf_wt_ok for a branch:
# mk_wt_branch_removable accepts NAME for the payload cwd, a worktree that
# still checks it out being allowed only when it is among GONE_PATH (lanes an
# earlier segment of the command removes).
_mk_cf_br_ok() {
  local i=0 v=1 k="b$1" g nl='
'
  [ "${MK_CF_WT:-0}" = 1 ] && [ "${MK_CF_MAIN:-0}" = 1 ] || return 1
  [ "${#1}" -le 1024 ] || return 1
  for g in "${@:2}"; do k="$k$nl$g"; done
  while [ "$i" -lt "${#_MK_CF_WT_K[@]}" ]; do
    if [ "${_MK_CF_WT_K[i]}" = "$k" ]; then return "${_MK_CF_WT_V[i]}"; fi
    i=$((i + 1))
  done
  if command -v mk_wt_branch_removable >/dev/null 2>&1 &&
     mk_wt_branch_removable "$1" "${MK_CF_CWD:-}" "${@:2}"; then v=0; fi
  _MK_CF_WT_K[i]="$k"; _MK_CF_WT_V[i]=$v
  return "$v"
}

# _mk_cf_gitseg_ok WORD... -- the words after "git" in one segment are
# exactly `worktree remove [--force|-f] <path>` with a literal absolute path
# (_mk_cf_lit) that _mk_cf_wt_ok accepts (it is then added to _gone), or
# `branch -D|-d|--delete [--force] <name>` with a literal name (_mk_cf_name)
# that _mk_cf_br_ok accepts given _gone (sawbr=1 then). _gone and sawbr are
# locals of _mk_cf_cleanup_ok, seen through dynamic scope.
_mk_cf_gitseg_ok() {
  local w
  case "$1" in
    worktree)
      [ "${2:-}" = remove ] || return 1
      shift 2
      case "${1:-}" in --force|-f) shift ;; esac
      [ "$#" -eq 1 ] && [ "${#1}" -le 4096 ] && _mk_cf_lit "$1" || return 1
      w="$1"
      case "$w" in \"*\"|\'*\') w="${w#?}"; w="${w%?}" ;; esac
      _mk_cf_wt_ok "$w" || return 1
      _gone[${#_gone[@]}]="$w" ;;
    branch)
      case "${2:-}" in -D|-d|--delete) ;; *) return 1 ;; esac
      shift 2
      [ "${1:-}" = --force ] && shift
      [ "$#" -eq 1 ] && [ "${#1}" -le 1024 ] && _mk_cf_name "$1" || return 1
      w="$1"
      case "$w" in \"*\"|\'*\') w="${w#?}"; w="${w%?}" ;; esac
      _mk_cf_br_ok "$w" ${_gone[@]+"${_gone[@]}"} || return 1
      sawbr=1 ;;
    *) return 1 ;;
  esac
  return 0
}

# MK_CF_LIT_MAX_TARGETS -- in the main session's compound form, a view with
# more rm targets than this gets no exemption: each target costs a subshell
# and stat calls per view, and a long list would end in the budget deny.
MK_CF_LIT_MAX_TARGETS=16

# _mk_cf_cleanup_ok VIEW -- true when every segment of VIEW (split by
# mk_careful_segments, quotes not parsed) has as its command word (its first
# token, leading { removed; tokens made only of { } skipped) rm, /bin/rm,
# /usr/bin/rm, or one of the harmless commands cd echo printf true false :
# test [ ls pwd, every cd argument is literal (no $ ` * ? [), and the rm
# segments hold at most MK_CF_LIT_MAX_TARGETS words that are no option or
# redirection. Called once per view.
# A positive allowlist (security review of Task 9): any other command (cp,
# rsync, tar, install, rename, mv, ln, an interpreter, sh -c, sudo, env,
# NAME=value, a quoted or computed word, anything unknown) could put a
# non-temp tree where the exempt rm then deletes, so it gives no exemption.
# A backtick or ANY parenthesis also gives none: $( ) <( ) >( ) and zsh's
# =(cmd) and glob qualifiers (word(e:'cmd':), legal even without a wildcard)
# run code inside an allowlisted command; a subshell group asks too.
# The rm segments' targets are judged by _mk_cf_rm. Fail closed: the split
# text must come back between a leading and a trailing sentinel line, so a
# splitter that did not start or did not run to its end -> false.
# Lane cleanup (spec 0.8 Part D): in the main session's second labelling
# (MK_CF_WT=1, MK_CF_MAIN=1) a segment whose command word is git is accepted
# too, when its other words (at most 4) pass _mk_cf_gitseg_ok: one literal
# lane worktree removal or one literal merged-branch deletion that
# lib/worktrees.sh allows. A branch deletion in a command that also holds a
# cd segment is refused (cd may enter another repository, where the branch
# was never checked). Any other git segment: false, as before.
_mk_cf_cleanup_ok() {
  local segs seg t w iscd isrm isgit n=0 rc=0 _f sawcd=0 sawbr=0 tok="mk-sentinel-$$-$RANDOM-$RANDOM" nl='
'
  local -a gt=() _gone=()
  # Byte-wise, and the whole-text test is one regex (linear), not a case
  # glob: bash 3.2 pattern matching on a long text is super-linear in UTF-8.
  # The sentinels are checked with substrings, not pattern ops, for the same
  # reason.
  local LC_ALL=C re='[`()]' re_lead='^[{]*(.*)$'
  [[ $1 =~ $re ]] && return 1
  segs="$(mk_careful_segments "$tok$nl$1$nl$tok")"
  [ "${#segs}" -gt $((2 * ${#tok} + 1)) ] || return 1
  [ "${segs:0:${#tok}+1}" = "$tok$nl" ] || return 1
  [ "${segs:${#segs}-${#tok}-1}" = "$nl$tok" ] || return 1
  segs="${segs:${#tok}+1:${#segs}-2*${#tok}-2}"
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  while IFS= read -r seg; do
    w=""; iscd=0; isrm=0; isgit=0; gt=()
    # shellcheck disable=SC2086  # word splitting is intended; globbing is off (set -f)
    for t in $seg; do
      if [ -z "$w" ]; then
        case "$t" in *[!\{\}]*) ;; *) continue ;; esac
        w="$t"; [[ $t =~ $re_lead ]] && w="${BASH_REMATCH[1]}"
        case "$w" in
          rm|/bin/rm|/usr/bin/rm) isrm=1 ;;
          echo|printf|true|false|:|test|'['|ls|pwd) break ;;
          cd) iscd=1; sawcd=1 ;;
          git)
            if [ "${MK_CF_WT:-0}" = 1 ] && [ "${MK_CF_MAIN:-0}" = 1 ]; then isgit=1; else rc=1; break; fi ;;
          *) rc=1; break ;;
        esac
        continue
      fi
      if [ "$isgit" -eq 1 ]; then
        [ "${#gt[@]}" -lt 4 ] || { rc=1; break; }
        gt[${#gt[@]}]="$t"
        continue
      fi
      if [ "$isrm" -eq 1 ]; then
        case "$t" in
          -*|*[\<\>]*) ;;
          *) n=$((n + 1)); [ "$n" -le "$MK_CF_LIT_MAX_TARGETS" ] || { rc=1; break; } ;;
        esac
        continue
      fi
      [ "$iscd" -eq 1 ] || break
      case "$t" in *[\$\`*?[]*) rc=1; break ;; esac
    done
    if [ "$rc" -eq 0 ] && [ "$isgit" -eq 1 ]; then
      _mk_cf_gitseg_ok ${gt[@]+"${gt[@]}"} || rc=1
    fi
    [ "$rc" -eq 0 ] || break
  done <<EOF
$segs
EOF
  [ "$_f" = 1 ] || set +f
  if [ "$sawbr" -eq 1 ] && [ "$sawcd" -eq 1 ]; then rc=1; fi
  return "$rc"
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
#     dotnet ssh scp sftp rsync gh  (not after $: $GIT stays a variable)
#     in any case -> lower           (the last five for lib/remote.sh)
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
    -e 's/(^|[^[:alnum:]_.$-])[Ss][Ss][Hh]/\1ssh/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Ss][Cc][Pp]/\1scp/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Ss][Ff][Tt][Pp]/\1sftp/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Rr][Ss][Yy][Nn][Cc]/\1rsync/g' \
    -e 's/(^|[^[:alnum:]_.$-])[Gg][Hh]/\1gh/g' \
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

# _mk_cf_wt_skip -- the git-branch-delete and git-worktree-force rules print
# nothing: the main session's second labelling (MK_CF_WT=1, MK_CF_MAIN=1)
# found the whole command in the main-session literal shape
# (_MK_CF_TEMP_LIT, a local of _mk_cf_labels), so _mk_cf_cleanup_ok saw on
# every view only allowlisted harmless segments, rm segments (judged by
# _mk_cf_rm) and git segments each of which is one lane removal or branch
# deletion that lib/worktrees.sh allows. A rule match in an allowlisted
# segment (echo git branch -D x) runs nothing.
_mk_cf_wt_skip() {
  [ "${MK_CF_WT:-0}" = 1 ] && [ "${MK_CF_MAIN:-0}" = 1 ] && [ "${_MK_CF_TEMP_LIT:-0}" = 1 ]
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
    _mk_cf_wt_skip || printf 'git-branch-delete\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git worktree)" '[[:space:]]remove([[:space:]]|$)' \
       "[[:space:]]($MK_CF_FORCE|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]]|\$)"; then
    _mk_cf_wt_skip || printf 'git-worktree-force\n'
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
# without awk: the de-duplication itself cannot lose a label. The labelling
# runs in a subshell behind a per-call sentinel: one that did not run to its
# end (killed by the guard's CPU budget, a crash) reads as unparsed, never as
# "no label" (fix round 4).
mk_careful_labels() {
  local out l seen=" " tok="mk-sentinel-$$-$RANDOM-$RANDOM" nl='
'
  out="$(_mk_cf_labels "$1"; printf '%s\n' "$tok")"
  case "$out" in
    "$tok") out="" ;;
    *"$nl$tok") out="${out%"$nl$tok"}" ;;
    *) out="$out${nl}unparsed" ;;
  esac
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
  local t n tok joined stripped views flat one _rm_scan _MK_CF_TEMP_OK=0 _MK_CF_TEMP_LIT=0 nl='
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
  # The temp exemption, seen by _mk_cf_rm through dynamic scope; never set
  # anywhere else. The single-rm form (main session or subagent) as before;
  # for the main session also any other shape, with literal targets only
  # (_MK_CF_TEMP_LIT) and only allowlisted commands beside rm, checked per
  # view (joined, and flat when it differs; stripped equals joined here) by
  # _mk_cf_cleanup_ok. Fail closed: a flat view that could not be built
  # gives no exemption. The same shape gates the lane cleanup (MK_CF_WT, the
  # main session's second labelling), which needs no temp tree: _mk_cf_rm's
  # temp check still requires one, its worktree check does not.
  if { [ -n "${MK_TEMP_PROJECT_DIR:-}" ] || [ "${MK_CF_WT:-0}" = 1 ]; } && [ "$joined" = "$stripped" ]; then
    if mk_careful_single_rm "$1"; then
      _MK_CF_TEMP_OK=1
    elif [ "${MK_CF_MAIN:-0}" = 1 ] && [ -n "$flat" ] && _mk_cf_cleanup_ok "$joined" &&
         { [ "$flat" = "$joined" ] || _mk_cf_cleanup_ok "$flat"; }; then
      _MK_CF_TEMP_OK=1; _MK_CF_TEMP_LIT=1
    fi
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
  # Remote labels (lib/remote.sh, the label column of each scan line), only
  # with a "remote" config; remote.sh is loaded here when the caller has not.
  # Fail closed: it cannot be loaded, or the scan does not run to its end
  # (mk_remote_scan_checked's sentinel) -> unparsed.
  if [ "${MK_REMOTE_ENABLED:-0}" = 1 ]; then
    if ! command -v mk_remote_scan_checked >/dev/null 2>&1 &&
       [ -n "${MK_LIB_DIR:-}" ] && [ -f "$MK_LIB_DIR/remote.sh" ]; then
      # shellcheck source-path=SCRIPTDIR source=remote.sh
      . "$MK_LIB_DIR/remote.sh" 2>/dev/null
    fi
    if command -v mk_remote_scan_checked >/dev/null 2>&1; then
      mk_remote_scan_checked "$1" || true
      while IFS= read -r t; do
        if [ -n "$t" ]; then printf '%s\n' "${t%%$'\t'*}"; fi
      done <<EOF
$_rm_scan
EOF
    else
      printf 'unparsed\n'
    fi
  fi
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

# mk_careful_targets_code TARGETS -- approval code for a plan: TARGETS is a
# newline-separated list, sorted and de-duplicated (LC_ALL=C) so the order the
# model names them in does not matter. Bound to the project root like
# mk_careful_code.
mk_careful_targets_code() {
  local list
  list="$(printf '%s\n' "$1" | LC_ALL=C sort -u | sed '/^$/d')"
  printf '%s\n%s' "$MK_ROOT" "$list" | _mk_cf_sha256 | cut -c1-6
}

# _mk_cf_words LIST -- newline list -> sorted unique targets on one line,
# space-separated. Fails (exit 1) on an empty list or a target holding
# whitespace or a glob character (* ? [ ]), so a line in the pending/window files is always plain words.
_mk_cf_words() {
  local list flat
  flat="$(printf '%s' "$1" | tr -d '\n')"
  case "$flat" in
    *[[:space:]]*|*'*'*|*'?'*|*'['*|*']'*) return 1 ;;
  esac
  list="$(printf '%s\n' "$1" | LC_ALL=C sort -u | sed '/^$/d' | tr '\n' ' ')"
  [ -n "$list" ] || return 1
  printf '%s' "${list% }"
}

# _mk_cf_write FILE LINE -- replace FILE atomically (mktemp + mv, umask 077)
# with the single line LINE. Refuses an unsafe (symlinked / foreign) FILE and
# a path that is not absolute (mk_tmp printed nothing: a broken sed).
_mk_cf_write() {
  local f="$1" tmp
  case "$f" in /?*) ;; *) return 1 ;; esac
  _mk_cf_unsafe "$f" && return 1
  [ -d "$f" ] && return 1
  tmp="$( umask 077; mktemp "$f.XXXXXX" 2>/dev/null )" || return 1
  [ -n "$tmp" ] || return 1
  printf '%s\n' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# mk_careful_pending_file SESSION -- the session's pending plan file.
mk_careful_pending_file() {
  mk_tmp "careful-pending-$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' _)"
}

# mk_careful_pending_set SESSION CODE [TARGETS] -- remember the plan code the
# user is asked to approve: one line "<code> <expiry>[!] <targets...>"
# (TARGETS a newline list, may be empty), valid MK_CF_TTL seconds, replacing
# any earlier line of this session. The expiry carries a trailing "!" when
# this set REPLACED a different unexpired code (or a flagged line of the same
# code): two codes were shown to the user, so a bare approval must not pick
# one; only "onay <code>" grants a flagged line.
mk_careful_pending_set() {
  local f words="" exp old oc oe flag=""
  f="$(mk_careful_pending_file "$1")"
  _mk_cf_unsafe "$f" && return 1
  case "$2" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  if [ -n "${3:-}" ]; then words="$(_mk_cf_words "$3")" || return 1; fi
  if old="$(mk_careful_pending_get "$1")"; then
    oc="${old%% *}"; oe="${old#* }"; oe="${oe%% *}"
    if [ "$oc" != "$2" ]; then flag="!"; fi
    case "$oe" in *!) flag="!" ;; esac
  fi
  exp="$(( $(date +%s) + MK_CF_TTL ))"
  _mk_cf_write "$f" "$2 $exp$flag${words:+ $words}"
}

# mk_careful_pending_req_file SESSION -- sibling of the pending file holding
# the code a memokit-window.sh request minted in this session.
mk_careful_pending_req_file() {
  mk_tmp "careful-pending-req-$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' _)"
}

# mk_careful_pending_req_set SESSION CODE -- record that a request minted CODE.
mk_careful_pending_req_set() {
  case "$2" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  _mk_cf_write "$(mk_careful_pending_req_file "$1")" "$2 $(( $(date +%s) + MK_CF_TTL ))"
}

# mk_careful_pending_req_get SESSION -- print the code of the session's last
# request while its record is unexpired; exit 1 otherwise (an expired or
# malformed record is removed). A guard deny never touches the record; only
# mk_careful_pending_clear (approval) and expiry remove it.
mk_careful_pending_req_get() {
  local f c="" e=""
  f="$(mk_careful_pending_req_file "$1")"
  _mk_cf_unsafe "$f" && return 1
  [ -f "$f" ] || return 1
  read -r c e < "$f" || true
  case "$e" in ''|*[!0-9]*) rm -f "$f"; return 1 ;; esac
  { [ "${#e}" -le 12 ] && [ -n "$c" ]; } || { rm -f "$f"; return 1; }
  [ "$e" -gt "$(date +%s)" ] || { rm -f "$f"; return 1; }
  printf '%s\n' "$c"
}

# mk_careful_pending_clear SESSION -- drop the session's pending line (and
# the request record next to it).
mk_careful_pending_clear() {
  local f r
  f="$(mk_careful_pending_file "$1")"
  r="$(mk_careful_pending_req_file "$1")"
  _mk_cf_unsafe "$f" || rm -f "$f"
  _mk_cf_unsafe "$r" || rm -f "$r"
  return 0
}

# mk_careful_pending_get SESSION [CODE] -- print the pending line while it is
# unexpired (and, with CODE, matches it); exit 1 otherwise. The expiry keeps
# its "!" flag in the output. An expired or malformed file is removed.
mk_careful_pending_get() {
  local f code exp rest e
  f="$(mk_careful_pending_file "$1")"
  _mk_cf_unsafe "$f" && return 1
  [ -f "$f" ] || return 1
  read -r code exp rest < "$f" || true
  e="${exp%!}"
  # a dropped line also drops the session's request record once that expired
  case "$e" in ''|*[!0-9]*) rm -f "$f"; mk_careful_pending_req_get "$1" >/dev/null || true; return 1 ;; esac
  { [ "${#e}" -le 12 ] && [ -n "$code" ]; } || { rm -f "$f"; mk_careful_pending_req_get "$1" >/dev/null || true; return 1; }
  [ "$e" -gt "$(date +%s)" ] || { rm -f "$f"; mk_careful_pending_req_get "$1" >/dev/null || true; return 1; }
  if [ -n "${2:-}" ] && [ "$code" != "$2" ]; then return 1; fi
  printf '%s %s%s\n' "$code" "$exp" "${rest:+ $rest}"
}

# Change windows are per session (spec 0.8 Part A, security review S4): the
# window file careful-window-<session> and the failed marker
# careful-window-failed-<session>, the session id sanitised as the pending
# file's.
_mk_cf_sess() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' _; }
mk_careful_window_file() { mk_tmp "careful-window-$(_mk_cf_sess "$1")"; }
_mk_cf_window_failed_file() { mk_tmp "careful-window-failed-$(_mk_cf_sess "$1")"; }

# mk_careful_window_open SESSION MINUTES TARGETS -- open the session's change
# window: one line "<expiry> <targets...>". MINUTES is an integer 1-240,
# TARGETS a non-empty newline list, SESSION non-empty; anything else exits 1
# and writes nothing.
mk_careful_window_open() {
  local f words exp
  [ -n "$1" ] || return 1
  f="$(mk_careful_window_file "$1")"
  _mk_cf_unsafe "$f" && return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#2}" -le 3 ] || return 1
  [ "$((10#$2))" -ge 1 ] && [ "$((10#$2))" -le 240 ] || return 1
  words="$(_mk_cf_words "$3")" || return 1
  exp="$(( $(date +%s) + 10#$2 * 60 ))"
  _mk_cf_write "$f" "$exp $words"
}

# mk_careful_window_get SESSION -- print "<expiry> <targets...>" while the
# session's window is open; an expired or malformed file is removed and the
# exit is 1.
mk_careful_window_get() {
  local f exp rest
  [ -n "$1" ] || return 1
  f="$(mk_careful_window_file "$1")"
  _mk_cf_unsafe "$f" && return 1
  [ -f "$f" ] || return 1
  read -r exp rest < "$f" || true
  case "$exp" in ''|*[!0-9]*) rm -f "$f"; return 1 ;; esac
  { [ "${#exp}" -le 12 ] && [ -n "$rest" ]; } || { rm -f "$f"; return 1; }
  [ "$exp" -gt "$(date +%s)" ] || { rm -f "$f"; return 1; }
  printf '%s %s\n' "$exp" "$rest"
}

# mk_careful_window_covers SESSION TARGETS -- exit 0 only when the session's
# open window holds every target of the newline list TARGETS as a whole word.
# Pure bash (no here-document that could fail and read as "no target").
mk_careful_window_covers() {
  local line t rl n=0 nl='
'
  line="$(mk_careful_window_get "$1")" || return 1
  line=" ${line#* } "
  rl="$2$nl"
  while [ -n "$rl" ]; do
    t="${rl%%"$nl"*}"; rl="${rl#*"$nl"}"
    [ -n "$t" ] || continue
    n=$((n + 1))
    case "$line" in *" $t "*) ;; *) return 1 ;; esac
  done
  [ "$n" -gt 0 ]
}

# mk_careful_window_close SESSION [REASON] -- remove the session's window;
# with REASON also leave the failed marker (first line of REASON) for the
# next deny to report.
mk_careful_window_close() {
  local f ff
  f="$(mk_careful_window_file "$1")"
  _mk_cf_unsafe "$f" || rm -f "$f"
  if [ -n "${2:-}" ]; then
    ff="$(_mk_cf_window_failed_file "$1")"
    _mk_cf_write "$ff" "$(printf '%s\n' "$2" | head -n 1)"
  fi
  return 0
}

# mk_careful_window_failed SESSION -- print the session's failed reason once
# and remove it; exit 1 when there is none.
mk_careful_window_failed() {
  local ff reason
  ff="$(_mk_cf_window_failed_file "$1")"
  _mk_cf_unsafe "$ff" && return 1
  [ -f "$ff" ] || return 1
  IFS= read -r reason < "$ff" || true
  rm -f "$ff"
  [ -n "$reason" ] || return 1
  printf '%s\n' "$reason"
}
