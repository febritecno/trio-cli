//! trio: one config, three models (builder / scout / advisor).
//! Generates agent files for Claude Code and OpenCode from one config.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const Value = json.Value;
const Allocator = std.mem.Allocator;
const path_util = std.Io.Dir.path;

const version = "0.4.0";
const role_keys = [_][]const u8{ "builder", "scout", "advisor" };

const default_files = [_]struct { rel: []const u8, data: []const u8 }{
    .{ .rel = "config.json", .data = @embedFile("defaults_config") },
    .{ .rel = "prompts/builder.md", .data = @embedFile("defaults_builder") },
    .{ .rel = "prompts/scout.md", .data = @embedFile("defaults_scout") },
    .{ .rel = "prompts/advisor.md", .data = @embedFile("defaults_advisor") },
};

const help_text =
    \\trio {s} - one config, three models (builder / scout / advisor)
    \\
    \\Usage:
    \\  trio apply [targets] [scope] [--dry-run]
    \\                             Generate agents for every enabled target (creates the config on first run)
    \\  trio init [targets] [scope] [--force]
    \\                             Write the default config; with targets, also turn them on
    \\  trio enable [targets] [scope]   Same as apply
    \\  trio disable [targets] [--dry-run]
    \\                             Delete generated agents (only the named targets if given), keep the config
    \\  trio status                Show the config and what is installed
    \\  trio set <key> <value>     Change one config value, then apply
    \\                             e.g. trio set roles.advisor.models.opencode google/gemini-3.1-pro
    \\                                  trio set targets.opencode.setDefault true
    \\  trio edit [what]           Open config | builder | scout | advisor in $EDITOR, then apply
    \\  trio uninstall [--yes]     Disable, then delete the config and the trio binary itself
    \\  trio path                  Print the config directory
    \\  trio version               Print the version
    \\
    \\Targets: --claude --opencode --cursor --copilot --gemini --droid --kilo --codex, or --all
    \\  With no target flag, every target enabled in the config is used.
    \\Scope:   default is global (your home directory).
    \\  --project        install into the current folder
    \\  --dir <folder>   install into that folder
    \\  -g, --global     back to global
    \\
    \\Examples:
    \\  trio init --opencode                   turn OpenCode on, globally
    \\  trio apply --cursor --dir ~/work/app   Cursor agents inside ~/work/app
    \\  trio disable --codex                   remove the Codex agents only
    \\
    \\Config lives in {s}
    \\
;

// ---------------------------------------------------------------- context

const Ctx = struct {
    io: Io,
    a: Allocator,
    out: *Io.Writer,
    err: *Io.Writer,
    cwd: []const u8,
    home: []const u8,
    config_dir: []const u8,
    dry_run: bool = false,

    fn log(c: *Ctx, comptime fmt: []const u8, args: anytype) void {
        c.out.print(fmt ++ "\n", args) catch {};
    }

    fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) error{Fail} {
        c.out.flush() catch {};
        c.err.print("trio: " ++ fmt ++ "\n", args) catch {};
        c.err.flush() catch {};
        return error.Fail;
    }

    fn join(c: *Ctx, parts: []const []const u8) ![]u8 {
        return path_util.join(c.a, parts);
    }

    fn configPath(c: *Ctx) ![]u8 {
        return c.join(&.{ c.config_dir, "config.json" });
    }

    fn statePath(c: *Ctx) ![]u8 {
        return c.join(&.{ c.config_dir, "state.json" });
    }
};

// ---------------------------------------------------------------- files

fn readIfExists(c: *Ctx, file: []const u8) !?[]u8 {
    return Io.Dir.cwd().readFileAlloc(c.io, file, c.a, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

fn exists(c: *Ctx, file: []const u8) bool {
    Io.Dir.cwd().access(c.io, file, .{}) catch return false;
    return true;
}

fn writeFile(c: *Ctx, file: []const u8, text: []const u8) !void {
    if (path_util.dirname(file)) |dir| try Io.Dir.cwd().createDirPath(c.io, dir);
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = file, .data = text });
}

fn deleteFile(c: *Ctx, file: []const u8) !void {
    Io.Dir.cwd().deleteFile(c.io, file) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

/// Keeps the first backup only, so the user's original survives repeated applies.
fn backupOnce(c: *Ctx, file: []const u8) !void {
    const bak = try std.fmt.allocPrint(c.a, "{s}.trio-bak", .{file});
    if (exists(c, file) and !exists(c, bak)) {
        try Io.Dir.copyFile(.cwd(), file, .cwd(), bak, c.io, .{});
    }
}

fn sha(c: *Ctx, text: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return c.a.dupe(u8, &hex);
}

fn prettyJson(c: *Ctx, v: anytype) ![]u8 {
    const body = try json.Stringify.valueAlloc(c.a, v, .{ .whitespace = .indent_2 });
    return std.fmt.allocPrint(c.a, "{s}\n", .{body});
}

fn jsonString(c: *Ctx, s: []const u8) ![]u8 {
    return json.Stringify.valueAlloc(c.a, s, .{});
}

// ---------------------------------------------------------------- state

const Def = struct { prev: ?[]const u8, set: []const u8 };
const StrMap = std.StringArrayHashMapUnmanaged([]const u8);
const DefMap = std.StringArrayHashMapUnmanaged(Def);

const State = struct {
    files: StrMap = .empty,
    defaults: DefMap = .empty,
};

fn readState(c: *Ctx) !State {
    var st: State = .{};
    const raw = (try readIfExists(c, try c.statePath())) orelse return st;
    const root = json.parseFromSliceLeaky(Value, c.a, raw, .{}) catch return st;
    if (root != .object) return st;
    if (root.object.get("files")) |files| if (files == .object) {
        var it = files.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .string) try st.files.put(c.a, e.key_ptr.*, e.value_ptr.string);
        }
    };
    if (root.object.get("defaults")) |defs| if (defs == .object) {
        var it = defs.object.iterator();
        while (it.next()) |e| {
            const v = e.value_ptr.*;
            if (v != .object) continue;
            const set = v.object.get("set") orelse continue;
            if (set != .string) continue;
            const prev: ?[]const u8 = if (v.object.get("prev")) |p| (if (p == .string) p.string else null) else null;
            try st.defaults.put(c.a, e.key_ptr.*, .{ .prev = prev, .set = set.string });
        }
    };
    return st;
}

fn writeState(c: *Ctx, st: *State) !void {
    var aw: Io.Writer.Allocating = .init(c.a);
    var s: json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("files");
    try s.beginObject();
    for (st.files.keys(), st.files.values()) |k, v| {
        try s.objectField(k);
        try s.write(v);
    }
    try s.endObject();
    try s.objectField("defaults");
    try s.beginObject();
    for (st.defaults.keys(), st.defaults.values()) |k, v| {
        try s.objectField(k);
        try s.beginObject();
        try s.objectField("prev");
        try s.write(v.prev);
        try s.objectField("set");
        try s.write(v.set);
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
    try aw.writer.writeAll("\n");
    try writeFile(c, try c.statePath(), aw.written());
}

// ---------------------------------------------------------------- config

fn initConfig(c: *Ctx, force: bool) ![][]const u8 {
    var created: std.ArrayList([]const u8) = .empty;
    for (default_files) |f| {
        const dest = try c.join(&.{ c.config_dir, f.rel });
        if (exists(c, dest) and !force) continue;
        try writeFile(c, dest, f.data);
        try created.append(c.a, dest);
    }
    return created.items;
}

fn loadConfig(c: *Ctx) !Value {
    const file = try c.configPath();
    const raw = (try readIfExists(c, file)) orelse return c.fail("no config at {s} (run: trio init)", .{file});
    const cfg = json.parseFromSliceLeaky(Value, c.a, raw, .{}) catch |e| {
        return c.fail("{s} is not valid JSON: {s}", .{ file, @errorName(e) });
    };
    if (cfg != .object) return c.fail("{s} must contain a JSON object", .{file});
    const roles = cfg.object.get("roles") orelse return c.fail("config: roles is missing", .{});
    if (roles != .object) return c.fail("config: roles must be an object", .{});
    for (role_keys) |key| {
        const r = roles.object.get(key) orelse return c.fail("config: roles.{s} is missing", .{key});
        if (r != .object) return c.fail("config: roles.{s} must be an object", .{key});
        for ([_][]const u8{ "name", "description", "prompt" }) |field| {
            const v = r.object.get(field);
            if (v == null or v.? != .string or v.?.string.len == 0) {
                return c.fail("config: roles.{s}.{s} must be a non-empty string", .{ key, field });
            }
        }
    }
    return cfg;
}

fn roleOf(cfg: Value, key: []const u8) Value {
    return cfg.object.get("roles").?.object.get(key).?;
}

fn roleStr(cfg: Value, key: []const u8, field: []const u8) []const u8 {
    return roleOf(cfg, key).object.get(field).?.string;
}

fn roleModel(cfg: Value, key: []const u8, target: Target) ?[]const u8 {
    const models = roleOf(cfg, key).object.get("models") orelse return null;
    if (models != .object) return null;
    const m = models.object.get(target.id()) orelse return null;
    return if (m == .string) m.string else null;
}

const TargetOpts = struct { enabled: bool = false, project: bool = false, set_default: bool = false, dir: ?[]const u8 = null };

fn targetOpts(cfg: Value, target: Target) TargetOpts {
    var o: TargetOpts = .{};
    const targets = cfg.object.get("targets") orelse return o;
    if (targets != .object) return o;
    const t = targets.object.get(target.id()) orelse return o;
    if (t != .object) return o;
    if (t.object.get("enabled")) |v| o.enabled = (v == .bool and v.bool);
    if (t.object.get("setDefault")) |v| o.set_default = (v == .bool and v.bool);
    if (t.object.get("scope")) |v| o.project = (v == .string and std.mem.eql(u8, v.string, "project"));
    if (t.object.get("dir")) |v| if (v == .string and v.string.len > 0) {
        o.dir = v.string;
    };
    return o;
}

/// Reads a role's prompt file and fills in the {{builder}} / {{scout}} / {{advisor}} agent names.
fn renderPrompt(c: *Ctx, cfg: Value, key: []const u8) ![]u8 {
    const file = try path_util.resolve(c.a, &.{ c.config_dir, roleStr(cfg, key, "prompt") });
    const text = (try readIfExists(c, file)) orelse return c.fail("prompt file not found: {s}", .{file});
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "{{")) {
            if (std.mem.indexOfPos(u8, text, i + 2, "}}")) |end| {
                const name = text[i + 2 .. end];
                if (isWord(name)) {
                    if (cfg.object.get("roles").?.object.get(name)) |r| {
                        if (r == .object) if (r.object.get("name")) |n| if (n == .string) {
                            try out.appendSlice(c.a, n.string);
                            i = end + 2;
                            continue;
                        };
                    }
                }
            }
        }
        try out.append(c.a, text[i]);
        i += 1;
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    return std.fmt.allocPrint(c.a, "{s}\n", .{trimmed});
}

fn isWord(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

// ---------------------------------------------------------------- yaml

fn needsQuotes(s: []const u8) bool {
    if (s.len == 0) return true;
    const first = s[0];
    if (std.ascii.isWhitespace(first) or std.mem.indexOfScalar(u8, "-?:,[]{}#&*!|>'\"%@`", first) != null) return true;
    if (std.mem.indexOf(u8, s, ": ") != null or std.mem.indexOf(u8, s, " #") != null) return true;
    return std.ascii.isWhitespace(s[s.len - 1]);
}

const YamlError = Io.Writer.Error || Allocator.Error;

fn yamlScalar(c: *Ctx, w: *Io.Writer, indent: []const u8, key: []const u8, v: Value) YamlError!void {
    switch (v) {
        .null => {},
        .array => |arr| {
            // Only flat string lists are written, e.g. `tools: [read, search]`.
            try w.print("{s}{s}: [", .{ indent, key });
            var first = true;
            for (arr.items) |item| {
                if (item != .string) continue;
                if (!first) try w.writeAll(", ");
                first = false;
                try w.writeAll(try jsonString(c, item.string));
            }
            try w.writeAll("]\n");
        },
        .string => |s| {
            if (needsQuotes(s)) {
                try w.print("{s}{s}: {s}\n", .{ indent, key, try jsonString(c, s) });
            } else {
                try w.print("{s}{s}: {s}\n", .{ indent, key, s });
            }
        },
        .bool => |b| try w.print("{s}{s}: {}\n", .{ indent, key, b }),
        .integer => |n| try w.print("{s}{s}: {d}\n", .{ indent, key, n }),
        .float => |f| try w.print("{s}{s}: {d}\n", .{ indent, key, f }),
        .number_string => |s| try w.print("{s}{s}: {s}\n", .{ indent, key, s }),
        .object => |o| {
            try w.print("{s}{s}:\n", .{ indent, key });
            try yamlMap(c, w, try std.fmt.allocPrint(c.a, "{s}  ", .{indent}), o);
        },
    }
}

fn yamlMap(c: *Ctx, w: *Io.Writer, indent: []const u8, o: json.ObjectMap) YamlError!void {
    for (o.keys(), o.values()) |k, v| try yamlScalar(c, w, indent, k, v);
}

fn tomlScalar(c: *Ctx, w: *Io.Writer, key: []const u8, v: Value) YamlError!void {
    switch (v) {
        .string => |s| try w.print("{s} = {s}\n", .{ key, try jsonString(c, s) }),
        .bool => |b| try w.print("{s} = {}\n", .{ key, b }),
        .integer => |n| try w.print("{s} = {d}\n", .{ key, n }),
        .float => |f| try w.print("{s} = {d}\n", .{ key, f }),
        else => {},
    }
}

// ---------------------------------------------------------------- targets

const Format = enum { markdown, toml };

const Spec = struct {
    label: []const u8,
    /// Agent directory relative to $HOME (user scope).
    user: []const u8,
    /// Agent directory relative to the project folder (project scope).
    project: []const u8,
    ext: []const u8 = ".md",
    format: Format = .markdown,
    /// Write `name:` in the frontmatter (some tools take the name from the file name).
    name_field: bool = true,
    /// Write `mode: primary|subagent` in the frontmatter.
    mode_field: bool = false,
    /// Write `model: inherit` literally. Otherwise an inherited model omits the line.
    inherit_literal: bool = false,
    /// The tool has a config key that selects the default agent.
    has_default: bool = false,
};

const Target = enum {
    claude,
    opencode,
    cursor,
    copilot,
    gemini,
    droid,
    kilo,
    codex,

    fn id(t: Target) []const u8 {
        return @tagName(t);
    }

    fn spec(t: Target) Spec {
        return switch (t) {
            .claude => .{ .label = "Claude Code", .user = ".claude/agents", .project = ".claude/agents", .inherit_literal = true, .has_default = true },
            .opencode => .{ .label = "OpenCode", .user = ".config/opencode/agents", .project = ".opencode/agents", .name_field = false, .mode_field = true, .has_default = true },
            .cursor => .{ .label = "Cursor", .user = ".cursor/agents", .project = ".cursor/agents", .inherit_literal = true },
            .copilot => .{ .label = "GitHub Copilot", .user = ".copilot/agents", .project = ".github/agents", .ext = ".agent.md" },
            .gemini => .{ .label = "Gemini CLI", .user = ".gemini/agents", .project = ".gemini/agents" },
            .droid => .{ .label = "Factory Droid", .user = ".factory/droids", .project = ".factory/droids", .inherit_literal = true },
            .kilo => .{ .label = "Kilo Code", .user = ".config/kilo/agent", .project = ".kilo/agents", .name_field = false, .mode_field = true },
            .codex => .{ .label = "Codex", .user = ".codex/agents", .project = ".codex/agents", .ext = ".toml", .format = .toml },
        };
    }

    fn label(t: Target) []const u8 {
        return t.spec().label;
    }

    fn agentPath(t: Target, c: *Ctx, o: TargetOpts, name: []const u8) ![]u8 {
        const sp = t.spec();
        const file = try std.fmt.allocPrint(c.a, "{s}{s}", .{ name, sp.ext });
        if (o.project) return c.join(&.{ o.dir orelse c.cwd, sp.project, file });
        return c.join(&.{ c.home, sp.user, file });
    }

    /// Only meaningful for targets with `has_default`.
    fn settingsPath(t: Target, c: *Ctx, o: TargetOpts) ![]u8 {
        const base = if (o.project) (o.dir orelse c.cwd) else c.home;
        return switch (t) {
            .claude => c.join(&.{ base, ".claude", "settings.json" }),
            .opencode => if (o.project) c.join(&.{ base, "opencode.json" }) else c.join(&.{ base, ".config", "opencode", "opencode.json" }),
            else => unreachable,
        };
    }

    fn render(t: Target, c: *Ctx, cfg: Value, key: []const u8, model: []const u8, body: []const u8) ![]u8 {
        const sp = t.spec();
        const role = roleOf(cfg, key);
        const has_model = !(model.len == 0 or std.mem.eql(u8, model, "inherit")) or sp.inherit_literal;
        var aw: Io.Writer.Allocating = .init(c.a);
        const w = &aw.writer;
        if (sp.format == .toml) {
            try tomlScalar(c, w, "name", role.object.get("name").?);
            try tomlScalar(c, w, "description", role.object.get("description").?);
            if (has_model) try tomlScalar(c, w, "model", .{ .string = model });
            if (role.object.get("frontmatter")) |fm| if (fm == .object) {
                if (fm.object.get(t.id())) |extra| if (extra == .object) {
                    for (extra.object.keys(), extra.object.values()) |k, v| try tomlScalar(c, w, k, v);
                };
            };
            try tomlScalar(c, w, "developer_instructions", .{ .string = body });
            return aw.written();
        }
        try w.writeAll("---\n");
        if (sp.name_field) try yamlScalar(c, w, "", "name", role.object.get("name").?);
        try yamlScalar(c, w, "", "description", role.object.get("description").?);
        if (sp.mode_field) try yamlScalar(c, w, "", "mode", .{ .string = if (std.mem.eql(u8, key, "builder")) "primary" else "subagent" });
        if (has_model) try yamlScalar(c, w, "", "model", .{ .string = model });
        if (role.object.get("frontmatter")) |fm| if (fm == .object) {
            if (fm.object.get(t.id())) |extra| if (extra == .object) try yamlMap(c, w, "", extra.object);
        };
        try w.print("---\n\n{s}", .{body});
        return aw.written();
    }

    fn getDefault(t: Target, c: *Ctx, file: []const u8) !?[]const u8 {
        const raw = (try readIfExists(c, file)) orelse return null;
        switch (t) {
            .claude => {
                const root = json.parseFromSliceLeaky(Value, c.a, raw, .{}) catch return c.fail("{s} is not valid JSON", .{file});
                if (root != .object) return null;
                const v = root.object.get("agent") orelse return null;
                return if (v == .string) v.string else null;
            },
            .opencode => return if (findDefaultLine(raw)) |l| l.value else null,
            else => return null,
        }
    }

    fn setDefault(t: Target, c: *Ctx, file: []const u8, name: ?[]const u8) !void {
        switch (t) {
            .claude => {
                const raw = try readIfExists(c, file);
                var root: Value = .{ .object = .empty };
                if (raw) |r| {
                    root = json.parseFromSliceLeaky(Value, c.a, r, .{}) catch return c.fail("{s} is not valid JSON", .{file});
                    if (root != .object) return c.fail("{s} does not contain a JSON object", .{file});
                }
                if (name) |n| {
                    try root.object.put(c.a, "agent", .{ .string = n });
                } else {
                    _ = root.object.orderedRemove("agent");
                }
                try backupOnce(c, file);
                try writeFile(c, file, try prettyJson(c, root));
            },
            .opencode => try setOpencodeDefault(c, file, name),
            else => {},
        }
    }
};

// opencode.json is JSONC (comments, trailing commas), so it is edited as text
// rather than parsed and rewritten, which would drop the user's comments.

const DefaultLine = struct { start: usize, end: usize, value: []const u8, comma: bool };

fn findDefaultLine(raw: []const u8) ?DefaultLine {
    var pos: usize = 0;
    while (pos < raw.len) {
        const nl = std.mem.indexOfScalarPos(u8, raw, pos, '\n');
        const end = if (nl) |n| n + 1 else raw.len;
        const line = std.mem.trimEnd(u8, raw[pos..end], "\r\n");
        if (parseDefaultLine(line)) |p| return .{ .start = pos, .end = end, .value = p.value, .comma = p.comma };
        pos = end;
    }
    return null;
}

fn parseDefaultLine(line: []const u8) ?struct { value: []const u8, comma: bool } {
    var s = std.mem.trimStart(u8, line, " \t");
    const key = "\"default_agent\"";
    if (!std.mem.startsWith(u8, s, key)) return null;
    s = std.mem.trimStart(u8, s[key.len..], " \t");
    if (s.len == 0 or s[0] != ':') return null;
    s = std.mem.trimStart(u8, s[1..], " \t");
    if (s.len == 0 or s[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse return null;
    const value = s[1..close];
    s = std.mem.trimStart(u8, s[close + 1 ..], " \t");
    var comma = false;
    if (s.len > 0 and s[0] == ',') {
        comma = true;
        s = std.mem.trimStart(u8, s[1..], " \t");
    }
    if (s.len != 0) return null;
    return .{ .value = value, .comma = comma };
}

fn setOpencodeDefault(c: *Ctx, file: []const u8, name: ?[]const u8) !void {
    const raw = try readIfExists(c, file);
    const quoted: []const u8 = if (name) |n| try jsonString(c, n) else "";
    var next: []const u8 = undefined;
    if (raw == null) {
        if (name == null) return;
        next = try std.fmt.allocPrint(c.a, "{{\n  \"$schema\": \"https://opencode.ai/config.json\",\n  \"default_agent\": {s}\n}}\n", .{quoted});
    } else if (findDefaultLine(raw.?)) |l| {
        const r = raw.?;
        const line: []const u8 = if (name == null) "" else try std.fmt.allocPrint(c.a, "  \"default_agent\": {s}{s}\n", .{ quoted, if (l.comma) "," else "" });
        next = try std.mem.concat(c.a, u8, &.{ r[0..l.start], line, r[l.end..] });
    } else if (name == null) {
        return;
    } else if (isEmptyObject(raw.?)) {
        next = try std.fmt.allocPrint(c.a, "{{\n  \"default_agent\": {s}\n}}\n", .{quoted});
    } else {
        const r = raw.?;
        const open = std.mem.indexOfScalar(u8, r, '{') orelse return c.fail("{s} does not look like a JSON object", .{file});
        next = try std.fmt.allocPrint(c.a, "{s}\n  \"default_agent\": {s},{s}", .{ r[0 .. open + 1], quoted, r[open + 1 ..] });
    }
    try backupOnce(c, file);
    try writeFile(c, file, next);
}

fn isEmptyObject(raw: []const u8) bool {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (t.len < 2 or t[0] != '{' or t[t.len - 1] != '}') return false;
    return std.mem.trim(u8, t[1 .. t.len - 1], " \t\r\n").len == 0;
}

// ---------------------------------------------------------------- managed files

fn writeManaged(c: *Ctx, file: []const u8, content: []const u8, st: *State) !void {
    const current = try readIfExists(c, file);
    const new_hash = try sha(c, content);
    if (current) |cur| if (std.mem.eql(u8, cur, content)) {
        try st.files.put(c.a, file, new_hash);
        c.log("  unchanged  {s}", .{file});
        return;
    };
    var note: []const u8 = "";
    if (current) |cur| {
        const known = st.files.get(file);
        if (known == null or !std.mem.eql(u8, known.?, try sha(c, cur))) {
            note = try std.fmt.allocPrint(c.a, "  (previous saved to {s}.trio-bak)", .{path_util.basename(file)});
            if (!c.dry_run) try backupOnce(c, file);
        }
    }
    if (!c.dry_run) try writeFile(c, file, content);
    try st.files.put(c.a, file, new_hash);
    c.log("  {s}  {s}{s}", .{ if (current == null) "created  " else "updated  ", file, note });
}

/// Deletes a generated file, unless it was edited by hand since trio wrote it.
fn removeManaged(c: *Ctx, file: []const u8, st: *State) !void {
    if (try readIfExists(c, file)) |cur| {
        const known = st.files.get(file);
        if (known == null or !std.mem.eql(u8, known.?, try sha(c, cur))) {
            c.log("  kept       {s}  (edited by hand, not deleted)", .{file});
        } else {
            if (!c.dry_run) try deleteFile(c, file);
            c.log("  removed    {s}", .{file});
        }
    }
    _ = st.files.orderedRemove(file);
}

/// Points the tool's default agent at the builder, remembering what was there so remove can restore it.
fn syncDefault(c: *Ctx, target: Target, file: []const u8, want: ?[]const u8, st: *State) !void {
    const key = try std.fmt.allocPrint(c.a, "{s}:{s}", .{ target.id(), file });
    const entry = st.defaults.get(key);
    const current = try target.getDefault(c, file);
    if (want) |w| {
        if (current != null and std.mem.eql(u8, current.?, w)) {
            if (entry == null) try st.defaults.put(c.a, key, .{ .prev = null, .set = w });
            c.log("  unchanged  default agent \"{s}\" in {s}", .{ w, file });
            return;
        }
        const prev = if (entry) |e| e.prev else current;
        try st.defaults.put(c.a, key, .{ .prev = prev, .set = w });
        if (!c.dry_run) try target.setDefault(c, file, w);
        c.log("  updated    default agent -> \"{s}\" in {s}", .{ w, file });
    } else if (entry) |e| {
        if (current != null and std.mem.eql(u8, current.?, e.set)) {
            if (!c.dry_run) try target.setDefault(c, file, e.prev);
            if (e.prev) |p| {
                c.log("  restored   default agent -> \"{s}\" in {s}", .{ p, file });
            } else {
                c.log("  restored   default agent -> (none) in {s}", .{file});
            }
        }
        _ = st.defaults.orderedRemove(key);
    }
}

fn syncStaleDefault(c: *Ctx, key: []const u8, st: *State) !void {
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return;
    const target = std.meta.stringToEnum(Target, key[0..colon]) orelse return;
    try syncDefault(c, target, key[colon + 1 ..], null, st);
}

// ---------------------------------------------------------------- commands

fn cmdApply(c: *Ctx) !void {
    if (!exists(c, try c.configPath())) {
        _ = try initConfig(c, false);
        c.log("Created default config in {s}", .{c.config_dir});
    }
    return applyConfig(c, try loadConfig(c));
}

fn scopeLabel(c: *Ctx, o: TargetOpts) []const u8 {
    if (!o.project) return "user";
    return std.fmt.allocPrint(c.a, "project: {s}", .{o.dir orelse c.cwd}) catch "project";
}

fn applyConfig(c: *Ctx, cfg: Value) !void {
    var st = try readState(c);
    var wanted_files: std.StringHashMapUnmanaged(void) = .empty;
    var wanted_defaults: std.StringHashMapUnmanaged(void) = .empty;

    inline for (std.meta.fields(Target)) |f| {
        const target: Target = @enumFromInt(f.value);
        const opts = targetOpts(cfg, target);
        if (opts.enabled) {
            c.log("{s} ({s})", .{ target.label(), scopeLabel(c, opts) });
            for (role_keys) |key| {
                const model = roleModel(cfg, key, target) orelse "inherit";
                const file = try target.agentPath(c, opts, roleStr(cfg, key, "name"));
                try wanted_files.put(c.a, file, {});
                const content = try target.render(c, cfg, key, model, try renderPrompt(c, cfg, key));
                try writeManaged(c, file, content, &st);
            }
            if (target.spec().has_default) {
                const settings = try target.settingsPath(c, opts);
                if (opts.set_default) try wanted_defaults.put(c.a, try std.fmt.allocPrint(c.a, "{s}:{s}", .{ target.id(), settings }), {});
                try syncDefault(c, target, settings, if (opts.set_default) roleStr(cfg, "builder", "name") else null, &st);
            }
        }
    }

    // Anything trio installed earlier that the config no longer asks for
    // (renamed role, disabled target, changed scope) is cleaned up.
    var stale_files: std.ArrayList([]const u8) = .empty;
    for (st.files.keys()) |file| if (!wanted_files.contains(file)) try stale_files.append(c.a, file);
    var stale_defaults: std.ArrayList([]const u8) = .empty;
    for (st.defaults.keys()) |key| if (!wanted_defaults.contains(key)) try stale_defaults.append(c.a, key);
    if (stale_files.items.len > 0 or stale_defaults.items.len > 0) c.log("Cleanup", .{});
    for (stale_files.items) |file| try removeManaged(c, file, &st);
    for (stale_defaults.items) |key| try syncStaleDefault(c, key, &st);

    if (c.dry_run) c.log("Dry run: nothing was written.", .{}) else try writeState(c, &st);
}

// ---------------------------------------------------------------- target selection

const Scope = enum { keep, user, project };

/// Targets and scope picked on the command line, e.g. `--opencode --cursor --dir ./app`.
const Selection = struct {
    targets: std.EnumSet(Target) = .initEmpty(),
    all: bool = false,
    scope: Scope = .keep,
    dir: ?[]const u8 = null,

    fn explicit(sel: Selection) bool {
        return sel.all or sel.targets.count() > 0;
    }

    fn any(sel: Selection) bool {
        return sel.explicit() or sel.scope != .keep;
    }
};

fn ensureObj(c: *Ctx, node: *Value, key: []const u8) !*Value {
    if (node.* != .object) node.* = .{ .object = .empty };
    const gop = try node.object.getOrPut(c.a, key);
    if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
    return gop.value_ptr;
}

/// Copies this target's block, models and frontmatter from the built-in defaults
/// into a config that predates the target. Existing values are never overwritten.
fn mergeTargetDefaults(c: *Ctx, cfg: *Value, target: Target) !void {
    const defaults = try json.parseFromSliceLeaky(Value, c.a, default_files[0].data, .{});
    const id = target.id();
    const targets = try ensureObj(c, cfg, "targets");
    if (!targets.object.contains(id)) {
        if (defaults.object.get("targets")) |dt| if (dt == .object) if (dt.object.get(id)) |block| {
            try targets.object.put(c.a, id, block);
        };
    }
    const roles = try ensureObj(c, cfg, "roles");
    for (role_keys) |key| {
        const dr = (defaults.object.get("roles") orelse continue).object.get(key) orelse continue;
        const role = try ensureObj(c, roles, key);
        for ([_][]const u8{ "models", "frontmatter" }) |section| {
            const dsec = dr.object.get(section) orelse continue;
            if (dsec != .object) continue;
            const dval = dsec.object.get(id) orelse continue;
            const sec = try ensureObj(c, role, section);
            if (!sec.object.contains(id)) try sec.object.put(c.a, id, dval);
        }
    }
}

fn setTargetField(c: *Ctx, cfg: *Value, target: Target, field: []const u8, v: ?Value) !void {
    const block = try ensureObj(c, try ensureObj(c, cfg, "targets"), target.id());
    if (v) |val| try block.object.put(c.a, field, val) else _ = block.object.orderedRemove(field);
}

/// Turns the selected targets on (or off) in the config, applying --project / --dir / --global.
fn applySelection(c: *Ctx, sel: Selection, enable: bool, was_missing: bool) !Value {
    var fresh = was_missing;
    if (!exists(c, try c.configPath())) {
        if (!enable) return c.fail("nothing to disable: no config at {s}", .{try c.configPath()});
        if (c.dry_run) return c.fail("no config yet; run `trio init` first, then --dry-run", .{});
        _ = try initConfig(c, false);
        c.log("Created default config in {s}", .{c.config_dir});
        fresh = true;
    }
    var cfg = try loadConfig(c);

    var chosen: std.EnumSet(Target) = .initEmpty();
    if (sel.all) {
        chosen = .initFull();
    } else if (sel.targets.count() > 0) {
        chosen = sel.targets;
    } else {
        // Scope flags alone act on whatever is already enabled.
        inline for (std.meta.fields(Target)) |f| {
            const t: Target = @enumFromInt(f.value);
            if (targetOpts(cfg, t).enabled) chosen.insert(t);
        }
    }

    var abs_dir: ?[]const u8 = null;
    if (sel.dir) |d| {
        const resolved = try path_util.resolve(c.a, &.{ c.cwd, d });
        var folder = Io.Dir.cwd().openDir(c.io, resolved, .{}) catch return c.fail("--dir {s}: not a folder", .{resolved});
        folder.close(c.io);
        abs_dir = resolved;
    }

    var it = chosen.iterator();
    while (it.next()) |t| {
        if (enable) try mergeTargetDefaults(c, &cfg, t);
        try setTargetField(c, &cfg, t, "enabled", .{ .bool = enable });
        if (enable and sel.scope != .keep) {
            try setTargetField(c, &cfg, t, "scope", .{ .string = if (sel.scope == .project) "project" else "user" });
            try setTargetField(c, &cfg, t, "dir", if (sel.scope == .project) Value{ .string = abs_dir orelse c.cwd } else null);
        }
    }
    // On a brand-new config, "init --cursor" means only Cursor, not the default pair as well.
    if (fresh and enable and sel.explicit() and !sel.all) {
        inline for (std.meta.fields(Target)) |f| {
            const t: Target = @enumFromInt(f.value);
            if (!chosen.contains(t)) try setTargetField(c, &cfg, t, "enabled", .{ .bool = false });
        }
    }
    if (!c.dry_run) try writeFile(c, try c.configPath(), try prettyJson(c, cfg));
    return cfg;
}

fn cmdRemove(c: *Ctx) !void {
    var st = try readState(c);
    for (try c.a.dupe([]const u8, st.files.keys())) |file| try removeManaged(c, file, &st);
    for (try c.a.dupe([]const u8, st.defaults.keys())) |key| try syncStaleDefault(c, key, &st);
    if (c.dry_run) c.log("Dry run: nothing was removed.", .{}) else try writeState(c, &st);
    c.log("Config kept in {s}", .{c.config_dir});
}

fn cmdUninstall(c: *Ctx, confirmed: bool) !void {
    const exe = try std.process.executablePathAlloc(c.io, c.a);
    const is_trio = std.mem.eql(u8, path_util.basename(exe), "trio");
    if (!confirmed and !c.dry_run) {
        c.log("This will disable trio, delete {s} and delete {s}.", .{ c.config_dir, if (is_trio) exe else "(binary: not named trio, left alone)" });
        return c.fail("re-run with --yes to confirm (or --dry-run to preview)", .{});
    }
    try cmdRemove(c);
    if (!c.dry_run) {
        const cwd = Io.Dir.cwd();
        for ([_][]const u8{ "config.json", "state.json" }) |name| try deleteFile(c, try c.join(&.{ c.config_dir, name }));
        cwd.deleteTree(c.io, try c.join(&.{ c.config_dir, "prompts" })) catch {};
        cwd.deleteDir(c.io, c.config_dir) catch {}; // stays if the user keeps other files in it
    }
    c.log("  {s}  {s}", .{ if (c.dry_run) "would delete" else "deleted     ", c.config_dir });
    if (is_trio) {
        if (!c.dry_run) try deleteFile(c, exe);
        c.log("  {s}  {s}", .{ if (c.dry_run) "would delete" else "deleted     ", exe });
    }
    if (!c.dry_run) c.log("trio-cli uninstalled.", .{});
}

fn cmdStatus(c: *Ctx) !void {
    const cfg = try loadConfig(c);
    const st = try readState(c);
    c.log("Config: {s}", .{try c.configPath()});
    inline for (std.meta.fields(Target)) |f| {
        const target: Target = @enumFromInt(f.value);
        const opts = targetOpts(cfg, target);
        if (!opts.enabled) {
            c.log("\n{s}: disabled", .{target.label()});
        } else {
            if (target.spec().has_default) {
                const cur = try target.getDefault(c, try target.settingsPath(c, opts));
                c.log("\n{s} ({s}), default agent: {s}", .{ target.label(), scopeLabel(c, opts), cur orelse "(none)" });
            } else {
                c.log("\n{s} ({s})", .{ target.label(), scopeLabel(c, opts) });
            }
            for (role_keys) |key| {
                const name = roleStr(cfg, key, "name");
                const file = try target.agentPath(c, opts, name);
                const installed: []const u8 = if (!exists(c, file)) "not installed" else if (st.files.contains(file)) "installed" else "exists, not managed by trio";
                c.log("  {s: <8} {s: <12} {s: <30} {s}", .{ key, name, roleModel(cfg, key, target) orelse "(no model)", installed });
            }
        }
    }
}

fn cmdSet(c: *Ctx, args: []const []const u8) !void {
    if (args.len < 2) return c.fail("usage: trio set <key> <value>", .{});
    var cfg = try loadConfig(c);
    const value_text = try std.mem.join(c.a, " ", args[1..]);
    const parsed: Value = if (std.mem.eql(u8, value_text, "true")) .{ .bool = true } else if (std.mem.eql(u8, value_text, "false")) .{ .bool = false } else .{ .string = value_text };

    var keys: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, args[0], '.');
    while (it.next()) |k| try keys.append(c.a, k);

    if (keys.items.len > 1 and std.mem.eql(u8, keys.items[0], "targets")) {
        if (std.meta.stringToEnum(Target, keys.items[1])) |t| try mergeTargetDefaults(c, &cfg, t);
    }
    var node: *Value = &cfg;
    for (keys.items[0 .. keys.items.len - 1]) |k| {
        const gop = try node.object.getOrPut(c.a, k);
        if (!gop.found_existing or gop.value_ptr.* != .object) gop.value_ptr.* = .{ .object = .empty };
        node = gop.value_ptr;
    }
    try node.object.put(c.a, keys.items[keys.items.len - 1], parsed);
    if (!c.dry_run) try writeFile(c, try c.configPath(), try prettyJson(c, cfg));
    c.log("{s} = {s}", .{ args[0], try json.Stringify.valueAlloc(c.a, parsed, .{}) });
    try cmdApply(c);
}

fn cmdEdit(c: *Ctx, env: *std.process.Environ.Map, args: []const []const u8) !void {
    if (!exists(c, try c.configPath())) _ = try initConfig(c, false);
    const what: []const u8 = if (args.len > 0) args[0] else "config";
    // Plain "config" skips validation so a broken config can still be opened and fixed.
    const cfg: Value = if (std.mem.eql(u8, what, "config")) .null else try loadConfig(c);
    const file: []const u8 = if (std.mem.eql(u8, what, "config"))
        try c.configPath()
    else for (role_keys) |key| {
        if (std.mem.eql(u8, key, what)) break try path_util.resolve(c.a, &.{ c.config_dir, roleStr(cfg, key, "prompt") });
    } else return c.fail("unknown item \"{s}\" (use: config, builder, scout, advisor)", .{what});

    const editor = env.get("VISUAL") orelse env.get("EDITOR") orelse "vi";
    const cmd = try std.fmt.allocPrint(c.a, "{s} {s}", .{ editor, try jsonString(c, file) });
    try c.out.flush();
    var child = std.process.spawn(c.io, .{
        .argv = &.{ "sh", "-c", cmd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| return c.fail("cannot start editor: {s}", .{@errorName(e)});
    const term = try child.wait(c.io);
    switch (term) {
        .exited => |code| if (code != 0) return c.fail("editor exited with status {d}", .{code}),
        else => return c.fail("editor was terminated", .{}),
    }
    try cmdApply(c);
}

fn cmdInit(c: *Ctx, force: bool) !void {
    const created = try initConfig(c, force);
    if (created.len == 0) {
        c.log("Config already exists in {s} (use --force to reset)", .{c.config_dir});
    } else for (created) |f| c.log("  wrote  {s}", .{f});
}

fn printHelp(c: *Ctx) void {
    c.out.print(help_text, .{ version, c.config_dir }) catch {};
}

fn run(c: *Ctx, env: *std.process.Environ.Map, argv: []const []const u8) !void {
    var flags: std.StringHashMapUnmanaged(void) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var sel: Selection = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--dir")) {
            i += 1;
            if (i >= argv.len) return c.fail("--dir needs a folder", .{});
            sel.dir = argv[i];
            sel.scope = .project;
        } else if (std.mem.eql(u8, arg, "--project")) {
            sel.scope = .project;
        } else if (std.mem.eql(u8, arg, "--global") or std.mem.eql(u8, arg, "-g")) {
            sel.scope = .user;
        } else if (std.mem.eql(u8, arg, "--all")) {
            sel.all = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (std.meta.stringToEnum(Target, arg[2..])) |t| sel.targets.insert(t) else try flags.put(c.a, arg, {});
        } else try pos.append(c.a, arg);
    }
    c.dry_run = flags.contains("--dry-run");
    if (flags.contains("--version")) return c.log("trio {s}", .{version});
    if (pos.items.len == 0) return printHelp(c);

    const cmd = pos.items[0];
    const args = pos.items[1..];
    const eq = std.mem.eql;
    if (eq(u8, cmd, "apply") or eq(u8, cmd, "enable") or eq(u8, cmd, "install")) {
        if (sel.any()) return applyConfig(c, try applySelection(c, sel, true, false));
        return cmdApply(c);
    }
    if (eq(u8, cmd, "disable") or eq(u8, cmd, "remove")) {
        if (sel.explicit()) return applyConfig(c, try applySelection(c, sel, false, false));
        return cmdRemove(c);
    }
    if (eq(u8, cmd, "uninstall")) return cmdUninstall(c, flags.contains("--yes"));
    if (eq(u8, cmd, "status")) return cmdStatus(c);
    if (eq(u8, cmd, "set")) return cmdSet(c, args);
    if (eq(u8, cmd, "edit")) return cmdEdit(c, env, args);
    if (eq(u8, cmd, "init")) {
        const was_missing = !exists(c, try c.configPath());
        try cmdInit(c, flags.contains("--force"));
        if (sel.any()) return applyConfig(c, try applySelection(c, sel, true, was_missing));
        return;
    }
    if (eq(u8, cmd, "path")) return c.log("{s}", .{c.config_dir});
    if (eq(u8, cmd, "version")) return c.log("trio {s}", .{version});
    if (eq(u8, cmd, "help") or flags.contains("--help")) return printHelp(c);
    printHelp(c);
    return c.fail("unknown command \"{s}\"", .{cmd});
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_w = Io.File.stdout().writer(io, &out_buf);
    var err_w = Io.File.stderr().writer(io, &err_buf);

    const home = init.environ_map.get("HOME") orelse {
        err_w.interface.writeAll("trio: HOME is not set\n") catch {};
        err_w.interface.flush() catch {};
        std.process.exit(1);
    };
    const config_dir = init.environ_map.get("TRIO_HOME") orelse try path_util.join(a, &.{ home, ".config", "trio-cli" });

    var ctx: Ctx = .{
        .io = io,
        .a = a,
        .out = &out_w.interface,
        .err = &err_w.interface,
        .cwd = try std.process.currentPathAlloc(io, a),
        .home = home,
        .config_dir = config_dir,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(a);
    _ = it.next();
    while (it.next()) |arg| try argv.append(a, arg);

    run(&ctx, init.environ_map, argv.items) catch |e| {
        ctx.out.flush() catch {};
        if (e != error.Fail) {
            ctx.err.print("trio: {s}\n", .{@errorName(e)}) catch {};
            ctx.err.flush() catch {};
        }
        std.process.exit(1);
    };
    try ctx.out.flush();
}
