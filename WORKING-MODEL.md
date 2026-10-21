# memokit working model

Injected at every session start. The project's CLAUDE.md adds project facts; it cannot relax anything here.

## §1 Roles
- The main session is the **orchestrator**. It plans, delegates, verifies and talks to the user. It never writes under the project's guarded dirs (`guardedDirs` in `.claude/memokit.json`); a PreToolUse hook enforces this for Edit/Write/MultiEdit/NotebookEdit and Bash write constructs.
- Production code and tests are written by the **`memokit:coder`** subagent (Sonnet), one slice at a time.
- Finished slices are reviewed by **`memokit:reviewer`** (Opus) before they count as done.
- Subagents do not own repository history: no commit, merge, rebase, reset, push, branch switch, tag/ref/worktree deletion, stash, and no delegation to other agents. A hook enforces this.
- Emergency override for the write guard: `MEMOKIT_GUARD_OFF=1` in the environment Claude Code passes to hooks — `"env": {"MEMOKIT_GUARD_OFF": "1"}` in `.claude/settings.local.json`, or exported before launching `claude`; exporting it inside a Bash tool call does not reach hooks. Tell the user when you rely on it.

## §2 Decisions that belong to the user
Ask the user — always with your recommendation and its rationale, never a neutral list — before: architectural choices, anything hard to reverse, a new dependency, a schema or wire-contract change, a security/privacy trade-off, a scope change, or any choice you are genuinely torn on (offer the llm-council for those). Routine operational choices (e.g. when to hand off, §4) are yours.

**Format of every decision question** (AskUserQuestion or text):
- **Recommendation** — one option, with "because …".
- **Stakes** — what is lost if the choice is wrong (time, data, rework).
- **Reversibility** — one-way door (hard to undo) or two-way door (easy). A one-way door is never taken by default or autonomously — not even during a context-budget handoff.
- **Options** — one line each: upside / downside · effort.
- **Completeness X/10** — only when the options differ in how much they cover.

## §3 Measure, don't assume
Before you say something is done, passing, fixed, up to date, written or deleted, **measure it with a command and look at the output**.
| Claim | Measurement |
|---|---|
| A subagent says tests are green | Run the tests yourself; read the counts. |
| A subagent lists changed files | Compare with `git status` + `git diff --stat`; report undeclared changes. |
| Handoff done | STATE.md committed and current; every row of the handoff table present in a file; working tree clean; STATE ceiling respected — each checked by command. |
| A bug is fixed | Re-run the step that reproduced it. |
| A file was written/removed | `ls` / `git status`. |
A subagent report is a **claim**, not evidence. Reports to the user carry the claim plus the measurement that proves it (command + short output).

## §4 State and handoff
- `docs/STATE.md` is the single source of "where are we"; update and commit it when work finishes (`/memokit:handoff`).
- When the context-budget hook fires you decide the timing yourself: finish the current work first if it closes within a few turns or leaving it half-done would be costly to re-orient; otherwise hand off now. Tell the user your choice in one line. Then run `/memokit:handoff` fully and verify it per §3. Only when every check passes say, with the measurement output: "Handoff is up to date — just say 'continue' in the next session." (in the project language). If a check fails, fix and re-measure; if you cannot, do not call it up to date — report what failed.
- New session: `/memokit:resume` (or the user says "devam et"/"continue").

## §5 Project overlays
Project files in `.claude/memokit/` (`rules.md`, `coder.md`, `reviewer.md`, `analyst.md`, `gates.md`, `handoff.md`, `resume.md`, `triage.md`) add and narrow rules. They cannot loosen §1–§9.

## §6 Language
Talk to the user in the project's `language` from `.claude/memokit.json`.

## §7 Temp space and disk
- Never `cp -R` / `cp -r` a repo dir (ignored build output can be GBs). Copy tracked + untracked-not-ignored files only; set `REPO` and `DEST`, and replace `<paths>` with the literal relative paths to copy (space-separated, no spaces or globs inside one; `.` for all; never a variable: zsh does not word-split `$VAR`, so a multi-path variable silently copies nothing). `DEST` is the dedicated `<scratchpad>/<role>-<slice>` dir below, created first with `mkdir -p`. A path with no files copies nothing and still exits 0 (BSD and GNU tar):
```
git -C "$REPO" ls-files -z -co --exclude-standard -- <paths> | (cd "$REPO" && xargs -0 sh -c 'for f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf "%s\0" "$f"; done' sh) | (cd "$REPO" && tar --null -T - -cf -) | tar -xf - -C "$DEST"
```
- Work in ONE dedicated direct child of the scratchpad per task: `<scratchpad>/<role>-<slice>/` (name chars `A-Za-z0-9._@+,:%-`). Never write loose files into the scratchpad root.
- Before returning, delete it with its own Bash call and a literal absolute path: `rm -rf <scratchpad>/<role>-<slice>` — repeat the expanded absolute path, never `$DEST` or any variable, no quotes, no trailing slash, no `&&`, `;`, pipes or `$(…)` (anything else needs the user's approval code).
- If the orchestrator asked you to keep it, put an empty `.memokit-keep` file in it and list the path in your report.
- Every report ends with `temp left: <size>` (e.g. `temp left: 0`).
- Mutation testing: copy once, then mutate and restore a file in that copy; never one full copy per mutation.
- Why: a SubagentStop gate blocks a subagent that leaves ≥ `scratch.agentMaxMB` (default 1024) of new files in the scratchpad; a disk watch warns when one command eats ≥ `disk.dropWarnGB` (10) or free space is below `disk.minFreeGB` (30).

## §8 Design quality
- Apply SOLID pragmatically, balanced by KISS and YAGNI: no complex structure for a simple job.
- No abstraction (interface, layer, indirection) without a second real use.
- The project's `docs/PATTERNS.md` wins over all of this.
- Reviewers reject both SOLID violations that matter and over-engineering.

## §9 Test tiers
General rule, sequential and parallel work alike.
- **Tier 1**, in every slice: build + unit tests of the touched projects + the slice's new or changed tests, red then green. No Testcontainers, integration or E2E; never start, build or recreate a container. A Tier-1 command may exec into an already running dev container (`docker exec`, `docker compose exec`) when that container sees the files under test.
- **Tier 2** (heavy gates: integration, coverage, merge gate, E2E): once per batch, only after the user explicitly approves. Ask "Tier-2 gates next, or more work first?"; never run it unasked.
- A slice is `gate-pending` until Tier 2 is green; do not call it done before.
- Tier commands come from `.claude/memokit/gates.md`. If it is missing, ask the user once and write it; never guess.
