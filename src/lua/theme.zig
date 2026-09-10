const std = @import("std");
const c = @import("c.zig");
const core = @import("../core/root.zig");
const tokens = @import("../design/root.zig").tokens;

pub const Theme = struct {
    colors: tokens.Theme,
    typography: Typography = .{},
    controls: Controls = .{},
    widgets: Widgets = .{},
};

pub const Typography = struct {
    /// Null preserves the widget-specific built-in font size.
    size: ?f32 = null,
    family: Family = .{},
};

/// An empty default selects the font injected by the host. Parsed names own
/// their storage and remain valid after their Lua state is closed.
pub const Family = struct {
    bytes: [127]u8 = @splat(0),
    len: u8 = 0,

    pub fn name(self: *const Family) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Controls = struct {
    height: f32 = 32,
    /// Null preserves the widget-specific built-in value.
    radius: ?f32 = null,
    border_width: ?f32 = null,
};

pub const Widgets = struct {
    button: Overrides = .{},
    text_input: Overrides = .{},
    option: Overrides = .{},
    label: Overrides = .{},
};

pub const Overrides = struct {
    height: ?f32 = null,
    padding_x: ?f32 = null,
    radius: ?f32 = null,
    border_width: ?f32 = null,
    font_size: ?f32 = null,
    background: ?core.Color = null,
    foreground: ?core.Color = null,
    border: ?core.Color = null,
    hover: ?core.Color = null,
    pressed: ?core.Color = null,
    disabled: ?core.Color = null,
    disabled_foreground: ?core.Color = null,
    focus: ?core.Color = null,
};

/// Merge raw Lua table fields into an inherited theme without retaining Lua
/// references. Description wrapper properties and already-validated dense
/// children are ignored. The stack is unchanged on success and error.
pub fn apply(state: *c.State, index: c_int, base: Theme) !Theme {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    if (c.lua_type(state, index) == c.type_nil) return base;
    if (c.lua_checkstack(state, 16) == 0) return error.OutOfMemory;
    return merge(Theme, state, index, base, "theme");
}

fn merge(comptime T: type, state: *c.State, index: c_int, base: T, comptime owner: []const u8) !T {
    if (c.lua_type(state, index) != c.type_table) return error.InvalidThemeType;
    const table = if (index < 0 and index > c.registry_index) c.lua_gettop(state) + index + 1 else index;
    var result = base;
    if (T == Theme) {
        // Explicit colors must win regardless of Lua's table iteration order.
        _ = c.lua_pushstring(state, "color_scheme");
        _ = c.lua_rawget(state, table);
        if (c.lua_type(state, -1) != c.type_nil) {
            const scheme = try string(state, -1);
            result.colors = if (std.mem.eql(u8, scheme, "light")) tokens.light else if (std.mem.eql(u8, scheme, "dark")) tokens.dark else return error.InvalidColorScheme;
        }
        c.lua_settop(state, -2);
    }
    c.lua_pushnil(state);
    while (c.lua_next(state, table) != 0) {
        defer c.lua_settop(state, -2);
        if (T == Theme and c.lua_isinteger(state, -2) != 0) {
            var is_number: c_int = 0;
            const child = c.lua_tointegerx(state, -2, &is_number);
            if (child >= 1 and child <= c.lua_rawlen(state, table)) continue;
            return error.UnknownThemeField;
        }
        if (c.lua_type(state, -2) != c.type_string) return error.UnknownThemeField;
        const key = try string(state, -2);
        if (T == Theme and (std.mem.eql(u8, key, "color_scheme") or
            std.mem.eql(u8, key, "key") or std.mem.eql(u8, key, "children") or
            std.mem.eql(u8, key, "flex"))) continue;
        inline for (std.meta.fields(T)) |field| {
            if (std.mem.eql(u8, key, field.name)) {
                if (T == Overrides and !supportsWidgetField(owner, field.name)) return error.UnknownThemeField;
                @field(result, field.name) = try value(field.type, state, -1, @field(result, field.name), field.name);
                break;
            }
        } else return error.UnknownThemeField;
    }
    return result;
}

fn supportsWidgetField(comptime widget: []const u8, comptime field: []const u8) bool {
    if (std.mem.eql(u8, widget, "label"))
        return std.mem.eql(u8, field, "foreground") or std.mem.eql(u8, field, "font_size");
    if (std.mem.eql(u8, widget, "text_input"))
        return !std.mem.eql(u8, field, "hover") and !std.mem.eql(u8, field, "pressed");
    if (std.mem.eql(u8, widget, "option"))
        return !std.mem.eql(u8, field, "disabled") and !std.mem.eql(u8, field, "disabled_foreground") and !std.mem.eql(u8, field, "focus");
    return true;
}

fn value(comptime T: type, state: *c.State, index: c_int, base: T, comptime key: []const u8) !T {
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        return try value(Child, state, index, base orelse std.mem.zeroes(Child), key);
    }
    if (T == f32) {
        const positive = comptime std.mem.eql(u8, key, "height") or std.mem.eql(u8, key, "font_size") or std.mem.eql(u8, key, "size");
        return extent(state, index, positive);
    }
    if (T == core.Color) return color(state, index);
    if (T == Family) {
        const text = try string(state, index);
        if (text.len == 0 or text.len > 127 or std.mem.indexOfScalar(u8, text, 0) != null or
            !std.unicode.utf8ValidateSlice(text)) return error.InvalidFontFamily;
        var family: Family = .{ .len = @intCast(text.len) };
        @memcpy(family.bytes[0..text.len], text);
        return family;
    }
    return merge(T, state, index, base, key);
}

/// Parse a numeric metric without coercion or stack changes. Positive values
/// that would underflow to zero in f32 are rejected along with overflow.
pub fn extent(state: *c.State, index: c_int, positive: bool) !f32 {
    if (c.lua_type(state, index) != c.type_number) return error.InvalidThemeType;
    var is_number: c_int = 0;
    const number = c.lua_tonumberx(state, index, &is_number);
    if (!std.math.isFinite(number) or number < 0 or number > std.math.floatMax(f32) or
        (positive and number == 0)) return error.InvalidThemeNumber;
    const narrowed: f32 = @floatCast(number);
    if (number != 0 and narrowed == 0) return error.InvalidThemeNumber;
    return narrowed;
}

/// Parse exactly #RRGGBB or #RRGGBBAA without changing the stack.
pub fn color(state: *c.State, index: c_int) !core.Color {
    const text = try string(state, index);
    if ((text.len != 7 and text.len != 9) or text[0] != '#') return error.InvalidThemeColor;
    var channels = [4]u8{ 0, 0, 0, 255 };
    for (0..(text.len - 1) / 2) |channel| {
        const start = 1 + channel * 2;
        const high = std.fmt.charToDigit(text[start], 16) catch return error.InvalidThemeColor;
        const low = std.fmt.charToDigit(text[start + 1], 16) catch return error.InvalidThemeColor;
        channels[channel] = high * 16 + low;
    }
    return core.Color.rgba(channels[0], channels[1], channels[2], channels[3]);
}

fn string(state: *c.State, index: c_int) ![]const u8 {
    if (c.lua_type(state, index) != c.type_string) return error.InvalidThemeType;
    var len: usize = 0;
    const bytes = c.lua_tolstring(state, index, &len) orelse return error.InvalidThemeType;
    return bytes[0..len];
}

fn loadTestValue(state: *c.State, source: []const u8) !void {
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(state, source.ptr, source.len, "theme-test", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(state, 0, 1, 0, 0, null));
}

fn parseTestValue(state: *c.State, source: []const u8, base: Theme) !Theme {
    const top = c.lua_gettop(state);
    defer c.lua_settop(state, top);
    try loadTestValue(state, source);
    const result = try apply(state, -1, base);
    try std.testing.expectEqual(top + 1, c.lua_gettop(state));
    return result;
}

test "lua theme inherits nested overrides and preserves zero metrics" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    const defaults: Theme = .{ .colors = tokens.light };
    try std.testing.expectEqualStrings("", defaults.typography.family.name());
    try std.testing.expectEqual(@as(?f32, null), defaults.typography.size);
    try std.testing.expectEqualDeep(Controls{ .height = 32, .radius = null, .border_width = null }, defaults.controls);
    try std.testing.expectEqualDeep(defaults, try parseTestValue(state, "return nil", defaults));
    const base = try parseTestValue(state,
        \\return {
        \\  colors = {primary = '#12aB34', ring = '#235689ab'},
        \\  typography = {size = 19, family = 'Noto 日本語'},
        \\  controls = {height = 41, radius = 7, border_width = 2},
        \\  widgets = {button = {padding_x = 13, foreground = '#654321'},
        \\             label = {font_size = 17}, option = {height = 23},
        \\             text_input = {border_width = 3}}
        \\}
    , defaults);
    const child = try parseTestValue(state,
        \\return {key = 'scope', children = {}, flex = 1,
        \\  typography = {size = 21}, controls = {radius = 0, border_width = 0},
        \\  widgets = {button = {padding_x = 0, radius = 0, border_width = 0}}
        \\}
    , base);
    var expected = base;
    expected.typography.size = 21;
    expected.controls.radius = 0;
    expected.controls.border_width = 0;
    expected.widgets.button.padding_x = 0;
    expected.widgets.button.radius = 0;
    expected.widgets.button.border_width = 0;
    try std.testing.expectEqualDeep(expected, child);
    try std.testing.expectEqualStrings("Noto 日本語", child.typography.family.name());
    try std.testing.expectEqual(core.Color.rgba(0x12, 0xab, 0x34, 255), child.colors.primary);
    try std.testing.expectEqual(core.Color.rgba(0x23, 0x56, 0x89, 0xab), child.colors.ring);
    try std.testing.expectEqualDeep(base, try parseTestValue(state, "return {{}, {}, key = 'dense'}", base));
}

test "lua theme color scheme replaces colors only and explicit colors win" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    const base = try parseTestValue(
        state,
        "return {typography={size=22,family='Custom'},controls={height=45},widgets={button={hover='#ab341256'}},colors={primary='#010203'}}",
        .{ .colors = tokens.light },
    );
    const dark = try parseTestValue(state, "return {colors={background='#123456'},color_scheme='dark'}", base);
    var expected = base;
    expected.colors = tokens.dark;
    expected.colors.background = core.Color.rgba(0x12, 0x34, 0x56, 255);
    try std.testing.expectEqualDeep(expected, dark);
    expected.colors = tokens.light;
    try std.testing.expectEqualDeep(expected, try parseTestValue(state, "return {color_scheme='light'}", dark));
}

test "lua theme accepts every generated color and validates each widget field set" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    const base: Theme = .{ .colors = tokens.dark };
    inline for (std.meta.fields(tokens.Theme)) |field| {
        const parsed = try parseTestValue(state, "return {colors={" ++ field.name ++ "='#135a9fc2'}}", base);
        var expected = base;
        @field(expected.colors, field.name) = core.Color.rgba(0x13, 0x5a, 0x9f, 0xc2);
        try std.testing.expectEqualDeep(expected, parsed);
    }
    const supported = .{
        .{ "button", ",height,padding_x,radius,border_width,font_size,background,foreground,border,hover,pressed,disabled,disabled_foreground,focus," },
        .{ "text_input", ",height,padding_x,radius,border_width,font_size,background,foreground,border,disabled,disabled_foreground,focus," },
        .{ "option", ",height,padding_x,radius,border_width,font_size,background,foreground,border,hover,pressed," },
        .{ "label", ",foreground,font_size," },
    };
    inline for (supported) |widget| {
        inline for (std.meta.fields(Overrides)) |field| {
            const numeric = field.type == ?f32;
            const literal = if (numeric) "2.5" else "'#aB1234cd'";
            const result = parseTestValue(state, "return {widgets={" ++ widget[0] ++ "={" ++ field.name ++ "=" ++ literal ++ "}}}", base);
            if (std.mem.indexOf(u8, widget[1], "," ++ field.name ++ ",") != null) {
                var expected = base;
                @field(@field(expected.widgets, widget[0]), field.name) = if (numeric) 2.5 else core.Color.rgba(0xab, 0x12, 0x34, 0xcd);
                try std.testing.expectEqualDeep(expected, try result);
            } else {
                try std.testing.expectError(error.UnknownThemeField, result);
            }
        }
        try std.testing.expectError(error.UnknownThemeField, parseTestValue(state, "return {widgets={" ++ widget[0] ++ "={padding_y=0}}}", base));
    }
}

test "lua theme rejects unknown fields and invalid values without changing the stack" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    const cases = .{
        .{ "return true", error.InvalidThemeType },
        .{ "return {unknown=1}", error.UnknownThemeField },
        .{ "return {[false]=1}", error.UnknownThemeField },
        .{ "return {[0]={}}", error.UnknownThemeField },
        .{ "return {[1.5]={}}", error.UnknownThemeField },
        .{ "return {colors={key='x'}}", error.UnknownThemeField },
        .{ "return {typography={unknown=1}}", error.UnknownThemeField },
        .{ "return {controls={padding=1}}", error.UnknownThemeField },
        .{ "return {widgets={slider={}}}", error.UnknownThemeField },
        .{ "return {widgets={button={children={}}}}", error.UnknownThemeField },
        .{ "return {widgets={label={[1]=2}}}", error.UnknownThemeField },
        .{ "return {colors=false}", error.InvalidThemeType },
        .{ "return {typography=7}", error.InvalidThemeType },
        .{ "return {controls='x'}", error.InvalidThemeType },
        .{ "return {widgets=false}", error.InvalidThemeType },
        .{ "return {widgets={option=1}}", error.InvalidThemeType },
        .{ "return {color_scheme='sepia'}", error.InvalidColorScheme },
        .{ "return {color_scheme=1}", error.InvalidThemeType },
        .{ "return {typography={family=123}}", error.InvalidThemeType },
        .{ "return {typography={family=''}}", error.InvalidFontFamily },
        .{ "return {typography={family='a\\0b'}}", error.InvalidFontFamily },
        .{ "return {typography={family='\\255'}}", error.InvalidFontFamily },
        .{ "return {typography={family='\\192\\128'}}", error.InvalidFontFamily },
        .{ "return {typography={family='" ++ "a" ** 128 ++ "'}}", error.InvalidFontFamily },
    };
    inline for (cases) |case| {
        try loadTestValue(state, case[0]);
        const original_type = c.lua_type(state, -1);
        c.lua_pushinteger(state, 987);
        const top = c.lua_gettop(state);
        try std.testing.expectError(case[1], apply(state, -2, .{ .colors = tokens.light }));
        try std.testing.expectEqual(top, c.lua_gettop(state));
        var is_number: c_int = 0;
        try std.testing.expectEqual(@as(c.Integer, 987), c.lua_tointegerx(state, -1, &is_number));
        try std.testing.expectEqual(original_type, c.lua_type(state, -2));
        c.lua_settop(state, 0);
    }
    inline for (.{ "'12'", "false", "{}", "-1", "1/0", "-1/0", "0/0", "3.5e38", "1e-100" }) |literal| {
        inline for (.{ "controls={radius=", "controls={height=", "typography={size=", "widgets={button={padding_x=" }) |prefix| {
            const close = if (comptime std.mem.startsWith(u8, prefix, "widgets")) "}}}" else "}}";
            try loadTestValue(state, "return {" ++ prefix ++ literal ++ close);
            const result = apply(state, 1, .{ .colors = tokens.light });
            try std.testing.expect(if (result) |_| false else |_| true);
            try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
            c.lua_settop(state, 0);
        }
    }
    inline for (.{ "controls={height=0}", "typography={size=0}", "widgets={label={font_size=0}}", "widgets={option={height=0}}" }) |fields| {
        try loadTestValue(state, "return {" ++ fields ++ "}");
        try std.testing.expectError(error.InvalidThemeNumber, apply(state, 1, .{ .colors = tokens.light }));
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        c.lua_settop(state, 0);
    }
    inline for (.{ "''", "'#abc'", "'1234567'", "'#12345g'", "'#1234567'", "'#123456789'", "'#123456  '", "'#12+345'", "42", "{}" }) |literal| {
        try loadTestValue(state, "return {widgets={text_input={focus=" ++ literal ++ "}}}");
        const result = apply(state, 1, .{ .colors = tokens.light });
        try std.testing.expect(if (result) |_| false else |_| true);
        try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
        c.lua_settop(state, 0);
    }
}

test "lua theme copies family bytes independently and accepts f32 boundaries" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    const base = parseTestValue(state, "return {typography={family='" ++ "x" ** 127 ++ "'}}", .{ .colors = tokens.light }) catch |err| {
        c.lua_close(state);
        return err;
    };
    c.lua_close(state);
    var child = base;
    child.typography.family.bytes[0] = 'y';
    try std.testing.expectEqualStrings("x" ** 127, base.typography.family.name());
    try std.testing.expectEqualStrings("y" ++ "x" ** 126, child.typography.family.name());

    const other = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(other);
    const parsed = try parseTestValue(other, "return {controls={height=3.4028234663852886e38,radius=1.401298464324817e-45},typography={family='Short'}}", base);
    try std.testing.expectEqual(std.math.floatMax(f32), parsed.controls.height);
    try std.testing.expectEqual(@as(f32, @bitCast(@as(u32, 1))), parsed.controls.radius);
    try std.testing.expectEqualStrings("Short", parsed.typography.family.name());
    try std.testing.expectEqualStrings("x" ** 127, base.typography.family.name());
}

test "lua theme scalar parsers preserve values and stack on success and failure" {
    const state = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(state);
    try loadTestValue(state, "return '#1234aB80'");
    try std.testing.expectEqual(core.Color.rgba(0x12, 0x34, 0xab, 0x80), try color(state, 1));
    try std.testing.expectError(error.InvalidThemeType, extent(state, 1, false));
    try std.testing.expectEqual(c.type_string, c.lua_type(state, 1));
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
    c.lua_settop(state, 0);
    try loadTestValue(state, "return 0");
    try std.testing.expectEqual(@as(f32, 0), try extent(state, -1, false));
    try std.testing.expectError(error.InvalidThemeNumber, extent(state, -1, true));
    try std.testing.expectError(error.InvalidThemeType, color(state, -1));
    try std.testing.expectEqual(c.type_number, c.lua_type(state, 1));
    try std.testing.expectEqual(@as(c_int, 1), c.lua_gettop(state));
}
