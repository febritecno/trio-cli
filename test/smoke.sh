#!/bin/sh
# End-to-end checks against the built binary. Usage: test/smoke.sh [path-to-trio]
set -u
BIN=$(cd "$(dirname "${1:-zig-out/bin/trio}")" && pwd)/$(basename "${1:-zig-out/bin/trio}")
fails=0
ROOT=$(pwd)

new_home() {
  H=$(mktemp -d)
  export HOME="$H" TRIO_HOME="$H/trio-config"
  mkdir -p "$H/project"
  cd "$H/project" || exit 1
}
trio() { "$BIN" "$@" >/dev/null; }
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }
has() { grep -q -- "$2" "$1" 2>/dev/null; } # file pattern
check() { # description, command...
  desc=$1; shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
missing() { [ ! -e "$1" ]; }
same() { [ "$(cat "$1")" = "$2" ]; }

echo "apply generates agents for both targets"
new_home
trio apply
check "claude scout name"   has "$H/.claude/agents/scout.md" '^name: scout$'
check "claude scout model"  has "$H/.claude/agents/scout.md" '^model: haiku$'
check "claude scout tools"  has "$H/.claude/agents/scout.md" '^tools: Read, Grep, Glob, WebFetch, WebSearch$'
check "opencode mode"       has "$H/.config/opencode/agents/conductor.md" '^mode: primary$'
check "opencode model"      has "$H/.config/opencode/agents/conductor.md" '^model: opencode/claude-sonnet-5-5$'
check "role names filled"   has "$H/.config/opencode/agents/conductor.md" '`scout` subagent'
check "no template left"    sh -c "! grep -q '{{' '$H/.config/opencode/agents/conductor.md'"
check "opencode permission" has "$H/.config/opencode/agents/scout.md" '^  bash: deny$'

echo "claude default agent set, restored on remove"
new_home
mkdir -p "$H/.claude"
printf '{"model":"opus","agent":"mine"}' > "$H/.claude/settings.json"
trio apply
check "agent set"  has "$H/.claude/settings.json" '"agent": "conductor"'
check "model kept" has "$H/.claude/settings.json" '"model": "opus"'
trio remove
check "agent restored" has "$H/.claude/settings.json" '"agent": "mine"'
check "agent file gone" missing "$H/.claude/agents/conductor.md"
check "config survives" test -e "$H/trio-config/config.json"

echo "opencode default is opt-in and JSONC survives"
new_home
mkdir -p "$H/.config/opencode"
jsonc='{
  // my comment
  "model": "x/y",
  "provider": { "a": 1, },
}'
printf '%s\n' "$jsonc" > "$H/.config/opencode/opencode.json"
trio apply
check "untouched while off" same "$H/.config/opencode/opencode.json" "$jsonc"
trio set targets.opencode.setDefault true
expected='{
  "default_agent": "conductor",
  // my comment
  "model": "x/y",
  "provider": { "a": 1, },
}'
check "inserted" same "$H/.config/opencode/opencode.json" "$expected"
trio set targets.opencode.setDefault false
check "removed" same "$H/.config/opencode/opencode.json" "$jsonc"

echo "foreign file is backed up"
new_home
mkdir -p "$H/.claude/agents"
printf 'hand written' > "$H/.claude/agents/scout.md"
trio apply
check "backup" same "$H/.claude/agents/scout.md.trio-bak" 'hand written'
check "replaced" has "$H/.claude/agents/scout.md" 'name: scout'

echo "hand-edited generated file survives remove"
new_home
trio apply
printf 'my own version' > "$H/.claude/agents/advisor.md"
trio remove
check "kept" same "$H/.claude/agents/advisor.md" 'my own version'
check "others removed" missing "$H/.claude/agents/scout.md"

echo "set changes model; rename cleans up"
new_home
trio apply
trio set roles.advisor.models.opencode google/gemini-3.1-pro
check "model changed" has "$H/.config/opencode/agents/advisor.md" '^model: google/gemini-3.1-pro$'
trio set roles.builder.name lead
check "old removed" missing "$H/.claude/agents/conductor.md"
check "new created" test -e "$H/.claude/agents/lead.md"
check "default renamed" has "$H/.claude/settings.json" '"agent": "lead"'

echo "project scope and disabling a target"
new_home
trio apply
trio set targets.claude.scope project
check "project file" test -e "$H/project/.claude/agents/scout.md"
check "user file gone" missing "$H/.claude/agents/scout.md"
trio set targets.opencode.enabled false
check "opencode gone" missing "$H/.config/opencode/agents/scout.md"

echo "init with target flags: only those targets, global by default"
new_home
trio init --cursor --codex
check "cursor global"   test -e "$H/.cursor/agents/scout.md"
check "cursor readonly" has "$H/.cursor/agents/scout.md" '^readonly: true$'
check "codex toml"      has "$H/.codex/agents/scout.toml" '^sandbox_mode = "read-only"$'
check "no claude"       missing "$H/.claude"
check "no opencode"     missing "$H/.config/opencode"
check "nothing in cwd"  missing "$H/project/.cursor"

echo "--dir and --project install into a folder; -g moves back"
new_home
mkdir "$H/app"
trio apply
trio apply --copilot --dir "$H/app"
check "copilot in folder" test -e "$H/app/.github/agents/scout.agent.md"
check "copilot tools"     has "$H/app/.github/agents/scout.agent.md" '^tools: \["read", "search", "web"\]$'
check "claude untouched by flag" test -e "$H/.claude/agents/scout.md"
trio apply --gemini --project
check "project = cwd"     test -e "$H/project/.gemini/agents/scout.md"
trio apply --copilot -g
check "copilot global"    test -e "$H/.copilot/agents/scout.agent.md"
check "folder cleaned"    missing "$H/app/.github/agents/scout.agent.md"
check "bad dir fails"     sh -c "! '$BIN' apply --cursor --dir '$H/nope' >/dev/null 2>&1"

echo "disable one target keeps the rest"
new_home
trio apply
trio apply --cursor
trio disable --cursor
check "cursor gone"      missing "$H/.cursor/agents/scout.md"
check "claude kept"      test -e "$H/.claude/agents/scout.md"
check "config kept"      has "$H/trio-config/config.json" '"cursor"'

echo "disable without config installs nothing; --project pins the folder"
new_home
check "disable on empty fails" sh -c "! '$BIN' disable --cursor >/dev/null 2>&1"
check "no agents written"      missing "$H/.claude"
trio init --gemini --project
mkdir "$H/other" && cd "$H/other"
trio apply
check "gemini stays in first folder" test -e "$H/project/.gemini/agents/scout.md"
check "not written to other folder"  missing "$H/other/.gemini"

echo "set on an old config merges target defaults"
new_home
trio apply
trio set targets.cursor.enabled true
check "cursor readonly via set" has "$H/.cursor/agents/scout.md" '^readonly: true$'

echo "--all enables every target"
new_home
trio apply --all
for d in .claude .config/opencode .cursor .copilot .gemini .factory .config/kilo .codex; do
  check "all: $d" test -d "$H/$d"
done

echo "dry run writes nothing"
new_home
trio init
trio apply --dry-run
check "no .claude" missing "$H/.claude"
check "no state" missing "$H/trio-config/state.json"

echo "disable / enable"
new_home
trio apply
trio disable
check "disabled: agents gone" missing "$H/.claude/agents/scout.md"
check "disabled: config kept" test -e "$H/trio-config/config.json"
trio enable
check "enabled: agents back" test -e "$H/.claude/agents/scout.md"

echo "uninstall"
new_home
mkdir -p "$H/bin" && cp "$BIN" "$H/bin/trio"
"$H/bin/trio" apply >/dev/null
check "needs --yes" sh -c "! '$H/bin/trio' uninstall >/dev/null 2>&1"
check "still installed without --yes" test -e "$H/bin/trio"
"$H/bin/trio" uninstall --dry-run >/dev/null
check "dry run keeps binary" test -e "$H/bin/trio"
"$H/bin/trio" uninstall --yes >/dev/null
check "agents gone" missing "$H/.claude/agents/scout.md"
check "config gone" missing "$H/trio-config"
check "binary gone" missing "$H/bin/trio"

echo "prompt for other agents"
check "prompt prints"   sh -c "'$BIN' prompt | grep -q 'Set up trio-cli for yourself'"
check "--other prints"  sh -c "'$BIN' apply --other | grep -q 'Set up trio-cli for yourself'"
check "readme in sync"  sh -c "'$BIN' prompt | grep -vxFf '$ROOT/README.md' | wc -l | grep -qx ' *0'"

echo "misc"
check "version" sh -c "'$BIN' version | grep -q '^trio '"
check "unknown command fails" sh -c "! '$BIN' bogus >/dev/null 2>&1"

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
