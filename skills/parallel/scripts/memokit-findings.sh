#!/usr/bin/env bash
# memokit review-findings validator (jq only).
#   validate <file>   take the LAST fenced ```json block of <file> and check it
#                     against the reviewer's findings schema:
#                     {"verdict":"APPROVE|REJECT","findings":[{"id","verdict":
#                     "confirmed|needs_validation|rejected","severity" (required iff
#                     confirmed, forbidden otherwise),"file","line","summary",
#                     "evidence","blocker" (required iff needs_validation)}]}
# Exit 0 valid; 1 invalid (first error on stdout); 2 bad usage.
set -u
if [ "${1:-}" != validate ] || [ -z "${2:-}" ] || [ $# -ne 2 ]; then
  echo "usage: memokit-findings.sh validate <file>" >&2
  exit 2
fi
file="$2"
[ -f "$file" ] || { echo "cannot read $file"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

block="$(awk '
  # Top-level fences only: a fence opens with 3+ backticks and closes on a bare
  # fence of at least the same length; anything inside another fence is content.
  function fence(line,   t, n) {
    t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    if (t !~ /^```+/) return 0
    n = match(t, /^`+/); flen = RLENGTH; info = substr(t, flen + 1)
    return 1
  }
  {
    if (!fence($0)) { if (state == "json") cur = cur $0 "\n"; next }
    if (state == "") {
      if (info == "json") { state = "json"; open = flen; cur = "" }
      else if (info !~ /`/) { state = "other"; open = flen }
    } else if (info == "" && flen >= open) {
      if (state == "json") { last = cur; have = 1 }
      state = ""
    } else if (state == "json") cur = cur $0 "\n"
  }
  END { if (state == "json") { print "UNTERMINATED"; exit } if (have) printf "%s", last }
' "$file")"
[ "$block" != UNTERMINATED ] || { echo "unterminated json block"; exit 1; }
[ -n "$block" ] || { echo "no fenced json block found"; exit 1; }
printf '%s' "$block" | jq -e . >/dev/null 2>&1 || { echo "last json block is not valid JSON"; exit 1; }

err="$(printf '%s' "$block" | jq -r '
  def sev: ["critical","high","medium","low","info"];
  def isstr: type == "string" and length > 0;
  def ferrs($i):
    if type != "object" then ["finding #\($i): must be an object"]
    else
      (if (.id | isstr) then .id else "#\($i)" end) as $n
      | (if (.id | isstr) then [] else ["finding #\($i): missing id"] end)
        + (if (.verdict | IN("confirmed","needs_validation","rejected")) then
             ( [ . as $f | ("file","summary","evidence") | select(($f[.] | isstr) | not) | "finding \($n): missing \(.)" ]
               + (if (.line | type == "number" and . >= 1 and . == floor) then [] else ["finding \($n): line must be an integer >= 1"] end)
               + (if .verdict == "confirmed" then
                    (if has("severity") | not then ["finding \($n): severity is required when verdict is confirmed"]
                     elif (.severity | IN(sev[])) then [] else ["finding \($n): severity must be one of critical, high, medium, low, info"] end)
                  elif has("severity") then ["finding \($n): severity is only allowed when verdict is confirmed"]
                  else [] end)
               + (if .verdict == "needs_validation" and ((.blocker | isstr) | not) then ["finding \($n): blocker is required when verdict is needs_validation"] else [] end) )
           else ["finding \($n): verdict must be confirmed, needs_validation or rejected"] end)
    end;
  if type != "object" then "top level must be an object"
  elif (.verdict | IN("APPROVE","REJECT")) | not then "verdict must be APPROVE or REJECT"
  elif (.findings | type) != "array" then "findings must be an array"
  else
    ( [ .findings | to_entries[] | (.key as $k | .value | ferrs($k)) ] | add // [] ) as $e
    | ([.findings[] | select(type == "object" and (.id | isstr)) | .id] | group_by(.) | map(select(length > 1)) | .[0][0]) as $d
    | if ($e | length) > 0 then $e[0]
      elif $d != null then "duplicate id \($d)"
      elif .verdict == "REJECT" and ([.findings[] | select(.verdict == "confirmed")] | length) == 0
        then "REJECT requires at least one confirmed finding"
      else empty end
  end')" || { echo "validator failed to run"; exit 1; }
if [ -n "$err" ]; then
  echo "$err"
  exit 1
fi
exit 0
