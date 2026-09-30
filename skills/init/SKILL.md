---
name: init
description: Set up memokit in the current project (new project) or migrate a project from legacy per-repo hooks. Use only when the user asks for /memokit:init or explicitly asks to set up/migrate memokit — never on your own.
---

# /memokit:init

Talk to the user in their language. Script: `"${CLAUDE_PLUGIN_ROOT}/skills/init/scripts/memokit-init.sh"` (below: `$INIT`). Root: the current project root.
memokit must be installed and enabled for this project (`claude plugin enable memokit@memokit --scope local`).

## 0. Detect
Run `$INIT detect "$ROOT"`.
- `git:false` → stop: "memokit needs a git repository — run `git init` first."
- `configured:true` → stop: already set up; offer to show `.claude/memokit.json`. If the hooks report it as invalid, do not try to repair it from this session (the guards deny every Edit/Write/Bash call while it is invalid): tell the user to fix `.claude/memokit.json` by hand, or to set `MEMOKIT_GUARD_OFF=1` under `env` in `.claude/settings.local.json`, start a new session to fix it, then remove the override.
- `legacy:true` → go to **Migration mode** (below). Never mix modes.

## 1. New project — ask (one message, with proposed defaults)
- Project name (default: folder name) and tag (2–10 uppercase letters/digits; propose one).
- Language: `tr` or `en` (default: the language the user is speaking).
- Guarded dirs (default `src`, `tests`; propose extra dirs from the detected stack, e.g. `web` for a separate frontend).
- Docs to show at session start (default none).
- Code graph (graphify) — always ask, with a measured recommendation. Measure first: `command -v graphify` and `git ls-files <main source dir> | wc -l`. Recommend **yes** when graphify is installed and the source dir has roughly 50+ files (say: code only, AST extraction, no LLM tokens, seconds to a minute; refreshed on every handoff that changed code); recommend **later** for an empty or tiny project (it can be added to `.claude/memokit.json` any time). If graphify is not installed, say so and recommend installing it before enabling this. Proposed setting: `"graph": {"root": "<main source dir>"}` (`maxCommitsBehind` defaults to 20).
If the stack is empty/unknown, say you will use defaults and that `/memokit:init` can be re-run after the tech decision (edit `.claude/memokit.json` directly then).

## 2. Write
1. Build the config JSON in a temp file; `$INIT write-config "$ROOT" <file>`.
2. `$INIT scaffold "$ROOT" <lang>` — it never overwrites; show the created/kept list.
3. `$INIT settings "$ROOT"`.
4. Code graph — only if the user said yes:
   - `git check-ignore -q graphify-out/graph.json || echo not-ignored`; if not ignored, append `graphify-out/` to `.gitignore`.
   - Look for ignored files that exist under the root: `git ls-files -o -i --exclude-standard <root> | head -50`. graphify does not read nested `.gitignore` files, so build output or secrets found there (e.g. `.env`, auth/session files, bundles) go into a `.graphifyignore` at the repo root before the first build. Show the user what you excluded.
   - Build: `"${CLAUDE_PLUGIN_ROOT}/skills/handoff/scripts/memokit-graph.sh" refresh; echo "graph-exit=$?"` and show the output (node count, marker).
5. Show `git status --short` and `git diff` to the user. **Do not commit** unless the user says so.

## 3. Verify (WORKING-MODEL §3)
Tell the user to start a new session (hooks load at session start), then in that session check and show:
- a Write to `<first guarded dir>/probe.txt` from the main session is denied;
- the session-start context contains the project header and STATE;
- a prompt containing "hata"/"bug" gets the debugging hint.
Report each with its evidence.

## Migration mode (legacy `.claude/hooks/` present)

Preconditions — refuse and explain if any fails:
- `git status --porcelain` is empty.
- The user has confirmed in this conversation that AI coding in this project is finished and a handoff was done (the plan's §9.2 gate; never assume it).

Steps:
1. `$INIT extract-legacy "$ROOT"` → show the proposal to the user as a table (name, tag, guarded dirs, docs, health script, limits, custom hints, and for each covered hint a "project-specific remainder" column). The script handles both hint styles (`matches '<re>' && HINTS=…` pairs and the if-block style `if matches '<re>'; then … HINTS=… fi`).
   - Custom hints = pairs whose text is **not** covered by a builtin; convert their text to the memokit names (`/memokit:handoff`, `memokit:coder`, …).
   - Covered hints (`covered: true`) are replaced by the generic builtin, so for each one show its legacy text beside the builtin text (the `MK_T_IR_HINT_*` line for that builtin in `${CLAUDE_PLUGIN_ROOT}/hooks/messages/<language>.sh`) and fill the remainder column with whatever the legacy text says that the builtin does not (e.g. "main push goes live, no test gate" in a review hint, a freshness-rule reference in a graphify hint), or `none`.
   - `builtin`: all six unless the user wants fewer.
   - `docs`: turn `docsRaw` into `"path — description"` lines; drop `CLAUDE.md` (always read) and HISTORY notes (memokit adds them).
   - If the tag or name looks wrong (e.g. a cloned project still carrying another project's tag), propose a correction and ask.
2. Write `.claude/memokit/rules.md` = the project-specific part of `rulesRaw`: drop every rule the generic `[TAG-KURAL]` block already states (guarded-dir write ban, decision-point stop/ask, recommendation-with-rationale, STATE update + commit, no "done" without green tests / measurement, find-skills); keep the rest verbatim (e.g. scope verification sources, module boundaries, project-specific decision triggers). Also carry over every project-specific remainder from step 1: put it in `rules.md` when it applies on every prompt, or into a custom hint with the same `match` as the legacy hint when it should only fire with that keyword. Nothing from a covered hint may be dropped silently.
3. Split `.claude/agents/coder.md` and `reviewer.md`: everything not already in memokit's generic agents (stack line, test commands, project rules, project checks) goes to `.claude/memokit/coder.md` / `reviewer.md`, verbatim where possible.
4. Split legacy `handoff`/`resume` skills the same way into `.claude/memokit/handoff.md` / `resume.md` (e.g. ticket transitions, "talk first" gates beyond memokit's, `.council/` handling specifics).
5. CLAUDE.md: replace the working-model and decision-protocol sections that WORKING-MODEL.md now covers with the one-line pointer from the template; keep every project-specific section untouched.
6. `$INIT write-config "$ROOT" <file>` (after the user approved the table), then `$INIT remove-legacy "$ROOT"`. It refuses with exit 4 only when the legacy paths (`.claude/hooks`, `.claude/agents`, `.claude/skills`, `.claude/settings.json`) have uncommitted changes — the files written in steps 2–6 are expected to be dirty at this point. It stages the deletions but never commits.
7. If `vendoredSkills` is non-empty, ask whether to remove those copies (`git rm -r`).
8. If `scripts/knowledge-health.sh` exists, run it with `--fast`; if it now fails only because its hook check finds no `.claude/hooks/*` entries, report it (the hook check becomes vacuous; do not edit the script unless the user asks — knowledge-health belongs to a later sub-project).
9. Show `git status --short` and the full `git diff --cached` + `git diff`. **Wait for the user's explicit approval.** Then one commit:
   `chore(ai): migrate AI infra to memokit plugin` (with the Co-Authored-By line).
10. Tell the user to restart the session immediately after that commit: until the restart, the legacy and memokit hooks both run in this session and can give contradictory instructions. Do no other work in this session. In the new session, run the smoke tests listed in §3 above plus: a subagent `git push` is denied; `MEMOKIT_GUARD_OFF=1` disables the write guard.
Rollback: `git revert <commit>` restores the legacy hooks; memokit stays silent without `.claude/memokit.json`.
