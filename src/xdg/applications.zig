//! Pure XDG desktop-entry parsing and safe Exec preparation.

const std = @import("std");

pub const Scan = @import("application_scan.zig").Scan;

pub const max_file_bytes = 1024 * 1024;
pub const max_total_bytes = 64 * 1024 * 1024;
pub const max_files = 65_536;
pub const max_depth = 32;

pub const Config = struct {
    roots: []const []const u8,
    locale: []const u8 = "",
    desktops: []const []const u8 = &.{},
    allocator: ?std.mem.Allocator = null,

    pub fn init(allocator: std.mem.Allocator, environ: std.process.Environ) !Config {
        var roots: std.ArrayList([]const u8) = .empty;
        errdefer freeStrings(allocator, &roots);
        const home = std.process.Environ.getPosix(environ, "HOME") orelse "";
        const data_home = std.process.Environ.getPosix(environ, "XDG_DATA_HOME") orelse "";
        if (validRoot(data_home)) try appendCopy(allocator, &roots, data_home) else if (data_home.len == 0 and validRoot(home)) {
            const value = try std.fs.path.join(allocator, &.{ home, ".local/share" });
            errdefer allocator.free(value);
            try roots.append(allocator, value);
        }
        const dirs_value = std.process.Environ.getPosix(environ, "XDG_DATA_DIRS") orelse "";
        const dirs = if (dirs_value.len == 0) "/usr/local/share:/usr/share" else dirs_value;
        var parts = std.mem.splitScalar(u8, dirs, ':');
        while (parts.next()) |part| if (validRoot(part) and !contains(roots.items, part)) try appendCopy(allocator, &roots, part);

        const locale_source = firstNonEmpty(&.{
            std.process.Environ.getPosix(environ, "LC_ALL"),
            std.process.Environ.getPosix(environ, "LC_MESSAGES"),
            std.process.Environ.getPosix(environ, "LANG"),
        });
        const locale = try allocator.dupe(u8, locale_source);
        errdefer allocator.free(locale);
        var desktops: std.ArrayList([]const u8) = .empty;
        errdefer freeStrings(allocator, &desktops);
        var desktop_it = std.mem.splitScalar(u8, std.process.Environ.getPosix(environ, "XDG_CURRENT_DESKTOP") orelse "", ':');
        while (desktop_it.next()) |desktop| if (desktop.len != 0) try appendCopy(allocator, &desktops, desktop);
        const owned_roots = try roots.toOwnedSlice(allocator);
        errdefer {
            for (owned_roots) |value| allocator.free(value);
            allocator.free(owned_roots);
        }
        const owned_desktops = try desktops.toOwnedSlice(allocator);
        return .{ .roots = owned_roots, .locale = locale, .desktops = owned_desktops, .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        const allocator = self.allocator orelse return;
        for (self.roots) |value| allocator.free(value);
        allocator.free(self.roots);
        for (self.desktops) |value| allocator.free(value);
        allocator.free(self.desktops);
        allocator.free(self.locale);
        self.* = undefined;
    }
};

pub const Action = struct { id: []const u8, name: []const u8, exec: ?[]const u8, icon: ?[]const u8 };
pub const Entry = struct {
    id: []const u8,
    path: []const u8,
    name: []const u8,
    generic_name: ?[]const u8,
    comment: ?[]const u8,
    icon: ?[]const u8,
    exec: ?[]const u8,
    try_exec: ?[]const u8 = null,
    working_directory: ?[]const u8,
    keywords: []const []const u8,
    actions: []const Action,
    hidden: bool,
    no_display: bool,
    terminal: bool,
    dbus_activatable: bool,
    visible: bool,
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Group = struct { name: []const u8, pairs: std.StringHashMapUnmanaged([]const u8) };

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, id: []const u8, path: []const u8, config: *const Config) !?Entry {
    if (!std.unicode.utf8ValidateSlice(bytes) or std.mem.indexOfScalar(u8, bytes, 0) != null or !validDesktopId(id)) return error.MalformedDesktopEntry;
    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |*group| group.pairs.deinit(allocator);
        groups.deinit(allocator);
    }
    var current: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') return error.MalformedDesktopEntry;
            const name = line[1 .. line.len - 1];
            for (groups.items) |group| if (std.mem.eql(u8, group.name, name)) return error.MalformedDesktopEntry;
            try groups.append(allocator, .{ .name = name, .pairs = .empty });
            current = groups.items.len - 1;
            continue;
        }
        const index = current orelse return error.MalformedDesktopEntry;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return error.MalformedDesktopEntry;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (!validKey(key)) return error.MalformedDesktopEntry;
        // Packaged entries can repeat keys (Chrome repeats StartupWMClass).
        // Match GLib key files: the last value in this group wins.
        try groups.items[index].pairs.put(allocator, key, value);
    }
    const main = findGroup(groups.items, "Desktop Entry") orelse return error.MalformedDesktopEntry;
    if (!std.mem.eql(u8, main.get("Type") orelse return error.MalformedDesktopEntry, "Application")) return null;
    const name = try localized(allocator, main, "Name", config.locale) orelse return error.MalformedDesktopEntry;
    if (name.len == 0) return error.MalformedDesktopEntry;
    if (main.contains("OnlyShowIn") and main.contains("NotShowIn")) return error.MalformedDesktopEntry;
    const hidden = try boolean(main, "Hidden", false);
    const no_display = try boolean(main, "NoDisplay", false);
    const terminal = try boolean(main, "Terminal", false);
    const dbus = try boolean(main, "DBusActivatable", false);
    const exec = try optionalString(allocator, main.get("Exec"));
    if (exec == null and !dbus) return error.MalformedDesktopEntry;
    const visible = !hidden and !no_display and try showIn(allocator, main, config.desktops);
    var actions: std.ArrayList(Action) = .empty;
    defer actions.deinit(allocator);
    if (main.get("Actions")) |action_list| for (try splitList(allocator, action_list)) |action_id| {
        const heading = try std.fmt.allocPrint(allocator, "Desktop Action {s}", .{action_id});
        const action_group = findGroup(groups.items, heading);
        if (action_group) |group| if (try localized(allocator, group, "Name", config.locale)) |action_name|
            try actions.append(allocator, .{ .id = try allocator.dupe(u8, action_id), .name = action_name, .exec = try optionalString(allocator, group.get("Exec")), .icon = try localized(allocator, group, "Icon", config.locale) });
    };
    return .{
        .id = try allocator.dupe(u8, id),
        .path = try allocator.dupe(u8, path),
        .name = name,
        .generic_name = try localized(allocator, main, "GenericName", config.locale),
        .comment = try localized(allocator, main, "Comment", config.locale),
        .icon = try localized(allocator, main, "Icon", config.locale),
        .exec = exec,
        .try_exec = try optionalString(allocator, main.get("TryExec")),
        .working_directory = try optionalString(allocator, main.get("Path")),
        .keywords = if (try localizedRaw(main, "Keywords", config.locale)) |value| try splitList(allocator, value) else &.{},
        .actions = try allocator.dupe(Action, actions.items),
        .hidden = hidden,
        .no_display = no_display,
        .terminal = terminal,
        .dbus_activatable = dbus,
        .visible = visible,
    };
}

pub const LaunchOptions = struct { action: ?[]const u8 = null, terminal_argv: []const []const u8 = &.{} };
pub const Launch = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    pub fn deinit(self: *Launch) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn prepareLaunch(allocator: std.mem.Allocator, entry: *const Entry, options: LaunchOptions) !Launch {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var exec = entry.exec;
    if (options.action) |wanted| {
        exec = null;
        for (entry.actions) |action| if (std.mem.eql(u8, action.id, wanted))
            if (action.exec) |action_exec| {
                exec = action_exec;
                break;
            } else return error.NoExec;
        if (exec == null) return error.UnknownAction;
    }
    const command = exec orelse return error.NoExec;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    if (entry.terminal) {
        if (options.terminal_argv.len == 0) return error.TerminalRequired;
        for (options.terminal_argv) |arg| try argv.append(a, try a.dupe(u8, arg));
    }
    try expandExec(a, &argv, command, entry);
    if (argv.items.len == (if (entry.terminal) options.terminal_argv.len else 0)) return error.InvalidExec;
    return .{ .arena = arena, .argv = try argv.toOwnedSlice(a), .cwd = if (entry.working_directory) |cwd| try a.dupe(u8, cwd) else null };
}

fn expandExec(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), command: []const u8, entry: *const Entry) !void {
    if (std.mem.indexOfAny(u8, command, "\x00\n\r") != null) return error.InvalidExec;
    var token: std.Io.Writer.Allocating = .init(allocator);
    defer token.deinit();
    var quoted = false;
    var active = false;
    var whole_code: ?u8 = null;
    var file_code_seen = false;
    var has_field_code = false;
    const prefix_len = argv.items.len;
    var i: usize = 0;
    while (i <= command.len) {
        const ch: u8 = if (i == command.len) ' ' else command[i];
        if (ch == '"') {
            quoted = !quoted;
            active = true;
            i += 1;
            continue;
        }
        if (ch == '\\') {
            if (i + 1 >= command.len) return error.InvalidExec;
            const next = command[i + 1];
            if (quoted and next != '"' and next != '`' and next != '$' and next != '\\') return error.InvalidExec;
            token.writer.writeByte(next) catch return error.OutOfMemory;
            active = true;
            i += 2;
            continue;
        }
        if (!quoted and (ch == ' ' or ch == '\t')) {
            if (active) {
                if (argv.items.len == prefix_len and (whole_code != null or has_field_code or token.written().len == 0 or std.mem.indexOfScalar(u8, token.written(), '=') != null)) return error.InvalidExec;
                if (whole_code) |code| try appendWholeCode(allocator, argv, code, entry) else try argv.append(allocator, try allocator.dupe(u8, token.written()));
                token.clearRetainingCapacity();
                active = false;
                whole_code = null;
                has_field_code = false;
            }
            i += 1;
            continue;
        }
        if (ch == '%' and i + 1 < command.len) {
            const code = command[i + 1];
            has_field_code = true;
            if (code == 'F' or code == 'U' or code == 'f' or code == 'u') {
                if (file_code_seen) return error.InvalidExec;
                file_code_seen = true;
            }
            if (code == 'F' or code == 'U' or code == 'f' or code == 'u' or code == 'i') {
                if (quoted or token.written().len != 0 or whole_code != null) return error.InvalidExec;
                whole_code = code;
                active = true;
                i += 2;
                continue;
            }
            if (code == 'd' or code == 'D' or code == 'n' or code == 'N' or code == 'v' or code == 'm') {
                i += 2;
                active = true;
                continue;
            }
            if (code == '%') token.writer.writeByte('%') catch return error.OutOfMemory else if (code == 'c') token.writer.writeAll(entry.name) catch return error.OutOfMemory else if (code == 'k') token.writer.writeAll(entry.path) catch return error.OutOfMemory else return error.InvalidExec;
            active = true;
            i += 2;
            continue;
        }
        if (ch == '%') return error.InvalidExec;
        if (whole_code != null) return error.InvalidExec;
        if (!quoted and std.mem.indexOfScalar(u8, "'`$><~|&;*?#()", ch) != null) return error.InvalidExec;
        token.writer.writeByte(ch) catch return error.OutOfMemory;
        active = true;
        i += 1;
    }
    if (quoted) return error.InvalidExec;
}

fn appendWholeCode(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), code: u8, entry: *const Entry) !void {
    if (code == 'i' and entry.icon != null) {
        try argv.append(allocator, "--icon");
        try argv.append(allocator, try allocator.dupe(u8, entry.icon.?));
    }
}

fn validRoot(value: []const u8) bool {
    return value.len != 0 and std.fs.path.isAbsolute(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}
fn appendCopy(a: std.mem.Allocator, list_: *std.ArrayList([]const u8), value: []const u8) !void {
    const copy = try a.dupe(u8, value);
    errdefer a.free(copy);
    try list_.append(a, copy);
}
fn firstNonEmpty(values: []const ?[]const u8) []const u8 {
    for (values) |optional| if (optional) |value| if (value.len != 0) return value;
    return "";
}
fn validDesktopId(id: []const u8) bool {
    return id.len > ".desktop".len and std.mem.endsWith(u8, id, ".desktop") and id[0] != '-' and std.mem.indexOfAny(u8, id, "/\\\x00") == null;
}
fn freeStrings(a: std.mem.Allocator, list_: *std.ArrayList([]const u8)) void {
    for (list_.items) |value| a.free(value);
    list_.deinit(a);
}
fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '[' and ch != ']' and ch != '_' and ch != '@' and ch != '.') return false;
    return true;
}
fn findGroup(groups: []Group, name: []const u8) ?*const std.StringHashMapUnmanaged([]const u8) {
    for (groups) |*group| if (std.mem.eql(u8, group.name, name)) return &group.pairs;
    return null;
}
fn boolean(group: *const std.StringHashMapUnmanaged([]const u8), key: []const u8, default: bool) !bool {
    const value = group.get(key) orelse return default;
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.MalformedDesktopEntry;
}
fn tryUnescape(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] == '\\') {
            if (i + 1 == value.len) return error.MalformedDesktopEntry;
            const ch = value[i + 1];
            out.writer.writeByte(switch (ch) {
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => return error.MalformedDesktopEntry,
            }) catch return error.OutOfMemory;
            i += 2;
        } else {
            out.writer.writeByte(value[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.toOwnedSlice();
}
fn optionalString(a: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try tryUnescape(a, text) else null;
}
fn localizedRaw(group: *const std.StringHashMapUnmanaged([]const u8), base: []const u8, locale_input: []const u8) !?[]const u8 {
    var locale = locale_input;
    var owned_locale: ?[]u8 = null;
    defer if (owned_locale) |value| std.heap.page_allocator.free(value);
    if (std.mem.indexOfScalar(u8, locale, '.')) |dot| {
        const at = std.mem.indexOfPos(u8, locale, dot, "@") orelse locale.len;
        if (at < locale.len) {
            owned_locale = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ locale[0..dot], locale[at..] });
            locale = owned_locale.?;
        } else locale = locale[0..dot];
    }
    if (locale.len != 0 and !std.mem.eql(u8, locale, "C") and !std.mem.eql(u8, locale, "POSIX")) {
        var candidates: [4][]const u8 = undefined;
        var count: usize = 0;
        candidates[count] = locale;
        count += 1;
        const under = std.mem.indexOfScalar(u8, locale, '_');
        const at = std.mem.indexOfScalar(u8, locale, '@');
        var owned_langmod: ?[]u8 = null;
        defer if (owned_langmod) |value| std.heap.page_allocator.free(value);
        if (under != null and at != null) {
            candidates[count] = locale[0..at.?];
            count += 1;
            owned_langmod = try std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ locale[0..under.?], locale[at.?..] });
            candidates[count] = owned_langmod.?;
            count += 1;
        }
        candidates[count] = locale[0 .. under orelse at orelse locale.len];
        count += 1;
        for (candidates[0..count]) |candidate| {
            const key = try std.fmt.allocPrint(std.heap.page_allocator, "{s}[{s}]", .{ base, candidate });
            defer std.heap.page_allocator.free(key);
            if (group.get(key)) |value| return value;
        }
    }
    return group.get(base);
}
fn localized(a: std.mem.Allocator, group: *const std.StringHashMapUnmanaged([]const u8), base: []const u8, locale: []const u8) !?[]const u8 {
    return if (try localizedRaw(group, base, locale)) |value| try tryUnescape(a, value) else null;
}
fn splitList(a: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |item| a.free(item);
        result.deinit(a);
    }
    var current: std.Io.Writer.Allocating = .init(a);
    defer current.deinit();
    var i: usize = 0;
    while (i <= value.len) {
        if (i == value.len or value[i] == ';') {
            if (current.written().len != 0) try result.append(a, try current.toOwnedSlice());
            current = .init(a);
            i += 1;
            continue;
        }
        if (value[i] == '\\') {
            if (i + 1 == value.len) return error.MalformedDesktopEntry;
            current.writer.writeByte(switch (value[i + 1]) {
                ';' => ';',
                's' => ' ',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                else => return error.MalformedDesktopEntry,
            }) catch return error.OutOfMemory;
            i += 2;
        } else {
            current.writer.writeByte(value[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return result.toOwnedSlice(a);
}
fn showIn(a: std.mem.Allocator, group: *const std.StringHashMapUnmanaged([]const u8), desktops: []const []const u8) !bool {
    const only = group.get("OnlyShowIn");
    const not = group.get("NotShowIn");
    const only_list = if (only) |value| try splitList(a, value) else &.{};
    const not_list = if (not) |value| try splitList(a, value) else &.{};
    for (desktops) |desktop| {
        if (contains(not_list, desktop)) return false;
        if (contains(only_list, desktop)) return true;
    }
    return only == null;
}

test "XDG applications Exec preparation is literal and expands metadata" {
    const entry: Entry = .{ .id = "x.desktop", .path = "/x.desktop", .name = "A; touch /tmp/pwn", .generic_name = null, .comment = null, .icon = "x icon", .exec = "app \"two words\" %c %i %% %F", .working_directory = "/tmp", .keywords = &.{}, .actions = &.{}, .hidden = false, .no_display = false, .terminal = false, .dbus_activatable = false, .visible = true };
    var launch = try prepareLaunch(std.testing.allocator, &entry, .{});
    defer launch.deinit();
    try std.testing.expectEqual(@as(usize, 6), launch.argv.len);
    try std.testing.expectEqualStrings("A; touch /tmp/pwn", launch.argv[2]);
    try std.testing.expectEqualStrings("--icon", launch.argv[3]);
    try std.testing.expectError(error.TerminalRequired, prepareLaunch(std.testing.allocator, &.{ .id = "x", .path = "x", .name = "x", .generic_name = null, .comment = null, .icon = null, .exec = "x", .working_directory = null, .keywords = &.{}, .actions = &.{}, .hidden = false, .no_display = false, .terminal = true, .dbus_activatable = false, .visible = true }, .{}));
}

fn testRoot(allocator: std.mem.Allocator, temporary: *std.testing.TmpDir) ![:0]u8 {
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path });
    defer allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, allocator);
}

fn testWrite(root: []const u8, relative: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, relative });
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(path).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn testList(config: *const Config) !Catalog {
    var loop: @import("../loop/root.zig").Loop = undefined;
    try loop.init(std.testing.allocator, 16, 16);
    defer loop.deinit();
    var scan: Scan = undefined;
    try scan.init(std.testing.allocator, &loop, config);
    defer scan.deinit();
    try scan.start();
    while (!scan.finished()) {
        _ = try loop.submit();
        switch (loop.dispatch(try loop.wait())) {
            .file => |completion| try std.testing.expect(try scan.dispatch(completion)),
            .operation_cancel => {},
            else => return error.UnexpectedCompletion,
        }
        try scan.collectCanceled();
    }
    return (try scan.take()).?;
}

test "XDG applications scan applies nested ids shadowing locale and visibility" {
    var high = std.testing.tmpDir(.{});
    defer high.cleanup();
    var low = std.testing.tmpDir(.{});
    defer low.cleanup();
    const high_root = try testRoot(std.testing.allocator, &high);
    defer std.testing.allocator.free(high_root);
    const low_root = try testRoot(std.testing.allocator, &low);
    defer std.testing.allocator.free(low_root);
    try testWrite(high_root, "applications/sub/app.desktop", "[Desktop Entry]\nType=Application\nName=Base\nName[sr]=Localized\nExec=app\nHidden=true\n");
    try testWrite(low_root, "applications/sub/app.desktop", "[Desktop Entry]\nType=Application\nName=Shadowed\nExec=app\n");
    try testWrite(low_root, "applications/other.desktop", "[Desktop Entry]\nType=Application\nName=Other\nExec=app\nOnlyShowIn=GNOME;\n");
    const config: Config = .{ .roots = &.{ high_root, low_root }, .locale = "sr_RS.UTF-8", .desktops = &.{"KDE"} };
    var catalog = try testList(&config);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try std.testing.expectEqualStrings("other.desktop", catalog.entries[0].id);
    try std.testing.expect(!catalog.entries[0].visible);
    try std.testing.expectEqualStrings("sub-app.desktop", catalog.entries[1].id);
    try std.testing.expectEqualStrings("Localized", catalog.entries[1].name);
    try std.testing.expect(catalog.entries[1].hidden);
    try std.testing.expect(!catalog.entries[1].visible);
}

fn testEntry(exec: ?[]const u8) Entry {
    return .{ .id = "x.desktop", .path = "/x.desktop", .name = "Name", .generic_name = null, .comment = null, .icon = null, .exec = exec, .working_directory = null, .keywords = &.{}, .actions = &.{}, .hidden = false, .no_display = false, .terminal = false, .dbus_activatable = false, .visible = true };
}

fn expectArgv(entry: *const Entry, expected: []const []const u8) !void {
    var launch = try prepareLaunch(std.testing.allocator, entry, .{});
    defer launch.deinit();
    try std.testing.expectEqual(expected.len, launch.argv.len);
    for (expected, launch.argv) |want, actual| try std.testing.expectEqualStrings(want, actual);
}

test "XDG applications Exec tokenizer preserves empties and rejects boundaries" {
    var entry = testEntry("app \"\" \";$()\" literal %% %F");
    try expectArgv(&entry, &.{ "app", "", ";$()", "literal", "%" });
    const invalid = [_][]const u8{ "app %Ftail", "app %iTAIL", "app %F %u", "app %", "app \"open", "=bad arg", "%c arg", "app\narg", "app ; bad", "" };
    for (invalid) |command| {
        entry.exec = command;
        try std.testing.expectError(error.InvalidExec, prepareLaunch(std.testing.allocator, &entry, .{}));
    }
    const actions = [_]Action{.{ .id = "missing", .name = "Missing", .exec = null, .icon = null }};
    entry.exec = "app";
    entry.actions = &actions;
    try std.testing.expectError(error.NoExec, prepareLaunch(std.testing.allocator, &entry, .{ .action = "missing" }));
    try std.testing.expectError(error.UnknownAction, prepareLaunch(std.testing.allocator, &entry, .{ .action = "unknown" }));
    entry.terminal = true;
    try std.testing.expectError(error.TerminalRequired, prepareLaunch(std.testing.allocator, &entry, .{}));
    var terminal = try prepareLaunch(std.testing.allocator, &entry, .{ .terminal_argv = &.{ "term", "-e" } });
    defer terminal.deinit();
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "term", "-e", "app" }), terminal.argv);
}

test "XDG applications malformed shadow NoDisplay locale lists and keywords" {
    var high = std.testing.tmpDir(.{});
    defer high.cleanup();
    var low = std.testing.tmpDir(.{});
    defer low.cleanup();
    const high_root = try testRoot(std.testing.allocator, &high);
    defer std.testing.allocator.free(high_root);
    const low_root = try testRoot(std.testing.allocator, &low);
    defer std.testing.allocator.free(low_root);
    try testWrite(high_root, "applications/bad.desktop", "not a desktop file\n");
    try testWrite(low_root, "applications/bad.desktop", "[Desktop Entry]\nType=Application\nName=must not appear\nExec=app\n");
    try testWrite(low_root, "applications/good.desktop", "[Desktop Entry]\nType=Application\nName=Base\nName[sr@latin]=Fallback\nExec=app\nNoDisplay=true\nOnlyShowIn=Desk\\;Top;KDE;\nKeywords=one\\;two;slash\\\\end;space\\sword;\n");
    const config: Config = .{ .roots = &.{ high_root, low_root }, .locale = "sr_RS.UTF-8@latin", .desktops = &.{"KDE"} };
    var catalog = try testList(&config);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    const entry = catalog.entries[0];
    try std.testing.expectEqualStrings("Fallback", entry.name);
    try std.testing.expect(entry.no_display and !entry.visible);
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "one;two", "slash\\end", "space word" }), entry.keywords);
}

test "XDG applications accepts duplicate keys with group-local last-value precedence" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const entry = (try parse(arena.allocator(),
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Old name
        \\Name=Google Chrome
        \\Exec=old-command
        \\Exec=/usr/bin/google-chrome-stable %U
        \\StartupWMClass=Google-chrome
        \\StartupWMClass=google-chrome
        \\NoDisplay=true
        \\NoDisplay=false
        \\Actions=new-window;
        \\[Desktop Action new-window]
        \\Name=New Window
        \\Exec=/usr/bin/google-chrome-stable
        \\StartupWMClass=Google-chrome
    , "google-chrome.desktop", "/test/google-chrome.desktop", &.{ .roots = &.{} })).?;
    try std.testing.expect(entry.visible);
    try std.testing.expectEqualStrings("Google Chrome", entry.name);
    try std.testing.expectEqualStrings("/usr/bin/google-chrome-stable %U", entry.exec.?);
    try std.testing.expectEqual(@as(usize, 1), entry.actions.len);
    try std.testing.expectEqualStrings("New Window", entry.actions[0].name);
    try std.testing.expectEqualStrings("/usr/bin/google-chrome-stable", entry.actions[0].exec.?);
}

test "XDG applications preserves TryExec without filtering missing or nonexecutable targets" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try testRoot(std.testing.allocator, &temporary);
    defer std.testing.allocator.free(root);
    try testWrite(root, "bin/plain", "plain\n");
    const plain = try std.fs.path.join(std.testing.allocator, &.{ root, "bin/plain" });
    defer std.testing.allocator.free(plain);
    const desktop = try std.fmt.allocPrint(std.testing.allocator, "[Desktop Entry]\nType=Application\nName=plain\nExec=app\nTryExec={s}\n", .{plain});
    defer std.testing.allocator.free(desktop);
    try testWrite(root, "applications/plain.desktop", desktop);
    try testWrite(root, "applications/missing.desktop", "[Desktop Entry]\nType=Application\nName=missing\nExec=app\nTryExec=ourokit-nonexistent-test-executable\n");
    const config: Config = .{ .roots = &.{root} };
    var catalog = try testList(&config);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try std.testing.expect(catalog.entries[0].visible);
    try std.testing.expect(catalog.entries[1].visible);
    try std.testing.expectEqualStrings("ourokit-nonexistent-test-executable", catalog.entries[0].try_exec.?);
    try std.testing.expectEqualStrings(plain, catalog.entries[1].try_exec.?);
}

test "XDG applications follows symlink directories and files without cycles" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try testRoot(std.testing.allocator, &temporary);
    defer std.testing.allocator.free(root);
    try testWrite(root, "real/app.desktop", "[Desktop Entry]\nType=Application\nName=linked\nExec=app\n");
    const applications = try std.fs.path.join(std.testing.allocator, &.{ root, "applications" });
    defer std.testing.allocator.free(applications);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, applications);
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, applications, .{});
    defer dir.close(std.testing.io);
    try dir.symLink(std.testing.io, "../real", "linked", .{ .is_directory = true });
    try dir.symLink(std.testing.io, ".", "cycle", .{ .is_directory = true });
    try dir.symLink(std.testing.io, "../real/app.desktop", "file.desktop", .{});
    const config: Config = .{ .roots = &.{root} };
    var catalog = try testList(&config);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 2), catalog.entries.len);
    try std.testing.expectEqualStrings("file.desktop", catalog.entries[0].id);
    try std.testing.expectEqualStrings("linked-app.desktop", catalog.entries[1].id);
}

test "XDG applications rejects oversize and depth and ignores FIFO" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try testRoot(std.testing.allocator, &temporary);
    defer std.testing.allocator.free(root);
    const huge = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    try testWrite(root, "applications/huge.desktop", huge);
    const config: Config = .{ .roots = &.{root} };
    try std.testing.expectError(error.CatalogCapacityExceeded, testList(&config));

    try temporary.dir.deleteTree(std.testing.io, "applications");
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(std.testing.allocator);
    try nested.appendSlice(std.testing.allocator, "applications");
    for (0..max_depth + 1) |_| try nested.appendSlice(std.testing.allocator, "/d");
    try nested.appendSlice(std.testing.allocator, "/deep.desktop");
    try testWrite(root, nested.items, "[Desktop Entry]\nType=Application\nName=deep\nExec=app\n");
    try std.testing.expectError(error.CatalogCapacityExceeded, testList(&config));

    try temporary.dir.deleteTree(std.testing.io, "applications");
    try testWrite(root, "applications/good.desktop", "[Desktop Entry]\nType=Application\nName=good\nExec=app\n");
    const fifo = try std.fs.path.join(std.testing.allocator, &.{ root, "applications/pipe.desktop" });
    defer std.testing.allocator.free(fifo);
    const fifo_z = try std.testing.allocator.dupeZ(u8, fifo);
    defer std.testing.allocator.free(fifo_z);
    try std.testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.mknod(fifo_z, std.os.linux.S.IFIFO | 0o600, 0)));
    var catalog = try testList(&config);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.entries.len);
    try std.testing.expectEqualStrings("good.desktop", catalog.entries[0].id);
}

test "XDG applications prepare allocation failures retain ownership" {
    const entry = testEntry("app \"two words\" %%");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator, value: *const Entry) !void {
            var launch = try prepareLaunch(a, value, .{});
            launch.deinit();
        }
    }.run, .{&entry});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            var config = try Config.init(a, .empty);
            config.deinit();
        }
    }.run, .{});
}
