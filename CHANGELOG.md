# Changelog

Every change to `hooks/`, `skills/`, `agents/` or `WORKING-MODEL.md` bumps `version` in `.claude-plugin/plugin.json` and adds an entry here (a pinned version means `/plugin update` delivers nothing otherwise).

## 0.2.0 — 2026-09-29
- Migrations complete; equivalence harness removed.

## 0.1.1 — 2026-09-29
- Write guard covers git worktrees of the project (incl. Claude Code EnterWorktree); memokit activates when Claude is launched from a subdirectory; a legacy repo (`.claude/hooks`) launched from a subdirectory no longer gets the init hint.

## 0.1.0 — 2026-09-29
- First release: 8 hooks (write guard, subagent authority guard, rule/hint injection, session start with STATE + risk scan, STATE staleness, context budget with autonomous handoff, subagent background-work gate, precompact guidance), memokit:coder / memokit:reviewer, /memokit:init (new + migration), /memokit:handoff, /memokit:resume, JSON schema.
