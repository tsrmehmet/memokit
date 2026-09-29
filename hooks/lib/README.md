# hooks/lib — shared hook library

`common.sh` is sourced by every hook in `hooks/*.sh`; it is never executed
directly. `config.jq` is the config-parsing/validation program `mk_load_config`
runs via `jq -r -f`.

Every hook in this plugin starts with one of the two canonical preambles
below, copied verbatim (only `<hook-name>` changes). This keeps the gate
order — kill switch / config load / activation — identical across every
hook, which is the property the tests in `tests/preamble.bats` enforce.

## Guard preamble

Used by the two fail-closed guards: `guard-edit.sh` and
`guard-subagent-authority.sh`. These hooks must deny on any "cannot
classify" path, so config loading happens inline and a `jq`-missing /
invalid-config condition itself produces a `deny` JSON payload instead of
silently exiting 0.

```bash
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_guard_off && exit 0
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "<hook-name>" "$PAYLOAD"
if ! mk_load_config; then
  if [ "$MK_CONFIG_ERR" = "jq" ]; then
    printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "PreToolUse",\n    "permissionDecision": "deny",\n    "permissionDecisionReason": "%s"\n  }\n}\n' "$(mk_msg CONFIG_NO_JQ_STATIC)"
    exit 0
  fi
  jq -n --arg r "$(mk_msg CONFIG_INVALID "$MK_CONFIG_ERR")" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi
```

Gate order, and why it cannot be reordered: the kill switch (`mk_guard_off`)
is checked before `mk_resolve_root`/`mk_active` so `MEMOKIT_GUARD_OFF=1` is a
true unconditional override, independent of whether a project root or config
can even be found. `mk_active` (no `.claude/memokit.json`) still exits 0
silently — the activation gate applies before config loading is attempted.

## Non-guard preamble

Used by every other hook (session-start.sh deviates from this, see Task 7 —
it must still print the init hint when the project is inactive).

```bash
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "<hook-name>" "$PAYLOAD"
mk_load_config || exit 0
```

These hooks are fail-open: any of the gates above simply exits 0 with no
output, since a hint or side-effect hook must never block Claude Code.

## Message text transformation rules

Applied to every user-visible string ported from a legacy hook into
`hooks/messages/en.sh` / `hooks/messages/tr.sh`:

- `CLAUDE.md §0` → `WORKING-MODEL.md §1`
- `CLAUDE.md §2` → `WORKING-MODEL.md §4`
- `coder.md kural 0` → `memokit:coder kural 0`
- `subagent_type:"coder"` / `subagent_type:coder` → `subagent_type:"memokit:coder"`
- `/handoff` → `/memokit:handoff`
- `resume skill'i` → `/memokit:resume`
- every literal guarded-dir enumeration (`src/, tests/, web/ ve mobile/`,
  `src/ tests/ web/ mobile/`, `src/, tests/, web/ veya mobile/`, `src/tests`)
  → `%s` filled by `mk_dirs_human`
- legacy `<PREFIX>_*` env knobs → `MEMOKIT_*`
- `[<PREFIX>-` → `[@TAG@-`

No project names may appear in ported comments or messages outside `docs/`;
legacy comments that cite one are rewritten generically (e.g. "a real
incident in a production repo", "<Project>.Web").

## Sanitizing external process output (inject-rules.sh graphify gate)

A hook's no-`jq` fallback JSON is hand-written (`printf` with a literal
format string), which is only safe when the interpolated value is known in
advance to contain no `"`, no `\`, and no control characters -- that is
exactly what the `_STATIC` message-key contract guarantees for this repo's
own strings. `inject-rules.sh`'s graphify-staleness gate text does not come
from this repo's own strings, though: it is the first line of output from an
external script (`scripts/graph-staleness.sh`), a boundary this repo cannot
enforce by contract alone. The hook does not trust that script to already
produce safe output -- it explicitly strips quotes, backslashes, and C0
control characters (`ESC`, tab, ...) from that line before using it anywhere,
even though today's call site (jq is available) does not strictly need it
yet, so the sanitizing survives unchanged if that call site ever changes.
`LC_ALL=C` is required for the strip: without it, `tr` can corrupt
multi-byte UTF-8 sequences (e.g. Turkish `ş`, `ğ`) under a UTF-8 locale,
whereas restricting the strip to the `0x00`-`0x1F` byte range is safe under
`LC_ALL=C` because every byte of a multi-byte UTF-8 sequence is `>= 0x80`.
