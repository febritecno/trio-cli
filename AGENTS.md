# AGENTS.md

Guide for AI coding agents working on trio-cli. Read this first, then [RULES.md](RULES.md). Open work is in [TODO.md](TODO.md).

## What this is

`trio` is a single static binary written in Zig 0.16. From one config it generates three role agents (builder, scout, advisor) for AI coding tools, so a session runs on three models. It writes agent files in each tool's own format and tracks what it wrote so it can clean up.

## Layout

| Path | What |
|---|---|
| `src/main.zig` | The whole program: context, files, state, config, YAML and TOML writers, targets, commands, CLI parsing |
| `defaults/config.json` | Default config, compiled into the binary |
| `defaults/prompts/*.md` | Default role prompts (builder, scout, advisor), compiled in |
| `defaults/other-prompt.md` | Prompt for agents trio does not support, printed by `trio prompt` |
| `build.zig` | Build, embeds the files under `defaults/` |
| `test/smoke.sh` | End-to-end tests against the built binary |
| `install.sh` | One-line installer, checks `SHA256SUMS` |
| `.github/workflows/` | Release: a pushed tag builds four binaries |

## Commands

```bash
zig build -Drelease=true      # binary at zig-out/bin/trio
zig build test                # unit tests
sh test/smoke.sh              # end-to-end, needs the release build first
zig-out/bin/trio --help
```

All three checks must pass before a commit.

## How it works

- **Targets** are an enum in `src/main.zig`. `Target.spec()` says where a tool's agent files go (global and project folder), the extension, the format (markdown or TOML) and which frontmatter keys it takes. Only Claude Code and OpenCode also have a default-agent setting.
- **Config** is `~/.config/trio-cli/config.json` (`TRIO_HOME` overrides it). `targets.<id>` holds `enabled`, `scope` (`user` or `project`), `dir` and `setDefault`. `roles.<role>` holds name, description, prompt file, `models.<id>` and `frontmatter.<id>`.
- **State** is `state.json` next to the config. It maps every file trio wrote to its hash, and remembers the previous default agent. Cleanup of renamed roles, disabled targets and changed scope is driven by it.
- **CLI selection**: `--<agent>`, `--all`, `--project`, `--dir <folder>`, `-g`. They are parsed in `run()` into a `Selection`, and `applySelection()` edits the config before `applyConfig()` writes the files.
- **Older configs** may lack newer targets. `mergeTargetDefaults()` copies the built-in block, models and frontmatter for a target when it is turned on. A missing model falls back to `inherit`.

## Supported targets

Claude Code, OpenCode, Cursor, GitHub Copilot, Gemini CLI, Factory Droid, Kilo Code, Codex. The formats for the last six come from public docs and are not tested against the real tools.

Not supported on purpose: Windsurf, Cline, Antigravity, Hermes, OpenClaw, Roo Code, Oh My Pi, Trae, Kimi, Pi, Vibe. There is no confirmed file-based subagent with its own model. `trio prompt` covers them.

## Adding a target

1. Add a variant to `Target` and an entry in `Target.spec()`.
2. Add `targets.<id>` (`enabled: false`), `models.<id>` per role, and any `frontmatter.<id>` to `defaults/config.json`.
3. Add the flag to the help text and the table in `README.md`.
4. Add a smoke test that checks the written file.

Only add a target after its format is confirmed from official docs.

## Releasing

Only when the user asks. Bump `version` in `src/main.zig` and the version in `README.md`, run the three checks, commit, push, then `git tag vX.Y.Z && git push origin vX.Y.Z`. Never reuse or move an existing tag.
