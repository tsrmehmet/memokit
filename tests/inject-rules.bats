#!/usr/bin/env bats
load helpers

@test "silent without config" {
  mk_project none
  run_hook inject-rules.sh "$(prompt_payload 'hata var')"; [ -z "$output" ]
}
@test "base block with tag, dirs and coder" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  ctx | grep -q '^\[DMO-KURAL\]'; ctx | grep -q 'src/, tests/'; ctx | grep -q 'memokit:coder'
  lacks "$(ctx)" '[SKILL]'
}
@test "debugging hint fires" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'bu test hata veriyor')"
  ctx | grep -q 'systematic-debugging'
}
@test "builtin hints can be disabled" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"builtin":["review"]}}'
  run_hook inject-rules.sh "$(prompt_payload 'bu test hata veriyor')"
  lacks "$(ctx)" 'systematic-debugging'
}
@test "custom hint fires" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"custom":[{"match":"razor|cshtml","text":"FE-HINT-X"}]}}'
  run_hook inject-rules.sh "$(prompt_payload 'razor sayfasını düzelt')"
  ctx | grep -q 'FE-HINT-X'
}
@test "rules.md appended" {
  mk_project; mkdir -p "$PROJ/.claude/memokit"; printf 'PROJ-RULE-7' > "$PROJ/.claude/memokit/rules.md"
  run_hook inject-rules.sh "$(prompt_payload 'x')"
  ctx | grep -q 'PROJ-RULE-7'
}
@test "resume and handoff hints use memokit names" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'devam et')";        ctx | grep -q 'memokit:resume'
  run_hook inject-rules.sh "$(prompt_payload 'handoff yapalım')"; ctx | grep -q 'memokit:handoff'
}
@test "graphify gate output is sanitized" {
  mk_project; mkdir -p "$PROJ/scripts"
  printf '#!/bin/sh\nprintf "Graf \\"3\\" commit bayat\\\\\\033x\\n"\n' > "$PROJ/scripts/graph-staleness.sh"; chmod +x "$PROJ/scripts/graph-staleness.sh"
  run_hook inject-rules.sh "$(prompt_payload 'bu servis nerede')"
  ctx | grep -q 'Graf 3 commit bayat'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "prompt text is never echoed" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'SECRET-XYZ hata')"
  lacks "$output" 'SECRET-XYZ'
}
@test "no jq: static base block, valid json" {
  mk_project
  p="$(prompt_payload 'hata')"
  run env PATH="$(path_without jq)" "$MK_BASH" -c 'printf "%s" "$1" | "$0" "$2"' "$MK_BASH" "$p" "$HOOKS/inject-rules.sh"
  printf '%s' "$output" | /usr/bin/env jq -e '.hookSpecificOutput.additionalContext | test("KURAL")' >/dev/null
}
@test "custom hint with invalid ERE does not crash or fire" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"custom":[{"match":"[","text":"BROKEN-HINT"}]}}'
  run_hook inject-rules.sh "$(prompt_payload 'merhaba [ dunyasi')"
  [ "$status" -eq 0 ]
  lacks "$(ctx)" 'BROKEN-HINT'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "english keywords: continue fires resume, hand off / handoff fire handoff" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook inject-rules.sh "$(prompt_payload 'continue')";               ctx | grep -q 'memokit:resume'
  run_hook inject-rules.sh "$(prompt_payload 'OK, Continue please')";    ctx | grep -q 'memokit:resume'
  run_hook inject-rules.sh "$(prompt_payload 'please hand off now')";    ctx | grep -q 'memokit:handoff'
  run_hook inject-rules.sh "$(prompt_payload 'time for a handoff')";     ctx | grep -q 'memokit:handoff'
}
@test "continue inside another word does not fire the resume hint" {
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'we discontinued that api')"
  [ "$status" -eq 0 ]
  lacks "$(ctx)" 'memokit:resume'
}
@test "subdirectory launch: rule block is injected" {
  mk_project
  export CLAUDE_PROJECT_DIR="$PROJ/src"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  ctx | grep -q '^\[DMO-KURAL\]'
}
GRAPH_EN='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en","graph":{"root":"src"}}'
@test "graph configured but not built: hint names the builtin refresh" {
  mk_project "$GRAPH_EN"
  run_hook inject-rules.sh "$(prompt_payload 'where is the parser')"
  ctx | grep -qF 'skills/handoff/scripts/memokit-graph.sh refresh'
}
@test "graph configured and fresh: hint says query directly" {
  mk_project "$GRAPH_EN"
  mkdir -p "$PROJ/graphify-out"; echo '{"nodes":[{"id":"a"}]}' > "$PROJ/graphify-out/graph.json"
  git -C "$PROJ" rev-parse HEAD > "$PROJ/graphify-out/.graph_commit"
  run_hook inject-rules.sh "$(prompt_payload 'where is the parser')"
  ctx | grep -q 'fresh'
  printf '%s' "$output" | jq -e . >/dev/null
}
@test "graph config wins over a legacy staleness script" {
  mk_project "$GRAPH_EN"; mkdir -p "$PROJ/scripts"
  printf '#!/bin/sh\necho LEGACY-GATE\n' > "$PROJ/scripts/graph-staleness.sh"; chmod +x "$PROJ/scripts/graph-staleness.sh"
  run_hook inject-rules.sh "$(prompt_payload 'where is the parser')"
  lacks "$(ctx)" 'LEGACY-GATE'
}
@test "no graph config and no gate: the hint says to ask the user before building a graph" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook inject-rules.sh "$(prompt_payload 'who calls this')"
  ctx | grep -q 'ask the user'
  mk_project
  run_hook inject-rules.sh "$(prompt_payload 'bu servis nerede')"
  ctx | grep -q 'kullanıcıya'
}
@test "triage hint fires for red/flaky test piles" {
  mk_project
  for p in 'E2E 84 kırmızı, bakalım' 'flaky testleri triyaj et' 'CI is full of red tests, triage them'; do
    run_hook inject-rules.sh "$(prompt_payload "$p")"
    ctx | grep -q '/memokit:triage' || { echo "no hint: $p"; false; }
  done
}

# --- 0.8.0 approval phrases, bare approval, change window ---------------
# lib SNIPPET -- run SNIPPET with common.sh and careful.sh sourced in $PROJ.
lib() {
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; cd '$PROJ'; mk_resolve_root '{}'; mk_load_config >/dev/null; $1"
}
setup_appr() { mk_project; SID="appr$$-$BATS_TEST_NUMBER"; }

@test "phrases: onay/onaylıyorum/approve/approved <code> all grant" {
  setup_appr
  for p in 'onay abc123' 'Onaylıyorum abc123' 'APPROVE abc123' 'approved abc123.'; do
    run_hook inject-rules.sh "$(prompt_payload "$p" "$SID")"
    ctx | grep -q 'abc123 kaydedildi' || { echo "no grant: $p"; false; }
  done
  lib 'mk_careful_pending_set "'$SID'" abc123'
  run_hook inject-rules.sh "$(prompt_payload 'onay abc123' "$SID")"
  ctx | grep -q 'abc123 kaydedildi'
}
@test "bare approval grants the single pending code" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123'
  run_hook inject-rules.sh "$(prompt_payload 'onaylıyorum' "$SID")"
  ctx | grep -q 'abc123 kaydedildi'
  run_hook inject-rules.sh "$(prompt_payload 'onaylıyorum' "$SID")"
  ctx | grep -q 'CAREFUL'
  lacks "$(ctx)" 'kaydedildi'
}
@test "bare approval with trailing text does not grant" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123'
  run_hook inject-rules.sh "$(prompt_payload 'onaylıyorum ama önce bak' "$SID")"
  lacks "$(ctx)" 'CAREFUL'
  lib 'mk_careful_pending_get "'$SID'"'; [ "$status" -eq 0 ]
}
@test "a code with targets opens a window and names targets and expiry" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123 "host:prod.example.com"'
  run_hook inject-rules.sh "$(prompt_payload 'onay abc123' "$SID")"
  ctx | grep -q 'host:prod.example.com'
  ctx | grep -qE '[0-9]{2}:[0-9]{2}'
  lib 'mk_careful_window_covers "'$SID'" host:prod.example.com'; [ "$status" -eq 0 ]
  lib 'mk_careful_pending_get "'$SID'"'; [ "$status" -eq 1 ]
}
@test "a code unknown to pending is granted single-use as before" {
  setup_appr
  run_hook inject-rules.sh "$(prompt_payload 'approve abcdef' "$SID")"
  ctx | grep -q 'abcdef kaydedildi'
}
@test "a code quoted on the second line grants nothing" {
  setup_appr
  run_hook inject-rules.sh "$(prompt_payload $'x\nonay abcdef' "$SID")"
  lacks "$(ctx)" 'CAREFUL'
}
@test "flagged pending: bare approval is ambiguous, nothing opened" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" aaaaaa host:a; mk_careful_pending_set "'$SID'" bbbbbb host:b'
  run_hook inject-rules.sh "$(prompt_payload 'approve' "$SID")"
  ctx | grep -q 'bbbbbb'; ctx | grep -q 'CAREFUL'
  lacks "$(ctx)" 'host:b'
  lib 'mk_careful_window_get "'$SID'"'; [ "$status" -eq 1 ]
  lib 'mk_careful_pending_get "'$SID'"'; [ "$status" -eq 0 ]
}
@test "flagged pending: explicit code opens the window" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" aaaaaa host:a; mk_careful_pending_set "'$SID'" bbbbbb host:b'
  run_hook inject-rules.sh "$(prompt_payload 'onay bbbbbb' "$SID")"
  ctx | grep -q 'host:b'
  lib 'mk_careful_window_covers "'$SID'" host:b'; [ "$status" -eq 0 ]
}
@test "bare 'evet onayla' grants" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123'
  run_hook inject-rules.sh "$(prompt_payload '  Evet onayla  ' "$SID")"
  ctx | grep -q 'abc123 kaydedildi'
}
@test "no pending: message only, nothing is written" {
  setup_appr
  run_hook inject-rules.sh "$(prompt_payload 'approve' "$SID")"
  ctx | grep -q 'CAREFUL'
  lib 'mk_careful_window_get "'$SID'"'; [ "$status" -eq 1 ]
}
@test "empty session id works as unknown" {
  setup_appr
  lib 'mk_careful_pending_set unknown abc123 host:z'
  run_hook inject-rules.sh "$(prompt_payload 'onay abc123' '')"
  ctx | grep -q 'host:z'
  lib 'mk_careful_window_covers unknown host:z'; [ "$status" -eq 0 ]
}

# --- fix round 1: exact phrases, no trailing text, unknown codes with remote ---
RCFG='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"tr","guardedDirs":["src"],"remote":{"hosts":["prod.example.com"]}}'
# nothing_happened -- no window, no grants file, pending line still there.
nothing_happened() {
  lib 'mk_careful_window_get "'$SID'"'; [ "$status" -eq 1 ]
  lib 'f="$(mk_careful_grants_file)"; [ ! -s "$f" ]'; [ "$status" -eq 0 ]
  lib 'mk_careful_pending_get "'$SID'"'; [ "$status" -eq 0 ]
}

@test "refusals and look-alikes grant nothing and leave the pending line" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123 host:a'
  for p in 'onaylamıyorum' 'onaylamıyorum abc123' 'onaylayamıyorum' 'onaylatmıyorum abc123' 'onaylxrum' 'onaylxrum abc123' 'ONAYLAMIYORUM'; do
    run_hook inject-rules.sh "$(prompt_payload "$p" "$SID")"
    lacks "$(ctx)" 'CAREFUL' || { echo "granted: $p"; false; }
    nothing_happened
  done
}
@test "onaylıyorum / onayliyorum / ONAYLIYORUM still grant, bare and with a code" {
  setup_appr
  for p in 'onaylıyorum' 'onayliyorum' 'ONAYLIYORUM' 'onaylıyorum abc123' 'ONAYLIYORUM abc123'; do
    lib 'mk_careful_pending_set "'$SID'" abc123 host:a'
    run_hook inject-rules.sh "$(prompt_payload "$p" "$SID")"
    ctx | grep -q 'host:a' || { echo "no window: $p"; false; }
    lib 'mk_careful_window_covers "'$SID'" host:a'; [ "$status" -eq 0 ]
    lib 'mk_careful_window_close "'$SID'"'
  done
}
@test "text after the code grants nothing; blanks and punctuation are fine" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123 host:a'
  for p in 'approve abc123? no, do not' 'onay abc123 ama once bak' 'approve abc123, thanks' 'approve abc1234'; do
    run_hook inject-rules.sh "$(prompt_payload "$p" "$SID")"
    lacks "$(ctx)" 'CAREFUL' || { echo "granted: $p"; false; }
    nothing_happened
  done
  run_hook inject-rules.sh "$(prompt_payload 'onay abc123!' "$SID")"
  ctx | grep -q 'host:a'
}
@test "CRLF after a code or a bare phrase still counts" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123 host:a'
  run_hook inject-rules.sh "$(prompt_payload $'onay abc123\r\nsecond' "$SID")"
  ctx | grep -q 'host:a'
  lib 'mk_careful_pending_set "'$SID'" abc123'
  run_hook inject-rules.sh "$(prompt_payload $'approve\r' "$SID")"
  ctx | grep -q 'abc123 kaydedildi'
}
@test "remote: an unknown code is refused, nothing written" {
  mk_project "$RCFG"; SID="appr$$-$BATS_TEST_NUMBER"
  run_hook inject-rules.sh "$(prompt_payload 'approve abcdef' "$SID")"
  ctx | grep -q 'CAREFUL'; lacks "$(ctx)" 'abcdef'
  lib 'f="$(mk_careful_grants_file)"; [ ! -e "$f" ]'; [ "$status" -eq 0 ]
}
@test "remote: a code differing from the pending one is refused, pending kept" {
  mk_project "$RCFG"; SID="appr$$-$BATS_TEST_NUMBER"
  lib 'mk_careful_pending_set "'$SID'" abc123 host:a'
  run_hook inject-rules.sh "$(prompt_payload 'approve abcdef' "$SID")"
  lacks "$(ctx)" 'host:a'
  nothing_happened
}
@test "remote: an expired pending line with its code is refused" {
  mk_project "$RCFG"; SID="appr$$-$BATS_TEST_NUMBER"
  lib 'printf "%s\n" "abc123 1 host:a" > "$(mk_careful_pending_file "'$SID'")"'
  run_hook inject-rules.sh "$(prompt_payload 'approve abc123' "$SID")"
  ctx | grep -q 'CAREFUL'; lacks "$(ctx)" 'kaydedildi'
  lib 'f="$(mk_careful_grants_file)"; [ ! -e "$f" ]'; [ "$status" -eq 0 ]
}
@test "no remote block: an unknown code is a single-use grant as before" {
  setup_appr
  run_hook inject-rules.sh "$(prompt_payload 'approve abcdef' "$SID")"
  ctx | grep -q 'abcdef kaydedildi'
  lib 'mk_careful_consume abcdef'; [ "$status" -eq 0 ]
}
@test "ambiguous bare approval writes no grants file" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" aaaaaa host:a; mk_careful_pending_set "'$SID'" bbbbbb host:b'
  run_hook inject-rules.sh "$(prompt_payload 'approve' "$SID")"
  lib 'f="$(mk_careful_grants_file)"; [ ! -e "$f" ]'; [ "$status" -eq 0 ]
}
@test "no-target pending line is consumed on grant" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123'
  run_hook inject-rules.sh "$(prompt_payload 'approve abc123' "$SID")"
  ctx | grep -q 'abc123 kaydedildi'
  lib 'mk_careful_pending_get "'$SID'"'; [ "$status" -eq 1 ]
  lib 'mk_careful_consume abc123'; [ "$status" -eq 0 ]
}
@test "line-2 code leaves a targets pending untouched" {
  setup_appr
  lib 'mk_careful_pending_set "'$SID'" abc123 host:a'
  run_hook inject-rules.sh "$(prompt_payload $'hello\napprove abc123' "$SID")"
  lacks "$(ctx)" 'CAREFUL'
  nothing_happened
}

# --- 0.8.1 (spec 4): config change / deletion notice ------------------------
_snap() { # write the session snapshot like session-start does
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; mk_resolve_root '{}'; mk_config_snapshot_write \"\$1\"" _ "$(prompt_payload x)"
  [ "$status" -eq 0 ]
}
@test "config notice: unchanged config, no notice" {
  mk_project; _snap
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  lacks "$(ctx)" 'memokit.json'
}
@test "config notice: no snapshot, config present, no notice" {
  mk_project
  printf '%s' '{"version":1,"project":{"name":"D2","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  lacks "$(ctx)" 'memokit.json'
}
@test "config notice: changed announces once, again only after another change" {
  mk_project; _snap
  printf '%s' '{"version":1,"project":{"name":"D2","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  ctx | grep -qF 'memokit.json changed during this session: subagents keep the session-start version; /clear or a new session adopts it.'
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  lacks "$(ctx)" 'memokit.json'
  printf '%s' '{"version":1,"project":{"name":"D3","tag":"DMO"},"language":"en"}' > "$PROJ/.claude/memokit.json"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  ctx | grep -qF 'memokit.json changed during this session'
}
@test "config notice: deleted with snapshot announces once, valid json" {
  mk_project; _snap
  rm -f "$PROJ/.claude/memokit.json"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  printf '%s' "$output" | jq -e . >/dev/null
  ctx | grep -qF 'memokit.json bu oturum sırasında silindi: geri konana kadar alt ajan çağrıları reddedilir.'
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  [ -z "$output" ]
}
@test "config notice: deleted without snapshot stays silent" {
  mk_project
  rm -f "$PROJ/.claude/memokit.json"
  run_hook inject-rules.sh "$(prompt_payload 'merhaba')"
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

# 0.8.1 (spec 9): the builtin context7 hint.
@test "context7 hint fires once on library, API and version questions (en and tr)" {
  mk_project
  local p n
  for p in 'how do I use the React 19 useActionState hook' "what changed in Next.js 15" 'is this API deprecated' 'upgrade prisma to v6' \
           "Next.js 15'te ne değişti" 'bu kütüphanenin son sürümünde ne var' 'bu API deprecated mı' "prisma'yı v6'ya yükselt" \
           'where are the docs for this sdk version' 'is the Stripe SDK v12 API still supported' 'Expo SDK 52 nasıl kurulur'; do
    run_hook inject-rules.sh "$(prompt_payload "$p")"
    n="$(ctx | grep -o 'context7' | wc -l | tr -d ' ')"
    [ "$n" = 1 ] || { echo "no single hint for: $p ($n)"; false; }
  done
}
@test "hints match ASCII case-insensitively whatever the locale (an upper-case I under tr_TR.UTF-8)" {
  mk_project
  if locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\{0,1\}8$'; then
    export LANG=tr_TR.UTF-8 LC_ALL=tr_TR.UTF-8
  fi
  local p
  for p in 'WHICH LIBRARY VERSION ADDED THIS' 'IS THIS API DEPRECATED'; do
    run_hook inject-rules.sh "$(prompt_payload "$p")"
    ctx | grep -qF 'context7' || { echo "no context7 hint for: $p"; false; }
  done
  run_hook inject-rules.sh "$(prompt_payload 'THE BUILD IS BROKEN')"
  ctx | grep -qF 'systematic-debugging' || { echo "no debugging hint: [$output]"; false; }
  # GNU grep -i folds I to the dotless i under tr_TR (BSD grep does not, so
  # the lines above pass on macOS either way): matches() runs grep under C
  # first.
  sed -n '/^matches() {$/,/^}$/p' "$HOOKS/inject-rules.sh" | sed -n 2p | grep -qF '| LC_ALL=C grep -qiE "$1"'
}
@test "hints still fold Turkish upper-case letters through the locale" {
  mk_project
  if locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\{0,1\}8$'; then
    export LANG=tr_TR.UTF-8 LC_ALL=tr_TR.UTF-8
  else
    skip "no tr_TR.UTF-8 locale"
  fi
  run_hook inject-rules.sh "$(prompt_payload 'TESTLER ÇALIŞMIYOR')"
  ctx | grep -qF 'systematic-debugging' || { echo "no debugging hint: [$output]"; false; }
  run_hook inject-rules.sh "$(prompt_payload 'KÜTÜPHANE SÜRÜMÜ NEDİR')"
  ctx | grep -qF 'context7' || { echo "no context7 hint: [$output]"; false; }
}
@test "context7 hint stays silent on plain coding requests" {
  mk_project
  local p
  for p in 'rename the helper function' 'merhaba' 'bu fonksiyonu sadeleştir' 'add a button to the page' 'sunucuyu yeniden başlat' \
           'add api documentation comments to this class' 'update the README with the new package version' 'api sürümü alanını ekle' 'add sdk2 folder to the build'; do
    run_hook inject-rules.sh "$(prompt_payload "$p")"
    lacks "$(ctx)" 'context7' || { echo "fired for: $p"; false; }
  done
}
@test "context7 hint is off when hints.builtin omits it" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"hints":{"builtin":["review"]}}'
  run_hook inject-rules.sh "$(prompt_payload 'is this API deprecated')"
  lacks "$(ctx)" 'context7'
}
@test "context7 hint: a 64 KiB prompt with the match near the end decides within 2 s of CPU" {
  mk_project
  if locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\{0,1\}8$'; then
    export LANG=tr_TR.UTF-8 LC_ALL=tr_TR.UTF-8
  fi
  local f="$BATS_TEST_TMPDIR/big" t0 cpu
  { awk 'BEGIN { for (i = 0; i < 6500; i++) printf "api sdk package v1 x\n" }'; printf 'is this deprecated'; } > "$f"
  local pl; pl="$(jq -nc --rawfile p "$f" --arg cwd "$PROJ" '{prompt:$p,cwd:$cwd}')"
  TIMEFORMAT='%U %S'
  cpu="$( { time run_hook inject-rules.sh "$pl" >/dev/null; } 2>&1 )"
  cpu="$(printf '%s' "$cpu" | awk '{printf "%d", ($1+$2)*1000}')"
  echo "cpu ms: $cpu"
  [ "$cpu" -lt 2000 ]
}
