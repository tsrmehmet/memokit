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
  list|free) ;;
  *) printf 'usage: memokit-temp.sh list|free\n' >&2; exit 2 ;;
esac

mk_resolve_root "$(jq -nc --arg c "$PWD" '{cwd:$c}' 2>/dev/null || printf '{}')"
if ! mk_active; then printf 'memokit is not configured here (.claude/memokit.json missing).\n' >&2; exit 2; fi
if ! mk_load_config; then printf 'invalid .claude/memokit.json (field: %s)\n' "$MK_CONFIG_ERR" >&2; exit 2; fi
# shellcheck source-path=SCRIPTDIR source=../../../hooks/lib/temp.sh
. "$MK_LIB_DIR/temp.sh"

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
