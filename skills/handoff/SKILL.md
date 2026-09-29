---
name: handoff
description: Only in projects that have .claude/memokit.json — hand the session over cleanly; rewrite docs/STATE.md, print the handoff table, enforce the STATE ceiling, record durable decisions, commit, then VERIFY BY MEASURING. Use when the user says /handoff or "handoff/devret", and when the context-budget hook fires.
---

# Handoff — session close ritual

Goal: the next session reads `docs/STATE.md` and, when the user only says "devam et"/"continue", continues **without asking anything and without dropping any work**. Talk to the user in the project `language` (`.claude/memokit.json`).

## Steps

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here and use the project's own handoff skill/ritual instead. Do nothing else from this skill.

1. **Collect what changed.**
   ```bash
   git log --oneline -10
   git status --short
   ```
   Also sweep the **conversation**: decisions, preferences, scope changes, "later" items agreed with the user but not yet written anywhere. They exist only in this context — unwritten, they are lost.

2. **Rewrite `docs/STATE.md`**, keeping its template and order: last updated date · active phase/slice · **the single next step** (one sentence; if unclear write "decision pending: …") · open questions/blockers · recent work commits · environment (test counts from a real run, branch) · where things are (short). No narrative history — that goes to `docs/HISTORY.md` (create it if missing).

3. **PRINT THE HANDOFF TABLE — in full, before trimming and before committing, visible to the user.** This step must produce output; "checked, all clear" is not a check.

   | # | Work item | Unambiguous? | Missing decision | Written where |
   |---|---|---|---|---|

   One row per handed-over item: unfinished work, uncommitted changes, pending subagent results, pending council syntheses, unwritten decisions from step 1. For each: can the next session start without asking? does it hide an unchosen option? was its cost/time approved by the user? Every "NO" row gets the stamp **"TALK FIRST, NO CODE" / "ÖNCE KONUŞ, KOD YAZMA"** in STATE, and its options — with costs and your recommendation — go to `docs/HISTORY.md`, referenced from STATE.

4. **Enforce the ceiling.** `docs/STATE.md` ≤ 150 lines and ≤ 5 KB (`wc -l -c docs/STATE.md`). Move overflow to the end of `docs/HISTORY.md`; no handoff-table row may lose its trace. If `sessionStart.healthScript` is set in `.claude/memokit.json`, also run it with `--full`.

5. **Durable records.** Hard-to-reverse decision → `docs/DECISIONS.md` row (date | decision | rationale | council folder). New code trap → `docs/PATTERNS.md`. Same correction from the user twice → `docs/LESSONS.md`; a third time → promote to a CLAUDE.md rule or hook. Only create these files if the project already uses them. Progress never goes to Claude memory — that is STATE's job; memory is for durable, project-wide facts only.

6. **Project steps.** If `.claude/memokit/handoff.md` exists, read it and apply its steps now (e.g. ticket transitions, roadmap updates).

7. **Commit.**
   ```bash
   git add docs/ && { [ ! -d .council ] || git add .council/; }
   git commit -m "docs(state): <active work> — next: <single step>"
   ```

8. **VERIFY BY MEASURING** (WORKING-MODEL.md §3) and show the output to the user:
   ```bash
   git status --short                               # must be empty
   wc -l -c docs/STATE.md                           # within the ceiling
   git log --oneline -5                             # STATE's commit list is not stale
   git log -3 --format='%an %s' -- docs/STATE.md    # no unexpected author
   ```
   plus the health script with `--full` and `echo "exit=$?"` if configured. Then answer YES/NO for each: table printed? every NO row stamped and its options in HISTORY? every unwritten decision from step 1 now in a file? next step unambiguous when read with fresh eyes? test numbers from a real run, not an agent claim? any red test / half-done work / unexplained finding hidden? (must be NO).

   **Only if every measurement passes**, summarise the outputs and say exactly (project language): tr — *"Handoff güncel, sonraki oturumda 'devam et' demen yeterli."*; en — *"Handoff is up to date — just say 'continue' in the next session."* No hedging ("probably", "I think"). If anything fails, do **not** say it is up to date: state what is missing, fix it, re-measure.

   Closing summary: what finished, what remains, the single next step, open blockers.

## Don't
- Embed derived numbers (line/byte counts, "N×") in documents — write the threshold and the command instead.
- Grow STATE. The ceiling is not negotiable.
- Mark unfinished work as finished; hide red tests.
- Skip the handoff table.
- Write anything from secret folders into STATE/HISTORY/commit messages.
