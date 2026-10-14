Set up trio-cli for yourself. trio splits a coding session into three agents on three models: a builder that writes the code, a scout that only reads and reports, and an advisor that reviews at key moments. trio has no built-in support for you, so you will install it and write the three agent files in your own format.

Do these steps in order and stop to ask me if one is unclear.

1. Install the binary without applying anything:
   curl -fsSL https://raw.githubusercontent.com/febritecno/trio-cli/main/install.sh | TRIO_NO_APPLY=1 sh
   Make sure `trio` is on PATH (the installer puts it in ~/.local/bin).

2. Check whether you are already supported. Run `trio --help` and read the "Targets" line. If your tool is listed, run `trio init --<your-id>` and stop here.

3. Otherwise run `trio init` to write the default config, then read these files in the folder printed by `trio path`:
   - config.json: for each role (builder, scout, advisor) the agent name, the description, and the prompt file.
   - prompts/builder.md, prompts/scout.md, prompts/advisor.md: the system prompt of each role. In them, {{builder}}, {{scout}} and {{advisor}} stand for the agent names from config.json. Replace them with those names.

4. Find in YOUR OWN documentation how to define a custom agent, subagent or mode as a file: the folder (global and per project), the file format, and the keys for name, description, model, tools and permissions. If your tool cannot define separate agents with their own model, tell me that and stop. Do not invent a format.

5. Create three agents from the three roles:
   - builder: the main agent. Make it the default or primary agent if your tool allows that.
   - scout: read-only. Allow reading, searching and web lookups. Deny editing files and running commands.
   - advisor: no editing. Reading and read-only shell commands are fine.
   Use each role's description as the agent description and its prompt file as the agent's instructions. Write them globally (in my home directory) unless I said otherwise.

6. Models: use the models you already have available. If you can, pick a strong model for the advisor, a mid model for the builder and a fast cheap model for the scout. Otherwise leave the model unset, and tell me which models to set.

7. Never overwrite an existing file. If a file with the same name exists, stop and ask me.

8. When done, list every file you created or changed, so I can remove them later, and tell me how to start a session with the builder.
