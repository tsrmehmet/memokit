# memokit

memokit is a Claude Code plugin that enforces a small working model for AI-assisted development. The orchestrator (your main session) never writes production code; a Sonnet `memokit:coder` subagent does, and an Opus `memokit:reviewer` gates every slice before it counts as done. Session rituals keep `docs/STATE.md` current, and a context budget triggers a measured, autonomous handoff before a session grows too expensive.

This is personal infrastructure shared as-is. MIT licensed, no support guarantee.

## What's inside

| Kind | Name | What it does |
|---|---|---|
| Hook | `guard-edit.sh` | PreToolUse: blocks the main session from writing under the guarded dirs (Edit/Write and Bash write constructs), in the main checkout and in every git worktree of the repo (including Claude Code worktrees). |
| Hook | `guard-subagent-authority.sh` | PreToolUse: blocks subagents from committing, merging, rewriting history, touching the remote, or delegating. |
| Hook | `guard-destructive.sh` | PreToolUse: denies destructive Bash commands (force push, reset --hard, recursive rm, destructive SQL, kubectl/helm delete, …, plus project patterns) until the user approves with a single-use code. It also denies Edit/Write/MultiEdit/NotebookEdit to memokit's approval (grant) file, including through symlinks. |
| Hook | `inject-rules.sh` | UserPromptSubmit: re-injects the core rules (plus your `rules.md`) and keyword-gated skill hints. |
| Hook | `session-start.sh` | SessionStart: injects `docs/STATE.md`, tracked docs, health-script summary and a settings risk scan. |
| Hook | `check-state-stale.sh` | Stop: warns when guarded dirs changed but `docs/STATE.md` did not. |
| Hook | `check-context-budget.sh` | Stop: when the context passes the budget, tells the AI to hand off on its own. |
| Hook | `check-subagent-background.sh` | SubagentStop: stops a subagent from returning while background work it started is still running. |
| Hook | `check-subagent-scratch.sh` | SubagentStop: blocks (up to 3 times) a subagent that leaves a large temp footprint in the session scratchpad, so it cleans up before returning. |
| Hook | `check-disk.sh` | PreToolUse/PostToolUse/PostToolUseFailure (Bash) and Stop: warns when one command drops free disk space by `disk.dropWarnGB`, warns when free space is below `disk.minFreeGB`, and at Stop points to `/memokit:sweep`. |
| Hook | `precompact-handoff.sh` | PreCompact: steers the compaction summary toward what a handoff needs. |
| Agent | `memokit:coder` | Writes production code and tests, one slice at a time, test-first. |
| Agent | `memokit:reviewer` | Adversarial review of each coder slice. |
| Skill | `/memokit:init` | Sets memokit up in a repo (new project or migration from per-repo hooks). |
| Skill | `/memokit:handoff` | Writes the handoff and verifies it by measurement. |
| Skill | `/memokit:resume` | Picks up from `docs/STATE.md` in a new session. |
| Skill | `/memokit:triage` | Clusters red/flaky tests by signature, classifies them with evidence, then drives one root cause to a red-before-green fix. |
| Skill | `/memokit:sweep` | Measures the stale temp leftovers earlier sessions left behind, asks, deletes the approved ones one literal `rm -rf` at a time and reports the freed space. |
| Doc | `WORKING-MODEL.md` | The shared rules the hooks, agents and skills refer to. |

## Install

Install and enable memokit **per project**, from the project's root:

```
/plugin marketplace add tsrmehmet/memokit
/plugin install memokit@memokit
```

In the `/plugin install` dialog pick a project-local scope (from a shell: `claude plugin install memokit@memokit --scope local`, which writes `.claude/settings.local.json`; that file must be git-ignored, because a migration needs a clean working tree). The plugin manifest sets `"defaultEnabled": false`, so install alone leaves memokit disabled (`"enabledPlugins": {"memokit@memokit": false}`) and `/memokit:init` cannot run yet. Enable it for this project: in the `/plugin` menu, or from a shell:

```
claude plugin enable memokit@memokit --scope local
```

memokit stays off in every project that has not enabled it. `/memokit:init` then writes `enabledPlugins["memokit@memokit"] = true` into the project's `.claude/settings.json`, so the project turns memokit on for everyone who clones it.

Do not enable memokit at user level while other projects still run their own per-repo hooks. The hooks stay silent without `.claude/memokit.json`, but the agents and skills (`memokit:coder`, `memokit:reviewer`, `/memokit:handoff`, `/memokit:resume`) would be listed next to those projects' own coder/reviewer/handoff/resume, and picking memokit's version skips the project rules that live in the legacy ones. Each of them stops on its own when `.claude/memokit.json` is missing, but that is a backstop, not the install model.

Requirements: bash, jq, git; macOS or Linux.

## Quick start

1. Open Claude Code in a git repository, install and enable memokit for it (see Install) and run `/memokit:init`.
2. It detects your stack and asks a short set of questions: project name, tag, language, guarded directories, and the docs to show at session start.
3. It writes `.claude/memokit.json` and overlay skeletons, creates `CLAUDE.md`, `docs/STATE.md` and `docs/DECISIONS.md` from templates if they are missing (it never overwrites an existing file), and registers the marketplace and plugin in `settings.json`.
4. Start a new session. Hooks are active only in projects that have `.claude/memokit.json`.

## Configuration

`.claude/memokit.json` (full schema: [`schema/memokit.schema.json`](schema/memokit.schema.json), example: [`examples/memokit.json`](examples/memokit.json)). Add a `$schema` line for editor completion and validation:

```json
{ "$schema": "https://raw.githubusercontent.com/tsrmehmet/memokit/main/schema/memokit.schema.json" }
```

| Field | Required | Default | Purpose |
|---|---|---|---|
| `version` | yes | none | Must be `1`. |
| `project.name` | yes | none | Shown in the session-start header. |
| `project.tag` | yes | none | Message tag, e.g. `ACME` gives `[ACME-...]` prefixes (2-10 chars, `A-Z0-9`, starts with a letter). |
| `language` | no | `en` | `en` or `tr`: language of hook messages and of the assistant's replies to you. |
| `guardedDirs` | no | `["src","tests"]` | Repo-relative directories the main session may not write to. |
| `contextBudget.limitTokens` | no | `300000` | Context size at which the handoff reminder starts (minimum 1000). |
| `stateStale.maxCommitsBehind` | no | `3` | Guarded-dir commits allowed after the last `docs/STATE.md` commit. |
| `sessionStart.docs` | no | `[]` | `"path — description"` lines shown at session start. |
| `sessionStart.healthScript` | no | none | Repo-relative script run with `--fast` at session start. |
| `hints.builtin` | no | all | Any of `debugging`, `decision`, `review`, `handoff`, `resume`, `graphify`. |
| `hints.custom[]` | no | `[]` | `{ "match": "<regex>", "text": "<hint>" }` project-specific keyword hints. |
| `graph.root` | no | none | Enables the code graph (see below): repo-relative directory the graph covers (`.` = whole repo). |
| `graph.maxCommitsBehind` | no | `20` | Commits under `graph.root` since the last refresh before the codebase-question hint says "refresh first". |
| `graph.refreshScript` | no | none | Repo-relative script that replaces the builtin refresh (run from the repo root; exit 0 = refreshed). |
| `scratch.agentMaxMB` | no | `1024` | New data (MB) a subagent may leave in the scratchpad before the SubagentStop gate blocks it. |
| `scratch.staleAfterHours` | no | `24` | Age after which a temp entry of an earlier session counts as stale. |
| `scratch.reportMinMB` | no | `500` | Stale temp size (MB) from which SessionStart reports leftovers. |
| `disk.minFreeGB` | no | `30` | Free-space floor (GB) that triggers the low-disk warning; `0` turns it off. |
| `disk.dropWarnGB` | no | `10` | Free-space drop (GB) during one Bash command that triggers a warning. |
| `careful.patterns[]` | no | `[]` | `{ "match": "<ERE>", "label": "<name>" }` destructive-command patterns added to the builtin set (case-insensitive, whole command). |

## Code graph (graphify)

With `graph` set in `.claude/memokit.json`, memokit keeps a graphify code graph in `graphify-out/` current:

- **At every handoff** `/memokit:handoff` runs `skills/handoff/scripts/memokit-graph.sh refresh` after its commit. It does nothing when no commit touched `graph.root` since the last refresh; otherwise it runs `graphify update <graph.root>` (code only, AST extraction, no LLM tokens) and moves the marker `graphify-out/.graph_commit` to `HEAD`. A failed refresh keeps the previous graph and is reported as a warning; it does not fail the handoff.
- **On a codebase question** ("where is", "who calls", …) the hint carries the measured staleness: fresh → query directly; more than `maxCommitsBehind` commits behind → refresh before answering.
- `graphify-out/` must be git-ignored; the refresh refuses otherwise. graphify does not read nested `.gitignore` files, so put build output and secrets under the root into a `.graphifyignore` at the repo root.

`/memokit:init` offers the graph with a measured recommendation. In a project without `graph`, the hint tells the AI to ask you before building one rather than building it on its own. `memokit-graph.sh status` prints the staleness (exit 0 fresh, 1 stale, 2 unknown, 3 no graph).

## Handoff notification

The last step of `/memokit:handoff` sends one line through Claude Code's `PushNotification` tool: "handoff ready, next: …" or "handoff not complete: …". The tool skips the push while you are at the terminal and reaches your phone when Remote Control is connected, so an autonomous handoff at the context budget tells you when to open a new session.

## Overlays

Project-specific rules live in `.claude/memokit/`:

| File | Read by |
|---|---|
| `rules.md` | `inject-rules.sh`, on every prompt |
| `coder.md` | `memokit:coder`, as its first step |
| `reviewer.md` | `memokit:reviewer`, as its first step |
| `handoff.md` | `/memokit:handoff`, after the generic steps |
| `resume.md` | `/memokit:resume`, after the generic steps |
| `triage.md` | `/memokit:triage`, as its first step |

Precedence: overlays only add and narrow. They cannot loosen the plugin's invariants: subagents cannot touch git history, the orchestrator cannot write to guarded dirs, and nothing is called done without evidence. A loosening attempt is ineffective because the hooks block it anyway.

## Context budget

Every turn re-sends the whole context, so cost grows roughly with its square. When the context passes `contextBudget.limitTokens`, the Stop hook tells the AI to decide by itself, without asking you:

1. Finish the current work, then hand off (if it closes in a few turns), or hand off now (if the remaining work is long or you are at a natural stopping point).
2. Tell you in one line which it chose and why.
3. Run `/memokit:handoff` completely, through its phone notification, then verify the handoff by measurement.
4. Only when every check passes, say the handoff is current and that "continue" is enough next session. If a check fails, fix and re-measure, or report what failed.

The reminder fires once when the budget is crossed and again every step of tokens after that. Environment variables (must be valid non-negative integers, otherwise the default applies; `MEMOKIT_CONTEXT_STEP` must be above zero):

| Variable | Effect |
|---|---|
| `MEMOKIT_CONTEXT_LIMIT` | Overrides `contextBudget.limitTokens`. |
| `MEMOKIT_CONTEXT_STEP` | Tokens between repeat reminders (default `100000`). |
| `MEMOKIT_CONTEXT_OFF=1` | Disables the context-budget reminder. |

## Kill switches and troubleshooting

Hooks read these from their environment, so set them in `.claude/settings.local.json` under `env`, or export them before launching `claude`. Exporting inside a Bash tool call does not reach the hooks.

```json
{ "env": { "MEMOKIT_GUARD_OFF": "1" } }
```

| Variable | Effect |
|---|---|
| `MEMOKIT_GUARD_OFF=1` | Emergency override: disables the write guard and the subagent authority guard. |
| `MEMOKIT_SUBAGENT_BG_OFF=1` | Disables the subagent background-work gate, so subagents can return while their background tasks still run. |
| `MEMOKIT_CONTEXT_OFF=1` | Disables the context-budget reminder. |
| `MEMOKIT_CAREFUL_OFF=1` | Disables the destructive-command guard. (`MEMOKIT_GUARD_OFF=1` disables it too.) |
| `MEMOKIT_SCRATCH_OFF=1` | Disables the subagent temp-footprint gate, and the SessionStart temp-leftover line and its cached total. |
| `MEMOKIT_DISK_OFF=1` | Disables the disk watch (drop warning, free-space floor, Stop message). |
| `MEMOKIT_TEMP_ROOT=<dir>` | Testing override of the temp root memokit inspects; for tests, do not set it in a real session. |
| `MEMOKIT_NO_INIT_HINT=1` | Silences the "run `/memokit:init`" hint. Without it the hint is added on every SessionStart (startup, resume, clear, compact) in a git work tree that has no `.claude/memokit.json` and no legacy `.claude/hooks/`. |
| `MEMOKIT_HOOK_DEBUG=1` | Each hook dumps the payload it received to `$TMPDIR/memokit-<hash>-hook-<name>.json` (`/tmp` if `TMPDIR` is unset). |

Troubleshooting:
- **Guards deny everything:** `jq` is missing or `.claude/memokit.json` is invalid. The guards fail closed, so the session cannot repair the config itself. Install jq, or fix `.claude/memokit.json` by hand (or set `MEMOKIT_GUARD_OFF=1` in `.claude/settings.local.json` `env` and start a new session to fix it there); the denial message names the cause.
- **No hooks fire:** the project has no `.claude/memokit.json`, or the plugin is disabled in `settings.json`.

## Temp space

Agents leave scratch copies behind and a full disk stops everything. `WORKING-MODEL.md` §7 gives the rules (copy only tracked and untracked-not-ignored files, one dedicated scratchpad directory per task, delete it before returning, end every report with `temp left: <size>`). Three things enforce them:
- a SubagentStop gate blocks a subagent that leaves `scratch.agentMaxMB` or more of new files in the scratchpad (`MEMOKIT_SCRATCH_OFF=1` disables it);
- a disk watch warns when one command eats `disk.dropWarnGB` or free space is below `disk.minFreeGB`, and SessionStart reports stale leftovers of at least `scratch.reportMinMB` and low disk (`MEMOKIT_DISK_OFF=1` disables the watch);
- `/memokit:sweep` measures stale leftovers, asks, and deletes the approved ones. The destructive-command guard lets a single simple `rm -rf` of a literal direct child of the current session scratchpad, or of a whole stale sibling temp entry, through without an approval code; every other recursive `rm` still needs one.

## Migrating from per-repo hooks

Run `/memokit:init` in a repo that has legacy `.claude/hooks/`. Migration mode refuses to run on a dirty working tree, then:
- extracts the constants from the old hooks (guarded dirs, tag, header, docs, custom hint patterns, rules text) into `memokit.json` and `rules.md`;
- moves project-specific parts of agents and skills into overlay files;
- replaces the shared CLAUDE.md sections with a pointer to `WORKING-MODEL.md`, keeping the project-specific parts;
- removes the old `.claude/hooks/`, `.claude/agents/`, `.claude/skills/handoff|resume` and the `settings.json` hook wiring;
- shows you the diff and does not commit without your approval. The result is a single commit.

To roll back, `git revert` that commit.

## Development

```
brew install bats-core shellcheck gitleaks
bats tests/
```

To try a local checkout: `/plugin marketplace add /path/to/memokit`.

Releases: `.claude-plugin/plugin.json` pins `version`, and `/plugin update` delivers nothing until that string changes. Every change to `hooks/`, `skills/`, `agents/` or `WORKING-MODEL.md` therefore bumps `version` in `.claude-plugin/plugin.json` and adds a `CHANGELOG.md` entry in the same change.

## Destructive commands

`guard-destructive.sh` denies a Bash command that matches a builtin pattern (`git push --force`/`-f`/`+ref`, `git reset --hard`, `git clean -f` (also with `-n`/`--dry-run`), `git branch -D` (also `-d -f`, `--delete --force`, `-df`), `git checkout -- .`/`git restore .` (`git restore --staged` alone is not blocked, nor is `git rm`), recursive `rm` outside `node_modules bin obj dist build .next coverage TestResults __pycache__ .pytest_cache`, `DROP`/`TRUNCATE`/`DELETE FROM` together with a SQL client (psql, pgcli, mysql, mariadb, sqlite3, sqlcmd), `dropdb`, `mysqladmin … drop`, `dotnet ef database drop`, `kubectl delete`, `helm uninstall|delete|del|un`, `docker system|volume prune`, `docker volume rm|remove`; docker global options are tolerated; unique abbreviations such as `git push --fo`, `git reset --ha` and `rm --rec` count, and the command names rm, git, kubectl, helm, docker and dotnet match in any case and with `.exe`) or a project pattern from `careful.patterns`. Quoted, escaped, prefixed and grouped spellings are matched as the command they run (`"rm" -rf x`, `r''m`, `\rm`, `sudo rm`, `timeout 5 rm`, `{rm,-rf,x}`, `(cd x && git reset --hard)`, `git push -f&`, zsh `/bin/rm(N)`), and a computed command word right before an rm-style recursive option (`$RM -rf x`, `/bin/r? -rf x`) counts as a recursive rm. A command longer than 64 KiB, or with more than 1000 distinct rm commands, is not checked but denied as `too-large` (write long files with the Write tool, or approve it). The deny message carries a 6-character code. To approve, start your next message with `onay <code>` or `approve <code>`; the AI then re-runs the exact same command once. A code is bound to the project and the exact command text and expires after 10 minutes. Edit, Write, MultiEdit and NotebookEdit to memokit's approval (grant) file are denied too, including through symlinks and in any letter case, so the AI cannot grant itself an approval; a Bash command naming that file in any case, also through a glob that keeps its name (`careful?grants`, `careful*grants`), is denied without a code, and so is a glob on a `memokit-` path in a temp location (`/tmp/memokit-*`, `$TMPDIR/memokit-*`) or next to `careful`; any other glob that may reach it (`careful*`, `../memokit-*`) is denied as `careful-state-glob`, which can be approved. Every deny message lists all labels the command matched.

It denies rather than asks because a hook's "ask" does not reliably prompt in auto mode or `claude -p`. It is an accident-prevention guardrail, not a sandbox, and the AI runs as your user. The approval code is derived from the project and the command text, so it is not a secret: it stops accidents, not an agent that deliberately works around it. Project patterns can only add to the builtin set. If another memokit guard also blocks the same command (a write to a guarded directory from the main session, git history commands from a subagent), an approval code does not help: that guard's rule applies.

Limitations: matching is on the command text only. A command name that exists only at run time is not seen (`$X push -f`, `$GIT reset --hard`, `$(printf %s r m) -rf x`, zsh `/bin/r(m|x) -rf x`, `$RM src -rf` with the option after an operand, SQL spelled `DROP${IFS}TABLE` or `DROP/**/TABLE`), nor is anything run from a script file, an alias or function, or a variable (`bash -c "$CMD"`). A shell that computes the grant file's path at run time (variables, `printf`) can still reach it: the approval code is an accident guard, not a security boundary against a deliberately adversarial agent. A glob on any `memokit-` path (e.g. `ls ../memokit-*`, which also matches memokit-NNN directories) asks for an approval code (`careful-state-glob`); spelling the path out avoids it. False positives are accepted and ask for an approval code: quotes are not parsed, so quoted text is matched like a command (a commit message mentioning `git push --force` or `rm -rf`), and a computed command word directly followed by an option made of rm's letters with `r`/`R` (`"$EDITOR" -R notes.md`, `ls *.log -R`, `tar -C "$d" -rvf a.tar`) counts as a recursive rm. A failing or silent tool in the check (awk, sed, grep, tr, jq) denies the command instead of letting it through: as `unparsed`, as `careful-state` (no approval possible) when the approval-file check itself cannot run, or with a static message when jq fails.

## Türkçe

memokit, Claude Code için bir çalışma modeli plugin'idir: ana oturum (orkestratör) üretim kodu yazmaz, kodu bir Sonnet alt ajanı (`memokit:coder`) yazar, her dilimi bir Opus gözden geçirici (`memokit:reviewer`) onaylar. Oturum ritüelleri `docs/STATE.md` dosyasını güncel tutar; bağlam bütçesi aşılınca yapay zekâ kendi kararıyla ölçülü bir handoff yapar.

memokit'i **proje başına** kurup etkinleştirin (projenin kök dizininde):

```
/plugin marketplace add tsrmehmet/memokit
/plugin install memokit@memokit
```

`/plugin install` penceresinde projeye özel bir kapsam seçin (kabukta: `claude plugin install memokit@memokit --scope local`). Manifest `"defaultEnabled": false` ayarladığı için kurulum tek başına yetmez, plugin kapalı kurulur ve `/memokit:init` çalışmaz. Projede etkinleştirin: `/plugin` menüsünden ya da kabukta `claude plugin enable memokit@memokit --scope local`. Etkinleştirilmemiş projelerde memokit kapalı kalır. `/memokit:init`, projenin `.claude/settings.json` dosyasına `enabledPlugins["memokit@memokit"] = true` yazar. Başka projeler hâlâ kendi depo-içi hook'larıyla çalışırken memokit'i kullanıcı düzeyinde (user level) etkinleştirmeyin: memokit'in ajan ve skill'leri o projelerin kendi coder/reviewer/handoff/resume'u ile yan yana görünür.

Ardından git deposunda `/memokit:init` çalıştırın; proje adı, etiket, dil, korunan klasörleri ve kod grafiğini (graphify) sorar, `.claude/memokit.json` dosyasını yazar. `graph` ayarlıysa her handoff kod grafiğini tazeler (yalnız kod, LLM yok); handoff'un son adımı telefonuna bildirim gönderir (Remote Control bağlıyken). Türkçe yanıt ve hook mesajları için `memokit.json` içinde `"language": "tr"` ayarlayın. Acil durumda korumaları kapatmak için `MEMOKIT_GUARD_OFF=1` değerini `.claude/settings.local.json` içindeki `env` bölümüne yazın ya da `claude`'u başlatmadan önce dışa aktarın. Kişisel bir altyapıdır, olduğu gibi paylaşılır; destek garantisi yoktur. Yıkıcı komutlar (force push, reset --hard, özyinelemeli rm, yıkıcı SQL, kubectl/helm delete ve projenin `careful.patterns` kalıpları) engellenir; onay için bir sonraki mesajınıza `onay <kod>` ile başlayın. Bu bir kaza önleme korkuluğudur, sandbox değildir: yalnızca komut metnine bakar. 64 KiB'tan uzun (ya da 1000'den fazla rm komutu içeren) bir komut denetlenmez, `too-large` olarak engellenir; uzun dosyaları Write aracıyla yazın ya da onay kodu verin. Kırmızı ve flaky testler için `/memokit:triage`.

## License

MIT. See [LICENSE](LICENSE).
