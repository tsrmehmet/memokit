---
name: learn
description: Only in projects that have .claude/memokit.json — mine this session's transcript for hook denies, tool errors, user corrections and repeated commands, propose at most 5 short rule lines and write only the lines the user approves. Use when the user says /learn or "learn/öğren", or when the handoff points here.
---

# Learn — turn this session's friction into rules

Goal: what went wrong more than once in this session (the user corrected you, a hook denied the same thing, a tool kept failing, a command was retyped) becomes a short rule the next session follows. Talk to the user in the project `language` (`.claude/memokit.json`). Nothing is written without the user's approval of that exact line.

## Steps

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here. Do nothing else from this skill.

1. **Main session only, this session only.** A subagent never runs this skill: its shell carries `CLAUDE_CODE_CHILD_SESSION=1` (and its parent's session id), and the script refuses with exit 3. Other sessions' transcripts are out of scope.

2. **Mine.**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/skills/learn/scripts/memokit-learn.sh" mine; echo "learn-exit=$?"
   ```
   Without an argument it reads this session's transcript, `~/.claude/projects/<slug>/$CLAUDE_CODE_SESSION_ID.jsonl` (the Bash tool environment carries `CLAUDE_CODE_SESSION_ID`; the script looks the id up in every project folder), and falls back to the newest `.jsonl` in the project's own folder (`<slug>` = the project path with every character outside `A-Za-z0-9` turned into `-`). If that picks the wrong file, pass the path: `memokit-learn.sh mine <transcript>`. A non-zero exit: show its message and stop.

   It prints one JSON object with four lists:
   - `denies` — PreToolUse hook denies: `label` (e.g. `[TAG-CAREFUL] rm-recursive`), `count`, `first` command or path;
   - `errors` — tool errors that were not a deny or a rejection: `tool`, `count`, `first` error line;
   - `corrections` — user messages whose first line starts with a correction word (tr `hayır|yanlış|yapma|değil|olmaz|dur`, en `no|wrong|don't|stop|not that`): `user` line and the `assistant` line that followed;
   - `repeats` — identical Bash commands run 3 times or more: `command`, `count`.

3. **Show the table** — one row per item, numbered by kind (`D1`, `E1`, `C1`, `R1`); this number is the evidence row a proposal cites:

   | # | Kind | What | Count | First / reply |
   |---|---|---|---|---|

   The correction match is a first-word match: a row that is not a correction ("no problem", "stop the server please") stays in the table marked "not a correction" and is not used. If nothing usable is left, say there is nothing to learn and stop.

4. **Propose at most 5 rule lines.** Each line is one imperative sentence of at most 160 characters (measure: `jq -rn --arg l '<line>' '$l | length'`), shown with its evidence row (`← C1, D2`). Read `.claude/memokit/rules.md`, CLAUDE.md and `docs/LESSONS.md` (if present) first and do not repeat what they already say. Propose only what generalises:
   - a correction → what the user wants instead;
   - a deny label hit more than once → how to work with it (ask first, request the change window, use a subagent), never a way around the hook;
   - a recurring error with a known cause → the check that avoids it;
   - a repeated command → when to run it, or a script or `gates.md` entry for it.

   Never propose a line that loosens WORKING-MODEL.md §1–§10, a guard or an approval step, and never copy secrets, tokens or command output into a line.

5. **Ask per line** — one message, every line numbered, each with its choice:
   - `.claude/memokit/rules.md` — prompt-injected: appended to every prompt, so only short, hard rules. Show its size now and after the line, measured with `wc -c < .claude/memokit/rules.md` (a missing file is 0) plus the line's bytes (`printf '%s\n' '<line>' | wc -c`). The file stays at most 1536 bytes (1.5 KB), never exceeded: a line that would cross it is not offered there — offer to shorten it, to replace a named existing line, `docs/LESSONS.md`, or drop.
   - `docs/LESSONS.md` — offered only if the project already uses it (the file exists); never created here.
   - drop.

   The question says that the approved lines will be written and committed (step 7). The user answers per number ("1 → rules.md", "2 → drop"); an edited wording is shown again before it counts. A line without an answer is dropped. Nothing is written without that per-line answer.

6. **Write the approved lines** exactly as approved: append each to `.claude/memokit/rules.md` (one line, `- ` prefix; create the file if missing) or to `docs/LESSONS.md` in that file's existing format (date, lesson, its evidence in a few words). Measure again: `wc -c < .claude/memokit/rules.md` must be ≤ 1536; if it is not, remove the line just added and tell the user. Show the sizes and `git diff --stat`.

7. **Commit** only the files written, by pathspec — the per-line approval covers this commit, and the handoff needs a clean tree:
   ```bash
   git add -- <files> && git commit -m "docs(learn): <n> rule line(s) from this session" -- <files>
   ```
   Skip a file git ignores. Then summarise in one line: lines written where, lines dropped.

## Don't
- Write a line the user did not approve, or change its wording after approval.
- Let `.claude/memokit/rules.md` exceed 1536 bytes, even by one line.
- Read other sessions' transcripts or run this in a subagent.
- Turn a hook deny into advice to bypass, disable or weaken the hook.
