---
name: sweep
description: Only in projects that have .claude/memokit.json — clean the stale temp leftovers earlier sessions left in this project's Claude temp dir (/private/tmp/claude-<uid>/<project>/), and leftover worktrees under .claude/worktrees/ and mk/* branches: measure, ask in the decision format, delete only approved stale temp entries (one literal rm -rf at a time) and approved merged-clean worktrees/branches (one git worktree remove / git branch -d at a time), re-measure and report freed space. Use when the user says /sweep, "disk dolu", "disk full", "yer kalmadı", "temp temizle", "worktree temizle", or a session-start line reports earlier sessions' leftovers or leftover worktrees.
---

# Sweep — stale temp leftovers and leftover worktrees

Goal: give back disk space that finished sessions left behind, without ever touching a live session. Talk to the user in the project `language` (`.claude/memokit.json`). Deletion is irreversible, so the user decides what goes.

## Steps

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here and do nothing else from this skill.

1. **Measure.**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/sweep/scripts/memokit-temp.sh" list
   "${CLAUDE_PLUGIN_ROOT}/skills/sweep/scripts/memokit-temp.sh" free
   ```
   `list` prints TSV: `stale|active|manual`, KB, human size, last activity (UTC), absolute path; largest first. The current session is never in it. Show two tables:
   - **Stale** (offered): path, size, last activity, total.
   - **Possibly active, not offered**: the `active` rows, listed for information only.
   - Only `stale` rows are ever offered. A `manual` row has a character in its path outside `A-Za-z0-9._/@+,:%-` (a space, `[`, `=`, a control character shown as `?`, ...), so no single literal `rm -rf` is safe for it: list it separately for the user to handle by hand and never include it in "all stale".

   Nothing stale → report the free space and stop.

2. **Ask** with `AskUserQuestion`, in the WORKING-MODEL.md §2 format:
   - **Recommendation**: "all stale", because these sessions' transcripts are older than `scratch.staleAfterHours`, so nothing in them is in use.
   - **Stakes**: the files are gone for good; a stale entry could still hold output somebody wanted.
   - **Reversibility**: one-way door (deletion is irreversible); never taken without the user's answer, not even in an autonomous handoff.
   - **Options**, one line each: `all stale` (recommended: frees the most, N entries, X GB) · `pick` (user chooses entries from the table: slower, keeps what they want) · `cancel` (nothing deleted).

   `pick` → ask which rows, then continue with only those.

3. **Delete.** After the approval, remove each approved entry with its OWN Bash call, exactly:

   `rm -rf <literal absolute path exactly as listed>`

   - One entry per call, whole command only that `rm`: never `&&`, `;`, pipes, loops, variables, `$(…)`, quotes around a glob, trailing `/` or wildcards. The destructive-command guard passes this form without an approval code only for a whole stale entry of this project's temp dir.
   - A path with a character outside `A-Za-z0-9._/@+,:%-`, or one the guard denies: do not work around the guard. Tell the user; they either approve with the code the guard prints or skip that entry.

4. **Re-measure and report.** Run `ls` on the project temp dir, `du -sk` on what is left, `df -h` on it, and `list`/`free` again. Report the freed space as measured (before minus after, with the commands' numbers), the entries removed, and any left behind with the reason.

## Leftover worktrees and `mk/*` branches

Parallel lanes (`.claude/worktrees/mk-<run>-<lane>` on `mk/<run>/<lane>`) and Claude Code's own agent worktrees (`.claude/worktrees/agent-*`) can outlive their run. They are git state, not temp files: a worktree can hold the only copy of uncommitted work or of ignored local files (a `.env`, a nested repo), a branch the only copy of commits. Run this part when the session-start line reports leftover worktrees or the user asks (`/memokit:sweep worktrees` runs only this part, without the temp steps above); a multi-GB `agent-*` worktree on an unmerged feature branch is the typical case: it is reported, and only the user decides what happens to it. Lanes are found under the `.claude/worktrees/` of the main checkout and of every other worktree of the repository (a session in a sibling `git worktree add` checkout creates its lanes under its own `.claude/worktrees/`). The worktree this session runs in is never listed. An `mk/*` branch checked out in a worktree outside `.claude/worktrees` is not reported at all.

1. **Measure** (read-only, from the project root):
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/sweep/scripts/memokit-temp.sh" worktrees
   ```
   TSV: status, kind (`worktree` | `branch`), KB, human size (`?` = not measured within about 2 s), last commit (UTC), worktree path or branch, branch, merged-into (`head` | `default` | `-`), note. "Merged" means every commit is in the current branch (`head`) or in the default branch (`default`: `origin/HEAD`'s target, else `main`, else `master`). Statuses:
   - `active-run`: a lane (worktree or branch) of a parallel run whose ledger (`.claude/memokit/runs/<run>/ledger.md`, in whichever checkout ran it) says `status: active`; the note names the run. The run still owns it: `/memokit:resume` continues the run and its own cleanup removes the lane. Never offered, not even when merged and clean. A run the user ended early has `status: stopped`, and its lanes then get their ordinary status.
   - `merged-clean`: merged, no uncommitted, untracked or ignored file.
   - `merged-ignored`: merged and clean, but it has ignored files that `git worktree remove` would delete; the note names them (count and the first few, e.g. `ignored: 2 (.env, node_modules/)`).
   - `dirty`: uncommitted or untracked changes (or its status could not be read).
   - `unmerged`: the worktree's branch has commits in neither the current nor the default branch.
   - `orphan-branch`: an `mk/*` branch with no worktree and commits in neither.
   - `detached`, `locked`, `prunable` (directory or its `.git` link gone): memokit cannot prove removal is safe.
   - `manual`: merged, but either a nested repo sits under an ignored dir (note says so), or the name under `.claude/worktrees/` or the branch has a character outside `A-Za-z0-9._/@+,:%-` (or the path a quote or a `?` standing for a control character), so no single literal command is safe for it.

   Show four tables:
   - **Offered**: path or branch, size, last commit, merged-into, total. Only `merged-clean` rows are offered, except branch rows merged into `default`.
   - **Delete from the default branch**: `merged-clean` branch rows (kind `branch`) whose merged-into is `default`. git refuses `git branch -d` for them while the session is off the default branch, so they are not in the "all merged-clean" offer: tell the user to run `git branch -d <branch>` after switching to the default branch.
   - **On request only**: `merged-ignored` rows with their note.
   - **Listed, not offered** (the user decides, by hand): every other row with its status and what it means, e.g. "`unmerged`: 3 commits only on `feature/x`; merge or keep it", "`active-run`: lane of run <id>, which `/memokit:resume` continues". Say how to look (`git log <current>..<branch>`, `git -C <path> status --ignored`); do not run any change for them.

   Nothing offered or on request → report the listed rows and stop.

2. **Ask** with `AskUserQuestion`, in the WORKING-MODEL.md §2 format:
   - **Recommendation**: "all merged-clean", because their commits are already in the current or the default branch and they hold no uncommitted, untracked or ignored file.
   - **Stakes**: removal deletes the checkout; a branch can be recreated from the commits, which the current or default branch keeps.
   - **Reversibility**: one-way door for the checkout; never taken without the user's answer, not even in an autonomous handoff.
   - **Options**, one line each: `all merged-clean` (recommended: N entries, X GB; never `merged-ignored` rows, nor branch rows merged into `default`) · `pick` (user chooses rows) · `cancel` (nothing removed).

   A `merged-ignored` row goes only by an explicit per-row pick, after a separate question for that row whose Stakes line names its ignored entries (e.g. "deletes `.env` and `node_modules/` for good").

3. **Remove.** After the approval, each approved row with its OWN Bash call, exactly as listed, the path in single quotes:
   - a `merged-clean` (or picked `merged-ignored`) worktree: `git worktree remove '<literal absolute path>'`; then, when its branch starts with `mk/`, `git branch -d <branch>` in a separate call (other branches, e.g. an `agent-*` worktree's feature branch, are left alone unless the user asks);
   - a `merged-clean` branch row merged into `head`: `git branch -d <branch>`.

   `git branch -d` checks the current HEAD (lanes have no upstream), so it refuses a branch whose merged-into is `default` while the user is on another branch. The worktree removal has still succeeded; the branch stays. Tell the user it can be deleted with `git branch -d <branch>` from the default branch. One entry per call, the whole command only that `git` call. If git refuses (it found changes, a lock, or an unmerged branch), stop for that row and tell the user what git said; do not retry another way.

4. **Re-measure and report.** Run `git --no-optional-locks worktree list`, `git branch --list 'mk/*'` and `worktrees` again; report the rows removed, the space freed as measured by the `worktrees` sizes before and `df -h` after, and every row left with its status.

## Never
- Delete the current session's dir or anything in it, or any `active` or `manual` entry.
- Delete anything outside this project's temp dir, or anything the user did not approve.
- Batch several paths in one command, use a loop, a variable or a glob, or route around the guard.
- Claim space was freed without the measurement from step 4.
- Remove a worktree or branch that is not `merged-clean` (an `active-run` lane never), except a `merged-ignored` row the user picked by name after seeing its ignored files; or the worktree this session runs in.
- Use `--force`/`-f` with `git worktree remove`, `-D` or `-d -f` with `git branch`, `git worktree prune`, `rm -rf` on a worktree, or any other way around git's own refusal.
