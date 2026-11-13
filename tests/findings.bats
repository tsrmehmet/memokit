#!/usr/bin/env bats
load helpers
V() { "$MK_REPO/skills/parallel/scripts/memokit-findings.sh" validate "$1"; }
mk() { # mk <file> <json>  -> report with prose then a fenced block
  { printf 'Overlay read: none (not present)\nAPPROVE\n\n```json\n%s\n```\n' "$2"; } > "$1"
}
OK='{"verdict":"REJECT","findings":[{"id":"F1","verdict":"confirmed","severity":"high","file":"a.sh","line":3,"summary":"s","evidence":"e"},{"id":"F2","verdict":"needs_validation","file":"b.sh","line":9,"summary":"s","evidence":"e","blocker":"run x"},{"id":"F3","verdict":"rejected","file":"c.sh","line":1,"summary":"s","evidence":"e"}]}'
@test "valid block exits 0" { mk "$BATS_TEST_TMPDIR/r.md" "$OK"; run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 0 ]; }
@test "empty findings with APPROVE is valid" { mk "$BATS_TEST_TMPDIR/r.md" '{"verdict":"APPROVE","findings":[]}'; run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 0 ]; }
@test "no block exits 1" { printf 'APPROVE\n' > "$BATS_TEST_TMPDIR/r.md"; run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 1 ]; [[ "$output" == *"no fenced json block"* ]]; }
@test "missing file exits 1" { run V "$BATS_TEST_TMPDIR/none.md"; [ "$status" -eq 1 ]; }
@test "bad usage exits 2" { run "$MK_REPO/skills/parallel/scripts/memokit-findings.sh"; [ "$status" -eq 2 ]; }
@test "unparsable json exits 1" { mk "$BATS_TEST_TMPDIR/r.md" '{"verdict":'; run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 1 ]; [[ "$output" == *"not valid JSON"* ]]; }
@test "two blocks: the last one counts" {
  { printf '```json\n%s\n```\ntext\n```json\n%s\n```\n' '{"verdict":"X"}' "$OK"; } > "$BATS_TEST_TMPDIR/r.md"
  run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 0 ]
  { printf '```json\n%s\n```\ntext\n```json\n%s\n```\n' "$OK" '{"verdict":"X"}'; } > "$BATS_TEST_TMPDIR/r2.md"
  run V "$BATS_TEST_TMPDIR/r2.md"; [ "$status" -eq 1 ]
}
bad() { # bad <jq-filter-applied-to-OK> <message-substring>
  j="$(printf '%s' "$OK" | jq -c "$1")"; mk "$BATS_TEST_TMPDIR/r.md" "$j"
  run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 1 ]; [[ "$output" == *"$2"* ]] || { echo "$output"; false; }
}
@test "bad overall verdict" { bad '.verdict="MAYBE"' 'verdict must be APPROVE or REJECT'; }
@test "findings must be an array" { bad '.findings="x"' 'findings must be an array'; }
@test "bad finding verdict" { bad '.findings[0].verdict="maybe"' 'finding F1: verdict must be'; }
@test "severity required on confirmed" { bad 'del(.findings[0].severity)' 'finding F1: severity is required when verdict is confirmed'; }
@test "bad severity value" { bad '.findings[0].severity="urgent"' 'finding F1: severity must be one of'; }
@test "severity forbidden on needs_validation" { bad '.findings[1].severity="low"' 'finding F2: severity is only allowed when verdict is confirmed'; }
@test "severity forbidden on rejected" { bad '.findings[2].severity="low"' 'finding F3: severity is only allowed when verdict is confirmed'; }
@test "blocker required on needs_validation" { bad 'del(.findings[1].blocker)' 'finding F2: blocker is required when verdict is needs_validation'; }
@test "missing field" { bad 'del(.findings[0].evidence)' 'finding F1: missing evidence'; }
@test "missing id" { bad 'del(.findings[0].id)' 'finding #0: missing id'; }
@test "duplicate id" { bad '.findings[1].id="F1"' 'duplicate id F1'; }
@test "line must be an integer >= 1" {
  for l in '"abc"' '-3' '3.5' '"12"' '0' 'null'; do
    j="$(printf '%s' "$OK" | jq -c ".findings[0].line=$l")"; mk "$BATS_TEST_TMPDIR/r.md" "$j"
    run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 1 ] || { echo "$l"; false; }
    [[ "$output" == *"finding F1: line must be an integer >= 1"* ]] || { echo "$l: $output"; false; }
  done
}
@test "example json block inside a longer markdown fence is not selected" {
  { printf '```json\n%s\n```\n\n````markdown\nexample:\n```json\n{"verdict":"X"}\n```\n````\n' "$OK"; } > "$BATS_TEST_TMPDIR/r.md"
  run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 0 ]
  { printf '```json\n%s\n```\n\n```markdown\nexample:\n```json\n{"verdict":"X"}\n```\n```\n' "$OK"; } > "$BATS_TEST_TMPDIR/r2.md"
  run V "$BATS_TEST_TMPDIR/r2.md"; [ "$status" -eq 0 ]
}
@test "unterminated trailing json block" {
  { printf '```json\n%s\n```\ntext\n```json\n{"verdict":\n' "$OK"; } > "$BATS_TEST_TMPDIR/r.md"
  run V "$BATS_TEST_TMPDIR/r.md"; [ "$status" -eq 1 ]; [[ "$output" == *"unterminated json block"* ]]
}
@test "REJECT needs a confirmed finding" {
  bad '.findings=[.findings[1]]' 'REJECT requires at least one confirmed finding'; }
