<!-- Test tiers (WORKING-MODEL.md §9). memokit:coder runs Tier 1; the orchestrator runs Tier 2. -->
## Tier 1 — every slice (build, unit tests of the touched projects; no integration or E2E; may exec into an already running dev container, never start one)
<!-- One line per stack; must run without secrets (lane worktrees have none), e.g. `<stack>: <build command> && <unit test command>` -->
<!-- It runs in every slice, so keep it fast and scoped to the touched projects; whole-repo static analysis or full suites go to Tier 2. -->

## Tier 2 — once per batch, only after the user approves
<!-- Heavy gates in order, e.g. integration per service, coverage, merge gate, E2E. -->
