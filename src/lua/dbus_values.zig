const std = @import("std");
const linux = std.os.linux;
const c = @import("c.zig");
const wire = @import("../dbus/wire.zig");

const variant_mt = "ouro.dbus.variant";
const uint64_mt = "ouro.dbus.uint64";
const fd_mt = "ouro.dbus.fd";
const max_values = 4096;
const max_depth = 32;

const U64 = extern struct { value: u64 };
const Fd = extern struct { value: linux.fd_t };

pub const Encoded = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    fds: []linux.fd_t,
    pub fn deinit(self: *Encoded) void {
        for (self.fds) |fd| _ = linux.close(fd);
        self.allocator.free(self.fds);
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

fn fail(L: *c.State, text: [*:0]const u8) c_int {
    _ = c.lua_pushstring(L, text);
    return c.lua_error(L);
}
fn abs(L: *c.State, i: c_int) c_int {
    return if (i > 0 or i <= c.registry_index) i else c.lua_gettop(L) + i + 1;
}
fn bytes(L: *c.State, i: c_int) ?[]const u8 {
    if (c.lua_type(L, i) != c.type_string) return null;
    var n: usize = 0;
    const p = c.lua_tolstring(L, i, &n) orelse return null;
    return p[0..n];
}
fn userdata(comptime T: type, L: *c.State, i: c_int, mt: [*:0]const u8) ?*T {
    return @ptrCast(@alignCast(c.luaL_testudata(L, i, mt)));
}

fn variantCtor(L: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(L) != 2) return fail(L, "dbus.variant expects signature and value");
    const sig = bytes(L, 1) orelse return fail(L, "invalid variant signature");
    if (!wire.validSignature(sig, false)) return fail(L, "invalid variant signature");
    _ = c.lua_newuserdatauv(L, 1, 2) orelse return fail(L, "out of memory");
    _ = c.luaL_newmetatable(L, variant_mt);
    _ = c.lua_setmetatable(L, -2);
    c.lua_pushvalue(L, 1);
    _ = c.lua_setiuservalue(L, -2, 1);
    c.lua_pushvalue(L, 2);
    _ = c.lua_setiuservalue(L, -2, 2);
    return 1;
}
fn variantIndex(L: *c.State) callconv(.c) c_int {
    if (userdata(u8, L, 1, variant_mt) == null) return fail(L, "invalid variant");
    const key = bytes(L, 2) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    if (std.mem.eql(u8, key, "signature")) _ = c.lua_getiuservalue(L, 1, 1) else if (std.mem.eql(u8, key, "value")) _ = c.lua_getiuservalue(L, 1, 2) else c.lua_pushnil(L);
    return 1;
}
fn uintCtor(L: *c.State) callconv(.c) c_int {
    if (c.lua_gettop(L) != 1) return fail(L, "dbus.uint64 expects one value");
    var value: u64 = 0;
    if (bytes(L, 1)) |s| value = std.fmt.parseInt(u64, s, 10) catch return fail(L, "invalid uint64") else {
        var ok: c_int = 0;
        const n = c.lua_tointegerx(L, 1, &ok);
        if (ok == 0 or n < 0) return fail(L, "invalid uint64");
        value = @intCast(n);
    }
    const out = c.lua_newuserdatauv(L, @sizeOf(U64), 0) orelse return fail(L, "out of memory");
    @as(*U64, @ptrCast(@alignCast(out))).* = .{ .value = value };
    _ = c.luaL_newmetatable(L, uint64_mt);
    _ = c.lua_setmetatable(L, -2);
    return 1;
}
fn uintString(L: *c.State) callconv(.c) c_int {
    const u = userdata(U64, L, 1, uint64_mt) orelse return fail(L, "invalid uint64");
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{u.value}) catch unreachable;
    _ = c.lua_pushlstring(L, s.ptr, s.len);
    return 1;
}
fn uintEq(L: *c.State) callconv(.c) c_int {
    const a = userdata(U64, L, 1, uint64_mt);
    const b = userdata(U64, L, 2, uint64_mt);
    c.lua_pushboolean(L, @intFromBool(a != null and b != null and a.?.value == b.?.value));
    return 1;
}
fn fdClose(L: *c.State) callconv(.c) c_int {
    const fd = userdata(Fd, L, 1, fd_mt) orelse return fail(L, "invalid D-Bus file descriptor");
    if (fd.value >= 0) {
        _ = linux.close(fd.value);
        fd.value = -1;
    }
    return 0;
}

pub fn install(L: *c.State) !void {
    _ = c.luaL_newmetatable(L, variant_mt);
    c.lua_pushcclosure(L, variantIndex, 0);
    c.lua_setfield(L, -2, "__index");
    c.lua_settop(L, -2);
    _ = c.luaL_newmetatable(L, uint64_mt);
    c.lua_pushcclosure(L, uintString, 0);
    c.lua_setfield(L, -2, "__tostring");
    c.lua_pushcclosure(L, uintEq, 0);
    c.lua_setfield(L, -2, "__eq");
    c.lua_settop(L, -2);
    _ = c.luaL_newmetatable(L, fd_mt);
    c.lua_pushcclosure(L, fdClose, 0);
    c.lua_setfield(L, -2, "close");
    c.lua_pushcclosure(L, fdClose, 0);
    c.lua_setfield(L, -2, "__gc");
    c.lua_pushcclosure(L, fdClose, 0);
    c.lua_setfield(L, -2, "__close");
    c.lua_pushvalue(L, -1);
    c.lua_setfield(L, -2, "__index");
    c.lua_settop(L, -2);
    c.lua_pushcclosure(L, variantCtor, 0);
    c.lua_setfield(L, -2, "variant");
    c.lua_pushcclosure(L, uintCtor, 0);
    c.lua_setfield(L, -2, "uint64");
}

fn sequenceLen(L: *c.State, idx0: c_int) !usize {
    const idx = abs(L, idx0);
    if (c.lua_type(L, idx) != c.type_table) return error.InvalidValue;
    const n = c.lua_rawlen(L, idx);
    if (n > max_values) return error.ValueLimitExceeded;
    c.lua_pushnil(L);
    while (c.lua_next(L, idx) != 0) {
        var ok: c_int = 0;
        const k = c.lua_tointegerx(L, -2, &ok);
        if (c.lua_isinteger(L, -2) == 0 or ok == 0 or k < 1 or @as(u64, @intCast(k)) > n) {
            c.lua_settop(L, -3);
            return error.InvalidValue;
        }
        c.lua_settop(L, -2);
    }
    for (1..n + 1) |i| {
        _ = c.lua_rawgeti(L, idx, @intCast(i));
        if (c.lua_type(L, -1) == c.type_nil) {
            c.lua_settop(L, -2);
            return error.InvalidValue;
        }
        c.lua_settop(L, -2);
    }
    return n;
}
fn integer(comptime T: type, L: *c.State, idx: c_int) !T {
    if (c.lua_isinteger(L, idx) == 0) return error.InvalidValue;
    var ok: c_int = 0;
    const v = c.lua_tointegerx(L, idx, &ok);
    return std.math.cast(T, v) orelse error.InvalidValue;
}
fn encodeOne(L: *c.State, index: c_int, sig: []const u8, pos: *usize, e: *wire.Encoder, fds: *std.ArrayList(linux.fd_t), count: *usize, depth: usize) anyerror!void {
    if (depth >= max_depth or count.* >= max_values) return error.InvalidValue;
    if (c.lua_checkstack(L, 8) == 0) return error.OutOfMemory;
    const idx = abs(L, index);
    count.* += 1;
    const ch = sig[pos.*];
    pos.* += 1;
    switch (ch) {
        'y' => try e.byte(try integer(u8, L, idx)),
        'n' => try e.int16(try integer(i16, L, idx)),
        'q' => try e.uint16(try integer(u16, L, idx)),
        'i' => try e.int32(try integer(i32, L, idx)),
        'u' => try e.uint32(try integer(u32, L, idx)),
        'x' => try e.int64(try integer(i64, L, idx)),
        't' => {
            const u = userdata(U64, L, idx, uint64_mt);
            if (u) |v| try e.uint64(v.value) else try e.uint64(try integer(u64, L, idx));
        },
        'd' => {
            if (c.lua_type(L, idx) != c.type_number) return error.InvalidValue;
            var ok: c_int = 0;
            const v = c.lua_tonumberx(L, idx, &ok);
            if (ok == 0) return error.InvalidValue;
            try e.double(v);
        },
        'b' => {
            if (c.lua_type(L, idx) != c.type_boolean) return error.InvalidValue;
            try e.boolean(c.lua_toboolean(L, idx) != 0);
        },
        's', 'o', 'g' => {
            const s = bytes(L, idx) orelse return error.InvalidValue;
            if (ch == 's') try e.string(s) else if (ch == 'o') try e.objectPath(s) else try e.signature(s);
        },
        'h' => {
            const fd = userdata(Fd, L, idx, fd_mt) orelse return error.InvalidValue;
            if (fd.value < 0) return error.InvalidValue;
            if (fds.items.len >= 16) return error.InvalidValue;
            try fds.ensureUnusedCapacity(e.allocator, 1);
            const copy = try dupFd(fd.value);
            fds.appendAssumeCapacity(copy);
            try e.unixFd(@intCast(fds.items.len - 1));
        },
        'v' => {
            if (userdata(u8, L, idx, variant_mt) == null) return error.InvalidValue;
            _ = c.lua_getiuservalue(L, idx, 1);
            const inner = bytes(L, -1) orelse return error.InvalidValue;
            try e.variantSignature(inner);
            c.lua_settop(L, -2);
            _ = c.lua_getiuservalue(L, idx, 2);
            var p: usize = 0;
            try encodeOne(L, -1, inner, &p, e, fds, count, depth + 1);
            c.lua_settop(L, -2);
        },
        'a' => {
            const start = pos.*;
            pos.* = try wire.signatureEnd(sig, start, true);
            if (sig[start] == 'y' and c.lua_type(L, idx) == c.type_string) {
                const s = bytes(L, idx).?;
                const mark = try e.beginArray(1);
                for (s) |v| try e.byte(v);
                try e.endArray(mark);
                return;
            }
            const n = try sequenceLen(L, idx);
            const mark = try e.beginArray(wire.typeAlignment(sig[start]));
            for (1..n + 1) |i| {
                _ = c.lua_rawgeti(L, idx, @intCast(i));
                var p = start;
                try encodeOne(L, -1, sig, &p, e, fds, count, depth + 1);
                c.lua_settop(L, -2);
            }
            try e.endArray(mark);
        },
        '(', '{' => {
            try e.structAlignment();
            const closing: u8 = if (ch == '(') ')' else '}';
            const n = try sequenceLen(L, idx);
            var field: usize = 0;
            while (sig[pos.*] != closing) {
                field += 1;
                if (field > n) return error.InvalidValue;
                _ = c.lua_rawgeti(L, idx, @intCast(field));
                try encodeOne(L, -1, sig, pos, e, fds, count, depth + 1);
                c.lua_settop(L, -2);
            }
            if (field != n) return error.InvalidValue;
            pos.* += 1;
        },
        else => return error.InvalidSignature,
    }
}

pub fn encode(L: *c.State, index: c_int, signature: []const u8, allocator: std.mem.Allocator) !Encoded {
    const top = c.lua_gettop(L);
    defer c.lua_settop(L, top);
    const idx = abs(L, index);
    if (!wire.validSignature(signature, true)) return error.InvalidSignature;
    var e = wire.Encoder.init(allocator);
    defer e.deinit();
    var fds: std.ArrayList(linux.fd_t) = .empty;
    errdefer {
        for (fds.items) |fd| _ = linux.close(fd);
        fds.deinit(allocator);
    }
    var p: usize = 0;
    var count: usize = 0;
    var arg: usize = 0;
    const n = try sequenceLen(L, idx);
    while (p < signature.len) {
        arg += 1;
        if (arg > n) return error.InvalidValue;
        _ = c.lua_rawgeti(L, idx, @intCast(arg));
        try encodeOne(L, -1, signature, &p, &e, &fds, &count, 0);
        c.lua_settop(L, -2);
    }
    if (arg != n) return error.InvalidValue;
    const body = try e.buffer.toOwnedSlice(allocator);
    errdefer allocator.free(body);
    const owned_fds = try fds.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .body = body, .fds = owned_fds };
}

pub fn pushFd(L: *c.State, fd: linux.fd_t) !void {
    const p = c.lua_newuserdatauv(L, @sizeOf(Fd), 0) orelse return error.OutOfMemory;
    @as(*Fd, @ptrCast(@alignCast(p))).* = .{ .value = fd };
    _ = c.luaL_newmetatable(L, fd_mt);
    _ = c.lua_setmetatable(L, -2);
}

fn pushOne(L: *c.State, sig: []const u8, pos: *usize, d: *wire.Decoder, message: *const wire.Message, count: *usize, depth: usize) anyerror!void {
    if (depth >= max_depth or count.* >= max_values) return error.InvalidValue;
    if (c.lua_checkstack(L, 8) == 0) return error.OutOfMemory;
    count.* += 1;
    const ch = sig[pos.*];
    pos.* += 1;
    switch (ch) {
        'y' => c.lua_pushinteger(L, try d.byte()),
        'n' => c.lua_pushinteger(L, try d.int16()),
        'q' => c.lua_pushinteger(L, try d.uint16()),
        'i' => c.lua_pushinteger(L, try d.int32()),
        'u' => c.lua_pushinteger(L, try d.uint32()),
        'x' => c.lua_pushinteger(L, try d.int64()),
        't' => {
            const p = c.lua_newuserdatauv(L, @sizeOf(U64), 0) orelse return error.OutOfMemory;
            @as(*U64, @ptrCast(@alignCast(p))).* = .{ .value = try d.uint64() };
            _ = c.luaL_newmetatable(L, uint64_mt);
            _ = c.lua_setmetatable(L, -2);
        },
        'd' => c.lua_pushnumber(L, try d.double()),
        'b' => c.lua_pushboolean(L, @intFromBool(try d.boolean())),
        's', 'o', 'g' => {
            const s = if (ch == 's') try d.string() else if (ch == 'o') try d.objectPath() else try d.signature();
            _ = c.lua_pushlstring(L, s.ptr, s.len);
        },
        'h' => {
            const i = try d.unixFd();
            if (i >= message.fds.len) return error.InvalidValue;
            const copy = try dupFd(message.fds[i]);
            errdefer _ = linux.close(copy);
            try pushFd(L, copy);
        },
        'v' => {
            const inner = try d.variantSignature();
            _ = c.lua_newuserdatauv(L, 1, 2) orelse return error.OutOfMemory;
            _ = c.luaL_newmetatable(L, variant_mt);
            _ = c.lua_setmetatable(L, -2);
            _ = c.lua_pushlstring(L, inner.ptr, inner.len);
            _ = c.lua_setiuservalue(L, -2, 1);
            var p: usize = 0;
            try pushOne(L, inner, &p, d, message, count, depth + 1);
            _ = c.lua_setiuservalue(L, -2, 2);
        },
        'a' => {
            const start = pos.*;
            pos.* = try wire.signatureEnd(sig, start, true);
            const end = try d.beginArray(wire.typeAlignment(sig[start]));
            if (sig[start] == 'y') {
                const begin = d.position;
                while (!(try d.arrayFinished(end))) _ = try d.byte();
                _ = c.lua_pushlstring(L, d.data[begin..end].ptr, end - begin);
            } else {
                c.lua_createtable(L, 0, 0);
                var i: usize = 0;
                while (!(try d.arrayFinished(end))) {
                    i += 1;
                    var p = start;
                    try pushOne(L, sig, &p, d, message, count, depth + 1);
                    c.lua_rawseti(L, -2, @intCast(i));
                }
            }
        },
        '(', '{' => {
            try d.structAlignment();
            c.lua_createtable(L, 0, 0);
            const close: u8 = if (ch == '(') ')' else '}';
            var i: usize = 0;
            while (sig[pos.*] != close) {
                i += 1;
                try pushOne(L, sig, pos, d, message, count, depth + 1);
                c.lua_rawseti(L, -2, @intCast(i));
            }
            pos.* += 1;
        },
        else => return error.InvalidSignature,
    }
}

pub fn pushArgs(L: *c.State, message: *const wire.Message) !void {
    c.lua_createtable(L, 0, 0);
    var d = message.bodyDecoder();
    var p: usize = 0;
    var count: usize = 0;
    var i: usize = 0;
    while (p < message.header.signature.len) {
        i += 1;
        try pushOne(L, message.header.signature, &p, &d, message, &count, 0);
        c.lua_rawseti(L, -2, @intCast(i));
    }
    try d.end();
}
pub fn pushMessage(L: *c.State, message: *const wire.Message) !void {
    const top = c.lua_gettop(L);
    errdefer c.lua_settop(L, top);
    c.lua_createtable(L, 0, 7);
    _ = c.lua_pushlstring(L, message.header.signature.ptr, message.header.signature.len);
    c.lua_setfield(L, -2, "signature");
    try pushArgs(L, message);
    c.lua_setfield(L, -2, "args");
    inline for (.{ "path", "interface", "member", "sender", "destination" }) |name| {
        const value = @field(message.header, name);
        if (value) |s| {
            _ = c.lua_pushlstring(L, s.ptr, s.len);
            c.lua_setfield(L, -2, name);
        }
    }
}

fn dupFd(fd: linux.fd_t) !linux.fd_t {
    const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.InvalidFileDescriptor;
    return @intCast(result);
}

test "D-Bus Lua codec preserves nested types and exact integer boundaries" {
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    try app.prepareScript(
        \\local d = require('ouro').dbus
        \\input = {-32768, 65535, -2147483648, 4294967295, math.mininteger, d.uint64('18446744073709551615'), false, 1.25,
        \\  '\x00\xff\x07', {}, {{'first', d.variant('(us)', {17, 'asymmetric'})}, {'first', d.variant('av', {d.variant('i', -41)})}},
        \\  {'/valid/path', 'a{sv}', 233}}
    );
    try app.runReadyTurn();
    const L = app.lua_vm.state;
    _ = c.lua_getglobal(L, "input");
    var encoded = try encode(L, -1, "nqiuxtbdayasa{sv}(ogy)", std.testing.allocator);
    defer encoded.deinit();
    c.lua_settop(L, -2);
    // Check independently derived bytes, not just encode/decode agreement.
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x80, 0xff, 0xff, 0x00, 0x00, 0x00, 0x80, 0xff, 0xff, 0xff, 0xff }, encoded.body[0..12]);
    const data = try wire.encodeMessage(std.testing.allocator, .{ .message_type = .method_return, .reply_serial = 91, .signature = "nqiuxtbdayasa{sv}(ogy)" }, 32, encoded.body, 0);
    var message = try wire.parseMessage(std.testing.allocator, data, try std.testing.allocator.alloc(linux.fd_t, 0));
    defer message.deinit();
    try pushMessage(L, &message);
    c.lua_setglobal(L, "reply");
    try app.prepareScript(
        \\local a = reply.args
        \\assert(a[1] == -32768 and a[2] == 65535 and a[3] == -2147483648 and a[4] == 4294967295)
        \\assert(a[5] == math.mininteger and tostring(a[6]) == '18446744073709551615')
        \\assert(a[6] == require('ouro').dbus.uint64('18446744073709551615'))
        \\assert(a[7] == false and a[8] == 1.25 and a[9] == '\x00\xff\x07' and #a[10] == 0)
        \\assert(#a[11] == 2 and a[11][1][1] == 'first' and a[11][2][1] == 'first')
        \\assert(a[11][1][2].signature == '(us)' and a[11][1][2].value[2] == 'asymmetric')
        \\assert(a[11][2][2].value[1].signature == 'i' and a[11][2][2].value[1].value == -41)
        \\assert(a[12][1] == '/valid/path' and a[12][2] == 'a{sv}' and a[12][3] == 233)
        \\codec_done = true
    );
    try app.runReadyTurn();
    try std.testing.expect(app.lua_vm.globalBoolean("codec_done"));
}

test "D-Bus Lua codec rejects coercions holes arity ranges and recursive variants" {
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    const Case = struct { expression: []const u8, signature: []const u8 };
    for ([_]Case{
        .{ .expression = "{-1}", .signature = "u" },
        .{ .expression = "{65536}", .signature = "q" },
        .{ .expression = "{1.5}", .signature = "i" },
        .{ .expression = "{'2.5'}", .signature = "d" },
        .{ .expression = "{1}", .signature = "b" },
        .{ .expression = "{{[1]=3,[3]=5}}", .signature = "au" },
        .{ .expression = "{{1,extra=4}}", .signature = "au" },
        .{ .expression = "{{['1']=4}}", .signature = "au" },
        .{ .expression = "{{1}}", .signature = "(us)" },
        .{ .expression = "{1,2}", .signature = "u" },
        .{ .expression = "{}", .signature = "u" },
        .{ .expression = "{'bad/path'}", .signature = "o" },
        .{ .expression = "{'nul\\x00text'}", .signature = "s" },
        .{ .expression = "{{}}", .signature = "a" },
        .{ .expression = "{require('ouro').dbus.variant('u', -1)}", .signature = "v" },
    }) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "input = {s}", .{case.expression});
        defer std.testing.allocator.free(source);
        try app.prepareScript(source);
        try app.runReadyTurn();
        const L = app.lua_vm.state;
        _ = c.lua_getglobal(L, "input");
        const top = c.lua_gettop(L);
        if (encode(L, -1, case.signature, std.testing.allocator)) |value| {
            var owned = value;
            owned.deinit();
            return error.ExpectedRejection;
        } else |_| {}
        try std.testing.expectEqual(top, c.lua_gettop(L));
        c.lua_settop(L, -2);
    }
    try app.prepareScript("local d=require('ouro').dbus; local v=d.variant('y',7); for i=1,40 do v=d.variant('v',v) end; input={v}");
    try app.runReadyTurn();
    _ = c.lua_getglobal(app.lua_vm.state, "input");
    try std.testing.expectError(error.InvalidValue, encode(app.lua_vm.state, -1, "v", std.testing.allocator));
    c.lua_settop(app.lua_vm.state, -2);
}

test "D-Bus Lua fd values duplicate with CLOEXEC and close independently" {
    const App = @import("../app/app.zig").App;
    var app: App = undefined;
    try app.init(std.testing.allocator);
    defer app.deinit();
    const result = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    const original: linux.fd_t = @intCast(result);
    try pushFd(app.lua_vm.state, original);
    c.lua_setglobal(app.lua_vm.state, "fd");
    try app.prepareScript("input = {fd}");
    try app.runReadyTurn();
    _ = c.lua_getglobal(app.lua_vm.state, "input");
    var encoded = try encode(app.lua_vm.state, -1, "h", std.testing.allocator);
    defer encoded.deinit();
    c.lua_settop(app.lua_vm.state, -2);
    try std.testing.expect(encoded.fds[0] != original);
    try std.testing.expectEqual(@as(usize, linux.FD_CLOEXEC), linux.fcntl(encoded.fds[0], linux.F.GETFD, 0));
    try app.prepareScript("fd:close(); fd:close()");
    try app.runReadyTurn();
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(original, linux.F.GETFD, 0)));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(encoded.fds[0], linux.F.GETFD, 0)));
}
