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
  local stack status

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

  jq -n \
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
      files: { claudeMd: $claudeMd, state: $state, decisions: $decisions }
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
  if ! jq --indent 2 --arg schema "$SCHEMA_URL" '{"$schema": $schema} + .' "$json_file" > "$tmp" 2>/dev/null; then
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
}

# ---------------------------------------------------------------------------
# settings <root> [--drop-legacy-hooks]
# ---------------------------------------------------------------------------

cmd_settings() {
  local root="$1" drop=0 target tmp
  shift
  if [ "${1:-}" = "--drop-legacy-hooks" ]; then
    drop=1
  fi
  target="$root/.claude/settings.json"
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
      .extraKnownMarketplaces.memokit = {"source":{"source":"github","repo":"tsrmehmet/memokit"}}
      | .enabledPlugins["memokit@memokit"] = true
      | if has("hooks") then
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
# remove-legacy <root>
# ---------------------------------------------------------------------------

# Refuses (exit 4) only when a legacy path about to be removed or rewritten
# is dirty. The migration writes .claude/memokit.json, the overlays and
# CLAUDE.md BEFORE this step (skills/init/SKILL.md, Migration mode), so a
# whole-tree check would always refuse; the clean-tree precondition is
# checked once at the start of the migration instead.
cmd_remove_legacy() {
  local root="$1" status rel
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
      git -C "$root" rm -r -q -- "$rel"
      printf 'removed %s\n' "$rel"
    fi
  done
  cmd_settings "$root" --drop-legacy-hooks
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
  extract-legacy)
    shift
    cmd_extract_legacy "$@"
    ;;
  remove-legacy)
    shift
    cmd_remove_legacy "$@"
    ;;
  *)
    printf 'usage: memokit-init.sh {detect|write-config|scaffold|settings|extract-legacy|remove-legacy} <root> [args...]\n' >&2
    exit 2
    ;;
esac
