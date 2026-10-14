# TODO

## For agents

Read [AGENTS.md](AGENTS.md) and [RULES.md](RULES.md) first. Then work on the items that are not checked (`- [ ]`), top to bottom. Do not start an item that is already checked.

1. Take the first unchecked item. Read the notes under it and the code it names before you change anything.
2. Build and test: `zig build -Drelease=true && zig build test && sh test/smoke.sh`. All three must pass.
3. Add a smoke test for the new behavior in `test/smoke.sh`, and update `README.md` and the help text in `src/main.zig`.
4. Change `- [ ]` to `- [x]` for that item and add the commit hash after it.
5. Commit with a message that says what changed. Do not push or tag unless the user asks.
6. Stop after one item unless the user said to continue. Report what you did and which item is next.

Rules: do not guess a tool's file format. If the docs do not confirm it, leave the tool out and write down why. Never overwrite a file trio did not write.

## Done

- [x] Single static binary in Zig, config in `~/.config/trio-cli`
- [x] Claude Code and OpenCode targets
- [x] `enable`, `disable`, `uninstall`
- [x] Cursor, Copilot, Gemini CLI, Factory Droid, Kilo Code and Codex targets
- [x] Target flags (`--<agent>`, `--all`), `--project`, `--dir <folder>`, `-g`
- [x] `trio prompt` for agents trio does not support

## Next

Ordered by value.

- [ ] **`trio doctor`**: check what `apply` wrote. Frontmatter parses, TOML parses, model id is not empty or `inherit` where the tool needs one, the folder is the one the tool reads. Exit non-zero on a problem. Cursor, Gemini, Codex, Droid and Kilo formats are untested against the real tools, so this is the main risk to close. Code: `Target.spec()` and `render` in `src/main.zig`.
- [ ] **Model presets**: `trio preset economy|balanced|max` fills `roles.*.models.<target>` for every enabled target in one go. Add `trio models` to list valid ids per target. New targets default to `inherit`, so the 3-model split only works after the user sets models by hand.
- [ ] **Global and folder at the same time**: scope is one value per target today. Allow a target to be installed globally and in one or more folders, with cleanup still driven by `state.json`.
- [ ] **`trio diff`**: show what `apply` would change, file by file, before writing. Better than `--dry-run`.
- [ ] **Custom roles**: `role_keys` is fixed to builder, scout and advisor. Let the config declare more roles (reviewer, tester) with their own prompt and models.
- [ ] **`trio update`**: replace the binary from the latest GitHub release, check `SHA256SUMS`, and say when a newer version exists.
- [ ] **More targets**: Roo Code (YAML modes), Mistral Vibe (TOML), Kimi CLI, Pi. Add each only after its format is confirmed from official docs.
- [ ] **`trio export` / `trio import`**: share config and prompts as one file or URL.
