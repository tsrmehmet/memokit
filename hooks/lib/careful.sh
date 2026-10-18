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

MK_CF_SAFE_RM="node_modules bin obj dist build .next coverage TestResults"
# Set (as a local) only by mk_careful_labels; see _mk_cf_rm.
_MK_CF_TEMP_OK=0

# _mk_cf_has ERE TEXT -- case-sensitive ERE test, quiet on a bad regex.
_mk_cf_has() { printf '%s' "$2" | grep -Eq -- "$1" 2>/dev/null; }

# _mk_cf_cmdre WORD SUB-ERE -- ERE: WORD is a command (not part of a longer
# word) and SUB appears later in the segment as a whole word.
_mk_cf_cmdre() {
  printf '%s' "(^|[^[:alnum:]_.-])$1([[:space:]]+[^[:space:]]+)*[[:space:]]+($2)([[:space:]]|\$)"
}

# _mk_cf_rule SEGMENTS ERE... -- true when ONE segment (line) matches every
# ERE; an ERE starting with "!" must NOT match. One grep per ERE over all
# segments, so the fork count does not depend on the number of segments.
_mk_cf_rule() {
  local cur="$1" re
  shift
  for re in "$@"; do
    case "$re" in
      '!'*) cur="$(printf '%s\n' "$cur" | grep -Ev -- "${re#!}" 2>/dev/null)" ;;
      *) cur="$(printf '%s\n' "$cur" | grep -E -- "$re" 2>/dev/null)" ;;
    esac
  done
  printf '%s' "$cur" | grep -q .
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
      --recursive) recursive=1; continue ;;
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
        if [ "${_MK_CF_TEMP_OK:-0}" = 1 ] && [ -n "${MK_TEMP_PROJECT_DIR:-}" ] &&
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

# mk_careful_segments CMD -- one shell segment per line. Quotes are not
# parsed: a separator inside quotes only makes an extra, harmless split.
mk_careful_segments() {
  printf '%s\n' "$1" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); gsub(/[[:space:]]&[[:space:]]/, "\n"); print }'
}

# mk_careful_builtin CMD -- builtin labels the command matches, one per line.
mk_careful_builtin() {
  local segs seg flat
  if _mk_cf_has 'careful-grants' "$1"; then printf 'careful-state\n'; fi
  flat="$(printf '%s' "$1" | tr '\n' ' ')"
  if printf '%s' "$1" | grep -Eiq '(^|[^[:alnum:]_])(psql|mysql|mariadb|sqlite3|sqlcmd)([^[:alnum:]_./-]|$)' &&
     printf '%s' "$flat" | grep -Eiq '(^|[^[:alnum:]_])(drop[[:space:]]+(table|database|schema)|truncate|delete[[:space:]]+from)([^[:alnum:]_]|$)'; then
    printf 'sql-destructive\n'
  fi
  segs="$(mk_careful_segments "$1")"
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git push)" \
       '[[:space:]](-f|--force|-[a-zA-Z]*f[a-zA-Z]*|\+[^[:space:]]+)([[:space:]]|$)'; then
    printf 'git-force-push\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git reset)" '[[:space:]]--hard([[:space:]]|$)'; then
    printf 'git-reset-hard\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git clean)" \
       '[[:space:]](--force|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]]|$)' \
       '![[:space:]](--dry-run|-[a-zA-Z]*n[a-zA-Z]*)([[:space:]]|$)'; then
    printf 'git-clean\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git branch)" '[[:space:]]-[a-zA-Z]*D[a-zA-Z]*([[:space:]]|$)' ||
     _mk_cf_rule "$segs" "$(_mk_cf_cmdre git branch)" '[[:space:]](-d|--delete)([[:space:]]|$)' \
       '[[:space:]](-f|--force)([[:space:]]|$)' ||
     _mk_cf_rule "$segs" "$(_mk_cf_cmdre git branch)" \
       '[[:space:]]-[a-zA-Z]*(d[a-zA-Z]*f|f[a-zA-Z]*d)[a-zA-Z]*([[:space:]]|$)'; then
    printf 'git-branch-delete\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre git 'checkout|restore')" '[[:space:]]\.([[:space:]]|$)' \
       '![[:space:]](--staged|-S)([[:space:]]|$)' ||
     _mk_cf_rule "$segs" "$(_mk_cf_cmdre git 'checkout|restore')" '[[:space:]]\.([[:space:]]|$)' \
       '[[:space:]](--staged|-S)([[:space:]]|$)' '[[:space:]](--worktree|-W)([[:space:]]|$)'; then
    printf 'git-discard-all\n'
  fi
  # rm: one grep pre-selects segments, then the (fork-free) token parser runs.
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    if _mk_cf_rm "$seg"; then printf 'rm-recursive\n'; break; fi
  done <<EOF
$(printf '%s\n' "$segs" | grep -E '(^|[^[:alnum:]_.-])rm[[:space:]]' 2>/dev/null)
EOF
  if _mk_cf_rule "$segs" '(^|[^[:alnum:]_.-])dotnet[[:space:]]+ef[[:space:]]+database[[:space:]]+drop([[:space:]]|$)'; then
    printf 'ef-database-drop\n'
  fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre kubectl delete)"; then printf 'kubectl-delete\n'; fi
  if _mk_cf_rule "$segs" "$(_mk_cf_cmdre helm 'uninstall|delete')"; then printf 'helm-uninstall\n'; fi
  if _mk_cf_rule "$segs" '(^|[^[:alnum:]_.-])docker([[:space:]]+[^[:space:]]+)*[[:space:]]+(system[[:space:]]+prune|volume[[:space:]]+(prune|rm))([[:space:]]|$)'; then
    printf 'docker-prune\n'
  fi
}

# _mk_cf_pattern I FIELD -- field of the I-th project pattern (jq -r adds the newline).
_mk_cf_pattern() { printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq -r ".[$1].$2" 2>/dev/null; }

# mk_careful_project CMD -- labels of matching project patterns. A regex
# grep -E rejects makes grep exit 2, i.e. no match: only that pattern is off.
mk_careful_project() {
  local n i
  n="$(printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq 'length' 2>/dev/null)" || n=0
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    if printf '%s' "$1" | grep -Eiq -- "$(_mk_cf_pattern "$i" match)" 2>/dev/null; then
      _mk_cf_pattern "$i" label
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
        [ "$targets" -eq 0 ] && [ "$dd" -eq 0 ] || { rc=1; break; }
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

# mk_careful_labels CMD -- builtin + project labels, de-duplicated, in order.
mk_careful_labels() {
  local joined stripped _MK_CF_TEMP_OK=0
  joined="$(mk_careful_join "$1")"
  stripped="$(mk_careful_strip "$1")"
  # Seen by _mk_cf_rm through dynamic scope; never set anywhere else.
  if [ -n "${MK_TEMP_PROJECT_DIR:-}" ] && [ "$joined" = "$stripped" ] &&
     mk_careful_single_rm "$1"; then
    _MK_CF_TEMP_OK=1
  fi
  {
    mk_careful_builtin "$joined"; mk_careful_project "$joined"
    if [ "$stripped" != "$joined" ]; then
      mk_careful_builtin "$stripped"; mk_careful_project "$stripped"
    fi
  } | awk 'NF && !seen[$0]++'
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
