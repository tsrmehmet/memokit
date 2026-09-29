RULES='[ABC-KURAL] 1) x.'
matches() { printf '%s' "$prompt" | grep -qiE "$1"; }
  if matches 'where|depends on|call graph'; then
    gate=""
    if [ -n "$gate" ]; then
      HINTS="${HINTS} [SKILL] Code question -> graphify. ${gate}"
    else
      HINTS="${HINTS} [SKILL] Code question -> graphify. Freshness: scripts/refresh.sh"
    fi
  fi
  matches 'schema|migration' \
    && HINTS="${HINTS} [SKILL] DB -> check the migration plan."
