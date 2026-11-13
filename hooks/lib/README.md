# hooks/lib — shared hook library

`common.sh` is sourced by every hook in `hooks/*.sh`; it is never executed
directly. `config.jq` is the config-parsing/validation program `mk_load_config`
runs via `jq -r -f`.
`graph.sh` (code-graph staleness) is sourced after `mk_load_config` by
`inject-rules.sh` and `skills/handoff/scripts/memokit-graph.sh`, so the hint and
the handoff refresh share one definition of "stale".
`temp.sh` (Claude Code's per-session temp tree and free disk space) is sourced
after `common.sh` by the scratch/disk hooks (`check-subagent-scratch.sh`,
`check-disk.sh`, `session-start.sh`), by `guard-destructive.sh` for the
`rm -rf` exemption of spec 3b that `careful.sh` applies, and by the sweep CLI,
so they all locate the temp tree, measure a footprint and decide "stale" the
same way. Callers run
`mk_load_config` first (staleness reads `MK_SCRATCH_STALE_HOURS`), then
`mk_temp_init "$PAYLOAD"`; the live measurements it relies on are recorded in
its header.
`transcript.sh` (0.8.1) is the one reader of Claude Code session transcripts
(JSON Lines), sourced after `common.sh` by `check-context-budget.sh` (tail
only, every Stop: `mk_tr_context_used FILE 500`), the handoff's
`memokit-stats.sh` and `/memokit:learn` (whole file, once). Programs get the
shared jq defs (`mk_tr_records`, `mk_tr_context`, `mk_tr_tool_uses`,
`mk_tr_tool_results`, `mk_tr_hook_deny`) through `mk_tr_jq` / `mk_tr_jq_tail`:
lines are parsed one by one so a half-written last line is dropped, only
objects are records, and whole-file readers keep `reduce` state so memory
does not grow with the file. `mk_tr_locate` finds this session's transcript.
Its header records the measured record shapes (split assistant records that
repeat one usage, tool_use/tool_result blocks, the two hook-deny forms).
`integrity.sh` (0.8.1) is the runtime integrity check, sourced after
`common.sh` by `check-integrity.sh` (PreToolUse on every tool; Post,
PostToolUseFailure and SubagentStop for subagents), `record-permission.sh`
(PermissionRequest; records suggested allow rules, never decides) and
`inject-rules.sh` (the one-time prompt notices). Pre writes a record (time,
copy of small settings files, one digest line per protected file:
`crc:size:mode:inode:ctime`) under the session's temp prefix, careful-state by
name; Post and SubagentStop compare. A change leaves a marker the subagent
block, the one-time main-session deny and the prompt notice each consume.
It restores nothing. The header lists every state file and the plugin scope
rules (`--plugin-dir` project exemption); `budget.sh` arms it with
`MK_BUDGET_EVENT` so a timeout on Post is a reported change.
`worktrees.sh` (leftover worktrees under `.claude/worktrees/` and `mk/*`
branches) is sourced after `common.sh` by `session-start.sh` (`mk_wt_count`)
and the sweep CLI (`mk_wt_list`); it is read-only and documents its statuses
in its header.
`budget.sh` (0.8.0 final wave) is the hard time budget of the three
PreToolUse guards (`guard-destructive.sh`, `guard-subagent-authority.sh`,
`guard-edit.sh`): `mk_budget_arm WALL CPU DENY_KEY CRASH_KEY [strict|zero]`
arms a wall-clock watchdog, a CPU limit and the TERM/XCPU/EXIT traps; every
deny goes through `mk_budget_deny_json` / `mk_budget_static_deny` (decided,
then printed), so a decision is printed exactly once. Mode `zero` lets an
`exit 0` with no output through (the two guards whose allow is a bare exit);
`strict` denies any exit before a printed decision. A guard must not run a
foreground child (a pipeline or external command outside `$(...)`) before
it arms, or bash 3.2 stops honouring the CPU limit in the hook process
(measured; the header says more). `mk_strip_heredoc_bodies` (common.sh) is
the one-awk heredoc-body strip of `guard-edit.sh` and the subagent guard.
`remote.sh` (0.8.0 remote changes) is sourced after `common.sh` and
`careful.sh`, whose views, segment splitter and exemption rules it reuses. With
a `remote` config object (`MK_REMOTE_ENABLED=1`) it labels deploy pushes,
remote-host changes, cluster mutations, runbook runs and project patterns that
carry a `target`, and extracts each command's targets (`host:`, `branch:`,
`k8s[:ctx]`, `runbook:<path>@<sha256>`, `pattern:`) for the change window:
`mk_remote_scan`, `mk_remote_targets`, `mk_remote_strip_covered`,
`mk_remote_covered_only` (the guard's window-pass check: shape, bare command
word, option allowlists), `mk_remote_target_valid`, `mk_remote_runbook_target`.
A command that can carry no remote label at all is not scanned and never
bounded here, so a long heredoc writing a file stays unlabelled; that is
decided on the normalised text the views see (continuations joined,
quotes and backslashes deleted, `.exe` dropped, lower-cased): no tool
word, no configured host or deploy branch name, no runbooks dir basename
and none of `$ \` * ? [`. ANSI-C quoted spans (`$'\x73sh'`) are decoded
into a view of their own before matching; otherwise a command past a structural
bound (`MK_RM_MAX_*`: 8 KiB, a 4 KiB segment, 40 segments (`MK_RM_MAX_SEGS`;
not to be confused with the guard's window-pass cap `MK_GD_MAX_STRIP`, 20
segments), 32 tool words, 64 quote characters) is labelled `too-large` and
not parsed, and a segment
whose tool words times tokens exceeds `MK_RM_MAX_WORK` is `unparsed`. One scan serves the guard's labels, targets
and window pass (`mk_remote_scan_checked` keeps the last result, keyed by
the command text); the window pass scans each segment once more and returns
those segments' labels on its first output line. Its header lists the
read-only ssh commands (nothing that can change the server or run another
program: no `env`, `find`, `curl`, `git log`, ...) and the exemptions, each
of which holds only when every option is understood. `_mk_cf_labels` appends
its labels (through `mk_remote_scan_checked`, whose sentinel turns a scan that
dies half way into `unparsed`) and loads `remote.sh` itself when the caller has
not; if that fails it prints `unparsed` (fail closed).
Limitations: the subagent config gate (`guard-subagent-authority.sh`: the
`.claude/memokit.json` allowlist, the hooks-path and window-request rules) is
lexical. Subagent hooks judge by a session-start copy of the config (a change
shows one notice; `/clear` or a new session adopts it), which is one more
layer, not a tamper-proof one: it is a same-user file in the temp dir. A
runtime check of the protected files (`integrity.sh`, above) reports what
the text check misses, after the call. The
settings-file gate has its own residual classes: paths assembled from pieces
at run time, link makers other than `ln`, `cp -s` and `symlink` in the same
command (archive extraction), copies of `session-start.sh` under another
name or behind a bare variable (`bash $S`; the session-start rule reads the
last path component of each word, a glob or expansion included, and never
the filesystem), and interpreter writes to comma-named links. The guard
runs with `set -f`; a glob command word or cd target is expanded on its own.
Not seen: recursive tools run from the root (`find . -name '*.json'
-exec sed -i ...`, `grep -rl ... | xargs sed -i`, `chmod -R a-w .`),
parameter-default spellings (`.${X:-c}laude`), and `cd -` / `cd ~-` (the
previous directory is not tracked). Bounds (`MK_GS_MAX_*`, guard header):
a subagent command over 64 KiB, or with more than 512 words holding `..`, a
dollar sign or a backquote, or brace groups, or more than 16 384 paths for
the device:inode test, is too large (`GS_TOO_LARGE`); a brace word past 64
alternatives, more than 1 024 alternatives, a letter range, a nested brace
or more than 8 literal `cd` targets is a config reference (fail closed).
Limitations: it is text matching. A command run through computed words that
name nothing in the text is not seen. For example, `$G $P` with `G=git
P=push` on a deploy branch passes: no deploy branch, configured host or
verb (`push`, `merge`, `apply`, `rollout`, `delete`, `scale`, `patch`,
`upgrade`, `uninstall`, `exec`, as whole words once the token's quotes,
brackets, commas and backslashes are stripped; `src/push.ts`, `x=delete`
and `$'delete'` are not verbs) is written in the segment. This is the same
gap as a plain `git push` made through a computed verb. A command word
holding a command substitution (`$(cat cmd) origin deploy`), also as the
first word after `sudo`, `env`, `nice`, `timeout` and the other wrappers of
`MK_RM_WRAPPERS`, is always labelled; a wrapper option this file does not
know may hide one. The read-only ssh exemption refuses any `$` in the remote
command (`ssh h 'cat $HOME/x'` is labelled): whether a `$` sits in single
quotes cannot be told under heredocs, `#` comments or a shell around ssh.
Any `NAME=value` word before `git` or `gh` in the same segment (`HOME=`,
`PATH=`, `EDITOR=`, `GIT_*=`, `GH_TOKEN=`; only `LANG`, `LC_*`, `TZ`, `TERM`,
`COLUMNS`, `LINES`, `NO_COLOR`, `GIT_TRACE*` and `GIT_PAGER=cat` are
excepted), `--git-dir` / `--work-tree`, any `-c` key or `git config` write
outside an exact list of harmless keys (`user.name`, `user.email`,
`user.signingkey`, `color.*`, `advice.*`, `gpg.format`, ...; never a key
holding `command`, `program`, `cmd`, `helper`, `path` or `hook`), labels
the command with every deploy branch: git config can run commands or
redirect remotes. So `git config --global --add safe.directory /x` and
`GH_TOKEN=x gh pr list` need a window. An `export NAME=value` in an earlier
segment is not seen; an alias set there (or in the global config) is seen
only as a subcommand git does not have, which is taken as a push when a
deploy branch is named in the same segment (`git p origin deploy`), not
when the branch comes from the current HEAD or upstream (`git p origin`).
`gh api` is labelled for a writing method, a body option or a merge,
dispatch or ref path; a computed path with a plain GET is a read.
Accepted limitations of the window pass (`mk_remote_covered_only`), not
fixed: local code staged before the window runs inside it: a
`.git/hooks/pre-push` hook on a covered `git push`, a directory on `PATH`
shadowing `ssh`, the local file of `kubectl create secret
--from-file=<local>`, the body of `gh pr merge --body-file <local>` (the
guard checks the command text, not the files it names). `rsync --delete
<host>:/empty/ ./` is a download whose damage is local: it is not a remote
change and passes as one. `ssh -- host -F cfg` passes on the assumption that
OpenSSH does not parse options after `--`. Inside a window `git push` must
name the remote and the branch explicitly (`git push origin deploy`): the
remote must be a name `git remote` prints for the project root (no URL, no
path) and a bare `git push` (implicit upstream) is refused; `git push`
without `-C`, `gh pr merge` and `gh workflow run` pass only when the
payload `cwd` belongs to the project repository (same `git-common-dir` as
the root, toplevel the root or a listed worktree; a nested repository
under the root is not), and gh's positional words may hold no `/` or `:`. A runbook path
is resolved against the payload `cwd`, must be a file under the configured
runbooks directory whose hash the window holds, and its invocation must be
the only segment of the command (another segment could rewrite the file
first).

The change-window and pending-approval state files (`careful-window-*`,
`careful-pending-*`, in the temp dir) are plain text the user's own shell can
write. `careful.sh` limits what a hand-written file buys: an expiry later
than a writer could have set (window: now + 240 min; pending line and
request record: now + `MK_CF_TTL`) is malformed on read (the file is
removed), and a command that names a state path literally, or writes to a
computed `memokit-`/`careful-` word while naming a temp location, is
`careful-state`, never approvable (a computed write without a temp location
is `careful-state-glob`, approvable with a code). The markitdown cache
(`careful-convert`, a directory; `convert-read.sh`) is in the same family:
named in a Bash command it is `careful-state`, and a subagent file-tool
write anywhere below it is denied (`guard-subagent-authority.sh`).
Considered and rejected: HMAC on state files. A secret that hooks can read
is readable by the model's own Bash under the same user, so a keyed hash
adds no barrier against the only attacker in this model.

Every hook in this plugin starts with one of the two canonical preambles
below, copied verbatim (only `<hook-name>` changes). This keeps the gate
order — kill switch / config load / activation — identical across every
hook, which is the property the tests in `tests/preamble.bats` enforce.

## Guard preamble

Used by the two fail-closed guards: `guard-edit.sh` and
`guard-subagent-authority.sh`. These hooks must deny on any "cannot
classify" path, so config loading happens inline and a `jq`-missing /
invalid-config condition itself produces a `deny` JSON payload instead of
silently exiting 0.

```bash
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_guard_off && exit 0
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "<hook-name>" "$PAYLOAD"
if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg CONFIG_NO_JQ_STATIC)"
    exit 0
  fi
  jq -n --arg r "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
```

Gate order, and why it cannot be reordered: the kill switch (`mk_guard_off`)
is checked before `mk_resolve_root`/`mk_active` so `MEMOKIT_GUARD_OFF=1` is a
true unconditional override, independent of whether a project root or config
can even be found. `mk_active` (no `.claude/memokit.json`) still exits 0
silently — the activation gate applies before config loading is attempted.

## Non-guard preamble

Used by every other hook (session-start.sh deviates from this, see Task 7 —
it must still print the init hint when the project is inactive).

```bash
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "<hook-name>" "$PAYLOAD"
mk_load_config || exit 0
```

These hooks are fail-open: any of the gates above simply exits 0 with no
output, since a hint or side-effect hook must never block Claude Code.

## Message text transformation rules

Applied to every user-visible string ported from a legacy hook into
`hooks/messages/en.sh` / `hooks/messages/tr.sh`:

- `CLAUDE.md §0` → `WORKING-MODEL.md §1`
- `CLAUDE.md §2` → `WORKING-MODEL.md §4`
- `coder.md kural 0` → `memokit:coder kural 0`
- `subagent_type:"coder"` / `subagent_type:coder` → `subagent_type:"memokit:coder"`
- `/handoff` → `/memokit:handoff`
- `resume skill'i` → `/memokit:resume`
- every literal guarded-dir enumeration (`src/, tests/, web/ ve mobile/`,
  `src/ tests/ web/ mobile/`, `src/, tests/, web/ veya mobile/`, `src/tests`)
  → `%s` filled by `mk_dirs_human`
- legacy `<PREFIX>_*` env knobs → `MEMOKIT_*`
- `[<PREFIX>-` → `[@TAG@-`

No project names may appear in ported comments or messages outside `docs/`;
legacy comments that cite one are rewritten generically (e.g. "a real
incident in a production repo", "<Project>.Web").

## Sanitizing external process output (inject-rules.sh graphify gate)

A hook's no-`jq` fallback JSON is hand-written (`printf` with a literal
format string), which is only safe when the interpolated value is known in
advance to contain no `"`, no `\`, and no control characters -- that is
exactly what the `_STATIC` message-key contract guarantees for this repo's
own strings. `inject-rules.sh`'s graphify-staleness gate text does not come
from this repo's own strings, though: it is the first line of output from an
external script (`scripts/graph-staleness.sh`), a boundary this repo cannot
enforce by contract alone. The hook does not trust that script to already
produce safe output -- it explicitly strips quotes, backslashes, and C0
control characters (`ESC`, tab, ...) from that line before using it anywhere,
even though today's call site (jq is available) does not strictly need it
yet, so the sanitizing survives unchanged if that call site ever changes.
`LC_ALL=C` is required for the strip: without it, `tr` can corrupt
multi-byte UTF-8 sequences (e.g. Turkish `ş`, `ğ`) under a UTF-8 locale,
whereas restricting the strip to the `0x00`-`0x1F` byte range is safe under
`LC_ALL=C` because every byte of a multi-byte UTF-8 sequence is `>= 0x80`.
