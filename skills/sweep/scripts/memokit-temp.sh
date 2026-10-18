#!/usr/bin/env bash
# memokit temp-space helper for /memokit:sweep (read-only; it never deletes).
#   list   TSV lines: stale|active|manual <TAB> kb <TAB> human <TAB> last activity
#          (UTC ISO) <TAB> absolute path, largest first, for every sibling session
#          dir and loose entry of the CURRENT project's temp dir that holds files
#          (> 0 KB). The current session is never listed. "manual" marks a path
#          with a control character (printed with "?" in its place) or any char
#          outside [A-Za-z0-9._/@+,:%-] (non-ASCII included): it is never
#          offered and must not be deleted by name.
#   free   free disk space, human readable
#   worktrees
#          TSV lines: status <TAB> kind <TAB> kb <TAB> human <TAB> last commit (UTC
#          ISO) <TAB> worktree path or branch <TAB> branch <TAB> merged-into
#          (head|default|-) <TAB> note, for every leftover worktree under
#          .claude/worktrees/ and mk/* branch without a worktree, except the one
#          this shell runs in (hooks/lib/worktrees.sh mk_wt_list; statuses
#          documented there). On top of those, for a merged-clean row:
#          "manual" when the name under .claude/worktrees/ or the branch holds a
#          char outside [A-Za-z0-9._/@+,:%-], or the path a quote or "?" (a
#          control char), or an ignored entry holds a nested .git;
#          "merged-ignored" when the worktree has ignored files (git worktree
#          remove would delete them), named in the note; "dirty" when that
#          check sees a change. An "active-run" row (a lane of a run whose
#          ledger says status: active) names its run in the note. Needs no
#          temp dir.
# The current session comes from MEMOKIT_SESSION_ID / MEMOKIT_TRANSCRIPT_PATH,
# else the newest *.jsonl in ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<slug of the
# project root>/.
set -u
# Byte-wise character classes: the name test below must reject every non-ASCII
# byte whatever the user's locale. Nothing here depends on a locale.
LC_ALL=C; export LC_ALL
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/common.sh
. "$SELF_DIR/../../../hooks/lib/common.sh"

CMD="${1:-}"
case "$CMD" in
  list|free|worktrees) ;;
  *) printf 'usage: memokit-temp.sh list|free|worktrees\n' >&2; exit 2 ;;
esac

mk_resolve_root "$(jq -nc --arg c "$PWD" '{cwd:$c}' 2>/dev/null || printf '{}')"
if ! mk_active; then printf 'memokit is not configured here (.claude/memokit.json missing).\n' >&2; exit 2; fi
if ! mk_load_config; then printf 'invalid .claude/memokit.json (field: %s)\n' "$MK_CONFIG_ERR" >&2; exit 2; fi
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/temp.sh
. "$MK_LIB_DIR/temp.sh"

if [ "$CMD" = "worktrees" ]; then
  # shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/worktrees.sh
  . "$MK_LIB_DIR/worktrees.sh"
  tab="$(printf '\t')"
  # The worktree this shell runs in is never a leftover, whatever MK_ROOT is.
  wt="$(mk_wt_list "$MK_ROOT" "" "$PWD")"
  [ -n "$wt" ] || exit 0
  # ignored_scan WT -- sets ig_n (ignored entries), ig_list (first 3, ", "
  # separated, "?" for control chars), ig_git (1 when an ignored dir holds a .git) and
  # returns 1 when the status cannot be read or shows anything but "!!".
  ignored_scan() {
    local f rec rc e
    ig_n=0; ig_list=""; ig_git=0
    f="$(mktemp "${TMPDIR:-/tmp}/memokit-wtig.XXXXXX" 2>/dev/null)" || return 1
    git -C "$1" --no-optional-locks status --porcelain -z --ignored --untracked-files=normal --ignore-submodules=none > "$f" 2>/dev/null
    rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$f"; return 1; fi
    while IFS= read -r -d '' rec; do
      case "$rec" in
        '!! '?*) e="${rec#!! }" ;;
        *) rc=1; break ;;
      esac
      ig_n=$((ig_n + 1))
      if [ "$ig_n" -le 3 ]; then ig_list="$ig_list${ig_list:+, }$(_mk_wt_show "$e")"; fi
      # Only an ignored DIRECTORY (git prints it with a trailing "/") can hold a
      # nested repo; one find per ignored file was seconds for a few thousand.
      case "$e" in
        */) if [ "$ig_git" -eq 0 ] && [ -n "$(find "$1/${e%/}" -name .git -print -quit 2>/dev/null)" ]; then ig_git=1; fi ;;
      esac
    done < "$f"
    rm -f "$f"
    [ "$ig_n" -gt 3 ] && ig_list="$ig_list, ..."
    return "$rc"
  }
  out=""
  while IFS="$tab" read -r kind st kb last name br mi; do
    [ -n "$kind" ] || continue
    note="-"
    if [ "$st" = active-run ]; then
      # mk/<run>/<lane>: name the run; the session's resume continues it.
      case "$br" in mk/?*/?*) rid="${br#mk/}"; note="run ${rid%%/*} (/memokit:resume)" ;; *) note="active run (/memokit:resume)" ;; esac
    fi
    if [ "$st" = merged-clean ]; then
      # Only the part memokit chose (the name under .claude/worktrees/ and the
      # branch) must be plain; the repo path is single-quoted in the command,
      # so it only must not hold a quote or a "?" (a control char shown as ?).
      if [ "$kind" = worktree ]; then
        rel="${name##*/.claude/worktrees/}"
        [ "$rel" = "$name" ] && rel="${name##*/}"
        case "$name" in *"'"*|*'?'*) st=manual ;; esac
      else
        rel=""
      fi
      case "$rel$br" in *[!A-Za-z0-9._/@+,:%-]*) st=manual ;; esac
      [ "$st" = manual ] && note="name needs a hand-written command"
    fi
    if [ "$st" = merged-clean ] && [ "$kind" = worktree ]; then
      if ! ignored_scan "$name"; then
        st=dirty; mi="-"
      elif [ "$ig_git" -eq 1 ]; then
        st=manual; note="nested repo under ignored: $ig_n ($ig_list)"
      elif [ "$ig_n" -gt 0 ]; then
        st=merged-ignored; note="ignored: $ig_n ($ig_list)"
      fi
    fi
    case "$kb" in
      ''|*[!0-9]*) kb="?"; hs="?" ;;
      *) if [ "$kb" -lt 1024 ]; then hs="$kb KB"; else hs="$(mk_human_kb "$kb")"; fi ;;
    esac
    out="$out$st$tab$kind$tab$kb$tab$hs$tab$last$tab$name$tab$br$tab$mi$tab$note
"
  done <<EOF
$wt
EOF
  # One write: a reader that stops early (SIGPIPE ignored) costs one quiet error.
  printf '%s' "$out" 2>/dev/null || exit 0
  exit 0
fi

tp="${MEMOKIT_TRANSCRIPT_PATH:-}"
sid="${MEMOKIT_SESSION_ID:-}"
if [ -z "$tp" ]; then
  slug="$(printf '%s' "$MK_ROOT" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  pd="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug"
  # shellcheck disable=SC2012  # transcript names are uuids, ls -t is fine
  newest="$(ls -t "$pd"/*.jsonl 2>/dev/null | head -n 1)"
  tp="$newest"
fi
if [ -n "$tp" ] && [ -z "$sid" ]; then sid="${tp##*/}"; sid="${sid%.jsonl}"; fi
if ! mk_temp_init "$(jq -nc --arg t "$tp" --arg s "$sid" '{transcript_path:$t,session_id:$s}')"; then
  if [ "$CMD" = "free" ]; then
    kb="$(mk_disk_free_kb)" && mk_human_kb "$kb" && printf '\n'
    exit 0
  fi
  printf 'cannot locate this session'"'"'s temp dir (no transcript found)\n' >&2
  exit 1
fi

if [ "$CMD" = "free" ]; then
  kb="$(mk_disk_free_kb)" || exit 1
  mk_human_kb "$kb"; printf '\n'
  exit 0
fi

human() { if [ "$1" -lt 1024 ]; then printf '%s KB' "$1"; else mk_human_kb "$1"; fi; }
tab="$(printf '\t')"; nl='
'; cr="$(printf '\r')"
out=""
for e in "$MK_TEMP_PROJECT_DIR"/* "$MK_TEMP_PROJECT_DIR"/.[!.]* "$MK_TEMP_PROJECT_DIR"/..?*; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  name="${e##*/}"
  [ "$name" = "$MK_TEMP_SESSION_ID" ] && continue
  [ "$e" -ef "$MK_TEMP_SESSION_DIR" ] && continue
  # Skeleton (only dirs) is not worth offering; ext4 sizes an empty dir at 4 KB.
  [ -n "$(find "$e" ! -type d -print -quit 2>/dev/null)" ] || continue
  kb="$(du -sk -- "$e" 2>/dev/null | head -n 1)"; kb="${kb%%"$tab"*}"
  case "$kb" in ''|*[!0-9]*) continue ;; esac
  [ "$kb" -gt 0 ] || continue
  # Last activity: the transcript's mtime for a session dir that has one, else
  # the entry's birth time (never the dir mtime, which the system cleaner moves).
  t=""
  if [ -f "$MK_TEMP_TRANSCRIPT_DIR/$name.jsonl" ]; then t="$(mk_temp_mtime "$MK_TEMP_TRANSCRIPT_DIR/$name.jsonl")" || t=""; fi
  [ -n "$t" ] || t="$(mk_temp_birth "$e")" || t=0
  iso="$(jq -rn --argjson t "$t" '$t | todate' 2>/dev/null)" || iso="?"
  case "$e" in
    *"$nl"*|*"$tab"*|*"$cr"*)
      st=manual; shown="${e//$nl/?}"; shown="${shown//$tab/?}"; shown="${shown//$cr/?}" ;;
    *[!A-Za-z0-9._/@+,:%-]*)
      # Not a form the guard passes as a single literal rm: never offered.
      st=manual; shown="$e" ;;
    *)
      if mk_temp_is_stale "$name"; then st=stale; else st=active; fi
      shown="$e" ;;
  esac
  out="$out$kb$tab$st$tab$(human "$kb")$tab$iso$tab$shown$nl"
done
# Sort by size (field 1), then print without it: status first.
[ -n "$out" ] || exit 0
printf '%s' "$out" | LC_ALL=C sort -t "$tab" -k1,1nr -k5,5 | awk -F'\t' -v OFS='\t' '{print $2,$1,$3,$4,$5}'
exit 0
