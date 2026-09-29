RULES='[ABC-KURAL] 1) x. 2) y.'
matches() { printf '%s' "$prompt" | grep -qiE "$1"; }
  matches 'bug|hata|broken' \
    && HINTS="${HINTS} [SKILL] Hata avi -> superpowers:systematic-debugging: once hipotez."
  matches 'ui|screen' \
    && HINTS="${HINTS} [SKILL] FE -> x."
