# memokit

memokit is a Claude Code plugin that enforces a small working model for AI-assisted development. The orchestrator (your main session) never writes production code; a Sonnet `memokit:coder` subagent does, and an Opus `memokit:reviewer` gates every slice before it counts as done. Session rituals keep `docs/STATE.md` current, and a context budget triggers a measured, autonomous handoff before a session grows too expensive.

This is personal infrastructure shared as-is. MIT licensed, no support guarantee.

## What's inside

| Kind | Name | What it does |
|---|---|---|
| Hook | `guard-edit.sh` | PreToolUse: blocks the main session from writing under the guarded dirs (Edit/Write and Bash write constructs). |
| Hook | `guard-subagent-authority.sh` | PreToolUse: blocks subagents from committing, merging, rewriting history, touching the remote, or delegating. |
| Hook | `inject-rules.sh` | UserPromptSubmit: re-injects the core rules (plus your `rules.md`) and keyword-gated skill hints. |
| Hook | `session-start.sh` | SessionStart: injects `docs/STATE.md`, tracked docs, health-script summary and a settings risk scan. |
| Hook | `check-state-stale.sh` | Stop: warns when guarded dirs changed but `docs/STATE.md` did not. |
| Hook | `check-context-budget.sh` | Stop: when the context passes the budget, tells the AI to hand off on its own. |
| Hook | `check-subagent-background.sh` | SubagentStop: stops a subagent from returning while background work it started is still running. |
| Hook | `precompact-handoff.sh` | PreCompact: steers the compaction summary toward what a handoff needs. |
| Agent | `memokit:coder` | Writes production code and tests, one slice at a time, test-first. |
| Agent | `memokit:reviewer` | Adversarial review of each coder slice. |
| Skill | `/memokit:init` | Sets memokit up in a repo (new project or migration from per-repo hooks). |
| Skill | `/memokit:handoff` | Writes the handoff and verifies it by measurement. |
| Skill | `/memokit:resume` | Picks up from `docs/STATE.md` in a new session. |
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

## Overlays

Project-specific rules live in `.claude/memokit/`:

| File | Read by |
|---|---|
| `rules.md` | `inject-rules.sh`, on every prompt |
| `coder.md` | `memokit:coder`, as its first step |
| `reviewer.md` | `memokit:reviewer`, as its first step |
| `handoff.md` | `/memokit:handoff`, after the generic steps |
| `resume.md` | `/memokit:resume`, after the generic steps |

Precedence: overlays only add and narrow. They cannot loosen the plugin's invariants: subagents cannot touch git history, the orchestrator cannot write to guarded dirs, and nothing is called done without evidence. A loosening attempt is ineffective because the hooks block it anyway.

## Context budget

Every turn re-sends the whole context, so cost grows roughly with its square. When the context passes `contextBudget.limitTokens`, the Stop hook tells the AI to decide by itself, without asking you:

1. Finish the current work, then hand off (if it closes in a few turns), or hand off now (if the remaining work is long or you are at a natural stopping point).
2. Tell you in one line which it chose and why.
3. Run `/memokit:handoff` completely, then verify the handoff by measurement.
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
| `MEMOKIT_NO_INIT_HINT=1` | Silences the "run `/memokit:init`" hint. Without it the hint is added on every SessionStart (startup, resume, clear, compact) in a git work tree that has no `.claude/memokit.json` and no legacy `.claude/hooks/`. |
| `MEMOKIT_HOOK_DEBUG=1` | Each hook dumps the payload it received to `$TMPDIR/memokit-<hash>-hook-<name>.json` (`/tmp` if `TMPDIR` is unset). |

Troubleshooting:
- **Guards deny everything:** `jq` is missing or `.claude/memokit.json` is invalid. The guards fail closed, so the session cannot repair the config itself. Install jq, or fix `.claude/memokit.json` by hand (or set `MEMOKIT_GUARD_OFF=1` in `.claude/settings.local.json` `env` and start a new session to fix it there); the denial message names the cause.
- **No hooks fire:** the project has no `.claude/memokit.json`, or the plugin is disabled in `settings.json`.

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

## Türkçe

memokit, Claude Code için bir çalışma modeli plugin'idir: ana oturum (orkestratör) üretim kodu yazmaz, kodu bir Sonnet alt ajanı (`memokit:coder`) yazar, her dilimi bir Opus gözden geçirici (`memokit:reviewer`) onaylar. Oturum ritüelleri `docs/STATE.md` dosyasını güncel tutar; bağlam bütçesi aşılınca yapay zekâ kendi kararıyla ölçülü bir handoff yapar.

memokit'i **proje başına** kurup etkinleştirin (projenin kök dizininde):

```
/plugin marketplace add tsrmehmet/memokit
/plugin install memokit@memokit
```

`/plugin install` penceresinde projeye özel bir kapsam seçin (kabukta: `claude plugin install memokit@memokit --scope local`). Manifest `"defaultEnabled": false` ayarladığı için kurulum tek başına yetmez, plugin kapalı kurulur ve `/memokit:init` çalışmaz. Projede etkinleştirin: `/plugin` menüsünden ya da kabukta `claude plugin enable memokit@memokit --scope local`. Etkinleştirilmemiş projelerde memokit kapalı kalır. `/memokit:init`, projenin `.claude/settings.json` dosyasına `enabledPlugins["memokit@memokit"] = true` yazar. Başka projeler hâlâ kendi depo-içi hook'larıyla çalışırken memokit'i kullanıcı düzeyinde (user level) etkinleştirmeyin: memokit'in ajan ve skill'leri o projelerin kendi coder/reviewer/handoff/resume'u ile yan yana görünür.

Ardından git deposunda `/memokit:init` çalıştırın; proje adı, etiket, dil ve korunan klasörleri sorar, `.claude/memokit.json` dosyasını yazar. Türkçe yanıt ve hook mesajları için `memokit.json` içinde `"language": "tr"` ayarlayın. Acil durumda korumaları kapatmak için `MEMOKIT_GUARD_OFF=1` değerini `.claude/settings.local.json` içindeki `env` bölümüne yazın ya da `claude`'u başlatmadan önce dışa aktarın. Kişisel bir altyapıdır, olduğu gibi paylaşılır; destek garantisi yoktur.

## License

MIT. See [LICENSE](LICENSE).
