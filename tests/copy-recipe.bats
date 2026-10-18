#!/usr/bin/env bats
load helpers
# Extracts the fenced copy recipe from WORKING-MODEL.md §7 and runs it, with
# its literal <paths> placeholder replaced the way an agent fills it in.

# recipe PATHS... -- the §7 recipe with <paths> replaced by the arguments.
recipe() {
  local r
  r="$(sed -n '/^## §7/,$p' "$MK_REPO/WORKING-MODEL.md" | awk '/^```/{f=!f; next} f')"
  [ -n "$r" ] || return 1
  printf '%s' "$r" | sed "s|<paths>|$*|g"
}

setup() {
  REPO="$(mktemp -d "${BATS_TMPDIR:-/tmp}/cr-repo.XXXXXX")"
  DEST="$(mktemp -d "${BATS_TMPDIR:-/tmp}/cr-dest.XXXXXX")"
  git -C "$REPO" init -q
  mkdir -p "$REPO/src" "$REPO/lib" "$REPO/other" "$REPO/bin"
  printf 'a' > "$REPO/src/tracked.txt"
  printf 'g' > "$REPO/src/gone.txt"
  printf 'l' > "$REPO/lib/l.txt"
  printf 'o' > "$REPO/other/o.txt"
  printf 'bin/\n' > "$REPO/.gitignore"
  git -C "$REPO" -c user.email=t@t -c user.name=t add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init
  rm "$REPO/src/gone.txt"
  printf 'u' > "$REPO/src/untracked.txt"
  printf 'big' > "$REPO/bin/big"
  export REPO DEST
}
teardown() { rm -rf "$REPO" "$DEST"; }

# two_paths SHELL ARGS... -- run the recipe for "src lib" and check the copy.
two_paths() {
  local r
  r="$(recipe src lib)"
  printf '%s\n' "$r" | grep -qF -- '-- src lib |' || { echo "placeholder not filled: $r"; return 1; }
  run "$@" "$r"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ -f "$DEST/src/tracked.txt" ] && [ -f "$DEST/src/untracked.txt" ] && [ -f "$DEST/lib/l.txt" ] ||
    { echo "missing files:"; find "$DEST" -type f; return 1; }
  [ ! -e "$DEST/src/gone.txt" ] && [ ! -e "$DEST/other" ] && [ ! -e "$DEST/bin" ] ||
    { echo "extra files:"; find "$DEST" -type f; return 1; }
}

@test "§7 copy recipe: '.' copies tracked + untracked-not-ignored files only" {
  run "$MK_BASH" -c "$(recipe .)"
  [ "$status" -eq 0 ]
  [ -f "$DEST/src/tracked.txt" ]
  [ -f "$DEST/src/untracked.txt" ]
  [ -f "$DEST/other/o.txt" ]
  [ ! -e "$DEST/src/gone.txt" ]
  [ ! -e "$DEST/bin" ]
}

@test "§7 copy recipe: two paths under bash" {
  two_paths "$MK_BASH" -c
}

@test "§7 copy recipe: two paths under zsh (Claude Code may run the user's zsh)" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  two_paths zsh -f -c
}

@test "§7 copy recipe: the recipe names no shell variable for the path list" {
  r="$(sed -n '/^## §7/,$p' "$MK_REPO/WORKING-MODEL.md" | awk '/^```/{f=!f; next} f')"
  printf '%s' "$r" | grep -qF -- '-- <paths> |'
  lacks "$r" '$PATHS'
}

@test "§7 copy recipe: a path with no files copies nothing and exits 0" {
  for sh in "$MK_BASH" zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    run "$sh" -c "$(recipe no-such-dir)"
    [ "$status" -eq 0 ] || { echo "$sh: status $status: $output"; false; }
    [ -z "$(ls -A "$DEST")" ] || { echo "$sh: copied something"; false; }
  done
}
