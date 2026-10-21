# memokit

memokit is a Claude Code plugin that enforces a small working model for AI-assisted development. The orchestrator (your main session) never writes production code; a Sonnet `memokit:coder` subagent does, and an Opus `memokit:reviewer` gates every slice before it counts as done. Session rituals keep `docs/STATE.md` current, and a context budget triggers a measured, autonomous handoff before a session grows too expensive.

This is personal infrastructure shared as-is. MIT licensed, no support guarantee.

## What's inside

| Kind | Name | What it does |
|---|---|---|
| Hook | `guard-edit.sh` | PreToolUse: blocks the main session from writing under the guarded dirs (Edit/Write and Bash write constructs), in the main checkout and in every git worktree of the repo (including Claude Code worktrees). |
| Hook | `guard-subagent-authority.sh` | PreToolUse: blocks subagents from committing, merging, rewriting history, touching the remote, or delegating. |
| Hook | `guard-destructive.sh` | PreToolUse: denies destructive Bash commands (force push, reset --hard, recursive rm, destructive SQL, kubectl/helm delete, …, plus project patterns) until the user approves with a single-use code. It also denies Edit/Write/MultiEdit/NotebookEdit to memokit's approval (grant) file, including through symlinks. |
| Hook | `inject-rules.sh` | UserPromptSubmit: re-injects the core rules (plus your `rules.md`) and keyword-gated skill hints. |
| Hook | `session-start.sh` | SessionStart: injects `docs/STATE.md`, tracked docs, health-script summary and a settings risk scan, and reports leftover worktrees and `mk/*` branches. |
| Hook | `check-state-stale.sh` | Stop: warns when guarded dirs changed but `docs/STATE.md` did not. |
| Hook | `check-context-budget.sh` | Stop: when the context passes the budget, tells the AI to hand off on its own. |
| Hook | `check-subagent-background.sh` | SubagentStop: stops a subagent from returning while background work it started is still running. |
| Hook | `check-subagent-scratch.sh` | SubagentStop: blocks (up to 3 times) a subagent that leaves a large temp footprint in the session scratchpad, so it cleans up before returning. |
| Hook | `check-disk.sh` | PreToolUse/PostToolUse/PostToolUseFailure (Bash) and Stop: warns when one command drops free disk space by `disk.dropWarnGB`, warns when free space is below `disk.minFreeGB`, and at Stop points to `/memokit:sweep`. |
| Hook | `precompact-handoff.sh` | PreCompact: steers the compaction summary toward what a handoff needs. |
| Agent | `memokit:coder` | Writes production code and tests, one slice at a time, test-first. |
| Agent | `memokit:reviewer` | Adversarial review of each coder slice. |
| Agent | `memokit:analyst` | Read-only analysis of a task before any code: files it touches, dependencies, risk tag, decision questions with recommendations. |
| Skill | `/memokit:init` | Sets memokit up in a repo (new project, or adoption of an existing AI setup: CLAUDE.md, AGENTS.md, other tools' rules, `.claude/` agents, skills and hooks, legacy per-repo hooks). |
| Skill | `/memokit:handoff` | Writes the handoff and verifies it by measurement. |
| Skill | `/memokit:resume` | Picks up from `docs/STATE.md` in a new session. |
| Skill | `/memokit:triage` | Clusters red/flaky tests by signature, classifies them with evidence, then drives one root cause to a red-before-green fix. |
| Skill | `/memokit:sweep` | For what the session-start auto-clean keeps: measures the stale temp leftovers earlier sessions left behind, asks, deletes the approved ones one literal `rm -rf` at a time and reports the freed space; also lists leftover worktrees and `mk/*` branches and removes the approved merged-clean ones. |
| Skill | `/memokit:parallel` | Runs a batch of independent tasks in parallel lanes, each in its own git worktree: analysis, plan approval, one batch of decision questions, review by risk, merge queue, cleanup, then asks before the heavy gates. |
| Doc | `WORKING-MODEL.md` | The shared rules the hooks, agents and skills refer to. |

## Install

Install memokit **once, at user level**:

```
/plugin marketplace add tsrmehmet/memokit
/plugin install memokit@memokit
```

In the `/plugin install` dialog pick the user scope (from a shell: `claude plugin install memokit@memokit --scope user`). The plugin manifest sets `"defaultEnabled": true`, so the install leaves memokit enabled for every project. Then run `/memokit:init` in each git repository that should use it.

memokit stays out of the way elsewhere: the hooks act only in projects that have `.claude/memokit.json`, the agents and skills (`memokit:coder`, `/memokit:resume`, …) are `memokit:`-namespaced and stop on their own when it is missing, and the "run `/memokit:init`" hint is off by default (`MEMOKIT_INIT_HINT=1` turns it on; see "Kill switches and troubleshooting"). `/memokit:init` asks whether everyone who clones the repository should be offered memokit too; only on yes does it write `enabledPlugins["memokit@memokit"] = true` and the marketplace into the project's shared `.claude/settings.json`. The recommended answer is no unless you maintain the repository and the team agreed: the entry offers every contributor a third-party plugin, and your user-scope install already covers you.

In a repository you do not trust, look at `.claude/memokit.json` before the first session: its `sessionStart.healthScript` runs at every session start and `graph.refreshScript` at handoff. That is the same exposure as hooks in the repository's `.claude/settings.json`; memokit only refuses scripts that resolve outside the project root.

Requirements: bash, jq, git; macOS or Linux.

## Quick start

1. With memokit installed (see Install), open Claude Code in a git repository and run `/memokit:init`.
2. It detects your stack and asks a short set of questions: project name, tag, language, guarded directories, and the docs to show at session start.
3. It writes `.claude/memokit.json` and overlay skeletons, creates `CLAUDE.md`, `docs/STATE.md` and `docs/DECISIONS.md` from templates if they are missing (it never overwrites an existing file), and, only if you want the team on memokit, registers the marketplace and plugin in `.claude/settings.json`.
4. Start a new session. Hooks are active only in projects that have `.claude/memokit.json`.

## Configuration

`.claude/memokit.json` (full schema: [`schema/memokit.schema.json`](schema/memokit.schema.json), example: [`examples/memokit.json`](examples/memokit.json)). Add a `$schema` line for editor completion and validation:

```json
{ "$schema": "https://raw.githubusercontent.com/tsrmehmet/memokit/main/schema/memokit.schema.json" }
```

| Field | Required | Default | Purpose |
|---|---|---|---|
| `version` | yes | none | Must be `1`. |
| `project.name` | yes | none | Shown in the session-start header. |
| `project.tag` | yes | none | Message tag, e.g. `ACME` gives `[ACME-...]` prefixes (2-10 chars, `A-Z0-9`, starts with a letter). |
| `language` | no | `en` | `en` or `tr`: language of hook messages and of the assistant's replies to you. |
| `guardedDirs` | no | `["src","tests"]` | Repo-relative directories the main session may not write to. |
| `contextBudget.limitTokens` | no | `300000` | Context size at which the handoff reminder starts (minimum 1000). |
| `stateStale.maxCommitsBehind` | no | `3` | Guarded-dir commits allowed after the last `docs/STATE.md` commit. |
| `sessionStart.docs` | no | `[]` | `"path — description"` lines shown at session start. |
| `sessionStart.healthScript` | no | none | Repo-relative script run with `--fast` at session start. Not run when it resolves outside the project root or is a symlink. |
| `hints.builtin` | no | all | Any of `debugging`, `decision`, `review`, `handoff`, `resume`, `graphify`. |
| `hints.custom[]` | no | `[]` | `{ "match": "<regex>", "text": "<hint>" }` project-specific keyword hints. |
| `graph.root` | no | none | Enables the code graph (see below): repo-relative directory the graph covers (`.` = whole repo). |
| `graph.maxCommitsBehind` | no | `20` | Commits under `graph.root` since the last refresh before the codebase-question hint says "refresh first". |
| `graph.refreshScript` | no | none | Repo-relative script that replaces the builtin refresh (run from the repo root; exit 0 = refreshed). Not run when it resolves outside the project root or is a symlink. |
| `scratch.agentMaxMB` | no | `1024` | New data (MB) a subagent may leave in the scratchpad before the SubagentStop gate blocks it. |
| `scratch.staleAfterHours` | no | `24` | Age after which a temp entry of an earlier session counts as stale. |
| `scratch.reportMinMB` | no | `500` | Stale temp size (MB) from which SessionStart reports leftovers. |
| `disk.minFreeGB` | no | `30` | Free-space floor (GB) that triggers the low-disk warning; `0` turns it off. |
| `disk.dropWarnGB` | no | `10` | Free-space drop (GB) during one Bash command that triggers a warning. |
| `parallel.maxCoders` | no | `3` | Coder lanes `/memokit:parallel` runs at once (integer, minimum 1; `1` = sequential). |
| `parallel.maxReviewers` | no | `3` | Reviewers `/memokit:parallel` runs at once (integer, minimum 1). |
| `review.model` | no | `auto` | Reviewer model in a parallel run: `auto` (Opus for `high`-risk tasks, Sonnet for `normal`), `opus` or `sonnet`. The Opus batch review runs with every value. |
| `careful.patterns[]` | no | `[]` | `{ "match": "<ERE>", "label": "<name>" }` destructive-command patterns added to the builtin set (case-insensitive, whole command). |

## Code graph (graphify)

With `graph` set in `.claude/memokit.json`, memokit keeps a graphify code graph in `graphify-out/` current:

- **At every handoff** `/memokit:handoff` runs `skills/handoff/scripts/memokit-graph.sh refresh` after its commit. It does nothing when no commit touched `graph.root` since the last refresh; otherwise it runs `graphify update <graph.root>` (code only, AST extraction, no LLM tokens) and moves the marker `graphify-out/.graph_commit` to `HEAD`. A failed refresh keeps the previous graph and is reported as a warning; it does not fail the handoff.
- **On a codebase question** ("where is", "who calls", …) the hint carries the measured staleness: fresh → query directly; more than `maxCommitsBehind` commits behind → refresh before answering.
- `graphify-out/` must be git-ignored; the refresh refuses otherwise. graphify does not read nested `.gitignore` files, so put build output and secrets under the root into a `.graphifyignore` at the repo root.

`/memokit:init` offers the graph with a measured recommendation. In a project without `graph`, the hint tells the AI to ask you before building one rather than building it on its own. `memokit-graph.sh status` prints the staleness (exit 0 fresh, 1 stale, 2 unknown, 3 no graph).

## Handoff notification

The last step of `/memokit:handoff` sends one line through Claude Code's `PushNotification` tool: "handoff ready, next: …" or "handoff not complete: …". The tool skips the push while you are at the terminal and reaches your phone when Remote Control is connected, so an autonomous handoff at the context budget tells you when to open a new session.

## Overlays

Project-specific rules live in `.claude/memokit/`:

| File | Read by |
|---|---|
| `rules.md` | `inject-rules.sh`, on every prompt |
| `coder.md` | `memokit:coder`, as its first step |
| `reviewer.md` | `memokit:reviewer`, as its first step |
| `analyst.md` | `memokit:analyst`, as its first step (project checks, e.g. issue-tracker or design verification) |
| `gates.md` | `memokit:coder` and the orchestrator: the Tier-1 and Tier-2 test commands (see Test tiers) |
| `handoff.md` | `/memokit:handoff`, after the generic steps |
| `resume.md` | `/memokit:resume`, after the generic steps |
| `triage.md` | `/memokit:triage`, as its first step |

Precedence: overlays only add and narrow. They cannot loosen the plugin's invariants: subagents cannot touch git history, the orchestrator cannot write to guarded dirs, and nothing is called done without evidence. A loosening attempt is ineffective because the hooks block it anyway.

## Test tiers

A general rule (`WORKING-MODEL.md` §9) for sequential and parallel work alike, re-injected on every prompt:

- **Tier 1**, in every slice, run by `memokit:coder`: build, the unit tests of the touched projects, and the slice's new or changed tests (red, then green). No Docker or Testcontainers, no integration or E2E suites. It must run without secrets.
- **Tier 2**, the heavy gates (integration, coverage, merge gate, E2E): once per batch, run by the orchestrator in the main checkout, one gate at a time, and only after you answer "Tier-2 gates next, or more work first?". Never unasked, never by a subagent.
- A slice with a green Tier 1 is `gate-pending`; it is called done only when Tier 2 is green.

The commands live in `.claude/memokit/gates.md` (`## Tier 1` and `## Tier 2` sections). `/memokit:init` creates the skeleton and offers to fill it with you. When it is missing or has no Tier-1 command, the coder returns `BLOCKED` with `gates.md missing` and the orchestrator asks you once; nobody guesses the commands.

## Parallel runs

`/memokit:parallel` runs a batch of independent tasks (a plan file, a ticket list, a `docs/STATE.md` section) at the same time without giving up any of the single-slice rules: every slice still gets TDD, Tier-1 evidence and an independent review, and you still make every decision. The orchestrator does every git operation; subagents only write code in their own directory.

Each lane works in its own **git worktree**. A worktree is an extra working directory attached to the same repository: it has its own checked-out branch and its own files, but shares the one `.git` history. Two lanes in two worktrees cannot overwrite each other's files, and a finished lane is merged like any branch. Lane worktrees live under `.claude/worktrees/mk-<run>-<lane>` on a branch `mk/<run>/<lane>`, created from the current integration branch when the lane starts. Nothing untracked or ignored is copied in: no `.env`, no local config, no secrets.

The lifecycle:

1. **Analysis.** One read-only `memokit:analyst` per task (or small group) reports the files it touches, its dependencies, a risk tag (`high` or `normal`) and the decision questions it foresees.
2. **Plan approval.** Tasks that share files or depend on each other go into one lane, in order; global hotspots (shared libraries, migrations, cross-service contracts) get a solo lane that runs alone. You approve the lane table, risk tags included, before any code starts.
3. **Batch decision sweep.** Every foreseeable question is asked up front, at most 4 per prompt, each with a recommendation. A lane with an open question does not start.
4. **Rolling lanes in worktrees.** Up to `parallel.maxCoders` lanes run at once; a freed slot starts the next ready lane right away. A decision that comes up at run time pauses only its own lane.
5. **Review by risk.** Each slice is reviewed on its lane's diff, up to `parallel.maxReviewers` at once. The orchestrator first marks the lane's new files intent-to-add (`git add -N`, nothing committed), so the diff includes them.
6. **Merge queue.** Approved lanes merge into the integration branch one at a time, in completion order (`git merge --no-ff --no-edit`), and the orchestrator re-runs Tier 1 after each merge. A conflict or a red Tier 1 goes to a resolution slice; the orchestrator never edits code by hand.
7. **Cleanup.** Right after a green merge: `git worktree remove` and `git branch -d`, verified with `git worktree list` and `git branch --list 'mk/*'`. Never forced: if git refuses, you are asked.
8. **Opus batch review.** One Opus review of the whole batch diff, the safety net for anything a slice review missed; its findings go through one fix wave.
9. **Tier-2 question.** "Tier-2 gates next, or more work first?" Only your go runs the heavy gates; reds are triaged in one pass.

**Ledger.** The run's state lives in `.claude/memokit/runs/<run-id>/ledger.md`, next to the lane briefs and reports. It is git-ignored and stays local (`/memokit:init` and the skill add the ignore lines for it and for `.claude/worktrees/`). Each task moves through `planned` → `decided` → `running` ⇄ `needs-decision` → `in-review` → `approved` → `merging` → `merged` (gate-pending) → `done`; a failed step sends it back to `running` through a fix slice. `merging` marks the merge in progress (merge-start and merge-end are logged), so a resumed run can tell whether it landed. `/memokit:handoff` writes "Resume run <id> with /memokit:parallel" as STATE's next step, and `/memokit:resume` continues the run from its ledger. At the end the run reports each lane's token totals and wall time, with a recommendation on `parallel.maxCoders`.

**Reviewer by risk.** `memokit:reviewer` is one agent; the parallel run picks its model per dispatch. With `review.model: auto`, `high`-risk tasks (security, authorization or tenant isolation, personal data, migrations or data integrity, concurrency, shared libraries, cross-service contracts, guard/hook code) are reviewed by Opus and `normal` ones by Sonnet. A Sonnet reviewer that meets a high-risk concern answers `ESCALATE: opus — <reason>` instead of approving, and the review is re-run on Opus. The Opus batch review before the Tier-2 question always runs. Outside a parallel run the reviewer keeps its default model, Opus.

**Leftover worktrees.** At session start memokit counts the worktrees under `.claude/worktrees/` (parallel lanes and Claude Code's own `agent-*` worktrees) of the main checkout and of every other worktree of the repository (a session in a sibling `git worktree add` checkout creates its lanes there), and the `mk/*` branches without a worktree, except the worktree the session runs in, and reports them in one line with their total size (measured within about 2 s; `≥` when some could not be measured). From 0.6.1 it then checks them in a detached background job and removes the `merged-clean` ones that look unused for `scratch.staleAfterHours` (index not rewritten, no Claude Code transcript for that path written, no process with its cwd inside) and still hold no change or ignored file right before the removal (`git worktree remove`, never forced, and `git branch -d` for an `mk/*` branch; git ≥ 2.31) and merged `mk/*` branches without a worktree; everything else (dirty, unmerged, ignored files, fresh) is reported at the next session start for `/memokit:sweep worktrees`. `MEMOKIT_AUTOCLEAN_OFF=1` turns the removal off. Lanes of a run whose ledger says `status: active` are not leftovers: a separate line names the run, which `/memokit:resume` continues. A run you end early gets `status: stopped`; its remaining lanes are then reported like any others. `/memokit:sweep worktrees` lists each one with its status (`active-run`, `merged-clean`, `merged-ignored`, `dirty`, `unmerged`, `orphan-branch`, `detached`, `locked`, `prunable`, `manual`), size, last commit and whether it is merged into the current or the default branch. It offers only `merged-clean` rows; a row with ignored files (a `.env`, `node_modules/`) goes only by an explicit per-row pick after you have seen them, and a branch merged only into the default branch is listed for you to delete from the default branch (git refuses `git branch -d` elsewhere). Unmerged or dirty work is listed for you to decide, never removed.

Limitations: no hook confines a coder to its lane worktree; the brief sets the scope and the orchestrator verifies it by measurement (`git -C <worktree> status`, a clean main checkout). Tier 1 runs without secrets in the lanes; anything that needs them belongs to Tier 2. `parallel.maxCoders` has no upper bound in the config; the skill warns when `maxCoders` + `maxReviewers` exceeds Claude Code's concurrent-subagent limit (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, default 20).

## Context budget

Every turn re-sends the whole context, so cost grows roughly with its square. When the context passes `contextBudget.limitTokens`, the Stop hook tells the AI to decide by itself, without asking you:

1. Finish the current work, then hand off (if it closes in a few turns), or hand off now (if the remaining work is long or you are at a natural stopping point).
2. Tell you in one line which it chose and why.
3. Run `/memokit:handoff` completely, through its phone notification, then verify the handoff by measurement.
4. Only when every check passes, say the handoff is current and that "continue" is enough next session. If a check fails, fix and re-measure, or report what failed.

The reminder fires once when the budget is crossed and again every step of tokens after that. Environment variables (must be valid non-negative integers, otherwise the default applies; `MEMOKIT_CONTEXT_STEP` must be above zero):

| Variable | Effect |
|---|---|
| `MEMOKIT_CONTEXT_LIMIT` | Overrides `contextBudget.limitTokens`. |
| `MEMOKIT_CONTEXT_STEP` | Tokens between repeat reminders (default `100000`). |
| `MEMOKIT_CONTEXT_OFF=1` | Disables the context-budget reminder. |

## Kill switches and troubleshooting

Hooks read these from their environment, so set them in `.claude/settings.local.json` under `env` (one that should apply in every repository, such as `MEMOKIT_INIT_HINT`, under `env` in `~/.claude/settings.json`), or export them before launching `claude`. Exporting inside a Bash tool call does not reach the hooks.

```json
{ "env": { "MEMOKIT_GUARD_OFF": "1" } }
```

| Variable | Effect |
|---|---|
| `MEMOKIT_GUARD_OFF=1` | Emergency override: disables the write guard and the subagent authority guard. |
| `MEMOKIT_SUBAGENT_BG_OFF=1` | Disables the subagent background-work gate, so subagents can return while their background tasks still run. |
| `MEMOKIT_CONTEXT_OFF=1` | Disables the context-budget reminder. |
| `MEMOKIT_CAREFUL_OFF=1` | Disables the destructive-command guard. (`MEMOKIT_GUARD_OFF=1` disables it too.) |
| `MEMOKIT_SCRATCH_OFF=1` | Disables the subagent temp-footprint gate, and the SessionStart temp-leftover line and its cached total. |
| `MEMOKIT_DISK_OFF=1` | Disables the disk watch (drop warning, free-space floor, Stop message). |
| `MEMOKIT_AUTOCLEAN_OFF=1` | Disables the session-start auto-clean of stale temp entries and merged, clean leftover worktrees; they are only reported. |
| `MEMOKIT_TEMP_ROOT=<dir>` | Testing override of the temp root memokit inspects; for tests, do not set it in a real session. |
| `MEMOKIT_INIT_HINT=1` | Turns on the "run `/memokit:init`" hint (off by default since 0.6.2). With it the hint is added on every SessionStart (startup, resume, clear, compact) in a git work tree that has no `.claude/memokit.json` and no legacy `.claude/hooks/`. The pre-0.6.2 `MEMOKIT_NO_INIT_HINT=1` still silences it and wins over `MEMOKIT_INIT_HINT=1`. |
| `MEMOKIT_HOOK_DEBUG=1` | Each hook dumps the payload it received to `$TMPDIR/memokit-<hash>-hook-<name>.json` (`/tmp` if `TMPDIR` is unset). |

Troubleshooting:
- **Guards deny everything:** `jq` is missing or `.claude/memokit.json` is invalid. The guards fail closed, so the session cannot repair the config itself. Install jq, or fix `.claude/memokit.json` by hand (or set `MEMOKIT_GUARD_OFF=1` in `.claude/settings.local.json` `env` and start a new session to fix it there); the denial message names the cause.
- **No hooks fire:** the project has no `.claude/memokit.json`, or the plugin is disabled in `settings.json`.

## Temp space

Agents leave scratch copies behind and a full disk stops everything. `WORKING-MODEL.md` §7 gives the rules (copy only tracked and untracked-not-ignored files, one dedicated scratchpad directory per task, delete it before returning, end every report with `temp left: <size>`). Three things enforce them:
- a SubagentStop gate blocks a subagent that leaves `scratch.agentMaxMB` or more of new files in the scratchpad (`MEMOKIT_SCRATCH_OFF=1` disables it);
- a disk watch warns when one command eats `disk.dropWarnGB` or free space is below `disk.minFreeGB`, and SessionStart reports stale leftovers of at least `scratch.reportMinMB` and low disk (`MEMOKIT_DISK_OFF=1` disables the watch);
- SessionStart removes stale leftovers of finished sessions by itself in the background (nothing under them holding `.memokit-keep`; `MEMOKIT_AUTOCLEAN_OFF=1` disables it), and reports what it keeps. "Stale" means the session's transcript has been idle longer than `scratch.staleAfterHours` (a loose entry: born that long ago), so a session left open but idle that long counts as finished;
- `/memokit:sweep` measures stale leftovers, asks, and deletes the approved ones. The destructive-command guard lets a single simple `rm -rf` of a literal direct child of the current session scratchpad, or of a whole stale sibling temp entry, through without an approval code; every other recursive `rm` still needs one.

## Upgrading from 0.5.x

- **Test commands move to `.claude/memokit/gates.md`.** From 0.6.0 every coder slice, sequential ones too, takes its commands from `gates.md` and returns `BLOCKED` (`gates.md missing`) until it has a Tier-1 command; test commands in `coder.md` are no longer used for that. Move them from `coder.md` into `gates.md`: build and unit tests under `## Tier 1`; integration, Docker/Testcontainers, coverage, merge gate and E2E under `## Tier 2`. Or let the next session ask: `/memokit:resume` proposes the move once when `coder.md` has test commands and `gates.md` has no Tier-1 command.
- **Drop per-slice heavy gates from `coder.md`.** An overlay that asks for integration or Docker runs in every slice conflicts with the coder's Tier-1-only rule; the heavy gates now run once per batch, after your go.
- **New overlay skeletons.** `/memokit:init` stops on a configured project; run its scaffold step directly. Ask Claude in the project to run it, or in your own shell (where `CLAUDE_PLUGIN_ROOT` is not set) use the plugin cache: `bash ~/.claude/plugins/cache/memokit/memokit/<version>/skills/init/scripts/memokit-init.sh scaffold <project root> <tr|en>`. It adds the missing `analyst.md` and `gates.md` skeletons without overwriting any existing file; it also creates any other missing scaffold file, so review `git status` afterwards.
- **Ignore lines.** `.claude/memokit/runs/` and `.claude/worktrees/` arrive through `/memokit:init` on a new project or through the first `/memokit:parallel` run, which adds them idempotently and commits only `.gitignore`.

## Adopting an existing AI setup

Run `/memokit:init` in a repo that already has an AI setup (a `CLAUDE.md`, an `AGENTS.md`, Cursor/Copilot/Windsurf/Devin/Cline/Roo/Gemini/Kiro/Continue/Junie/Zed/Aider rules, `.claude/` agents, skills, commands, rules or hooks, or legacy per-repo `.claude/hooks/`). Adopt mode refuses to run on a dirty working tree and writes nothing until you approve one table. Every piece of content (a section, a rule, a command) is one row with a target or "kept in place":
- **Moved** (Claude-owned: root `CLAUDE.md`, `.claude/rules|agents|commands|skills`, project and legacy hooks): the content goes into memokit's structure (`CLAUDE.md`, `.claude/rules/<name>.md`, `.claude/memokit/rules.md`, `gates.md`, `coder.md` and the other overlays), then the original is edited or removed as the table says.
- **Copied** (other tools' files): usable content is copied and tagged `(source: <path>)`; the source file stays byte-identical unless you set its row to "remove the source".
- **Kept**: nested `CLAUDE.md`/`AGENTS.md` (checked for conflicts only), personal files (`CLAUDE.local.md`, `.claude/settings.local.json`, except the approved Artifact deny), framework artifacts (`docs/superpowers/`, `.specify/`, `openspec/`, ...), `.mcp.json`, output styles, and project hooks that do not inject context (e.g. a formatter).
- **`AGENTS.md` is never edited.** `CLAUDE.md` imports it with `@AGENTS.md`; Claude reads `AGENTS.md` natively only when no `CLAUDE.md` exists, so the import keeps it read (or starts it being read). Items that contradict memokit's working model go into a short override section right below the import.
- **Scoped rules** become `.claude/rules/<name>.md` with `paths:` frontmatter (from Cursor `globs`, Copilot `applyTo`, and so on). `.claude/memokit/rules.md` is for short, hard rules only and stays small (about 1.5 KB) because it is appended to every prompt.
- **Conflicts** (main session editing code, committing to main, E2E after every change, auto-commit/push hooks, code-writing project agents, superpowers steps that dispatch implementers) are shown with the memokit rule they contradict and are not carried over; you accept or cancel, there is no keep option. Context-injecting project hooks are read, classified and dropped from `settings.json` once their text has a home.
- The table ends with a before/after size summary of what is loaded per prompt and per session. The result is a single commit, only after you approve the diff; roll back with `git revert`.

With legacy per-repo hooks (detected by the memokit-style `inject-rules.sh` signature), adopt mode also extracts the constants (guarded dirs, tag, header, docs, custom hint patterns, rules text) into `memokit.json` and `rules.md`, and removes the old `.claude/hooks/`, `.claude/agents/`, `.claude/skills/handoff|resume` and the `settings.json` hook wiring. A project's own `.claude/hooks/` without that signature is treated as ordinary project hooks.

## Development

```
brew install bats-core shellcheck gitleaks
bats tests/
```

To try a local checkout: `/plugin marketplace add /path/to/memokit`.

Releases: `.claude-plugin/plugin.json` pins `version`, and `/plugin update` delivers nothing until that string changes. Every change to `hooks/`, `skills/`, `agents/` or `WORKING-MODEL.md` therefore bumps `version` in `.claude-plugin/plugin.json` and adds a `CHANGELOG.md` entry in the same change.

## Destructive commands

`guard-destructive.sh` denies a Bash command that matches a builtin pattern (`git push --force`/`-f`/`+ref`, `git reset --hard`, `git clean -f` (also with `-n`/`--dry-run`), `git branch -D` (also `-d -f`, `--delete --force`, `-df`), `git worktree remove --force`/`-f` (label `git-worktree-force`: it can discard a worktree's uncommitted work; a plain `git worktree remove` and `git branch -d` are not blocked), `git checkout -- .`/`git restore .` (`git restore --staged` alone is not blocked, nor is `git rm`), recursive `rm` outside `node_modules bin obj dist build .next coverage TestResults __pycache__ .pytest_cache`, `DROP`/`TRUNCATE`/`DELETE FROM` together with a SQL client (psql, pgcli, mysql, mariadb, sqlite3, sqlcmd), `dropdb`, `mysqladmin … drop`, `dotnet ef database drop`, `kubectl delete`, `helm uninstall|delete|del|un`, `docker system|volume prune`, `docker volume rm|remove`; docker global options are tolerated; unique abbreviations such as `git push --fo`, `git reset --ha` and `rm --rec` count, and the command names rm, git, kubectl, helm, docker and dotnet match in any case and with `.exe`) or a project pattern from `careful.patterns`. Quoted, escaped, prefixed and grouped spellings are matched as the command they run (`"rm" -rf x`, `r''m`, `\rm`, `sudo rm`, `timeout 5 rm`, `{rm,-rf,x}`, `(cd x && git reset --hard)`, `git push -f&`, zsh `/bin/rm(N)`), and a computed command word right before an rm-style recursive option (`$RM -rf x`, `/bin/r? -rf x`) counts as a recursive rm. A command longer than 64 KiB, or with more than 1000 distinct rm commands, is not checked but denied as `too-large` (write long files with the Write tool, or approve it). The deny message carries a 6-character code. To approve, start your next message with `onay <code>` or `approve <code>`; the AI then re-runs the exact same command once. A code is bound to the project and the exact command text and expires after 10 minutes. Edit, Write, MultiEdit and NotebookEdit to memokit's approval (grant) file are denied too, including through symlinks and in any letter case, so the AI cannot grant itself an approval; a Bash command naming that file in any case, also through a glob that keeps its name (`careful?grants`, `careful*grants`), is denied without a code, and so is a glob on a `memokit-` path in a temp location (`/tmp/memokit-*`, `$TMPDIR/memokit-*`) or next to `careful`; any other glob that may reach it (`careful*`, `../memokit-*`) is denied as `careful-state-glob`, which can be approved. Every deny message lists all labels the command matched.

It denies rather than asks because a hook's "ask" does not reliably prompt in auto mode or `claude -p`. It is an accident-prevention guardrail, not a sandbox, and the AI runs as your user. The approval code is derived from the project and the command text, so it is not a secret: it stops accidents, not an agent that deliberately works around it. Project patterns can only add to the builtin set. If another memokit guard also blocks the same command (a write to a guarded directory from the main session, git history commands from a subagent), an approval code does not help: that guard's rule applies.

Limitations: matching is on the command text only. A command name that exists only at run time is not seen (`$X push -f`, `$GIT reset --hard`, `$(printf %s r m) -rf x`, zsh `/bin/r(m|x) -rf x`, `$RM src -rf` with the option after an operand, SQL spelled `DROP${IFS}TABLE` or `DROP/**/TABLE`), nor is anything run from a script file, an alias or function, or a variable (`bash -c "$CMD"`). A shell that computes the grant file's path at run time (variables, `printf`) can still reach it: the approval code is an accident guard, not a security boundary against a deliberately adversarial agent. A glob on any `memokit-` path (e.g. `ls ../memokit-*`, which also matches memokit-NNN directories) asks for an approval code (`careful-state-glob`); spelling the path out avoids it. False positives are accepted and ask for an approval code: quotes are not parsed, so quoted text is matched like a command (a commit message mentioning `git push --force` or `rm -rf`), and a computed command word directly followed by an option made of rm's letters with `r`/`R` (`"$EDITOR" -R notes.md`, `ls *.log -R`, `tar -C "$d" -rvf a.tar`) counts as a recursive rm. A failing or silent tool in the check (awk, sed, grep, tr, jq) denies the command instead of letting it through: as `unparsed`, as `careful-state` (no approval possible) when the approval-file check itself cannot run, or with a static message when jq fails.

## Türkçe

memokit, Claude Code için bir çalışma modeli plugin'idir: ana oturum (orkestratör) üretim kodu yazmaz, kodu bir Sonnet alt ajanı (`memokit:coder`) yazar, her dilimi bir Opus gözden geçirici (`memokit:reviewer`) onaylar. Oturum ritüelleri `docs/STATE.md` dosyasını güncel tutar; bağlam bütçesi aşılınca yapay zekâ kendi kararıyla ölçülü bir handoff yapar.

memokit'i **bir kez, kullanıcı düzeyinde** kurun:

```
/plugin marketplace add tsrmehmet/memokit
/plugin install memokit@memokit
```

`/plugin install` penceresinde kullanıcı kapsamını seçin (kabukta: `claude plugin install memokit@memokit --scope user`). Manifest `"defaultEnabled": true` ayarladığı için kurulumla birlikte memokit her projede etkin olur. `.claude/memokit.json` olmayan projelerde hook'lar sessiz kalır, `memokit:` önekli ajan ve skill'ler kendiliğinden durur; "`/memokit:init` çalıştırın" ipucu varsayılan olarak kapalıdır (`MEMOKIT_INIT_HINT=1` açar). `/memokit:init`, depoyu klonlayan herkese de memokit önerilsin mi diye sorar; yalnız evet cevabında projenin paylaşılan `.claude/settings.json` dosyasına `enabledPlugins["memokit@memokit"] = true` ve marketplace kaydını yazar. Önerilen cevap, depoyu siz yönetmiyor ve ekip onaylamadıysa hayırdır: bu kayıt her katkıcıya üçüncü taraf bir eklenti önerir, sizin için kullanıcı kapsamlı kurulum zaten yeterlidir. Güvenmediğiniz bir depoda ilk oturumdan önce `.claude/memokit.json` dosyasına bakın: `sessionStart.healthScript` her oturum başında, `graph.refreshScript` handoff'ta çalışır (deponun `.claude/settings.json` hook'larıyla aynı risk; memokit yalnız proje kökünün dışına çıkan betikleri reddeder).

Ardından memokit'i kullanacağınız git deposunda `/memokit:init` çalıştırın; proje adı, etiket, dil, korunan klasörleri ve kod grafiğini (graphify) sorar, `.claude/memokit.json` dosyasını yazar. `graph` ayarlıysa her handoff kod grafiğini tazeler (yalnız kod, LLM yok); handoff'un son adımı telefonuna bildirim gönderir (Remote Control bağlıyken). Türkçe yanıt ve hook mesajları için `memokit.json` içinde `"language": "tr"` ayarlayın. Acil durumda korumaları kapatmak için `MEMOKIT_GUARD_OFF=1` değerini `.claude/settings.local.json` içindeki `env` bölümüne yazın ya da `claude`'u başlatmadan önce dışa aktarın. Kişisel bir altyapıdır, olduğu gibi paylaşılır; destek garantisi yoktur. Yıkıcı komutlar (force push, reset --hard, özyinelemeli rm, yıkıcı SQL, kubectl/helm delete ve projenin `careful.patterns` kalıpları) engellenir; onay için bir sonraki mesajınıza `onay <kod>` ile başlayın. Bu bir kaza önleme korkuluğudur, sandbox değildir: yalnızca komut metnine bakar. 64 KiB'tan uzun (ya da 1000'den fazla rm komutu içeren) bir komut denetlenmez, `too-large` olarak engellenir; uzun dosyaları Write aracıyla yazın ya da onay kodu verin. Kırmızı ve flaky testler için `/memokit:triage`.

Birden çok bağımsız görev için `/memokit:parallel`: her şerit (lane) kendi git worktree'sinde çalışır (aynı deponun, kendi dalı ve dosyaları olan ayrı bir çalışma klasörü; şeritler birbirinin dosyasının üzerine yazamaz). Akış: analiz → plan onayı → öngörülen tüm kararlar tek seferde sorulur → en fazla `parallel.maxCoders` şerit aynı anda → riske göre gözden geçirme (`high` Opus, `normal` Sonnet; `review.model`) → sırayla birleştirme → worktree ve dalın hemen temizlenmesi → Opus ile tüm batch'in gözden geçirilmesi → Tier 2 sorusu. Testler iki katmanlıdır (WORKING-MODEL.md §9): Tier 1 (build + birim testleri + dilimin yeni testleri) her dilimde; ağır kapılar (Tier 2) batch başına bir kez ve yalnız kullanıcı onaylarsa. Komutlar `.claude/memokit/gates.md` dosyasındadır. Koşunun durumu git'e girmeyen yerel bir ledger dosyasında tutulur, handoff ve resume onu sürdürür. Artakalan worktree ve `mk/*` dalları oturum başında raporlanır; 0.6.1'den beri birleşmiş, temiz ve `scratch.staleAfterHours` boyunca kullanılmamış olanlar ile önceki oturumların eski temp dosyaları arka planda otomatik silinir (`MEMOKIT_AUTOCLEAN_OFF=1` kapatır); geri kalanları `/memokit:sweep worktrees` onayınla siler, birleşmemiş ya da değişiklik içeren iş hiçbir zaman otomatik silinmez; etkin bir koşunun (ledger `status: active`) şeritleri artakalan sayılmaz, oturum başı o koşuyu adıyla anar. `git worktree remove --force` bir onay kodu ister (`git-worktree-force`).

0.5.x'ten yükseltirken: test komutlarını `coder.md` dosyasından `.claude/memokit/gates.md` dosyasına taşıyın (`## Tier 1`: build + birim testleri; `## Tier 2`: entegrasyon, Docker, E2E) ve `coder.md` içindeki dilim başı ağır kapıları kaldırın; ya da bunu bir sonraki oturuma bırakın, `/memokit:resume` bir kez sorar. Ayrıntılar: "Upgrading from 0.5.x".

Zaten bir yapay zekâ kurulumu olan projede (CLAUDE.md, AGENTS.md, başka araçların kuralları, `.claude/` ajan/skill/hook'ları, eski per-repo hook'lar) `/memokit:init` benimseme (adopt) kipine girer: temiz çalışma ağacı ister, tek bir tablo gösterir ve onayınıza kadar hiçbir şey yazmaz. Claude'a ait kaynaklar memokit yapısına taşınır; diğer araçların dosyaları bayt bayt aynı kalır (içerik `(source: ...)` etiketiyle kopyalanır); `AGENTS.md` asla düzenlenmez, `CLAUDE.md` onu `@AGENTS.md` ile içe aktarır ve çelişen maddeler hemen altında bir geçersiz kılma bölümünde listelenir. Belirli dosya kalıplarına bağlı kurallar `paths:` ile `.claude/rules/` altına gider; `rules.md` her istemde eklendiği için küçük (yaklaşık 1,5 KB) tutulur. Kişisel dosyalara (`CLAUDE.local.md`, `.claude/settings.local.json`) dokunulmaz; tek istisna onayladığınız Artifact deny kuralıdır. Sonuç tek bir commit'tir; geri almak için `git revert`. Ayrıntılar: "Adopting an existing AI setup".

## License

MIT. See [LICENSE](LICENSE).
