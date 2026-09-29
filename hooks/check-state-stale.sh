#!/usr/bin/env bash
# Stop hook: warn when a guarded dir (memokit.json guardedDirs) changed but
# docs/STATE.md did not.
#
# Two independent checks, because "stale" has two shapes:
#  1. Uncommitted: a guarded dir has working-tree changes, STATE.md has none.
#  2. Committed-but-stale: guarded-dir commits landed AFTER the last commit
#     that touched STATE.md. Once a slice is committed without updating
#     STATE.md, check 1 goes quiet forever even though STATE.md is now
#     out of date -- this is the gap check 1 alone cannot see.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "check-state-stale" "$PAYLOAD"
mk_load_config || exit 0

cd "$MK_ROOT" || exit 0

STATE_FILE="docs/STATE.md"
MAX_SRC_COMMITS_BEHIND="$MK_STATE_MAX_BEHIND"

REASONS=""

# Round 6 merge-gate audit fix (Finding 5, confirmed): every check below is
# git-based. If `git` is simply missing from PATH (as opposed to this
# genuinely not being a git repo), `git status`/`git rev-parse` all fail with
# "command not found" -- exit 127, no output. That reads EXACTLY like "clean
# tree, nothing to report" to every check below (SRC_DIRTY=0, STATE_DIRTY=0,
# the `git rev-parse --git-dir` guard also just silently fails its `if`), so
# the whole staleness check goes quiet with no warning at all, on a repo that
# may in fact be genuinely stale. That is a materially different situation
# from "not a git repo" (a legitimate, silent no-op) and must not be
# conflated with it -- so check for the binary explicitly, first, and WARN
# (not silently skip) when it is absent.
if ! command -v git >/dev/null 2>&1; then
  jq -n --arg ctx "$(mk_msg ST_NO_GIT "$(mk_dirs_human)")" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  exit 0
fi

# Build the guarded-dirs pathspec once, as positional args, for use by BOTH
# `git status --porcelain` and `git rev-list --count` below. guardedDirs is
# already validated by config.jq (dir_ok: no spaces, no leading "/" or "..",
# no glob metacharacters -- see hooks/lib/config.jq), so the unquoted word
# split below never sees a shell-meaningful character; `set -f` (noglob)
# stays on for the split anyway, as cheap defense-in-depth against that
# invariant ever loosening.
set -f
# shellcheck disable=SC2046,SC2086  # intentional: splitting MK_GUARDED_DIRS
# (newline-separated, trailing "/" appended per entry) into one positional
# arg per guarded dir -- see the comment above for why this is safe.
set -- $(printf '%s\n' "$MK_GUARDED_DIRS" | sed 's#$#/#')
set +f

SRC_DIRTY=$(git status --porcelain -- "$@" 2>/dev/null | wc -l | tr -d ' ')
STATE_DIRTY=$(git status --porcelain -- "$STATE_FILE" 2>/dev/null | wc -l | tr -d ' ')

if [ "$SRC_DIRTY" -gt 0 ] && [ "$STATE_DIRTY" -eq 0 ]; then
  # STATE.md'nin çalışma ağacında temiz olmasının İKİ ayrı anlamı var ve bu
  # kontrol başlangıçta ikisini birbirine karıştırıyordu:
  #   (a) hiç güncellenmedi  -> gerçekten bayat, uyarılmalı
  #   (b) güncellendi ve AZ ÖNCE commit'lendi, guarded dir ise kasten
  #       commit'siz bekliyor (dilim ortası: kod denetimde, STATE.md güncel)
  #       -> uyarma
  # (b) bir üretim deposunda canlı yanlış pozitif olarak ateşledi: STATE.md
  # commit edilmiş, guarded dir denetim beklerken hook "STATE.md
  # güncellenmedi" dedi. Doğru soru "çalışma ağacında kirli mi" değil,
  # "GÜNCEL mi" -- bunu kontrol 2'nin zaten kullandığı git-log tazelik
  # mantığıyla ölç.
  #
  # Pencere KASITLI OLARAK yalnızca HEAD: "STATE.md'yi 10 commit önce
  # güncellemiştim" bahanesi guard'ı susturmasın. Kontrol 2 (aşağıda) eskimeyi
  # ayrıca ve bağımsız olarak yakalamaya devam eder.
  #
  # Fail-closed: state_sha boşsa (STATE.md hiç commit'lenmemiş) ya da git
  # komutları başarısız olursa uyarı BASILIR -- sessizce izin verilmez.
  head_sha=$(git rev-parse HEAD 2>/dev/null)
  state_sha=$(git log -1 --format=%H -- "$STATE_FILE" 2>/dev/null)
  if [ -z "$state_sha" ] || [ -z "$head_sha" ] || [ "$state_sha" != "$head_sha" ]; then
    REASONS="${REASONS}$(mk_msg ST_DIRTY "$(mk_dirs_human)" "$SRC_DIRTY")"
  fi
fi

# `git rev-parse --git-dir`, not `[ -d .git ]`: in a git worktree or
# submodule, .git is a FILE (a gitdir pointer), not a directory, so the
# directory test silently fails and this whole check goes quiet with no
# warning. rev-parse works for both layouts. `git` itself is already known
# to exist at this point (checked above) -- a false result here now means
# "genuinely not a git repo", a legitimate, silent no-op.
if git rev-parse --git-dir >/dev/null 2>&1; then
  last_state_commit=$(git log -1 --format=%H -- "$STATE_FILE" 2>/dev/null)
  if [ -n "$last_state_commit" ]; then
    behind=$(git rev-list --count "${last_state_commit}..HEAD" -- "$@" 2>/dev/null || echo 0)
    case "$behind" in
      ''|*[!0-9]*) behind=0 ;;
    esac
    if [ "$behind" -gt "$MAX_SRC_COMMITS_BEHIND" ]; then
      REASONS="${REASONS}$(mk_msg ST_BEHIND "$(mk_dirs_human)" "$behind" "$MAX_SRC_COMMITS_BEHIND")"
    fi
  fi
fi

if [ -n "$REASONS" ]; then
  jq -n --arg ctx "$(mk_msg ST_TAIL "$REASONS")" \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
fi
exit 0
