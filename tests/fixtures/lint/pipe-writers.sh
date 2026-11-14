#!/bin/bash
# Positive control for tests/lint-pipe-writers.awk. Never executed.
# Bad shapes start at lines 4 5 7 9 10 12 13 16; good shapes at 18 19 21 22.
printf '%s\n' "$a" | grep -q x
printf '%s\n' "$a" |
  grep -q x
printf '%s\n' "$a" | \
  head -n 1
{ printf '%s\n' "$a"; echo b; } | grep -q x
x="$(printf '%s\n' "$a" |
  head -n 1)"
printf 'loud\n' | printf '%s\n' "$a" 2>/dev/null | grep -q x
if printf '%s\n' "$a" | grep -q x && printf '%s\n' "$b" | head -n 1; then :; fi
for i in 1; do
  printf '%s\n' "$i"
done | head -n 1
# good shapes
printf '%s\n' "$a" 2>/dev/null | grep -q x
printf '%s\n' "$a" 2>/dev/null |
  head -n 1
{ printf '%s\n' "$a"; echo b; } 2>/dev/null | grep -q x
printf '%s\n' 'a | grep -q
b | head' | cat
