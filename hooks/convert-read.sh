#!/usr/bin/env bash
# PreToolUse hook (Read), 0.8.1: opt-in markitdown conversion. A Read of a
# PDF, DOCX, PPTX or XLSX file is redirected to a cached Markdown conversion,
# which costs far fewer tokens than page images plus text.
#
# - Gates, in order: a matching extension anywhere in the payload text (the
#   fast path below: no fork, no jq), memokit active with a valid config,
#   convert.markitdown true, markitdown on PATH, tool Read with an absolute
#   file_path ending in .pdf/.docx/.pptx/.xlsx (any case) and no pages
#   argument (pages = the model wants page images), a regular readable file,
#   and no Read deny or ask rule in any settings file the hook can see (the
#   project root's, the launch dir's, the payload cwd's, the user's, managed
#   settings and their managed-settings.d drop-ins). Claude Code evaluates
#   permission rules against the input a hook returns, so a rule naming the
#   original path would not see the redirected Read; with any such rule the
#   hook stays out. Rules given on the command line or by MDM policies are
#   not seen. Main session and subagents alike.
# - Output: updatedInput = the original tool_input with file_path replaced,
#   plus one line of additionalContext. permissionDecision "allow" when the
#   source lies inside CLAUDE_PROJECT_DIR (set, resolved physically, not /;
#   never the payload cwd; the source not a symlink): a Read there needs
#   no prompt anyway, and without a decision auto mode denies a Read whose
#   input a hook changed. Any other source gets "ask" with a reason naming
#   the original path, so the user approves that document, not a temp path.
#   Deny and ask rules still apply (hooks reference: "ask" shows the modified
#   input to the user).
# - It never denies: every other outcome is exit 0 with no output (fail open:
#   a convenience, not a guard), so the shared budget trap is not armed.
# - Cache: mk_tmp "careful-convert" (0700, ours, not a symlink): in
#   memokit's protected state family (release fix d), so a subagent can
#   plant no Markdown there for the orchestrator's next Read of that
#   document: a subagent file-tool write below it is denied
#   (guard-subagent-authority.sh) and a Bash command naming it is
#   careful-state (lib/careful.sh, main session too); the redirected Read
#   is checked by neither. Each source has its
#   own dir <sha256>-<size>/ holding <basename>.md (basename cut to 120
#   bytes, extension kept), so a "don't ask again" on
#   that dir covers that document only. Written mktemp + mv; a hit skips
#   markitdown and refreshes the .md's mtime. Nothing there is trusted
#   unless the cache dir and the key dir are directories of ours, not
#   symlinks, and the entry (or skip marker) a regular file of ours, not a
#   symlink: a key dir that is not is removed (a link itself, never its
#   target) and made again, an entry that is not is removed before the
#   conversion, and the redirect checks all three again before it is
#   printed; what cannot be removed leaves the Read alone. A scanned PDF,
#   an empty result or a timeout leaves <key>/.skip (umask 077, made
#   anew with noclobber, never refreshed, ignored and removed after a day) so the next Read of the same content is neither
#   converted nor waited on again; a failed run is retried. Every new entry
#   or skip marker removes files untouched for 7 days and then empty source
#   dirs; mk_state_prune removes the whole cache dir 7 days after its last
#   new source dir.
# - Conversion: markitdown <file> -o <tmp>, the file as one argument, stdin
#   /dev/null, 45 s wall clock (hook timeout 60 s); on timeout TERM to it and
#   its descendants, KILL 2 s later, and the Read is left alone.
#   Test seams: MEMOKIT_TEST_CONVERT_SECS shortens the bound;
#   MEMOKIT_TEST_MANAGED_DIR adds a managed-settings dir to the scan (the
#   real managed paths are always scanned, so it cannot hide a rule).
# - A source path holding a control character is never redirected.
# - Scanned PDF: fewer than 200 non-blank bytes of Markdown per page; pages
#   are the /Type /Page objects (not /Pages) in the first 32 MiB; when that
#   finds 0 or 1, the largest /Count there (object streams hide the pages);
#   none counts as 1. Office files: any non-empty text.
set -u

# _cv_fast PAYLOAD -- true when the payload text can name a matching file.
# One regex under LC_ALL=C (bash 3.2's regexec finds nothing in a UTF-8
# locale when the text holds an invalid byte), payloads over 64 KiB skipped.
_cv_fast() {
  local LC_ALL=C
  local re='\.([Pp][Dd][Ff]|[Dd][Oo][Cc][Xx]|[Pp][Pp][Tt][Xx]|[Xx][Ll][Ss][Xx])"'
  [ "${#1}" -le 65536 ] && [[ $1 =~ $re ]]
}
PAYLOAD=""
IFS= read -r -d '' PAYLOAD || true
_cv_fast "$PAYLOAD" || exit 0

# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "convert-read" "$PAYLOAD"
mk_load_config || exit 0
[ "$MK_CONVERT_MARKITDOWN" = 1 ] || exit 0
command -v markitdown >/dev/null 2>&1 || exit 0

CV_FILE=""; CV_CWD=""
eval "$(printf '%s' "$PAYLOAD" | jq -r '
  if (.tool_name // "") == "Read" and (.tool_input | type) == "object"
     and (.tool_input.file_path | type) == "string"
     and ((.tool_input.pages // "") | tostring) == ""
  then @sh "CV_FILE=\(.tool_input.file_path) CV_CWD=\((.cwd // "") | tostring)" else empty end' 2>/dev/null)"
CV_KIND=""
case "$CV_FILE" in
  /*.[Pp][Dd][Ff]) CV_KIND=pdf ;;
  /*.[Dd][Oo][Cc][Xx]|/*.[Pp][Pp][Tt][Xx]|/*.[Xx][Ll][Ss][Xx]) CV_KIND=office ;;
  *) exit 0 ;;
esac
[ -f "$CV_FILE" ] && [ -r "$CV_FILE" ] || exit 0
# A path holding a control character is never redirected: it would reach the
# ask reason and the context line (one regex under LC_ALL=C, bounded path).
_cv_cntrl() { local LC_ALL=C; local re='[[:cntrl:]]'; [[ $1 =~ $re ]]; }
_cv_cntrl "$CV_FILE" && exit 0
# The launch dir for the settings scan: where the user started Claude Code,
# else the payload cwd. The allow decision uses CLAUDE_PROJECT_DIR alone.
CV_LAUNCH="${CLAUDE_PROJECT_DIR:-$CV_CWD}"

# _cv_read_rules -- true when a settings file holds a Read deny or ask rule,
# or one that exists cannot be read as JSON.
_cv_read_rules() {
  local f d cfg="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  set --
  for d in "$MK_ROOT" "$CV_LAUNCH" "$CV_CWD"; do
    [ -n "$d" ] || continue
    for f in "$d/.claude/settings.json" "$d/.claude/settings.local.json"; do
      [ -e "$f" ] && set -- "$@" "$f"
    done
  done
  for f in "$cfg/settings.json" "$cfg/settings.local.json"; do
    [ -e "$f" ] && set -- "$@" "$f"
  done
  # The real managed settings always; the test seam only adds a dir.
  set -- "$@" "/Library/Application Support/ClaudeCode/managed-settings.json" \
    "/Library/Application Support/ClaudeCode/managed-settings.d"/*.json \
    /etc/claude-code/managed-settings.json /etc/claude-code/managed-settings.d/*.json
  if [ -n "${MEMOKIT_TEST_MANAGED_DIR:-}" ]; then
    set -- "$@" "$MEMOKIT_TEST_MANAGED_DIR"/managed-settings.json "$MEMOKIT_TEST_MANAGED_DIR"/managed-settings.d/*.json
  fi
  # Drop the names that do not exist (an unmatched glob stays literal).
  for f in "$@"; do shift; [ -e "$f" ] && set -- "$@" "$f"; done
  [ "$#" -eq 0 ] && return 1
  [ "$(jq -s '[.[] | ((.permissions.deny // []) + (.permissions.ask // []))[]
      | select(type == "string" and test("^\\s*Read\\s*(\\(|$)"))] | length' "$@" 2>/dev/null)" != 0 ]
}
_cv_read_rules && exit 0

# _cv_own F -- a regular file of ours, not a symlink.
_cv_own() { [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]; }
# _cv_dir_ok D -- a directory of ours, not a symlink.
_cv_dir_ok() { [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]; }
# _cv_mkdir D -- create D (umask 077) unless something is there; then check.
_cv_mkdir() {
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then ( umask 077; mkdir "$1" ) 2>/dev/null; fi
  _cv_dir_ok "$1"
}
# _cv_in_launch -- CLAUDE_PROJECT_DIR is set and resolves (physically) to a
# directory other than /, the source's directory resolved physically is
# under it, and the source itself is not a symlink. The payload cwd never
# counts here.
_cv_in_launch() {
  local top dirp
  [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ ! -L "$CV_FILE" ] || return 1
  top="$(CDPATH='' cd -- "$CLAUDE_PROJECT_DIR" 2>/dev/null && pwd -P)" || return 1
  case "$top" in ''|/) return 1 ;; esac
  dirp="$(CDPATH='' cd -- "$(dirname -- "$CV_FILE")" 2>/dev/null && pwd -P)" || return 1
  case "$dirp/" in "$top"/*) return 0 ;; esac
  return 1
}
# _cv_redirect -- print the redirect to CV_MD, only when the cache dir, the
# key dir and the entry are still ours (a swap since the hit or the mv
# leaves the Read alone).
_cv_redirect() {
  local ctx why="" dec=allow
  _cv_dir_ok "$CV_DIR" && _cv_dir_ok "$CV_KEYDIR" && _cv_own "$CV_MD" || return 0
  ctx="$(mk_msg CV_REDIRECT "$CV_FILE" "$CV_MD")" || return 0
  if ! _cv_in_launch; then
    dec=ask; why="$(mk_msg CV_ASK "$CV_FILE" "$CV_MD")" || return 0
  fi
  printf '%s' "$PAYLOAD" | jq -c --arg p "$CV_MD" --arg c "$ctx" --arg d "$dec" --arg w "$why" '
    {hookSpecificOutput: ({hookEventName: "PreToolUse", permissionDecision: $d}
      + (if $w == "" then {} else {permissionDecisionReason: $w} end)
      + {updatedInput: (.tool_input + {file_path: $p}), additionalContext: $c})}' 2>/dev/null
  return 0
}
# _cv_sha256 FILE -- the hex SHA-256 of FILE (shasum, sha256sum or openssl).
_cv_sha256() {
  local out re='([0-9a-f]{64})'
  if command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256 < "$1" 2>/dev/null)"
  elif command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum < "$1" 2>/dev/null)"
  else out="$(openssl dgst -sha256 < "$1" 2>/dev/null)"; fi
  [[ $out =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
# _cv_prune -- files untouched for 7 days, then empty source dirs.
_cv_prune() {
  find "$CV_DIR" -mindepth 2 -maxdepth 2 -type f -mtime +6 -exec rm -f {} + 2>/dev/null
  find "$CV_DIR" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} + 2>/dev/null
  return 0
}

CV_DIR="$(mk_tmp careful-convert)"
_cv_mkdir "$CV_DIR" || exit 0
cv_sum="$(_cv_sha256 "$CV_FILE")" || exit 0
cv_size="$(wc -c < "$CV_FILE" 2>/dev/null | tr -d ' ')"
case "$cv_size" in ''|*[!0-9]*) exit 0 ;; esac
cv_size=$((10#$cv_size))
CV_KEYDIR="$CV_DIR/$cv_sum-$cv_size"
# _cv_short NAME -- NAME cut to 120 bytes, keeping its extension; a UTF-8
# sequence split by the cut is dropped (iconv -c), so the cache name stays
# under NAME_MAX with ".md" and is the same on every Read.
_cv_short() {
  local LC_ALL=C
  local n="$1" ext
  if [ "${#n}" -le 120 ]; then printf '%s' "$n"; return 0; fi
  ext=".${n##*.}"
  printf '%s%s' "$(printf '%s' "${n:0:$((120 - ${#ext}))}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)" "$ext"
}
CV_MD="$CV_KEYDIR/$(_cv_short "$(basename -- "$CV_FILE")").md"
CV_SKIP="$CV_KEYDIR/.skip"
# A hit or a skip marker counts only inside a key dir of ours; anything
# else at the key dir's name (a symlink, a file) is removed and the key dir
# made again: a miss.
if _cv_dir_ok "$CV_KEYDIR"; then
  if _cv_own "$CV_MD" && [ -s "$CV_MD" ]; then
    touch "$CV_MD" 2>/dev/null
    _cv_redirect
    exit 0
  fi
  if _cv_own "$CV_SKIP"; then
    [ -n "$(find "$CV_SKIP" -mmin +1440 2>/dev/null)" ] || exit 0
    rm -f "$CV_SKIP"
  fi
elif [ -e "$CV_KEYDIR" ] || [ -L "$CV_KEYDIR" ]; then
  rm -f "$CV_KEYDIR" 2>/dev/null
fi
_cv_mkdir "$CV_KEYDIR" || exit 0
# An entry that is not a regular file of ours (a symlink, a directory) or
# is empty: removed first; one that stays leaves the Read alone.
if [ -e "$CV_MD" ] || [ -L "$CV_MD" ]; then
  rm -f "$CV_MD" 2>/dev/null
  { [ -e "$CV_MD" ] || [ -L "$CV_MD" ]; } && exit 0
fi

CV_TMP="$( umask 077; mktemp "$CV_KEYDIR/.conv.XXXXXX" 2>/dev/null )" || exit 0
[ -n "$CV_TMP" ] || exit 0
trap 'rm -f "$CV_TMP"; rmdir "$CV_KEYDIR" 2>/dev/null' EXIT
cv_secs=45
case "${MEMOKIT_TEST_CONVERT_SECS:-}" in ''|*[!0-9]*) ;; *) cv_secs="$MEMOKIT_TEST_CONVERT_SECS" ;; esac

# _cv_kids PID -- PID's children: pgrep -P; without pgrep (Linux without
# procps) the ppid field of /proc/*/stat, read with builtins (the field after
# the state, which follows the last ") ": a command name may hold one);
# neither: none.
_cv_kids() {
  local f l
  if command -v pgrep >/dev/null 2>&1; then pgrep -P "$1" 2>/dev/null; return 0; fi
  [ -r /proc/self/stat ] || return 0
  for f in /proc/[0-9]*/stat; do
    l=""; read -r l 2>/dev/null < "$f"
    l="${l##*) }"; l="${l#* }"
    if [ "${l%% *}" = "$1" ]; then l="${f#/proc/}"; printf '%s\n' "${l%/stat}"; fi
  done
  return 0
}
# _cv_tree PID -- PID and all its descendants (listed before any is killed:
# a parent killed first would orphan its children out of reach).
_cv_tree() {
  local c
  for c in $(_cv_kids "$1"); do _cv_tree "$c"; done
  printf '%s\n' "$1"
}
markitdown "$CV_FILE" -o "$CV_TMP" </dev/null >/dev/null 2>&1 &
cv_pid=$!
# Watchdog (as in lib/budget.sh): its sleeps are children it kills on TERM.
# When it fires it TERMs the conversion tree, KILLs it 2 s later (also when
# the hook stops it during those 2 s) and exits 3.
# shellcheck disable=SC2016,SC2086  # $s/$t/$st are read in the child; one pid per word
( st=0; s=""; t=""
  trap '[ -n "$s" ] && kill "$s" 2>/dev/null; [ "$st" = 3 ] && kill -KILL $t 2>/dev/null; exit "$st"' TERM
  sleep "$cv_secs" & s=$!; wait "$s"
  t="$(_cv_tree "$cv_pid")"; st=3
  kill -TERM $t 2>/dev/null
  sleep 2 & s=$!; wait "$s"
  kill -KILL $t 2>/dev/null
  exit 3 ) >/dev/null 2>&1 </dev/null &
cv_wd=$!
cv_rc=0
wait "$cv_pid" 2>/dev/null || cv_rc=$?
# Stop the watchdog and its sleep (named here too: a TERM that lands before
# the watchdog recorded its sleep's pid would leave the sleep behind).
# shellcheck disable=SC2046  # one pid per word
kill "$cv_wd" $(_cv_kids "$cv_wd") 2>/dev/null
cv_wdrc=0
wait "$cv_wd" 2>/dev/null || cv_wdrc=$?

# _cv_skip -- leave the skip marker and stop. Whatever is at its name goes
# first and the new one is made with noclobber (O_EXCL): never written
# through a planted link.
_cv_skip() { ( umask 077; rm -f "$CV_SKIP"; set -C; : > "$CV_SKIP" ) 2>/dev/null; _cv_prune; exit 0; }
[ "$cv_rc" -ne 0 ] && [ "$cv_wdrc" -eq 3 ] && _cv_skip
[ "$cv_rc" -eq 0 ] || exit 0
cv_chars="$(LC_ALL=C tr -d '[:space:]' < "$CV_TMP" | wc -c | tr -d ' ')"
case "$cv_chars" in ''|*[!0-9]*) exit 0 ;; esac
# Parsed numbers are read in base 10 ($((10#...))): a leading zero would be
# octal, and 08 or 09 an arithmetic error.
cv_chars=$((10#$cv_chars))
[ "$cv_chars" -gt 0 ] || _cv_skip
if [ "$CV_KIND" = pdf ]; then
  cv_pages="$(head -c 33554432 "$CV_FILE" | LC_ALL=C grep -a -o -E '/Type[[:space:]]*/Page([^A-Za-z]|$)' | wc -l | tr -d ' ')"
  case "$cv_pages" in ''|*[!0-9]*) cv_pages=0 ;; *) cv_pages=$((10#$cv_pages)) ;; esac
  if [ "$cv_pages" -le 1 ]; then
    cv_count="$(head -c 33554432 "$CV_FILE" | LC_ALL=C grep -a -o -E '/Count[[:space:]]+[0-9]{1,6}' | LC_ALL=C tr -dc '0-9\n' | sort -n | tail -1)"
    case "$cv_count" in
      ''|*[!0-9]*) ;;
      *) cv_count=$((10#$cv_count)); [ "$cv_count" -gt "$cv_pages" ] && cv_pages="$cv_count" ;;
    esac
  fi
  [ "$cv_pages" -ge 1 ] || cv_pages=1
  [ "$cv_chars" -ge $((200 * cv_pages)) ] || _cv_skip
fi
mv -f "$CV_TMP" "$CV_MD" 2>/dev/null || exit 0
_cv_prune
_cv_redirect
exit 0
