#!/usr/bin/env bash
# memokit-init.sh: deterministic helper for the /memokit:init skill.
#
# Not a hook -- run directly by the skill's model instructions, one
# subcommand per invocation, root always $2. `set -eu` is used throughout
# (no PreToolUse-style fail-open contract applies here); bash 3.2
# compatibility (no `declare -A`, `${var,,}`, `mapfile`/`readarray`, `|&`,
# namerefs -- `${!var}` and `${var//a/b}` are fine) is still required
# because this script is shipped in the same plugin and must run under the
# same `/bin/bash` the hooks do.
#
# Dispatch is a `case` over $1 with one function per subcommand.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
CONFIG_JQ="$SCRIPT_DIR/../../../hooks/lib/config.jq"
SCHEMA_URL="https://raw.githubusercontent.com/tsrmehmet/memokit/main/schema/memokit.schema.json"

# ---------------------------------------------------------------------------
# detect <root>
# ---------------------------------------------------------------------------

# mk_stack_has FILES PATTERN... -- true if any basename in the newline-
# separated FILES list matches one of the given glob PATTERNs.
mk_stack_has() {
  local files="$1" line base pat
  shift
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    base="$(basename "$line")"
    for pat in "$@"; do
      # $pat is deliberately unquoted: it is a glob pattern (e.g. '*.sln',
      # 'build.gradle*') that must expand as one, not match literally.
      # shellcheck disable=SC2254
      case "$base" in
        $pat) return 0 ;;
      esac
    done
  done <<EOF
$files
EOF
  return 1
}

# mk_detect_stack ROOT -- space-separated stack ids found under ROOT
# (depth <= 3, ignoring node_modules/.git/bin/obj).
mk_detect_stack() {
  local root="$1" files result=""
  files="$(find "$root" -maxdepth 3 \
    \( -name node_modules -o -name .git -o -name bin -o -name obj \) -prune \
    -o -type f -print 2>/dev/null || true)"
  if mk_stack_has "$files" '*.sln' '*.csproj'; then result="$result dotnet"; fi
  if mk_stack_has "$files" 'package.json'; then result="$result node"; fi
  if mk_stack_has "$files" 'go.mod'; then result="$result go"; fi
  if mk_stack_has "$files" 'pyproject.toml' 'requirements.txt'; then result="$result python"; fi
  if mk_stack_has "$files" 'Cargo.toml'; then result="$result rust"; fi
  if mk_stack_has "$files" 'pom.xml' 'build.gradle*'; then result="$result jvm"; fi
  printf '%s' "$result"
}

cmd_detect() {
  local root="$1"
  local is_git=false is_clean=false is_legacy=false is_configured=false
  local has_claude_md=false has_state=false has_decisions=false
  local stack status inv ai_setup src_count inv_error=false inv_rc=0

  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    is_git=true
    status="$(git -C "$root" status --porcelain 2>/dev/null || true)"
    if [ -z "$status" ]; then
      is_clean=true
    fi
  fi
  if [ -d "$root/.claude/hooks" ]; then is_legacy=true; fi
  if [ -f "$root/.claude/memokit.json" ]; then is_configured=true; fi
  if [ -f "$root/CLAUDE.md" ]; then has_claude_md=true; fi
  if [ -f "$root/docs/STATE.md" ]; then has_state=true; fi
  if [ -f "$root/docs/DECISIONS.md" ]; then has_decisions=true; fi

  stack="$(mk_detect_stack "$root")"

  # Inventory runs in a subshell with errexit on, so a failure partway
  # through is seen as a non-zero status (not as partial JSON); any failure
  # degrades to "no AI setup found" with inventoryError:true.
  set +e
  inv="$(set -e; cmd_inventory "$root" 2>/dev/null)"
  inv_rc=$?
  set -e
  [ "$inv_rc" -eq 0 ] || inv_error=true
  ai_setup="$(printf '%s' "$inv" | jq -c '.adoptable == true' 2>/dev/null || true)"
  src_count="$(printf '%s' "$inv" | jq -c '[.sources[] | select(.group == "claude" or .group == "shared" or .group == "other")] | length' 2>/dev/null || true)"
  case "$ai_setup" in true|false) ;; *) ai_setup=false; inv_error=true ;; esac
  case "$src_count" in ''|*[!0-9]*) src_count=0 ;; esac

  jq -n \
    --argjson aiSetup "$ai_setup" \
    --argjson invError "$inv_error" \
    --argjson sources "$src_count" \
    --argjson git "$is_git" \
    --argjson clean "$is_clean" \
    --argjson legacy "$is_legacy" \
    --argjson configured "$is_configured" \
    --arg stack "$stack" \
    --argjson claudeMd "$has_claude_md" \
    --argjson state "$has_state" \
    --argjson decisions "$has_decisions" \
    '{
      git: $git, clean: $clean, legacy: $legacy, configured: $configured,
      stack: ($stack | split(" ") | map(select(length > 0))),
      files: { claudeMd: $claudeMd, state: $state, decisions: $decisions },
      aiSetup: $aiSetup, sources: $sources, inventoryError: $invError
    }'
}

# ---------------------------------------------------------------------------
# write-config <root> <json-file>
# ---------------------------------------------------------------------------

# mk_config_err SHELL_ASSIGNMENTS -- runs config.jq's shell-assignment output
# in a throwaway subshell and prints MK_CONFIG_ERR, without polluting this
# process's own environment (mirrors hooks/lib/common.sh's mk_load_config).
mk_config_err() {
  ( eval "$1"; printf '%s' "$MK_CONFIG_ERR" )
}

cmd_write_config() {
  local root="$1" json_file="$2" target tmp out err
  target="$root/.claude/memokit.json"

  if [ -f "$target" ]; then
    printf 'refused: %s already exists\n' "$target" >&2
    exit 3
  fi
  if [ ! -f "$json_file" ]; then
    printf 'error: %s not found\n' "$json_file" >&2
    exit 2
  fi

  out=""
  if ! out="$(jq -r -f "$CONFIG_JQ" "$json_file" 2>/dev/null)" || [ -z "$out" ]; then
    printf 'refused: invalid config (not valid JSON)\n' >&2
    exit 1
  fi
  err="$(mk_config_err "$out")"
  if [ -n "$err" ]; then
    printf 'refused: invalid config (%s)\n' "$err" >&2
    exit 1
  fi

  mkdir -p "$root/.claude"
  tmp="$(mktemp "${TMPDIR:-/tmp}/memokit-init.XXXXXX")"
  if ! jq --indent 2 --arg schema "$SCHEMA_URL" '{"$schema": $schema} + . + (if has("careful") then {} else {careful: {patterns: []}} end)' "$json_file" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    printf 'error: failed to render config\n' >&2
    exit 1
  fi
  mv "$tmp" "$target"
  printf 'wrote %s\n' "$target"
}

# ---------------------------------------------------------------------------
# scaffold <root> <lang>
# ---------------------------------------------------------------------------

# mk_sed_escape_repl VALUE -- escapes VALUE for safe use as the replacement
# side of a `sed 's|X|VALUE|'` substitution (backslash and `&`), and refuses
# (nonzero exit, nothing printed) a VALUE containing the `|` delimiter or a
# newline, either of which would break a single-line sed script.
mk_sed_escape_repl() {
  local v="$1"
  case "$v" in
    *'|'*)
      printf 'error: value contains "|", cannot substitute safely\n' >&2
      return 1
      ;;
  esac
  case "$v" in
    *$'\n'*)
      printf 'error: value contains a newline, cannot substitute safely\n' >&2
      return 1
      ;;
  esac
  v="${v//\\/\\\\}"
  v="${v//&/\\&}"
  printf '%s' "$v"
}

# mk_render_template SRC NAME_ESCAPED LANG -- prints SRC with {{NAME}} and
# {{LANG}} substituted. NAME_ESCAPED must already be sed-replacement-safe
# (see mk_sed_escape_repl); LANG is always "tr"/"en", never escaped.
mk_render_template() {
  local src="$1" name_esc="$2" lang="$3"
  sed -e "s|{{NAME}}|$name_esc|g" -e "s|{{LANG}}|$lang|g" "$src"
}

# mk_scaffold_one SRC ROOT REL NAME_ESC LANG -- copies SRC to ROOT/REL only
# if ROOT/REL does not already exist; prints "created REL" / "kept REL".
mk_scaffold_one() {
  local src="$1" root="$2" rel="$3" name_esc="$4" lang="$5" dst
  dst="$root/$rel"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    printf 'kept %s\n' "$rel"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  mk_render_template "$src" "$name_esc" "$lang" > "$dst"
  printf 'created %s\n' "$rel"
}

cmd_scaffold() {
  local root="$1" lang="$2" name name_esc

  case "$lang" in
    tr|en) : ;;
    *) printf 'error: lang must be "tr" or "en"\n' >&2; exit 2 ;;
  esac

  # The project name comes from the just-written .claude/memokit.json (the
  # skill runs write-config before scaffold). Missing config -> empty name,
  # which substitutes cleanly to "# " and is still safe.
  name=""
  if [ -f "$root/.claude/memokit.json" ]; then
    name="$(jq -r '.project.name // empty' "$root/.claude/memokit.json" 2>/dev/null)" || name=""
  fi
  name_esc="$(mk_sed_escape_repl "$name")" || exit 1

  mk_scaffold_one "$TEMPLATES_DIR/CLAUDE.md" "$root" "CLAUDE.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/STATE.$lang.md" "$root" "docs/STATE.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/DECISIONS.md" "$root" "docs/DECISIONS.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/rules.md" "$root" ".claude/memokit/rules.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/coder.md" "$root" ".claude/memokit/coder.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/reviewer.md" "$root" ".claude/memokit/reviewer.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/analyst.md" "$root" ".claude/memokit/analyst.md" "$name_esc" "$lang"
  mk_scaffold_one "$TEMPLATES_DIR/gates.md" "$root" ".claude/memokit/gates.md" "$name_esc" "$lang"
}

# ---------------------------------------------------------------------------
# settings <root> [--drop-legacy-hooks | --drop-hook <event> <substring>...]
# Without flags: register the marketplace and enable the plugin in the
# project's shared settings.json (only when the user wants the team on
# memokit). The drop forms only remove hooks; they never register.
# ---------------------------------------------------------------------------

cmd_settings() {
  local root="$1" drop=0 target tmp pairs="[]" ev sub n before after
  shift
  if [ "${1:-}" = "--drop-legacy-hooks" ]; then
    [ "$#" -eq 1 ] || { printf 'settings: --drop-legacy-hooks takes no other arguments\n' >&2; return 2; }
    drop=1
  elif [ "${1:-}" = "--drop-hook" ]; then
    case " $* " in *" --drop-legacy-hooks "*) printf 'settings: --drop-hook cannot be combined with --drop-legacy-hooks\n' >&2; return 2 ;; esac
    target="$root/.claude/settings.json"
    while [ "$#" -gt 0 ]; do
      if [ "$1" != "--drop-hook" ] || [ "$#" -lt 3 ]; then
        printf 'settings: --drop-hook needs <event> <command-substring>\n' >&2; return 2
      fi
      ev="$2"; sub="$3"; shift 3
      if [ -z "$ev" ] || [ -z "$sub" ]; then
        printf 'settings: --drop-hook needs a non-empty <event> and <command-substring>\n' >&2; return 2
      fi
      [ -f "$target" ] || { printf 'settings: --drop-hook %s %s matched nothing\n' "$ev" "$sub" >&2; return 3; }
      n="$(jq --arg e "$ev" --arg s "$sub" '[(.hooks[$e] // [])[]?.hooks[]? | select(.command? | type == "string" and contains($s))] | length' "$target")"
      if [ "$n" -eq 0 ]; then
        printf 'settings: --drop-hook %s %s matched nothing\n' "$ev" "$sub" >&2; return 3
      fi
      pairs="$(printf '%s' "$pairs" | jq -c --arg e "$ev" --arg s "$sub" '. + [[$e,$s]]')"
    done
    before="$(jq '[.hooks[]?[]?.hooks[]?] | length' "$target")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/memokit-settings.XXXXXX")"
    if ! jq --argjson pairs "$pairs" '
      reduce $pairs[] as $p (.;
          if (.hooks[$p[0]] // null) != null then
            .hooks[$p[0]] |= map(.hooks = ((.hooks // []) | map(select((.command? | type == "string" and contains($p[1])) | not))))
          else . end)
      | .hooks |= (with_entries(.value |= map(select((.hooks | length) > 0))) | with_entries(select((.value | length) > 0)))
      | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
    ' "$target" > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
    after="$(jq '[.hooks[]?[]?.hooks[]?] | length' "$tmp")"
    mv "$tmp" "$target"
    printf 'dropped %s hook entries\n' "$((before - after))"
    printf 'wrote %s\n' "$target"
    return 0
  fi
  target="$root/.claude/settings.json"
  if [ "$drop" -eq 1 ] && [ ! -f "$target" ]; then
    printf 'settings: no %s, nothing to drop\n' "$target"
    return 0
  fi
  mkdir -p "$root/.claude"
  if [ ! -f "$target" ]; then
    printf '{}' > "$target"
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/memokit-settings.XXXXXX")"
  if [ "$drop" -eq 1 ]; then
    # Remove every hook entry whose command contains ".claude/hooks/", then
    # drop matcher groups left with an empty "hooks" array, then drop event
    # keys left with an empty array, then drop "hooks" itself if it ends up
    # an empty object. Every other top-level key is untouched.
    jq '
      if has("hooks") then
          .hooks |= (
            with_entries(
              .value = (.value
                | map(.hooks = (.hooks | map(select((.command // "") | contains(".claude/hooks/") | not))))
                | map(select((.hooks | length) > 0))
              )
            )
            | with_entries(select((.value | length) > 0))
          )
          | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
        else . end
    ' "$target" > "$tmp"
  else
    jq '
      .extraKnownMarketplaces.memokit = {"source":{"source":"github","repo":"tsrmehmet/memokit"}}
      | .enabledPlugins["memokit@memokit"] = true
    ' "$target" > "$tmp"
  fi
  mv "$tmp" "$target"
  printf 'wrote %s\n' "$target"
}

# ---------------------------------------------------------------------------
# deny-tools <root> <tool>...
# ---------------------------------------------------------------------------

# Adds bare tool names (e.g. Artifact) to permissions.deny in the git-ignored
# .claude/settings.local.json: a bare name takes the tool's definition out of
# the session context. Keeps every other key, never duplicates a rule, and
# makes sure git ignores the file. Exit 2 on a name that is not a bare tool
# name (nothing written).
cmd_deny_tools() {
  local root="${1:-}" target tmp t
  if [ -z "$root" ] || [ ! -d "$root" ]; then printf 'deny-tools: no project root given\n' >&2; return 2; fi
  shift
  [ "$#" -gt 0 ] || { printf 'deny-tools: no tool name given\n' >&2; return 2; }
  for t in "$@"; do
    case "$t" in ''|[!A-Za-z]*|*[!A-Za-z0-9_]*) printf 'deny-tools: not a bare tool name: %s\n' "$t" >&2; return 2 ;; esac
  done
  target="$root/.claude/settings.local.json"
  mkdir -p "$root/.claude"
  [ -f "$target" ] || printf '{}' > "$target"
  tmp="$(mktemp "${TMPDIR:-/tmp}/memokit-settings.XXXXXX")"
  if ! jq --args '.permissions.deny = (((.permissions.deny // []) + $ARGS.positional) | unique)' "$@" < "$target" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  mv "$tmp" "$target"
  printf 'wrote %s\n' "$target"
  if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$root" ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
      # Tracked: an ignore line would not apply; leave that to the user.
      printf 'tracked .claude/settings.local.json (not ignored; untrack it with git rm --cached to keep it local)\n'
    elif ! git -C "$root" check-ignore -q .claude/settings.local.json; then
      printf '\n.claude/settings.local.json\n' >> "$root/.gitignore"
      printf 'ignored .claude/settings.local.json\n'
    fi
  fi
}

# ---------------------------------------------------------------------------
# extract-legacy <root>
# ---------------------------------------------------------------------------

# mk_legacy_hints FILE -- prints one "<regex><TAB><text>" line per legacy
# hint found in a legacy inject-rules.sh. Two forms are recognised:
#   matches '<re>' && HINTS="${HINTS} <text>"     (backslash continuations joined)
#   if matches '<re>'; then ... HINTS="${HINTS} <text>" ... fi   (if-block style;
#   the first HINTS assignment inside the block supplies the text)
mk_legacy_hints() {
  awk '
    function hint_text(line,   t, i, c) {
      if (index(line, "HINTS=\"${HINTS} ") == 0) return ""
      line = substr(line, index(line, "HINTS=\"${HINTS} ") + length("HINTS=\"${HINTS} "))
      t = ""
      # Cut at the first unescaped double quote; unescape \" to ".
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "\\" && substr(line, i + 1, 1) == "\"") { t = t "\""; i++; continue }
        if (c == "\"") break
        t = t c
      }
      return t
    }
    function regex_of(line,   r) {
      r = substr(line, index(line, "matches '\''") + length("matches '\''"))
      sub(/'\''.*$/, "", r)
      return r
    }
    { cur = $0
      while (cur ~ /\\[ \t]*$/ && (getline nxt) > 0) {
        sub(/\\[ \t]*$/, " ", cur); sub(/^[ \t]+/, "", nxt); cur = cur nxt
      }
      if (cur ~ /^[ \t]*(el)?if matches '\''[^'\'']*'\''[ \t]*;[ \t]*then/) {
        pending = regex_of(cur); next
      }
      if (cur ~ /matches '\''[^'\'']*'\''[ \t]*&&[ \t]*HINTS="\$\{HINTS\} /) {
        t = hint_text(cur)
        if (t != "") printf "%s\t%s\n", regex_of(cur), t
        pending = ""; next
      }
      if (pending != "" && cur ~ /HINTS="\$\{HINTS\} /) {
        t = hint_text(cur)
        if (t != "") printf "%s\t%s\n", pending, t
        pending = ""
      }
    }' "$1"
}

# mk_legacy_rules FILE -- value of the first single-quoted RULES='...' assignment,
# possibly spanning lines. The value ends at the first closing quote that is
# not part of a shell-escaped '\'' sequence; each '\'' is rewritten to '.
mk_legacy_rules() {
  local q="'"
  awk -v q="$q" '
    BEGIN { inside = 0; done = 0; out = ""; esc = q "\\" q q; start = "RULES=" q }
    done { next }
    {
      line = $0
      if (!inside) {
        sub(/^[ \t]+/, "", line)
        if (substr(line, 1, length(start)) != start) next
        line = substr(line, length(start) + 1)
        inside = 1
      } else {
        out = out "\n"
      }
      n = length(line)
      for (i = 1; i <= n; i++) {
        if (substr(line, i, 4) == esc) { out = out q; i += 3; continue }
        if (substr(line, i, 1) == q) { done = 1; break }
        out = out substr(line, i, 1)
      }
    }
    END { if (done) printf "%s", out }' "$1"
}

# mk_first_sed FILE SED_EXPR -- first line produced by `sed -n -E EXPR` (empty if none).
mk_first_sed() {
  sed -n -E "$2" "$1" 2>/dev/null | head -n 1
}

# mk_list_json -- reads names on stdin (one per line), prints a JSON string array.
mk_list_json() {
  jq -R -s 'split("\n") | map(select(length > 0))'
}

cmd_extract_legacy() {
  local root="$1" hooks tag="" name="" gdirs="" docs="" health="null" rules=""
  local limit="" maxc="" hints_tsv="" agents="" skills="" vendored="" d n

  hooks="$root/.claude/hooks"

  if [ -f "$hooks/inject-rules.sh" ]; then
    tag="$(grep -o -E '\[[A-Z][A-Z0-9]{1,9}-KURAL\]' "$hooks/inject-rules.sh" | head -n 1 | sed -E 's/^\[(.*)-KURAL\]$/\1/' || true)"
    rules="$(mk_legacy_rules "$hooks/inject-rules.sh")"
    hints_tsv="$(mk_legacy_hints "$hooks/inject-rules.sh")"
  fi
  if [ -f "$hooks/session-start.sh" ]; then
    name="$(mk_first_sed "$hooks/session-start.sh" 's/^.*ctx="\[(.*) — oturum açılışı\].*$/\1/p')"
    docs="$(mk_first_sed "$hooks/session-start.sh" 's/^.*ctx=".*Kurallar: ([^"]*)".*$/\1/p')"
  fi
  if [ -f "$hooks/guard-edit.sh" ]; then
    # The patterns below match a literal `$ROOT_LOWER` in legacy source text.
    # shellcheck disable=SC2016
    gdirs="$(grep 'LEXICAL_MATCH=1 ;;' "$hooks/guard-edit.sh" | head -n 1 \
      | grep -o -E '"\$ROOT_LOWER/[^"*]+"' | sed -E 's/^"\$ROOT_LOWER\/(.*)"$/\1/' | awk '!seen[$0]++' || true)"
  fi
  if [ -f "$hooks/check-context-budget.sh" ]; then
    limit="$(mk_first_sed "$hooks/check-context-budget.sh" 's/^[[:space:]]*DEFAULT_LIMIT=([0-9]+).*$/\1/p')"
    if [ "$limit" = "300000" ]; then limit=""; fi
  fi
  if [ -f "$hooks/check-state-stale.sh" ]; then
    maxc="$(mk_first_sed "$hooks/check-state-stale.sh" 's/^[[:space:]]*MAX_SRC_COMMITS_BEHIND=([0-9]+).*$/\1/p')"
    if [ "$maxc" = "3" ]; then maxc=""; fi
  fi
  if [ -f "$root/scripts/knowledge-health.sh" ] && [ -x "$root/scripts/knowledge-health.sh" ]; then
    health='"scripts/knowledge-health.sh"'
  fi

  if [ -d "$root/.claude/agents" ]; then
    agents="$(if cd "$root/.claude/agents"; then find . -type f 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort || true; fi)"
  fi
  if [ -d "$root/.claude/skills" ]; then
    for d in "$root"/.claude/skills/*/; do
      [ -d "$d" ] || continue
      n="$(basename "$d")"
      skills="$skills$n
"
      if [ -d "$HOME/.claude/skills/$n" ] && diff -rq "$d" "$HOME/.claude/skills/$n/" >/dev/null 2>&1; then
        vendored="$vendored$n
"
      fi
    done
  fi

  jq -n \
    --arg tag "$tag" --arg name "$name" \
    --argjson guarded "$(printf '%s\n' "$gdirs" | mk_list_json)" \
    --arg docs "$docs" --argjson health "$health" --arg rules "$rules" \
    --arg limit "$limit" --arg maxc "$maxc" \
    --argjson agents "$(printf '%s\n' "$agents" | mk_list_json)" \
    --argjson skills "$(printf '%s' "$skills" | mk_list_json)" \
    --argjson vendored "$(printf '%s' "$vendored" | mk_list_json)" \
    --argjson hints "$(printf '%s\n' "$hints_tsv" | jq -R -s '
      def markers: [["systematic-debugging","debugging"],["llm-council","decision"],["code-review","review"],["graphify","graphify"],["Handoff","handoff"],["devam et","resume"]];
      split("\n") | map(select(length > 0) | split("\t") | {match: .[0], text: (.[1:] | join("\t"))})
      | map(. as $h | .covered = ([markers[] | select(. as $m | $h.text | contains($m[0]))] | length > 0))')" \
    '{
      tag: (if $tag == "" then null else $tag end),
      name: (if $name == "" then null else $name end),
      guardedDirs: $guarded,
      docsRaw: (if $docs == "" then null else $docs end),
      healthScript: $health,
      rulesRaw: (if $rules == "" then null else $rules end),
      hints: $hints,
      builtinCovered: (
        def markers: [["systematic-debugging","debugging"],["llm-council","decision"],["code-review","review"],["graphify","graphify"],["Handoff","handoff"],["devam et","resume"]];
        [ $hints[] | select(.covered) | .text as $t | markers[] | select(. as $m | $t | contains($m[0])) | .[1] ] | unique
      ),
      contextLimit: (if $limit == "" then null else ($limit | tonumber) end),
      maxCommitsBehind: (if $maxc == "" then null else ($maxc | tonumber) end),
      agents: $agents, skills: $skills, vendoredSkills: $vendored
    }'
}

# ---------------------------------------------------------------------------
# remove <root> <path>... and remove-legacy <root>
# ---------------------------------------------------------------------------

# mk_git_rm_paths ROOT PATH... -- stages the removal of all paths in ONE
# git call (git checks every pathspec before touching anything, so overlapping
# or duplicate paths cannot leave a partial result), never commits, and prints
# "removed <path>" per path. Pathspecs are literal (no globbing).
mk_git_rm_paths() {
  local root="$1" rel
  shift
  git --literal-pathspecs -C "$root" rm -r -q -- "$@"
  for rel in "$@"; do
    printf 'removed %s\n' "$rel"
  done
}

# Validates every path before removing any: exit 2 for a bad root, no path,
# an absolute or ".." path, or a missing path; exit 4 for a path with no
# tracked files or with uncommitted changes. Stages removals, never commits.
cmd_remove() {
  local root="${1:-}" p q status
  if [ -z "$root" ] || [ ! -d "$root" ]; then printf 'remove: no project root given\n' >&2; exit 2; fi
  shift
  [ "$#" -gt 0 ] || { printf 'remove: no path given\n' >&2; exit 2; }
  for p in "$@"; do
    q="$p"
    while [ "${q%/}" != "$q" ]; do q="${q%/}"; done
    case "$p" in
      ''|/*|..|../*|*/..|*/../*) printf 'remove: path must be relative and inside the project: %s\n' "$p" >&2; exit 2 ;;
    esac
    case "$q" in
      ''|.|*/.) printf 'remove: path must name something inside the project, not the root: %s\n' "$p" >&2; exit 2 ;;
    esac
    if [ ! -e "$root/$p" ] && [ ! -L "$root/$p" ]; then
      printf 'remove: no such path: %s\n' "$p" >&2; exit 2
    fi
  done
  for p in "$@"; do
    if [ -z "$(git --literal-pathspecs -C "$root" ls-files -- "$p" 2>/dev/null)" ]; then
      printf 'refused: no tracked files under %s\n' "$p" >&2; exit 4
    fi
    if ! status="$(git --literal-pathspecs -C "$root" status --porcelain -- "$p" 2>/dev/null)"; then
      printf 'refused: git status failed for %s\n' "$p" >&2; exit 4
    fi
    if [ -n "$status" ]; then
      printf 'refused: %s has uncommitted changes\n' "$p" >&2
      printf '%s\n' "$status" >&2
      exit 4
    fi
  done
  mk_git_rm_paths "$root" "$@"
}

# Refuses (exit 4) only when a legacy path about to be removed or rewritten
# is dirty. The migration writes .claude/memokit.json, the overlays and
# CLAUDE.md BEFORE this step (skills/init/SKILL.md, Migration mode), so a
# whole-tree check would always refuse; the clean-tree precondition is
# checked once at the start of the migration instead.
cmd_remove_legacy() {
  local root="$1" status rel existing=()
  if ! status="$(git -C "$root" status --porcelain -- \
      .claude/hooks .claude/agents .claude/skills .claude/settings.json 2>/dev/null)"; then
    printf 'refused: git status failed in %s\n' "$root" >&2
    exit 4
  fi
  if [ -n "$status" ]; then
    printf 'refused: legacy paths have uncommitted changes (.claude/hooks, .claude/agents, .claude/skills, .claude/settings.json)\n' >&2
    printf '%s\n' "$status" >&2
    exit 4
  fi
  for rel in .claude/hooks .claude/agents/coder.md .claude/agents/reviewer.md \
             .claude/skills/handoff .claude/skills/resume; do
    if [ -e "$root/$rel" ]; then
      existing+=("$rel")
    fi
  done
  if [ "${#existing[@]}" -gt 0 ]; then
    mk_git_rm_paths "$root" "${existing[@]}"
  fi
  cmd_settings "$root" --drop-legacy-hooks
}

# ---------------------------------------------------------------------------
# inventory <root>
# ---------------------------------------------------------------------------
# Read-only: lists the repo's existing AI-assistant setup files as one JSON
# object. hooks/settingsError/legacy are placeholders here (filled later).

# mk_inv_classify REL KIND -- prints "group tool" for a recognised path
# (KIND is file|dir); returns 1 when the path is not a source.
mk_inv_classify() {
  local rel="$1" kind="$2" rest
  if [ "$kind" = dir ]; then
    case "$rel" in
      .claude/hooks) echo "claude claude-code" ;;
      docs/superpowers) echo "framework superpowers" ;;
      .specify) echo "framework spec-kit" ;;
      _bmad|_bmad-output|.bmad-core) echo "framework bmad" ;;
      .taskmaster) echo "framework taskmaster" ;;
      openspec) echo "framework openspec" ;;
      .planning) echo "framework gsd" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  # `*` in a case pattern also matches `/`: reject too-deep paths for the
  # single-level locations.
  case "$rel" in
    */CLAUDE.md|*/CLAUDE.local.md|*/AGENTS.md|*/GEMINI.md) ;; # match at any depth
    .windsurf/rules/*/*|.devin/rules/*/*|.kiro/steering/*/*|.continue/rules/*/*|.cline/rules/*/*) return 1 ;;
    .clinerules/*/*|.github/agents/*/*|.github/prompts/*/*|.claude/output-styles/*/*) return 1 ;;
  esac
  case "$rel" in
    CLAUDE.local.md|*/CLAUDE.local.md|.claude/settings.local.json) echo "personal claude-code" ;;
    .junie/AGENTS.md) echo "other junie" ;;
    AGENTS.md|*/AGENTS.md) echo "shared agents-md" ;;
    CLAUDE.md|*/CLAUDE.md) echo "claude claude-code" ;;
    .claude/rules/*.md|.claude/agents/*.md|.claude/commands/*.md) echo "claude claude-code" ;;
    .claude/skills/*/SKILL.md)
      rest="${rel#.claude/skills/}"
      case "${rest%/SKILL.md}" in */*) return 1 ;; esac
      echo "claude claude-code" ;;
    .claude/output-styles/*.md) echo "aux claude-code" ;;
    .mcp.json) echo "aux mcp" ;;
    .cursorrules|.cursor/rules/*.mdc) echo "other cursor" ;;
    .github/copilot-instructions.md|.github/instructions/*.instructions.md) echo "other copilot" ;;
    .github/agents/*.agent.md|.github/prompts/*.prompt.md) echo "other copilot" ;;
    .windsurfrules|.windsurf/rules/*.md) echo "other windsurf" ;;
    .devin/rules/*.md) echo "other devin" ;;
    .clinerules|.clinerules/*.md|.cline/rules/*.md) echo "other cline" ;;
    .roo/rules*/*.md|.roorules*|.roomodes) echo "other roo" ;;
    GEMINI.md|*/GEMINI.md) echo "other gemini" ;;
    AGENTS.override.md) echo "other codex" ;;
    .kiro/steering/*.md) echo "other kiro" ;;
    .continue/rules/*.md) echo "other continue" ;;
    .junie/guidelines.md) echo "other junie" ;;
    .rules) echo "other zed" ;;
    CONVENTIONS.md|.aider.conf.yml) echo "other aider" ;;
    *) return 1 ;;
  esac
}

# mk_inv_classify_dirlink REL -- like mk_inv_classify, for a symlink to a
# directory sitting at a rule/skill location. Links are never followed.
mk_inv_classify_dirlink() {
  case "$1" in
    .claude/skills/*/*) return 1 ;;
    .claude/skills|.claude/skills/*|.claude/rules|.claude/rules/*|.claude/agents|.claude/agents/*) echo "claude claude-code" ;;
    .claude/commands|.claude/commands/*) echo "claude claude-code" ;;
    .claude/output-styles) echo "aux claude-code" ;;
    .cursor/rules|.cursor/rules/*) echo "other cursor" ;;
    .github/instructions|.github/instructions/*|.github/agents|.github/prompts) echo "other copilot" ;;
    .windsurf/rules) echo "other windsurf" ;;
    .devin/rules) echo "other devin" ;;
    .clinerules|.cline/rules) echo "other cline" ;;
    .roo/rules*) echo "other roo" ;;
    .kiro/steering) echo "other kiro" ;;
    .continue/rules) echo "other continue" ;;
    *) return 1 ;;
  esac
}

# mk_inv_frontmatter FILE -- prints "key<TAB>value" lines for the whitelisted
# keys of a leading `---` block. Prints nothing when the block never closes.
mk_inv_frontmatter() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unq(s) {
      if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; open = 1; next }
    open && $0 == "---" { closed = 1; exit }
    open {
      if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*:/) {
        i = index($0, ":"); cur = substr($0, 1, i - 1)
        if (!(cur in val)) order[++n] = cur
        val[cur] = unq(trim(substr($0, i + 1)))
      } else if (cur != "" && $0 ~ /^[ \t]+-([ \t]|$)/) {
        item = $0; sub(/^[ \t]+-[ \t]*/, "", item); item = unq(trim(item))
        val[cur] = (val[cur] == "" ? item : val[cur] "," item)
      }
    }
    END {
      if (!closed) exit
      for (k = 1; k <= n; k++) {
        key = order[k]
        if (key ~ /^(name|description|globs|alwaysApply|applyTo|paths|trigger|inclusion|fileMatchPattern)$/)
          printf "%s\t%s\n", key, val[key]
      }
    }
  ' "$1"
}

cmd_inventory() {
  local root="${1:-}" rel kind gt group tool bytes link tracked ignored fm in_git=false entries=""
  if [ -z "$root" ] || [ ! -d "$root" ]; then printf 'inventory: not a directory: %s\n' "$root" >&2; return 2; fi
  # Only candidates reach the shell loop: the nested basenames anywhere, the
  # rest at specific root locations (cost must not grow with repo size).
  local cand=(-name CLAUDE.md -o -name CLAUDE.local.md -o -name AGENTS.md -o -name GEMINI.md)
  local c
  for c in .claude .cursor .github .windsurf .devin .cline .roo .kiro .continue .junie; do
    cand+=(-o -path "./$c" -o -path "./$c/*")
  done
  for c in .cursorrules .windsurfrules .clinerules '.roorules*' .roomodes .rules .aider.conf.yml .mcp.json \
      CONVENTIONS.md AGENTS.override.md .specify .bmad-core .taskmaster .planning _bmad _bmad-output openspec \
      docs/superpowers; do
    cand+=(-o -path "./$c")
  done
  cand+=(-o -path './.clinerules/*')
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=true
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    kind="file"
    [ -d "$root/$rel" ] && kind="dir"
    if ! gt="$(mk_inv_classify "$rel" "$kind")"; then
      if [ ! -L "$root/$rel" ] || [ "$kind" != dir ]; then continue; fi
      gt="$(mk_inv_classify_dirlink "$rel")" || continue
    fi
    group="${gt%% *}"; tool="${gt#* }"
    bytes=null
    if [ "$kind" = file ] && [ -f "$root/$rel" ]; then
      bytes="$(wc -c < "$root/$rel" | tr -d ' ')"
    fi
    link=""
    [ -L "$root/$rel" ] && link="$(readlink "$root/$rel")"
    tracked=false; ignored=false
    if [ "$in_git" = true ]; then
      git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 && tracked=true
      git -C "$root" check-ignore -q -- "$rel" >/dev/null 2>&1 && ignored=true
    fi
    fm='{}'
    case "$rel" in
      *.md|*.mdc)
        if [ -f "$root/$rel" ]; then
          fm="$(mk_inv_frontmatter "$root/$rel" | jq -Rn '[inputs | capture("^(?<k>[^\t]*)\t(?<v>.*)$") | {(.k): .v}] | add // {}')"
        fi ;;
    esac
    entries="$entries$(jq -nc --arg path "$rel" --arg group "$group" --arg tool "$tool" --arg kind "$kind" \
      --argjson bytes "$bytes" --argjson tracked "$tracked" --argjson ignored "$ignored" \
      --arg link "$link" --arg islink "$([ -L "$root/$rel" ] && echo 1 || echo 0)" --argjson fm "$fm" \
      '{path:$path,group:$group,tool:$tool,kind:$kind,bytes:$bytes,tracked:$tracked,ignored:$ignored,
        linkTarget:(if $islink == "1" then $link else null end),frontmatter:$fm}')
"
  done < <(cd "$root" && find . -mindepth 1 \( -name .git -o -name node_modules -o -name vendor -o -name dist \
      -o -name build -o -name bin -o -name obj -o -name target -o -name .venv -o -name .worktrees \
      -o -name worktrees -o -path ./.claude/worktrees \) -prune -o \( "${cand[@]}" \) -print0)
  local stracked=false signored=false settings_f="$root/.claude/settings.json"
  if [ "$in_git" = true ] && [ -e "$settings_f" ]; then
    git -C "$root" ls-files --error-unmatch -- .claude/settings.json >/dev/null 2>&1 && stracked=true
    git -C "$root" check-ignore -q -- .claude/settings.json >/dev/null 2>&1 && signored=true
  fi
  local hooks_json='[]' serr=false legacy_json=null settings="$root/.claude/settings.json" base="${root%/}" rootp
  # Only a real memokit legacy setup counts: .claude/hooks/ alone is where a
  # project keeps its own hooks. extract-legacy may `exit`: contain it.
  if [ -d "$root/.claude/hooks" ]; then
    legacy_json="$( (cmd_extract_legacy "$root") 2>/dev/null)" || legacy_json=null
    [ -n "$legacy_json" ] || legacy_json=null
    printf '%s' "$legacy_json" | jq -e '.tag != null' >/dev/null 2>&1 || legacy_json=null
  fi
  if [ -f "$settings" ]; then
    if jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
      local raw cand existing_json='[]' c d
      rootp="$(CDPATH='' cd -- "$root" && pwd -P)" || rootp="$base"
      # One pass: every command hook plus the repo-relative path of its first
      # word (candidate). $CLAUDE_PROJECT_DIR is a literal string in
      # settings.json, so it is resolved textually.
      raw="$(jq -c --arg root "$base" '[(.hooks // {}) | if type == "object" then . else {} end | to_entries[] | .key as $e
        | (.value // []) | if type == "array" then .[] else empty end
        | select(type == "object") | (.matcher // null) as $m | (.hooks // []) | if type == "array" then .[] else empty end
        | select(type == "object") | {event: $e, matcher: $m, type: (.type // null), command: (if (.command | type) == "string" then .command else null end)}
        | . as $h
        | (($h.command // "" | capture("^\\s*(?:\"(?<a>[^\"]*)\"|'"'"'(?<b>[^'"'"']*)'"'"'|(?<c>[^\\s\"'"'"']+))(?<t>\\S*)") // {a: ""})
            | ((.a // .b // .c // "") + (.t // "") | gsub("[\"'"'"']"; ""))) as $w
        | (if ($w | startswith("${CLAUDE_PROJECT_DIR}/")) then $root + "/" + ($w | ltrimstr("${CLAUDE_PROJECT_DIR}/"))
           elif ($w | startswith("$CLAUDE_PROJECT_DIR/")) then $root + "/" + ($w | ltrimstr("$CLAUDE_PROJECT_DIR/"))
           elif ($w | startswith("/")) then $w
           else $root + "/" + ($w | sub("^(\\./)+"; "")) end) as $abs
        | ($abs | ltrimstr($root + "/")) as $rel
        | $h + {cand: (if $h.command != null and ($abs | startswith($root + "/")) and $rel != "" and ($rel | test("(^|/)\\.\\.(/|$)") | not)
                           and ($rel | test("[\\t\\n]") | not) then $rel else null end)}]' "$settings")"
      while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        c="$root/$cand"
        if [ ! -f "$c" ] || [ -L "$c" ]; then continue; fi
        d="$(CDPATH='' cd -- "$(dirname -- "$c")" 2>/dev/null && pwd -P)" || continue
        case "$d/" in "$rootp"/*) ;; *) continue ;; esac
        existing_json="$(printf '%s' "$existing_json" | jq -c --arg c "$cand" '. + [$c]')"
      done <<EOF
$(printf '%s' "$raw" | jq -r '[.[].cand | select(. != null)] | unique | .[]')
EOF
      hooks_json="$(printf '%s' "$raw" | jq -c --argjson ex "$existing_json" --argjson leg "$([ "$legacy_json" = null ] && echo false || echo true)" \
        '[.[] | .cand as $k | . + {legacy: ($leg and .command != null and (.command | contains(".claude/hooks/"))),
                scriptPath: (if .cand != null and ($ex | index($k)) != null then $k else null end),
                injectsContext: (.event == "SessionStart" or .event == "UserPromptSubmit")} | del(.cand)]')"
    else
      serr=true
    fi
  fi
  printf '%s' "$entries" | jq -s --argjson hooks "$hooks_json" --argjson serr "$serr" --argjson legacy "$legacy_json" \
    --argjson st "$stracked" --argjson si "$signored" \
    '{sources: (sort_by(.path)), hooks: $hooks, settingsError: $serr, settingsTracked: $st, settingsIgnored: $si, legacy: $legacy,
      adoptable: (any(.[]; .group == "claude" or .group == "shared" or .group == "other")
        or any($hooks[]; .legacy == false) or $legacy != null)}'
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  detect)
    shift
    cmd_detect "$@"
    ;;
  write-config)
    shift
    cmd_write_config "$@"
    ;;
  scaffold)
    shift
    cmd_scaffold "$@"
    ;;
  settings)
    shift
    cmd_settings "$@"
    ;;
  deny-tools)
    shift
    cmd_deny_tools "$@"
    ;;
  extract-legacy)
    shift
    cmd_extract_legacy "$@"
    ;;
  remove)
    shift
    cmd_remove "$@"
    ;;
  remove-legacy)
    shift
    cmd_remove_legacy "$@"
    ;;
  inventory)
    shift
    cmd_inventory "$@"
    ;;
  *)
    printf 'usage: memokit-init.sh {detect|write-config|scaffold|settings|deny-tools|extract-legacy|remove|remove-legacy|inventory} <root> [args...]\n' >&2
    exit 2
    ;;
esac
