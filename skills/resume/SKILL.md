---
name: resume
description: Only in projects that have .claude/memokit.json — continue where the last session stopped; use the injected docs/STATE.md, pick the single next step, check health, confirm with the user in one sentence, then delegate. Use when the user says /resume, "devam et" or "continue".
---

# Resume — session open ritual

Talk to the user in the project `language` (`.claude/memokit.json`).

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here and use the project's own resume skill/ritual instead. Do nothing else from this skill.
1. **STATE.** The SessionStart hook already injected `docs/STATE.md`. If it did, do **not** read it again.
2. **Pick the single next step.** If STATE says "ÖNCE KONUŞ, KOD YAZMA" / "TALK FIRST, NO CODE" or "decision pending", do not start implementing — ask the user with your recommendation and rationale (read only the referenced `docs/HISTORY.md` section). If an unfinished council exists (`.council/<dir>/`), close it first.
3. **Read only what you need:** the relevant section of the roadmap/patterns docs the project uses, the slice spec/plan. Never read `docs/HISTORY.md` end to end.
4. **Health.** If `sessionStart.healthScript` is configured, the hook already ran it; report warnings without blocking.
5. **Project steps.** If `.claude/memokit/resume.md` exists, read it and apply it now.
6. **Confirm the plan with the user in one sentence**, then start.
7. **Don't write code.** Delegate to `memokit:coder`, review with `memokit:reviewer`, then **run the tests yourself** (WORKING-MODEL.md §3) — a subagent report is a claim.

## Don't
- Read `docs/HISTORY.md` or trawl archives.
- Pass a decision point without asking the user.
- Treat a "TALK FIRST" item as the next step to implement.
