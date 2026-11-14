# SIGPIPE lint: a writer feeding an early-exit reader (grep -q/-m, head) must
# be silenced (2>/dev/null) or sit inside a closer ("} ) done") that is.
# Quotes are blanked (single quotes may span lines; $( inside double quotes
# stays code); lines ending in a lone "|" or "\" are joined.
# A quote or $( still open at the end of a file means the lint lost sync (an
# apostrophe in a heredoc body does it): the file is reported by name and the
# exit status is 1, never a silent pass.
# Portable: POSIX awk only (mawk, BSD awk, gawk).
function blank(s,   o, i, c) {
  o = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (sq) { if (c == "'") { sq = 0; o = o "Q" } ; continue }
    if (dq) {
      if (c == "\\") { i++; continue }
      if (c == "$" && substr(s, i + 1, 1) == "(") { stk[++sp] = depth; depth = 0; dq = 0; o = o "$("; i++; continue }
      if (c == "\"") { dq = 0; o = o "Q" }
      continue
    }
    if (c == "(") depth++
    if (c == ")") { if (depth == 0 && sp > 0) { depth = stk[sp--]; dq = 1; o = o ")"; continue } depth-- }
    if (c == "\\") { o = o substr(s, i, 2); i++; continue }
    if (c == "'") { sq = 1; continue }
    if (c == "\"") { dq = 1; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
    o = o c
  }
  return o
}
function reader(s) {
  return s ~ /^[ \t]*([A-Za-z_]+=[^ \t]*[ \t]+)*(grep([ \t]+-[A-Za-z]+)*[ \t]+-[A-Za-z]*[qm][A-Za-z0-9]*([ \t]|$)|head([ \t]|$))/
}
function quiet(w) { return w ~ /2>[ \t]*\/dev\/null/ }
function flush(   i, j, k, m, n, st, segs, w, ok) {
  if (buf == "") return
  gsub(/[|][|]/, " OR ", buf)
  gsub(/&&|;|\$\(|\(|\{|\)[ \t]*$/, "\n&", buf)
  m = split(buf, st, "\n")
  for (k = 1; k <= m; k++) {
    n = split(st[k], segs, "[|]")
    for (i = 2; i <= n; i++) {
      if (!reader(segs[i])) continue
      ok = 1
      for (j = i - 1; j >= 1; j--) {
        w = segs[j]
        if (w ~ /(\}|\)|done)[ \t]*2>[ \t]*\/dev\/null[ \t]*$/) break
        if (!quiet(w)) { ok = 0; break }
      }
      if (!ok) printf "%s:%d: %s\n", FILENAME, start, substr(st[k], 1, 150)
    }
  }
  buf = ""; nl = 0
}
function synced(f) {
  if (f != "" && (sq || dq || sp)) { printf "%s: unbalanced quote at end of file, the lint lost sync\n", f; bad = 1 }
}
FNR == 1 { flush(); synced(prev); prev = FILENAME; sq = 0; dq = 0; sp = 0; depth = 0 }
{
  line = blank($0)
  if (sq || dq) { if (buf != "") buf = buf " " line; else { start = FNR; buf = line }; nl++; next }
  if (buf == "") start = FNR
  buf = buf (buf == "" ? "" : " ") line; nl++
  if (line ~ /(^|[^|])[|][ \t]*$/ || line ~ /\\$/) { sub(/\\$/, "", buf); next }
  flush()
}
END { flush(); synced(prev); if (bad) exit 1 }
