# Changelog

Every change to `hooks/`, `skills/`, `agents/` or `WORKING-MODEL.md` bumps `version` in `.claude-plugin/plugin.json` and adds an entry here (a pinned version means `/plugin update` delivers nothing otherwise).

## 0.5.2 — 2026-10-18
- Destructive-command guard: a quoted, escaped, prefixed or grouped command word no longer bypasses the rules (`"rm" -rf src`, `r""m`, `\rm`, `sudo rm`, `timeout 5 rm`, `{rm,-rf,src}`, `(cd src && git reset --hard)`, `git push -f&`, zsh `/bin/rm(N)`, `rm>/dev/null -rf x`). Every rule now also runs on a flat view of the command built in one linear `sed` pass (quotes and backslashes deleted, `( ) { }` and backticks blanked, glued `; | & < >` split); labels are only ever added.
- A computed command word right before an rm-style recursive option (`$RM -rf x`, `${RM:-rm} -rf x`, `/bin/r? -rf x`) counts as a recursive rm, without the build-directory safelist.
- Unique abbreviations count: `git push --fo…`, `git clean --fo…`, `git reset --ha…`, `rm --r…`; `helm un|del` and `docker volume remove` are matched.
- Fail closed, in bounded time: a command longer than 64 KiB, or with more than 1000 distinct rm segments, is denied as `too-large` (approval code still works); a flat view that cannot be built is denied as `unparsed`. `too-large` never hides `careful-state`: a big command that touches the approval file is still denied without an approval code. Every stage of the check fails closed: an awk, sed, grep, tr or jq that fails or prints nothing gives `unparsed` (the next stage falls back to the unprocessed text, a grep error counts as a match), careful-state is checked first, and labels are de-duplicated without awk. The guard checks labels in bash (a broken grep no longer reads as "no careful-state"), validates jq's deny and config output, and a tr or grep that fails or prints nothing gives careful-state. More spellings: wrapper `-n` (`nice -n 10 git clean -fdx`), command names in any case or with `.exe` (`RM -rf x`, `Git push -f`, `kubectl.exe delete`), `dropdb`, `mysqladmin … drop`, `pgcli`; `__pycache__` and `.pytest_cache` join the rm safelist. `git clean -f` is labelled even with `-n`/`--dry-run` (an option argument such as `-e -nx` read as a dry run let `git clean -fdx -e -nx` through). The grant-file check is case-insensitive and glob-aware: the name (`CAREFUL-GRANTS`, `careful?grants`, `careful*grants`) is never approvable, nor is a glob on a temp-located `memokit-` path (`/tmp/memokit-*`, `$TMPDIR/memokit-*`); other globs (`careful*`, `../memokit-*`) are the approvable `careful-state-glob`; every deny message lists all labels; and each awk/sed stage must echo a per-call sentinel line, so a tool printing plausible but constant output fails closed. The temp exemption skips commands over 4 KiB (1 KiB with a line continuation), which removed a quadratic slowdown that let the guard run past its 5 s timeout on 64 KB of continuations.
- Known false positives (accepted, ask for approval): quoted text is matched like a command (a commit message mentioning `git push --force` now asks too), and `"$EDITOR" -R file`-style computed words before an `-R`/`-r` option. Still out of reach (README, Limitations): `$X push -f`, `$(printf %s r m) -rf x`, `/bin/r(m|x)`, `$RM src -rf`, `DROP${IFS}TABLE`.

## 0.5.1 — 2026-10-18
- Linux portability: the `human_kb` test no longer fails on hosts without the `tr_TR.UTF-8` locale (bash's setlocale warning leaked into the captured output); no awk/mawk difference was found in the 0.5.0 code.
- shellcheck compatibility: `A && B || C` chains in `careful.sh` and `temp.sh` are explicit `if` statements, so older shellcheck releases (SC2015) pass.

## 0.5.0 — 2026-10-18
- Subagent temp-footprint gate: new SubagentStop hook `check-subagent-scratch.sh` blocks (up to 3 times) a subagent that leaves `scratch.agentMaxMB` (default 1024) or more of new files in the session scratchpad. `MEMOKIT_SCRATCH_OFF=1` disables it.
- Disk watch: new hook `check-disk.sh` (PreToolUse, PostToolUse and PostToolUseFailure on Bash, and Stop) warns when one command, failing or not, drops free space (min of the project and temp-root filesystems) by `disk.dropWarnGB` (10), warns below `disk.minFreeGB` (30; 0 = off), and at Stop points to `/memokit:sweep`. `MEMOKIT_DISK_OFF=1` disables it; SessionStart reports large temp leftovers (`scratch.reportMinMB`) and low disk.
- Config: new `scratch` (`agentMaxMB`, `staleAfterHours`, `reportMinMB`) and `disk` (`minFreeGB`, `dropWarnGB`) settings.
- Temp rules: WORKING-MODEL.md §7 (shell-agnostic copy recipe with literal `<paths>`, one scratchpad dir per task, delete before returning, `temp left:` line), the injected rule block and the `memokit:coder` / `memokit:reviewer` agents carry them.
- Destructive-command guard: recursive `rm` needs no approval only for a single simple `rm` of a literal direct child of the current session scratchpad or a whole stale sibling temp entry; commands containing NUL are denied.
- `/memokit:sweep`: measures stale temp leftovers, asks, deletes the approved ones one literal `rm -rf` at a time and reports the freed space.
- Destructive-command guard fixes (made after 0.4.0): backslash line continuations are joined before matching, SQL heredocs are flattened, and grant temp-file hygiene.

## 0.4.0 — 2026-10-06
- Destructive-command guard: new PreToolUse hook `guard-destructive.sh` with a builtin pattern set and project `careful.patterns`; denies with a single-use, 10-minute approval code that only the user's own message (`onay <code>` / `approve <code>` at its start) can grant; Edit/Write to the grant file are denied too. `MEMOKIT_CAREFUL_OFF=1` disables it; SessionStart warns about invalid project regexes; `/memokit:init` writes an empty `careful.patterns`.
- `/memokit:triage`: bulk triage of red/flaky tests into REGRESSION / FLAKY / ENV/DATA / UNKNOWN clusters with evidence, then root cause with a three-strike stop and a red-before-green fix slice; overlay `.claude/memokit/triage.md`; the debugging hint points to it.
- Decision format in WORKING-MODEL.md §2 (recommendation, stakes, one-way/two-way door, options, completeness); the rule block, `memokit:coder` and `/memokit:triage` use it.
- `memokit:coder` reports a bugfix slice's red output from before the fix; `memokit:reviewer` rejects a bugfix slice without it.

## 0.3.0 — 2026-10-01
- Code graph: optional `graph` setting (`root`, `maxCommitsBehind`, `refreshScript`). `/memokit:handoff` refreshes the graphify graph after its commit (code only, no LLM; a failure is a warning, not a failed handoff); the codebase-question hint reports measured staleness; `skills/handoff/scripts/memokit-graph.sh status|refresh`.
- Without `graph`, the graphify hint asks the user before building a graph instead of building one.
- `/memokit:init` offers the code graph with a measured recommendation and builds it.
- `/memokit:handoff` ends with a `PushNotification` (reaches the phone when Remote Control is connected); the context-budget message requires that step.

## 0.2.0 — 2026-09-29
- Migrations complete; equivalence harness removed.

## 0.1.1 — 2026-09-29
- Write guard covers git worktrees of the project (incl. Claude Code EnterWorktree); memokit activates when Claude is launched from a subdirectory; a legacy repo (`.claude/hooks`) launched from a subdirectory no longer gets the init hint.

## 0.1.0 — 2026-09-29
- First release: 8 hooks (write guard, subagent authority guard, rule/hint injection, session start with STATE + risk scan, STATE staleness, context budget with autonomous handoff, subagent background-work gate, precompact guidance), memokit:coder / memokit:reviewer, /memokit:init (new + migration), /memokit:handoff, /memokit:resume, JSON schema.
