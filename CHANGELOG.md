# Changelog

Every change to `hooks/`, `skills/`, `agents/` or `WORKING-MODEL.md` bumps `version` in `.claude-plugin/plugin.json` and adds an entry here (a pinned version means `/plugin update` delivers nothing otherwise).

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
