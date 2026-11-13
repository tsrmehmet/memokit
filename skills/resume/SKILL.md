---
name: resume
description: Only in projects that have .claude/memokit.json — continue where the last session stopped; use the injected docs/STATE.md, pick the single next step, check health, confirm with the user in one sentence, then delegate. Use when the user says /resume, "devam et" or "continue".
---

# Resume — session open ritual

Talk to the user in the project `language` (`.claude/memokit.json`).

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here and use the project's own resume skill/ritual instead. Do nothing else from this skill.
1. **STATE.** The SessionStart hook already injected `docs/STATE.md`. If it did, do **not** read it again.
2. **Pick the single next step.** If STATE says "ÖNCE KONUŞ, KOD YAZMA" / "TALK FIRST, NO CODE" or "decision pending", do not start implementing — ask the user with your recommendation and rationale (read only the referenced `docs/HISTORY.md` section). If an unfinished council exists (`.council/<dir>/`), close it first.
   **Active parallel run.** If a `.claude/memokit/runs/*/ledger.md` has `status: active` (a run not yet closed; a `status: stopped` or `status: closed` ledger is not resumed), that run is the next step: confirm with the user in one sentence, then continue with `/memokit:parallel`, which resumes from its ledger (its step 1, "Resume first"). Do not re-plan or re-dispatch by hand.
   **Parallel proposal.** After the checks above (talk-first, unfinished council, active run — a ledger with `status: active`), and only when no run is active: count the remaining tasks of the work STATE points to (the plan file it references, else its own task list). If two or more remain and `parallel.maxCoders` is greater than 1, the confirmation of step 6 offers both ways: `/memokit:parallel` (up to `maxCoders` lanes) or one at a time. Resume does not dispatch an analyst to judge independence; that is step 2 of the parallel skill, and its plan table is what the user approves. With `parallel.auto: true`, the announcement and the start happen at step 6, replacing the one-sentence offer: steps 3–5 (docs, health, `resume.md`) run first, say in one sentence that you are starting `/memokit:parallel` and do so; the parallel skill's own gates check replaces step 7; plan approval and the decision sweep inside the parallel skill still happen. One remaining task, `maxCoders` 1 or a talk-first stamp: no proposal.
3. **Read only what you need:** the relevant section of the roadmap/patterns docs the project uses, the slice spec/plan. Never read `docs/HISTORY.md` end to end.
4. **Health.** If `sessionStart.healthScript` is configured, the hook already ran it; report warnings without blocking.
5. **Project steps.** If `.claude/memokit/resume.md` exists, read it and apply it now.
6. **Confirm the plan with the user in one sentence**, then start. When step 2 found two or more remaining tasks, that sentence carries the offer of `/memokit:parallel` or one at a time.
7. **Gates before the first coder slice.** If `.claude/memokit/gates.md` is missing or has no Tier-1 command (a non-empty, non-comment line under `## Tier 1`), the coder would return `BLOCKED: gates.md missing`, so ask the user once (WORKING-MODEL.md §2 format) before delegating: if `.claude/memokit/coder.md` names test commands (a project set up before 0.6.0), recommend moving them into `gates.md` — build and unit tests under `## Tier 1`, integration, container starts, Docker suites, E2E and coverage under `## Tier 2` (an exec into an already running dev container can be Tier 1) — and removing per-slice heavy gates from `coder.md`; otherwise ask for the commands. Write only what the user approves, never guess; commit `gates.md` with a pathspec only if the project tracks its overlays (`git ls-files .claude/memokit` is non-empty).
8. **Don't write code.** Delegate to `memokit:coder`, review with `memokit:reviewer`, then **run the tests yourself** (WORKING-MODEL.md §3) — a subagent report is a claim.

## Don't
- Read `docs/HISTORY.md` or trawl archives.
- Pass a decision point without asking the user.
- Treat a "TALK FIRST" item as the next step to implement.
