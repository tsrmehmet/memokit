#!/usr/bin/env bats
load helpers
@test "silent without config" { mk_project none; run_hook precompact-handoff.sh '{}'; [ -z "$output" ]; }
@test "summary instructions mention STATE" { mk_project; run_hook precompact-handoff.sh '{}'; printf '%s' "$output" | grep -q 'docs/STATE.md'; }
@test "english summary" {
  mk_project '{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en"}'
  run_hook precompact-handoff.sh '{}'; printf '%s' "$output" | grep -qi 'preserve'
}
