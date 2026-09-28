const std = @import("std");
const platform = @import("../../platform/window.zig");
const KeyChord = @import("key_chord.zig").KeyChord;

pub const Kind = enum { key, press, release, motion, enter, leave, axis };
pub const State = enum { pressed, released, repeated };

/// Owned scalar data only: never exposes text, IME payloads or input serials.
pub const Event = struct {
    kind: Kind,
    phase: enum { capture, bubble } = .bubble,
    key: platform.TranslatedKey = .{ .keycode = 0 },
    state: State = .pressed,
    x: f32 = 0,
    y: f32 = 0,
    button: u32 = 0,
    delta: f64 = 0,
    axis: platform.PointerAxis = .vertical,
};

pub const Filter = struct {
    keys: [16]KeyChord = @splat(.{}),
    key_count: u8 = 0,
    states: std.EnumSet(State) = std.EnumSet(State).initFull(),
    kinds: std.EnumSet(Kind) = std.EnumSet(Kind).initFull(),
    button: ?u32 = null,

    pub fn matches(self: Filter, event: Event) bool {
        if (!self.kinds.contains(event.kind)) return false;
        if (event.kind == .key) {
            if (!self.states.contains(event.state)) return false;
            if (self.key_count == 0) return true;
            for (self.keys[0..self.key_count]) |key| if (key.matches(event.key)) return true;
            return false;
        }
        if (self.button) |button|
            return (event.kind == .press or event.kind == .release) and button == event.button;
        return true;
    }
};

test "contextual input filters require exact modifiers state kind and button" {
    var filter: Filter = .{};
    filter.keys[0] = try KeyChord.parse("Ctrl+Left");
    filter.key_count = 1;
    filter.states = std.EnumSet(State).initOne(.pressed);
    var key: Event = .{ .kind = .key, .key = .{ .keycode = 0, .logical = .arrow_left, .modifiers = .{ .control = true } } };
    try std.testing.expect(filter.matches(key));
    key.key.modifiers.shift = true;
    try std.testing.expect(!filter.matches(key));
    key.key.modifiers.shift = false;
    key.state = .repeated;
    try std.testing.expect(!filter.matches(key));
    key.state = .released;
    try std.testing.expect(!filter.matches(key));
    filter = .{ .kinds = std.EnumSet(Kind).initOne(.press), .button = 272 };
    try std.testing.expect(filter.matches(.{ .kind = .press, .button = 272 }));
    try std.testing.expect(!filter.matches(.{ .kind = .press, .button = 273 }));
    try std.testing.expect(!filter.matches(.{ .kind = .release, .button = 272 }));
    filter.kinds = std.EnumSet(Kind).initFull();
    try std.testing.expect(!filter.matches(.{ .kind = .motion, .button = 272 }));
    try std.testing.expect((Filter{}).matches(.{ .kind = .motion }));
}
