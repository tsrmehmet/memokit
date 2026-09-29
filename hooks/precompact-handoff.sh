#!/usr/bin/env bash
# PreCompact hook: steer the compaction summarizer.
# NOTE: PreCompact does NOT support hookSpecificOutput. Claude Code takes this
# script's raw stdout and hands it to the summarizer as its custom
# instructions, so the output must be plain text written for the summarizer.
set -u
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
PAYLOAD="$(cat)"
mk_resolve_root "$PAYLOAD"
mk_active || exit 0
mk_debug_dump "precompact-handoff" "$PAYLOAD"
mk_load_config || exit 0

mk_msg PC_SUMMARY
printf '\n'
exit 0
