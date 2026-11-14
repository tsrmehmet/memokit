#!/bin/bash
cat <<TXT
this heredoc body has an apostrophe: don't
TXT
printf '%s\n' "$a" | grep -q x
printf "%s\n" "$a" | head -n 1
