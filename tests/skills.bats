#!/usr/bin/env bats
load helpers
@test "skill names" {
  grep -q '^name: handoff$' "$MK_REPO/skills/handoff/SKILL.md"
  grep -q '^name: resume$'  "$MK_REPO/skills/resume/SKILL.md"
  grep -q '^name: triage$' "$MK_REPO/skills/triage/SKILL.md"
  grep -q '^name: sweep$' "$MK_REPO/skills/sweep/SKILL.md"
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
  for s in handoff resume triage; do
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
