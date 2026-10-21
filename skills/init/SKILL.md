---
name: init
description: Set up memokit in the current project (new project) or adopt its existing AI setup (CLAUDE.md, AGENTS.md, rules, agents, hooks). Use only when the user asks for /memokit:init or explicitly asks to set up/adopt memokit — never on your own.
---

# /memokit:init

Talk to the user in their language. Script: `"${CLAUDE_PLUGIN_ROOT}/skills/init/scripts/memokit-init.sh"` (below: `$INIT`). Root: the current project root.
memokit must be installed and enabled (a user-scope install, `claude plugin install memokit@memokit --scope user`, enables it for every project).

## 0. Detect
Run `$INIT detect "$ROOT"`.
- `git:false` → stop: "memokit needs a git repository — run `git init` first."
- `configured:true` → stop: already set up; offer to show `.claude/memokit.json`. If the hooks report it as invalid, do not try to repair it from this session (the guards deny every Edit/Write/Bash call while it is invalid): tell the user to fix `.claude/memokit.json` by hand, or to set `MEMOKIT_GUARD_OFF=1` under `env` in `.claude/settings.local.json`, start a new session to fix it, then remove the override.
- `inventoryError:true` → the inventory could not be read (its output was not valid JSON): tell the user and ask how to proceed; do not route to new-project mode.
- `aiSetup:true` (any CLAUDE.md, AGENTS.md, other-tool rules, `.claude/` agents/skills/commands/rules/hooks, a `.claude/hooks/` directory; `sources` counts the inventoried files; hooks alone can make `aiSetup` true with `sources` 0) → go to **Adopt mode** (below). Never mix modes.
- Otherwise → New project (§1). If `$INIT inventory "$ROOT"` lists only personal files, framework artifacts, `.mcp.json` or output styles, name them in one line and leave them untouched.

## 1. New project — ask (one message, with proposed defaults)
- Project name (default: folder name) and tag (2–10 uppercase letters/digits; propose one).
- Language: `tr` or `en` (default: the language the user is speaking).
- Guarded dirs (default `src`, `tests`; propose extra dirs from the detected stack, e.g. `web` for a separate frontend).
- Docs to show at session start (default none).
- Code graph (graphify) — always ask, with a measured recommendation. Measure first: `command -v graphify` and `git ls-files <main source dir> | wc -l`. Recommend **yes** when graphify is installed and the source dir has roughly 50+ files (say: code only, AST extraction, no LLM tokens, seconds to a minute; refreshed on every handoff that changed code); recommend **later** for an empty or tiny project (it can be added to `.claude/memokit.json` any time). If graphify is not installed, say so and recommend installing it before enabling this. Proposed setting: `"graph": {"root": "<main source dir>"}` (`maxCommitsBehind` defaults to 20).
- Artifact tool (Claude Code publishes HTML pages, e.g. UI mockups or design previews, to claude.ai) — always ask: "Will this project need Artifact pages (mockups, design previews)?" Recommend **no** unless the project has UI design work: its tool definition is loaded into every session's opening context (measured 2026-10: Artifact, Workflow and ScheduleWakeup together about 14.8k tokens). Answer no → it is denied in this project's git-ignored `.claude/settings.local.json` (step 2). It can be turned back on any time by removing `Artifact` from `permissions.deny` there.
- Team — always ask: "Should everyone who clones this repo be offered memokit too?" Recommend **no** unless the user maintains the repo and the team agreed: yes commits `.claude/settings.json` entries that register the `tsrmehmet/memokit` GitHub marketplace (not pinned to a version) and enable the plugin, so Claude Code offers every contributor a third-party plugin whose hooks run shell commands. With a user-scope install memokit already runs here for the user without it. Answer no → nothing is written to `.claude/settings.json` for registration.
If the stack is empty/unknown, say you will use defaults and that `/memokit:init` can be re-run after the tech decision (edit `.claude/memokit.json` directly then).

## 2. Write
1. Build the config JSON in a temp file; `$INIT write-config "$ROOT" <file>`.
2. `$INIT scaffold "$ROOT" <lang>` — it never overwrites; show the created/kept list. Besides the docs it creates the overlay skeletons `.claude/memokit/rules.md`, `coder.md`, `reviewer.md`, `.claude/memokit/analyst.md` (project analysis checks) and `.claude/memokit/gates.md` (test tiers, WORKING-MODEL §9). Offer to fill `gates.md` now: ask the user for the Tier-1 commands (build + unit tests, no Docker, no secrets) and the Tier-2 heavy gates, and write only what they give — never guess; left empty, the orchestrator asks before the first coder slice.
3. Only if the user said yes to Team: `$INIT settings "$ROOT"` (registers the marketplace and enables the plugin in `.claude/settings.json`, keeping every other key). If the user said no to Artifact: `$INIT deny-tools "$ROOT" Artifact` (adds it to `permissions.deny` in `.claude/settings.local.json`, keeps every other key, and makes sure git ignores that file); it takes effect from the next session.
4. Ignore parallel-run ledgers and lane worktrees (idempotent; `/memokit:parallel` creates them):
   ```bash
   git check-ignore -q .claude/memokit/runs/x || printf '\n.claude/memokit/runs/\n' >> .gitignore
   git check-ignore -q .claude/worktrees/x || printf '\n.claude/worktrees/\n' >> .gitignore
   ```
5. Code graph — only if the user said yes:
   - `git check-ignore -q graphify-out/graph.json || echo not-ignored`; if not ignored, append `graphify-out/` to `.gitignore`.
   - Look for ignored files that exist under the root: `git ls-files -o -i --exclude-standard <root> | head -50`. graphify does not read nested `.gitignore` files, so build output or secrets found there (e.g. `.env`, auth/session files, bundles) go into a `.graphifyignore` at the repo root before the first build. Show the user what you excluded.
   - Build: `"${CLAUDE_PLUGIN_ROOT}/skills/handoff/scripts/memokit-graph.sh" refresh; echo "graph-exit=$?"` and show the output (node count, marker).
6. Show `git status --short` and `git diff` to the user. **Do not commit** unless the user says so.

## 3. Verify (WORKING-MODEL §3)
Tell the user to start a new session (hooks load at session start), then in that session check and show:
- a Write to `<first guarded dir>/probe.txt` from the main session is denied;
- the session-start context contains the project header and STATE;
- a prompt containing "hata"/"bug" gets the debugging hint.
Report each with its evidence.

## Adopt mode (the project already has an AI setup)

Preconditions — refuse and explain if any fails:
- `git status --porcelain` is empty.
- The user has confirmed in this conversation that no AI coding session is running in this repo. With legacy hooks present (`inventory .legacy != null`), the confirmation must be that AI coding in this project is finished and a handoff was done (the plan's §9.2 gate; never assume it).

Rules for the whole flow:
- Nothing is written before the user approves the table. Cancel at any point before that leaves nothing written.
- Every piece of inventoried content ends in exactly one visible row, with a target or "kept in place". Nested `CLAUDE.md`/`AGENTS.md` stay in place and are checked for conflicts and duplicates only, except the AGENTS.md override line (step 4), which is the one permitted write.
- Claude-owned sources (root `CLAUDE.md`, `.claude/rules|agents|commands|skills/**`, project hooks, legacy hooks) are moved into memokit's structure, then the original is edited or removed as the approved table says.
- Other-tool sources (Cursor, Copilot, Windsurf, Cline, Roo, Gemini, Kiro, Continue, Junie, Zed, Aider, `AGENTS.override.md`) stay byte-identical by default. Usable content is copied and each copy is tagged `(source: <path>)`. The user may set a row to "remove the source"; never propose it by default.
- Personal files (`CLAUDE.local.md`, `.claude/settings.local.json`) are read for conflicts only: never write them or propose changes. The one exception is the approved Artifact deny, written by `$INIT deny-tools` (step 7.3).
- Ignored Claude-owned files: copy the content, keep the file (row note: "ignored by git: content copied, file kept"). If memokit's own paths (`.claude/memokit.json`, `.claude/memokit/`, `.claude/rules/`) would be ignored, add a `.gitignore` un-ignore row (`.claude/*` with `!` exceptions when `.claude/` itself is ignored).
- Symlinks: never edit through a link; a link to another source is that source. A `CLAUDE.md` → `AGENTS.md` link gets its own row: replace it with a real `CLAUDE.md` holding the `@AGENTS.md` import plus the Claude-specific content. Mechanics: remove the link first (`$INIT remove "$ROOT" CLAUDE.md`), then write the real `CLAUDE.md` (writing through the link would edit AGENTS.md).
- Framework artifacts (`docs/superpowers/`, `.specify/`, `specs/NNN-*/`, `_bmad*/`, `.bmad-core/`, `.taskmaster/`, `openspec/`, `.planning/`), `.mcp.json` and output styles: "kept (history/tooling)" rows, not read further. If a framework holds its own STATE file (e.g. `.planning/STATE.md`), add a warning row: memokit's `docs/STATE.md` is the one its rituals maintain.

Steps:
1. `$INIT inventory "$ROOT"` → JSON: `sources[]` (path, group, tool, kind, bytes, tracked, ignored, linkTarget, frontmatter), `hooks[]` (event, matcher, type, command, legacy, scriptPath, injectsContext; a non-command hook such as `type: "prompt"` is listed with `command: null`), `settingsError`, `settingsTracked`/`settingsIgnored` (whether `.claude/settings.json` is tracked / git-ignored; both false when absent), `legacy` (the `extract-legacy` output, non-null only for a real memokit legacy setup, i.e. when a tag was found; a project's own `.claude/hooks/` without that signature is ordinary project hooks: rows, `--drop-hook` for approved context-injecting ones, kept otherwise; `detect.legacy` is only dir-based and does not decide this). Read the sources; if `settingsError` is set, report it and ask. Split them into rows: a row is a section, a rule or a command, not a whole file.
2. Ask once (one message, proposed defaults taken from the inventory): the questions of §1 (name, tag, language, guarded dirs, docs, graph, Artifact, Team). For a repository the user does not maintain (e.g. an open-source clone), Team is no.
3. Classify each row (category → target):
   - project facts specific to Claude → `CLAUDE.md` (with the `@AGENTS.md` import and the WORKING-MODEL pointer line from the template)
   - short, hard rules that must be repeated every prompt → `.claude/memokit/rules.md` (keep it small, about 1.5 KB: it is appended to every prompt)
   - all other project rules → `.claude/rules/<name>.md`, with `paths:` frontmatter when the source was scoped to file patterns (Cursor `globs`, Copilot `applyTo`, Windsurf/Continue `globs`, Kiro `fileMatchPattern`, Cline `paths`), without it otherwise
   - test and build commands → `.claude/memokit/gates.md` (Tier 1: build + unit tests, no Docker/secrets; Tier 2: integration, E2E, coverage, Docker)
   - agent/ritual specifics → `.claude/memokit/coder.md`, `reviewer.md`, `analyst.md`, `handoff.md`, `resume.md`, `triage.md`
   - drop: covered (already in WORKING-MODEL or the generic agents; name where), drop: conflict, keep in place.
   - Content both CLAUDE.md and AGENTS.md state is kept once, in AGENTS.md. Copy verbatim, translating only into memokit names (`/memokit:handoff`, `memokit:coder`).
4. AGENTS.md: never edit it (root or nested). Import it with `@AGENTS.md` in CLAUDE.md and add a row for the effect: Claude reads AGENTS.md natively only when no CLAUDE.md exists, so in an AGENTS.md-only repo the import keeps it read, and in a repo with both files it starts being read. AGENTS.md conflicts go into a short override section right below the import, naming each item and the memokit rule that replaces it, e.g. "In this project these AGENTS.md items do not apply to Claude: committing straight to main (memokit WORKING-MODEL §1); E2E after every change (§9)." Each is a conflict row with target "override in CLAUDE.md". A nested AGENTS.md's override goes in the CLAUDE.md of the same directory, else in the root section with the directory named.
5. Conflicts: content that tells an agent to do what WORKING-MODEL, the generic agents or the hooks forbid (main session editing code, committing to main or subagents committing, E2E after every change, skipping review, auto-commit/push hooks). Each is a row with the source text, the memokit rule it contradicts, and "not carried over". Two exits per row: accept (drop the row; edit or remove a Claude-owned source; an other-tool source stays and the note says the conflict keeps applying in that tool but no longer in Claude), or cancel adopt. There is no keep option. Stricter project rules are not conflicts: they go to their target.
   - Project agents that write code in guarded dirs conflict with §1: their instructions go to `coder.md`, and the agent file is proposed for removal. Read-only agents (explorers, doc writers outside guarded dirs) are kept.
   - Superpowers (or similar) steps that dispatch implementer subagents (`subagent-driven-development`, `executing-plans`, parallel code dispatch) conflict; the row names `memokit:coder` slices and `/memokit:parallel` instead. Brainstorming, plans, debugging and verification are kept.
   - Hooks in `hooks[]` with `injectsContext:true` and a `scriptPath`: read the script and the files it references (when `scriptPath` is null, e.g. `bash x.sh` or `FOO=1 x.sh`, read the `command` itself to find the script), classify that text like any source, and propose `--drop-hook <event> <substring>`. Other project hooks (e.g. a formatter after Edit) are kept in place.
   - A hook with `command: null` (e.g. `type: "prompt"`) can carry rule text: classify it from the `inventory` entry like any source. `--drop-hook` never matches it; if its removal is approved, the row says "remove it by hand" and the user does.
   - If `settingsIgnored` or not `settingsTracked` (`.claude/settings.json` is git-ignored or untracked), a context-injecting hook gets its text copied and the row says "drop it yourself; not revertable" — no `--drop-hook` (the edit would be invisible to `git diff` and `git revert` cannot restore it).
   - Legacy only: if `vendoredSkills` is non-empty, add a row "remove vendored skill copies" (it is part of this one table; do not ask after approval).
   - Project skills/commands that duplicate memokit's rituals (handoff, resume, commit flow, code review) are split into the matching overlay and removed; the rest are kept.
6. Show the table: columns `#`, source (path, section), content (one line), category, target, note (source line, conflict reason, AGENTS.md import effect, per-prompt cost). End with a summary: files that will change, files removed, files kept byte-identical, conflicts dropped, `rules.md` byte size, and the project-specific bytes loaded per prompt/session (CLAUDE.md, imports, always-loaded `.claude/rules`, `rules.md`, context-injecting hooks) before vs after; a rise is shown with its reason. The user edits rows by number ("5 → keep", "9 → remove source"); re-show after edits. Ask for explicit approval of the table.
7. Write, in this order:
   1. If an approved `.gitignore` un-ignore row exists, apply it first, before anything is written under `.claude/`. Then `$INIT write-config "$ROOT" <file>`, then `$INIT scaffold "$ROOT" <lang>`.
   2. The overlays, `.claude/rules/*.md`, `gates.md` and the CLAUDE.md edit per the approved rows. With legacy hooks (`.legacy != null`), edits to files under `.claude/agents|skills|hooks` and to `.claude/settings.json` are not written here: they happen after 7.3, because `remove-legacy` refuses (exit 4) while those paths are dirty.
   3. With legacy hooks (`inventory .legacy != null`): `$INIT remove-legacy "$ROOT"` now, before any `settings` or `remove` (it refuses with exit 4 when the legacy paths are dirty — stop and report, write nothing more — and runs `settings --drop-legacy-hooks` itself). Then apply the deferred edits of 7.2.
      Then, with or without legacy hooks, `$INIT settings "$ROOT"` with one `--drop-hook <event> <substring>` per approved row; pass the hook's full `command` as the substring, and check that the printed `dropped N hook entries` equals the number of approved rows (a mismatch, or exit 3 = a pair matched nothing: stop and report); with no approved hook rows, skip it. The `--drop-*` forms never register the plugin: only if the user said yes to Team, `$INIT settings "$ROOT"` with no flags, as in §2 step 3. If the user said no to Artifact, `$INIT deny-tools "$ROOT" Artifact` as in §2 step 3.
   4. `$INIT remove "$ROOT" <path>...` for the other approved removals: Claude-owned files and other-tool sources the user set to "remove the source" (git rm of tracked, clean paths; exit 2 = bad, missing or outside path, exit 4 = untracked or dirty: stop and report). With legacy hooks (`.legacy != null`), also the vendored skills the table row approved (legacy subsection).
   5. The ignore lines (§2 step 4), then the code graph if the user said yes (§2 step 5).
8. Verify before commit: every path the table marks "kept" must be absent from `git status --porcelain`; every "remove" and "edit" row must appear there. A mismatch stops the flow and is reported.
9. Show `git status --short` and the full `git diff --cached` + `git diff`. **Wait for the user's explicit approval.** Then one commit:
   `chore(ai): adopt existing AI setup into memokit` (with the Co-Authored-By line).
10. Tell the user to restart the session immediately after that commit. With legacy hooks (`.legacy != null`): until the restart, the legacy and memokit hooks both run in this session and can give contradictory instructions. Do no other work in this session. In the new session, run the smoke tests of §3 plus: a subagent `git push` is denied; `MEMOKIT_GUARD_OFF=1` disables the write guard; a kept project hook still fires.
Rollback: `git revert <commit>`; memokit stays silent without `.claude/memokit.json`.

### When memokit legacy hooks are present (`inventory .legacy != null`)
`inventory .legacy` holds the `extract-legacy` output (or run `$INIT extract-legacy "$ROOT"`). Its rows go into the single table of step 6 (no separate table); its writes happen in 7.1 (config fields from step 1, via `write-config`), 7.2 (overlays, `rules.md`, CLAUDE.md), 7.3 (`remove-legacy`) and 7.4 (vendored skills; knowledge-health is run, not removed):
1. Build the proposal rows (name, tag, guarded dirs, docs, health script, limits, custom hints, and for each covered hint a "project-specific remainder" column). The script handles both hint styles (`matches '<re>' && HINTS=…` pairs and the if-block style `if matches '<re>'; then … HINTS=… fi`).
   - Custom hints = pairs whose text is **not** covered by a builtin; convert their text to the memokit names (`/memokit:handoff`, `memokit:coder`, …).
   - Covered hints (`covered: true`) are replaced by the generic builtin, so for each one show its legacy text beside the builtin text (the `MK_T_IR_HINT_*` line for that builtin in `${CLAUDE_PLUGIN_ROOT}/hooks/messages/<language>.sh`) and fill the remainder column with whatever the legacy text says that the builtin does not (e.g. "main push goes live, no test gate" in a review hint, a freshness-rule reference in a graphify hint), or `none`.
   - `builtin`: all six unless the user wants fewer.
   - `docs`: turn `docsRaw` into `"path — description"` lines; drop `CLAUDE.md` (always read) and HISTORY notes (memokit adds them).
   - If the tag or name looks wrong (e.g. a cloned project still carrying another project's tag), propose a correction and ask.
2. `rules.md` = the project-specific part of `rulesRaw`: drop every rule the generic `[TAG-KURAL]` block already states (guarded-dir write ban, decision-point stop/ask, recommendation-with-rationale, STATE update + commit, no "done" without green tests / measurement, find-skills); keep the rest verbatim (e.g. scope verification sources, module boundaries, project-specific decision triggers), subject to the `rules.md` size limit (longer, non-critical rules go to `.claude/rules/`). Also carry over every project-specific remainder from step 1: put it in `rules.md` when it applies on every prompt, or into a custom hint with the same `match` as the legacy hint when it should only fire with that keyword. Nothing from a covered hint may be dropped silently.
3. Split `.claude/agents/coder.md` and `reviewer.md`: everything not already in memokit's generic agents (stack line, test commands, project rules, project checks) goes to `.claude/memokit/coder.md` / `reviewer.md`, verbatim where possible.
4. Split legacy `handoff`/`resume` skills the same way into `.claude/memokit/handoff.md` / `resume.md` (e.g. ticket transitions, "talk first" gates beyond memokit's, `.council/` handling specifics).
5. CLAUDE.md: replace the working-model and decision-protocol sections that WORKING-MODEL.md now covers with the one-line pointer from the template; keep every project-specific section untouched.
6. `$INIT remove-legacy "$ROOT"` (step 7.3, after the writes of 7.1–7.2). It refuses with exit 4 (stop and report, write nothing more) only when the legacy paths (`.claude/hooks`, `.claude/agents`, `.claude/skills`, `.claude/settings.json`) have uncommitted changes — the files written in steps 2–5 are expected to be dirty at this point. It stages the deletions but never commits.
7. Vendored skills: removal happens in 7.4 only for the table row approved in step 6 (`git rm -r` via `$INIT remove`).
8. If `scripts/knowledge-health.sh` exists, run it with `--fast`; if it now fails only because its hook check finds no `.claude/hooks/*` entries, report it (the hook check becomes vacuous; do not edit the script unless the user asks — knowledge-health belongs to a later sub-project).
