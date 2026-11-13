#!/usr/bin/env bats
# hooks/convert-read.sh: opt-in markitdown conversion of PDF and Office reads.
# A stub markitdown (tests/fixtures/convert/markitdown) stands in for the
# real CLI, which is never installed for the tests.
load helpers

CONVERT_ON='{"version":1,"project":{"name":"Demo","tag":"DMO"},"language":"en","convert":{"markitdown":true}}'

setup() {
  mk_project "$CONVERT_ON"
  # Never read the developer's own ~/.claude settings (Read deny rules).
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR
  export PATH="$MK_REPO/tests/fixtures/convert:$PATH"
  export MK_STUB_LOG="$BATS_TEST_TMPDIR/stub.log"; : > "$MK_STUB_LOG"
  export MK_STUB_PID="$BATS_TEST_TMPDIR/stub.pid"
  MK_STUB_MD="$(printf '%0500d' 0)"   # 500 non-blank characters
  export MK_STUB_MD
  CACHE="$TMPDIR/memokit-$(printf '%s' "$PROJ" | cksum | cut -d' ' -f1)-careful-convert"
  # Extra managed settings for the tests; the machine's own are read too.
  export MEMOKIT_TEST_MANAGED_DIR="$BATS_TEST_TMPDIR/managed"; mkdir -p "$MEMOKIT_TEST_MANAGED_DIR"
  # A machine whose real managed settings hold a Read rule makes the hook
  # stand down everywhere: the redirect tests cannot run there.
  if real_managed_read_rule; then skip "real managed settings hold a Read deny/ask rule"; fi
}

# real_managed_read_rule -- true when this machine's managed settings (or
# their drop-ins) hold a Read deny or ask rule, or cannot be parsed.
real_managed_read_rule() {
  local f
  set --
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" \
           "/Library/Application Support/ClaudeCode/managed-settings.d"/*.json \
           /etc/claude-code/managed-settings.json /etc/claude-code/managed-settings.d/*.json; do
    [ -e "$f" ] && set -- "$@" "$f"
  done
  [ "$#" -eq 0 ] && return 1
  [ "$(jq -s '[.[] | ((.permissions.deny // []) + (.permissions.ask // []))[]
      | select(type == "string" and test("^\\s*Read\\s*(\\(|$)"))] | length' "$@" 2>/dev/null)" != 0 ]
}

# key_of FILE -- the cache key: SHA-256 of the content, then the size.
key_of() {
  local h
  if command -v shasum >/dev/null 2>&1; then h="$(shasum -a 256 < "$1")"; else h="$(sha256sum < "$1")"; fi
  printf '%s-%s' "${h%% *}" "$(wc -c < "$1" | tr -d ' ')"
}
decision_of() { printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // "none"'; }

# mk_pdf PATH PAGES -- a fake PDF: one /Pages tree node and PAGES /Page objects.
mk_pdf() {
  local i
  mkdir -p "$(dirname "$1")"
  { printf '%%PDF-1.4\n1 0 obj\n<< /Type /Pages /Count %s >>\nendobj\n' "$2"
    i=0; while [ "$i" -lt "$2" ]; do printf '<< /Type/Page /Parent 1 0 R >>\n'; i=$((i + 1)); done
    printf '%%%%EOF\n'; } > "$1"
}
# read_payload FILE [AGENT_ID] [EXTRA_TOOL_INPUT_JSON] [CWD]
read_payload() {
  local x="${3:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg p "$1" --arg a "${2:-}" --arg cwd "${4:-$PROJ}" --argjson x "$x" \
    '{hook_event_name:"PreToolUse",session_id:"cv1",tool_name:"Read",tool_input:({file_path:$p} + $x),cwd:$cwd}
     + (if $a=="" then {} else {agent_id:$a} end)'
}
calls() { grep -c '^call ' "$MK_STUB_LOG" || true; }
new_path() { printf '%s' "$output" | jq -r '.hookSpecificOutput.updatedInput.file_path // empty'; }
untouched() { [ "$status" -eq 0 ] && [ -z "$output" ]; }

@test "setting off: untouched, markitdown not called" {
  mk_project; mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched; [ "$(calls)" -eq 0 ]
}

@test "markitdown not on PATH: untouched" {
  mk_pdf "$PROJ/doc.pdf" 1
  p="$(read_payload "$PROJ/doc.pdf")"
  PATH="$(path_without)"
  run_hook convert-read.sh "$p"
  untouched; [ "$(calls)" -eq 0 ]
}

@test "non-matching extension: untouched" {
  for f in notes.txt doc.pdfx doc.pdf.txt doc.doc; do
    printf 'x' > "$PROJ/$f"
    run_hook convert-read.sh "$(read_payload "$PROJ/$f")"
    untouched || { echo "touched: $f $output"; false; }
  done
  [ "$(calls)" -eq 0 ]
}

@test "non-matching Read takes the fast path: no jq" {
  printf 'x' > "$PROJ/notes.txt"
  p="$(read_payload "$PROJ/notes.txt")"
  fake="$BATS_TEST_TMPDIR/fakejq"; mkdir -p "$fake"
  printf '#!/bin/bash\necho jq >> "%s/jq.log"\nexec "%s" "$@"\n' "$fake" "$(command -v jq)" > "$fake/jq"
  chmod +x "$fake/jq"
  PATH="$fake:$PATH"
  run_hook convert-read.sh "$p"
  untouched
  [ ! -e "$fake/jq.log" ]
}

@test "pages argument given: untouched" {
  mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf" "" '{"pages":"1-2"}')"
  untouched; [ "$(calls)" -eq 0 ]
}

@test "PDF with enough text: Read redirected to the cached Markdown" {
  mk_pdf "$PROJ/doc.pdf" 2
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf" "" '{"offset":1,"limit":50}')"
  [ "$status" -eq 0 ]
  k="$(key_of "$PROJ/doc.pdf")"
  [ "$(new_path)" = "$CACHE/$k/doc.pdf.md" ]
  [ "$(cat "$CACHE/$k/doc.pdf.md")" = "$MK_STUB_MD" ]
  [ "$(ls -A "$CACHE/$k")" = "doc.pdf.md" ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
    and .hookSpecificOutput.permissionDecision == "allow"
    and .hookSpecificOutput.updatedInput.offset == 1 and .hookSpecificOutput.updatedInput.limit == 50'
  ctx | grep -qF 'markitdown'
  ctx | grep -qF 'pages'
  [ "$(ctx | wc -l | tr -d ' ')" -le 1 ]
  [ "$(ls -ld "$CACHE" | cut -c1-10)" = "drwx------" ]
  [ "$(calls)" -eq 1 ]
}

@test "second Read of the unchanged file: cache hit, markitdown not called again" {
  mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  first="$(new_path)"; [ -n "$first" ]
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ "$(new_path)" = "$first" ]
  [ "$(calls)" -eq 1 ]
  # A changed source converts again.
  printf '%% changed\n' >> "$PROJ/doc.pdf"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ -n "$(new_path)" ] && [ "$(new_path)" != "$first" ]
  [ "$(calls)" -eq 2 ]
}

@test "scanned-looking PDF (under 200 characters per page): untouched, not converted twice" {
  mk_pdf "$PROJ/scan.pdf" 3
  MK_STUB_MD="$(printf '%0500d' 0)"   # 166 per page
  run_hook convert-read.sh "$(read_payload "$PROJ/scan.pdf")"
  untouched
  run_hook convert-read.sh "$(read_payload "$PROJ/scan.pdf")"
  untouched
  [ "$(calls)" -eq 1 ]
}

@test "page count ignores /Pages; blanks do not count as text" {
  mk_pdf "$PROJ/two.pdf" 2
  MK_STUB_MD="$(printf '%0450d' 0)"   # 225 per page over 2 pages, 150 if /Pages counted
  run_hook convert-read.sh "$(read_payload "$PROJ/two.pdf")"
  [ -n "$(new_path)" ]
  mk_pdf "$PROJ/blank.pdf" 1
  MK_STUB_MD="$(printf '%0150d' 0)$(printf '%300s' '')"
  run_hook convert-read.sh "$(read_payload "$PROJ/blank.pdf")"
  untouched
}

@test "PDF without readable /Page objects counts as one page" {
  printf '%%PDF-1.7\nstream compressed\n' > "$PROJ/os.pdf"
  MK_STUB_MD="$(printf '%0250d' 0)"
  run_hook convert-read.sh "$(read_payload "$PROJ/os.pdf")"
  [ -n "$(new_path)" ]
}

@test "Office files (any case) redirect on any non-empty Markdown; empty Markdown leaves them" {
  printf 'PK\003\004' > "$PROJ/Report.DOCX"
  MK_STUB_MD="short text"
  run_hook convert-read.sh "$(read_payload "$PROJ/Report.DOCX")"
  [ -n "$(new_path)" ]
  for f in deck.pptx sheet.Xlsx; do
    printf 'PK\003\004%s' "$f" > "$PROJ/$f"
    run_hook convert-read.sh "$(read_payload "$PROJ/$f")"
    [ -n "$(new_path)" ] || { echo "not redirected: $f"; false; }
  done
  printf 'PK\003\004empty' > "$PROJ/empty.docx"
  MK_STUB_MD=""
  run_hook convert-read.sh "$(read_payload "$PROJ/empty.docx")"
  untouched
}

@test "markitdown failure: untouched, nothing left in the cache, retried next time" {
  mk_pdf "$PROJ/doc.pdf" 1
  export MK_STUB_MODE=fail
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched
  [ -z "$(ls -A "$CACHE" 2>/dev/null)" ]
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched
  [ "$(calls)" -eq 2 ]
}

@test "conversion over its time bound: killed with its children, untouched, not retried" {
  mk_pdf "$PROJ/big.pdf" 1
  export MK_STUB_MODE=sleep MEMOKIT_TEST_CONVERT_SECS=1
  start=$SECONDS
  run_hook convert-read.sh "$(read_payload "$PROJ/big.pdf")"
  untouched
  [ $((SECONDS - start)) -lt 10 ]
  pid="$(cat "$MK_STUB_PID")"; [ -n "$pid" ]
  sleep 0.3
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  run_hook convert-read.sh "$(read_payload "$PROJ/big.pdf")"
  untouched
  [ "$(calls)" -eq 1 ]
}

@test "a path with spaces and quotes reaches markitdown as one argument" {
  f="$PROJ/my \"odd\" file's \$(touch pwned) name.pdf"
  mk_pdf "$f" 1
  run_hook convert-read.sh "$(read_payload "$f")"
  [ -n "$(new_path)" ]
  [ "$(sed -n 1p "$MK_STUB_LOG")" = "call 3" ]
  [ "$(sed -n 2p "$MK_STUB_LOG")" = "arg[$f]" ]
  [ "$(sed -n 3p "$MK_STUB_LOG")" = "arg[-o]" ]
  [ ! -e "$PROJ/pwned" ] && [ ! -e pwned ]
}

@test "subagent payload is redirected the same way" {
  mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf" a1)"
  [ -n "$(new_path)" ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "allow"'
}

@test "file outside the launch dir: ask, naming the original path, from a per-source cache dir" {
  f="$BATS_TEST_TMPDIR/outside/my report.pdf"; mk_pdf "$f" 1
  run_hook convert-read.sh "$(read_payload "$f")"
  [ "$(decision_of)" = ask ]
  r="$(reason)"
  printf '%s' "$r" | grep -qF -- "$f" || { echo "reason: $r"; false; }
  printf '%s' "$r" | grep -qF 'Markdown'
  k="$(key_of "$f")"
  [ "$(new_path)" = "$CACHE/$k/my report.pdf.md" ]
  [ "$(ls -A "$CACHE/$k")" = "my report.pdf.md" ]
}

@test "allow only for a source inside the launch dir (CLAUDE_PROJECT_DIR), not the whole repo" {
  mkdir -p "$PROJ/sub"; export CLAUDE_PROJECT_DIR="$PROJ/sub"
  mk_pdf "$PROJ/top.pdf" 1; mk_pdf "$PROJ/sub/in.pdf" 2
  run_hook convert-read.sh "$(read_payload "$PROJ/top.pdf" "" "" "$PROJ/sub")"
  [ -n "$(new_path)" ]; [ "$(decision_of)" = ask ]
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/in.pdf" "" "" "$PROJ/sub")"
  [ -n "$(new_path)" ]; [ "$(decision_of)" = allow ]
  # A symlink inside the launch dir to a file outside it is not inside.
  ln -s "$PROJ/top.pdf" "$PROJ/sub/link.pdf"
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/link.pdf" "" "" "$PROJ/sub")"
  [ "$(decision_of)" = ask ]
}

@test "Read rules in the launch dir, the payload cwd or managed settings (and drop-ins): untouched" {
  mk_pdf "$PROJ/sub/secret.pdf" 1
  mkdir -p "$PROJ/sub/.claude" "$PROJ/other/.claude"
  export CLAUDE_PROJECT_DIR="$PROJ/sub"
  printf '%s' '{"permissions":{"deny":["Read(./secret.pdf)"]}}' > "$PROJ/sub/.claude/settings.local.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/secret.pdf" "" "" "$PROJ/sub")"
  untouched
  rm "$PROJ/sub/.claude/settings.local.json"
  export CLAUDE_PROJECT_DIR="$PROJ"
  printf '%s' '{"permissions":{"ask":["Read(//tmp/**)"]}}' > "$PROJ/other/.claude/settings.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/secret.pdf" "" "" "$PROJ/other")"
  untouched
  rm "$PROJ/other/.claude/settings.json"
  printf '%s' '{"permissions":{"deny":["Read"]}}' > "$MEMOKIT_TEST_MANAGED_DIR/managed-settings.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/secret.pdf")"
  untouched
  rm "$MEMOKIT_TEST_MANAGED_DIR/managed-settings.json"
  mkdir -p "$MEMOKIT_TEST_MANAGED_DIR/managed-settings.d"
  printf '%s' '{"permissions":{"deny":["Read(**/*.pdf)"]}}' > "$MEMOKIT_TEST_MANAGED_DIR/managed-settings.d/10-docs.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/secret.pdf")"
  untouched
  rm "$MEMOKIT_TEST_MANAGED_DIR/managed-settings.d/10-docs.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/sub/secret.pdf")"
  [ -n "$(new_path)" ]
  [ "$(calls)" -eq 1 ]
}

@test "a skip marker is not refreshed on a hit and expires after a day" {
  mk_pdf "$PROJ/scan.pdf" 3
  run_hook convert-read.sh "$(read_payload "$PROJ/scan.pdf")"
  untouched
  skip="$CACHE/$(key_of "$PROJ/scan.pdf")/.skip"
  [ -f "$skip" ]
  [ "$(ls -l "$skip" | cut -c1-10)" = "-rw-------" ]
  t="$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)"
  touch -t "$t" "$skip"
  run_hook convert-read.sh "$(read_payload "$PROJ/scan.pdf")"
  untouched; [ "$(calls)" -eq 1 ]
  [ -n "$(find "$skip" -mmin +100)" ]
  touch -t 202001010000 "$skip"
  MK_STUB_MD="$(printf '%0700d' 0)"
  run_hook convert-read.sh "$(read_payload "$PROJ/scan.pdf")"
  [ -n "$(new_path)" ]; [ "$(calls)" -eq 2 ]
  [ ! -e "$skip" ]
}

@test "page count falls back to the largest /Count when /Page objects are hidden" {
  printf '%%PDF-1.7\n<< /Type /Pages /Kids [4 0 R] /Count 2 >>\n<< /Type /Pages /Count 3 >>\nstream compressed\n' > "$PROJ/os3.pdf"
  MK_STUB_MD="$(printf '%0500d' 0)"   # 166 per page over 3 pages
  run_hook convert-read.sh "$(read_payload "$PROJ/os3.pdf")"
  untouched
  MK_STUB_MD="$(printf '%0650d' 0)"
  printf '%% v2\n' >> "$PROJ/os3.pdf"
  run_hook convert-read.sh "$(read_payload "$PROJ/os3.pdf")"
  [ -n "$(new_path)" ]
}

@test "a conversion that ignores TERM is killed 2 s later" {
  mk_pdf "$PROJ/stuck.pdf" 1
  export MK_STUB_MODE=hang MEMOKIT_TEST_CONVERT_SECS=1
  start=$SECONDS
  run_hook convert-read.sh "$(read_payload "$PROJ/stuck.pdf")"
  untouched
  [ $((SECONDS - start)) -lt 10 ]
  pid="$(cat "$MK_STUB_PID")"; [ -n "$pid" ]
  sleep 0.3
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}

@test "without pgrep (Linux without procps) the tree is found through /proc and killed" {
  [ -r /proc/self/stat ] || skip "no /proc: the fallback is Linux only"
  # PATH as before, every directory linked into one, pgrep left out.
  local bin="$BATS_TEST_TMPDIR/nopgrep" d
  mkdir -p "$bin"
  local IFS=:
  # (a name in two directories: the first one wins, ln reports the rest)
  for d in $PATH; do if [ -d "$d" ]; then ln -s "$d"/* "$bin"/ 2>/dev/null || :; fi; done
  unset IFS
  rm -f "$bin/pgrep"
  export PATH="$bin"
  ! command -v pgrep
  mk_pdf "$PROJ/big.pdf" 1
  export MK_STUB_MODE=sleep MEMOKIT_TEST_CONVERT_SECS=1
  run_hook convert-read.sh "$(read_payload "$PROJ/big.pdf")"
  untouched
  pid="$(cat "$MK_STUB_PID")"; [ -n "$pid" ]
  sleep 0.3
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}

@test "a Read deny or ask rule in any settings file: untouched" {
  mk_pdf "$PROJ/doc.pdf" 1
  printf '%s' '{"permissions":{"deny":["Read(./secret/**)"]}}' > "$PROJ/.claude/settings.local.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched
  rm "$PROJ/.claude/settings.local.json"
  mkdir -p "$HOME/.claude"
  printf '%s' '{"permissions":{"ask":["Read"]}}' > "$HOME/.claude/settings.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched
  printf '%s' '{"permissions":{"deny":["Bash(rm:*)"],"ask":["WebFetch"]}}' > "$HOME/.claude/settings.json"
  printf '%s' 'not json' > "$PROJ/.claude/settings.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched
  rm "$PROJ/.claude/settings.json"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ -n "$(new_path)" ]
  [ "$(calls)" -eq 1 ]
}

@test "cache dir that is a symlink: untouched" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CACHE"
  mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}

# 0.8.1 release fix d: nothing in the cache is trusted unless the cache dir,
# the key dir and the entry are ours and not links; anything else is a miss.
@test "a key dir that is a symlink: miss, reconverted into a fresh dir, never redirected into the link" {
  mk_pdf "$PROJ/a.pdf" 2
  run_hook convert-read.sh "$(read_payload "$PROJ/a.pdf")"
  [ -n "$(new_path)" ]
  mk_pdf "$PROJ/doc.pdf" 1
  k="$(key_of "$PROJ/doc.pdf")"
  mkdir -p "$BATS_TEST_TMPDIR/planted"
  printf 'FORGED %0300d\n' 0 > "$BATS_TEST_TMPDIR/planted/doc.pdf.md"
  ln -s "$BATS_TEST_TMPDIR/planted" "$CACHE/$k"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ "$status" -eq 0 ]
  [ "$(new_path)" = "$CACHE/$k/doc.pdf.md" ]
  [ ! -L "$CACHE/$k" ] && [ -d "$CACHE/$k" ]
  [ "$(cat "$CACHE/$k/doc.pdf.md")" = "$MK_STUB_MD" ]
  [ "$(calls)" -eq 2 ]
  # the link's target is left as it was
  grep -q FORGED "$BATS_TEST_TMPDIR/planted/doc.pdf.md"
  [ "$(ls -A "$BATS_TEST_TMPDIR/planted")" = "doc.pdf.md" ]
  # the next Read hits the fresh entry
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ "$(new_path)" = "$CACHE/$k/doc.pdf.md" ]; [ "$(calls)" -eq 2 ]
}

@test "a skip marker in a symlinked key dir is not honoured; a key dir that is a file is replaced" {
  mk_pdf "$PROJ/a.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/a.pdf")"
  [ -n "$(new_path)" ]
  mk_pdf "$PROJ/doc.pdf" 2
  k="$(key_of "$PROJ/doc.pdf")"
  mkdir -p "$BATS_TEST_TMPDIR/planted"
  : > "$BATS_TEST_TMPDIR/planted/.skip"
  ln -s "$BATS_TEST_TMPDIR/planted" "$CACHE/$k"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ "$(new_path)" = "$CACHE/$k/doc.pdf.md" ]; [ "$(calls)" -eq 2 ]
  [ ! -L "$CACHE/$k" ]
  [ -f "$BATS_TEST_TMPDIR/planted/.skip" ]
  # a plain file where the key dir belongs
  mk_pdf "$PROJ/b.pdf" 2; printf '%% b\n' >> "$PROJ/b.pdf"
  k="$(key_of "$PROJ/b.pdf")"
  printf 'FORGED\n' > "$CACHE/$k"
  run_hook convert-read.sh "$(read_payload "$PROJ/b.pdf")"
  [ "$(new_path)" = "$CACHE/$k/b.pdf.md" ]; [ "$(calls)" -eq 3 ]
  [ -d "$CACHE/$k" ]
}

@test "an entry that is a symlink or a directory is never redirected to" {
  mk_pdf "$PROJ/doc.pdf" 1
  k="$(key_of "$PROJ/doc.pdf")"
  mk_pdf "$PROJ/a.pdf" 2
  run_hook convert-read.sh "$(read_payload "$PROJ/a.pdf")"
  [ -n "$(new_path)" ]
  # a symlinked entry: a miss; the conversion replaces the link itself
  ( umask 077; mkdir "$CACHE/$k" )
  printf 'FORGED %0300d\n' 0 > "$BATS_TEST_TMPDIR/forged.md"
  ln -s "$BATS_TEST_TMPDIR/forged.md" "$CACHE/$k/doc.pdf.md"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ "$(new_path)" = "$CACHE/$k/doc.pdf.md" ]; [ "$(calls)" -eq 2 ]
  [ ! -L "$CACHE/$k/doc.pdf.md" ]
  [ "$(cat "$CACHE/$k/doc.pdf.md")" = "$MK_STUB_MD" ]
  grep -q FORGED "$BATS_TEST_TMPDIR/forged.md"
  # a directory where the entry belongs: neither converted nor redirected
  rm -f "$CACHE/$k/doc.pdf.md"; mkdir "$CACHE/$k/doc.pdf.md"
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched; [ "$(calls)" -eq 2 ]
  [ -z "$(ls -A "$CACHE/$k/doc.pdf.md")" ]
}

@test "the cache lives in memokit's protected state family (memokit-<n>-careful-convert)" {
  mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  case "$(new_path)" in "${TMPDIR%/}"/memokit-[0-9]*-careful-convert/*/doc.pdf.md) ;; *) echo "got $(new_path)"; false ;; esac
  [ ! -e "${CACHE%-careful-convert}-convert" ]
}

@test "a new conversion prunes cache entries older than 7 days" {
  mk_pdf "$PROJ/a.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/a.pdf")"
  [ -n "$(new_path)" ]
  mkdir -p "$CACHE/old1" "$CACHE/old2"
  printf 'old' > "$CACHE/old1/x.pdf.md"; touch -t 202001010000 "$CACHE/old1/x.pdf.md"
  : > "$CACHE/old2/.skip"; touch -t 202001010000 "$CACHE/old2/.skip"
  mk_pdf "$PROJ/b.pdf" 2
  run_hook convert-read.sh "$(read_payload "$PROJ/b.pdf")"
  [ -n "$(new_path)" ]
  [ ! -e "$CACHE/old1" ] && [ ! -e "$CACHE/old2" ]
  [ -f "$CACHE/$(key_of "$PROJ/a.pdf")/a.pdf.md" ]
  # A new skip marker prunes too.
  mkdir -p "$CACHE/old3"; printf 'old' > "$CACHE/old3/y.pdf.md"; touch -t 202001010000 "$CACHE/old3/y.pdf.md"
  mk_pdf "$PROJ/scan.pdf" 5
  run_hook convert-read.sh "$(read_payload "$PROJ/scan.pdf")"
  untouched
  [ ! -e "$CACHE/old3" ]
}

@test "project without memokit config: silent" {
  mk_project none; mk_pdf "$PROJ/doc.pdf" 1
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  untouched; [ "$(calls)" -eq 0 ]
}

@test "the test seam adds a managed dir; the real managed paths are still checked" {
  mk_pdf "$PROJ/doc.pdf" 1
  p="$(read_payload "$PROJ/doc.pdf")"
  run "$MK_BASH" -c 'printf "%s" "$2" | "$0" -x "$1" 2>&1 >/dev/null' "$MK_BASH" "$HOOKS/convert-read.sh" "$p"
  for f in "/Library/Application Support/ClaudeCode/managed-settings.json" /etc/claude-code/managed-settings.json \
           "/Library/Application Support/ClaudeCode/managed-settings.d" /etc/claude-code/managed-settings.d \
           "$MEMOKIT_TEST_MANAGED_DIR/managed-settings.json"; do
    printf '%s' "$output" | grep -E "^\++ '?\['? -e " | grep -qF -- "$f" || { echo "not checked: $f"; false; }
  done
}

@test "a source path with a control character is never redirected" {
  for n in "$(printf 'a\nb.pdf')" "$(printf 'a\tb.pdf')" "$(printf 'a\033[31mb.pdf')" "$(printf 'a\rb.pdf')"; do
    mk_pdf "$PROJ/$n" 1
    run_hook convert-read.sh "$(read_payload "$PROJ/$n")"
    untouched || { echo "redirected: $(printf '%q' "$n") $output"; false; }
  done
  [ "$(calls)" -eq 0 ]
}

@test "allow needs CLAUDE_PROJECT_DIR: a payload cwd alone gives ask" {
  mk_pdf "$PROJ/doc.pdf" 1
  unset CLAUDE_PROJECT_DIR
  run_hook convert-read.sh "$(read_payload "$PROJ/doc.pdf")"
  [ -n "$(new_path)" ]
  [ "$(decision_of)" = ask ]
}

@test "/Count with a leading zero is read in base 10" {
  printf '%%PDF-1.7\n<< /Type /Pages /Count 08 >>\nstream compressed\n' > "$PROJ/c08.pdf"
  MK_STUB_MD="$(printf '%01000d' 0)"   # 125 per page over 8 pages
  run_hook convert-read.sh "$(read_payload "$PROJ/c08.pdf")"
  untouched
  printf '%% v2\n' >> "$PROJ/c08.pdf"
  MK_STUB_MD="$(printf '%02000d' 0)"   # 250 per page
  run_hook convert-read.sh "$(read_payload "$PROJ/c08.pdf")"
  [ -n "$(new_path)" ]
}

@test "a long basename is cut to 120 bytes in the cache, keeping the extension; the next Read hits" {
  long="$(printf '%0251d' 0 | tr 0 a).pdf"
  mbyte="x$(printf '%0125d' 0 | sed 's/0/ç/g').pdf"
  for n in "$long" "$mbyte"; do
    mk_pdf "$PROJ/$n" 1
    : > "$MK_STUB_LOG"
    run_hook convert-read.sh "$(read_payload "$PROJ/$n")"
    md="$(new_path)"; [ -n "$md" ] || { echo "not redirected: ${#n}"; false; }
    b="$(basename "$md")"
    [ "$(printf '%s' "$b" | LC_ALL=C wc -c | tr -d ' ')" -le 123 ]
    case "$b" in *.pdf.md) ;; *) echo "name: $b"; false ;; esac
    printf '%s' "$b" | iconv -f UTF-8 -t UTF-8 >/dev/null
    run_hook convert-read.sh "$(read_payload "$PROJ/$n")"
    [ "$(new_path)" = "$md" ]
    [ "$(calls)" -eq 1 ]
  done
}
