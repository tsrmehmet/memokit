RULES='[XYZ-KURAL] 1) a.'
  matches 'quote|word' \
    && HINTS="${HINTS} [SKILL] uses \"quoted\" word -> x."
  if matches 'blockre'; then
    HINTS="${HINTS} [SKILL] block \"q\" -> graphify."
  fi
