#!/usr/bin/env bash
# memokit shared hook library. Sourced by every hook, never executed.
# bash 3.2-safe. Design notes: hooks/lib/README.md.
# MK_* globals set by mk_resolve_root/mk_load_config are the library's public
# contract: hooks that source this file read them after calling the setter,
# so shellcheck cannot see the use from this file alone.
# shellcheck disable=SC2034
MK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MK_HOOKS_DIR="$(cd "$MK_LIB_DIR/.." && pwd)"
MK_ROOT=""
MK_CONFIG=""
MK_CONFIG_LIVE=""
MK_TAG="MEMOKIT"
MK_LANG="en"

mk_resolve_root() {
  local cwd cdup top
  MK_ROOT="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$MK_ROOT" ] && command -v jq >/dev/null 2>&1; then
    cwd="$(printf '%s' "${1:-}" | jq -r '.cwd // empty' 2>/dev/null)"
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then
      # Use --show-cdup (a relative offset) rather than --show-toplevel
      # (an already symlink-resolved absolute path): applying a relative
      # cd keeps MK_ROOT in the same logical (unresolved) form as $cwd,
      # matching how CLAUDE_PROJECT_DIR is normalized below.
      if cdup="$(git -C "$cwd" rev-parse --show-cdup 2>/dev/null)"; then
        MK_ROOT="$(cd "$cwd" && cd "${cdup:-.}" && pwd)"
      else
        MK_ROOT="$cwd"
      fi
    fi
  fi
  if [ -n "$MK_ROOT" ] && [ -d "$MK_ROOT" ]; then
    MK_ROOT="$(cd "$MK_ROOT" && pwd)"
  else
    MK_ROOT=""
  fi
  # Subdirectory launch (Claude started in <repo>/src): CLAUDE_PROJECT_DIR is
  # that subdirectory, which has no config of its own. Fall back to the git
  # top level -- and only to it, never further up -- when THAT holds the
  # config. A root that already has a config is used as-is. --show-cdup keeps
  # the logical (unresolved-symlink) form, as in the cwd branch above; the
  # -ef against --show-toplevel rejects a logical ".." that climbed out of a
  # symlinked subdirectory to somewhere other than the real top level.
  if [ -n "$MK_ROOT" ] && [ ! -f "$MK_ROOT/.claude/memokit.json" ] &&
     cdup="$(git -C "$MK_ROOT" rev-parse --show-cdup 2>/dev/null)" && [ -n "$cdup" ]; then
    top="$(cd "$MK_ROOT" && cd "$cdup" && pwd)" || top=""
    if [ -n "$top" ] && [ -f "$top/.claude/memokit.json" ] &&
       [ "$top" -ef "$(git -C "$MK_ROOT" rev-parse --show-toplevel 2>/dev/null)" ]; then
      MK_ROOT="$top"
    fi
  fi
  MK_CONFIG_LIVE="${MK_ROOT:+$MK_ROOT/.claude/memokit.json}"
  MK_CONFIG="$MK_CONFIG_LIVE"
  _mk_config_pick "${1:-}"
}

# _mk_config_pick PAYLOAD -- MK_CONFIG becomes this session's config snapshot
# (session-start.sh, mk_config_snapshot_write) when the payload is a
# subagent's (non-empty agent_id), the live file exists and the snapshot is a
# regular file, not a symlink, owned by the user. Anything else keeps the
# live file: the main session, no snapshot, a deleted live config (which
# mk_config_vanished denies as in 0.8.0). One jq call, only while the live
# file exists and the payload holds the text "agent_id" (one bash regex
# test, no fork: the main session's usual payload skips the jq). The test
# runs under LC_ALL=C: in a UTF-8 locale bash 3.2's regexec finds no match
# in a text holding an invalid byte anywhere.
_mk_config_pick() {
  local LC_ALL=C
  local out f re='"agent_id"' nl='
'
  [ -n "$MK_CONFIG_LIVE" ] && [ -f "$MK_CONFIG_LIVE" ] || return 0
  [[ $1 =~ $re ]] || return 0
  out="$(printf '%s' "$1" | jq -r '(if (.agent_id // "") != "" then "sub" else "main" end), (.session_id // "unknown")' 2>/dev/null)" || return 0
  case "$out" in "sub$nl"*) ;; *) return 0 ;; esac
  f="$(_mk_session_tmp config "${out#"sub$nl"}")"
  if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ]; then MK_CONFIG="$f"; fi
  return 0
}

mk_active() { [ -n "$MK_ROOT" ] && [ -f "$MK_CONFIG_LIVE" ]; }

# _mk_session_tmp KIND SID -- this project's per-session state file
# careful-KIND-<SID>, SID sanitised to [A-Za-z0-9_-] ("unknown" when empty).
_mk_session_tmp() {
  mk_tmp "careful-$1-$(printf '%s' "${2:-unknown}" | tr -c 'A-Za-z0-9_-' _)"
}
# _mk_state_write FILE -- stdin to FILE with the safe writer: never through a
# symlink or over a foreign or non-regular file; atomic (mktemp + mv, umask
# 077).
_mk_state_write() {
  local f="$1" tmp
  case "$f" in /?*) ;; *) return 1 ;; esac
  [ -L "$f" ] && return 1
  if [ -e "$f" ]; then { [ -f "$f" ] && [ -O "$f" ]; } || return 1; fi
  tmp="$( umask 077; mktemp "$f.XXXXXX" 2>/dev/null )" || return 1
  [ -n "$tmp" ] || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# Active marker: session-start.sh (main session) writes it when memokit is
# active, so a config that vanishes mid-session (every hook gates on
# mk_active) can be told from a project that never had memokit. The name
# starts with careful- so it is careful-state (a command naming it is denied).
mk_active_marker_file() {
  local sid
  sid="$(printf '%s' "$1" | jq -r '.session_id // "unknown"' 2>/dev/null)"
  _mk_session_tmp active "$sid"
}
# mk_active_marker_write PAYLOAD -- safe writer (_mk_state_write).
mk_active_marker_write() {
  printf 'active\n' | _mk_state_write "$(mk_active_marker_file "$1")"
}
# Config snapshot (0.8.1): session-start.sh copies the validated live config
# here on startup, resume and clear (not compact); subagent payloads read it
# (_mk_config_pick). Named careful-config-<session>: careful-state, so a
# command naming it is denied, and guard-subagent-authority.sh Rule 2a denies
# the file tools on it.
mk_config_snapshot_file() {
  local sid
  sid="$(printf '%s' "$1" | jq -r '.session_id // "unknown"' 2>/dev/null)"
  _mk_session_tmp config "$sid"
}
# mk_config_snapshot_write PAYLOAD -- copies MK_CONFIG_LIVE with the safe
# writer; exit 1 on any refusal.
mk_config_snapshot_write() {
  [ -n "$MK_CONFIG_LIVE" ] && [ -f "$MK_CONFIG_LIVE" ] || return 1
  _mk_state_write "$(mk_config_snapshot_file "$1")" < "$MK_CONFIG_LIVE"
}
# mk_config_vanished PAYLOAD -- true when memokit is not active now, this
# session's marker says it was, and the payload is a subagent (agent_id) using
# Bash or a file-editing tool.
mk_config_vanished() {
  local f
  mk_active && return 1
  f="$(mk_active_marker_file "$1")"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || return 1
  printf '%s' "$1" | jq -e '(.agent_id // "") != "" and ((.tool_name // "") as $t
    | ($t == "Bash" or $t == "Edit" or $t == "Write" or $t == "MultiEdit" or $t == "NotebookEdit"))' >/dev/null 2>&1
}

# mk_path_inside_root <repo-relative path>: true when the path's directory,
# resolved physically (so "../" and symlinked directories count), is below
# MK_ROOT and the file itself is not a symlink. Guards the scripts memokit.json
# names (healthScript, graph.refreshScript): memokit is enabled at user level,
# so a cloned repo's config must not point it at a file elsewhere.
mk_path_inside_root() {
  local rootp dirp
  [ -L "$MK_ROOT/$1" ] && return 1
  rootp="$(CDPATH='' cd -- "$MK_ROOT" && pwd -P)" || return 1
  dirp="$(CDPATH='' cd -- "$MK_ROOT" && CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  case "$dirp/" in "$rootp"/*) return 0 ;; esac
  return 1
}

# mk_config_invalid_msg -- the deny text for a config mk_load_config refused:
# CONFIG_SNAPSHOT_INVALID when MK_CONFIG is this session's snapshot (a
# subagent payload), CONFIG_INVALID otherwise.
mk_config_invalid_msg() {
  if [ "$MK_CONFIG" != "$MK_CONFIG_LIVE" ]; then
    mk_msg CONFIG_SNAPSHOT_INVALID "$MK_CONFIG_ERR"
  else
    mk_msg CONFIG_INVALID "$MK_CONFIG_ERR"
  fi
}

mk_lang_guess() {
  if grep -Eq '"language"[[:space:]]*:[[:space:]]*"tr"' "$MK_CONFIG" 2>/dev/null; then
    printf 'tr'
  else
    printf 'en'
  fi
}

mk_load_messages() {
  # shellcheck source-path=SCRIPTDIR source=../messages/en.sh
  . "$MK_HOOKS_DIR/messages/en.sh"
  if [ "${1:-en}" != "en" ] && [ -f "$MK_HOOKS_DIR/messages/$1.sh" ]; then
    # shellcheck disable=SC1090
    . "$MK_HOOKS_DIR/messages/$1.sh"
  fi
}

mk_load_config() {
  local out
  MK_CONFIG_OK=0; MK_CONFIG_ERR=""; MK_CONFIG_WARN=""
  MK_NAME=""; MK_GUARDED_DIRS="src
tests"; MK_CONTEXT_LIMIT=300000; MK_STATE_MAX_BEHIND=3
  MK_HEALTH_SCRIPT=""; MK_SESSION_DOCS=""; MK_HINTS_CUSTOM_JSON="[]"
  MK_GRAPH_ROOT=""; MK_GRAPH_MAX_BEHIND=20; MK_GRAPH_REFRESH_SCRIPT=""; MK_CAREFUL_PATTERNS_JSON="[]"
  MK_REMOTE_ENABLED=0; MK_REMOTE_DEPLOY_BRANCHES=""; MK_REMOTE_HOSTS=""; MK_REMOTE_READONLY=""
  MK_REMOTE_WINDOW_MIN=30; MK_REMOTE_RUNBOOKS_DIR=".claude/memokit/runbooks"; MK_REMOTE_LOG="docs/DEPLOYS.md"
  MK_SCRATCH_AGENT_MAX_MB=1024; MK_SCRATCH_STALE_HOURS=24; MK_SCRATCH_REPORT_MIN_MB=500
  MK_DISK_MIN_FREE_GB=30; MK_DISK_DROP_WARN_GB=10
  MK_PARALLEL_MAX_CODERS=3; MK_PARALLEL_MAX_REVIEWERS=3; MK_REVIEW_MODEL="auto"; MK_CONVERT_MARKITDOWN=0
  MK_HINTS_BUILTIN="debugging decision review handoff resume graphify"
  if ! command -v jq >/dev/null 2>&1; then
    MK_CONFIG_ERR="jq"; MK_LANG="$(mk_lang_guess)"; mk_load_messages "$MK_LANG"; return 1
  fi
  # config.jq always starts with MK_CONFIG_ERR=: anything else is a broken jq.
  if ! out="$(jq -r -f "$MK_LIB_DIR/config.jq" "$MK_CONFIG" 2>/dev/null)" ||
     case "$out" in MK_CONFIG_ERR=*) false ;; *) true ;; esac; then
    MK_CONFIG_ERR="parse"; MK_LANG="$(mk_lang_guess)"; mk_load_messages "$MK_LANG"; return 1
  fi
  eval "$out"
  if [ -n "$MK_CONFIG_ERR" ]; then
    MK_LANG="$(mk_lang_guess)"; mk_load_messages "$MK_LANG"; return 1
  fi
  MK_CONFIG_OK=1
  mk_load_messages "$MK_LANG"
  return 0
}

mk_msg() {
  local key="${1:-}" var tpl
  case "$key" in ''|*[!A-Z0-9_]*) return 1 ;; esac
  shift
  var="MK_T_${key}"
  tpl="${!var:-}"
  [ -z "$tpl" ] && return 1
  tpl="${tpl//@TAG@/$MK_TAG}"
  # shellcheck disable=SC2059
  printf "$tpl" "$@"
}

mk_tmp() {
  local h
  h="$(printf '%s' "${MK_ROOT:-none}" | cksum | cut -d' ' -f1)"
  printf '%s/memokit-%s-%s' "${TMPDIR:-/tmp}" "$h" "$1" | sed 's#//*#/#g'
}

mk_debug_dump() {
  [ "${MEMOKIT_HOOK_DEBUG:-0}" = "1" ] || return 0
  printf '%s' "$2" > "$(mk_tmp "hook-$1.json")" 2>/dev/null || true
}

mk_guard_off() { [ "${MEMOKIT_GUARD_OFF:-0}" = "1" ]; }

mk_dirs_human() {
  printf '%s\n' "$MK_GUARDED_DIRS" | sed '/^$/d; s#$#/#' | paste -sd, - | sed 's/,/, /g'
}

# mk_strip_heredoc_bodies TEXT -- TEXT with the BODY lines of every heredoc
# dropped (the opener line and the closing marker line kept), for
# guard-edit.sh and guard-subagent-authority.sh: a body is data, not a
# command. A line holding << opens a heredoc when the LAST <<MARKER on it
# (<<-?, blanks, an optional backslash and quote, a name) names one; the
# body ends at the line that is exactly the marker (leading tabs dropped
# first when the line holds <<-). ONE awk pass (0.8.0 final wave: the old
# loop forked grep | tail for every line holding <<, 16 000 such lines took
# past the 5 s hook timeout). The last marker is found by splitting the
# line on < (a marker holds no <), linear in the line.
mk_strip_heredoc_bodies() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { re = "^-?[[:space:]]*\\\\?[\"\047]?[A-Za-z_][A-Za-z0-9_]*[\"\047]?" }
    {
      if (inh) {
        t = $0
        if (tabs) sub(/^\t+/, "", t)
        if (t == mk) { inh = 0; print }
        next
      }
      print
      if (index($0, "<<")) {
        tabs = index($0, "<<-") ? 1 : 0
        n = split($0, a, "<")
        for (i = n - 1; i >= 2; i--) {
          if (a[i] != "" || !match(a[i + 1], re)) continue
          m = substr(a[i + 1], RSTART, RLENGTH)
          sub(/^-/, "", m); gsub("[[:space:]\"\047\\\\]", "", m)
          if (m != "") { mk = m; inh = 1 }
          break
        }
      }
    }'
}

mk_in_guarded_list() {
  local gd
  while IFS= read -r gd; do
    [ -z "$gd" ] && continue
    case "$1" in "$gd"|"$gd"/*) return 0 ;; esac
  done <<EOF
$MK_GUARDED_DIRS
EOF
  return 1
}
