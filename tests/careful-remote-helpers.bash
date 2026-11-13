# Shared helpers for tests/careful-remote-*.bats (loaded after helpers).
RCFG='{"version":1,"project":{"name":"D","tag":"DMO"},"language":"en",
"careful":{"patterns":[{"match":"flyctl deploy","label":"fly","target":"fly-prod"}]},
"remote":{"deployBranches":["deploy","public-release"],"hosts":["31.210.53.162","prod.example.com"],"readOnlyFirstWords":["pm2-list"]}}'
RB=.claude/memokit/runbooks/deploy.sh

# rlib CODE ARG... -- run CODE with common.sh, careful.sh and remote.sh loaded.
rlib() {
  local code="$1"; shift
  run "$MK_BASH" -c ". '$HOOKS/lib/common.sh'; . '$HOOKS/lib/careful.sh'; . '$HOOKS/lib/remote.sh'; mk_resolve_root '{}'; mk_load_config >/dev/null; $code" _ "$@"
}
labels()  { rlib 'mk_careful_labels "$1"' "$1"; }
targets() { rlib 'mk_remote_targets "$1"' "$1"; }
strip()   { rlib 'mk_remote_strip_covered "$1" "$2"' "$1" "$2"; }
valid()   { rlib 'mk_remote_target_valid "$1"' "$1"; }

rb_sha() { { sha256sum 2>/dev/null || shasum -a 256; } < "$PROJ/$RB" | cut -d' ' -f1; }
mk_runbook() {
  mkdir -p "$PROJ/.claude/memokit/runbooks"
  printf '#!/bin/sh\necho deploy "$1"\n' > "$PROJ/$RB"
}

# check_table: stdin lines "label|targets|command" (targets space-separated,
# sorted; label "none" = no remote label and no target). @SHA in a line is
# the runbook's sha256.
check_table() {
  local want tg cmd got sha=""
  [ -f "$PROJ/$RB" ] && sha="$(rb_sha)"
  while IFS='|' read -r want tg cmd; do
    [ -z "$cmd" ] && continue
    tg="${tg//@SHA/@$sha}"
    targets "$cmd"
    got="$(printf '%s' "$output" | tr '\n' ' ')"; got="${got% }"
    [ "$got" = "$tg" ] || { echo "targets: $cmd -> [$got], want [$tg]"; return 1; }
    labels "$cmd"
    if [ "$want" = none ]; then
      if printf '%s\n' "$output" | grep -qxE 'deploy-push|remote-mutate|k8s-mutate|runbook'; then
        echo "label: $cmd -> [$output], want no remote label"; return 1
      fi
    else
      printf '%s\n' "$output" | grep -qx "$want" || { echo "label: $cmd -> [$output], want $want"; return 1; }
    fi
  done
}
