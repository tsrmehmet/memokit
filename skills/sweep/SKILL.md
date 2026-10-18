---
name: sweep
description: Only in projects that have .claude/memokit.json — clean the stale temp leftovers earlier sessions left in this project's Claude temp dir (/private/tmp/claude-<uid>/<project>/): measure, ask in the decision format, delete only approved stale entries one literal rm -rf at a time, re-measure and report freed space. Use when the user says /sweep, "disk dolu", "disk full", "yer kalmadı", "temp temizle", or the session-start line reports earlier sessions' leftovers.
---

# Sweep — stale temp leftovers

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

## Never
- Delete the current session's dir or anything in it, or any `active` or `manual` entry.
- Delete anything outside this project's temp dir, or anything the user did not approve.
- Batch several paths in one command, use a loop, a variable or a glob, or route around the guard.
- Claim space was freed without the measurement from step 4.
