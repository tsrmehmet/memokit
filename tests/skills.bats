#!/usr/bin/env bats
load helpers
@test "skill names" {
  grep -q '^name: handoff$' "$MK_REPO/skills/handoff/SKILL.md"
  grep -q '^name: resume$'  "$MK_REPO/skills/resume/SKILL.md"
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
  for s in handoff resume; do
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
