---
name: parallel
description: Only in projects that have .claude/memokit.json — run a batch of independent tasks (plan file, ticket list, epic, a docs/STATE.md section) in parallel lanes; analyse, plan lanes, ask every foreseeable decision up front, run up to parallel.maxCoders memokit:coder lanes in their own git worktrees, review by risk, merge in completion order, clean up by measurement, then ask before Tier 2. Use when the user says /parallel, /memokit:parallel, "paralel", "toplu ticket", "epic", or asks to run several tasks at once.
---

# Parallel — independent tasks in parallel lanes

Goal: shorter wall time with no loss of quality or work. Every slice still gets TDD, Tier-1 evidence and an independent review, and the user still makes every decision. You are the orchestrator: you plan, ask, run every git command, commit and merge; subagents write the code. Talk to the user in the project `language` (`.claude/memokit.json`).

## Steps

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here and do nothing else from this skill.

1. **Start or resume.**
   - **Resume first.** If a `.claude/memokit/runs/*/ledger.md` has `status: active`, create nothing: re-read this skill and the ledger, reconcile with `git worktree list` and `git branch --list 'mk/*'`, and continue each task from its recorded state. A task in `merging` without its merge-end line: `git rev-parse -q --verify MERGE_HEAD` succeeds → a merge is in progress, ask the user; otherwise `git merge-base --is-ancestor mk/<run>/<lane> HEAD` tells whether it landed. A task in `merging` with its merge-end line but no Tier-1 re-run or cleanup logged: re-run Tier 1 (step 6), then clean up idempotently — check `git worktree list` and `git branch --list 'mk/<run>/<lane>'` first and run only the `git worktree remove` / `git branch -d` that still has something to remove. A ledger with `status: stopped` or `status: closed` is not resumed (step 12). A coder that cannot be resumed is re-dispatched with its brief file and told to continue from the worktree's current changes (never discard them). After any context compaction, too, re-read this skill and the ledger before acting.
   - Load the deferred tools once: ToolSearch `select:SendMessage,PushNotification,Monitor` (skip what does not exist).
   - Task source: a plan file, a ticket list or a `docs/STATE.md` section; none given → ask. Integration branch: the current branch unless the user names another (switching needs their ok).
   - **Clean start.** `git status --porcelain --untracked-files=all` in the main checkout may list only untracked memokit files (`.claude/memokit.json`, `.claude/memokit/`). Other untracked files (e.g. `.claude/settings.local.json`, `.idea/`, `.DS_Store`) → ask the user once to accept them into the baseline; modified tracked files still block the start. Until the user cleans up what blocks, the run does not start; never stash, discard or commit the user's changes.
   - Config: `parallel.maxCoders` (default 3), `parallel.maxReviewers` (3), `review.model` (`auto`). `maxCoders` 1 = sequential. If `maxCoders` + `maxReviewers` exceeds `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (default 20), warn the user before starting.
   - **Gates.** `.claude/memokit/gates.md` must exist and have at least one Tier-1 command: a non-empty, non-comment line under `## Tier 1`. If not, ask the user once for the Tier-1 and Tier-2 commands (§2 format) and write them there; never guess. Tier 1 must run without secrets (lane worktrees have none). If a Tier-1 command execs into a container, it runs on what that container mounts, usually the main checkout and not a lane worktree: unless the command can be pointed at the lane's own path inside the container (`--workdir`), tell the user and recommend running these tasks sequentially (§2).
   - **Ignore** the run dir and the lane worktrees (idempotent); commit and tell the user only if a line was added:
     ```bash
     git check-ignore -q .claude/memokit/runs/x || printf '\n.claude/memokit/runs/\n' >> .gitignore
     git check-ignore -q .claude/worktrees/x || printf '\n.claude/worktrees/\n' >> .gitignore
     # only if a line was added:
     git add -- .gitignore && git commit -m "chore(memokit): ignore run ledgers and lane worktrees" -- .gitignore
     ```
   - **Your commits in the main checkout name their files** (pathspec): `git add -- <file>`, then `git commit -m "<msg>" -- <file>` — for `.gitignore`, `gates.md` and the decision log. Commit `gates.md` only if the project tracks its overlays (`git ls-files .claude/memokit` is non-empty); if `.claude/memokit/` is ignored or untracked, never `git add -f`: paste the texts into the briefs.
   - **Ledger** `.claude/memokit/runs/<run-id>/ledger.md` (`<run-id>` = `YYYYMMDD-HHMM`): a `status: active` line near the top (session start and `/memokit:sweep` read the first `status:` line to keep this run's lanes off the leftover list; later edit that line, never add a second one), integration branch, batch base (`git rev-parse HEAD` after the commits above), config, the porcelain baseline (`git status --porcelain --untracked-files=all` now); one row per task: id · lane · risk · state · agent id · worktree · tokens · wall time; the merge queue; the decision queue; one log line per event, with merge-start and merge-end for every merge. Write every state change there before acting on it. States: `planned` → `decided` → `running` ⇄ `needs-decision` → `in-review` → `approved` → `merging` → `merged` (gate-pending) → `done`; a failed step sends a task back to `running` through a fix slice.
   - **Briefs and reports on disk.** Write each brief to `.claude/memokit/runs/<run-id>/<lane>-<task>-brief.md` (task text, the user's decisions, the untracked overlay texts, the gates text) and give the agent that file's absolute path. Every brief names the main project root (it holds `.claude/memokit.json`) next to the working directory, the lane id and task id, and a report file per round, `<lane>-<task>-<role>-r<n>.md` in the same dir. Coders and reviewers write their full report there and return only their first lines — coders their `Status:` line, reviewers their `Overlay read:` line and their verdict line — plus at most 5 lines; a `NEEDS_DECISION` question is returned verbatim, exempt from the cap. Analysts are read-only and return their fields directly.

2. **Analysis.** Dispatch `memokit:analyst`, one per task or small group, at most `maxCoders` at once, with the task text, the untracked overlay texts and the gates text. Each returns `touches:`, `depends_on:`, `risk:` and `questions:` per task; an analyst's `gates.md missing` follows the `gates.md missing` rule of step 5. Build lanes:
   - tasks that share files or depend on each other go into one lane, in order;
   - global hotspots (shared libraries, migrations, the DB context, cross-service contracts) go into a **solo** lane of one task;
   - `docs/STATE.md`, `docs/HISTORY.md`, `docs/DECISIONS.md` never count as shared files: lanes never touch them.
   Turn the analysts' questions into final questions, each with your recommendation.

3. **Plan approval.** Show one table: lane · tasks in order · why grouped · risk (`high`/`normal` with the reason) · solo · open questions. Nothing starts until the user approves the plan, risk tags included.

4. **Decision sweep.** Ask every question with `AskUserQuestion`, at most 4 questions per call, each in the WORKING-MODEL.md §2 format. Record each answer in the decision log (overlay-defined; default `docs/DECISIONS.md`; commit it with a pathspec right after each write) and in the lane's brief files. A task is `decided` only when all its questions are answered; a lane whose questions are not all answered does not start.

5. **Rolling execution.**
   - **Scheduling.** Rolling slots, not wave barriers: at most `maxCoders` lanes run at once; a freed slot starts the next ready lane right away, and ready lanes start in plan order. A lane runs until it is `merged`: lanes in `needs-decision`, `in-review` or the merge queue count as running. When the next lane in plan order is solo, start no new lanes and let the running ones drain to `merged`; nothing else starts while a solo lane runs. Tasks in a lane run in order, one slice and one commit each, in the lane's worktree.
   - **Asking blocks you, not the lanes.** Before each `AskUserQuestion`, process every pending event first (dispatch waiting reviews, run queued merges, start ready lanes), then ask.
   - **Start a lane** from the CURRENT integration branch, so it already holds every lane merged before it:
     ```bash
     git worktree add .claude/worktrees/mk-<run>-<lane> -b mk/<run>/<lane> <integration>
     ```
     Nothing untracked or ignored goes in: no `.env`, no `.secrets/`, no local config, no copy, no symlink. Run the secret-free bootstrap (e.g. dependency restore) in the worktree if an overlay defines one. Overlays in `.claude/memokit/*.md` that git does not track (`git ls-files --error-unmatch <file>` fails): paste their text into the brief.
   - **Dispatch `memokit:coder`** with its brief file: the worktree's absolute path as its only working directory, the main project root, lane id and task id, the report file.
   - `NEEDS_DECISION` → state `needs-decision`; queue the question in the ledger; only that lane pauses, other lanes keep running. Ask the queued questions one question at a time (`AskUserQuestion`, §2 format). If the user may be away, send one `PushNotification` line (`status: "proactive"`, `[<TAG>]` prefix, under 200 characters). Record the answer (decision log, brief), resume the same coder (`SendMessage` to its agent id); state `running`.
   - `BLOCKED` → ask the user about that lane (§2). An analyst's or a coder's `gates.md missing` → if `gates.md` has a Tier-1 command, the brief lacked it: resend the gates text to the same agent (`SendMessage`); ask the user only if it is truly absent (the gates rule of step 1).
   - `DONE` (`Tier 1 green — gate-pending`) → first `git -C <wt> add -N -- .` (intent-to-add: it records the lane's new, non-ignored files in the index without their content and commits nothing, so `diff HEAD` and `--stat` show them; a plain `diff HEAD` leaves untracked files out, and they are usually the new tests). Then measure (WORKING-MODEL.md §3): the lane's changes (`git -C <wt> status --short --untracked-files=all`, `git -C <wt> diff HEAD --stat`) match the report's file list and stay in the slice, and the main checkout's `git status --porcelain --untracked-files=all` lists nothing beyond the baseline (checked against the baseline; entries gone through your own pathspec commits are fine). A mismatch → fix round.
   - **Reviewer brief** (a brief file, as above): the lane worktree path as its working directory, the main project root, lane id and task id, the task text, the user's decisions, the untracked overlay texts and the gates text, the report file. It reviews `git -C <wt> status --short --untracked-files=all` and `git -C <wt> diff HEAD`; the brief says that the lane's new files are intent-to-add (you ran `git -C <wt> add -N -- .` at the DONE check; run it again after every fix round), so `diff HEAD` shows them with their content, and that a file still `??` in the status is not in the diff and must be read directly. At most `maxReviewers` at once; state `in-review`. Pick the model with the Agent tool's `model` parameter: `review.model` `auto` → `opus` for `high` risk, `sonnet` for `normal`; `opus` or `sonnet` → that model. `ESCALATE: opus — <reason>` → re-run the review on Opus. `REJECT` → fix round: send the same coder the reviewer's report file path (`SendMessage`), then a new review (next round number).
   - `APPROVE` → state `approved`; you commit in the worktree (`git -C <wt> add -A`, `git -C <wt> commit`) with the overlay's message conventions and git-identity checks. After the lane's last task, the lane joins the merge queue.

6. **Merge queue**, in completion order, one lane at a time, in the main checkout on the integration branch. State `merging`, log merge-start, merge, log merge-end:
   ```bash
   git merge --no-ff --no-edit mk/<run>/<lane>
   ```
   - `--no-edit` keeps git from opening an editor; when the overlay sets merge-message conventions, use `-m "<message>"` instead. Merge only; never squash or rebase a lane (`git branch -d` must see it as merged).
   - Re-run Tier 1 yourself for the merged areas (build + unit tests of the touched projects, from `gates.md`; Bash `timeout: 600000`) and read the counts. Then re-measure the main checkout against the baseline: changes your run produced (e.g. build output that is not ignored) are yours, not a lane's — report them to the user, then append those entries to the ledger baseline; DONE checks then ignore them. No fix round for them.
   - A conflict → `git merge --abort`. A conflict or a red Tier 1 → freeze the merge queue and new lane starts until the resolution slice is merged green. **Resolution slice:** `git worktree add .claude/worktrees/mk-<run>-<lane>-fix -b mk/<run>/<lane>-fix <integration>` (for a conflict, then `git -C <wt> merge --no-commit --no-ff mk/<run>/<lane>` in it, and record its conflicted files in the ledger before any coder runs: `git -C <wt> diff --name-only --diff-filter=U`); a coder resolves and gets Tier 1 green; `git -C <wt> add -N -- .`, then measure and review on `git -C <wt> diff HEAD`, where the lane's own files showing up is expected, not scope creep. After `add -N` the conflicted files show as `DA` in `git status` and `--diff-filter=U` comes back empty: that is the intent-to-add entry, not a deletion; the list you recorded in the ledger is the reference. Before you commit: `git -C <wt> add -A`; after a conflict, `git -C <wt> grep --cached -nE '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)( |$)|^=======$' -- <conflicted files>` must print nothing (exit 1: no leftover conflict markers in the staged files that had conflicts; not `diff --check`, which also fails on whitespace rules, `.gitattributes` `whitespace=` included). A match → do not commit: fix round to the same coder with the marker list (a `=======` line that the file also has on `mk/<run>/<lane>` or the integration branch is content, not a marker). Nothing printed (or no conflict) → commit, then merge `mk/<run>/<lane>-fix` like a lane.
   - Green → clean up, the same two commands also for any `-fix` worktree and branch (after a red Tier 1 the original lane is already merged, so `-d` works), then verify by measurement:
     ```bash
     git worktree remove .claude/worktrees/mk-<run>-<lane>
     git branch -d mk/<run>/<lane>
     git worktree list
     git branch --list 'mk/*'
     ```
     If git refuses (uncommitted changes, branch not merged), stop and ask the user. State `merged` (gate-pending); the slot is free.

7. **Follow-up tasks** found by a review or a measurement are appended to their parent's lane, right after the parent. A lane already merged reopens with a fresh worktree from the current integration branch; reusing `mk/<run>/<lane>` after its deletion is logged as a new lane start. Their questions are asked first (step 4 rules); they join the batch.

8. **Batch review.** When every task is `merged`: one Opus whole-batch review — `memokit:reviewer` with `model` `opus`, always, also with `review.model: sonnet` — of `git diff <batch base>..HEAD` (the whole batch, also when it runs again after added work). Its findings go through one fix wave (slices by steps 5–6).

9. **Tier 2 only on the user's explicit go.** Ask: "Tier-2 gates next, or more work first?" (project language, §2 format).
   - More work → steps 2–8 for the new tasks; their decisions are asked first.
   - Approved → run every approved `## Tier 2` gate from `gates.md` yourself, in the main checkout, one after another, Bash `timeout: 600000`. Start a gate expected to exceed 10 min with `run_in_background: true`; a gate in the background is awaited (Monitor) before the next one starts — never two at once.
   - Then triage all reds in one pass (`/memokit:triage`); fix slices follow steps 5–6 (worktree from the integration branch, review, Tier 1, merge). After the fixes, ask whether to run all Tier-2 gates again or only the red ones.
   - All green → tasks `done`, ledger `status: closed`. Merging to main and deploying follow the project's own rules.

10. **Report.** Per lane: tasks, subagent token totals (summed from the task notifications, kept in the ledger), wall time (lane start → merged), review rounds and escalations. Add the Tier-1/Tier-2 measurements and the leftover check (`git worktree list`, `git branch --list 'mk/*'`: no lane of this run unless the user chose to keep it). End with a recommendation on `parallel.maxCoders`: raise it when ready lanes waited for a slot and the machine stayed responsive; keep or lower it otherwise. Then update `docs/STATE.md` (the run's outcome, the batch's state, the single next step) and commit it with a pathspec: `git add -- docs/STATE.md`, `git commit -m "<msg>" -- docs/STATE.md`, so the stale-STATE reminder does not fire for the merged lanes; at a handoff, `/memokit:handoff` does this.

11. **Context budget.** When the context-budget hook fires, decide the timing (WORKING-MODEL.md §4) and run `/memokit:handoff`; the ledger makes the run resumable, and step 1 resumes it.

12. **Ending a run early.** When the user ends the run before it is done: tell running coders and reviewers to finish or stop cleanly (no background work left), record each task's real state in the ledger, then change the status line to `status: stopped` and log the date and the user's reason. Report what stays (`git worktree list`, `git branch --list 'mk/*'`): lanes that are merged and clean go through step 6's cleanup only with the user's ok; unmerged or dirty ones stay for the user to decide, never removed. A `status: stopped` ledger is closed for routing: handoff and resume no longer route to it, and its remaining lanes are reported at session start and by `/memokit:sweep worktrees` like any other leftovers. Update and commit `docs/STATE.md` as in step 10.

## Never
- Proceed on an assumption: at a decision point the lane pauses and the user is asked.
- Run Tier 2 without the user's explicit approval, or let a coder or reviewer run it.
- Copy or link untracked or ignored files, or secrets, into a lane worktree.
- Pass `--force`/`-f` to `git worktree remove` or `-D` to `git branch` (nor `-d -f`).
- Delete unmerged or uncommitted work, or discard a lane's changes to make a merge succeed.
- Let a lane write `docs/STATE.md`, `docs/HISTORY.md` or `docs/DECISIONS.md`; only you write them.
- Edit code yourself, in any worktree (guard-edit enforces this); conflicts and reds go to a coder slice.
- Call a task done before Tier 2 is green, or report a lane green without your own Tier-1 run.
