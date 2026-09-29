#!/usr/bin/env bash
# PreToolUse hook: block the orchestrator from writing production code.
# Subagents must do the coding (see WORKING-MODEL.md §1).
#
# Covers two tool shapes, wired via two matcher entries in settings.json:
#   - Edit/Write/MultiEdit/NotebookEdit: tool_input.file_path (or
#     .notebook_path) names the target directly.
#   - Bash: tool_input.command is free-form shell text. There is no
#     file_path field to read -- the command is scanned for WRITE
#     CONSTRUCTS (redirects, and a fixed list of file-mutating commands)
#     whose target arguments are then classified the exact same way as an
#     Edit/Write file_path. A command that merely MENTIONS one of the
#     guarded dirs (memokit.json guardedDirs) without one of those
#     constructs (grep, ls, git diff, dotnet test, ...) is not touched --
#     see the Bash-branch comments below for why blocking those would make
#     the guard unusable.
set -u
# source-path=SCRIPTDIR makes the source= hint below resolve relative to
# THIS file's own directory regardless of the directory shellcheck is
# invoked from (its default is relative to shellcheck's invocation CWD),
# so `shellcheck -x` follows it whether run from the repo root or from
# hooks/ itself -- dirname "$0" already resolves correctly at runtime
# either way.
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
# Hard kill-switch for emergencies: MEMOKIT_GUARD_OFF=1 disables the block.
# Checked before anything else, including the empty-payload branch right
# below, so the kill switch is a true unconditional override.
mk_guard_off && exit 0
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "guard-edit" "$PAYLOAD"

# Fail-closed, part 1: without jq the payload cannot be classified at all (no
# way to read tool_input.file_path/command or agent_id), so a write under one
# of the guarded dirs (memokit.json guardedDirs) could go unclassified --
# deny instead of silently allowing. Mentioning jq explicitly so the operator
# can diagnose it from the reason text alone.
if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg CONFIG_NO_JQ_STATIC)"
    exit 0
  fi
  jq -n --arg r "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# Empty stdin used to be treated as "nothing to classify, stay silent" on the
# theory that a smoke-test script sent it. That premise was checked and is
# false (legacy projects): a knowledge-health-style smoke fixture for this
# hook always writes a real, non-empty JSON payload to stdin, and its
# fallback fixture for hooks without a dedicated case is `{}`, not empty. So
# this branch protected nothing and only ever fired when stdin genuinely
# could not be read (e.g. a broken pipe, or `cat` missing from PATH) --
# confirmed live: with `cat` removed from PATH, PAYLOAD="" and the old code
# allowed a guarded-dir write straight through. Empty stdin now denies. The
# only sanctioned way to get the old "stay silent" behaviour is the explicit
# MEMOKIT_KH_SMOKE=1 escape hatch a knowledge-health-style script itself sets
# when it intentionally wants to probe a hook's bare-invocation path
# (currently unused by any fixture, kept as a documented, explicit-opt-in
# escape rather than an implicit one).
# This message is fixed text with nothing interpolated, so a hand-escaped
# static JSON literal is safe here -- deny() itself is not defined yet at
# this point in the script, and even once it is, deny() shells out to jq,
# which is exactly the kind of dependency an "stdin could not be read" path
# should not add before this file's stated "the layer must fail closed"
# resolves the ambiguity.
# Note: mk_active above already ran on this same (possibly empty) PAYLOAD, so
# with an empty payload the root comes from CLAUDE_PROJECT_DIR only --
# mk_resolve_root cannot fall back to a payload cwd it was never given.
if [ -z "$PAYLOAD" ]; then
  if [ "${MEMOKIT_KH_SMOKE:-0}" = "1" ]; then
    exit 0
  fi
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg GE_EMPTY_STDIN_STATIC)"
  exit 0
fi

deny() {
  # $1: localized (mk_msg-rendered) reason shown to the operator. This can include an
  # attacker-controlled path or Bash command (see the Bash-branch deny
  # below), so the value MUST be JSON-escaped rather than interpolated with
  # plain printf %s -- printf did no escaping at all, so a file_path
  # containing a literal double quote (e.g. `src/"pwn.cs`) produced invalid
  # JSON in the reason string. Claude Code silently ignores unparseable hook
  # output, so the deny was lost and the write proceeded. jq -n --arg
  # performs correct JSON string escaping (quotes, backslashes, newlines,
  # control chars) for us. This function requires jq. Every call site is
  # reached only after the guard preamble's jq-availability check
  # (mk_load_config, above deny()'s own definition) has already passed --
  # that check's own jq-missing path cannot call deny() (deny() shells out
  # to jq, which is exactly what would be missing), so it emits a static
  # hand-escaped JSON literal directly instead (see the preamble block
  # above, the `mk_msg CONFIG_NO_JQ_STATIC` branch).
  #
  # jq itself can still fail on THIS invocation (corrupt install, OOM, a
  # jq that segfaults on -n, ...) even though the earlier availability check
  # passed. `jq -n ... ; exit 0` unconditionally would then exit 0 with no
  # output -- Claude Code reads that as permission granted, silently losing
  # the deny. So capture the output, check the exit status, and fall back to
  # a static hand-escaped literal (no interpolation of $1 -- jq just failed,
  # so it cannot be trusted to escape it either) when jq did not succeed.
  DENY_JSON="$(jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null)"
  # shellcheck disable=SC2181  # $? here is jq's, from the command
  # substitution just above -- checking it directly would require
  # restructuring this into `if DENY_JSON=$(jq ...); then`, losing the
  # ability to also check `[ -n "$DENY_JSON" ]` in the same condition.
  if [ $? -eq 0 ] && [ -n "$DENY_JSON" ]; then
    printf '%s\n' "$DENY_JSON"
  else
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg GE_JQ_FAILED_STATIC)"
  fi
  exit 0
}

# True when directory $1 is the same inode as one of the guarded dirs under
# root $2 (one of GUARD_ROOTS, see load_guard_roots below).
dir_is_guarded() {
  local gd
  while IFS= read -r gd; do
    [ -z "$gd" ] && continue
    [ "$1" -ef "$2/$gd" ] && return 0
  done <<EOF
$MK_GUARDED_DIRS
EOF
  return 1
}

# True when directory $1 is the same inode as a guarded dir under ANY root.
dir_is_guarded_in_any_root() {
  local r
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    dir_is_guarded "$1" "$r" && return 0
  done <<EOF
$GUARD_ROOTS
EOF
  return 1
}

# Fail-closed, part 2: non-empty stdin that is not valid JSON is the same
# situation as jq missing -- cannot classify, so cannot allow.
if ! printf '%s' "$PAYLOAD" | jq -e '.' >/dev/null 2>&1; then
  deny "$(mk_msg GE_INVALID_JSON)"
fi

# Anchor the guard to THIS project's guarded dirs (memokit.json guardedDirs),
# not to any path anywhere on the filesystem that happens to contain one of
# their names (e.g. another project's node_modules/foo/src/index.js). ROOT
# comes from CLAUDE_PROJECT_DIR / the payload's cwd via mk_resolve_root (see
# lib/common.sh), not from this script's own location -- the script lives in
# the plugin cache, so dirname "$0" would not point at the project at all.
ROOT="$MK_ROOT"

# Sanity check on the derivation itself: mk_active already required
# $MK_ROOT/.claude/memokit.json to exist before this hook did anything, but a
# guard this security-sensitive should not trust a value computed several
# lines away without re-verifying it right where it is used for path
# classification below. Fail closed instead of trusting ROOT.
if [ ! -f "$ROOT/.claude/memokit.json" ]; then
  deny "$(mk_msg GE_ROOT_UNKNOWN "$ROOT")"
fi

# --- guard roots: ROOT plus the same place in every git worktree ----------
# A git worktree of this repository (Claude Code's EnterWorktree creates
# <root>/.claude/worktrees/<name>; users also `git worktree add ../repo-wt`)
# is a second checkout of the very same guarded dirs, but CLAUDE_PROJECT_DIR
# -- and so ROOT -- stays at the main checkout while the session's cwd moves
# into the worktree. Matching guarded dirs only as "$ROOT/<dir>" let the main
# session write <root>/.claude/worktrees/w/src/a.cs freely. So every
# root-relative check in classify_path (the lexical match, its case fold, and
# the `-ef` walk) runs against each GUARD ROOT, with ROOT's own guardedDirs:
#   - ROOT itself (the main checkout, covered exactly as before), then
#   - for every `worktree <path>` line of `git worktree list --porcelain`,
#     <path> plus ROOT's own offset inside its checkout. That offset is empty
#     unless memokit.json sits in a repo SUBDIRECTORY, where it keeps a
#     worktree's <wt>/app/src guarded without newly guarding <repo>/src.
# If git is missing or the list fails, ROOT stays the only root: exactly the
# pre-worktree coverage, never less. Loaded lazily from classify_path, so it
# runs at most once per hook run and only once a write candidate exists.
#
# git prints worktree paths physically resolved (e.g. /private/var/... on
# macOS) while ROOT and payload paths are usually logical (/var/...). A lexical
# match between the two spellings would silently miss, so GUARD_ROOTS_LOWER
# holds BOTH the raw and the `pwd -P` spelling of every root, and classify_path
# matches the target's physical spelling as well as its normalized one.
# Known gap: a worktree path containing a newline is cut at that newline by
# the line-based porcelain parse, so that one worktree is not covered (ROOT
# and every other root still are).
load_guard_roots() {
  [ "${GUARD_ROOTS_LOADED:-0}" = "1" ] && return 0
  GUARD_ROOTS_LOADED=1
  GUARD_ROOTS="$ROOT"
  wt_paths=""
  if command -v git >/dev/null 2>&1 && \
     wt_list="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null)"; then
    wt_paths="$(printf '%s\n' "$wt_list" | sed -n 's/^worktree //p')"
  fi
  if [ -n "$wt_paths" ]; then
    # ROOT's offset inside the checkout that contains it (longest match).
    root_phys="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || root_phys=""
    best=""
    while IFS= read -r wt; do
      [ -z "$wt" ] && continue
      wt_phys="$(cd -P "$wt" 2>/dev/null && pwd -P)" || wt_phys="$wt"
      case "$root_phys" in
        "$wt_phys"|"$wt_phys"/*)
          if [ "${#wt_phys}" -gt "${#best}" ]; then best="$wt_phys"; fi
          ;;
      esac
    done <<WTEOF
$wt_paths
WTEOF
    offset=""
    [ -n "$best" ] && offset="${root_phys#"$best"}"
    while IFS= read -r wt; do
      [ -z "$wt" ] && continue
      case "
$GUARD_ROOTS
" in
        *"
$wt$offset
"*) : ;;
        *) GUARD_ROOTS="$GUARD_ROOTS
$wt$offset" ;;
      esac
    done <<WTEOF
$wt_paths
WTEOF
  fi

  # Lowercased spellings (raw and physical) of every root, for the lexical
  # match. Same fail-closed handling as the single ROOT_LOWER this replaces.
  GUARD_ROOTS_LOWER=""
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    r_phys="$(cd -P "$r" 2>/dev/null && pwd -P)" || r_phys=""
    for s in "$r" "$r_phys"; do
      [ -z "$s" ] && continue
      s_lower="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')" || \
        deny "$(mk_msg GE_ROOT_LOWER_FAILED "$s")"
      [ -z "$s_lower" ] && \
        deny "$(mk_msg GE_ROOT_LOWER_EMPTY "$s")"
      case "
$GUARD_ROOTS_LOWER
" in
        *"
$s_lower
"*) : ;;
        *) GUARD_ROOTS_LOWER="$GUARD_ROOTS_LOWER
$s_lower" ;;
      esac
    done
  done <<RTEOF
$GUARD_ROOTS
RTEOF

  # The guarded dirs, lowercased once for every root and every candidate.
  GUARDED_LOWER=""
  while IFS= read -r gd; do
    [ -z "$gd" ] && continue
    gd_lower="$(printf '%s' "$gd" | tr '[:upper:]' '[:lower:]')" || \
      deny "$(mk_msg GE_GUARDED_DIR_LOWER_FAILED "$gd")"
    [ -z "$gd_lower" ] && \
      deny "$(mk_msg GE_GUARDED_DIR_LOWER_EMPTY "$gd")"
    GUARDED_LOWER="$GUARDED_LOWER
$gd_lower"
  done <<GDEOF
$MK_GUARDED_DIRS
GDEOF
}

# True when lowercased path $1 is a guarded dir under lowercased root $2, or
# inside one. Matches both the bare directory (no trailing slash) and
# everything under it.
lexical_guarded_under() {
  local gl
  while IFS= read -r gl; do
    [ -z "$gl" ] && continue
    case "$1" in
      "$2/$gl"|"$2/$gl"/*) return 0 ;;
    esac
  done <<EOF
$GUARDED_LOWER
EOF
  return 1
}

# True when lowercased path $1 is inside a guarded dir under ANY root spelling.
lexical_guarded_in_any_root() {
  local rl
  while IFS= read -r rl; do
    [ -z "$rl" ] && continue
    lexical_guarded_under "$1" "$rl" && return 0
  done <<EOF
$GUARD_ROOTS_LOWER
EOF
  return 1
}

# Sets PHYS_PATH to absolute, normalized path $1 with its deepest EXISTING
# ancestor replaced by that ancestor's `pwd -P` spelling and the not-yet-
# existing remainder appended unchanged (it has no "." / ".." left, since $1
# is already normalized). Sets a global instead of printing, so the deny()
# calls below exit the hook itself, not a command-substitution subshell.
physical_spelling() {
  p="$1"
  rest=""
  steps=0
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do
    steps=$((steps + 1))
    if [ "$steps" -gt 200 ]; then
      deny "$(mk_msg GE_PARENT_DIR_LOOP "$1")"
    fi
    rest="/${p##*/}$rest"
    p="${p%/*}"
    [ -z "$p" ] && p="/"
  done
  p_phys="$(cd -P "$p" 2>/dev/null && pwd -P)" || p_phys=""
  [ -z "$p_phys" ] && \
    deny "$(mk_msg GE_PARENT_PHYS_FAILED "$p")"
  [ "$p_phys" = "/" ] && p_phys=""
  PHYS_PATH="$p_phys$rest"
  [ -z "$PHYS_PATH" ] && PHYS_PATH="/"
  return 0
}

# Lexically normalize an absolute path: collapse "." segments, resolve ".."
# by popping the previous stacked segment, and collapse duplicate slashes.
# Pure bash 3.2 (IFS=/ segment split + a stack) -- no external tools, no
# realpath/readlink -f (not available on this machine). This function itself
# is still NOT symlink resolution: it operates purely on the path text as
# written, so a symlinked directory anywhere in the path is never followed
# by normalize_path alone.
#
# The guard as a WHOLE does not stop at this lexical text match: classify_path
# below also runs an inode-identity check (`-ef`, via dir_is_guarded) that
# walks up from the target path and compares device+inode against each of
# the guarded dirs (memokit.json guardedDirs) under every guard root ("$ROOT"
# and its worktree counterparts, see load_guard_roots). `-ef` asks the
# filesystem directly, so it transparently follows symlinks and reproduces
# whatever case/Unicode folding the OS itself applies.
# Prints the normalized absolute path and returns 0, or prints nothing and
# returns 1 when normalization cannot be completed (".." popping past the
# filesystem root). Callers MUST treat a non-zero return as deny: this guard
# is fail-closed by design, so "can't tell" must never mean "allow".
normalize_path() {
  case "$1" in
    /*) : ;;
    *) return 1 ;;
  esac
  old_ifs="$IFS"
  IFS=/
  # set -f (noglob) while splitting: an unquoted `set -- $1` word-splits on
  # IFS but would ALSO pathname-expand any "*"/"?"/"[" in the path against
  # the current directory if globbing stayed on -- a literal glob character
  # in a filename must not turn into a filesystem lookup here.
  set -f
  # shellcheck disable=SC2086  # unquoted on purpose -- this IS the IFS=/
  # segment split the comment above explains; quoting "$1" would defeat it.
  set -- $1
  set +f
  IFS="$old_ifs"
  stack=""
  for seg in "$@"; do
    case "$seg" in
      ""|".") continue ;;
      "..")
        # Nothing left to pop -- either already at "/" or this ".." would
        # escape the filesystem root. Lexical normalization alone cannot
        # tell which, so fail closed rather than guess.
        if [ -z "$stack" ]; then
          return 1
        fi
        stack="${stack%/*}"
        ;;
      *)
        stack="$stack/$seg"
        ;;
    esac
  done
  [ -z "$stack" ] && stack="/"
  printf '%s' "$stack"
  return 0
}

# classify_path: the single authority for "does this path identify a location
# inside one of the guarded dirs (memokit.json guardedDirs) under $ROOT or
# under the same place in any git worktree of it" (see load_guard_roots).
# Used by BOTH the Edit/Write branch (one call, on tool_input.file_path) and
# the Bash branch (one call per candidate write-target extracted from the
# command text) -- there is exactly one implementation of this logic in the
# file, per the explicit requirement that a weaker second classifier must not
# be written for the Bash path.
#
# $1: a path, absolute or relative. $2: the base directory relative paths are
# resolved against (the repo root for Edit/Write since those tools always
# send an absolute file_path in practice; the Bash tool_input's cwd, or ROOT
# as a fallback, for the Bash branch, since a shell command's relative paths
# are resolved against the shell's working directory, not this script's).
#
# Sets GUARDED=1 if the path is inside a guarded dir, GUARDED=0 otherwise.
# Sets CLASSIFIED_PATH to the normalized absolute path, for use in deny
# messages. Calls deny() (which exits the whole script) on any ambiguity a
# text-only classification cannot resolve -- this guard is fail-closed by
# design, "can't tell" must never fall through as "allow".
classify_path() {
  RAW_PATH="$1"
  BASEDIR="$2"

  case "$RAW_PATH" in
    /*) ABS_PATH="$RAW_PATH" ;;
    *) ABS_PATH="$BASEDIR/$RAW_PATH" ;;
  esac

  # --- trailing "/" / "/." stripping (defeats a `[ -h ]` false-negative) ---
  # `test -h` / `[ -h ]` FOLLOWS the link and stats its TARGET when the path
  # ends in a trailing slash (POSIX-mandated stat-follows-trailing-slash
  # behaviour) -- so `[ -h "$ABS_PATH" ]` is true for a symlink path like
  # "f.cs" but FALSE for "f.cs/", "f.cs//", "f.cs/.", even though all name
  # the exact same symlink. Confirmed live with f.cs a symlink into src/:
  # appending a single trailing "/" made the symlink-resolution loop below
  # get skipped entirely, and writing through it (overwriting a real file in
  # src/, or creating a new one through a dangling link) sailed through.
  # normalize_path() below would strip this exact lexical noise too, but only
  # AFTER the `[ -h ]` test already ran -- this loop exists specifically to
  # run BEFORE that test ever sees the path. Deliberately narrower than full
  # lexical normalization: it must NOT touch a trailing "..", because
  # "link.cs/../X" is a different case whose real parent is the link itself
  # (a plain directory entry), which normalize_path still resolves correctly
  # further down.
  while :; do
    case "$ABS_PATH" in
      /) break ;;
      */)  ABS_PATH="${ABS_PATH%/}";  [ -z "$ABS_PATH" ] && ABS_PATH="/" ;;
      */.) ABS_PATH="${ABS_PATH%/.}"; [ -z "$ABS_PATH" ] && ABS_PATH="/" ;;
      *) break ;;
    esac
  done

  # --- resolve a symlinked FINAL path component -----------------------------
  # The `-ef` ancestor walk further below resolves symlinked DIRECTORIES
  # anywhere in the path, but never looks at the final component itself. If
  # FILE_PATH's last component is itself a symlink pointing at a file inside
  # a guarded dir, every check downstream would classify based on the
  # symlink's own location, not its target. Confirmed live:
  # `ln -s $ROOT/src/<Project>.Web/Program.cs /tmp/sp/f.cs` then writing to
  # /tmp/sp/f.cs silently overwrote the real Program.cs (rc=0, empty stdout =
  # ALLOW); a link to a NONEXISTENT file inside src/ is worse still -- it
  # CREATES a brand new file under src/ through a path that lexically looks
  # like it lives entirely outside the repo.
  #
  # macOS `readlink` DOES support `-f` (verified: `readlink -f /etc/hosts` ->
  # `/private/etc/hosts`, rc=0), but `-f` returns rc=1 on a DANGLING symlink
  # even though it still prints the correct canonical path, which would turn
  # a legitimate dangling-link-to-somewhere-harmless into a spurious deny.
  # Manual one-hop-at-a-time `readlink` (no flags) never returns that
  # misleading rc for a dangling target. A relative link target is joined
  # against the PHYSICAL directory containing the link (via `cd -P`/`pwd -P`)
  # rather than lexically, for the same "don't out-guess the filesystem"
  # reason the `-ef` walk below uses `cd -P`. Hard-capped at 40 hops and
  # deny() outright past the cap -- a loop (a -> b -> a) must never spin.
  if [ -h "$ABS_PATH" ]; then
    if ! command -v readlink >/dev/null 2>&1; then
      deny "$(mk_msg GE_READLINK_MISSING)"
    fi
    SYMLINK_HOPS=0
    while [ -h "$ABS_PATH" ]; do
      SYMLINK_HOPS=$((SYMLINK_HOPS + 1))
      if [ "$SYMLINK_HOPS" -gt 40 ]; then
        deny "$(mk_msg GE_SYMLINK_LOOP "$ABS_PATH")"
      fi
      LINK_TARGET="$(readlink "$ABS_PATH" 2>/dev/null)"
      LINK_RC=$?
      if [ "$LINK_RC" -ne 0 ] || [ -z "$LINK_TARGET" ]; then
        deny "$(mk_msg GE_SYMLINK_TARGET_UNREADABLE "$ABS_PATH")"
      fi
      case "$LINK_TARGET" in
        /*)
          ABS_PATH="$LINK_TARGET"
          ;;
        *)
          LINK_DIR="${ABS_PATH%/*}"
          [ -z "$LINK_DIR" ] && LINK_DIR="/"
          LINK_DIR_PHYS="$(cd -P "$LINK_DIR" 2>/dev/null && pwd -P)" || LINK_DIR_PHYS=""
          [ -z "$LINK_DIR_PHYS" ] && \
            deny "$(mk_msg GE_SYMLINK_DIR_UNRESOLVED "$LINK_DIR")"
          ABS_PATH="$LINK_DIR_PHYS/$LINK_TARGET"
          ;;
      esac
    done
  fi

  # Classify the NORMALIZED path, not the raw one -- otherwise a lexical
  # trick like "docs/../src/A.cs" (must classify as src/) or
  # "src/../../etc/passwd" (must resolve outside the repo) fools a naive
  # glob match.
  NORM_PATH="$(normalize_path "$ABS_PATH")" || \
    deny "$(mk_msg GE_NORMALIZE_FAILED "$ABS_PATH")"
  CLASSIFIED_PATH="$NORM_PATH"

  # Case-fold before matching. This machine's root volume is APFS, which is
  # case-INSENSITIVE by default: "$ROOT/src/Program.cs" and
  # "$ROOT/SRC/Program.cs" are the SAME inode on disk (verified), but a
  # case-sensitive `case` match would only catch the former -- capitalizing
  # one letter of the path would write the real file straight past the
  # guard. Bash 3.2 has no ${var,,}, so lowercase both sides with `tr` and
  # compare the lowered forms instead.
  # Trade-off, taken deliberately: on a genuinely case-sensitive volume, a
  # directory literally named "SRC" (a distinct directory from "src") would
  # now also be denied even though it is not actually the guarded directory.
  # That is the correct direction for a fail-closed guard.
  if ! command -v tr >/dev/null 2>&1; then
    deny "$(mk_msg GE_TR_MISSING)"
  fi

  NORM_PATH_LOWER="$(printf '%s' "$NORM_PATH" | tr '[:upper:]' '[:lower:]')" || \
    deny "$(mk_msg GE_PATH_LOWER_FAILED "$NORM_PATH")"
  [ -z "$NORM_PATH_LOWER" ] && \
    deny "$(mk_msg GE_PATH_LOWER_EMPTY "$NORM_PATH")"

  # The lowered root spellings (ROOT and every worktree counterpart, see
  # load_guard_roots) and the lowered guarded dirs are the same for every call
  # in this process -- computed once and memoized, instead of re-running tr
  # on every candidate path a Bash command might produce.
  load_guard_roots

  # NOTE: `tr '[:upper:]' '[:lower:]'` above only folds ASCII case. It does
  # NOT reproduce APFS's own Unicode case-folding (e.g. U+017F "ſ" LATIN
  # SMALL LETTER LONG S uppercases to plain "S" on this filesystem, but `tr`
  # leaves "ſ" completely untouched). That gap is NOT closed by the lexical
  # match below -- it is closed by the inode-identity check further down,
  # which asks the filesystem directly instead of trying to out-guess its
  # folding rules lexically.

  # Cheap lexical PRE-FILTER, not the sole authority -- see the inode-identity
  # check immediately below for why. Matches both the bare directory (no
  # trailing slash) and everything under it, for every configured guarded dir
  # (memokit.json guardedDirs), under every guard root spelling.
  LEXICAL_MATCH=0
  if lexical_guarded_in_any_root "$NORM_PATH_LOWER"; then
    LEXICAL_MATCH=1
  fi

  # Same lexical match on the PHYSICAL spelling of the target (deepest
  # existing ancestor through `pwd -P`). Needed because git reports worktree
  # roots physically resolved while a payload path is usually logical (see
  # load_guard_roots); it also covers a physically spelled target under a
  # logical ROOT whose guarded dir does not exist yet (where `-ef` cannot
  # help). It can only add denies.
  if [ "$LEXICAL_MATCH" -eq 0 ]; then
    physical_spelling "$NORM_PATH"
    PHYS_PATH_LOWER="$(printf '%s' "$PHYS_PATH" | tr '[:upper:]' '[:lower:]')" || \
      deny "$(mk_msg GE_PATH_LOWER_FAILED "$PHYS_PATH")"
    [ -z "$PHYS_PATH_LOWER" ] && \
      deny "$(mk_msg GE_PATH_LOWER_EMPTY "$PHYS_PATH")"
    if lexical_guarded_in_any_root "$PHYS_PATH_LOWER"; then
      LEXICAL_MATCH=1
    fi
  fi

  # --- inode-identity check (why it exists, replacing lexical-only) --------
  # The ASCII `tr` fold above cannot see APFS's Unicode case-folding, e.g.
  # toUpper(U+017F "ſ") = "S" on this filesystem, so "$ROOT/ſrc/X.cs"
  # resolves on disk to the very same directory as "$ROOT/src/X.cs"
  # (confirmed live) -- but NORM_PATH_LOWER still contains the literal "ſrc"
  # bytes (tr never touches U+017F), so the lexical `case` above misses it
  # even though the write lands squarely inside the real src/. No amount of
  # tuning the lexical fold can fully replicate a filesystem's own
  # folding/aliasing rules for every current and future Unicode edge case --
  # so instead of trying, ask the filesystem itself with `-ef` (bash's
  # device+inode identity test), which is correct by construction for every
  # case-fold, Unicode normalization, or symlink APFS considers equivalent.
  # Do NOT "simplify" this back to a lexical-only check in a future round.
  #
  # The lexical pre-filter above is still needed and kept as a fallback for
  # the case where a guarded dir does not exist on disk at all -- `-ef` can
  # never match a nonexistent path, so relying on `-ef` alone would fail OPEN
  # in that situation. Final decision:
  #   guarded = LEXICAL_MATCH OR INODE_MATCH
  # which is strictly more fail-closed than the lexical-only check it
  # replaces (it can only turn more paths into denies, never fewer).
  #
  # The target path usually does not exist yet (Write/Edit create it, and any
  # number of nested parent directories may be new too), so `-ef` cannot be
  # applied to NORM_PATH directly. Walk up from the parent, first lexically
  # (cheap string chop) until an existing directory is found, then from there
  # keep walking up comparing that directory's identity against each guarded
  # dir under every guard root (via dir_is_guarded_in_any_root) with `-ef` at
  # every level up to "/". Both loops are hard-capped at 200 iterations and
  # deny() outright if the cap is hit.
  #
  # WHY the walk must start from the RAW $ABS_PATH, not $NORM_PATH: if some
  # ancestor directory in the path is a symlink whose TARGET is a
  # SUBDIRECTORY of a guarded dir (not the guarded dir itself), a walk over
  # the already-lexically-collapsed NORM_PATH keeps comparing lexical parents
  # of the link's own location, never the link's physical target. Confirmed
  # live: `ln -s $ROOT/src/<Project>.Web /tmp/sp/link` then writing to
  # `/tmp/sp/link/PWN.cs` produced rc=0 with empty stdout (ALLOW), even
  # though the real inode written to sits directly inside src/. A second,
  # related shape: normalize_path collapses ".." LEXICALLY, before any
  # physical resolution, but the kernel resolves ".." relative to a
  # symlink's TARGET, not its lexical location -- "docs/dl/../X.cs" where
  # docs/dl -> src/sub lexically collapses to "docs/X.cs" (looks like it
  # escapes src/ entirely) but physically steps out of sub/ into src/ itself.
  # Starting from the raw ABS_PATH and letting `-d` / `cd -P` (both
  # stat()-based, both kernel-correct) do the resolution avoids ever trusting
  # the lexical collapse for an identity decision.
  INODE_MATCH=0
  if [ "$LEXICAL_MATCH" -eq 0 ]; then
    d="${ABS_PATH%/*}"
    [ -z "$d" ] && d="/"

    # Deepest EXISTING ancestor, found by lexical chop-and-test. Chopping
    # lexically between attempts is fine at THIS stage -- `-d` itself resolves
    # symlinks and ".." physically via stat(), so it correctly reports "yes,
    # something real is here" even while `d` itself is still a raw,
    # unresolved path string.
    steps=0
    while [ ! -d "$d" ] && [ "$d" != "/" ]; do
      steps=$((steps + 1))
      if [ "$steps" -gt 200 ]; then
        deny "$(mk_msg GE_PARENT_DIR_LOOP "$NORM_PATH")"
      fi
      d="${d%/*}"
      [ -z "$d" ] && d="/"
    done

    # Physicalize ONCE, here, before the `-ef` walk. `cd -P` resolves every
    # symlink component AND every ".." against the real filesystem tree --
    # REQUIRED, not a style choice: a plain `cd` performs bash's own LOGICAL
    # ".." collapsing (textual, pre-resolution) and reproduces the exact same
    # bug this block exists to close. `pwd -P` afterward prints the fully
    # physical path with zero symlinks left in it, so every step of the
    # upward `-ef` walk below is a plain, symlink-free lexical pop from here
    # on -- no further physicalization is needed per level.
    d_phys="$(cd -P "$d" 2>/dev/null && pwd -P)" || d_phys=""
    [ -z "$d_phys" ] && \
      deny "$(mk_msg GE_PARENT_PHYS_FAILED "$d")"
    d="$d_phys"

    steps=0
    while :; do
      steps=$((steps + 1))
      if [ "$steps" -gt 200 ]; then
        deny "$(mk_msg GE_INODE_LOOP "$NORM_PATH")"
      fi
      if dir_is_guarded_in_any_root "$d"; then
        INODE_MATCH=1
        break
      fi
      [ "$d" = "/" ] && break
      d="${d%/*}"
      [ -z "$d" ] && d="/"
    done
  fi

  # KNOWN, ACCEPTED LIMIT (not solved here, do not attempt to "fix" this by
  # extending the walk above): a HARD link to a FILE is invisible to this
  # guard by construction. Everything else involving links is closed: a
  # symlinked DIRECTORY anywhere in the path (the -ef walk above), and a
  # symlinked FINAL path component -- including one pointing at a file inside
  # a guarded dir, a DANGLING target inside a guarded dir, a multi-link
  # chain, and a RELATIVE target -- are all resolved by the readlink loop
  # above, before NORM_PATH/LEXICAL_MATCH/INODE_MATCH ever see the path. A
  # hard link is different in kind, not just in coverage: `docs/hard.cs`
  # hard-linked to `src/Shared.cs` shares the same inode as the real file,
  # but it has no symlink bit (`[ -h ]` is false for it) and no separate
  # path text pointing at its target the way a symlink's `readlink` output
  # does -- every directory ABOVE it is a perfectly ordinary directory with
  # no special identity to catch via `-ef`. Closing this would require
  # comparing the target FILE's own inode against every file already known
  # to live under a guarded dir -- a fundamentally different (and far more
  # expensive) mechanism than any path/ancestor walk, symlink or otherwise.
  # Reproduce: `ln docs/probe.cs src/Probe.cs` (creates a hard link sharing
  # src/Probe.cs's inode), then write through `docs/probe.cs` -- this guard
  # allows it (rc=0, empty stdout) because docs/ is an ordinary, unrelated
  # directory all the way up. This is the sole record of that gap; there is
  # no dedicated "accepted risks" section elsewhere to point to instead --
  # so the limitation is stated here, in full, rather than as a citation to
  # a document that does not exist.
  #
  # Do NOT delete the readlink loop above as "redundant with this comment" in
  # a future round -- they cover different link types (symlink vs. hard link),
  # and only the hard-link gap is accepted/unclosed.

  if [ "$LEXICAL_MATCH" -eq 1 ] || [ "$INODE_MATCH" -eq 1 ]; then
    GUARDED=1
  else
    GUARDED=0
  fi
}

# handle_guarded_write: called once classify_path has determined a write
# targets a guarded dir. Subagents may write there (that is their job);
# the main session may not (WORKING-MODEL.md §1). $1 is the deny reason to
# use if this turns out to be the main session.
#
# Subagent detection. `agent_id` is the discriminator. Reproducible on any
# checkout: `printf '{"tool_input":{"file_path":"src/x.cs"}}' | bash
# guard-edit.sh` denies (no agent_id -> main session); the same payload with
# `,"agent_id":"probe"` appended allows silently (rc=0, no stdout). In the
# same live session, the main-thread payload carries neither `agent_id` nor
# `agent_type`, while a subagent payload carries both, and `agent_id` equals
# the id the Agent tool returned. `agent_type` is deliberately NOT used -- it
# would start matching the main thread the moment it gains a default value,
# silently disabling this guard; `agent_id` is tied to an actual spawned
# agent.
# `// ""` is required here; jq's `// empty` idiom yields an empty stream and
# makes the comparison vanish, which would also silently disable the guard.
# The assignment is also guarded with `|| deny`: if jq fails on THIS
# invocation, IS_SUB captures empty output, which matches neither "sub" nor
# equals "sub" below, so it would actually still fall through to the final
# deny by accident today -- but relying on that accident is fragile. Fail
# closed explicitly instead, with a reason that names the real cause.
# IS_SUB failing must ALSO deny, never allow -- do not turn this into
# `|| exit 0`.
handle_guarded_write() {
  IS_SUB="$(printf '%s' "$PAYLOAD" | jq -r 'if (.agent_id // "") != "" then "sub" else "main" end' 2>/dev/null)" || \
    deny "$(mk_msg GE_SUBAGENT_CHECK_FAILED)"

  # Subagents are always allowed.
  [ "$IS_SUB" = "sub" ] && exit 0

  # Fail-closed: the main session is denied from here on. Emergency escape is
  # MEMOKIT_GUARD_OFF=1 (handled at the top of this script; see also
  # WORKING-MODEL.md §1 for how to wire it so it actually takes effect).
  deny "$1"
}

# Dispatch on which FIELD is actually present in tool_input, not on
# tool_name. Edit/Write/MultiEdit/NotebookEdit payloads carry file_path (or
# notebook_path); Bash payloads carry command; the two shapes never overlap,
# so this is unambiguous, and it is more robust than string-matching
# tool_name for a reason that matters concretely here (legacy projects): a
# knowledge-health-style smoke fixture for this hook sends
# `{"tool_input":{"file_path":"..."}}` with NO tool_name field at all.
# Dispatching on tool_name would silently route that fixture to an
# "unrecognized tool" fall-through and stop it from ever exercising the real
# deny path -- exactly the false-coverage failure mode a smoke-testing setup
# like that is meant to catch. Dispatching on field presence keeps that
# fixture meaningful without needing a dedicated tool_name.
#
# `// ""` alone is NOT enough here, even paired with `|| deny` -- that only
# catches a NON-ZERO jq exit. A jq that exits 0 but prints truly nothing
# (empty stdout, not even an empty string) makes FILE_PATH="" via ordinary
# "command substitution of nothing", with the assignment itself still
# reporting success -- so `|| deny` never fires. Prefix the result with a
# literal sentinel ("@") that only a jq which actually RAN can ever produce:
# a truly empty result (no sentinel at all) then can only mean "jq produced
# nothing" (indistinguishable from a crash, denied); a result of exactly "@"
# means jq ran fine and the field is genuinely absent.
FILE_PATH_RAW="$(printf '%s' "$PAYLOAD" | jq -r '"@" + (.tool_input.file_path // .tool_input.notebook_path // "")' 2>/dev/null)"
FILE_PATH_RC=$?
if [ "$FILE_PATH_RC" -ne 0 ] || [ -z "$FILE_PATH_RAW" ]; then
  deny "$(mk_msg GE_PATH_EXTRACT_FAILED)"
fi
FILE_PATH="${FILE_PATH_RAW#@}"

if [ -n "$FILE_PATH" ]; then
  # Edit/Write/MultiEdit/NotebookEdit-shaped payload (or, in legacy
  # projects, a knowledge-health-style smoke fixture, which sends exactly
  # this shape without a tool_name field).
  #
  # Edit/Write/MultiEdit/NotebookEdit always send an absolute file_path in
  # practice, so BASEDIR only matters for the relative-path fallback branch
  # -- ROOT is the only base this script has any actual claim to (it never
  # reads a cwd field for this tool family). A knowledge-health-style smoke
  # fixture (legacy projects) DOES send a relative file_path
  # ("src/Microservices/..."), so this fallback is exercised by that
  # fixture, not dead code.
  classify_path "$FILE_PATH" "$ROOT"
  if [ "$GUARDED" -eq 1 ]; then
    # NOTE on quoting: mk_msg's template already carries the bash-escaped
    # literal quote characters (`\"`) around subagent_type. deny() hands the
    # rendered string to `jq --arg`, which does its own JSON escaping --
    # passing already-backslash-escaped quotes here would make jq escape the
    # backslashes too, rendering as literal backslashes in the text the
    # operator reads instead of plain quote marks.
    handle_guarded_write "$(mk_msg GE_WRITE_DENIED "$(mk_dirs_human)" "$FILE_PATH" "$CLASSIFIED_PATH")"
  fi
  exit 0
fi

# No file_path/notebook_path field -- either a Bash call (handled below via
# tool_input.command) or some other tool shape this guard has nothing to
# classify for (allowed: a genuinely absent field, not "jq produced
# nothing", which was already denied above).
CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)" || \
  deny "$(mk_msg GE_CMD_EXTRACT_FAILED)"

[ -z "$CMD" ] && exit 0

# --- the Bash branch: scan tool_input.command for WRITE CONSTRUCTS ---------
# A Bash command is not reliably parseable, and the main session
# legitimately runs many read-only commands that MENTION one of the guarded
# dirs (`grep -rn foo src/`, `dotnet test tests/Foo`, `ls src/`, `git diff --
# src/`). Fail-closed-on-any-mention would make the repo unusable, so this
# branch does the opposite of the rest of this file: it looks only for
# specific WRITE CONSTRUCTS (output redirects, and a fixed list of commands
# whose entire job is mutating files on disk) and extracts their target path
# argument(s). A command with none of those constructs yields zero
# candidates and is allowed, regardless of how many times it mentions a
# guarded dir.
# Every candidate path that IS found is still run through the exact same
# fail-closed classify_path() used by the Edit/Write branch above --
# ambiguity in resolving a FOUND candidate still denies.
#
# RESIDUAL LIMITATION (stated once, applies to this whole branch): this is a
# guard against the INSTINCTIVE violation ("I'll just fix this file real
# quick"), not a sandbox. An agent that actively WANTS to evade it still can
# -- base64-encoded payloads, a script file invoked with `bash foo.sh`,
# `python -c "open('src/x','w')...`, a custom shell alias, etc. Closing that
# would require actually executing (or fully emulating) the command to see
# what it does, which is a different and far more expensive mechanism than
# text scanning.

# Base directory for relative candidate paths: a shell command's relative
# paths resolve against the shell's cwd, not this script's. Claude Code's
# PreToolUse payload carries the session's cwd at the top level; fall back
# to ROOT (this repo's root) if it is absent or not absolute -- ROOT is the
# best available stand-in, and every test in this project's Bash tool calls
# does in practice run from the repo root.
CWD_RAW="$(printf '%s' "$PAYLOAD" | jq -r '.cwd // ""' 2>/dev/null)"
BASEDIR="$ROOT"
case "$CWD_RAW" in /*) BASEDIR="$CWD_RAW" ;; esac

# Heredoc BODY lines are DATA, not commands -- a doc-writing command like
# `cat > docs/x.md <<'EOF' ... EOF` can legitimately contain example text
# such as "cp /tmp/x src/y.cs" inside the heredoc body purely as
# illustration (this very hook-review task is such an example). Without
# this step, the segment-based command scan below would treat that
# documentation text as a real command and false-positive deny it. Detects
# `<<MARKER`, `<<-MARKER`, `<<'MARKER'`, `<<"MARKER"`, `<<\MARKER` and drops
# every line from the one after the opener up to (and re-including) the
# line that is exactly the bare marker (leading tabs stripped first when
# the `<<-` form was used, matching real shell semantics). Heuristic gap,
# accepted: a marker containing shell metacharacters beyond the ones
# stripped here, or two heredocs opened on the same line, are not specially
# handled.
strip_heredoc_bodies() {
  raw="$1"
  out=""
  heredoc_marker=""
  in_heredoc=0
  strip_tabs=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_heredoc" -eq 1 ]; then
      trimmed="$line"
      if [ "$strip_tabs" -eq 1 ]; then
        while :; do
          case "$trimmed" in
            "$(printf '\t')"*) trimmed="${trimmed#?}" ;;
            *) break ;;
          esac
        done
      fi
      if [ "$trimmed" = "$heredoc_marker" ]; then
        in_heredoc=0
        out="$out
$line"
      fi
      continue
    fi
    out="$out
$line"
    case "$line" in
      *'<<'*)
        strip_tabs=0
        case "$line" in *'<<-'*) strip_tabs=1 ;; esac
        marker="$(printf '%s\n' "$line" | grep -oE '<<-?[[:space:]]*\\?["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?' 2>/dev/null | tail -n1)"
        if [ -n "$marker" ]; then
          m="${marker#<<}"; m="${m#-}"
          # shellcheck disable=SC1003  # this IS the intended '"'"' embedded
          # single-quote, not a mistaken escape attempt.
          m="$(printf '%s' "$m" | tr -d '[:space:]"'"'"'\\' 2>/dev/null)"
          if [ -n "$m" ]; then
            heredoc_marker="$m"
            in_heredoc=1
          fi
        fi
        ;;
    esac
  done <<HDEOF
$raw
HDEOF
  printf '%s' "${out#$'\n'}"
}

# Extracts every candidate write-TARGET path from a (heredoc-stripped)
# command string, one per output line.
find_bash_write_targets() {
  c="$1"

  # Pass 1: output redirects -- `>`, `>>`, `>|` (noclobber override), `N>`,
  # `N>>`, `N>|`, `&>`, `&>>`. This also catches a heredoc-plus-redirect
  # combo like `cat > src/x <<EOF`, since the `>` is present regardless of
  # where the heredoc marker sits.
  printf '%s' "$c" | grep -oE '[0-9]*(>>|>\||>|&>>|&>)[[:space:]]*[^[:space:];|&<>(){}`]+' 2>/dev/null | \
  while IFS= read -r match; do
    path="${match##*>}"
    # `>|`: the `|` sits after the last '>' -- drop it before the trim.
    path="${path#|}"
    # The [[:space:]]* between the operator and the path is captured as
    # part of $match but sits after the last '>', so it survives the
    # ${match##*>} strip -- trim it or "> src/a.cs" resolves relative to
    # "$BASEDIR/ src/a.cs" (leading space baked into the path).
    while :; do
      case "$path" in
        " "*) path="${path# }" ;;
        "$(printf '\t')"*) path="${path#?}" ;;
        *) break ;;
      esac
    done
    # `2>&1`, `1>&2`, ... redirect to a FILE DESCRIPTOR, not a file -- skip
    # rather than pass "&1" through as a (harmless but noisy) non-match.
    case "$path" in
      '&'[0-9]*) continue ;;
    esac
    [ -n "$path" ] && printf '%s\n' "$path"
  done

  # Pass 2: named commands whose entire job is mutating files on disk.
  # Segmented the same way guard-subagent-authority.sh segments a command
  # (on newline, ; | &), so `foo && tee src/x.cs` is inspected as its own
  # command, not as an argument to foo. Deliberately does NOT descend into
  # $(...), `...`, (...) or {...} groups -- a write hidden inside a subshell
  # still requires deliberate obfuscation, which is out of scope per the
  # residual-limitation note above (that concern is for Fix 2's
  # banned-subcommand list in the OTHER hook, not this one).
  # shellcheck disable=SC2020  # intentional: each of \n ; | & is meant to
  # map to a newline individually (a set-to-set translation), not as a
  # 4-char "word" -- the duplicate targets are the point, not a mistake.
  SEGMENTS="$(printf '%s' "$c" | tr '\n;|&' '\n\n\n\n')"
  printf '%s\n' "$SEGMENTS" | while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    # Intentional word splitting to tokenize. This is a heuristic,
    # whitespace-only split, not a real shell parser -- a quoted argument
    # containing a space (`cp "my file.cs" src/`) is mis-tokenized.
    # Accepted gap: under-detection here means a missed deny, never a
    # false deny, consistent with this branch's fail-open-on-ambiguity
    # design.
    # shellcheck disable=SC2086
    set -- $seg
    while [ $# -gt 0 ]; do
      case "$1" in
        *=*) shift ;;                                  # VAR=val prefix
        sudo|env|nohup|time|command|builtin|xargs) shift ;;
        *) break ;;
      esac
    done
    [ $# -eq 0 ] && continue
    bin="${1##*/}"
    shift
    case "$bin" in
      tee)
        # tee writes to every non-flag argument.
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          printf '%s\n' "$a"
        done
        ;;
      dd)
        for a in "$@"; do
          case "$a" in of=*) printf '%s\n' "${a#of=}" ;; esac
        done
        ;;
      sed)
        # In-place edit only. Heuristic: if any argument is `-i` or starts
        # with `-i` (BSD `-i ''` / `-i.bak`, GNU `-i.bak`), the LAST
        # non-flag argument on this segment is the target file. Multiple
        # target files on one `sed -i` invocation are under-detected (only
        # the last is checked) -- accepted gap, under-detection only.
        has_i=0
        last=""
        for a in "$@"; do
          case "$a" in
            -i|-i.*|--in-place|--in-place=*) has_i=1 ;;
          esac
          case "$a" in -*) : ;; *) last="$a" ;; esac
        done
        [ "$has_i" -eq 1 ] && [ -n "$last" ] && printf '%s\n' "$last"
        ;;
      cp|mv|install|rsync)
        # Destination heuristic: the last argument (flag-form or not -- a
        # flag as the true last token, e.g. a trailing `-v`, simply fails
        # to classify as guarded and is harmless). Flags that themselves
        # consume a following value (`-m 0644`, `--target-directory=DIR`,
        # ...) are not specially parsed; worst case this checks the source
        # instead of an explicit `-t DIR` destination, which under-detects
        # rather than over-denies.
        last=""
        for a in "$@"; do last="$a"; done
        [ -n "$last" ] && printf '%s\n' "$last"
        ;;
      truncate)
        last=""
        for a in "$@"; do
          case "$a" in -*) : ;; *) last="$a" ;; esac
        done
        [ -n "$last" ] && printf '%s\n' "$last"
        ;;
      touch|mkdir|rm)
        # All three can target multiple paths in one call (mkdir is
        # checked regardless of -p; creating a plain, non-parented
        # directory inside a guarded dir is still a mutation there).
        for a in "$@"; do
          case "$a" in -*) continue ;; esac
          printf '%s\n' "$a"
        done
        ;;
    esac
  done
}

# unquote_candidate WORD -- WORD with ONE layer of matching surrounding
# double or single quotes removed (`"src/a.cs"` / `'src/a.cs'` ->
# `src/a.cs`), otherwise WORD unchanged. The shell strips those quotes
# before the command runs, so the quoted spelling writes the same file.
# Only ever used to classify an EXTRA spelling of a candidate (the raw
# spelling is still classified first), so it can only add denies.
unquote_candidate() {
  u="$1"
  case "$u" in
    \"*\") u="${u#\"}"; u="${u%\"}" ;;
    \'*\') u="${u#\'}"; u="${u%\'}" ;;
  esac
  printf '%s' "$u"
}

CMD_CLEANED="$(strip_heredoc_bodies "$CMD")"
CANDIDATES="$(find_bash_write_targets "$CMD_CLEANED")"

FOUND_GUARDED=0
GUARDED_CANDIDATE=""
if [ -n "$CANDIDATES" ]; then
  while IFS= read -r CAND; do
    [ -z "$CAND" ] && continue
    classify_path "$CAND" "$BASEDIR"
    if [ "$GUARDED" -eq 1 ]; then
      FOUND_GUARDED=1
      GUARDED_CANDIDATE="$CAND"
      break
    fi
    UNQUOTED="$(unquote_candidate "$CAND")"
    if [ -n "$UNQUOTED" ] && [ "$UNQUOTED" != "$CAND" ]; then
      classify_path "$UNQUOTED" "$BASEDIR"
      if [ "$GUARDED" -eq 1 ]; then
        FOUND_GUARDED=1
        GUARDED_CANDIDATE="$CAND"
        break
      fi
    fi
  done <<CANDEOF
$CANDIDATES
CANDEOF
fi

[ "$FOUND_GUARDED" -eq 0 ] && exit 0

handle_guarded_write "$(mk_msg GE_BASH_WRITE_DENIED "$(mk_dirs_human)" "$GUARDED_CANDIDATE" "$CLASSIFIED_PATH" "$CMD")"
