#!/usr/bin/env bats
load helpers
@test "skill names" {
  grep -q '^name: handoff$' "$MK_REPO/skills/handoff/SKILL.md"
  grep -q '^name: resume$'  "$MK_REPO/skills/resume/SKILL.md"
  grep -q '^name: triage$' "$MK_REPO/skills/triage/SKILL.md"
  grep -q '^name: sweep$' "$MK_REPO/skills/sweep/SKILL.md"
  grep -q '^name: parallel$' "$MK_REPO/skills/parallel/SKILL.md"
}
@test "handoff verifies by measuring and uses the exact closing phrase" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  grep -q "Handoff güncel, sonraki oturumda 'devam et' demen yeterli." "$f"
  grep -q 'WORKING-MODEL.md §3' "$f"
  grep -q '.claude/memokit/handoff.md' "$f"
}
@test "resume applies overlay and delegates to memokit agents" {
  f="$MK_REPO/skills/resume/SKILL.md"
  grep -q '.claude/memokit/resume.md' "$f"; grep -q 'memokit:coder' "$f"; grep -q 'memokit:reviewer' "$f"
}
@test "closing phrase matches the context-budget message" {
  grep -q "Handoff güncel, sonraki oturumda 'devam et' demen yeterli." "$HOOKS/messages/tr.sh"
}
GATE_DESC='Only in projects that have .claude/memokit.json — '
GATE_STEP='If `.claude/memokit.json` does not exist in the project root, stop'
@test "handoff and resume are gated on .claude/memokit.json: description prefix and step 0 first" {
  for s in handoff resume triage parallel; do
    f="$MK_REPO/skills/$s/SKILL.md"
    sed -n '/^---$/,/^---$/p' "$f" | grep -qF "description: $GATE_DESC" || { echo "$s: description not gated"; false; }
    g="$(grep -nF "$GATE_STEP" "$f" | head -n1 | cut -d: -f1)"
    n="$(grep -nE '^1\. ' "$f" | head -n1 | cut -d: -f1)"
    [ -n "$g" ] || { echo "$s: no step 0 gate"; false; }
    [ "$g" -lt "$n" ] || { echo "$s: gate after step 1"; false; }
  done
}
@test "init is not gated (it is how a project gets configured)" {
  f="$MK_REPO/skills/init/SKILL.md"
  run grep -F "$GATE_DESC" "$f"; [ "$status" -ne 0 ]
}
@test "triage: evidence-based classes, 3-strike stop, red before green, overlay" {
  f="$MK_REPO/skills/triage/SKILL.md"
  for s in 'REGRESSION' 'FLAKY' 'ENV/DATA' 'UNKNOWN' 'No classification without evidence' \
           'superpowers:systematic-debugging' '.claude/memokit/triage.md' 'docs/triage/' \
           'three hypotheses' 'red for the right reason' 'WORKING-MODEL.md §2' 'memokit:coder'; do
    grep -qF "$s" "$f" || { echo "missing: $s"; false; }
  done
}
handoff_add_line() { grep -E '^[[:space:]]*git add docs/' "$MK_REPO/skills/handoff/SKILL.md" | head -n1 | sed 's/^[[:space:]]*//'; }
@test "handoff step 7 stages docs/ when .council/ is absent" {
  mk_project none
  line="$(handoff_add_line)"; [ -n "$line" ]
  echo change >> "$PROJ/docs/STATE.md"
  run bash -c "cd '$PROJ' && $line"
  [ "$status" -eq 0 ] || { echo "rc=$status: $output"; false; }
  git -C "$PROJ" diff --cached --name-only | grep -qx 'docs/STATE.md'
}
@test "handoff step 7 stages docs/ and .council/ when both exist" {
  mk_project none
  line="$(handoff_add_line)"
  mkdir -p "$PROJ/.council/q1"; echo s > "$PROJ/.council/q1/synthesis.md"; echo change >> "$PROJ/docs/STATE.md"
  run bash -c "cd '$PROJ' && $line"
  [ "$status" -eq 0 ]
  git -C "$PROJ" diff --cached --name-only | grep -qx 'docs/STATE.md'
  git -C "$PROJ" diff --cached --name-only | grep -qx '.council/q1/synthesis.md'
}
@test "init migration: covered hints shown beside the builtin text and their remainder kept (I6)" {
  f="$MK_REPO/skills/init/SKILL.md"
  grep -qF 'builtin text' "$f" || { echo "no side-by-side instruction"; false; }
  grep -qF 'project-specific remainder' "$f" || { echo "no remainder instruction"; false; }
  grep -qF 'custom hint with the same `match`' "$f" || { echo "no same-match custom hint option"; false; }
}
@test "init migration: restart the session right after the migration commit (M5)" {
  f="$MK_REPO/skills/init/SKILL.md"
  grep -qiF 'restart the session immediately' "$f"
  grep -qF 'legacy and memokit hooks both run' "$f"
}
line_of() { grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1; }
@test "handoff refreshes the code graph after the commit and a graph failure does not fail the handoff" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  c="$(line_of "$f" 'git commit -m')"; g="$(line_of "$f" 'memokit-graph.sh" refresh')"
  [ -n "$c" ] && [ -n "$g" ] && [ "$c" -lt "$g" ]
  grep -qF 'does not fail the handoff' "$f"
  grep -qF 'CLAUDE_PLUGIN_ROOT}/skills/handoff/scripts/memokit-graph.sh' "$f"
}
@test "handoff ends with a push notification, after the verification" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  v="$(line_of "$f" "Handoff güncel, sonraki oturumda 'devam et' demen yeterli.")"; p="$(line_of "$f" 'select:PushNotification')"
  [ -n "$v" ] && [ -n "$p" ] && [ "$v" -lt "$p" ]
  grep -qF 'status: "proactive"' "$f"
  grep -qF 'Handoff TAMAMLANAMADI' "$f"
  grep -qF 'Handoff NOT complete' "$f"
}
@test "the context-budget message asks for the notification step in both languages" {
  for l in tr en; do grep '^MK_T_CB_AUTONOMOUS=' "$HOOKS/messages/$l.sh" | grep -qF 'PushNotification' || { echo "$l"; false; }; done
}
@test "init offers the code graph with a measured recommendation and builds it with the helper" {
  f="$MK_REPO/skills/init/SKILL.md"
  grep -qF 'graphify' "$f"
  grep -qF 'memokit-graph.sh" refresh' "$f"
  grep -qF '.graphifyignore' "$f"
}

@test "sweep is gated: description prefix and step 0 first" {
  f="$MK_REPO/skills/sweep/SKILL.md"
  sed -n '/^---$/,/^---$/p' "$f" | grep -qF "description: $GATE_DESC"
  g="$(grep -nF "$GATE_STEP" "$f" | head -n1 | cut -d: -f1)"
  n="$(grep -nE '^1\. ' "$f" | head -n1 | cut -d: -f1)"
  [ -n "$g" ] && [ "$g" -lt "$n" ]
}
@test "sweep asks in section 2 format and deletes literal paths only" {
  f="$MK_REPO/skills/sweep/SKILL.md"
  for s in 'AskUserQuestion' 'WORKING-MODEL.md §2' 'rm -rf <literal absolute path' 'one-way door' \
           'all stale' 'pick' 'its OWN Bash call' 'df -h' 'du -sk' \
           'CLAUDE_PLUGIN_ROOT}/skills/sweep/scripts/memokit-temp.sh'; do
    grep -qF -- "$s" "$f" || { echo "missing: $s"; false; }
  done
  grep -qE '^- Delete the current session' "$f"
  grep -qE '^- Delete anything outside this project' "$f"
  grep -qF 'never `&&`, `;`, pipes, loops, variables' "$f"
}
@test "sweep offers only merged-clean worktrees and branches, never forced" {
  f="$MK_REPO/skills/sweep/SKILL.md"
  for s in 'memokit-temp.sh" worktrees' "git worktree remove '<literal absolute path>'" 'git branch -d <branch>' \
           '`merged-ignored`' 'merged-into' 'refuses' 'default branch' 'outside `.claude/worktrees`' \
           'Only `merged-clean` rows are offered' '`dirty`' '`unmerged`' '`orphan-branch`' '`detached`' '`locked`' \
           '`prunable`' '`manual`' 'git --no-optional-locks worktree list' "git branch --list 'mk/*'"; do
    grep -qF -- "$s" "$f" || { echo "missing: $s"; false; }
  done
  # --force/-f and -D only ever appear as prohibitions in the Never section.
  nv="$(grep -n '^## Never' "$f" | cut -d: -f1)"
  [ -n "$nv" ]
  while IFS=: read -r ln _; do
    [ "$ln" -gt "$nv" ] || { echo "forced form before Never, line $ln"; false; }
  done < <(grep -nE -- '--force|branch -D|`-D`' "$f")
  # The offer lines name merged-clean only.
  grep -E '^[[:space:]]*(- )?\*\*Offered' "$f" | grep -qF 'merged-clean'
  [ "$(grep -E '^[[:space:]]*(- )?\*\*Offered' "$f" | grep -cE 'dirty|unmerged|orphan-branch')" -eq 0 ]
  grep -qE '^- Remove a worktree or branch that is not `merged-clean`' "$f"
  # merged-ignored is never part of the all-rows option; it needs a per-row pick naming the files.
  grep -F '`all merged-clean`' "$f" | grep -qF 'never `merged-ignored`'
  grep -qF 'per-row pick' "$f"
}
sweep_run() {
  run env MEMOKIT_SESSION_ID="$TT_SID" MEMOKIT_TRANSCRIPT_PATH="$TT_TDIR/$TT_SID.jsonl" \
    "$MK_BASH" -c 'cd "$1" && shift && "$@"' x "$PROJ" "$MK_REPO/skills/sweep/scripts/memokit-temp.sh" "$@"
}
@test "memokit-temp.sh list classifies stale/active against a fixture tree" {
  mk_project; mk_temp_tree
  OLD=00000001-aaaa-bbbb-cccc-000000000001; NEW=00000002-aaaa-bbbb-cccc-000000000002
  mk_blob "$TT_SESS/scratchpad/mine" 50
  mk_blob "$TT_PROJ/$OLD/scratchpad/big" 300
  mk_blob "$TT_PROJ/$NEW/scratchpad/f" 20
  mkdir -p "$TT_PROJ/empty/sub"; mk_blob "$TT_PROJ/loose/x" 10
  : > "$TT_TDIR/$OLD.jsonl"; touch -t 202001010000 "$TT_TDIR/$OLD.jsonl"
  : > "$TT_TDIR/$NEW.jsonl"
  sweep_run list
  [ "$status" -eq 0 ]
  echo "$output"
  printf '%s\n' "$output" | head -n1 | grep -Eq "^stale	[0-9]+	[0-9]+ KB	(2019-12-31|2020-01-01)T[0-9:]+Z	$TT_PROJ/$OLD$"
  printf '%s\n' "$output" | grep -q "^active	[0-9]*	[0-9]* KB	.*	$TT_PROJ/$NEW$"
  printf '%s\n' "$output" | grep -q "^active	[0-9]*	[0-9]* KB	.*	$TT_PROJ/loose$"
  ! printf '%s\n' "$output" | grep -q "$TT_SID"
  ! printf '%s\n' "$output" | grep -q "empty"
  rm -rf "$TROOT" "$PROJ"
}
@test "memokit-temp.sh list hides control characters and marks the row manual" {
  mk_project; mk_temp_tree
  mk_blob "$TT_PROJ/$(printf 'a\nb')/f" 5
  sweep_run list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s\n' "$output" | grep -q "^manual	[0-9]*	[0-9]* KB	.*	$TT_PROJ/a?b$"
  rm -rf "$TROOT" "$PROJ"
}
@test "memokit-temp.sh free prints a size and refuses without config" {
  mk_project; mk_temp_tree
  sweep_run free
  [ "$status" -eq 0 ]; printf '%s' "$output" | grep -Eq '^[0-9]+ MB$|^[0-9.]+ GB$'
  rm -f "$PROJ/.claude/memokit.json"
  sweep_run list
  [ "$status" -eq 2 ]
  rm -rf "$TROOT" "$PROJ"
}
@test "memokit-temp.sh marks names the guard would reject as manual, never stale" {
  mk_project; mk_temp_tree
  mk_blob "$TT_PROJ/a b/f" 5; mk_blob "$TT_PROJ/c[1]/f" 5; mk_blob "$TT_PROJ/ok.d/f" 5
  touch -t 202001010000 "$TT_PROJ/a b" "$TT_PROJ/c[1]" "$TT_PROJ/ok.d"
  sweep_run list
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^manual	.*	$TT_PROJ/a b$"
  printf '%s\n' "$output" | grep -qF "$TT_PROJ/c[1]"
  ! printf '%s\n' "$output" | grep '^stale' | grep -qE 'a b|c\['
  rm -rf "$TROOT" "$PROJ"
}
@test "memokit-temp.sh falls back to the newest transcript, from a subdirectory too" {
  mk_project; mk_temp_tree
  FH="$(mktemp -d "${BATS_TMPDIR:-/tmp}/mkhome.XXXXXX")"
  slug="$(printf '%s' "$PROJ" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$FH/projects/$slug" "$PROJ/src/deep" "$TROOT/claude-$TT_UID/$slug"
  A=00000001-aaaa-bbbb-cccc-000000000001; B=00000002-aaaa-bbbb-cccc-000000000002
  : > "$FH/projects/$slug/$A.jsonl"; touch -t 202001010000 "$FH/projects/$slug/$A.jsonl"
  : > "$FH/projects/$slug/$B.jsonl"
  mk_blob "$TROOT/claude-$TT_UID/$slug/$A/f" 30; mk_blob "$TROOT/claude-$TT_UID/$slug/$B/f" 30
  run env -u MEMOKIT_SESSION_ID -u MEMOKIT_TRANSCRIPT_PATH CLAUDE_CONFIG_DIR="$FH" \
    "$MK_BASH" -c 'cd "$1" && "$2" list' x "$PROJ/src/deep" "$MK_REPO/skills/sweep/scripts/memokit-temp.sh"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^stale	.*	$TROOT/claude-$TT_UID/$slug/$A$"
  ! printf '%s\n' "$output" | grep -qF "$B"
  rm -rf "$TROOT" "$PROJ" "$FH"
}
@test "memokit-temp.sh marks non-ASCII names manual under a UTF-8 locale" {
  loc="$(locale -a 2>/dev/null | grep -iE '\.utf-?8$' | head -n1)"
  [ -n "$loc" ] || skip "no UTF-8 locale installed"
  mk_project; mk_temp_tree
  mk_blob "$TT_PROJ/caf$(printf '\303\251')/f" 5; mk_blob "$TT_PROJ/$(printf '\304\260')x/f" 5
  touch -t 202001010000 "$TT_PROJ/caf$(printf '\303\251')" "$TT_PROJ/$(printf '\304\260')x"
  LC_ALL="$loc" sweep_run list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^manual')" -eq 2 ]
  ! printf '%s\n' "$output" | grep -q '^stale'
  rm -rf "$TROOT" "$PROJ"
}

# --- /memokit:parallel -------------------------------------------------------
PAR="$MK_REPO/skills/parallel/SKILL.md"
has_all() { local f="$1" s; shift; for s in "$@"; do grep -qF -- "$s" "$f" || { echo "missing: $s"; return 1; }; done; }
@test "parallel: description triggers and stays short" {
  d="$(sed -n '/^---$/,/^---$/p' "$PAR" | grep '^description:')"
  for s in '/parallel' 'paralel' 'toplu ticket' 'epic'; do printf '%s' "$d" | grep -qF -- "$s" || { echo "missing: $s"; false; }; done
  [ "$(wc -l < "$PAR" | tr -d ' ')" -le 155 ] || { echo "too long: $(wc -l < "$PAR")"; false; }
}
@test "parallel: never-list" {
  n="$(grep -nE '^## Never' "$PAR" | cut -d: -f1)"; [ -n "$n" ]
  for re in '^- Proceed on an assumption' '^- Run Tier 2 without the user.s explicit approval' \
            '^- Copy or link untracked or ignored files, or secrets, into a lane worktree' \
            '^- Pass `--force`/`-f` to `git worktree remove` or `-D` to `git branch`' \
            '^- Delete unmerged or uncommitted work' \
            '^- Let a lane write `docs/STATE.md`, `docs/HISTORY.md` or `docs/DECISIONS.md`' \
            '^- Edit code yourself'; do
    l="$(grep -nE -- "$re" "$PAR" | head -n1 | cut -d: -f1)"
    [ -n "$l" ] || { echo "missing: $re"; false; }
    [ "$l" -gt "$n" ] || { echo "not under Never: $re"; false; }
  done
}
@test "parallel: never assume; decision sweep before coding; runtime decisions pause one lane" {
  has_all "$PAR" 'AskUserQuestion' 'at most 4 questions' 'WORKING-MODEL.md §2' 'does not start' \
    'NEEDS_DECISION' 'only that lane' 'one question at a time' 'other lanes keep running' \
    'select:SendMessage,PushNotification,Monitor' 'project `language`' \
    'process every pending event' 'then ask'
}
@test "parallel: Tier 2 only after the explicit question; gates.md precondition" {
  has_all "$PAR" 'Tier-2 gates next, or more work first?' '.claude/memokit/gates.md' 'Tier-1 command' \
    'ask the user once' 'never guess' 'gates.md missing' 'Tier 1 green — gate-pending' '/memokit:triage'
  g="$(line_of "$PAR" '.claude/memokit/gates.md')"; c="$(line_of "$PAR" 'Dispatch `memokit:coder`')"
  [ -n "$g" ] && [ -n "$c" ] && [ "$g" -lt "$c" ] || { echo "gates.md check must come before coder dispatch"; false; }
}
@test "parallel: worktree and branch commands, cleanup verified, no force anywhere but the Never list" {
  has_all "$PAR" 'git worktree add .claude/worktrees/mk-<run>-<lane> -b mk/<run>/<lane> <integration>' \
    'git worktree remove .claude/worktrees/mk-<run>-<lane>' 'git branch -d mk/<run>/<lane>' \
    'git worktree list' "git branch --list 'mk/*'" 'git merge --no-ff --no-edit mk/<run>/<lane>' 'completion order'
  n="$(grep -nE '^## Never' "$PAR" | cut -d: -f1)"
  grep -nE -- '--force|branch -D|remove -f|-d -f|--no-verify|reset --hard|clean -f' "$PAR" | while IFS=: read -r l _; do
    [ "$l" -gt "$n" ] || { echo "forced/destructive form outside Never at line $l"; exit 1; }
  done
}
@test "parallel: no untracked files or secrets in worktrees; overlays go in as text" {
  has_all "$PAR" 'paste their text into the brief' 'no `.env`' 'Tier 1 must run without secrets'
}
@test "parallel: ledger, states, compact reports, resume" {
  has_all "$PAR" '.claude/memokit/runs/<run-id>/ledger.md' \
    '`planned` → `decided` → `running` ⇄ `needs-decision` → `in-review` → `approved` → `merging` → `merged` (gate-pending) → `done`' \
    'git check-ignore -q .claude/memokit/runs/x' 'report file' 'resume' '/memokit:handoff'
}
@test "parallel: reviewer model by risk, ESCALATE, Opus batch review" {
  has_all "$PAR" 'memokit:analyst' 'touches:' 'depends_on:' 'risk:' 'questions:' 'memokit:reviewer' \
    '`model`' 'review.model' 'ESCALATE: opus' 're-run the review on Opus' 'whole-batch review' \
    'review.model: sonnet' 'batch base'
}
@test "parallel: rolling slots, solo lanes, merge queue, follow-ups, usage report" {
  has_all "$PAR" 'parallel.maxCoders' 'maxReviewers' 'Rolling slots' 'solo' 'CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS' \
    'resolution slice' 'merged areas' 'Follow-up' 'parent' 'wall time' 'token' 'never squash'
}
@test "init: ignores the run dir and lane worktrees idempotently; scaffolds the analyst and gates skeletons" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" '.claude/memokit/runs/' '.claude/worktrees/' '.claude/memokit/analyst.md' '.claude/memokit/gates.md'
  lines="$(grep -E '^[[:space:]]*git check-ignore -q \.claude/(memokit/runs|worktrees)/' "$f" | sed 's/^[[:space:]]*//')"
  [ "$(printf '%s\n' "$lines" | grep -c .)" -eq 2 ] || { echo "want 2 ignore lines: $lines"; false; }
  printf '%s\n' "$lines" | while IFS= read -r l; do grep -qF -- "$l" "$PAR" || { echo "parallel lacks: $l"; exit 1; }; done
  mk_project none; printf '/tmp/' > "$PROJ/.gitignore"
  for i in 1 2; do printf '%s\n' "$lines" | while IFS= read -r l; do (cd "$PROJ" && bash -c "$l") || exit 1; done; done
  [ "$(grep -cxF '.claude/memokit/runs/' "$PROJ/.gitignore")" -eq 1 ]
  [ "$(grep -cxF '.claude/worktrees/' "$PROJ/.gitignore")" -eq 1 ]
  grep -qxF '/tmp/' "$PROJ/.gitignore"
  git -C "$PROJ" check-ignore -q .claude/memokit/runs/r1/ledger.md
}
@test "parallel: ignore lines + pathspec commit keep the main checkout clean after a lane worktree is added (1a, 10)" {
  mk_project none
  lines="$(grep -E '^[[:space:]]*git check-ignore -q \.claude/(memokit/runs|worktrees)/' "$PAR" | sed 's/^[[:space:]]*//')"
  commit="$(grep -E '^[[:space:]]*git add -- \.gitignore && git commit -m .* -- \.gitignore$' "$PAR" | head -n1 | sed 's/^[[:space:]]*//')"
  [ -n "$lines" ] && [ -n "$commit" ] || { echo "ignore lines or pathspec commit missing"; false; }
  echo dirty > "$PROJ/src/user.txt"
  printf '%s\n' "$lines" | while IFS= read -r l; do (cd "$PROJ" && bash -c "$l") || exit 1; done
  (cd "$PROJ" && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false add -- .gitignore && git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm x -- .gitignore)
  git -C "$PROJ" show --name-only --format= HEAD | grep -qx '.gitignore'
  lacks "$(git -C "$PROJ" show --name-only --format= HEAD)" 'src/user.txt'
  rm "$PROJ/src/user.txt"
  git -C "$PROJ" worktree add -q "$PROJ/.claude/worktrees/mk-r1-l1" -b mk/r1/l1 HEAD
  [ -z "$(git -C "$PROJ" status --porcelain --untracked-files=all)" ] || { git -C "$PROJ" status --porcelain; false; }
  git -C "$PROJ" worktree remove "$PROJ/.claude/worktrees/mk-r1-l1"; git -C "$PROJ" branch -d mk/r1/l1
}
@test "parallel: dirty start, baseline, pathspec commits (1b, 10)" {
  has_all "$PAR" 'porcelain baseline' 'git status --porcelain --untracked-files=all' 'against the baseline' \
    'never stash, discard or commit the user' 'pathspec' '-- <file>'
}
@test "parallel: reviewer brief and coder brief carry the root, ids, texts and report file (2, 3, 14)" {
  has_all "$PAR" 'Reviewer brief' 'main project root' 'lane id and task id' 'the gates text' \
    '<lane>-<task>-<role>-r<n>.md' 'returned verbatim' "the reviewer's report file" "report's file list"
}
@test "parallel: resolution slices are measured on diff HEAD with conflict-marker checks (4, 11)" {
  has_all "$PAR" 'git -C <wt> diff HEAD' 'git -C <wt> grep --cached' \
    "the lane's own files" 'freeze the merge queue' 'until the resolution slice is merged green'
}
@test "parallel: gates.md precondition and the gates.md missing path (5)" {
  has_all "$PAR" 'a non-empty, non-comment line under `## Tier 1`' 'resend the gates text' \
    'never `git add -f`' 'truly absent'
}
@test "parallel: briefs on disk, resume first, merging step, re-read after compaction (6, 16)" {
  has_all "$PAR" '.claude/memokit/runs/<run-id>/<lane>-<task>-brief.md' 'merge queue' 'merge-start' 'merge-end' \
    're-read this skill and the ledger' 'MERGE_HEAD' 'new lane start'
  r="$(line_of "$PAR" '**Resume first.**')"; t="$(line_of "$PAR" 'Task source:')"
  [ -n "$r" ] && [ -n "$t" ] && [ "$r" -lt "$t" ] || { echo "Resume first must precede the task source"; false; }
}
@test "parallel: Tier 2 mechanics (7, 15)" {
  has_all "$PAR" 'timeout: 600000' 'Monitor' 'never two at once' 'in one pass' \
    'all Tier-2 gates again or only the red ones' '<batch base>..HEAD'
}
@test "parallel: solo lanes drain the running lanes; ready lanes start in plan order (8)" {
  has_all "$PAR" 'next lane in plan order is solo' 'drain to `merged`' 'count as running' 'in plan order'
}
@test "parallel: marker check is a grep over the conflicted files, immune to whitespace rules; fails into a fix round (N1, N4, polish 2)" {
  rec='git -C <wt> diff --name-only --diff-filter=U'
  has_all "$PAR" "$rec" 'with the marker list' 'do not commit' 'before any coder runs'
  cmd="$(grep -oE "git -C <wt> grep --cached -nE '[^']*' -- <conflicted files>" "$PAR" | head -n1)"
  [ -n "$cmd" ] || { echo "no marker grep"; false; }
  run grep -F -- '--cached --name-only --diff-filter=U' "$PAR"; [ "$status" -ne 0 ]
  run grep -E -- 'diff --cached --check`? must pass' "$PAR"; [ "$status" -ne 0 ]
  mk_project none; G="git -c user.email=t@t -c user.name=t"
  printf 'a\nkeep\n' > "$PROJ/f.md"; printf '*.md whitespace=trailing-space\n' > "$PROJ/.gitattributes"
  (cd "$PROJ" && $G add f.md .gitattributes && $G commit -qm a && git checkout -qb lane \
    && printf 'lane side  \nkeep\n' > f.md && $G commit -qam lane && git checkout -q - \
    && printf 'main side  \nkeep\n' > f.md && $G commit -qam main)
  W="$PROJ/.claude/worktrees/fix"; $G -C "$PROJ" worktree add -q "$W" -b fix HEAD
  run $G -C "$W" merge --no-commit --no-ff lane; [ "$status" -ne 0 ]
  r="${rec//<wt>/$W}"; files="$(bash -c "$r")"; [ "$files" = "f.md" ] || { echo "conflicted: $files"; false; }
  c="${cmd//<wt>/$W}"; c="${c//<conflicted files>/$files}"
  git -C "$W" add -A; run bash -c "$c"; [ "$status" -eq 0 ] || { echo "markers not caught"; false; }
  printf 'resolved\n=======\nkeep\n' > "$W/f.md"; git -C "$W" add -A
  run bash -c "$c"; [ "$status" -eq 0 ] || { echo "lone separator not caught"; false; }
  printf 'resolved\n||||||| merged common ancestors\nkeep\n' > "$W/f.md"; git -C "$W" add -A
  run bash -c "$c"; [ "$status" -eq 0 ] || { echo "diff3 base marker not caught"; false; }
  printf 'resolved hard break  \nkeep\n' > "$W/f.md"; git -C "$W" add -A
  run git -C "$W" -c core.whitespace=-trailing-space,-space-before-tab,-blank-at-eof diff --cached --check
  [ "$status" -ne 0 ] || { echo "fixture: .gitattributes whitespace rule not active"; false; }
  run bash -c "$c"; [ "$status" -eq 1 ] || { echo "clean resolution flagged ($status): $output"; false; }
  [ -z "$output" ]
}
@test "parallel: baseline absorbs run artefacts and accepted untracked files (N2, N5, N6)" {
  has_all "$PAR" 'append those entries to the ledger baseline' 'DONE checks then ignore them' \
    'lists nothing beyond the baseline' '.claude/settings.local.json' 'accept them into the baseline' \
    'modified tracked files still block the start' 'run_in_background: true' "analyst's or a coder's \`gates.md missing\`"
}

@test "handoff carries an active parallel run: ledger, lanes, clean stop, no removal, no Tier 2" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  grep -qF '.claude/memokit/runs/*/ledger.md' "$f"
  grep -qF 'run id' "$f"
  grep -qF 'finish or stop cleanly' "$f"
  grep -qF 'never remove a worktree or branch' "$f"
  grep -qF 'never run Tier 2' "$f"
  grep -qF 'before the STATE commit' "$f"
}
@test "resume continues an active parallel run from its ledger via /memokit:parallel" {
  f="$MK_REPO/skills/resume/SKILL.md"
  grep -qF '.claude/memokit/runs/*/ledger.md' "$f"
  grep -qF '/memokit:parallel' "$f"
  grep -qF 'Resume first' "$f"
}
@test "polish: handoff keeps the ledger local and names the resume step; parallel step 2 routes gates.md missing" {
  f="$MK_REPO/skills/handoff/SKILL.md"
  grep -qF 'The ledger is git-ignored and local: leave it on disk, never `git add -f` it' "$f"
  grep -qF '"Resume run <id> with /memokit:parallel"' "$f"
  for s in handoff resume; do grep -F 'runs/*/ledger.md' "$MK_REPO/skills/$s/SKILL.md" | grep -qF '`status: active`' || { echo "$s"; false; }; done
  grep -E '^2\. \*\*Analysis\.\*\*' "$PAR" | grep -qF 'follows the `gates.md missing` rule of step 5'
}
@test "polish: sweep lists branch rows merged into default separately, outside the all-merged-clean offer" {
  f="$MK_REPO/skills/sweep/SKILL.md"
  grep -qF '**Delete from the default branch**' "$f"
  grep -F '**Delete from the default branch**' "$f" | grep -qF 'git refuses `git branch -d`'
  grep -E '^[[:space:]]*(- )?\*\*Offered' "$f" | grep -qF 'except branch rows merged into `default`'
  grep -F '`all merged-clean`' "$f" | grep -qF 'nor branch rows merged into `default`'
  grep -qF 'a `merged-clean` branch row merged into `head`: `git branch -d <branch>`' "$f"
  grep -qF '`/memokit:sweep worktrees` runs only this part' "$f"
}

# --- 0.6.0 final review -----------------------------------------------------
@test "final I3: new files enter the DONE check and the review diff through intent-to-add" {
  has_all "$PAR" 'git -C <wt> add -N -- .' 'git -C <wt> status --short --untracked-files=all' 'intent-to-add'
  run grep -F '(new files included)' "$PAR"; [ "$status" -ne 0 ]
  d="$(line_of "$PAR" '`DONE` (`Tier 1 green')"; a="$(line_of "$PAR" 'git -C <wt> add -N -- .')"
  [ -n "$a" ] && [ -n "$d" ] && [ "$a" -le "$d" ] || { echo "add -N must come with the DONE check"; false; }
  grep -F '**Reviewer brief**' "$PAR" | grep -qF 'intent-to-add'
  # Fixture: a new file is missing from diff HEAD --stat until add -N; nothing is committed.
  mk_project none; G="git -c user.email=t@t -c user.name=t"
  printf 'n\n' > "$PROJ/src/new.txt"
  h0="$(git -C "$PROJ" rev-parse HEAD)"
  lacks "$(git -C "$PROJ" diff HEAD --stat)" 'src/new.txt'
  cmd="$(grep -oF 'git -C <wt> add -N -- .' "$PAR" | head -n1)"; cmd="${cmd//<wt>/$PROJ}"
  bash -c "$cmd"
  git -C "$PROJ" diff HEAD --stat | grep -qF 'src/new.txt'
  git -C "$PROJ" status --short --untracked-files=all | grep -qF 'src/new.txt'
  [ "$(git -C "$PROJ" rev-parse HEAD)" = "$h0" ]
  # The approval commit (add -A) carries the file's content.
  git -C "$PROJ" add -A; $G -C "$PROJ" commit -qm lane
  [ "$(git -C "$PROJ" show HEAD:src/new.txt)" = n ]
}
@test "final I4: upgrade note in CHANGELOG 0.6.0 and README; resume proposes moving coder.md test commands" {
  sec="$(awk '/^## 0\.6\.0/{p=1;next} /^## /{p=0} p' "$MK_REPO/CHANGELOG.md")"
  printf '%s' "$sec" | grep -qF 'Upgrading from 0.5.x'
  for s in '.claude/memokit/gates.md' '`## Tier 1`' '`## Tier 2`' '`coder.md`' 'BLOCKED' 'scaffold' 'without overwriting' \
           '.claude/memokit/runs/' '.claude/worktrees/'; do
    printf '%s' "$sec" | grep -qF -- "$s" || { echo "CHANGELOG missing: $s"; false; }
  done
  grep -q '^## Upgrading from 0.5.x' "$MK_REPO/README.md"
  up="$(awk '/^## Upgrading from 0\.5\.x/{p=1;next} /^## /{p=0} p' "$MK_REPO/README.md")"
  for s in '.claude/memokit/gates.md' '`## Tier 1`' '`## Tier 2`' '`coder.md`' 'without overwriting' '.claude/memokit/runs/' '.claude/worktrees/'; do
    printf '%s' "$up" | grep -qF -- "$s" || { echo "README missing: $s"; false; }
  done
  f="$MK_REPO/skills/resume/SKILL.md"
  grep -F '.claude/memokit/gates.md' "$f" | grep -F '.claude/memokit/coder.md' | grep -qF 'ask the user once'
}
@test "final M1: the coder overlay skeleton sends test commands to gates.md" {
  head -n1 "$MK_REPO/skills/init/templates/coder.md" | grep -qF 'Project stack and project-only rules (test commands: gates.md)'
}
@test "final M3/M4: resume after merge-end; a run ended early is status: stopped and no longer resumed" {
  has_all "$PAR" 'with its merge-end line' 'clean up idempotently' 'status: stopped'
  grep -F 'status: stopped' "$PAR" | grep -qF '/memokit:sweep worktrees'
  for s in handoff resume; do grep -qF '`status: stopped`' "$MK_REPO/skills/$s/SKILL.md" || { echo "$s"; false; }; done
}
@test "final I1: sweep lists active-run lanes, never offers them" {
  f="$MK_REPO/skills/sweep/SKILL.md"
  grep -qF -- '- `active-run`:' "$f"
  grep -F -- '- `active-run`:' "$f" | grep -qF '/memokit:resume'
  grep -F -- '- `active-run`:' "$f" | grep -qF 'Never offered'
  grep -qF 'every other worktree of the repository' "$f"
}
@test "final M10/M11: STATE.md committed when the run closes; merges take --no-edit" {
  grep -E '^10\. \*\*Report\.\*\*' "$PAR" | grep -F 'docs/STATE.md' | grep -qF -- '-- docs/STATE.md'
  has_all "$PAR" 'git merge --no-ff --no-edit mk/<run>/<lane>'
}
@test "final M7: agents keep a named report file and return a short status/verdict" {
  for a in coder reviewer; do
    grep -qF 'If your brief names a report file, write the full report there and return only' "$MK_REPO/agents/$a.md" || { echo "$a"; false; }
  done
  grep -qF 'reviewers their `Overlay read:` line and their verdict line' "$PAR"
}
@test "init adopt: routing on aiSetup, inventory, remove and drop-hook named" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'aiSetup' '$INIT inventory' '$INIT remove "$ROOT"' '--drop-hook' 'Adopt mode'
}
@test "init adopt: AGENTS.md never edited, imported with an override section" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" '@AGENTS.md' 'never edit it (root or nested)' 'override'
}
@test "init adopt: other tools stay byte-identical; copies name their source" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'byte-identical' '(source: '
}
@test "init adopt: no keep option for conflicts; cancel leaves nothing written" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'cancel' 'no keep option'
}
@test "init adopt: one commit with the adopt message, verify kept paths first" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'chore(ai): adopt existing AI setup into memokit' 'git status --porcelain'
}
@test "init adopt: scoped rules go to .claude/rules with paths" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" '.claude/rules/' 'paths:'
}
@test "init adopt: legacy order - remove-legacy before settings --drop-hook in the write step" {
  f="$MK_REPO/skills/init/SKILL.md"
  a="$(line_of "$f" '`$INIT remove-legacy "$ROOT"` now, before any `settings`')"; d="$(line_of "$f" '`$INIT settings "$ROOT"` with one `--drop-hook')"
  [ -n "$a" ] && [ -n "$d" ] && [ "$a" -lt "$d" ]
}
@test "init adopt: legacy routing keyed on inventory .legacy != null; inventoryError and wrapper note" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'inventoryError:true' 'read the `command` itself'
  l="$(line_of "$MK_REPO/skills/init/SKILL.md" '3. With legacy hooks (`inventory .legacy != null`): `$INIT remove-legacy')"; [ -n "$l" ]
  l="$(line_of "$MK_REPO/skills/init/SKILL.md" '### When memokit legacy hooks are present (`inventory .legacy != null`)')"; [ -n "$l" ]
}
@test "init adopt: final-review wording (legacy edit order, ignored settings, prompt hooks, link mechanics)" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'happen after 7.3' 'stop and report, write nothing more' 'settingsIgnored' 'drop it yourself; not revertable' \
    "pass the hook's full \`command\` as the substring" 'dropped N hook entries' 'command: null' 'remove it by hand' \
    '$INIT remove "$ROOT" CLAUDE.md' 'except the AGENTS.md override line' 'hooks alone can make `aiSetup` true' 'knowledge-health is run, not removed'
  ! grep -qF 'ask whether to remove those copies' "$f"
}
@test "init: plugin registration in shared settings.json is a Team opt-in" {
  f="$MK_REPO/skills/init/SKILL.md"
  has_all "$f" 'Team — always ask' 'Recommend **no**' 'not pinned to a version' 'Only if the user said yes to Team: `$INIT settings "$ROOT"`' 'The `--drop-*` forms never register the plugin' 'Artifact, Team)'
}
