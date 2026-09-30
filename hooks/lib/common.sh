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
  MK_CONFIG="${MK_ROOT:+$MK_ROOT/.claude/memokit.json}"
}

mk_active() { [ -n "$MK_ROOT" ] && [ -f "$MK_CONFIG" ]; }

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
  MK_GRAPH_ROOT=""; MK_GRAPH_MAX_BEHIND=20; MK_GRAPH_REFRESH_SCRIPT=""
  MK_HINTS_BUILTIN="debugging decision review handoff resume graphify"
  if ! command -v jq >/dev/null 2>&1; then
    MK_CONFIG_ERR="jq"; MK_LANG="$(mk_lang_guess)"; mk_load_messages "$MK_LANG"; return 1
  fi
  if ! out="$(jq -r -f "$MK_LIB_DIR/config.jq" "$MK_CONFIG" 2>/dev/null)" || [ -z "$out" ]; then
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
