A runbook is a script in this directory that performs one server change (deploy, restart, migration); the orchestrator runs it inside an approved change window.
Approval is by content: the user approves the runbook's sha256, so editing the file after approval needs a new approval.
Example: `bash .claude/memokit/runbooks/deploy-prod.sh` (the guard shows its sha256 and asks for `approve <code>`).
