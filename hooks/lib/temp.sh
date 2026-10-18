#!/usr/bin/env bash
# memokit temp-tree and disk measurement library. Sourced after common.sh (and,
# for the staleness functions, after mk_load_config), never executed.
# bash 3.2-safe; works with BSD (macOS) and GNU (Linux) stat/find/du/df.
# Consumers: guard-destructive.sh via careful.sh (mk_temp_init,
# mk_temp_rm_safe), check-subagent-scratch.sh (mk_temp_footprint,
# mk_temp_iso_epoch, mk_human_kb), check-disk.sh and session-start.sh
# (mk_disk_free_kb, mk_temp_stale_list, mk_human_kb) and the sweep skill.
# Design: the 0.5.0 scratch and disk hygiene spec ("Terms", features 1, 3b, 4).
#
# Every function returns 0 on success and prints nothing on failure. Scalar
# results (epochs, KB, "19.0 GB") carry no trailing newline; list results
# ("<kb>\t<abs path>" lines, largest first) end each line with one.
#
# --- THE TEMP TREE (measured live, macOS, Claude Code 2.1.302, 2026-10-18) ---
# - `CLAUDE_CODE_TMPDIR` was unset in both the controller's and this session;
#   `TMPDIR` was /var/folders/.../T/, yet the per-session dirs were NOT under
#   $TMPDIR: they live in /private/tmp/claude-<uid>/ (/tmp is a symlink to
#   private/tmp). So $TMPDIR is not a root candidate; $CLAUDE_CODE_TMPDIR is
#   kept as one per the spec (not observed set, so its honouring is unmeasured).
# - Layout: <root>/<slug>/<session-uuid>/{scratchpad,tasks,images,...}, plus
#   loose non-UUID entries directly under <slug>/ (observed: f64b-B, f64b-D,
#   f65a-A, f65a-C, xc-1, xc-1m, xfix). Root-level files (bootid, *.log, ...)
#   sit in <root>/ itself and are out of scope.
# - <slug> = the session's ~/.claude/projects/<slug>/ name, i.e. the launch
#   dir with every non-alphanumeric char -> "-" (observed:
#   /Users/x/Documents/GitHub/memokit-050 -> -Users-x-Documents-GitHub-memokit-050,
#   a worktree -> ...-<Project>--claude-worktrees-agent-<id>, a launch inside
#   a scratchpad -> -private-tmp-claude-501--Users-x-<uuid>-scratchpad-mk-demo).
#   It is taken from basename(dirname(transcript_path)), never from cwd (for
#   a subagent's own transcript, .../<slug>/<session-uuid>/subagents/
#   agent-<id>.jsonl, from the dir above <session-uuid>):
#   measured in this very session, a subagent whose cwd was a git worktree
#   (.../memokit-050) still had its temp dir under the PARENT session's slug
#   (-Users-x) and session uuid, matching its transcript dir. Subagents share
#   the parent session's dir (their transcripts sit in
#   <projects>/<slug>/<session>/subagents/agent-<id>.jsonl).
# - Birth time: BSD `stat -f %B` works on APFS (e.g. B=1792286705 for a live
#   session dir). Old session dirs have mtime refreshed to ~00:00 by a system
#   cleaner (measured: B=1791470085 [11 Oct] but m=1792270807 [18 Oct 00:00]),
#   which is why staleness uses transcript mtime or birth time, never dir mtime.
#   `touch -t` with a FUTURE time leaves the birth time alone; with a PAST time
#   APFS moves the birth time back too. A dir's ctime changes whenever a child
#   is created, so on a filesystem without birth times (ctime fallback) a
#   pre-existing dir that gets a new child looks new to mk_temp_footprint.
# - Payload fields: SubagentStop carries `agent_id` and `agent_transcript_path`
#   (measured, see check-subagent-background.sh); Stop carries `session_id` and
#   `transcript_path` (used in production by check-context-budget.sh). This lib
#   reads only `transcript_path` and `session_id`. `tool_use_id` on
#   Pre/PostToolUse (needed by check-disk.sh, not here) could NOT be dumped
#   live from this session: a headless probe run was refused by the permission
#   system, so the consumer must confirm it with MEMOKIT_HOOK_DEBUG=1.
#
# --- SAFETY (mk_temp_rm_safe decides which rm -rf targets skip approval) -----
# CONTRACT: mk_temp_rm_safe judges the filesystem as it is AT CHECK TIME, and
# nothing more. It is safe only when the caller guarantees that the whole Bash
# command is one simple `rm` invocation, so no other segment can create,
# remove or rename a path between this check and rm's execution (e.g.
# `rm -rf sp/d && ln -s ~ sp/d && rm -rf sp/d/x` passes every per-target check
# here, then follows the new link). careful.sh enforces that contract.
# Even then a background job started by an EARLIER Bash call can swap a dir
# for a symlink between this check and rm's execution, which no check-time
# test can see. So rule (a) is narrowed to DIRECT children of the current
# scratchpad: `$sp/<name>`, no intermediate component, no trailing "/". The
# only path rm then resolves is $sp itself (checked real, and owned by the
# harness); a <name> that is a symlink is unlinked, not followed.
#
# The executing shell may be zsh (Claude Code runs the user's $SHELL, with the
# user's setopts, e.g. EXTENDED_GLOB), so characters are judged against zsh
# syntax under any option: `^` (negation), `#`, `~`, `<a-b>`, `( )`, `**/`,
# `=` (EQUALS turns a word "=cmd" into the path of cmd, MAGIC_EQUAL_SUBST
# turns "x==cmd" into "x=/path/of/cmd") and `!` (history expansion in an
# interactive shell) must stay excluded; the lexical whitelist drops `= ! ^`.
# `@ +` need "(" (KSH_GLOB), "," needs "{", ":" modifiers need "$", "(" or
# "!", and "%" is no word expansion, so they stay inert. `^` and `[` are rejected in names; `*` and `?` are allowed in a
# rule (a) <name> only (they expand within $sp alone), but never as `**`
# (recursive under bash globstar / zsh GLOB_STAR_SHORT; zsh `***` follows
# symlinks).
#
# Within it, fail closed. On top of spec 3b:
# - a character whitelist (braces, quotes, spaces, ;|&<>() and backslashes
#   are rejected as well as $ ` ~ # = ! ^), no "." components, no relative
#   targets;
# - below scratchpad/: exactly one component, without `[`, `^` or `**`, not a
#   dot-name with a glob (`.*`, `.?*`: "." / ".." under some shells/options),
#   and no trailing "/" (rm -rf link/ would delete the link's TARGET's
#   contents);
#   deeper paths take the normal approval path;
# - a whole-entry target (rule b) must not have a trailing "/" at all, and
#   carries no glob (`* ? [ ^`);
# - identity, not spelling: the scratchpad prefix must match byte-for-byte; a
#   whole-entry target must be a stored entry name (glob listing), must not be
#   -ef the current session dir, and an upper/mixed-case session UUID is never
#   a "loose entry" (on case-insensitive APFS it opens the live lower-case
#   dir).
# Slug and session id are sanitised to [A-Za-z0-9-] (each other char -> "-",
# the slug rule itself) before they become paths.
#
# Ownership: the temp root, <root>/<slug>, and (for rm_safe) the session dir
# and its scratchpad must be real dirs owned by the current user (`-O`) and
# not group- or world-writable, else mk_temp_init fails and mk_temp_rm_safe
# refuses (on a shared /tmp another user could pre-create the tree).
#
# Test-only seams: MEMOKIT_TEMP_ROOT (first temp-root candidate) and
# MEMOKIT_DF_KB (mk_disk_free_kb prints it when it is a non-negative integer).
# Never set either in a real session.
#
# MK_TEMP_* globals are the public contract set by mk_temp_init; consumers read
# them, so shellcheck cannot see the use from this file alone.
# shellcheck disable=SC2034
MK_TEMP_UID=""; MK_TEMP_ROOT_DIR=""; MK_TEMP_ROOT_LOGICAL=""; MK_TEMP_SLUG=""
MK_TEMP_PROJECT_DIR=""; MK_TEMP_SESSION_ID=""; MK_TEMP_SESSION_DIR=""
MK_TEMP_TRANSCRIPT_DIR=""

# BSD vs GNU stat, detected once at source time.
if stat -f %B / >/dev/null 2>&1; then _MK_TEMP_STAT=bsd; else _MK_TEMP_STAT=gnu; fi

# _mk_temp_dir_ok DIR -- 0 when DIR is a directory owned by the current user
# and neither group- nor world-writable. An unreadable mode counts as unsafe.
# Judged on DIR itself, so pass a physical path (a symlink is rejected where
# the caller needs a real dir; the root is resolved by cd -P beforehand).
_mk_temp_dir_ok() {
  local d="${1:-}" m g o
  [ -n "$d" ] && [ -d "$d" ] && [ -O "$d" ] || return 1
  if [ "$_MK_TEMP_STAT" = bsd ]; then
    m="$(stat -f '%Lp' -- "$d" 2>/dev/null)" || return 1
  else
    m="$(stat -c '%a' -- "$d" 2>/dev/null)" || return 1
  fi
  case "$m" in ''|*[!0-7]*) return 1 ;; esac
  [ "${#m}" -ge 2 ] || return 1
  g="${m%?}"; g="${g: -1}"; o="${m: -1}"
  case "$g$o" in *[2367]*) return 1 ;; esac
  return 0
}

_mk_temp_uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# _mk_temp_norm PATH -- collapse repeated "/" and strip trailing "/".
_mk_temp_norm() {
  local t="$1" ss='//' s='/'
  while :; do case "$t" in *//*) t="${t//$ss/$s}" ;; *) break ;; esac; done
  while [ "${#t}" -gt 1 ] && [ "${t%/}" != "$t" ]; do t="${t%/}"; done
  printf '%s' "$t"
}

# _mk_temp_san STR -- every char outside [A-Za-z0-9-] becomes "-".
_mk_temp_san() { printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9-' '-'; }

mk_temp_init() {
  local p="${1:-}" vals tp sid tdir par slug uid cand root
  MK_TEMP_UID=""; MK_TEMP_ROOT_DIR=""; MK_TEMP_ROOT_LOGICAL=""; MK_TEMP_SLUG=""
  MK_TEMP_PROJECT_DIR=""; MK_TEMP_SESSION_ID=""; MK_TEMP_SESSION_DIR=""
  MK_TEMP_TRANSCRIPT_DIR=""
  [ -n "$p" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  vals="$(printf '%s' "$p" | jq -r '(.transcript_path // "" | tostring), (.session_id // "" | tostring)' 2>/dev/null)" || return 1
  tp="${vals%%
*}"
  sid="${vals#*
}"
  case "$tp" in /*/*) ;; *) return 1 ;; esac
  [ -n "$sid" ] && [ "$sid" != "$vals" ] || return 1
  case "$sid" in *"
"*) return 1 ;; esac
  tdir="${tp%/*}"
  # A subagent's own transcript (<projects>/<slug>/<session>/subagents/
  # agent-<id>.jsonl) belongs to the parent session: its slug is two levels up
  # and the transcript dir is the <slug> dir, as for the main transcript.
  par="${tdir%/*}"
  if [ "${tdir##*/}" = subagents ] && [[ ${par##*/} =~ $_mk_temp_uuid_re ]]; then
    tdir="${par%/*}"
    case "$tdir" in /*/*) ;; *) return 1 ;; esac
  fi
  slug="$(_mk_temp_san "${tdir##*/}")"
  sid="$(_mk_temp_san "$sid")"
  [ -n "$slug" ] && [ -n "$sid" ] || return 1
  uid="$(id -u 2>/dev/null)"
  case "$uid" in ''|*[!0-9]*) return 1 ;; esac
  for cand in "${MEMOKIT_TEMP_ROOT:-}" "${CLAUDE_CODE_TMPDIR:+$CLAUDE_CODE_TMPDIR/claude-$uid}" \
              "/private/tmp/claude-$uid" "/tmp/claude-$uid"; do
    [ -n "$cand" ] || continue
    root="$(CDPATH='' cd -P -- "$cand" 2>/dev/null && pwd -P)" || continue
    if [ -z "$root" ] || [ "$root" = "/" ]; then continue; fi
    _mk_temp_dir_ok "$root" || continue
    if [ ! -d "$root/$slug" ] || [ -L "$root/$slug" ]; then continue; fi
    _mk_temp_dir_ok "$root/$slug" || continue
    MK_TEMP_UID="$uid"
    MK_TEMP_ROOT_DIR="$root"
    MK_TEMP_ROOT_LOGICAL="$(_mk_temp_norm "$cand")"
    MK_TEMP_SLUG="$slug"
    MK_TEMP_PROJECT_DIR="$root/$slug"
    MK_TEMP_SESSION_ID="$sid"
    MK_TEMP_SESSION_DIR="$root/$slug/$sid"
    MK_TEMP_TRANSCRIPT_DIR="$tdir"
    return 0
  done
  return 1
}

# _mk_temp_pick B C -- B when it is a positive integer, else C (if integer).
_mk_temp_pick() {
  case "$1" in ''|*[!0-9]*) ;; *) [ "$1" -gt 0 ] && { printf '%s' "$1"; return 0; } ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$2"
}

mk_temp_birth() {
  local out
  [ -e "${1:-}" ] || [ -L "${1:-}" ] || return 1
  if [ "$_MK_TEMP_STAT" = bsd ]; then
    out="$(stat -f '%B %c' -- "$1" 2>/dev/null)" || return 1
  else
    out="$(stat -c '%W %Z' -- "$1" 2>/dev/null)" || return 1
  fi
  _mk_temp_pick "${out%% *}" "${out#* }"
}

mk_temp_mtime() {
  local out
  [ -e "${1:-}" ] || [ -L "${1:-}" ] || return 1
  if [ "$_MK_TEMP_STAT" = bsd ]; then
    out="$(stat -f '%m' -- "$1" 2>/dev/null)" || return 1
  else
    out="$(stat -c '%Y' -- "$1" 2>/dev/null)" || return 1
  fi
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

mk_temp_iso_epoch() {
  local out
  [ -n "${1:-}" ] || return 1
  out="$(jq -rn --arg t "$1" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | floor' 2>/dev/null)" || return 1
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# _mk_temp_stale_at NAME NOW -- mk_temp_is_stale against a given clock, so a
# caller walking many entries reads the clock once.
_mk_temp_stale_at() {
  local name="$1" now="$2" p h t
  [ -n "$MK_TEMP_PROJECT_DIR" ] && [ -n "$MK_TEMP_SESSION_ID" ] || return 1
  case "$name" in ''|.|..|*/*) return 1 ;; esac
  [ "$name" = "$MK_TEMP_SESSION_ID" ] && return 1
  h="${MK_SCRATCH_STALE_HOURS:-}"
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  p="$MK_TEMP_PROJECT_DIR/$name"
  [ -e "$p" ] || [ -L "$p" ] || return 1
  # Identity, not spelling: on a case-insensitive filesystem (APFS default)
  # "ABCDEF01-..." opens the current session's "abcdef01-..." dir.
  [ "$p" -ef "$MK_TEMP_SESSION_DIR" ] && return 1
  _mk_temp_uuid_variant "$name" && return 1
  if [[ $name =~ $_mk_temp_uuid_re ]] && [ -f "$MK_TEMP_TRANSCRIPT_DIR/$name.jsonl" ]; then
    t="$(mk_temp_mtime "$MK_TEMP_TRANSCRIPT_DIR/$name.jsonl")" || return 1
  else
    t="$(mk_temp_birth "$p")" || return 1
  fi
  [ $((now - t)) -gt $((10#$h * 3600)) ]
}

# _mk_temp_uuid_variant NAME -- 0 when NAME is a session UUID in anything but
# the canonical lower case Claude Code uses. Such a name is never treated as a
# loose entry (birth time), since it may open a live session's dir.
_mk_temp_uuid_variant() {
  local lc
  lc="$(printf '%s' "$1" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
  [ "$lc" != "$1" ] && [[ $lc =~ $_mk_temp_uuid_re ]]
}

# _mk_temp_listed NAME -- 0 when NAME is byte-for-byte the stored name of an
# entry of the project temp dir. Globbing returns the on-disk spelling, so a
# case variant that the filesystem would still resolve does not match.
_mk_temp_listed() {
  local e
  for e in "$MK_TEMP_PROJECT_DIR"/* "$MK_TEMP_PROJECT_DIR"/.[!.]* "$MK_TEMP_PROJECT_DIR"/..?*; do
    [ "${e##*/}" = "$1" ] && { [ -e "$e" ] || [ -L "$e" ]; } && return 0
  done
  return 1
}

mk_temp_is_stale() { _mk_temp_listed "${1:-}" && _mk_temp_stale_at "${1:-}" "$(date +%s)"; }

mk_temp_stale_list() {
  local budget="${1:-3}" now start e name kb out="" truncated=0 tab nl
  tab="$(printf '\t')"; nl='
'
  case "$budget" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$MK_TEMP_PROJECT_DIR" ] && [ -d "$MK_TEMP_PROJECT_DIR" ] || return 1
  now="$(date +%s)"; start=$SECONDS
  for e in "$MK_TEMP_PROJECT_DIR"/* "$MK_TEMP_PROJECT_DIR"/.[!.]* "$MK_TEMP_PROJECT_DIR"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    # The budget covers the staleness checks too (one stat each), so a huge
    # project temp dir cannot outlast the hook timeout; TRUNCATED then means
    # "at least this much".
    if [ $((SECONDS - start)) -ge "$budget" ]; then truncated=1; break; fi
    name="${e##*/}"
    case "$name" in *"$nl"*|*"$tab"*) continue ;; esac
    _mk_temp_stale_at "$name" "$now" || continue
    # An empty skeleton (only dirs left) is not worth offering. du alone cannot
    # tell: on ext4 an empty dir is 4 KB, on APFS 0.
    [ -n "$(find "$e" ! -type d -print -quit 2>/dev/null)" ] || continue
    kb="$(du -sk "$e" 2>/dev/null)"; kb="${kb%%"$tab"*}"
    case "$kb" in ''|*[!0-9]*) continue ;; esac
    [ "$kb" -gt 0 ] || continue
    out="$out$kb$tab$e$nl"
  done
  [ -n "$out" ] && printf '%s' "$out" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2
  [ "$truncated" -eq 1 ] && printf 'TRUNCATED\n'
  return 0
}

# Footprint candidates: reads "<birth> <ctime> <path>" lines (one batched stat
# over the walk), prints the paths born >= START that are not at/below a dir
# holding .memokit-keep and have no counted ancestor.
# shellcheck disable=SC2016  # an awk program: its $-fields are awk's, not ours
_MK_TEMP_FP_AWK='
function under_keep(p,  a) {
  a = p
  while (1) {
    if (a in keep) return 1
    if (length(a) <= length(sp)) return 0
    sub(/\/[^\/]*$/, "", a)
  }
}
BEGIN { sp = ENVIRON["MK_FP_SP"]; start = ENVIRON["MK_FP_START"] + 0; n = 0 }
{
  i = index($0, " "); b = substr($0, 1, i - 1); rest = substr($0, i + 1)
  j = index(rest, " "); c = substr(rest, 1, j - 1); p = substr(rest, j + 1)
  if (b !~ /^[0-9]+$/ || b + 0 <= 0) b = c
  if (b !~ /^[0-9]+$/) next
  if (substr(p, 1, length(sp) + 1) != sp "/") next
  path[n] = p; birth[n] = b + 0; n++
  if (p ~ /\/\.memokit-keep$/) { d = p; sub(/\/[^\/]*$/, "", d); keep[d] = 1 }
}
END {
  for (k = 0; k < n; k++)
    if (birth[k] >= start && !under_keep(path[k])) cand[path[k]] = 1
  for (p in cand) {
    a = p; ok = 1
    while (1) {
      sub(/\/[^\/]*$/, "", a)
      if (length(a) <= length(sp)) break
      if (a in cand) { ok = 0; break }
    }
    if (ok) print p
  }
}'

# mk_temp_has_birth -- true when the filesystem under the scratchpad reports a
# real birth time. Without it (ctime fallback) a pre-existing dir that gains a
# child looks new, so a consumer must not trust "born after start" as ownership.
# Test seam: MEMOKIT_NO_BIRTH=1 forces false.
mk_temp_has_birth() {
  local t="${1:-${MK_TEMP_SESSION_DIR:-}}" out
  [ "${MEMOKIT_NO_BIRTH:-0}" = "1" ] && return 1
  [ -e "$t" ] || return 1
  if [ "$_MK_TEMP_STAT" = bsd ]; then
    out="$(stat -f '%B' -- "$t" 2>/dev/null)" || return 1
  else
    out="$(stat -c '%W' -- "$t" 2>/dev/null)" || return 1
  fi
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  [ "$out" -gt 0 ]
}

# Newline-safety: the stat/awk walk is line based, so an entry whose path holds
# a newline, tab or CR would forge records (a name "orch<NL>x" yields a line
# that reads as the unrelated dir "orch"). Those entries are pruned from the
# walk and handled apart: each topmost one that is new (and not under a
# .memokit-keep or a counted entry) is reported as "<kb>\t<path>" with every
# control char replaced by "?", sized by du on the real entry. Callers treat a
# path with "?" as unusual (counted, never printed or deleted by name).
mk_temp_footprint() {
  local start="${1:-}" sp list p tab nl cr w red a b out kb extra skip c
  local -a counted
  tab="$(printf '\t')"; nl=$'\n'; cr=$'\r'
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$MK_TEMP_SESSION_DIR" ] || return 1
  sp="$MK_TEMP_SESSION_DIR/scratchpad"
  [ -d "$sp" ] && [ ! -L "$sp" ] || return 0
  if [ "$_MK_TEMP_STAT" = bsd ]; then
    list="$(find "$sp" -mindepth 1 -maxdepth 3 \( -path "*$nl*" -o -path "*$tab*" -o -path "*$cr*" \) -prune -o -exec stat -f '%B %c %N' {} + 2>/dev/null)"
  else
    list="$(find "$sp" -mindepth 1 -maxdepth 3 \( -path "*$nl*" -o -path "*$tab*" -o -path "*$cr*" \) -prune -o -exec stat -c '%W %Z %n' {} + 2>/dev/null)"
  fi
  counted=()
  if [ -n "$list" ]; then
    list="$(printf '%s\n' "$list" | MK_FP_SP="$sp" MK_FP_START="$start" LC_ALL=C awk "$_MK_TEMP_FP_AWK")"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # A depth-3 dir's own marker sits at depth 4, beyond the walk.
      [ -e "$p/.memokit-keep" ] && continue
      counted[${#counted[@]}]="$p"
    done <<EOF
$list
EOF
  fi
  out=""
  if [ "${#counted[@]}" -gt 0 ]; then
    out="$(printf '%s\0' "${counted[@]}" | xargs -0 du -sk 2>/dev/null)"
  fi
  extra=""
  while IFS= read -r -d '' w; do
    [ -e "$w" ] || [ -L "$w" ] || continue
    b="$(mk_temp_birth "$w")" || continue
    [ "$b" -ge "$start" ] || continue
    [ -e "$w/.memokit-keep" ] && continue
    skip=0; a="${w%/*}"
    while [ "${#a}" -gt "${#sp}" ]; do
      [ -e "$a/.memokit-keep" ] && { skip=1; break; }
      for c in ${counted[@]+"${counted[@]}"}; do [ "$c" = "$a" ] && { skip=1; break; }; done
      [ "$skip" -eq 1 ] && break
      a="${a%/*}"
    done
    [ "$skip" -eq 0 ] || continue
    kb="$(du -sk -- "$w" 2>/dev/null | head -n 1)"; kb="${kb%%"$tab"*}"
    case "$kb" in ''|*[!0-9]*) continue ;; esac
    red="${w//$nl/?}"; red="${red//$tab/?}"; red="${red//$cr/?}"
    extra="$extra$kb$tab$red
"
  done < <(find "$sp" -mindepth 1 -maxdepth 3 \( -path "*$nl*" -o -path "*$tab*" -o -path "*$cr*" \) -prune -print0 2>/dev/null)
  out="$out${out:+
}${extra%
}"
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | LC_ALL=C sort -t "$tab" -k1,1nr -k2,2
  return 0
}

# _mk_temp_rm_norm TARGET -- the lexical half of mk_temp_rm_safe: rejects
# (returns 1) on a char outside the whitelist, a relative path or a "." / ".."
# component; otherwise prints the target with "//" collapsed, trailing "/"
# stripped and the /tmp and logical-root spellings mapped to the physical root.
_mk_temp_rm_norm() {
  local t="${1:-}"
  case "$t" in /*) ;; *) return 1 ;; esac
  # Whitelist, spelled out (ranges are locale-dependent in bash patterns).
  case "$t" in
    *[!]ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/@+,:%*?[-]*) return 1 ;;
  esac
  t="$(_mk_temp_norm "$t")"
  case "$t/" in */./*|*/../*) return 1 ;; esac
  case "$MK_TEMP_ROOT_DIR/" in
    /private/tmp/*) case "$t" in /tmp|/tmp/*) t="/private$t" ;; esac ;;
  esac
  if [ -n "$MK_TEMP_ROOT_LOGICAL" ] && [ "$MK_TEMP_ROOT_LOGICAL" != "$MK_TEMP_ROOT_DIR" ]; then
    case "$t" in
      "$MK_TEMP_ROOT_LOGICAL"|"$MK_TEMP_ROOT_LOGICAL"/*) t="$MK_TEMP_ROOT_DIR${t#"$MK_TEMP_ROOT_LOGICAL"}" ;;
    esac
  fi
  printf '%s' "$t"
}

mk_temp_rm_safe() {
  local t="${1:-}" slash=0 sp rel name
  [ -n "$MK_TEMP_ROOT_DIR" ] && [ -n "$MK_TEMP_PROJECT_DIR" ] && [ -n "$MK_TEMP_SESSION_ID" ] || return 1
  case "$t" in */) slash=1 ;; esac
  t="$(_mk_temp_rm_norm "$t")" || return 1
  [ -L "$MK_TEMP_PROJECT_DIR" ] && return 1
  # Re-judged at check time: root and project dir still owned and private.
  _mk_temp_dir_ok "$MK_TEMP_ROOT_DIR" && _mk_temp_dir_ok "$MK_TEMP_PROJECT_DIR" || return 1
  sp="$MK_TEMP_SESSION_DIR/scratchpad"
  case "$t" in
    "$sp"/*)
      # (a) a direct child of the current session's scratchpad/
      # The prefix matched byte-for-byte (a case variant of root, slug,
      # session or "scratchpad" falls through to a reject), and its dirs must
      # be the real, non-symlinked ones.
      if [ -L "$MK_TEMP_SESSION_DIR" ] || [ -L "$sp" ] || [ ! -d "$sp" ]; then return 1; fi
      _mk_temp_dir_ok "$MK_TEMP_SESSION_DIR" && _mk_temp_dir_ok "$sp" || return 1
      # A direct child only (see SAFETY): any intermediate component could be
      # swapped for a symlink by a background job after this check, and a
      # trailing "/" makes rm follow a link. `*` and `?` may stay in the
      # name; `[`, zsh's `^` negation and `**` (recursive under bash
      # globstar or zsh GLOB_STAR_SHORT, and `***` follows links) may not.
      [ "$slash" -eq 0 ] || return 1
      rel="${t#"$sp"/}"
      case "$rel" in ''|*/*|*'['*|*'^'*|*'**'*) return 1 ;; esac
      # Belt and braces: a dot-name with a glob (.* .?* ..*) could match "."
      # or ".." in a shell or option set that expands them.
      case "$rel" in .*[*?]*) return 1 ;; esac
      if [ "$t" -ef "$sp" ] || [ "$t" -ef "$MK_TEMP_SESSION_DIR" ] ||
         [ "$t" -ef "$MK_TEMP_PROJECT_DIR" ] || [ "$t" -ef "$MK_TEMP_ROOT_DIR" ]; then
        return 1
      fi
      return 0 ;;
    "$MK_TEMP_PROJECT_DIR"/*)
      # (b) exactly a stale sibling session dir or loose entry, no glob
      name="${t#"$MK_TEMP_PROJECT_DIR"/}"
      case "$name" in ''|*/*|*[*?[]*|*'^'*) return 1 ;; esac
      [ "$name" = "$MK_TEMP_SESSION_ID" ] && return 1
      [ "$t" -ef "$MK_TEMP_SESSION_DIR" ] && return 1
      _mk_temp_uuid_variant "$name" && return 1
      # Whole-entry removal never needs a trailing "/", and with one rm
      # would follow whatever symlink sits there by then.
      [ "$slash" -eq 1 ] && return 1
      # mk_temp_is_stale also requires NAME to be a stored entry name.
      mk_temp_is_stale "$name" ;;
    *) return 1 ;;
  esac
}

mk_disk_free_kb() {
  local v d min=""
  v="${MEMOKIT_DF_KB:-}"
  case "$v" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$((10#$v))"; return 0 ;;
  esac
  for d in "${MK_ROOT:-}" "${MK_TEMP_ROOT_DIR:-}"; do
    if [ -z "$d" ] || [ ! -d "$d" ]; then continue; fi
    # Column 4 (Available). Located as the field before the first "NN%" one,
    # since a filesystem name may contain spaces ("map auto_home" on macOS).
    v="$(df -Pk "$d" 2>/dev/null | LC_ALL=C awk 'NR == 2 { for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { print $(i - 1); exit } }')"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$min" ] || [ "$v" -lt "$min" ]; then min="$v"; fi
  done
  [ -n "$min" ] || return 1
  printf '%s' "$min"
}

mk_human_kb() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  LC_ALL=C awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k / 1048576; else printf "%d MB", int(k / 1024) }'
}
