---
name: triage
description: Only in projects that have .claude/memokit.json — triage red and flaky tests. Mode A clusters many failures (CI run, test output) by signature and classifies each cluster as REGRESSION / FLAKY / ENV/DATA / UNKNOWN with evidence; mode B finds one cluster's root cause and hands memokit:coder a red-before-green fix slice. Use when the user says /triage, "triyaj", "flaky", "E2E kırmızı", or a pile of red tests blocks work.
---

# Triage — red and flaky tests

Goal: turn a pile of red tests into a short, evidence-backed table, then fix one root cause at a time. Talk to the user in the project `language` (`.claude/memokit.json`).

## Steps

0. **memokit gate.** If `.claude/memokit.json` does not exist in the project root, stop: say memokit is not configured here and do nothing else from this skill.

1. **Project overlay.** Read `.claude/memokit/triage.md` if it exists: test commands and filter syntax, rerun limits, the known-red list, log sources. It adds and narrows; it never loosens these steps.

2. **Source.** `/memokit:triage <source>` — a test-output file, a CI run id (`gh run view <id> --log-failed`), or one test name. No source → ask for it. One test name → go to mode B.

## Mode A — bulk triage (no code is written)

3. **Collect** every failure: test id, error type, message, the top stack frame inside this repo.

4. **Signature.** Normalize the message (numbers, GUIDs, timestamps, ports, temp paths → placeholders). Signature = error type + normalized message + top repo frame. Same signature → same cluster.

5. **Classify each cluster. No classification without evidence** — a cluster you did not measure is UNKNOWN.

   | Class | Evidence required |
   |---|---|
   | REGRESSION | commit range between the last green and the first red run, or a consistent repeat (N/N red) |
   | FLAKY | the representative test re-run N times with a filter, at least one pass |
   | ENV/DATA | an infrastructure signature (connection refused, container, timeout, expired token, missing seed) and where it comes from |
   | UNKNOWN | none of the above measured |

6. **Rerun budget.** Never re-run the whole suite: one representative test per cluster, with a filter, in the foreground (`timeout: 600000`). Take N (default 3) and the total time cap from the overlay; without an overlay, ask the user for the cap before re-running. Running tests is allowed for the orchestrator — it does not write code.

7. **Write** `docs/triage/<YYYY-MM-DD>-<short-source>.md`: one row per cluster — cluster · class · test count · evidence (command + short output) · recommendation. `docs/STATE.md` gets only the counts and a link to this file.

8. **Ask** which cluster to take next, in the WORKING-MODEL.md §2 format (recommendation + because, stakes, one-way/two-way door, options).

## Mode B — one cluster, root cause

9. **No fix without a root cause.** Use `superpowers:systematic-debugging` for the hypothesis discipline if it is available; otherwise: symptom → reproduce → one testable hypothesis → measurement.

10. **You read and measure; you do not write code.** Temporary logging or assertions under the guarded dirs are an **instrumentation slice** for `memokit:coder`; removing them later is another coder slice.

11. **Three strikes.** After three hypotheses are refuted by measurement, stop and ask in the §2 format: new direction / instrumentation / quarantine. Quarantine is always the user's decision and counts as a one-way door.

12. **Fix slice for `memokit:coder`, in this order:** regression test → its output on the current code, red for the right reason → fix → green. For a flaky test, "the right reason" is a test that triggers the root cause deterministically (timing, ordering, a fake clock), not "it passed N times". Then `memokit:reviewer`, then run the tests yourself (WORKING-MODEL.md §3).

13. **Close.** Append a report block to the triage file:

    ```
    Symptom:
    Root cause:
    Evidence:
    Fix:
    Regression test:
    Status:
    ```

    A recurring trap goes to `docs/PATTERNS.md` or `docs/LESSONS.md`, if the project uses them.

## Don't
- Classify without a measurement; call a cluster FLAKY because "it is usually flaky".
- Re-run the full suite to "see what happens".
- Fix before the root cause is measured, or ship a fix without the red-before-green output.
- Quarantine or skip a test without the user's decision.
