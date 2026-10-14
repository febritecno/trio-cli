# RULES.md

Rules for anyone, human or agent, who changes trio-cli. See [AGENTS.md](AGENTS.md) for the layout and commands.

## Safety: never lose the user's files

1. Never overwrite or delete a file trio did not write. A foreign file or a hand-edited one is copied to `<file>.trio-bak` first, and `disable` leaves it in place.
2. Back up a settings file once (`backupOnce`) before the first change. Do not rewrite it as a whole when a text edit is enough: `opencode.json` is JSONC, so comments and formatting must survive.
3. Every file trio writes must be recorded in `state.json`, so cleanup can find it. If you add a place trio writes to, make `disable` and `uninstall` remove it too.
4. `--dry-run` must write nothing: no files, no state, no config.
5. Never delete anything outside the folders the tool's spec names and the trio config folder.

## Correctness: do not guess

6. Do not write a file format you have not confirmed from the tool's official docs. If it cannot be confirmed, leave the tool out and say so in the README. A wrong file is worse than no file.
7. Mark any format taken from non-official sources as untested in `README.md`.
8. Defaults must be safe. A new target is `enabled: false` and its models are `inherit` until the user sets real ones.
9. Read-only roles stay read-only on every target. If a tool has no way to enforce it, the prompt must say so and the README must mention it.

## Behavior

10. Default scope is global. Project scope needs an explicit `--project` or `--dir`, and an absolute folder is stored, so running `trio` from another folder does not move agents.
11. A flag that names targets touches only those targets. On a fresh config it enables only them.
12. Fail with a clear message that says what to do. No silent fallbacks that change what gets written, except `inherit` for a missing model.
13. Keep old configs working. A new config key needs a default in code or in `mergeTargetDefaults`.

## Code

14. One binary, no runtime dependencies, no network calls except `install.sh`. Keep the binary small.
15. Keep `src/main.zig` readable: small functions, comments only for the reason behind non-obvious code. No dead code, no TODO comments (use `TODO.md`).
16. Handle every error. Do not discard one with `catch {}` unless losing it is harmless and a comment says why.
17. Do not add a dependency or a new file layer for something a few lines solve.

## Tests and docs

18. Every behavior change needs a case in `test/smoke.sh`. A bug fix needs a test that failed before the fix.
19. Before a commit: `zig build -Drelease=true && zig build test && sh test/smoke.sh`, all passing. Check the exit status, not just the last line of output.
20. Update `README.md`, the help text and `TODO.md` in the same commit as the change. The prompt in `README.md` must match `trio prompt` (a smoke test checks it).

## Git and releases

21. Small commits with a message that says what changed and why. Do not mix a feature with a version bump.
22. Do not push, tag or release unless the user asks. Never force-push, and never move or reuse a tag.
23. A new version needs both `version` in `src/main.zig` and the version in `README.md` bumped together.

## Working as an agent

24. Take the first unchecked item in `TODO.md`, finish it, check it off with the commit hash, then report. Do not start the next item without being asked.
25. Ask the user before a change that is large, spans several files in a new way, or is hard to undo.
26. Report what you verified and what you did not. Say so when a result is untested.
