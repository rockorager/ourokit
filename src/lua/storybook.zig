const std = @import("std");
const c = @import("c.zig");

pub const ColorScheme = enum { light, dark };

pub const Viewport = struct {
    width: u32 = 640,
    height: u32 = 480,
    scale: f32 = 1,
};

pub const ActionKind = enum { hover, pointer_down, click };

pub const Action = struct {
    kind: ActionKind,
    target: []u8,
};

pub const Story = struct {
    id: []u8,
    group: []u8,
    name: []u8,
    viewport: Viewport,
    color_scheme: ColorScheme,
    actions: []Action,
    content_reference: c_int,
};

/// One validated Storybook catalog. Strings are native-owned and content
/// callbacks remain anchored in the registry until `deinit`.
pub const Storybook = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    title: []u8,
    stories: []Story,

    pub fn load(
        allocator: std.mem.Allocator,
        state: *c.State,
        source: []const u8,
    ) !Storybook {
        try installConstructors(state);
        const top = c.lua_gettop(state);
        defer c.lua_settop(state, top);
        if (c.luaL_loadbufferx(state, source.ptr, source.len, "@storybook", null) != c.ok)
            return error.LuaLoadFailed;
        if (c.lua_pcallk(state, 0, 1, 0, 0, null) != c.ok)
            return error.LuaStorybookFailed;
        if (c.lua_type(state, -1) != c.type_table) return error.StorybookDeclarationRequired;
        try expectTag(state, -1, "storybook");

        const title = try optionalString(allocator, state, -1, "title", "Ourokit Storybook");
        errdefer allocator.free(title);
        if (c.lua_getfield(state, -1, "stories") != c.type_table)
            return error.StoriesDeclarationRequired;
        const count = c.lua_rawlen(state, -1);
        if (count == 0) return error.StorybookRequiresStory;
        const stories = try allocator.alloc(Story, count);
        errdefer allocator.free(stories);
        var initialized: usize = 0;
        errdefer for (stories[0..initialized]) |story| deinitStory(allocator, state, story);

        for (stories, 1..) |*story, index| {
            if (c.lua_rawgeti(state, -1, @intCast(index)) != c.type_table)
                return error.InvalidStoryDeclaration;
            try expectTag(state, -1, "story");
            const id = try requiredString(allocator, state, -1, "id");
            errdefer allocator.free(id);
            if (!validId(id)) return error.InvalidStoryId;
            for (stories[0..initialized]) |existing|
                if (std.mem.eql(u8, id, existing.id)) return error.DuplicateStoryId;
            const name = try requiredString(allocator, state, -1, "name");
            errdefer allocator.free(name);
            const group = try optionalString(allocator, state, -1, "group", "Stories");
            errdefer allocator.free(group);
            const viewport = try parseViewport(state, -1);
            const color_scheme = try parseColorScheme(state, -1);
            const actions = try parseActions(allocator, state, -1);
            errdefer deinitActions(allocator, actions);
            if (c.lua_getfield(state, -1, "content") != c.type_function)
                return error.StoryContentRequired;
            const content_reference = c.luaL_ref(state, c.registry_index);
            story.* = .{
                .id = id,
                .group = group,
                .name = name,
                .viewport = viewport,
                .color_scheme = color_scheme,
                .actions = actions,
                .content_reference = content_reference,
            };
            initialized += 1;
            c.lua_settop(state, -2);
        }
        return .{
            .allocator = allocator,
            .state = state,
            .title = title,
            .stories = stories,
        };
    }

    pub fn deinit(self: *Storybook) void {
        for (self.stories) |story| deinitStory(self.allocator, self.state, story);
        self.allocator.free(self.stories);
        self.allocator.free(self.title);
        self.* = undefined;
    }

    pub fn find(self: *const Storybook, id: []const u8) ?*const Story {
        for (self.stories) |*story| if (std.mem.eql(u8, story.id, id)) return story;
        return null;
    }
};

fn installConstructors(state: *c.State) !void {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.lua_getglobal(state, "ouro") != c.type_table) return error.OuroApiMissing;
    c.lua_pushcclosure(state, storybookConstructor, 0);
    c.lua_setfield(state, -2, "storybook");
    c.lua_pushcclosure(state, storyConstructor, 0);
    c.lua_setfield(state, -2, "story");
}

fn storybookConstructor(state: *c.State) callconv(.c) c_int {
    return taggedTable(state, "storybook");
}

fn storyConstructor(state: *c.State) callconv(.c) c_int {
    return taggedTable(state, "story");
}

fn taggedTable(state: *c.State, tag: [*:0]const u8) c_int {
    if (c.lua_gettop(state) != 1 or c.lua_type(state, 1) != c.type_table)
        return luaError(state, "constructor expects one declaration table");
    _ = c.lua_pushstring(state, tag);
    c.lua_setfield(state, 1, "type");
    c.lua_pushvalue(state, 1);
    return 1;
}

fn expectTag(state: *c.State, table: c_int, expected: []const u8) !void {
    if (c.lua_getfield(state, table, "type") != c.type_string)
        return error.InvalidStorybookDeclaration;
    defer c.lua_settop(state, -2);
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse
        return error.InvalidStorybookDeclaration;
    if (!std.mem.eql(u8, value[0..length], expected))
        return error.InvalidStorybookDeclaration;
}

fn requiredString(
    allocator: std.mem.Allocator,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
) ![]u8 {
    if (c.lua_getfield(state, table, field) != c.type_string) return error.RequiredStringMissing;
    defer c.lua_settop(state, -2);
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.RequiredStringMissing;
    if (length == 0) return error.RequiredStringMissing;
    return allocator.dupe(u8, value[0..length]);
}

fn optionalString(
    allocator: std.mem.Allocator,
    state: *c.State,
    table: c_int,
    field: [*:0]const u8,
    default: []const u8,
) ![]u8 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return allocator.dupe(u8, default);
    if (value_type != c.type_string) return error.InvalidOptionalString;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.InvalidOptionalString;
    if (length == 0) return error.InvalidOptionalString;
    return allocator.dupe(u8, value[0..length]);
}

fn parseViewport(state: *c.State, table: c_int) !Viewport {
    const value_type = c.lua_getfield(state, table, "viewport");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .{};
    if (value_type != c.type_table) return error.InvalidStoryViewport;
    return .{
        .width = try optionalDimension(state, -1, "width", 640),
        .height = try optionalDimension(state, -1, "height", 480),
        .scale = try optionalScale(state, -1),
    };
}

fn optionalDimension(state: *c.State, table: c_int, field: [*:0]const u8, default: u32) !u32 {
    const value_type = c.lua_getfield(state, table, field);
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return default;
    var is_number: c_int = 0;
    const value = c.lua_tointegerx(state, -1, &is_number);
    if (is_number == 0 or value <= 0 or value > std.math.maxInt(u32))
        return error.InvalidStoryViewport;
    return @intCast(value);
}

fn optionalScale(state: *c.State, table: c_int) !f32 {
    const value_type = c.lua_getfield(state, table, "scale");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return 1;
    var is_number: c_int = 0;
    const value = c.lua_tonumberx(state, -1, &is_number);
    if (is_number == 0 or !std.math.isFinite(value) or value <= 0 or value > 16)
        return error.InvalidStoryViewport;
    return @floatCast(value);
}

fn parseColorScheme(state: *c.State, table: c_int) !ColorScheme {
    const value_type = c.lua_getfield(state, table, "color_scheme");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return .light;
    if (value_type != c.type_string) return error.InvalidStoryColorScheme;
    var length: usize = 0;
    const value = c.lua_tolstring(state, -1, &length) orelse return error.InvalidStoryColorScheme;
    if (std.mem.eql(u8, value[0..length], "light")) return .light;
    if (std.mem.eql(u8, value[0..length], "dark")) return .dark;
    return error.InvalidStoryColorScheme;
}

fn parseActions(allocator: std.mem.Allocator, state: *c.State, table: c_int) ![]Action {
    const value_type = c.lua_getfield(state, table, "actions");
    defer c.lua_settop(state, -2);
    if (value_type == c.type_nil) return allocator.alloc(Action, 0);
    if (value_type != c.type_table) return error.InvalidStoryActions;
    const count = c.lua_rawlen(state, -1);
    if (count > 64) return error.TooManyStoryActions;
    const actions = try allocator.alloc(Action, count);
    errdefer allocator.free(actions);
    var initialized: usize = 0;
    errdefer for (actions[0..initialized]) |action| allocator.free(action.target);
    for (actions, 1..) |*action, index| {
        if (c.lua_rawgeti(state, -1, @intCast(index)) != c.type_table)
            return error.InvalidStoryAction;
        const kind_value = try requiredString(allocator, state, -1, "type");
        defer allocator.free(kind_value);
        const kind: ActionKind = if (std.mem.eql(u8, kind_value, "hover"))
            .hover
        else if (std.mem.eql(u8, kind_value, "pointer_down"))
            .pointer_down
        else if (std.mem.eql(u8, kind_value, "click"))
            .click
        else
            return error.InvalidStoryActionType;
        const target = try requiredString(allocator, state, -1, "target");
        errdefer allocator.free(target);
        if (!validSelector(target)) return error.InvalidStoryActionTarget;
        action.* = .{ .kind = kind, .target = target };
        initialized += 1;
        c.lua_settop(state, -2);
    }
    return actions;
}

fn validSelector(path: []const u8) bool {
    if (path.len == 0) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (segment.len == 0) return false;
    return true;
}

fn validId(id: []const u8) bool {
    var segments = std.mem.splitScalar(u8, id, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return false;
        for (segment) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.')
            return false;
    }
    return true;
}

fn deinitStory(allocator: std.mem.Allocator, state: *c.State, story: Story) void {
    c.luaL_unref(state, c.registry_index, story.content_reference);
    deinitActions(allocator, story.actions);
    allocator.free(story.name);
    allocator.free(story.group);
    allocator.free(story.id);
}

fn deinitActions(allocator: std.mem.Allocator, actions: []Action) void {
    for (actions) |action| allocator.free(action.target);
    allocator.free(actions);
}

fn luaError(state: *c.State, message: [*:0]const u8) c_int {
    _ = c.lua_pushstring(state, message);
    return c.lua_error(state);
}

test "storybook declarations are owned, defaulted, and selectable" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    var book = try Storybook.load(std.testing.allocator, state,
        \\return ouro.storybook {
        \\  title = "Controls",
        \\  stories = {
        \\    ouro.story {
        \\      id = "button/dark",
        \\      group = "Button",
        \\      name = "Dark",
        \\      viewport = { width = 320, height = 180, scale = 2 },
        \\      color_scheme = "dark",
        \\      actions = {
        \\        { type = "hover", target = "content/button" },
        \\        { type = "pointer_down", target = "content/button" },
        \\      },
        \\      content = function() end,
        \\    },
        \\  },
        \\}
    );
    defer book.deinit();
    try std.testing.expectEqualStrings("Controls", book.title);
    const story = book.find("button/dark").?;
    try std.testing.expectEqualStrings("Button", story.group);
    try std.testing.expectEqual(@as(u32, 320), story.viewport.width);
    try std.testing.expectEqual(@as(f32, 2), story.viewport.scale);
    try std.testing.expectEqual(ColorScheme.dark, story.color_scheme);
    try std.testing.expectEqual(@as(usize, 2), story.actions.len);
    try std.testing.expectEqual(ActionKind.pointer_down, story.actions[1].kind);
    try std.testing.expectEqualStrings("content/button", story.actions[1].target);
}

test "storybook rejects unsafe and duplicate IDs" {
    const state = c.luaL_newstate() orelse return error.LuaStateCreationFailed;
    defer c.lua_close(state);
    c.lua_createtable(state, 0, 2);
    c.lua_setglobal(state, "ouro");
    try std.testing.expectError(error.InvalidStoryId, Storybook.load(std.testing.allocator, state,
        \\return ouro.storybook { stories = {
        \\  ouro.story { id = "../escape", name = "Bad", content = function() end },
        \\} }
    ));
    try std.testing.expectError(error.DuplicateStoryId, Storybook.load(std.testing.allocator, state,
        \\return ouro.storybook { stories = {
        \\  ouro.story { id = "same", name = "One", content = function() end },
        \\  ouro.story { id = "same", name = "Two", content = function() end },
        \\} }
    ));
    try std.testing.expectError(error.InvalidStoryActionType, Storybook.load(std.testing.allocator, state,
        \\return ouro.storybook { stories = {
        \\  ouro.story {
        \\    id = "action", name = "Bad action", content = function() end,
        \\    actions = { { type = "wait", target = "content/button" } },
        \\  },
        \\} }
    ));
    try std.testing.expectError(error.InvalidStoryActionTarget, Storybook.load(std.testing.allocator, state,
        \\return ouro.storybook { stories = {
        \\  ouro.story {
        \\    id = "target", name = "Bad target", content = function() end,
        \\    actions = { { type = "click", target = "content//button" } },
        \\  },
        \\} }
    ));
}
