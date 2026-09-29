#!/usr/bin/env bash
# PreToolUse hook: block subagents from exceeding their authority.
#
# Subagents may NOT commit, merge, delete branches, rewrite history, touch the
# remote, or delegate work to another agent (WORKING-MODEL.md §1,
# agents/coder.md rule 0 (memokit:coder)). Those rules were written as TEXT
# first and violated 7 times anyway -- twice AFTER the rules were in place
# (a real incident in a production repo: one agent committed + merged to
# master + deleted its branch without permission, another delegated and
# returned early). Text did not hold; this is the mechanism. Sibling of
# guard-edit.sh, which enforces the inverse rule (main session may not write
# src/ or tests/).
#
# The orchestrator (main session) is unaffected -- it is the one that IS
# supposed to commit and to spawn agents.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
# Hard kill-switch for emergencies, same lever as guard-edit.sh. Hooks run as
# a process separate from the Claude Code session, so this variable must be
# in the environment Claude Code itself passes to hooks -- e.g. "env":
# {"MEMOKIT_GUARD_OFF": "1"} in .claude/settings.local.json, or exported
# before launching `claude`; exporting it inside a Bash tool call does not
# reach hooks. Checked before anything else, including the empty-payload
# branch right below, so the kill switch is a true unconditional override.
mk_guard_off && exit 0
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "guard-subagent" "$PAYLOAD"
if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg CONFIG_NO_JQ_STATIC)"
    exit 0
  fi
  jq -n --arg r "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# Empty stdin used to be treated as "the knowledge-health smoke test, nothing
# to classify". That premise was checked and is false: knowledge-health-style
# fallback fixtures for hooks without a dedicated case send `{}`, not empty
# stdin, and this hook has no dedicated case of its own either way. So this
# branch protected nothing and only ever fired when stdin genuinely could not
# be read (a broken pipe, `cat` missing from PATH, ...) -- the same failure
# mode guard-edit.sh had, confirmed live there. Empty stdin now denies. The
# only sanctioned way to get the old "stay silent" behaviour is the explicit
# MEMOKIT_KH_SMOKE=1 escape hatch, kept as a documented, explicit-opt-in
# escape rather than an implicit one.
# This message is fixed text with nothing interpolated, so a hand-escaped
# static JSON literal is safe here -- deny() is not defined yet at this point
# and itself depends on jq, which is exactly the kind of dependency an
# "stdin could not be read" path should not add.
if [ -z "$PAYLOAD" ]; then
  if [ "${MEMOKIT_KH_SMOKE:-0}" = "1" ]; then
    exit 0
  fi
  printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg GS_EMPTY_STDIN_STATIC)"
  exit 0
fi

deny() {
  # $1: localized (mk_msg-rendered) reason shown to the operator. May embed
  # the offending command, which is model-controlled text, so it MUST be
  # JSON-escaped by jq rather than interpolated with printf %s -- an embedded
  # double quote would produce unparseable JSON, and Claude Code silently
  # ignores unparseable hook output, which would lose the deny and let the
  # action through. Same reasoning and same fallback as guard-edit.sh's
  # deny().
  DENY_JSON="$(jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null)"
  # shellcheck disable=SC2181  # $? here is jq's, from the command
  # substitution just above -- checking it directly would require
  # restructuring this into `if DENY_JSON=$(jq ...); then`, losing the
  # ability to also check `[ -n "$DENY_JSON" ]` in the same condition.
  if [ $? -eq 0 ] && [ -n "$DENY_JSON" ]; then
    printf '%s\n' "$DENY_JSON"
  else
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg GS_JQ_FAILED_STATIC)"
  fi
  exit 0
}

# Fail-closed: non-empty stdin that is not valid JSON -- cannot classify, so
# cannot allow.
if ! printf '%s' "$PAYLOAD" | jq -e '.' >/dev/null 2>&1; then
  deny "$(mk_msg GS_INVALID_JSON)"
fi

# Subagent detection. Identical discriminator to guard-edit.sh: the main-thread
# payload carries no agent_id, a subagent payload carries the id the Agent tool
# returned. agent_type is deliberately NOT used -- a subagent could name itself
# anything, while agent_id is assigned by the harness.
IS_SUB="$(printf '%s' "$PAYLOAD" | jq -r 'if (.agent_id // "") != "" then "sub" else "main" end' 2>/dev/null)" || \
  deny "$(mk_msg GS_SUBAGENT_CHECK_FAILED)"

# The orchestrator is allowed to do all of this -- that is its job.
[ "$IS_SUB" = "main" ] && exit 0

TOOL="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null)" || \
  deny "$(mk_msg GS_TOOL_NAME_EXTRACT_FAILED)"

# --- Rule 1: no delegation. A subagent must do its own work. -----------------
# Observed failure: agent spawns a child, reports "started in the background",
# returns with an empty working tree. Worse, the parent then re-does the work
# -- a real incident: two writers raced on the same files.
# SendMessage is included alongside Agent/Task: it resumes an EXISTING agent
# with its full context intact, which is the same "hand my work to another
# agent" action this rule blocks -- only the entry point differs (spawning a
# new one vs. continuing one that already exists).
case "$TOOL" in
  Agent|Task|SendMessage)
    deny "$(mk_msg GS_NO_DELEGATION)"
    ;;
esac

# --- Rule 2: no commit / merge / branch deletion / history rewrite / remote
#     mutation / stash. --------------------------------------------------------
[ "$TOOL" = "Bash" ] || exit 0

CMD="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null)" || \
  deny "$(mk_msg GS_CMD_EXTRACT_FAILED)"
[ -z "$CMD" ] && exit 0

# Heredoc BODY lines are DATA, not commands -- a subagent writing a doc or a
# test fixture via `cat > docs/x.md <<'EOF' ... EOF` can legitimately contain
# example text such as "git commit -m x" inside the body purely as
# illustration. Without stripping heredoc bodies first, the segment-based
# scan below would treat that documentation text as a real command and
# false-positive deny it. Detects `<<MARKER`, `<<-MARKER`, `<<'MARKER'`, `<<"MARKER"`,
# `<<\MARKER` and drops every line from the one after the opener up to (and
# re-including) the line that is exactly the bare marker (leading tabs
# stripped first when the `<<-` form was used, matching real shell
# semantics). Heuristic gap, accepted: a marker containing shell
# metacharacters beyond the ones stripped here, or two heredocs opened on the
# same line, are not specially handled -- under-detection only (a body line
# that happens to look exactly like a real ban-worthy command would then
# still be scanned), never an over-denial.
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
CMD="$(strip_heredoc_bodies "$CMD")"

# `bash -c "..."` / `sh -c "..."` / `zsh -c "..."` / `dash -c "..."` run their
# argument as a nested command line -- `bash -c "git commit -m x"` must be
# caught exactly like a bare `git commit -m x`. Extracted here (once, on the
# whole command) rather than during segment tokenization below, because the
# inner command's own internal spaces would otherwise be destroyed by the
# same whitespace-only tokenization used to find it. The extracted text is
# appended as extra lines so it goes through the exact same segment/tokenize/
# git-detect pass as everything else, INCLUDING its own `;`/`&&`/heredocs.
# Heuristic, not a parser: only the first `-c ` occurrence on the whole
# command is honoured, and only one layer of surrounding quote is stripped
# (an escaped same-type quote INSIDE the inner command, e.g.
# `bash -c "git \"commit\""`, is not specially unescaped). Under-detection
# only -- a form this misses simply is not scanned, it is never wrongly
# flagged as a result of this step.
extract_dash_c_inner() {
  c="$1"
  # `bash`, `zsh`, and `dash` all happen to END in "sh", so a single
  # substring check for "sh -c " already covers `bash -c `, `zsh -c `,
  # `dash -c ` and plain `sh -c ` -- listing them separately would be dead
  # pattern duplication (shellcheck SC2221/SC2222 flagged exactly this).
  # Trade-off: any OTHER command ending in "sh" followed by " -c " (a custom
  # script literally named "*sh") would also match; harmless false-trigger,
  # since it only leads to scanning some extra text that will not contain a
  # `git` invocation.
  case "$c" in
    *'sh -c '*) : ;;
    *) printf '%s' ""; return ;;
  esac
  inner="${c#*-c }"
  case "$inner" in
    \"*) inner="${inner#\"}"; inner="${inner%%\"*}" ;;
    \'*) inner="${inner#\'}"; inner="${inner%%\'*}" ;;
  esac
  printf '%s' "$inner"
}
INNER_CMD="$(extract_dash_c_inner "$CMD")"
[ -n "$INNER_CMD" ] && CMD="$CMD
$INNER_CMD"

# Split into segments on shell separators so `foo && git commit` is inspected
# as its own command, not as an argument to foo. `(`, `)`, `{`, `}` and a
# backtick are ALSO separators here -- not because they terminate a command
# the way `;`/`|`/`&` do, but because splitting on them has the same net
# effect for detection purposes: `( git commit -m x )`, `{ git commit -m x;
# }`, and `` `git commit -m x` `` all reduce to a segment whose first word is
# `git`, with no extra handling needed. `$(...)` is covered too, since its
# `(` and `)` are among the same separator characters (`echo $(git commit -m
# x)` splits into "echo $" and "git commit -m x"). Measured before this fix:
# 7 of 8 phrasings of `git commit -m x` walked straight through denying only
# the bare form -- `( ... )`, `{ ...; }`, `$(...)`, backticks, `if/then`,
# `bash -c`, and `xargs` all allowed. All 8 are covered now (the `bash -c`
# and `xargs` forms need the extra handling above/below, not just the wider
# separator set).
#
# This remains deliberately coarse: it is a guard against the INSTINCTIVE
# violation, not a sandbox. An agent that actively WANTS to evade it --
# invoking git through a variable, a wrapper script, an alias, or an
# interpreter this scan does not special-case -- still can. The point is
# that the accidental "I'll just finish the job" commit is stopped, not that
# every possible indirection is closed.
# shellcheck disable=SC2020  # intentional: each of \n;|&(){}` is meant to
# map to a newline individually (a set-to-set translation), not as a
# multi-char "word" -- the duplicate targets are the point, not a mistake.
SEGMENTS="$(printf '%s' "$CMD" | tr '\n;|&(){}`' '\n\n\n\n\n\n\n\n\n')"

while IFS= read -r SEG; do
  [ -z "$SEG" ] && continue
  # Intentional word splitting to tokenize. This is a heuristic,
  # whitespace-only split, not a real shell parser -- a quoted argument
  # containing a space is mis-tokenized. Accepted gap: under-detection here
  # means a missed deny, never a false deny.
  # shellcheck disable=SC2086
  set -- $SEG
  # `git` must be the COMMAND of this segment, not merely a word inside it --
  # otherwise `echo git commit is a phrase` would be denied (measured: it
  # was, before the COMMAND-position check existed). Skip leading VAR=val
  # assignments, the usual wrapper prefixes, `xargs` (so `echo x | xargs git
  # commit -m` is caught -- measured before this fix: it was not), and a
  # handful of shell keywords that can legitimately precede a command word
  # after the `;`/`(`/`{` split above (`if true; then git commit -m x; fi`
  # splits into a segment starting with `then`, which must be skipped past
  # to reach `git`; measured before this fix: it was not caught).
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;                                  # VAR=val prefix
      env)
        # `env` takes its own options before the command (`env -i git
        # commit`, `env -u HOME git commit`): consume them, including the
        # separate value of the ones that take one, so the command word
        # after them is still found. Accepted gap: `env -S 'git commit'`
        # packs the command into one quoted argument, which this
        # whitespace tokenizer cannot see into (under-detection only).
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|-C|-P|-S|--unset|--chdir|--split-string) shift 2 2>/dev/null || shift $# ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        ;;
      sudo|nohup|time|command|builtin|xargs) shift ;;  # wrapper prefixes
      then|do|else|elif|'{'|'('|'!') shift ;;         # shell keywords
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && continue
  case "$1" in
    git|*/git) shift ;;   # consume `git` itself
    gh|*/gh)
      # GitHub CLI: merging a pull request merges on the remote -- the same
      # authority as `git merge` + `git push`, which a subagent does not
      # have. Read-only forms (`gh pr view`, `gh pr diff`, ...) stay allowed.
      if [ $# -ge 3 ] && [ "$2" = "pr" ] && [ "$3" = "merge" ]; then
        deny "$(mk_msg GS_GH_PR_MERGE "$SEG")"
      fi
      continue
      ;;
    *) continue ;;        # this segment does not run git -- nothing to check
  esac

  # Skip git's global options so `git -C /repo commit` is caught too. The
  # option forms that take a SEPARATE argument (-C dir, -c key=val, and the
  # separated spellings --git-dir <dir>, --work-tree <dir>, --namespace
  # <name>, --config-env <name>=<env>) must consume that argument as well,
  # or the value would be mistaken for the subcommand.
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--config-env) shift 2 2>/dev/null || shift $# ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-p|--paginate|--no-pager|--bare) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 0 ] && continue

  SUBCMD="$1"; shift
  case "$SUBCMD" in
    commit)
      # --dry-run / --short / --porcelain are read-only PREVIEWS of what
      # WOULD be committed -- they create no commit. Whitelisted so a
      # subagent can legitimately inspect its own staged changes before
      # reporting back. Any other form of `commit` is still denied.
      case " $* " in
        *' --dry-run '*|*' --short '*|*' --porcelain '*) continue ;;
      esac
      deny "$(mk_msg GS_COMMIT "$SEG")"
      ;;
    merge)
      deny "$(mk_msg GS_MERGE "$SEG")"
      ;;
    push)
      # No read-only form of push exists -- it always mutates the remote.
      # `git push origin --delete feat` deletes a REMOTE branch, strictly
      # worse than the local `branch -d` already blocked below -- measured
      # before this fix: unrestricted (both plain push and --delete allowed).
      deny "$(mk_msg GS_PUSH "$SEG")"
      ;;
    rebase)
      deny "$(mk_msg GS_REBASE "$SEG")"
      ;;
    revert)
      # Creates a new commit (or leaves a half-applied revert in progress).
      deny "$(mk_msg GS_REVERT "$SEG")"
      ;;
    pull)
      # fetch + merge/rebase into the current branch: can create merge
      # commits or rewrite local history, in every form.
      deny "$(mk_msg GS_PULL "$SEG")"
      ;;
    am)
      # Applies a mailbox of patches as commits.
      deny "$(mk_msg GS_AM "$SEG")"
      ;;
    filter-branch)
      deny "$(mk_msg GS_FILTER_BRANCH "$SEG")"
      ;;
    commit-tree)
      # Plumbing that creates a commit object (the building block of a
      # hand-rolled commit together with update-ref).
      deny "$(mk_msg GS_COMMIT_TREE "$SEG")"
      ;;
    reset)
      # memokit:coder's own rule bans `git reset` outright (not just --hard),
      # so this hook is made to match that claim exactly rather than trying
      # to carve out a "soft reset is harmless" exception it does not grant.
      deny "$(mk_msg GS_RESET "$SEG")"
      ;;
    checkout|switch)
      # A subagent switching to (or creating) ANOTHER branch is the exact
      # violation memokit:coder bans ("checkout <other-branch>"). Restoring a
      # FILE from the index/another ref via the `--` end-of-options marker
      # (`git checkout -- path`, `git checkout HEAD~1 -- path`) does not
      # change what branch HEAD points at, so it is allowed -- a local,
      # reversible, single-file operation a coding agent legitimately needs
      # (e.g. to back out its own failed experiment on one file). Measured
      # before this fix: `git checkout other-branch` was allowed outright.
      HAS_DASHDASH=0
      for ARG in "$@"; do
        [ "$ARG" = "--" ] && HAS_DASHDASH=1
      done
      if [ "$HAS_DASHDASH" -eq 1 ] || [ $# -eq 0 ]; then
        continue
      fi
      deny "$(mk_msg GS_BRANCH_SWITCH "$SEG")"
      ;;
    stash)
      # Stash is destructive to parallel subagent work: a second agent's
      # `stash pop` can clobber or hide a first agent's uncommitted changes.
      # Denied in every form (push, pop, apply, drop, list, ...), not just
      # the mutating ones, since a subagent has no legitimate need to touch
      # stash at all. Measured before this fix: allowed outright.
      deny "$(mk_msg GS_STASH "$SEG")"
      ;;
    cherry-pick)
      deny "$(mk_msg GS_CHERRY_PICK "$SEG")"
      ;;
    clean)
      deny "$(mk_msg GS_CLEAN "$SEG")"
      ;;
    tag)
      # Only deletion is blocked; `git tag` (list) and `git tag <name>`
      # (create) are harmless and denying them would break ordinary use.
      for ARG in "$@"; do
        case "$ARG" in
          -d|-D|--delete|--delete=*)
            deny "$(mk_msg GS_TAG_DELETE "$SEG")"
            ;;
        esac
      done
      ;;
    update-ref)
      # Only deletion (-d) is blocked; creating/updating a ref is out of
      # scope for this rule (it is not history rewriting or destruction).
      for ARG in "$@"; do
        case "$ARG" in
          -d) deny "$(mk_msg GS_REF_DELETE "$SEG")" ;;
        esac
      done
      ;;
    worktree)
      # Only `remove` is blocked; `worktree list`/`add` are not destructive.
      if [ $# -gt 0 ] && [ "$1" = "remove" ]; then
        deny "$(mk_msg GS_WORKTREE_REMOVE "$SEG")"
      fi
      ;;
    branch)
      # Deletion, force-moving (-f/--force: `git branch -f main HEAD~3`
      # rewinds main) and renaming (-m/-M/--move) are blocked; `git branch`
      # (list), `git branch -a` and `git branch <name>` are harmless
      # reads/creates, and denying them would break ordinary inspection.
      for ARG in "$@"; do
        case "$ARG" in
          -d|-D|--delete|--delete=*|-dr|-Dr)
            deny "$(mk_msg GS_BRANCH_DELETE "$SEG")"
            ;;
          -f|--force|-m|-M|--move)
            deny "$(mk_msg GS_BRANCH_FORCE "$SEG")"
            ;;
        esac
      done
      ;;
  esac
done <<EOF
$SEGMENTS
EOF

exit 0
