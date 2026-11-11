#!/usr/bin/env bash
# memokit remote-change labels and targets (0.8.0, spec Part A). Sourced
# after lib/common.sh and lib/careful.sh (it reuses their views, segment
# splitter and exemption rules), never executed. bash 3.2-safe.
#
# Active only with a "remote" object in .claude/memokit.json
# (MK_REMOTE_ENABLED=1). Labels, each with the targets a change window
# (lib/careful.sh) must hold to let the command through:
#   deploy-push    branch:<name>   git push to a deploy branch, gh pr merge,
#                                  gh workflow run, gh api writes, git with a
#                                  config / environment that can run anything
#                                  or an alias next to a deploy branch name
#                                  (every deploy branch unless named)
#   remote-mutate  host:<name>     ssh/scp/sftp/rsync to a configured host,
#                                  unless read-only (below)
#   k8s-mutate     k8s[:<ctx>]     kubectl/helm commands that change a cluster
#   runbook        runbook:<repo-relative path>@<sha256>
#   <label>        pattern:<target>  a careful.patterns entry with a target
#
# Like careful.sh this is text matching (accident prevention, not a sandbox).
# Every rule runs per segment on every view careful.sh builds (raw, joined,
# stripped, flat), on every tool word of the segment: a label found anywhere
# stands, so an exemption holds only when it holds in every view. A segment
# whose command word is computed ($X, $'ssh', a glob) and that names a
# configured host or deploy branch is labelled too (as careful.sh treats a
# computed rm). Fail closed: a stage that fails prints an "unparsed" line and
# the next stage works on the raw text.
#
# Exemptions (all off with MK_REMOTE_NO_EXEMPT=1, which the subagent guard
# uses), each only when every option is understood (fail closed otherwise):
#   git push --dry-run (the last --dry-run* word, before -- or a # comment);
#   ssh with no remote command and -N -G -V -Q or -O check|exit, or whose
#   remote command is read-only (_mk_rm_readonly); never when the segment is
#   fed by a pipe, holds <, names RemoteCommand/LocalCommand/
#   PermitLocalCommand/ProxyCommand or gives -F;
#   scp/sftp/rsync downloads (every remote spec before the last operand, the
#   last operand local; sftp only as host:path); rsync -n / --dry-run;
#   kubectl/helm --dry-run=client|server as the last --dry-run* word, not in
#   an option's value position (never for kubectl exec / cp).

# Builtin read-only remote commands. "a-b" means first word a AND second word
# b ("a-b-c": three words, so docker-compose-ps also covers docker compose ps).
# Extended by remote.readOnlyFirstWords (MK_REMOTE_READONLY). Commands that
# can change the server or run another program (env, find, ip, curl, date,
# hostname, less, top, journalctl, git log ...) are not listed.
MK_RM_READONLY="cat ls ll head tail wc df du free uptime whoami id printenv stat grep egrep fgrep ps netstat dig nslookup test true echo pwd which type file md5sum sha256sum systemctl-status systemctl-is-active systemctl-list-units docker-ps docker-logs docker-inspect docker-images docker-stats docker-compose-ps kubectl-get kubectl-describe kubectl-logs kubectl-top git-status tmux-ls"
# Verbs that make a computed command word (_mk_rm_dyn) a possible git/gh or
# kubectl/helm call, matched as whole words after the token's surrounding
# quotes, ( ) { } [ ] , ; and backslashes are stripped ("push", 'merge',
# push) match; src/push.ts, apply_migrations.py, patch_tool do not): the
# git/gh set names every deploy branch, the k8s set k8s too.
MK_RM_DYN_GIT="push merge"
MK_RM_DYN_K8S="apply rollout delete scale patch upgrade uninstall exec"
# Wrappers that run their first operand as a command: a command substitution
# there ($(cat cmd), `cat cmd`) is as strict as one in the command word
# (_mk_rm_wrap_skip skips their options; MK_RM_WRAP_LONGVAL: the long
# options with a separate value; timeout and chrt take a number first).
MK_RM_WRAPPERS="sudo env nice ionice nohup time command builtin exec setsid stdbuf timeout doas caffeinate chrt"
MK_RM_WRAP_LONGVAL=" --user --group --chdir --host --prompt --role --type --close-from --other-user --unset --split-string --default-signal --signal --kill-after --adjustment --input --output --error --class --classdata --pid --format "
# git config through -c / --config-env, git config writes, or the
# environment can make git run another command or talk to another place
# (aliases, core.sshCommand, core.hooksPath, gpg.ssh.defaultKeyCommand,
# credential.*, url.*.insteadOf, GIT_DIR, GIT_CONFIG_*, HOME, PATH, EDITOR
# ...), so any NAME=value word before git or gh (_mk_rm_env_word; LANG, LC_*,
# TZ, TERM, COLUMNS, LINES, NO_COLOR, GIT_TRACE* and GIT_PAGER=cat excepted),
# --git-dir / --work-tree, and any -c key or written config key outside an
# exact list of harmless keys (_mk_rm_git_cfgkey) give no exemption: every
# deploy branch and every host named.
# git global options without a value (git(1)); any other option word is
# unknown, and after one a computed word anywhere may be the subcommand.
MK_RM_GIT_FLAGS=" --bare --no-pager -p --paginate -P --no-replace-objects --no-lazy-fetch --no-optional-locks --no-advice --literal-pathspecs --glob-pathspecs --noglob-pathspecs --icase-pathspecs --exec-path --html-path --man-path --info-path --version --help -h "
# git's own subcommands (git --list-cmds=builtins,main, git 2.52). Any other
# subcommand (an alias set by an earlier git config, GIT_CONFIG_PARAMETERS or
# GIT_CONFIG_*, a git-* program) next to a deploy branch name is taken as
# push to the branches named (else every deploy branch).
MK_RM_GIT_CMDS=" add am annotate apply archimport archive backfill bisect blame branch bugreport bundle cat-file check-attr check-ignore check-mailmap check-ref-format checkout checkout--worker checkout-index cherry cherry-pick clean clone column commit commit-graph commit-tree config count-objects credential credential-cache credential-cache--daemon credential-netrc credential-osxkeychain credential-store cvsexportcommit cvsimport cvsserver daemon describe diagnose diff diff-files diff-index diff-pairs diff-tree difftool difftool--helper fast-export fast-import fetch fetch-pack filter-branch fmt-merge-msg for-each-ref for-each-repo format-patch fsck fsck-objects fsmonitor--daemon gc get-tar-commit-id grep hash-object help hook http-backend http-fetch http-push imap-send index-pack init init-db instaweb interpret-trailers last-modified log ls-files ls-remote ls-tree mailinfo mailsplit maintenance merge merge-base merge-file merge-index merge-octopus merge-one-file merge-ours merge-recursive merge-recursive-ours merge-recursive-theirs merge-resolve merge-subtree merge-tree mergetool mktag mktree multi-pack-index mv name-rev notes p4 pack-objects pack-redundant pack-refs patch-id pickaxe prune prune-packed pull push quiltimport range-diff read-tree rebase receive-pack reflog refs remote remote-ext remote-fd remote-ftp remote-ftps remote-http remote-https repack replace replay repo request-pull rerere reset restore rev-list rev-parse revert rm send-email send-pack sh-i18n--envsubst shell shortlog show show-branch show-index show-ref sparse-checkout stage stash status stripspace submodule submodule--helper subtree switch symbolic-ref tag unpack-file unpack-objects update-index update-ref update-server-info upload-archive upload-archive--writer upload-pack var verify-commit verify-pack verify-tag version web--browse whatchanged worktree write-tree "
# Bounds that keep one scan well inside the 5 s hook timeout (measured
# 2026-11-10, macOS bash 3.2: ~1.4 ms per parsed segment, ~10 ms per
# process; a 64 KB heredoc of ssh lines labels in ~1 s): segments (all
# views) naming a tool that one scan parses, more -> unparsed; distinct git
# lookups (two processes each, cached per directory) plus runbook hashes
# (cached per path), more -> fail closed (every deploy branch; runbook
# target @unreadable, never valid).
# A short-option word holding e (-e, -avze ...): a remote shell for rsync.
MK_RM_E_RE='(^|[^[:alnum:]_-])-[[:alnum:]]*e'
MK_RM_MAX_FORKS=8
# Structural bounds of one scan (fix rounds 2 and 4; the hook timeout is
# 5 s, after which Claude Code runs the command unchecked). Checked before
# any parsing on the raw command; past one of them the command is labelled
# too-large (the careful guard's approvable deny) and not parsed:
#   MK_RM_MAX_CHARS      bytes of the command
#   MK_RM_MAX_SEG_CHARS  bytes of one segment (split as mk_careful_segments)
#   MK_RM_MAX_SEGS       segments (newlines count)
#   MK_RM_MAX_TOOLS      tool words (ssh scp sftp rsync git gh kubectl helm,
#                        any case, whole words); every one is parsed with
#                        the tokens after it, so this times the tokens of a
#                        segment is the parse work
#   MK_RM_MAX_QUOTES     quote characters (' and "); the quote-aware passes
#                        and the window pass walk the quoted spans
# careful.sh keeps its own 64 KiB bound for its other rules. The parse loop
# itself stops (unparsed, fail closed) past MK_RM_MAX_PARSE segments over
# all views, and a segment whose tool words times tokens would exceed
# MK_RM_MAX_WORK is not parsed (unparsed), so the worst case inside the
# bounds stays linear in the command (2026-11-11: 32 tool words before
# 2000 tokens took seconds with the per-tool-word rescans).
MK_RM_MAX_CHARS=8192
MK_RM_MAX_SEG_CHARS=4096
MK_RM_MAX_SEGS=40
MK_RM_MAX_TOOLS=32
MK_RM_MAX_QUOTES=64
MK_RM_MAX_PARSE=200
MK_RM_MAX_WORK=8192
# Text whose every quote closes: runs of non-quotes, '...' and "...".
MK_RM_QUOTES_OK="^([^'\"]|'[^']*'|\"[^\"]*\")*\$"

# _mk_rm_too_large CMD -- 0 when CMD is past a structural bound above, 1
# when it is inside them, 2 when no remote label is possible at all (fix
# round 4b): the text holds no tool word (ssh scp sftp rsync git gh kubectl
# helm, any case, whole word), no configured host or deploy branch name
# (substring, any case), no runbooksDir path, no command substitution
# ($( or a backtick: a computed command word is labelled with everything),
# and no line with a computed word ($ or backtick) next to a verb
# (MK_RM_DYN_GIT, MK_RM_DYN_K8S, workflow) or, with hosts "*", next to @ :
# or Hostname=. Such a command (a
# heredoc writing a file, a long cat) is not scanned and never too-large
# here; careful.sh keeps its own 64 KiB bound. ONE awk call behind a
# per-call token (an awk that fails or prints anything else counts as too
# large, fail closed). Skipped (exit 1) when the caller set _rm_bounded=1:
# the window pass scans the segments of a command it already checked as a
# whole.
_mk_rm_too_large() {
  local tok out nl='
'
  [ "${_rm_bounded:-0}" = 1 ] && return 1
  tok="mk-ok-$$-$RANDOM-$RANDOM"
  # Relevance (fix round 5) is decided on the NORMALISED text the scanner's
  # views see: backslash-newline continuations joined, " ' and \ deleted,
  # .exe dropped, lower-cased; triggers: a tool word, a configured host or
  # branch name (substring), the runbooks dir basename, or a computed-word
  # character ($ ` * ? [). The counts (quotes, segments, segment length,
  # bytes) are taken on the raw text; tool words on the normalised one.
  out="$(printf '%s\n' "$1" | LC_ALL=C awk -v t="$tok" -v mc="$MK_RM_MAX_CHARS" -v m="$MK_RM_MAX_SEG_CHARS" -v ms="$MK_RM_MAX_SEGS" -v mt="$MK_RM_MAX_TOOLS" -v mq="$MK_RM_MAX_QUOTES" \
    -v names="${MK_REMOTE_HOSTS//$nl/ } ${MK_REMOTE_DEPLOY_BRANCHES//$nl/ }" -v rb="${MK_REMOTE_RUNBOOKS_DIR##*/}" '
    BEGIN { nn = split(tolower(names), nm, " "); rb = tolower(rb) }
    function norm(s,   i, nw, ws) {
      gsub("[\"\047\\\\]", "", s); s = tolower(s)
      gsub(/\.exe[^[:alnum:]_.-]/, " ", s); sub(/\.exe$/, "", s)
      if (s ~ /[$`*?[]/) rel = 1
      nw = split(s, ws, /[^[:alnum:]_.-]+/)
      for (i = 1; i <= nw; i++) if (ws[i] ~ /^(ssh|scp|sftp|rsync|git|gh|kubectl|helm)$/) { tw++; rel = 1 }
      for (i = 1; i <= nn; i++) if (nm[i] != "*" && nm[i] != "" && index(s, nm[i])) rel = 1
      if (rb != "" && index(s, rb)) rel = 1 }
    { total += length($0) + 1
      s = $0; q += gsub("[\"\047]", "", s)
      s = $0; gsub(/&&|\|\||;|\|/, "\n", s); gsub(/[[:space:]]&[[:space:]]/, "\n", s)
      k = split(s, a, "\n"); segs += k
      for (i = 1; i <= k; i++) if (length(a[i]) > m) big = 1
      if (match($0, /\\+$/) && RLENGTH % 2 == 1) { buf = buf substr($0, 1, length($0) - 1); next }
      norm(buf $0); buf = "" }
    END { if (buf != "") norm(buf)
          if (!rel) print "S" t; else if (total - 1 <= mc && !big && segs <= ms && tw <= mt && q <= mq) print t }')"
  case "$out" in
    "$tok") return 1 ;;
    "S$tok") return 2 ;;
  esac
  return 0
}

# _mk_rm_ansi TEXT TOKEN -- TEXT with every ANSI-C quoted span $'...'
# decoded and written as a plain '...' span, followed by a TOKEN line;
# nothing (unparsed, fail closed) when a span does not close or holds an
# escape the decoder does not implement. Decoded: \xH[H], \N[NN] octal,
# \uH[HHH] and \UH[HHHHHHH] below 128, \a \b \e \E \f \n \r \t \v \\ \? \"
# and \' (a quote is dropped); a NUL (\0, \x00, \u0000) ends the string as
# bash ends it (the rest of the span is dropped: $'prod.example.com\0x' is
# prod.example.com). \c, a \u or \U at 128 or above, a \x or \u with no hex
# digit and any other escaped character fail closed (I4, p11:
# $'prod.example.com' named nothing). Quote-aware (C3, p10): $' opens a
# span only outside '...' and "..." and when its $ is not escaped, so the
# grep anchor in grep 'foo$' f is text. One awk, linear.
#
# QA=1 (C3 addenda): quote-aware as above; a # after an unescaped blank or
# separator (or at a line start) outside quotes starts a comment, copied as
# text without changing the quote state, and a comment holding a
# dollar-quote fails closed; a quote still open at the end prints no TOKEN
# (fail closed). QA=0: the quote-unaware decoding (every $' opens a span,
# no comment rule), which prints "B" before TOKEN when a span does not close
# or decode; the scan keeps it as an extra view when it decodes cleanly:
# views only add labels, so the quote-aware view can only remove the C3
# false deny.
_mk_rm_ansi() {
  printf '%s\n' "$1" | LC_ALL=C awk -v t="$2" -v qa="${3:-1}" '
    function hv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
    function put(s) { if (!z) dec = dec s }
    { out = ""; i = 1; L = length($0); le = 0
      while (i <= L) {
        c = substr($0, i, 1)
        if (qa) {
          if (q == 1) { out = out c; if (c == "\047") q = 0; i++; continue }
          # le: the position of the last escaped character
          if (c == "\\") { out = out substr($0, i, 2); le = i + 1; i += 2; continue }
          if (q == 2) { out = out c; if (c == "\"") q = 0; i++; continue }
          # A comment starts at a # after an UNESCAPED separator (addendum
          # 2); a cut that leaves a dollar-quote behind fails closed.
          if (c == "#" && (i == 1 || (substr($0, i - 1, 1) ~ /[ \t;&|()<>]/ && le != i - 1))) {
            if (index(substr($0, i), "$\047")) bad = 1
            out = out substr($0, i); break }
          if (c == "\"") { q = 2; out = out c; i++; continue }
          if (c == "\047") { q = 1; out = out c; i++; continue }
        }
        if (c != "$" || substr($0, i + 1, 1) != "\047") { out = out c; i++; continue }
        j = i + 2; dec = ""; closed = 0; z = 0
        while (j <= L) {
          c = substr($0, j, 1)
          if (c == "\047") { closed = 1; j++; break }
          if (c != "\\") { put(c); j++; continue }
          d = substr($0, j + 1, 1)
          if (d == "x" || d == "u" || d == "U") {
            m = (d == "x") ? 2 : ((d == "u") ? 4 : 8)
            v = 0; n = 0
            while (n < m && substr($0, j + 2 + n, 1) ~ /[0-9A-Fa-f]/) { v = v * 16 + hv(substr($0, j + 2 + n, 1)); n++ }
            j += 2 + n
            if (n == 0 || (d != "x" && v >= 128)) { bad = 1; continue }
            if (v == 0) z = 1; else put(sprintf("%c", v))
            continue }
          if (d ~ /[0-7]/) {
            v = 0; n = 0
            while (n < 3 && substr($0, j + 1 + n, 1) ~ /[0-7]/) { v = v * 8 + substr($0, j + 1 + n, 1); n++ }
            j += 1 + n
            if (v == 0) z = 1; else if (v < 256) put(sprintf("%c", v)); else bad = 1
            continue }
          j += 2
          if (d == "n") put("\n"); else if (d == "t") put("\t")
          else if (d == "a") put(sprintf("%c", 7)); else if (d == "b") put(sprintf("%c", 8))
          else if (d == "e" || d == "E") put(sprintf("%c", 27)); else if (d == "f") put(sprintf("%c", 12))
          else if (d == "r") put(sprintf("%c", 13)); else if (d == "v") put(sprintf("%c", 11))
          else if (d == "\\" || d == "?" || d == "\"") put(d)
          else if (d != "\047") bad = 1 }
        if (!closed) bad = 1
        gsub(/\047/, "", dec)
        out = out "\047" dec "\047"; i = j }
      print out }
    END { if (!bad && (!qa || q == 0)) print t; else if (!qa) print "B" t }'
}
# Mutating subcommands (spec Part A list and review round 1). delete /
# uninstall too: under "remote" they yield a k8s target so a k8s window
# covers them (spec, "What a window covers"); kubectl-delete /
# helm-uninstall stay labelled as before.
MK_RM_K8S_MUT=" apply create replace patch edit set scale rollout label annotate cordon uncordon drain taint exec cp delete run expose autoscale debug attach certificate "
MK_RM_HELM_MUT=" install upgrade rollback uninstall delete del un "
# kubectl/helm global options with a separate value (to find the subcommand).
MK_RM_K8S_VALOPT=" -n --namespace --context --cluster --user -s --server --kubeconfig --token --as --as-group --as-uid --request-timeout -v --v --kube-context --kube-apiserver --kube-token --kube-as-user --kube-as-group --kube-ca-file --registry-config --repository-config --repository-cache "
# rsync options with a value (a separate word or =value) and the long options
# without one that keep the download exemption; any other option word
# (--remove-source-files, --server, ...) ends it.
MK_RM_RSYNC_VAL=" -e --rsh -f --filter -T --temp-dir -B --block-size -M --remote-option --exclude --include --exclude-from --include-from --files-from --log-file --partial-dir --compare-dest --copy-dest --link-dest --bwlimit --timeout --port --address --sockopts --password-file --chmod --chown --max-size --min-size --modify-window --suffix --backup-dir --out-format --iconv --protocol --checksum-choice --compress-level --skip-compress --usermap --groupmap --info --debug --outbuf --rsync-path --max-delete --max-alloc --contimeout --stop-after --stop-at "
MK_RM_RSYNC_FLAG=" --archive --verbose --compress --recursive --links --perms --times --group --owner --devices --specials --hard-links --acls --xattrs --one-file-system --sparse --whole-file --update --checksum --dirs --relative --quiet --dry-run --partial --progress --human-readable --itemize-changes --prune-empty-dirs --omit-dir-times --executability --copy-links --safe-links --ignore-times --size-only --existing --ignore-existing --delete --delete-before --delete-during --delete-delay --delete-after --delete-excluded --stats --numeric-ids --inplace --append --append-verify --no-motd --mkpath --list-only --ipv4 --ipv6 --protect-args --secluded-args "

# mk_remote_scan CMD -- one line per labelled segment of every view:
# "<label>\t<target> [<target>...]\t<segment>". Prints "unparsed\t\t" when a
# stage fails (and goes on with the raw text). No output: no remote label.
mk_remote_scan() {
  local tok joined stripped views flat ansi all segs seg n piped qsep nl='
' mark=$'\001'
  # Per-scan caches and fork budget, seen by the helpers through dynamic scope.
  local _rm_forks=0 _rm_lk_cache="" _rm_rb_cache="" _rm_dlok=0
  [ "${MK_REMOTE_ENABLED:-0}" = 1 ] || return 0
  # Structural bounds (MK_RM_MAX_*): a command past one is labelled
  # too-large and not parsed at all; one that can carry no builtin remote
  # label (_mk_rm_too_large exit 2) is only matched against the project
  # patterns with a target, on its raw lines (final wave: without a deploy
  # branch or host word in it, flyctl deploy got its label but no
  # pattern:<target>, so no window could ever cover it).
  _mk_rm_too_large "$1"
  case $? in 0) printf 'too-large\t\t\n'; return 0 ;; 2) _mk_rm_patterns "$1"; return 0 ;; esac
  # scp/sftp/rsync exemptions (download, rsync dry-run) only for a raw
  # command that is ONE segment (_mk_cf_oneseg, as the ssh read-only rule)
  # and names no remote shell or remote rsync anywhere: the splitter cuts
  # inside quotes (--rsync-path='x && rsync'), so a later piece can look
  # like a clean download. Fail closed.
  if _mk_cf_oneseg "$1"; then
    case "$1" in
      *--rsync-path*|*--rsh*|*RSYNC_RSH*) ;;
      *) [[ $1 =~ $MK_RM_E_RE ]] || _rm_dlok=1 ;;
    esac
  fi
  tok="mk-sentinel-$$-$RANDOM-$RANDOM"
  # The views, built as _mk_cf_labels builds them.
  joined="$1"; stripped="$1"
  case "$1" in *"\\$nl"*|*\\)
    joined="$(mk_careful_join "$tok$nl$1")"
    case "$joined" in
      "$tok") joined="" ;;
      "$tok$nl"*) joined="${joined#"$tok$nl"}" ;;
      *) printf 'unparsed\t\t\n'; joined="$1" ;;
    esac
    stripped="$(mk_careful_strip "$tok$nl$1")"
    case "$stripped" in
      "$tok") stripped="" ;;
      "$tok$nl"*) stripped="${stripped#"$tok$nl"}" ;;
      *) printf 'unparsed\t\t\n'; stripped="$1" ;;
    esac ;;
  esac
  views="$joined"
  [ "$stripped" = "$joined" ] || views="$views$nl$stripped"
  # ANSI-C quoting (fix round 5): a view with every $'...' decoded, so
  # $'\x73sh' $'prod\x2eexample.com' is seen as 'ssh' 'prod.example.com'
  # (the flat view below then drops the quotes). Quote-aware (C3): a span
  # that does not close, an escape the decoder does not know, a quote left
  # open, or an awk that fails: unparsed. The quote-unaware decoding is an
  # extra view when it decodes cleanly (views only add labels); a span it
  # cannot close or decode ("B" before its token: the C3 false deny) adds no
  # view, an awk that fails or prints anything else is unparsed.
  case "$1" in *"\$'"*)
    ansi="$(_mk_rm_ansi "$joined" "$tok" 1)"
    case "$ansi" in
      *"$nl$tok") ansi="${ansi%"$nl$tok"}"; views="$views$nl$ansi" ;;
      *) printf 'unparsed\t\t\n' ;;
    esac
    ansi="$(_mk_rm_ansi "$joined" "$tok" 0)"
    case "$ansi" in
      *"$nl$tok") ansi="${ansi%"$nl$tok"}"; views="$views$nl$ansi" ;;
      *"${nl}B$tok") ;;
      *) printf 'unparsed\t\t\n' ;;
    esac ;;
  esac
  if flat="$(mk_careful_flat "$views")" && ! _mk_cf_empty "$views" "$flat"; then
    [ "$flat" = "$views" ] || views="$views$nl$flat"
  else
    printf 'unparsed\t\t\n'
    flat=""
  fi
  # Segments of all views, split as mk_careful_segments splits, de-duplicated;
  # a segment after a single | (fed by a pipe) starts with the byte 0x01.
  # Sentinel lines first and last.
  all="$(printf '%s\n' "$tok$nl$views" | awk -v s="$tok" '{ gsub(/\|\|/, "\002"); gsub(/\|/, "\n\001"); gsub(/&&|\002|;/, "\n"); gsub(/[[:space:]]&[[:space:]]/, "\n"); k = split($0, a, "\n"); for (i = 1; i <= k; i++) if (!seen[a[i]]++) print a[i] } END { print s }')"
  case "$all" in
    "$tok$nl"*"$nl$tok") all="${all#"$tok$nl"}"; all="${all%"$nl$tok"}" ;;
    *) printf 'unparsed\t\t\n'; all="$1" ;;
  esac
  # Only a segment naming a tool as a word, holding a computed word or the
  # runbooks dir can match. Bounded (MK_RM_MAX_PARSE over all views): past
  # it, unparsed (fail closed) and no more parsing.
  # A computed word counts only next to a configured host or branch name, a
  # verb (MK_RM_DYN_GIT / MK_RM_DYN_K8S, workflow; as whole words once
  # quotes, brackets, commas and backslashes are blanked), a Hostname= or
  # user@ word (hosts "*"), or when the command word, or the first word after
  # a wrapper (MK_RM_WRAPPERS), holds a command substitution (_mk_rm_dyn),
  # so most heredocs of ordinary shell code are not parsed.
  segs="$(printf '%s\n' "$all" | awk -v s="$tok" -v rb="${MK_REMOTE_RUNBOOKS_DIR##*/}" -v names="${MK_REMOTE_HOSTS//$nl/ } ${MK_REMOTE_DEPLOY_BRANCHES//$nl/ }" -v verbs="$MK_RM_DYN_GIT $MK_RM_DYN_K8S workflow" -v wraps="$MK_RM_WRAPPERS" \
    'BEGIN { k = split(tolower(names), nm, " "); gsub(/ /, "|", verbs); vre = "[ ](" verbs ")[ ]"; gsub(/ /, "|", wraps); wre = "^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([^[:space:]]*\\/)?(" wraps ")[[:space:]]" }
     function named(l, i) { l = tolower(l); for (i = 1; i <= k; i++) if (nm[i] != "*" && index(l, nm[i])) return 1; return 0 }
     function verbw(l) { gsub(/[][:space:]"\047(){}[,;\\]/, " ", l); return (" " l " ") ~ vre }
     /(^|[^[:alnum:]_.-])(git|gh|ssh|scp|sftp|rsync|kubectl|helm)([^[:alnum:]_.-]|$)/ || (rb != "" && index($0, rb)) || (/[$`*?[]/ && ((names ~ /(^| )\*( |$)/ && (/[@:]/ || tolower($0) ~ /hostname=/)) || named($0) || verbw($0) || /^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*[^[:space:]]*(\$\(|`)/ || ($0 ~ wre && /\$\(|`/))) { print }
     END { print s }')"
  case "$segs" in
    "$tok") segs="" ;;
    *"$nl$tok") segs="${segs%"$nl$tok"}" ;;
    *) printf 'unparsed\t\t\n'; segs="$all" ;;
  esac
  n=0
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$MK_RM_MAX_PARSE" ]; then printf 'unparsed\t\t\n'; break; fi
    piped=0
    case "$seg" in "$mark"*) piped=1; seg="${seg#"$mark"}" ;; esac
    _mk_rm_seg "$seg" "$piped"
  done <<EOF
$segs
EOF
  # A separator inside quotes or escaped with a backslash (fix rounds 3 and
  # 4): the splitter above cuts there, so ssh -o 'User=x;' host ..., scp
  # 'a;b' host:x, rsync -e 'ssh; x' host:y or ssh -o User=x\; host leave no
  # piece that pairs the tool with its host. When the raw text holds a
  # quoted span with ; & | or a newline in it, or a backslash before ; & or
  # |, every rule runs once more on the segments of a QUOTE-AWARE split (on
  # ; && || and newline outside quotes, an unescaped one; a pipe or & stays
  # inside its segment, which can only add labels) of the joined, stripped
  # and flat views. Any label found stands. Quotes that do not close (or an
  # awk that fails) give unparsed: parsing the unsplit text instead was
  # measured at 4 s for 8 KB of ssh lines (2026-11-11), past the budget.
  if [ -n "$segs" ]; then
    qsep="'[^']*[;&|$nl][^']*'|\"[^\"]*[;&|$nl][^\"]*\"|\\\\[;&|]"
    if [[ $1 =~ $qsep ]]; then
      _mk_rm_qpass "$joined" "$tok"
      [ "$stripped" = "$joined" ] || _mk_rm_qpass "$stripped" "$tok"
      if [ -n "$flat" ] && [ "$flat" != "$joined" ] && [ "$flat" != "$stripped" ]; then
        _mk_rm_qpass "$flat" "$tok"
      fi
    fi
  fi
  # The pipe marks dropped by tr (M5: ${all//<mark>/} is the per-position
  # pattern op class, 1.9 s for 32 KB with 40 marks under a UTF-8 locale).
  _mk_rm_patterns "$(printf '%s' "$all" | LC_ALL=C tr -d '\001')"
}

# _mk_rm_qpass TEXT TOKEN -- every rule on each segment of a quote-aware
# split of TEXT (on ; && || and newline outside '...' and "..."; a
# backslash outside single quotes escapes the next character). Quotes that
# do not close, or an awk that does not print TOKEN last: unparsed.
_mk_rm_qpass() {
  local qa seg seen=0 nl='
'
  qa="$(printf '%s\n' "$1" | LC_ALL=C awk -v t="$2" '
    { if (NR > 1 && q == 0) { print s; s = "" } else if (NR > 1) s = s " "
      k = length($0)
      for (i = 1; i <= k; i++) {
        c = substr($0, i, 1)
        if (q == 1) { if (c == "\047") q = 0; s = s c; continue }
        if (c == "\\") { s = s c substr($0, i + 1, 1); i++; continue }
        if (q == 2) { if (c == "\"") q = 0; s = s c; continue }
        if (c == "\047") { q = 1; s = s c; continue }
        if (c == "\"") { q = 2; s = s c; continue }
        if (c == ";") { print s; s = ""; continue }
        if ((c == "&" || c == "|") && substr($0, i + 1, 1) == c) { print s; s = ""; i++; continue }
        s = s c
      } }
    END { print s; if (!q) print t }')"
  case "$qa" in
    "$2") return 0 ;;
    *"$nl$2") qa="${qa%"$nl$2"}" ;;
    *) printf 'unparsed\t\t\n'; return 0 ;;
  esac
  while IFS= read -r seg; do
    if [ "$seg" = "$2" ]; then seen=1; break; fi
    case "$seg" in *[![:space:]]*) _mk_rm_seg "$seg" 0 ;; esac
  done <<EOF
$qa
$2
EOF
  [ "$seen" = 1 ] || printf 'unparsed\t\t\n'
}

# mk_remote_scan_checked CMD -- sets _rm_scan to mk_remote_scan's output; a
# scan that did not run to its end (per-call sentinel line) gives
# "unparsed\t\t" and exit 1. Used by careful.sh and the functions below.
# ONE scan per command (fix round 4): the last result is kept in shell
# variables keyed by the command text (and the exemption switch), so the
# guard's labels, targets and window pass share one scan; a subshell
# inherits the cache it was started with (the guard fills it before
# mk_careful_labels runs in its own subshell).
mk_remote_scan_checked() {
  local tok="mk-sentinel-$$-$RANDOM-$RANDOM" key rc=0 nl='
'
  key="${MK_REMOTE_NO_EXEMPT:-0}${MK_REMOTE_ENABLED:-0}$nl$1"
  if [ "${_MK_RM_CACHE_KEY+set}" = set ] && [ "$key" = "$_MK_RM_CACHE_KEY" ]; then
    _rm_scan="$_MK_RM_CACHE_OUT"
    return "$_MK_RM_CACHE_RC"
  fi
  _rm_scan="$(mk_remote_scan "$1"; printf '%s\n' "$tok")"
  case "$_rm_scan" in
    "$tok") _rm_scan="" ;;
    *"$nl$tok") _rm_scan="${_rm_scan%"$nl$tok"}" ;;
    *) _rm_scan="unparsed"$'\t\t'; rc=1 ;;
  esac
  _MK_RM_CACHE_KEY="$key"; _MK_RM_CACHE_OUT="$_rm_scan"; _MK_RM_CACHE_RC="$rc"
  return "$rc"
}

# mk_remote_targets CMD -- the targets of every scan line, sorted, unique,
# one per line.
mk_remote_targets() {
  local l t x _f _rm_scan
  mk_remote_scan_checked "$1" || true
  [ -n "$_rm_scan" ] || return 0
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  while IFS= read -r l; do
    t="${l#*$'\t'}"; t="${t%%$'\t'*}"
    # shellcheck disable=SC2086  # targets are blank-separated; globbing is off
    for x in $t; do printf '%s\n' "$x"; done
  done <<EOF | LC_ALL=C sort -u
$_rm_scan
EOF
  [ "$_f" = 1 ] || set +f
}

# mk_remote_strip_covered CMD WINDOW_TARGETS -- CMD without the segments
# (split as mk_careful_segments splits) whose own targets are all in
# WINDOW_TARGETS (newline or blank separated); the rest, one per line. A
# segment with no target, or whose scan printed unparsed, is kept. Fail
# closed: CMD unchanged if the split fails or a here-document loop does not
# reach its sentinel line. (Targets only: the guard's window pass uses
# mk_remote_covered_only, which also checks the shape and the command word.)
mk_remote_strip_covered() {
  local tok all seg l t x covered seen win out="" done_all=0 _f _rm_scan nl='
'
  tok="mk-sentinel-$$-$RANDOM-$RANDOM"
  all="$(mk_careful_segments "$tok$nl$1")"
  case "$all" in
    "$tok") all="" ;;
    "$tok$nl"*) all="${all#"$tok$nl"}" ;;
    *) printf '%s\n' "$1"; return 0 ;;
  esac
  win="$nl${2// /$nl}$nl"
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  while IFS= read -r seg; do
    if [ "$seg" = "$tok" ]; then done_all=1; break; fi
    covered=0
    if mk_remote_scan_checked "$seg" && [ -n "$_rm_scan" ]; then
      covered=1; seen=0
      while IFS= read -r l; do
        if [ "$l" = "$tok" ]; then seen=1; break; fi
        case "$l" in unparsed$'\t'*) covered=0 ;; esac
        t="${l#*$'\t'}"; t="${t%%$'\t'*}"
        [ -n "$t" ] || covered=0
        # shellcheck disable=SC2086  # one target per word; globbing is off
        for x in $t; do
          case "$win" in *"$nl$x$nl"*) ;; *) covered=0 ;; esac
        done
      done <<EOF
$_rm_scan
$tok
EOF
      [ "$seen" = 1 ] || covered=0
    fi
    [ "$covered" = 1 ] || out="$out$seg$nl"
  done <<EOF
$all
$tok
EOF
  [ "$_f" = 1 ] || set +f
  if [ "$done_all" != 1 ]; then printf '%s\n' "$1"; return 0; fi
  printf '%s' "$out"
}

# ---- Change-window pass (security reviews of 0.8.0 Task 4) ----
# Words that make ssh, git, rsync, helm or the environment run a LOCAL
# program, matched case-insensitively anywhere in the command: a command
# holding one never passes a change window (defence in depth: the option
# allowlists below already refuse every option they do not name).
MK_RM_LOCALEXEC="proxycommand localcommand permitlocalcommand knownhostscommand sshcommand git_ssh rsync_rsh rsync_connect_prog --rsync-path receive-pack upload-pack --exec post-renderer"
# The whole command: every < > is part of a whole-word fd duplication
# ([12]>&[12] or >&[12], between blanks; 2>&10, 2>&1foo, x;2>&1 are not),
# every & of one or of && (no background &, file redirection, here-doc
# or here-string). _mk_rm_redir_ok blanks the duplications, then
# MK_RM_AMP_ONLY must hold.
MK_RM_FDDUP_RE='(^|[[:space:]])[12]?>&[12]([[:space:]]|$)'
MK_RM_AMP_ONLY='^([^&<>]|&&)*$'

# _mk_rm_redir_ok TEXT -- 0 when TEXT passes the rule above.
_mk_rm_redir_ok() {
  local s="$1" m
  while [[ $s =~ $MK_RM_FDDUP_RE ]]; do
    m="${BASH_REMATCH[0]}"
    s="${s/"$m"/ }"
  done
  [[ $s =~ $MK_RM_AMP_ONLY ]]
}
# Segment first words that change how a later word runs (PATH, functions,
# aliases, the directory, the environment): a command with one never passes.
MK_RM_ENVWORDS=" export declare typeset readonly local alias unalias function hash enable set shopt trap source . eval exec builtin command cd pushd popd unset umask ulimit "
# ssh/scp/sftp: short flags without a value (scp and sftp also -r and -p),
# and -o keys (lowercase). No HostName: -o HostName=other would send an
# approved alias elsewhere; no UserKnownHostsFile: it appends to any local
# file.
MK_RM_SSH_FLAGS="qv46AaCTtNn"
MK_RM_SCP_FLAGS="qv46ACpr"
MK_RM_SSH_OKEYS=" stricthostkeychecking batchmode connecttimeout connectionattempts port user identitiesonly identityfile serveraliveinterval serveralivecountmax loglevel passwordauthentication pubkeyauthentication preferredauthentications tcpkeepalive compression "
# kubectl/helm options that point the tool at another cluster, server,
# identity or credential: never in a window (--context / --kube-context are
# the target and stay).
MK_RM_K8S_DENY=" --cluster --server -s --user --kubeconfig --token --username --password --client-certificate --client-key --certificate-authority --insecure-skip-tls-verify --as --as-group --as-uid --tls-server-name --kube-apiserver --kube-token --kube-ca-file --kube-as-user --kube-as-group --kube-insecure-skip-tls-verify --kube-tls-server-name "
# An option value a window accepts: plain characters only (no blank, quote,
# ; | & $ or other shell syntax).
MK_RM_PLAIN_RE='^[A-Za-z0-9._/@:~+=,-]*$'
# rsync option values (--exclude='*.log'): plain, plus the pattern characters
# * ? [ ] (rsync's own patterns; unquoted, _mk_rm_ok_globs refuses them).
MK_RM_RSVAL_RE='^[][A-Za-z0-9._/@:~+=,*?-]*$'
# A quoted span ('...' or "...") and what may follow ssh's quoted payload.
MK_RM_QSPAN_RE="('[^']*'|\"[^\"]*\")"
MK_RM_TAIL_OK='^[[:space:]]*(2>&1|1>&2|>&2)?[[:space:]]*$'
# An rsync -e / --rsh value as written (quotes possibly around the option).
MK_RM_RSH_RE="(^|[[:space:]])['\"]?(-e|--rsh)['\"]?(=|[[:space:]]+)('[^']*'|\"[^\"]*\"|[^[:space:]]*)"
# rsync: short flags, long flags, long options with a value.
MK_RM_RS_FLAGS="avzrlptgoDnqchP"
MK_RM_RS_LONG=" --archive --verbose --compress --delete --delete-after --delete-excluded --dry-run --progress --partial --times --perms --links --recursive --human-readable --stats "
MK_RM_RS_LONGVAL=" --exclude --include --exclude-from --include-from --chmod --timeout --port --bwlimit --max-size --min-size "
# kubectl/helm subcommands a window may pass (no editor, no copy to local,
# no plugins).
MK_RM_KUBECTL_OK=" apply create replace patch set scale rollout label annotate cordon uncordon drain taint delete exec "
MK_RM_HELM_OK=" install upgrade rollback uninstall delete "

# _mk_rm_repo_ok DIR [INSIDE] -- 0 when DIR (cd -P, relative to the payload
# cwd _rm_cwd; no cwd, no dir) is MK_ROOT or one of its worktrees (git
# worktree list); with INSIDE=1 also a directory below one of them. Sets
# _rm_rd to the resolved directory.
_mk_rm_repo_ok() {
  local d r out l p nl='
'
  _rm_rd=""
  [ -n "${_rm_cwd:-}" ] || return 1
  d="$(cd -P -- "$_rm_cwd" 2>/dev/null && cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1
  r="$(cd -P -- "$MK_ROOT" 2>/dev/null && pwd -P)" || return 1
  [ -n "$d" ] && [ -n "$r" ] || return 1
  _rm_rd="$d"
  [ "$d" = "$r" ] && return 0
  if [ "${2:-0}" = 1 ]; then
    # Below a root: the SAME repository (git-common-dir), not a nested one
    # with its own remotes, and its toplevel a root or listed worktree.
    _mk_rm_same_repo "$d" && return 0
    _rm_rd=""
    return 1
  fi
  out="$(git -C "$MK_ROOT" worktree list --porcelain 2>/dev/null)" || return 1
  out="$out$nl"
  while [ -n "$out" ]; do
    l="${out%%"$nl"*}"; out="${out#*"$nl"}"
    case "$l" in
      'worktree '?*)
        p="$(cd -P -- "${l#worktree }" 2>/dev/null && pwd -P)" || continue
        [ "$p" = "$d" ] && return 0 ;;
    esac
  done
  _rm_rd=""
  return 1
}

# _mk_rm_same_repo DIR -- 0 when DIR (resolved) belongs to the project
# repository: git -C DIR rev-parse --git-common-dir (cd -P) equals
# MK_ROOT's, and --show-toplevel (cd -P) is MK_ROOT or one of its listed
# worktrees (fix round 4b: a nested repository under the root has its own
# origin).
_mk_rm_same_repo() {
  local c1 c2 tl
  c1="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  c1="$(cd -P -- "$1" 2>/dev/null && cd -P -- "$c1" 2>/dev/null && pwd -P)" || return 1
  c2="$(git -C "$MK_ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 1
  c2="$(cd -P -- "$MK_ROOT" 2>/dev/null && cd -P -- "$c2" 2>/dev/null && pwd -P)" || return 1
  [ -n "$c1" ] && [ "$c1" = "$c2" ] || return 1
  tl="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$tl" ] || return 1
  local _rm_cwd="/" _rm_rd
  _mk_rm_repo_ok "$tl"
}

# _mk_rm_ok_ssh Q TOOL -- the options of ssh/scp/sftp at word Q are all in
# the allowlist. Uses raw[] (as written) and bw[] (quotes deleted), n.
_mk_rm_ok_ssh() {
  local x=$(($1 + 1)) t v host=0 c vo fl
  case "$2" in ssh) vo="pPli"; fl="$MK_RM_SSH_FLAGS" ;; *) vo="Pli"; fl="$MK_RM_SCP_FLAGS" ;; esac
  while [ "$x" -lt "$n" ]; do
    t="${bw[x]}"
    case "${raw[x]}" in *'$'*) return 1 ;; esac
    case "$t" in
      --) return 0 ;;
      -o)
        v="${bw[x + 1]:-}"
        case "${raw[x + 1]:-}" in *'$'*) return 1 ;; esac
        _mk_rm_ok_okey "$v" || return 1
        x=$((x + 2)) ;;
      -o?*) _mk_rm_ok_okey "${t#-o}" || return 1; x=$((x + 1)) ;;
      -?)
        c="${t#-}"
        case "$vo" in
          *"$c"*)
            v="${bw[x + 1]:-}"
            case "$v" in ''|-*) return 1 ;; esac
            case "${raw[x + 1]}" in *'$'*) return 1 ;; esac
            [[ $v =~ $MK_RM_PLAIN_RE ]] || return 1
            x=$((x + 2)) ;;
          *) case "$fl" in *"$c"*) x=$((x + 1)) ;; *) return 1 ;; esac ;;
        esac ;;
      -?*)
        c="${t:1:1}"
        case "$vo" in
          *"$c"*)   # attached value: -p22, -luser, -ikey
            [[ $t =~ $MK_RM_PLAIN_RE ]] || return 1
            x=$((x + 1)) ;;
          *)
            v="${t#-}"
            case "$v" in *[!"$fl"]*) return 1 ;; esac
            x=$((x + 1)) ;;
        esac ;;
      *)
        # ssh: options may follow the host, the command starts after it.
        if [ "$2" = ssh ]; then
          [ "$host" = 1 ] && return 0
          host=1
        fi
        x=$((x + 1)) ;;
    esac
  done
  return 0
}

# _mk_rm_ok_okey KEY=VALUE -- an -o option whose key is allowed.
_mk_rm_ok_okey() {
  local k nc=0 rc=1
  case "$1" in *=*) ;; *) return 1 ;; esac
  case "$1" in *'$'*) return 1 ;; esac
  k="${1%%=*}"
  case "$k" in ''|*[!A-Za-z]*) return 1 ;; esac
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "$MK_RM_SSH_OKEYS" in *" $k "*) rc=0 ;; esac
  [ "$nc" = 1 ] || shopt -u nocasematch
  [[ ${1#*=} =~ $MK_RM_PLAIN_RE ]] || rc=1
  return "$rc"
}

# _mk_rm_ok_rsync Q -- every option of rsync at word Q is allowed; -e /
# --rsh only as exactly ssh or ssh -p <digits>.
_mk_rm_ok_rsync() {
  local x=$(($1 + 1)) t r v end=0
  while [ "$x" -lt "$n" ]; do
    t="${bw[x]}"; r="${raw[x]}"
    case "$r" in *'$'*) return 1 ;; esac
    if [ "$end" = 1 ]; then
      # a remote shell named after -- is still refused
      case "$t" in -e|-e?*|--rsh*) return 1 ;; esac
      x=$((x + 1)); continue
    fi
    case "$t" in
      --) end=1; x=$((x + 1)) ;;
      -e)
        if [ "${raw[x + 1]:-}" = ssh ]; then x=$((x + 2))
        elif _mk_rm_ok_sshp "${raw[x + 1]:-}" "${raw[x + 2]:-}" "${raw[x + 3]:-}"; then x=$((x + 4))
        else return 1; fi ;;
      --rsh=*)
        v="${r#--rsh=}"
        if [ "$v" = ssh ]; then x=$((x + 1))
        elif _mk_rm_ok_sshp "$v" "${raw[x + 1]:-}" "${raw[x + 2]:-}"; then x=$((x + 3))
        else return 1; fi ;;
      --*=*)
        case "$MK_RM_RS_LONGVAL" in *" ${t%%=*} "*) ;; *) return 1 ;; esac
        [[ ${t#*=} =~ $MK_RM_RSVAL_RE ]] || return 1
        x=$((x + 1)) ;;
      --*)
        case "$MK_RM_RS_LONG" in
          *" $t "*) x=$((x + 1)) ;;
          *)
            case "$MK_RM_RS_LONGVAL" in *" $t "*) ;; *) return 1 ;; esac
            case "${bw[x + 1]:-}" in ''|-*) return 1 ;; esac
            [[ ${bw[x + 1]} =~ $MK_RM_RSVAL_RE ]] || return 1
            x=$((x + 2)) ;;
        esac ;;
      -?*)
        v="${t#-}"
        case "$v" in *[!"$MK_RM_RS_FLAGS"]*) return 1 ;; esac
        x=$((x + 1)) ;;
      *) x=$((x + 1)) ;;
    esac
  done
  return 0
}

# _mk_rm_ok_quotes SEG CMD -- every quoted span of SEG ('...' or "...")
# holds no blank, no -- and does not start with -; for ssh the last
# argument (its remote command, followed by nothing but a whole-word fd
# duplication) may hold blanks and -- (it runs on the server). So a quoted
# span can never join or split the words the allowlists checked.
_mk_rm_ok_quotes() {
  local s="$1" m v rest
  while [[ $s =~ $MK_RM_QSPAN_RE ]]; do
    m="${BASH_REMATCH[0]}"
    v="${m:1:${#m}-2}"
    rest="${s#*"$m"}"
    case "$v" in -*) return 1 ;; esac
    case "$2:$v" in
      rsync:'ssh -p '*)
        # the one blank value rsync may carry (-e 'ssh -p 22'), digits only
        case "${v#ssh -p }" in ''|*[!0-9]*) return 1 ;; esac ;;
      *:*[[:space:]]*|*:*--*)
        [ "$2" = ssh ] || return 1
        [[ $rest =~ $MK_RM_TAIL_OK ]] || return 1 ;;
    esac
    s="$rest"
  done
  return 0
}

# _mk_rm_ok_rshval SEG -- every rsync -e / --rsh value in the raw SEG (the
# option possibly quoted, the value as written) is exactly ssh or
# ssh -p <digits>.
_mk_rm_ok_rshval() {
  local s="$1" m v
  while [[ $s =~ $MK_RM_RSH_RE ]]; do
    m="${BASH_REMATCH[0]}"
    v="${BASH_REMATCH[4]}"
    case "$v" in \'*\'|\"*\") v="${v:1:${#v}-2}" ;; esac
    case "$v" in
      ssh) ;;
      'ssh -p '*) case "${v#ssh -p }" in ''|*[!0-9]*) return 1 ;; esac ;;
      *) return 1 ;;
    esac
    s="${s#*"$m"}"
  done
  return 0
}

# _mk_rm_ok_sshp A B C -- the raw words A B C are 'ssh -p <digits>' (one
# pair of quotes around the three, or "--rsh='ssh" style A).
_mk_rm_ok_sshp() {
  local q
  case "$1" in \'ssh) q="'" ;; \"ssh) q='"' ;; *) return 1 ;; esac
  [ "$2" = -p ] || return 1
  case "$3" in *"$q") ;; *) return 1 ;; esac
  case "${3%"$q"}" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# _mk_rm_ok_globs SEG CMD -- no * ? or [ outside quotes anywhere in SEG
# (the shell would expand it: a planted file named -oProxyCommand=x becomes
# an option), and inside a quoted span only in ssh's payload (the last
# argument, followed by nothing but a whole-word fd duplication) or in a
# quoted rsync --exclude / --include value (=value or the next word).
_mk_rm_ok_globs() {
  local s="$1" m v pre rest
  while [[ $s =~ $MK_RM_QSPAN_RE ]]; do
    m="${BASH_REMATCH[0]}"
    pre="${s%%"$m"*}"; rest="${s#*"$m"}"
    case "$pre" in *[\*\?\[]*) return 1 ;; esac
    v="${m:1:${#m}-2}"
    case "$v" in
      *[\*\?\[]*)
        case "$2" in
          ssh) [[ $rest =~ $MK_RM_TAIL_OK ]] || return 1 ;;
          rsync) case "$pre" in *--exclude=|*--include=|*--exclude[[:space:]]|*--include[[:space:]]) ;; *) return 1 ;; esac ;;
          *) return 1 ;;
        esac ;;
    esac
    s="$rest"
  done
  case "$s" in *[\*\?\[]*) return 1 ;; esac
  return 0
}

# _mk_rm_ok_k8s Q TOOL -- kubectl/helm at word Q: no $, no kubeconfig,
# exec or plugin options, no post-renderer, none of MK_RM_K8S_DENY (another
# cluster, server, identity or credential), and an allowed subcommand.
_mk_rm_ok_k8s() {
  local x=$(($1 + 1)) t sub=""
  while [ "$x" -lt "$n" ]; do
    case "${raw[x]}" in *'$'*) return 1 ;; esac
    case "${bw[x]}" in --kubeconfig*|--exec*|*plugin*|--post-renderer*) return 1 ;; esac
    case "${bw[x]}" in
      -*) case "$MK_RM_K8S_DENY" in *" ${bw[x]%%=*} "*) return 1 ;; esac ;;
    esac
    case "${bw[x]}" in -s?*) return 1 ;; esac
    x=$((x + 1))
  done
  x=$(($1 + 1))
  while [ "$x" -lt "$n" ]; do
    t="${bw[x]}"
    case "$t" in
      --*=*) x=$((x + 1)) ;;
      -*) case "$MK_RM_K8S_VALOPT" in *" $t "*) x=$((x + 2)) ;; *) x=$((x + 1)) ;; esac ;;
      *) sub="$t"; break ;;
    esac
  done
  case "$2" in
    kubectl) case "$MK_RM_KUBECTL_OK" in *" $sub "*) return 0 ;; esac ;;
    helm) case "$MK_RM_HELM_OK" in *" $sub "*) return 0 ;; esac ;;
  esac
  return 1
}

# _mk_rm_ok_git Q -- git push <remote> ... or git -C <dir> push <remote> ...
# (dir: MK_ROOT or one of its worktrees; without -C the payload cwd must
# resolve inside one of them, else the push is another repository's), no $
# and no push option that runs a program. The remote, the first word after
# push that is not an option (-o / --push-option take a value), must be a
# name git remote prints in THAT directory (fix round 4: no URL, no path,
# no implicit upstream).
_mk_rm_ok_git() {
  local x=$(($1 + 1)) remote dir
  while [ "$x" -lt "$n" ]; do
    case "${raw[x]}" in *'$'*) return 1 ;; esac
    case "${bw[x]}" in --receive-pack*|--exec*|--upload-pack*|--repo*) return 1 ;; esac
    x=$((x + 1))
  done
  x=$(($1 + 1))
  if [ "${bw[x]:-}" = -C ]; then
    _mk_rm_repo_ok "${bw[x + 1]:-/nonexistent/}" || return 1
    x=$((x + 2))
  else
    _mk_rm_repo_ok . 1 || return 1
  fi
  dir="$_rm_rd"
  [ -n "$dir" ] || return 1
  [ "${bw[x]:-}" = push ] || return 1
  x=$((x + 1))
  while [ "$x" -lt "$n" ]; do
    case "${bw[x]}" in
      -o|--push-option) x=$((x + 2)) ;;
      --) x=$((x + 1)); break ;;
      -*) x=$((x + 1)) ;;
      *) break ;;
    esac
  done
  remote="${bw[x]:-}"
  case "$remote" in ''|*[/:]*|.*|-*) return 1 ;; esac
  # (the directory is the project repository or one of its worktrees, which
  # share MK_ROOT's remotes: the names come from MK_ROOT)
  _mk_rm_remote_ok "$remote" "$MK_ROOT"
}

# _mk_rm_remote_ok NAME DIR -- NAME is a line of git -C DIR remote.
_mk_rm_remote_ok() {
  local out nl='
'
  out="$(git -C "$2" remote 2>/dev/null)" || return 1
  case "$nl$out$nl" in *"$nl$1$nl"*) return 0 ;; esac
  return 1
}

# _mk_rm_ok_gh Q -- gh pr merge / gh workflow run from a payload cwd inside
# MK_ROOT or one of its worktrees (gh takes the repository from the cwd),
# no $, never --repo / -R (a GH_REPO= word is refused as an assignment
# before the command word), and every positional word after the
# subcommand a number or a plain name: nothing holding / or : (a PR URL,
# an owner/repo form, a refs/ path).
_mk_rm_ok_gh() {
  local x=$(($1 + 1))
  _mk_rm_repo_ok . 1 || return 1
  while [ "$x" -lt "$n" ]; do
    case "${raw[x]}" in *'$'*) return 1 ;; esac
    case "${bw[x]}" in -R|-R?*|--repo|--repo=*) return 1 ;; esac
    case "${bw[x]}" in
      -*) ;;
      *) case "${bw[x]}" in ''|*[!A-Za-z0-9._=@-]*) return 1 ;; esac ;;
    esac
    x=$((x + 1))
  done
  case "${bw[$1 + 1]:-} ${bw[$1 + 2]:-}" in 'pr merge'|'workflow run') return 0 ;; esac
  return 1
}

# _mk_rm_ok_runbook Q -- bash/sh <runbook path> or the runbook path itself,
# no quotes or $ in either word, no option to bash/sh, no $ in its
# arguments. The path is resolved against the payload cwd (_rm_cwd, cd -P;
# no cwd: refused), must be a file under MK_ROOT/<runbooksDir>/, and its
# hash must give a target of the window (fix round 4: the scan hashes
# MK_ROOT/<path as written>, while a shell below the root would run another
# file of the same relative name).
_mk_rm_ok_runbook() {
  local x=$1 p rb="$MK_REMOTE_RUNBOOKS_DIR" dir base res root rel sum
  [ -n "$rb" ] || return 1
  [ -n "${_rm_cwd:-}" ] || return 1
  case "${raw[x]}" in bash|sh) x=$((x + 1)) ;; esac
  p="${raw[x]:-}"
  case "$p" in *[\'\"\$]*|-*|''|*/) return 1 ;; esac
  dir="${p%/*}"; base="${p##*/}"
  [ "$dir" = "$p" ] && dir=.
  case "$base" in ''|.|..) return 1 ;; esac
  res="$(cd -P -- "$_rm_cwd" 2>/dev/null && cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 1
  root="$(cd -P -- "$MK_ROOT" 2>/dev/null && pwd -P)" || return 1
  [ -n "$res" ] && [ -n "$root" ] || return 1
  res="$res/$base"
  case "$res" in "$root/$rb"/?*) ;; *) return 1 ;; esac
  rel="${res#"$root/"}"
  [ -f "$res" ] && [ -r "$res" ] || return 1
  sum="$(_mk_cf_sha256 < "$res" 2>/dev/null)" || return 1
  sum="${sum%% *}"
  case "$sum" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#sum}" -eq 64 ] || return 1
  case "$win" in *" runbook:$rel@$sum "*) ;; *) return 1 ;; esac
  x=$((x + 1))
  while [ "$x" -lt "$n" ]; do
    case "${raw[x]}" in *'$'*) return 1 ;; esac
    x=$((x + 1))
  done
  return 0
}

# mk_remote_covered_only CMD WINDOW_TARGETS [CWD] -- the change-window pass
# check. Exit 2, nothing printed, when CMD has a shape no window may pass
# (rule a): a | ( ) { } backtick or backslash anywhere; an & < > that is not
# part of &&, 2>&1, 1>&2 or >&2; a word of MK_RM_LOCALEXEC; a newline inside
# quotes or unbalanced quotes; a command past the structural bounds
# (_mk_rm_too_large); a segment starting with an assignment or a word of
# MK_RM_ENVWORDS; or a state label (careful-state, careful-state-glob,
# too-large, unparsed) among the careful labels of the covered segments.
# Otherwise exit 0 and print, first, one line with the remote labels (space
# separated, possibly none) the scans of the uncovered segments gave, then
# the segments (split on && ; and newline outside quotes, blank ones
# dropped) that are NOT covered, one per line, for the caller to label with
# careful's own rules: a command passes only when none of them has a label.
# (Each segment is scanned once here, and that scan's labels are returned,
# so the caller never scans it again: one scan per segment.)
# A segment is covered (rule b) only when
#   - its scan has lines, none unparsed or too-large, every line has targets
#     and every target is in WINDOW_TARGETS (newline or blank separated);
#   - its command word is the first word, or the second after a bare sudo or
#     env (no option, no assignment), written as a bare name without quotes,
#     / or $ (the runbook path excepted);
#   - every line's label is the command word's: remote-mutate for
#     ssh/scp/sftp/rsync, deploy-push for git/gh, k8s-mutate for
#     kubectl/helm, runbook for bash/sh <path> or the path; a project
#     pattern line (pattern:<target>) only in a segment of pattern lines
#     alone, without $ or a glob (quoted or not), whose careful labels are
#     all among its scan labels (the project's own regex; no option
#     allowlist applies to it);
#   - its options pass the tool's allowlist (_mk_rm_ok_*), checked on the
#     words with quotes deleted, and no word of its options holds a $;
#   - no * ? or [ outside quotes (_mk_rm_ok_globs: the shell would expand
#     it), and inside quotes only in ssh's payload or an rsync
#     --exclude / --include value;
#   - a runbook path resolves (from CWD, the payload cwd) to a file under
#     MK_ROOT/<runbooksDir>/ whose hash is in the window (_mk_rm_ok_runbook).
# Same-segment labels (ssh prod 'rm -rf /srv/old', git push --force) stay
# covered: with the allowlists those words only reach the remote side.
# Fail closed: a split, a here-document loop or a labelling that does not
# reach its sentinel leaves CMD uncovered (printed) or refused.
mk_remote_covered_only() {
  local tok all seg l t x ok seen win out="" cov="" rl=" " done_all=0 nc=0 word _f _rm_scan
  local raw bw n q cmd fam lab pat lines labs slabs nseg=0 hasrb=0 _rm_cwd="${3:-}" _rm_bounded=0 nl='
' IFS=$' \t\n'
  # Rule (a), on the raw text, in bash (no tool that could fail into "clean").
  # shellcheck disable=SC2016  # literal backtick
  case "$1" in *'|'*|*'`'*|*'('*|*')'*|*'{'*|*'}'*|*\\*) return 2 ;; esac
  _mk_rm_redir_ok "$1" || return 2
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  ok=1
  for word in $MK_RM_LOCALEXEC; do
    case "$1" in *"$word"*) ok=0; break ;; esac
  done
  [ "$nc" = 1 ] || shopt -u nocasematch
  [ "$ok" = 1 ] || return 2
  # The structural bounds, once on the whole command; the per-segment scans
  # below then skip them (_rm_bounded: a segment of a bounded command is
  # inside every bound).
  _mk_rm_too_large "$1" && return 2
  _rm_bounded=1
  # Quote-aware split; a line that ends inside quotes refuses the command.
  # The per-call token is printed last only when the quotes balance.
  tok="mk-sentinel-$$-$RANDOM-$RANDOM"
  all="$(printf '%s\n' "$1" | LC_ALL=C awk -v t="$tok" '
    { k = length($0); s = ""
      for (i = 1; i <= k; i++) {
        c = substr($0, i, 1)
        if (q == 1) { if (c == "\047") q = 0; s = s c; continue }
        if (q == 2) { if (c == "\"") q = 0; s = s c; continue }
        if (c == "\047") { q = 1; s = s c; continue }
        if (c == "\"") { q = 2; s = s c; continue }
        if (c == ";") { print s; s = ""; continue }
        if (c == "&" && substr($0, i + 1, 1) == "&") { print s; s = ""; i++; continue }
        s = s c
      }
      if (q) bad = 1
      print s }
    END { if (!bad) print t }')"
  case "$all" in
    "$tok") all="" ;;
    *"$nl$tok") all="${all%"$nl$tok"}" ;;
    *) return 2 ;;
  esac
  win=" ${2//$nl/ } "
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  while IFS= read -r seg; do
    if [ "$seg" = "$tok" ]; then done_all=1; break; fi
    case "$seg" in *[![:space:]]*) ;; *) continue ;; esac
    # shellcheck disable=SC2206  # word splitting is intended; globbing is off
    raw=( $seg )
    n="${#raw[@]}"
    nseg=$((nseg + 1))
    # Assignments and environment-changing first words refuse the command.
    case "${raw[0]}" in [A-Za-z_]*=*) [ "$_f" = 1 ] || set +f; return 2 ;; esac
    case "$MK_RM_ENVWORDS" in *" ${raw[0]} "*) [ "$_f" = 1 ] || set +f; return 2 ;; esac
    ok=0
    if mk_remote_scan_checked "$seg" && [ -n "$_rm_scan" ]; then
      ok=1
      # A runbook invocation passes only as the ONLY segment of the command
      # (fix round 4b: another segment could rewrite the file between the
      # hash check and the run).
      case "$_rm_scan" in runbook$'\t'*|*"$nl"runbook$'\t'*) hasrb=1 ;; esac
      bw=()
      x=0
      while [ "$x" -lt "$n" ]; do
        t="${raw[x]//\'/}"; bw[x]="${t//\"/}"
        x=$((x + 1))
      done
      q=0
      case "${raw[0]}" in sudo|env) q=1 ;; esac
      cmd="${raw[q]:-}"
      fam=""
      case "$cmd" in
        ssh|scp|sftp|rsync) fam="remote-mutate" ;;
        git|gh) fam="deploy-push" ;;
        kubectl|helm) fam="k8s-mutate" ;;
        bash|sh|*/*) fam="runbook" ;;
      esac
      pat=0; lines=0; slabs=" "; seen=0
      while IFS= read -r l; do
        if [ "$l" = "$tok" ]; then seen=1; break; fi
        lines=$((lines + 1))
        lab="${l%%$'\t'*}"
        t="${l#*$'\t'}"; t="${t%%$'\t'*}"
        [ -n "$t" ] || ok=0
        case "$lab" in unparsed|too-large) ok=0 ;; esac
        # shellcheck disable=SC2086  # one target per word; globbing is off
        for x in $t; do
          case "$win" in *" $x "*) ;; *) ok=0 ;; esac
        done
        slabs="$slabs$lab "
        case "$t" in
          pattern:*) pat=$((pat + 1)) ;;
          *) [ "$lab" = "$fam" ] || ok=0 ;;
        esac
      done <<EOF
$_rm_scan
$tok
EOF
      [ "$seen" = 1 ] || ok=0
      if [ "$ok" = 1 ] && [ "$pat" -gt 0 ]; then
        # pattern lines: alone in the segment, no $, labels all from them
        [ "$pat" = "$lines" ] || ok=0
        case "$seg" in *'$'*) ok=0 ;; esac
        case "$cmd" in */*|*[\'\"]*|'') ok=0 ;; esac
        # no glob, quoted or not (M7: flyctl deploy --config *.toml)
        [ "$ok" = 1 ] && { _mk_rm_ok_globs "$seg" "$cmd" || ok=0; }
        if [ "$ok" = 1 ]; then
          labs="$(MK_REMOTE_ENABLED=0 mk_careful_labels "$seg"; printf '%s' "$tok")"
          case "$labs" in *"$tok") labs="${labs%"$tok"}" ;; *) ok=0; labs="" ;; esac
          for x in $labs; do
            case "$slabs" in *" $x "*) ;; *) ok=0 ;; esac
          done
        fi
      elif [ "$ok" = 1 ]; then
        case "$cmd" in
          ssh|scp|sftp) _mk_rm_ok_ssh "$q" "$cmd" || ok=0 ;;
          rsync) _mk_rm_ok_rsync "$q" || ok=0 ;;
          git) _mk_rm_ok_git "$q" || ok=0 ;;
          gh) _mk_rm_ok_gh "$q" || ok=0 ;;
          kubectl|helm) _mk_rm_ok_k8s "$q" "$cmd" || ok=0 ;;
          *) _mk_rm_ok_runbook "$q" || ok=0 ;;
        esac
        # Quotes may wrap only ssh's payload and simple values (word
        # boundaries the per-word checks above see must be bash's), a --
        # must be a whole unquoted word, rsync's remote shell is checked on
        # the raw text too, and no glob may reach the shell.
        [ "$ok" = 1 ] && { _mk_rm_ok_quotes "$seg" "$cmd" || ok=0; }
        [ "$ok" = 1 ] && { _mk_rm_ok_globs "$seg" "$cmd" || ok=0; }
        x=0
        while [ "$x" -lt "$n" ]; do
          if [ "${bw[x]}" = -- ] && [ "${raw[x]}" != -- ]; then ok=0; fi
          x=$((x + 1))
        done
        if [ "$cmd" = rsync ] && [ "$ok" = 1 ]; then _mk_rm_ok_rshval "$seg" || ok=0; fi
      fi
    fi
    if [ "$ok" = 1 ]; then
      cov="$cov$seg$nl"
    else
      out="$out$seg$nl"
      # the remote labels of this segment's scan, for the caller
      while IFS= read -r l; do
        [ -n "$l" ] || continue
        lab="${l%%$'\t'*}"
        case "$lab" in ''|*[[:space:]]*) continue ;; esac
        case "$rl" in *" $lab "*) ;; *) rl="$rl$lab " ;; esac
      done <<EOF
${_rm_scan:-}
EOF
    fi
  done <<EOF
$all
$tok
EOF
  [ "$_f" = 1 ] || set +f
  if [ "$done_all" != 1 ]; then printf 'unparsed\n%s\n' "$1"; return 0; fi
  if [ "$hasrb" = 1 ] && [ "$nseg" -gt 1 ]; then return 2; fi
  # Every covered segment is labelled too (careful's own rules; their
  # remote labels are the scan lines above): a state label refuses the pass.
  if [ -n "$cov" ]; then
    labs="$(MK_REMOTE_ENABLED=0 mk_careful_labels "$cov"; printf '%s' "$tok")"
    case "$labs" in *"$tok") labs="${labs%"$tok"}" ;; *) return 2 ;; esac
    case "$nl$labs$nl" in
      *"${nl}careful-state${nl}"*|*"${nl}careful-state-glob${nl}"*|*"${nl}too-large${nl}"*|*"${nl}unparsed${nl}"*) return 2 ;;
    esac
  fi
  rl="${rl# }"; rl="${rl% }"
  printf '%s\n%s' "$rl" "$out"
}

# mk_remote_target_valid TARGET -- 0 when TARGET is spelled as a target and
# the config allows it (a configured host, or any host-shaped name with "*";
# a deploy branch; k8s[:ctx]; a runbook under runbooksDir whose sha256
# matches the file now; a project pattern's target).
mk_remote_target_valid() {
  local t="$1" v p nl='
'
  case "$t" in
    host:?*)
      v="${t#host:}"
      case "$v" in *[[:space:]]*) return 1 ;; esac
      _mk_rm_host_target "$v" 1 ;;
    branch:?*)
      v="${t#branch:}"
      case "$nl$MK_REMOTE_DEPLOY_BRANCHES$nl" in *"$nl$v$nl"*) return 0 ;; esac
      return 1 ;;
    k8s) return 0 ;;
    k8s:?*)
      case "${t#k8s:}" in *[![:alnum:]._@:/-]*) return 1 ;; esac
      return 0 ;;
    runbook:?*@?*)
      v="${t#runbook:}"; p="${v%@*}"
      case "$p" in "$MK_REMOTE_RUNBOOKS_DIR"/?*) ;; *) return 1 ;; esac
      case "/$p/" in */../*|*/./*|*//*) return 1 ;; esac
      [ "$(mk_remote_runbook_target "$p")" = "$t" ] ;;
    pattern:?*)
      v="${t#pattern:}"
      case "$v" in *[![:alnum:]-]*) return 1 ;; esac
      printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq -e --arg t "$v" 'any(.[]; .target == $t)' >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# mk_remote_runbook_target RELPATH -- "runbook:<relpath>@<sha256>" of
# $MK_ROOT/RELPATH; exit 1 when it is not a readable file.
mk_remote_runbook_target() {
  local f="$MK_ROOT/$1" sum
  [ -f "$f" ] && [ -r "$f" ] || return 1
  sum="$(_mk_cf_sha256 < "$f" 2>/dev/null)" || return 1
  sum="${sum%% *}"
  case "$sum" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#sum}" -eq 64 ] || return 1
  printf 'runbook:%s@%s\n' "$1" "$sum"
}

# _mk_rm_seg SEG PIPED -- the remote labels of one segment line (PIPED=1: it
# is fed by a pipe). Tokens are split on blanks with globbing off; w[] holds
# each token with one pair of surrounding quotes removed, raw[] the token as
# written.
_mk_rm_seg() {
  local _f
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  _mk_rm_seg_body "$1" "${2:-0}"
  [ "$_f" = 1 ] || set +f
}

_mk_rm_seg_body() {
  local _rm_seg="$1" _rm_piped="$2" raw w n i t b g=0 h=0 rs=0 tw=0 IFS=$' \t\n'
  # Per-token host facts of this segment (_mk_rm_pre, filled on first use).
  local _rm_pre=0 _ph _ps _pn
  # shellcheck disable=SC2206  # word splitting is intended; globbing is off
  raw=( $1 )
  n="${#raw[@]}"
  [ "$n" -gt 0 ] || return 0
  w=("${raw[@]}")
  case "$1" in
    *[\'\"]*)
      i=0
      while [ "$i" -lt "$n" ]; do
        t="${raw[i]}"
        case "$t" in \'?*\'|\"?*\") w[i]="${t:1:${#t}-2}" ;; esac
        i=$((i + 1))
      done ;;
  esac
  # Work bound (MK_RM_MAX_WORK): every tool word is parsed with the tokens
  # after it; past tool words times tokens the segment is unparsed (fail
  # closed) instead of taking seconds.
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${w[i]##*/}" in git|gh|ssh|scp|sftp|rsync|kubectl|helm) tw=$((tw + 1)) ;; esac
    i=$((i + 1))
  done
  if [ "$((tw * n))" -gt "$MK_RM_MAX_WORK" ]; then printf 'unparsed\t\t\n'; return 0; fi
  _mk_rm_runbook
  _mk_rm_dyn
  # Every tool word of the segment (a label from any one stands), except the
  # remote shell named by -e / --rsh of an rsync earlier in this segment,
  # which rsync's own rules judge (xargs -e ssh, xterm -e ssh: parsed).
  i=0
  while [ "$i" -lt "$n" ]; do
    b="${w[i]##*/}"
    case "$b" in
      git) [ "$g" = 1 ] || { _mk_rm_git "$i" && g=1; } ;;
      gh) [ "$h" = 1 ] || { _mk_rm_gh "$i" && h=1; } ;;
      ssh|scp|sftp|rsync)
        t=""
        [ "$i" -gt 0 ] && [ "$rs" = 1 ] && t="${w[i - 1]}"
        case "$t" in -e|--rsh) ;; *) _mk_rm_net "$b" "$i" ;; esac
        [ "$b" = rsync ] && rs=1 ;;
      kubectl|helm) _mk_rm_k8s "$b" "$i" ;;
    esac
    i=$((i + 1))
  done
}

# _mk_rm_emit LABEL TARGETS -- one scan line for the current segment.
_mk_rm_emit() {
  [ -n "$2" ] && printf '%s\t%s\t%s\n' "$1" "${2# }" "$_rm_seg"
}

# _mk_rm_pre -- once per segment (fix round 4), the host facts of every
# token, read by the per-tool-word loop of _mk_rm_net and by _mk_rm_dyn, so
# a segment with many tool words is parsed in time linear in its tokens:
# _ph[k] and _ps[k] from _mk_rm_host_of on the bared token, _pn[k] the
# configured hosts (not "*") the raw token names anywhere,
# case-insensitively (as _mk_rm_named_hosts).
_mk_rm_pre() {
  local k h nc=0 nh IFS='
'
  _rm_pre=1
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  k=0
  while [ "$k" -lt "$n" ]; do
    # (a token without : @ or [ is its own host name, one trailing dot
    # dropped, shape 0: _mk_rm_host_of's result, without the call)
    case "${w[k]}" in
      *[:@\[]*) _mk_rm_host_of "${w[k]}"; _ph[k]="$_rm_h"; _ps[k]="$_rm_shape" ;;
      *) _ph[k]="${w[k]%.}"; _ps[k]=0 ;;
    esac
    nh=""
    for h in $MK_REMOTE_HOSTS; do
      [ "$h" = '*' ] && continue
      if [[ ${raw[k]} == *"$h"* ]]; then nh="$nh host:$h"; fi
    done
    _pn[k]="$nh"
    k=$((k + 1))
  done
  [ "$nc" = 1 ] || shopt -u nocasematch
}

# _mk_rm_branches -- sets _rm_b to " branch:<b>" for every deploy branch
# (a variable, not output: command substitution would fork per segment).
_mk_rm_branches() {
  local b nl='
'
  _rm_b=""
  # shellcheck disable=SC2086  # names hold no blank (schema); globbing is off (caller)
  for b in ${MK_REMOTE_DEPLOY_BRANCHES//$nl/ }; do _rm_b="$_rm_b branch:$b"; done
}

# _mk_rm_branch_hits WORD -- adds " branch:<b>" to the caller's hits for each
# deploy branch WORD names as a push destination: <b>, *:<b>, *:heads/<b>,
# *:refs/heads/<b>, and (fail closed) anything ending in /<b>. Names compare
# case-insensitively (fix round 4: deploy:PUBLIC-RELEASE); the target keeps
# the configured spelling.
_mk_rm_branch_hits() {
  local b nc=0 nl='
'
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  # shellcheck disable=SC2086  # names hold no blank (schema); globbing is off (caller)
  for b in ${MK_REMOTE_DEPLOY_BRANCHES//$nl/ }; do
    if [[ $1 == "$b" || $1 == *":$b" || $1 == *"/$b" ]]; then
      case "$hits " in *" branch:$b "*) ;; *) hits="$hits branch:$b" ;; esac
    fi
  done
  [ "$nc" = 1 ] || shopt -u nocasematch
}

# _mk_rm_fork -- true while the scan may still start a process for a git
# lookup or a runbook hash (MK_RM_MAX_FORKS); the caller fails closed past it.
_mk_rm_fork() {
  [ "${_rm_forks:-0}" -lt "$MK_RM_MAX_FORKS" ] || return 1
  _rm_forks=$((${_rm_forks:-0} + 1))
}

# _mk_rm_redir TOKEN -- 0: a redirection token; 2: one whose file is the
# next token; 1: not a redirection.
_mk_rm_redir() {
  case "$1" in
    '>'|'>>'|'<'|[0-9]'>'|[0-9]'>>'|[0-9]'<'|'&>'|'&>>') return 2 ;;
    '>'*|'<'*|[0-9]'>'*|[0-9]'<'*|'&>'*|'&') return 0 ;;
  esac
  return 1
}

# _mk_rm_dyn -- a computed word ($, backtick, a glob) may run ssh or git,
# and no list of wrappers (sudo, env, timeout, setsid, nice, ...) is ever
# complete. So unless the segment's command word (after NAME=value) is a
# literal tool word, whose own rules judge its computed arguments, a computed
# word ANYWHERE plus a configured host named anywhere in the segment text
# (inside quotes, Hostname= values, user@...), or a word naming a deploy
# branch in a segment that also holds push / pr merge / workflow run, is
# labelled with those targets (fail closed, as careful.sh's computed rm).
# Hosts come from every source (configured names as substrings, remote-form
# and user@host words, Hostname= values) before any rule decides.
_mk_rm_dyn() {
  local p=0 k q v hosts="" hits="" dyn=0 dollar=0 cmdc=0 cs=0 strict=0 push=0 k8s=0 vb=0 cb=""
  while [ "$p" -lt "$n" ]; do
    case "${w[p]}" in [A-Za-z_]*=*) p=$((p + 1)) ;; *) break ;; esac
  done
  case "${w[p]:-}" in
    ssh|scp|sftp|rsync|git|gh|kubectl|helm|*/ssh|*/scp|*/sftp|*/rsync|*/git|*/gh|*/kubectl|*/helm) return 0 ;;
  esac
  k=0
  while [ "$k" -lt "$n" ]; do
    case "${raw[k]}" in
      *[\$\`]*) dyn=1; dollar=1; break ;;
      *[\*\?\[]*) dyn=1 ;;
    esac
    k=$((k + 1))
  done
  [ "$dyn" = 1 ] || return 0
  case "${raw[p]:-}" in *[\$\`\*\?\[]*) cmdc=1 ;; esac
  # A command word holding a command substitution can be anything: always
  # every deploy branch and k8s (cs, below). The first word after a wrapper
  # (sudo, env, nice, timeout ... and their options) is the command word too.
  case "${raw[p]:-}" in *\$\(*|*\`*) cs=1 ;; esac
  _mk_rm_wrap_skip "$p"
  if [ "$_rm_q" -gt "$p" ]; then
    case "${raw[_rm_q]:-}" in *\$\(*|*\`*) cs=1; cmdc=1 ;; esac
  fi
  # Strict (any deploy branch word counts) unless the command word is a
  # literal non-tool word and the only computed words are globs: then a
  # branch counts only next to push / pr merge / workflow run
  # (grep -r deploy src/*.ts is not a push).
  if [ "$cmdc" = 1 ] || [ "$dollar" = 1 ]; then strict=1; fi
  _mk_rm_named_hosts "$_rm_seg"
  hosts="$_rm_nh"
  # (fix round 4: a plain token, no : @ [ Hostname= pr or verb text, costs
  # two cases here, so a 2000-token segment is parsed in milliseconds)
  k=0
  while [ "$k" -lt "$n" ]; do
    # With "*" every remote-form or user@host word, or Hostname= value,
    # names a host (a host shape needs : @ or a URL; the rest never has it).
    case "${w[k]}" in
      *[:@\[]*|*[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee]=*)
        _mk_rm_host_of "${w[k]}"
        case "${w[k]}" in
          -o[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee]=*|[Hh][Oo][Ss][Tt][Nn][Aa][Mm][Ee]=*) _rm_h="${w[k]#*=}"; _rm_shape=1 ;;
          *@*) _rm_shape=1 ;;
        esac
        if [ "$_rm_shape" = 1 ] && _mk_rm_host_target "$_rm_h" 1; then
          case "$hosts " in *" $_rm_t "*) ;; *) hosts="$hosts $_rm_t" ;; esac
        fi ;;
    esac
    # Verbs, as whole words of the bared raw token ("push", push), 'merge',
    # (delete), push\ match; src/push.ts, x=delete, 'merge:' do not). The
    # bare form is only computed for a token that holds a verb (the words
    # of MK_RM_DYN_GIT, MK_RM_DYN_K8S and workflow) or "pr" at all.
    case "${raw[k]}" in
      *push*|*merge*|*apply*|*rollout*|*delete*|*scale*|*patch*|*upgrade*|*uninstall*|*exec*|*workflow*|*pr*)
        _mk_rm_bare "${raw[k]}"; v="$_rm_bare"
        case " $MK_RM_DYN_GIT " in *" $v "*) vb=1; [ "$v" = push ] && push=1 ;; esac
        case " $MK_RM_DYN_K8S " in *" $v "*) vb=1; k8s=1 ;; esac
        case "${w[k]} ${w[k + 1]:-}" in
          # as gh: every deploy branch (the base branch is not looked up)
          'pr merge') push=1; _mk_rm_branches; hits="$_rm_b" ;;
        esac
        if [ "$v" = workflow ]; then
          _mk_rm_bare "${raw[k + 1]:-}"
          [ "$_rm_bare" = run ] && { vb=1; push=1; _mk_rm_branches; hits="$_rm_b"; }
        fi ;;
    esac
    k=$((k + 1))
  done
  if [ "$strict" = 1 ] || [ "$push" = 1 ]; then
    k=0
    while [ "$k" -lt "$n" ]; do _mk_rm_branch_hits "${w[k]#+}"; k=$((k + 1)); done
  fi
  # A computed push with no destination named (on a deploy branch, --all):
  # every deploy branch.
  if [ "$strict" = 1 ] && [ "$push" = 1 ] && [ -z "$hits" ]; then _mk_rm_branches; hits="$_rm_b"; fi
  # Rule C: a computed command word followed (after options) by another
  # computed word may be git/gh/kubectl/helm with a computed subcommand:
  # every deploy branch and k8s, but only when the segment also names a
  # deploy branch, a host (from any source) or a verb ("$CC" $CFLAGS -o x is
  # a build line; a bare $G $P is an accepted gap, README), or when the
  # command word holds a command substitution. A computed command word with
  # a k8s verb: k8s.
  if [ "$cmdc" = 1 ]; then
    [ -n "$hosts" ] && vb=1
    [ -n "$hits" ] && vb=1
    q=$((p + 1))
    while case "${w[q]:-}" in -*) true ;; *) false ;; esac; do q=$((q + 1)); done
    case "${raw[q]:-}" in *[\$\`\*\?\[]*) [ "$vb" = 1 ] && cs=1 ;; esac
    if [ "$cs" = 1 ]; then _mk_rm_branches; cb="$_rm_b"; k8s=1; fi
  else
    k8s=0
  fi
  [ -n "$cb" ] && hits="$cb"
  _mk_rm_emit remote-mutate "$hosts"
  _mk_rm_emit deploy-push "$hits"
  if [ "$k8s" = 1 ]; then _mk_rm_emit k8s-mutate k8s; fi
}

# _mk_rm_bare TOKEN -- sets _rm_bare to TOKEN without its leading and
# trailing quotes, ( ) { } [ ] , ; and backslashes (the verb-matching word).
# ONE regex (0.8.0 final wave, C1/M4): the old loop removed one character
# per pass with ${v%?}, 1.2 s for a 4 KB run of ) under a UTF-8 locale.
# A token made only of those characters keeps its last one (as the loop
# did).
_mk_rm_bare() {
  local re='^[]['\''"(){},;\]*(.*[^]['\''"(){},;\])[]['\''"(){},;\]*$'
  if [[ $1 =~ $re ]]; then
    _rm_bare="${BASH_REMATCH[1]}"
  elif [ -n "$1" ]; then
    _rm_bare="${1:$((${#1} - 1))}"
  else
    _rm_bare=""
  fi
}

# _mk_rm_wrap_skip P -- sets _rm_q to the index of the first word after the
# wrappers (MK_RM_WRAPPERS) that start at word P, their options (short
# clusters whose value letters take the rest of the cluster or the next
# word; MK_RM_WRAP_LONGVAL long options take the next word; --opt=value;
# NAME=value words for env and sudo; a leading number for timeout and chrt).
# _rm_q = P when word P is not a wrapper.
_mk_rm_wrap_skip() {
  local q="$1" wr t vo c
  _rm_q="$q"
  while [ "$q" -lt "$n" ]; do
    wr="${w[q]##*/}"
    case " $MK_RM_WRAPPERS " in *" $wr "*) ;; *) break ;; esac
    case "$wr" in
      sudo) vo=ugCDhprtTU ;; env) vo=uSCP ;; nice) vo=n ;; ionice) vo=cnpPu ;;
      time) vo=fo ;; exec) vo=a ;; stdbuf) vo=ioe ;; timeout) vo=sk ;;
      doas) vo=uC ;; caffeinate) vo=tw ;; chrt) vo=p ;; *) vo="" ;;
    esac
    q=$((q + 1))
    while [ "$q" -lt "$n" ]; do
      t="${w[q]}"
      case "$t" in
        --) q=$((q + 1)); break ;;
        --*=*) q=$((q + 1)) ;;
        --*) case "$MK_RM_WRAP_LONGVAL" in *" $t "*) q=$((q + 2)) ;; *) q=$((q + 1)) ;; esac ;;
        -?*)
          c=1
          while [ "$c" -lt "${#t}" ]; do
            case "$vo" in
              *"${t:c:1}"*) [ "$c" -eq $((${#t} - 1)) ] && q=$((q + 1)); break ;;
            esac
            c=$((c + 1))
          done
          q=$((q + 1)) ;;
        [A-Za-z_]*=*) q=$((q + 1)) ;;
        *) break ;;
      esac
    done
    case "$wr" in timeout|chrt) case "${w[q]:-}" in [0-9]*) q=$((q + 1)) ;; esac ;; esac
  done
  _rm_q="$q"
}

# _mk_rm_named_hosts TEXT -- sets _rm_nh to " host:<h>" for every configured
# host (not "*") that TEXT contains anywhere, case-insensitively (fail
# closed: preprod.example.com also names prod.example.com).
_mk_rm_named_hosts() {
  local h nc=0 _f IFS='
'
  _rm_nh=""
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  for h in $MK_REMOTE_HOSTS; do
    [ "$h" = '*' ] && continue
    if [[ $1 == *"$h"* ]]; then _rm_nh="$_rm_nh host:$h"; fi
  done
  [ "$nc" = 1 ] || shopt -u nocasematch
  [ "$_f" = 1 ] || set +f
}

# _mk_rm_git I -- git at token I: 1 when it is not "git ... push", else 0
# and the deploy-push line, if any. Destinations per _mk_rm_branch_hits;
# --all, --mirror, a glob or ":" name every branch. No refspec (or HEAD/@):
# the current branch and its upstream are looked up; a deploy branch in
# either, or a failing git, names every deploy branch (fail closed). A
# --dry-run (the last --dry-run* word before -- or a # comment) is exempt.
_mk_rm_git() {
  local j=$(($1 + 1)) q t r b rc cdir key sub hits="" dry=0 all=0 nonopt=0 head=0 skip=0 dd=0 cm=0 cfg=0 unk=0 nc=0 cur up tab=$'\t' nl='
'
  cdir=(-C "$MK_ROOT")
  # Any NAME=value word before git (HOME, PATH, EDITOR, GIT_*; a few harmless
  # names excepted), any -c key outside the harmless list, a computed -c
  # value, --config-env, --exec-path=, --git-dir and --work-tree can make git
  # run another command or talk to another place: fail closed.
  j=0
  while [ "$j" -lt "$1" ]; do
    _mk_rm_env_word "${w[j]}" && cfg=1
    j=$((j + 1))
  done
  j=$(($1 + 1))
  while [ "$j" -lt "$n" ]; do
    t="${w[j]}"
    case "$t" in
      -c) t="${w[j + 1]:-}"; j=$((j + 2)) ;;
      -c?*) t="${t#-c}"; j=$((j + 1)) ;;
      -C) cdir+=(-C "${w[j + 1]:-}"); j=$((j + 2)); continue ;;
      --config-env) cfg=1; j=$((j + 2)); continue ;;
      --config-env=*|--exec-path=*) cfg=1; j=$((j + 1)); continue ;;
      --namespace) j=$((j + 2)); continue ;;
      --namespace=*|--super-prefix=*|--list-cmds=*|--attr-source=*) j=$((j + 1)); continue ;;
      --git-dir|--work-tree) cfg=1; j=$((j + 2)); continue ;;
      --git-dir=*|--work-tree=*) cfg=1; j=$((j + 1)); continue ;;
      -*)
        case "$MK_RM_GIT_FLAGS" in *" $t "*) ;; *) unk=1 ;; esac
        j=$((j + 1)); continue ;;
      *) break ;;
    esac
    # (only -c values reach here): a computed value, or a key not harmless
    case "$t" in *[\$\`]*) cfg=1; continue ;; esac
    _mk_rm_lower "${t%%=*}"
    _mk_rm_git_cfgkey "$_rm_l" && cfg=1
  done
  if [ "$cfg" = 1 ]; then
    _mk_rm_named_hosts "$_rm_seg"
    _mk_rm_emit remote-mutate "$_rm_nh"
    _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"
    return 0
  fi
  # A computed subcommand may be push: every deploy branch (fail closed).
  # After an option git(1) does not list (it may or may not take a value),
  # any computed word after the git word may be it, and a later push word
  # is taken as the subcommand.
  if [ "$unk" = 1 ]; then
    q=$(($1 + 1))
    while [ "$q" -lt "$n" ]; do
      case "${raw[q]}" in
        *[\$\`\*\?\[]*) _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0 ;;
      esac
      [ "${w[q]}" = push ] && j="$q"
      q=$((q + 1))
    done
  fi
  case "${raw[j]:-}" in
    *[\$\`\*\?\[]*) _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0 ;;
  esac
  sub="${w[j]:-}"
  # Other spellings of a push (I2, p9): git subtree push (its refspecs are
  # read as git push's, from the push word on), git http-push and git p4
  # submit (every deploy branch).
  case "$sub" in
    subtree)
      q=$((j + 1))
      while [ "$q" -lt "$n" ]; do
        if [ "${w[q]}" = push ]; then j="$q"; sub=push; break; fi
        q=$((q + 1))
      done
      [ "$sub" = push ] || return 1 ;;
    http-push)
      [ -n "$MK_REMOTE_DEPLOY_BRANCHES" ] || return 0
      _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0 ;;
    p4)
      q=$((j + 1))
      while [ "$q" -lt "$n" ]; do
        if [ "${w[q]}" = submit ]; then
          [ -n "$MK_REMOTE_DEPLOY_BRANCHES" ] || return 0
          _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0
        fi
        q=$((q + 1))
      done
      return 1 ;;
  esac
  case "$sub" in
    push|send-pack) ;;
    config) _mk_rm_git_config "$j"; return 0 ;;
    '') return 1 ;;
    *)
      case "$MK_RM_GIT_CMDS" in *" $sub "*) return 1 ;; esac
      # Not one of git's own subcommands: an alias (set by an earlier git
      # config, GIT_CONFIG_PARAMETERS, GIT_CONFIG_*) or a git-* program. With
      # a deploy branch named in the segment it is taken as push to the
      # branches named as destinations, else to every deploy branch.
      [ -n "$MK_REMOTE_DEPLOY_BRANCHES" ] || return 1
      q=$((j + 1))
      while [ "$q" -lt "$n" ]; do _mk_rm_branch_hits "${w[q]#+}"; q=$((q + 1)); done
      if [ -z "$hits" ]; then
        shopt -q nocasematch && nc=1
        shopt -s nocasematch
        # shellcheck disable=SC2086  # names hold no blank (schema); globbing is off (caller)
        for b in ${MK_REMOTE_DEPLOY_BRANCHES//$nl/ }; do
          if [[ $_rm_seg == *"$b"* ]]; then all=1; fi
        done
        [ "$nc" = 1 ] || shopt -u nocasematch
        [ "$all" = 1 ] || return 1
        _mk_rm_branches; hits="$_rm_b"
      fi
      _mk_rm_emit deploy-push "$hits"
      return 0 ;;
  esac
  [ -n "$MK_REMOTE_DEPLOY_BRANCHES" ] || return 0
  j=$((j + 1))
  while [ "$j" -lt "$n" ]; do
    t="${w[j]}"; r="${raw[j]}"; j=$((j + 1))
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$r" in '#'*) cm=1 ;; esac
    # After a comment only destinations still count (fail closed).
    if [ "$cm" = 1 ]; then _mk_rm_branch_hits "${t#+}"; continue; fi
    if [ "$dd" = 0 ]; then
      rc=0; _mk_rm_redir "$t" || rc=$?
      case "$rc" in 0) continue ;; 2) skip=1; continue ;; esac
      case "$t" in
        --) dd=1; continue ;;
        --dry-run) dry=1; continue ;;
        --dry-run*|--no-dry-run*) dry=0; continue ;;
        --all|--mirror|--branches) all=1; continue ;;
        -o|--push-option|--repo|--receive-pack|--exec) skip=1; continue ;;
        -*) continue ;;
      esac
    fi
    nonopt=$((nonopt + 1))
    t="${t#+}"
    case "$t" in
      HEAD|@) head=1 ;;
      ''|:|*'*'*) all=1 ;;
    esac
    _mk_rm_branch_hits "$t"
  done
  if [ "$dry" = 1 ] && [ "${MK_REMOTE_NO_EXEMPT:-0}" != 1 ]; then return 0; fi
  if [ "$all" = 0 ] && { [ "$nonopt" -le 1 ] || [ "$head" = 1 ]; }; then
    # One lookup per directory per scan (_rm_lk_cache, a scan local: lines
    # "<-C args><tab><0|1>"); past the fork budget, every branch.
    key="${cdir[*]}"
    case "${_rm_lk_cache:-}" in
      *"$nl$key$tab"*) all="${_rm_lk_cache#*"$nl$key$tab"}"; all="${all%%"$nl"*}" ;;
      *)
        if ! _mk_rm_fork ||
           ! cur="$(git "${cdir[@]}" rev-parse --abbrev-ref HEAD 2>/dev/null)" ||
           ! up="$(git "${cdir[@]}" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"; then
          all=1
        else
          for b in ${MK_REMOTE_DEPLOY_BRANCHES//$nl/ }; do
            case "$cur" in "$b") all=1 ;; esac
            case "$up" in "$b"|*/"$b") all=1 ;; esac
          done
        fi
        _rm_lk_cache="${_rm_lk_cache:-$nl}$key$tab$all$nl" ;;
    esac
  fi
  if [ "$all" = 1 ]; then _mk_rm_branches; hits="$_rm_b"; fi
  _mk_rm_emit deploy-push "$hits"
  return 0
}

# _mk_rm_env_word WORD -- 0 when WORD is a NAME=value assignment that can
# change what git or gh runs or reads (HOME, XDG_CONFIG_HOME, PATH, PREFIX,
# SSH_*, EDITOR, GIT_SSH_COMMAND, GIT_CONFIG_*, GIT_DIR, GIT_PAGER, GH_*,
# ...: fail closed, any name); 1 for a non-assignment and for LANG, LC_*,
# TZ, TERM, COLUMNS, LINES, NO_COLOR, GIT_TRACE* and GIT_PAGER=cat. Pure
# bash patterns: independent of the locale.
_mk_rm_env_word() {
  local nm
  case "$1" in [A-Za-z_]*=*) ;; *) return 1 ;; esac
  # NAME+=value appends to NAME (I3, p1): the same assignment.
  nm="${1%%=*}"; nm="${nm%+}"
  case "$nm" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  # (the flat view lowercases a leading GIT to git_)
  case "$1" in
    LANG=*|LC_*=*|TZ=*|TERM=*|COLUMNS=*|LINES=*|NO_COLOR=*|[Gg][Ii][Tt]_TRACE*=*|[Gg][Ii][Tt]_PAGER=cat) return 1 ;;
  esac
  return 0
}

# _mk_rm_git_cfgkey KEY -- 0 unless the lower-cased git config KEY is
# harmless: an exact key (user.name, user.email, user.signingkey,
# core.quotepath, core.autocrlf, core.safecrlf, commit.gpgsign, gpg.format,
# gpg.mintrustlevel, gpg.ssh.allowedsignersfile, gpg.ssh.revocationfile) or
# a key family that names no program (color.*, advice.*, log.*, status.*,
# i18n.*, column.*) -- but never a key holding command, program, cmd,
# helper, path or hook. Every other key (aliases, core.sshCommand,
# core.hooksPath, gpg.ssh.defaultKeyCommand, credential.*, url.*.insteadOf,
# include.*, sequence.editor, diff.external, ...) can run a command or
# change where git talks to (fail closed).
_mk_rm_git_cfgkey() {
  case "$1" in
    user.name|user.email|user.signingkey|core.quotepath|core.autocrlf|core.safecrlf|commit.gpgsign|gpg.format|gpg.mintrustlevel|gpg.ssh.allowedsignersfile|gpg.ssh.revocationfile) return 1 ;;
    *command*|*program*|*cmd*|*helper*|*path*|*hook*) return 0 ;;
    color.*|advice.*|log.*|status.*|i18n.*|column.*) return 1 ;;
  esac
  return 0
}

# _mk_rm_git_config J -- "git config" at token J. A read is "get" or "list"
# as the first non-option word, or --get*, --list, -l, --show-*,
# --name-only BEFORE the key (the first non-option word); any word after the
# key other than an option (git config <key> <value>, ... --list) makes it a
# write again. A write of a key that _mk_rm_git_cfgkey labels, of a computed
# key, or with -e/--edit, names every host in the segment and every deploy
# branch (the written config can make a later git run anything: aliases,
# core.sshCommand ...).
_mk_rm_git_config() {
  local q=$(($1 + 1)) t key="" write=1 edit=0 comp=0 pos=0
  while [ "$q" -lt "$n" ]; do
    t="${w[q]}"
    case "${raw[q]}" in '#'*) break ;; esac
    case "$t" in
      -f|--file|--blob|--type|-t|--default|--comment|--value) q=$((q + 2)); continue ;;
    esac
    if [ "$pos" = 0 ]; then
      # before the key: mode options and the new-style verb
      case "$t" in
        --get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|--list|-l|--show-origin|--show-scope|--name-only) write=0 ;;
        -e|--edit) edit=1 ;;
        -*) ;;
        get|list) write=0; pos=1 ;;
        edit) edit=1; pos=1 ;;
        set|unset|unset-all|remove-section|rename-section) pos=1 ;;
        *) key="$t"; pos=2; case "${raw[q]}" in *[\$\`]*) comp=1 ;; esac ;;
      esac
    else
      case "$t" in
        -*) ;;
        *)
          if [ "$pos" = 1 ]; then
            key="$t"; pos=2; case "${raw[q]}" in *[\$\`]*) comp=1 ;; esac
          else
            write=1
          fi ;;
      esac
    fi
    q=$((q + 1))
  done
  [ "$write" = 1 ] || return 0
  if [ "$edit" = 0 ] && [ "$comp" = 0 ]; then
    [ -n "$key" ] || return 0
    _mk_rm_lower "$key"
    _mk_rm_git_cfgkey "$_rm_l" || return 0
  fi
  _mk_rm_named_hosts "$_rm_seg"
  _mk_rm_emit remote-mutate "$_rm_nh"
  _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"
}

# _mk_rm_gh I -- gh after token I names every deploy branch (the base branch
# is not looked up: a network call) for "pr ... merge" and "workflow ... run"
# (options may stand between), for "api" writes (_mk_rm_gh_api), for a
# NAME=value word before gh (_mk_rm_env_word), for a computed command word,
# and, fail closed, for any computed word in a segment holding pr or
# workflow, or after an option gh(1) does not list before the command.
_mk_rm_gh() {
  local j=0 unk=0 comp=0 pr=0 wf=0
  while [ "$j" -lt "$1" ]; do
    if _mk_rm_env_word "${w[j]}"; then _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0; fi
    j=$((j + 1))
  done
  j=$(($1 + 1))
  while [ "$j" -lt "$n" ]; do
    case "${w[j]}" in
      -R|--repo) j=$((j + 2)) ;;
      --repo=*|-R?*|--help|--version|-h) j=$((j + 1)) ;;
      -*) unk=1; j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  case "${raw[j]:-}" in
    *[\$\`\*\?\[]*) _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0 ;;
  esac
  # (an api call that writes nothing falls through to the rules below)
  if [ "${w[j]:-}" = api ] && _mk_rm_gh_api "$j"; then return 0; fi
  j=$(($1 + 1))
  while [ "$j" -lt "$n" ]; do
    case "${raw[j]}" in *[\$\`\*\?\[]*) comp=1 ;; esac
    case "${w[j]}" in
      pr) pr=1 ;;
      workflow) wf=1 ;;
      merge) [ "$pr" = 1 ] && { _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0; } ;;
      run) [ "$wf" = 1 ] && { _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0; } ;;
    esac
    j=$((j + 1))
  done
  if [ "$comp" = 1 ] && { [ "$unk" = 1 ] || [ "$pr$wf" != 00 ]; }; then
    _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"; return 0
  fi
  return 1
}

# _mk_rm_gh_api J -- "gh api" at token J: 0 and every deploy branch when it
# can write: a -X / --method of PUT, POST, PATCH or DELETE (any case) or a
# computed one, a -f / -F / --raw-field / --field / --input body, a "$@" /
# "$*" word, or a path matching pulls/*/merge, */merges, */dispatches or
# */git/refs (any method: fail closed). Other paths and options (--jq, -H,
# --paginate ...) are reads: 1, nothing printed.
_mk_rm_gh_api() {
  local q=$(($1 + 1)) t hit=0
  while [ "$q" -lt "$n" ]; do
    t="${w[q]}"
    case "${raw[q]}" in '#'*) break ;; esac
    # shellcheck disable=SC2016  # the literal words $@ and $*, as written in the command
    case "$t" in
      -X|--method) _mk_rm_gh_method "${w[q + 1]:-}" "${raw[q + 1]:-}" && hit=1; q=$((q + 2)); continue ;;
      -X?*) _mk_rm_gh_method "${t#-X}" "${raw[q]}" && hit=1 ;;
      --method=*) _mk_rm_gh_method "${t#*=}" "${raw[q]}" && hit=1 ;;
      -f|-F|--raw-field|--field|--input) hit=1; q=$((q + 2)); continue ;;
      -f?*|-F?*|--raw-field=*|--field=*|--input=*) hit=1 ;;
      -H|--header|-q|--jq|-t|--template|-p|--preview|--cache|--hostname) q=$((q + 2)); continue ;;
      '$@'|'$*'|'${@}'|'${*}') hit=1 ;;
      -*) ;;
      *pulls/*/merge*|*/merges*|*/dispatches*|*/git/refs*) hit=1 ;;
    esac
    q=$((q + 1))
  done
  [ "$hit" = 1 ] || return 1
  _mk_rm_branches; _mk_rm_emit deploy-push "$_rm_b"
}

# _mk_rm_gh_method VALUE RAW -- 0 when a gh api method VALUE writes (put,
# post, patch, delete in any case) or is computed (RAW holds $ or a
# backtick: fail closed).
_mk_rm_gh_method() {
  case "$2" in *[\$\`]*) return 0 ;; esac
  _mk_rm_lower "$1"
  case "$_rm_l" in put|post|patch|delete) return 0 ;; esac
  return 1
}

# _mk_rm_host_of TOKEN -- sets _rm_h to the host a [user@]host[:...] or
# (rsync|ssh|scp|sftp)://[user@]host[:port][/...] token names (user@ split
# at the last @ before the host, [ ] around it removed, one trailing dot
# dropped), and _rm_shape to 1 when it has the remote form (a colon after
# the host, or a URL), 0 for a bare word.
_mk_rm_host_of() {
  local u="$1" pre
  _rm_h=""; _rm_shape=0
  case "$u" in
    [Rr][Ss][Yy][Nn][Cc]://*|[Ss][Ss][Hh]://*|[Ss][Cc][Pp]://*|[Ss][Ff][Tt][Pp]://*)
      u="${u#*://}"; u="${u%%/*}"; _rm_shape=1 ;;
  esac
  case "$u" in
    *\[*\]*)
      pre="${u%%\[*}"
      case "$pre" in ''|*@) ;; *) _rm_h="${u%%:*}"; _rm_h="${_rm_h##*@}" ;; esac
      if [ -z "$_rm_h" ]; then
        _rm_h="${u#*\[}"; _rm_h="${_rm_h%%\]*}"
        case "${u#*\]}" in :*) _rm_shape=1 ;; esac
      fi ;;
    *)
      pre="${u%%:*}"; _rm_h="${pre##*@}"
      case "$u" in *:*) _rm_shape=1 ;; esac ;;
  esac
  _rm_h="${_rm_h%.}"
}

# _mk_rm_host_target NAME POS -- sets _rm_t to host:<configured spelling>
# when NAME is a configured host (case-insensitive), or, with "*" in the
# hosts and POS=1 (a target position), host:<name in lower case> for any
# host-shaped NAME. Exit 1 when neither.
_mk_rm_host_target() {
  local h star=0 nc=0 _f IFS='
'
  _rm_t=""
  [ -n "$1" ] || return 1
  case $- in *f*) _f=1 ;; *) _f=0 ;; esac
  set -f
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  for h in $MK_REMOTE_HOSTS; do
    if [ "$h" = '*' ]; then star=1; continue; fi
    if [[ $1 == "$h" ]]; then _rm_t="host:$h"; break; fi
  done
  [ "$nc" = 1 ] || shopt -u nocasematch
  [ "$_f" = 1 ] || set +f
  if [ -z "$_rm_t" ] && [ "$star" = 1 ] && [ "${2:-0}" = 1 ]; then
    case "$1" in
      *[![:alnum:]._-]*) ;;
      *) _mk_rm_lower "$1"; _rm_t="host:$_rm_l" ;;
    esac
  fi
  [ -n "$_rm_t" ]
}

# _mk_rm_lower TEXT -- sets _rm_l to TEXT with A-Z lowered, independent of
# locale and nocasematch. TEXT without an upper-case letter is copied; a
# long one (> 64 bytes; the loop below is quadratic: 2026-11-11, a 60 KB
# word took seconds) goes through one tr, falling back to the loop when tr
# fails or prints a different length.
_mk_rm_lower() {
  local s="$1" c p up=ABCDEFGHIJKLMNOPQRSTUVWXYZ lo=abcdefghijklmnopqrstuvwxyz
  case "$s" in *[ABCDEFGHIJKLMNOPQRSTUVWXYZ]*) ;; *) _rm_l="$s"; return 0 ;; esac
  if [ "${#s}" -gt 64 ]; then
    _rm_l="$(printf '%s.' "$s" | LC_ALL=C tr "$up" "$lo")"
    _rm_l="${_rm_l%.}"
    [ "${#_rm_l}" = "${#s}" ] && return 0
  fi
  _rm_l=""
  while [ -n "$s" ]; do
    c="${s%"${s#?}"}"; s="${s#?}"
    p="${up%%"$c"*}"
    [ "${#p}" -lt 26 ] && c="${lo:${#p}:1}"
    _rm_l="$_rm_l$c"
  done
}

# _mk_rm_rsh RAWVALUE -- 0 when an rsync -e / --rsh value is one plain word
# (no quote left after one surrounding pair, no backslash, $ or backtick).
_mk_rm_rsh() {
  local v="$1"
  case "$v" in \'?*\'|\"?*\") v="${v:1:${#v}-2}" ;; esac
  case "$v" in ''|*[\'\"\\\$\`[:space:]]*) return 1 ;; esac
  return 0
}

# _mk_rm_net TOOL I -- ssh, scp, sftp or rsync at token I. Hosts: a token
# naming a configured host in any position ([user@]host[:path], a URL,
# Hostname=host as an -o value), or with "*" any host-shaped name in a
# target position (ssh/sftp destination, a remote host:path operand, an -o
# Hostname). Then the exemptions (file header), unless MK_REMOTE_NO_EXEMPT=1.
_mk_rm_net() {
  local tool="$1" k=$(($2 + 1)) t r c m o val vr vl fl xl dest=-1 rk=-1 lastop=-1 flagx=0 ocmd=""
  local noex=0 dd=0 hosts="" pos u hb lasthb=0 dshape=0 rc dry=0 hl star=0 nc=0 nl='
'
  # Short options: with a value, without one, and those that end every
  # exemption (ssh(1), scp(1), sftp(1), rsync(1)); for scp, sftp and rsync
  # an unknown option letter ends it too.
  case "$tool" in
    ssh) vl=BbcDEeFIiJLlmOoPpQRSWw; fl=46AaCfGgKkMNnqsTtVvXxYy; xl=F ;;
    scp) vl=cDFiJloPSX; fl=346ABCOpqRrTv; xl=FSo ;;
    sftp) vl=BbcDFiJloPRSsX; fl=46AaCfNpqrv; xl=bDFosS ;;
    *) vl=efTBM; fl=avzrlptgoDHAXxSWucdRqnPhimOJEkKLCIyUN8F46sb; xl=M ;;
  esac
  # A NAME=value word before the tool (RSYNC_RSH=..., LD_PRELOAD=...) can
  # change what it runs: no exemption.
  m=0
  while [ "$m" -lt "$2" ]; do
    case "${w[m]}" in [A-Za-z_]*=*) noex=1 ;; esac
    m=$((m + 1))
  done
  # Operands: the destination, the remote command start (ssh), the last one.
  # ssh takes options after the destination too, up to the remote command.
  while [ "$k" -lt "$n" ]; do
    t="${w[k]}"; r="${raw[k]}"
    if [ "$dd" = 0 ]; then
      case "$r" in '#'*) break ;; esac
      case "$t" in *[\<\>\&]*)
        rc=0; _mk_rm_redir "$t" || rc=$?
        case "$rc" in 0) k=$((k + 1)); continue ;; 2) k=$((k + 2)); continue ;; esac ;;
      esac
      case "$t" in
        --) dd=1; k=$((k + 1)); continue ;;
        --?*)
          if [ "$tool" = rsync ]; then
            case "$t" in --dry-run) dry=1 ;; --dry-run*|--no-dry-run*) dry=0 ;; esac
            o="${t%%=*}"
            case "$MK_RM_RSYNC_VAL" in
              *" $o "*)
                case "$o" in --rsync-path|--remote-option) noex=1 ;; esac
                if [ "$o" = "$t" ]; then k=$((k + 1)); vr="${raw[k]:-}"; else vr="${r#*=}"; fi
                if [ "$o" = --rsh ]; then _mk_rm_rsh "$vr" || noex=1; fi ;;
              *) case "$MK_RM_RSYNC_FLAG" in *" $t "*) ;; *) noex=1 ;; esac ;;
            esac
          fi
          k=$((k + 1)); continue ;;
        -?*)
          [ "$tool" = rsync ] && [ "$t" = -n ] && dry=1
          m=1
          while [ "$m" -lt "${#t}" ]; do
            c="${t:m:1}"
            case "$xl" in *"$c"*) noex=1 ;; esac
            case "$c" in N|G|V) [ "$tool" = ssh ] && flagx=1 ;; esac
            case "$vl" in
              *"$c"*)
                val="${t:m+1}"; vr="${r#-*"$c"}"
                if [ -z "$val" ]; then k=$((k + 1)); val="${w[k]:-}"; vr="${raw[k]:-}"; fi
                case "$tool$c" in
                  sshO) ocmd="$val" ;;
                  sshQ) flagx=1 ;;
                  rsynce) _mk_rm_rsh "$vr" || noex=1 ;;
                esac
                break ;;
            esac
            case "$fl" in *"$c"*) ;; *) [ "$tool" = ssh ] || noex=1 ;; esac
            m=$((m + 1))
          done
          k=$((k + 1)); continue ;;
      esac
    fi
    if [ "$tool" = ssh ] && [ "$dest" -ge 0 ]; then rk="$k"; break; fi
    [ "$dest" -ge 0 ] || dest="$k"
    lastop="$k"
    k=$((k + 1))
  done
  # Hosts. A configured host anywhere inside a token (as written, quotes
  # included: user@, a:b@, [..], a trailing dot, Hostname=) is a target; with
  # "*" a host-shaped name in a target position. Every token is looked at, so
  # an ssh -o naming a command option ends the exemptions wherever it stands,
  # and so does a computed word ($, backtick) among scp/sftp/rsync arguments
  # or ssh options, or a remote path holding $ ` ( ) ; | & { } < > \.
  hl=" ${MK_REMOTE_HOSTS//$nl/ } "
  case "$hl" in *" * "*) star=1 ;; esac
  [ "${_rm_pre:-0}" = 1 ] || _mk_rm_pre
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  k=$(($2 + 1))
  while [ "$k" -lt "$n" ]; do
    t="${w[k]}"; r="${raw[k]}"; hb=0
    if [ "$tool" != ssh ] || [ "$rk" -lt 0 ] || [ "$k" -lt "$rk" ]; then
      case "$r" in *[\$\`]*) noex=1 ;; esac
    fi
    u="${t#-o}"; u="${u#[\"\']}"; u="${u%[\"\']}"
    case "$u" in
      RemoteCommand*|LocalCommand*|PermitLocalCommand*|ProxyCommand*) noex=1 ;;
    esac
    case "$u" in
      Hostname=*) _rm_h="${u#*=}"; pos=1; _rm_shape=1 ;;
      *)
        _rm_h="${_ph[k]}"; _rm_shape="${_ps[k]}"; pos=0
        case "$tool" in
          ssh) [ "$k" = "$dest" ] && pos=1 ;;
          sftp) { [ "$k" = "$dest" ] || [ "$_rm_shape" = 1 ]; } && pos=1 ;;
          *) [ "$_rm_shape" = 1 ] && pos=1 ;;
        esac ;;
    esac
    [ "$k" = "$dest" ] && dshape="$_rm_shape"
    _rm_nh="${_pn[k]}"
    if [ -n "$_rm_nh" ]; then
      hb=1
      for u in $_rm_nh; do
        case "$hosts " in *" $u "*) ;; *) hosts="$hosts $u" ;; esac
      done
    fi
    if [ "$star$pos" = 11 ] && [ -n "$_rm_h" ] && _mk_rm_host_target "$_rm_h" 1; then
      hb=1
      case "$hosts " in *" $_rm_t "*) ;; *) hosts="$hosts $_rm_t" ;; esac
    fi
    # With "*" (I1, p12): a destination the shell computes ($H, "$H",
    # root@$H, $(cat h), a backtick, a * or ? glob) names a host no text can
    # check: the target host:(computed), which is not host-shaped, so no
    # window ever holds it (mk_remote_target_valid) and the model is told to
    # spell the host literally. A configured host list keeps the text limit
    # (README, Limitations).
    if [ "$star$pos" = 11 ]; then
      case "$r" in
        *[\$\`*?]*)
          hb=1
          case "$hosts " in *" host:(computed) "*) ;; *) hosts="$hosts host:(computed)" ;; esac ;;
      esac
    fi
    # A remote-form operand names a host even when it is not configured; its
    # path must not compute or chain anything.
    if [ "$_rm_shape" = 1 ] && [ -n "$_rm_h" ]; then
      hb=1
      case "$r" in *[\$\`\(\)\;\|\&\{\}\<\>\\]*) noex=1 ;; esac
    fi
    [ "$k" = "$lastop" ] && lasthb="$hb"
    k=$((k + 1))
  done
  [ "$nc" = 1 ] || shopt -u nocasematch
  [ -n "$hosts" ] || return 0
  if [ "${MK_REMOTE_NO_EXEMPT:-0}" != 1 ] && [ "$noex" = 0 ]; then
    case "$tool" in
      ssh)
        if [ "${_rm_piped:-0}" = 0 ] && case "$_rm_seg" in *'<'*) false ;; *) true ;; esac; then
          if [ "$rk" -lt 0 ]; then
            [ "$flagx" = 1 ] && return 0
            case "$ocmd" in check|exit) return 0 ;; esac
          else
            _mk_rm_readonly "${raw[*]:rk}" && return 0
          fi
        fi ;;
      *)
        # Only when the raw command is one segment naming no remote shell
        # (_rm_dlok, set by mk_remote_scan).
        if [ "${_rm_dlok:-0}" != 1 ]; then :;
        elif [ "$tool" = rsync ] && [ "$dry" = 1 ]; then return 0
        elif [ "$tool" = sftp ] && [ "$dshape" = 0 ]; then :;
        elif [ "$lastop" -gt "$dest" ] && [ "$dest" -ge 0 ] && [ "$lasthb" = 0 ]; then
          return 0
        fi ;;
    esac
  fi
  _mk_rm_emit remote-mutate "$hosts"
}

# _mk_rm_readonly RCMD -- 0 when an ssh remote command is read-only: one
# segment (_mk_cf_oneseg), none of $ ` ( ) < > & \ (byte-wise under the
# _mk_cf_ctype_ok locale gate; a $ the local shell, or a shell around ssh,
# expands can carry ; into the remote shell, and whether it sits in single
# quotes cannot be told under heredocs, # comments or bash -c / eval, so
# ssh h 'cat $HOME/x' is labelled too), quotes that close inside it (a
# segment cut inside quotes, ssh h 'ls; rm -rf x', is never exempt), and a
# first word, or first-second (first-second-third) words, in the list.
_mk_rm_readonly() {
  local r="$1" list nl='
'
  [ -n "$r" ] || return 1
  _mk_cf_oneseg "$r" || return 1
  _mk_cf_ctype_ok "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" || return 1
  local LC_ALL=C
  case "$r" in *[\$\`\(\)\<\>\&\\]*) return 1 ;; esac
  # Every quote closes inside it (no backslash is left to escape one): one
  # regex, linear (2026-11-11: the former ${r//[!\'\"]/} walk was quadratic,
  # 0.46 s on a 4 KB word). A regex error is not a match (not read-only).
  [[ $r =~ $MK_RM_QUOTES_OK ]] || return 1
  r="${r//\'/}"; r="${r//\"/}"
  # shellcheck disable=SC2086  # words of the remote command; globbing is off (caller)
  set -- $r
  list=" $MK_RM_READONLY ${MK_REMOTE_READONLY//$nl/ } "
  case "$list" in
    *" $1 "*|*" $1-${2:-} "*|*" $1-${2:-}-${3:-} "*) return 0 ;;
  esac
  return 1
}

# _mk_rm_k8s TOOL I -- kubectl or helm at token I with a mutating subcommand
# anywhere after it (as careful.sh matches kubectl delete): k8s-mutate,
# target k8s:<--context / --kube-context> or k8s. kubectl diff in the
# subcommand position (after global options it knows) is not a change.
# --dry-run=client|server is exempt only as the last --dry-run* word before
# -- or a # comment, right after a non-option word or an --opt=value word
# (after any other option it may be that option's value: fail closed), and
# never for exec or cp.
_mk_rm_k8s() {
  local tool="$1" k=$(($2 + 1)) t r prev ctx="" mut=0 dry=0 stop=0 nodry=0 unk=0 list
  if [ "$tool" = kubectl ]; then list="$MK_RM_K8S_MUT"; else list="$MK_RM_HELM_MUT"; fi
  while [ "$k" -lt "$n" ]; do
    case "${w[k]}" in
      -*=*) k=$((k + 1)) ;;
      -*)
        case "$MK_RM_K8S_VALOPT" in *" ${w[k]} "*) k=$((k + 2)) ;; *) unk=1; break ;; esac ;;
      *) break ;;
    esac
  done
  [ "$tool" = kubectl ] && [ "${w[k]:-}" = diff ] && return 0
  # A computed subcommand may mutate: k8s (fail closed, no exemption). After
  # an option it does not know (which may or may not take a value), any
  # computed word after the tool word may be the subcommand.
  if [ "$unk" = 1 ]; then k=$(($2 + 1)); fi
  while [ "$k" -lt "$n" ]; do
    case "${raw[k]}" in *[\$\`\*\?\[]*) _mk_rm_emit k8s-mutate k8s; return 0 ;; esac
    case "$unk${w[k]}" in 1*|0-*) ;; *) break ;; esac
    k=$((k + 1))
  done
  k=$(($2 + 1)); prev="$tool"
  while [ "$k" -lt "$n" ]; do
    t="${w[k]}"; r="${raw[k]}"
    case "$t" in
      --context|--kube-context) ctx="${w[k + 1]:-}" ;;
      --context=*|--kube-context=*) ctx="${t#*=}" ;;
    esac
    case "$list" in
      *" $t "*)
        mut=1
        case "$t" in exec|cp) nodry=1 ;; esac ;;
    esac
    if [ "$stop" = 0 ]; then
      case "$r" in '#'*) stop=1 ;; esac
      [ "$t" = -- ] && stop=1
    fi
    if [ "$stop" = 0 ]; then
      case "$t" in
        --dry-run*|--no-dry-run*)
          dry=0
          case "$t" in
            --dry-run=client|--dry-run=server)
              case "$prev" in -*=*|[!-]*) dry=1 ;; esac ;;
          esac ;;
      esac
    fi
    prev="$t"
    k=$((k + 1))
  done
  [ "$mut" = 1 ] || return 0
  if [ "$dry" = 1 ] && [ "$nodry" = 0 ] && [ "${MK_REMOTE_NO_EXEMPT:-0}" != 1 ]; then return 0; fi
  _mk_rm_emit k8s-mutate "k8s${ctx:+:$ctx}"
}

# _mk_rm_runbook -- the segment runs a file under runbooksDir: as its first
# word (after NAME=value assignments), or as the first non-option word after
# bash, sh, zsh, source or ".". The path is taken relative to the root after
# dropping $PWD/ and $MK_ROOT/, doubled slashes and ./ parts. Target from
# mk_remote_runbook_target; a path holding /<runbooksDir>/ elsewhere, a ..
# part, an unreadable file or the fork budget gives runbook:<path>@unreadable
# (never valid, so never covered).
_mk_rm_runbook() {
  local p=0 t tg rel rb="$MK_REMOTE_RUNBOOKS_DIR" tab=$'\t' p1='/' p2='//' pd='/./' nl='
'
  while [ "$p" -lt "$n" ]; do
    case "${w[p]}" in
      [A-Za-z_]*=*) case "${w[p]%%=*}" in *[!A-Za-z0-9_]*) break ;; esac; p=$((p + 1)) ;;
      *) break ;;
    esac
  done
  # A plain sudo or env (no option, no assignment) before the invocation.
  case "${w[p]:-}" in sudo|env) case "${w[p + 1]:-}" in -*|[A-Za-z_]*=*|'') ;; *) p=$((p + 1)) ;; esac ;; esac
  case "${w[p]:-}" in
    bash|sh|zsh|source|.|*/bash|*/sh|*/zsh)
      p=$((p + 1))
      while case "${w[p]:-}" in -*) true ;; *) false ;; esac; do p=$((p + 1)); done ;;
  esac
  t="${w[p]:-}"
  # Cheap test first (the last part of runbooksDir survives // and ./).
  case "$t" in *"${rb##*/}"*) ;; *) return 0 ;; esac
  # shellcheck disable=SC2016  # the literal word $PWD, as written in the command
  case "$t" in
    '$PWD/'*|'${PWD}/'*|'$PWD}/'*|'"$PWD"/'*|'"${PWD}"/'*) t="${t#*/}" ;;
  esac
  while :; do case "$t" in *//*) t="${t//$p2/$p1}" ;; *) break ;; esac; done
  while :; do case "$t" in */./*) t="${t//$pd/$p1}" ;; *) break ;; esac; done
  case "$t" in "$MK_ROOT"/*) t="${t#"$MK_ROOT"/}" ;; esac
  while :; do case "$t" in ./*) t="${t#./}" ;; *) break ;; esac; done
  case "$t" in
    "$rb"/?*) rel="$t" ;;
    */"$rb"/?*) _mk_rm_emit runbook "runbook:$rb/${t#*/"$rb"/}@unreadable"; return 0 ;;
    *) return 0 ;;
  esac
  case "/$rel/" in */../*) _mk_rm_emit runbook "runbook:$rel@unreadable"; return 0 ;; esac
  # One hash per path per scan (_rm_rb_cache, a scan local: lines
  # "<path><tab><target>"); past the fork budget @unreadable (fail closed).
  case "${_rm_rb_cache:-}" in
    *"$nl$rel$tab"*) tg="${_rm_rb_cache#*"$nl$rel$tab"}"; tg="${tg%%"$nl"*}" ;;
    *)
      if _mk_rm_fork && tg="$(mk_remote_runbook_target "$rel")"; then :; else tg="runbook:$rel@unreadable"; fi
      _rm_rb_cache="${_rm_rb_cache:-$nl}$rel$tab$tg$nl" ;;
  esac
  _mk_rm_emit runbook "$tg"
}

# _mk_rm_patterns SEGMENTS -- careful.patterns entries with a target, matched
# per segment as mk_careful_project matches (grep -Ei; a regex grep rejects
# is off). Label column: the pattern's label.
_mk_rm_patterns() {
  local list idx lab tgt re out seg
  case "$MK_CAREFUL_PATTERNS_JSON" in *'"target"'*) ;; *) return 0 ;; esac
  list="$(printf '%s' "$MK_CAREFUL_PATTERNS_JSON" | jq -r 'to_entries[] | select(.value.target != null) | "\(.key) \(.value.label) \(.value.target)"' 2>/dev/null)" ||
    { printf 'unparsed\t\t\n'; return 0; }
  while read -r idx lab tgt; do
    [ -n "$idx" ] || continue
    re="$(_mk_cf_pattern "$idx" match)" || { printf 'unparsed\t\t\n'; continue; }
    out="$(printf '%s\n' "$1" | grep -Ei -- "$re" 2>/dev/null)" || continue
    while IFS= read -r seg; do
      printf '%s\t%s\t%s\n' "$lab" "pattern:$tgt" "$seg"
    done <<EOF
$out
EOF
  done <<EOF
$list
EOF
}
