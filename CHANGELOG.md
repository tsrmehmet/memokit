# Changelog

Every change to `hooks/`, `skills/`, `agents/` or `WORKING-MODEL.md` bumps `version` in `.claude-plugin/plugin.json` and adds an entry here (a pinned version means `/plugin update` delivers nothing otherwise).

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
