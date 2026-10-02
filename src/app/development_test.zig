const std = @import("std");
const dev = @import("development.zig");
const lua = @import("../lua/root.zig");
const c = @import("../lua/c.zig");
const ui = @import("../ui/root.zig");
const text = @import("../text/root.zig");
const task = @import("../task/root.zig");
const WindowRuntime = @import("window_runtime.zig").WindowRuntime;

const Fixture = struct {
    loop: @import("../loop/root.zig").Loop = undefined,
    vm: lua.Vm = undefined,
    callbacks: lua.CallbackRegistry = undefined,
    scheduler: task.Scheduler = undefined,
    scope: task.ScopeHandle = undefined,
    signals: lua.Signals = undefined,
    fonts: text.FontCache = undefined,
    font: [1]text.FontHandle = undefined,
    sources: text.ParagraphSourceCache = undefined,
    paragraphs: text.ParagraphCache = undefined,
    builder: lua.UiBuild = undefined,
    runtime: WindowRuntime = .{},
    descriptors: [256]ui.instance.Descriptor = undefined,
    semantics: [256]ui.semantics.Descriptor = undefined,

    fn create(source: []const u8) !*Fixture {
        const self = try std.testing.allocator.create(Fixture);
        self.* = .{};
        try self.loop.init(std.testing.allocator, 8, 2);
        try self.scheduler.init(std.testing.allocator, 1024, 16, 4);
        try self.vm.init(std.testing.allocator, &self.scheduler, &self.loop);
        self.vm.pushApi(self.vm.state);
        c.lua_setglobal(self.vm.state, "ouro");
        try self.callbacks.init(std.testing.allocator, 256);
        self.scope = try self.scheduler.createScope(self.scheduler.application_scope);
        try self.signals.init(std.testing.allocator, self.vm.state, 1024, 1024, 1024);
        self.fonts = text.FontCache.init(std.testing.allocator);
        self.font[0] = try self.fonts.acquire(.{ .key = .{ .file = "/fixtures/Inter-Regular.ttf", .index = 0 }, .bytes = @embedFile("ourokit_test_font_static") });
        self.sources = text.ParagraphSourceCache.init(std.testing.allocator, &self.fonts);
        self.paragraphs = text.ParagraphCache.init(std.testing.allocator, &self.fonts);
        try self.builder.init(self.vm.state, &self.descriptors);
        self.builder.attachCallbacks(&self.callbacks, &self.vm);
        self.builder.attachSignals(&self.signals);
        try self.builder.attachSemantics(&self.semantics);
        try self.builder.attachText(&self.sources, &self.font, 1);
        const theme = @import("../design/root.zig").tokens.light;
        self.builder.enableDeclarativeWidgets(theme);
        try self.runtime.init(std.testing.allocator, &self.scheduler, self.scope, .{ .slot = 3, .generation = 9 }, theme.background, theme.primary, theme.foreground, theme.input, theme.ring, &self.signals, &self.sources, &self.paragraphs, .{ .measure_phases = true });
        errdefer self.destroy();
        if (c.luaL_loadbufferx(self.vm.state, source.ptr, source.len, "@development-test", "t") != c.ok or
            c.lua_pcallk(self.vm.state, 0, 0, 0, 0, null) != c.ok) return error.LuaTestFailed;
        try self.settle();
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.runtime.clear(&self.builder) catch unreachable;
        self.scheduler.applyQueuedCancellations() catch unreachable;
        self.runtime.collectRetired() catch unreachable;
        self.runtime.deinit();
        self.scheduler.destroyScope(self.scope) catch unreachable;
        self.callbacks.deinit();
        self.vm.deinit();
        self.scheduler.deinit();
        self.loop.deinit();
        self.signals.deinit();
        self.paragraphs.deinit();
        self.sources.deinit();
        self.fonts.release(self.font[0]) catch unreachable;
        self.fonts.deinit();
        std.testing.allocator.destroy(self);
    }

    fn settle(self: *Fixture) !void {
        for (0..32) |_| {
            try self.runtime.dispatchInput(&self.callbacks);
            try self.scheduler.applyQueuedCancellations();
            while (self.scheduler.takeRunnable()) |handle|
                try std.testing.expectEqual(.completed, try self.vm.resumeRunnable(handle));
            try self.runtime.collectRetired();
            _ = c.lua_getglobal(self.vm.state, "build");
            const reference = c.luaL_ref(self.vm.state, c.registry_index);
            defer c.luaL_unref(self.vm.state, c.registry_index, reference);
            try self.runtime.reconcile(.{ .width = 324, .height = 224 }, &self.builder, reference);
            if (self.runtime.frame_state.readyForSubmission()) try self.runtime.frameSubmitted();
            if (!self.runtime.hasPendingScrollEvents()) return;
        }
        return error.TestDidNotSettle;
    }

    fn exec(self: *Fixture, source: []const u8) !void {
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(self.vm.state, source.ptr, source.len, "@scroll-test", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(self.vm.state, 0, 0, 0, 0, null));
    }

    fn play(self: *Fixture, action: dev.Action) !void {
        var playback = try dev.Playback.init(&self.runtime, dev.Token.current(&self.runtime), action);
        while (try playback.advance(&self.runtime) == .routed) try self.settle();
    }

    fn snapshot(self: *Fixture) !dev.Snapshot {
        return dev.inspect(std.testing.allocator, &self.runtime, .{});
    }
};

fn node(snapshot: dev.Snapshot, path: []const u8) !dev.Node {
    for (snapshot.nodes) |value| if (value.path) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return value;
    };
    return error.TestPathMissing;
}

test "inline links reuse keyboard activation and skip disabled or truncated ranges" {
    const f = try Fixture.create(
        \\local count=ouro.signal(0)
        \\function build() return ouro.column {key='root',gap=5,
        \\ ouro.text {key='rich',size=20,spans={
        \\  {text='before '}, {key='link',text='link\nnext',on_press=function() count:set(count()+3) end},
        \\  {text=' after '}, {key='disabled',text='disabled',enabled=false,on_press=function() count:set(999) end}}},
        \\ ouro.box {key='narrow',width=40,ouro.text {key='short',size=20,max_lines=1,overflow='ellipsis',spans={
        \\  {text='before '}, {key='hidden',text='hidden',on_press=function() count:set(999) end}}}},
        \\ ouro.text {key='status',text='Count '..count()}}
        \\end
    );
    defer f.destroy();
    const first = try f.runtime.semanticTarget("root/rich/link");
    try std.testing.expectEqual(.link, first.role);
    try f.play(.{ .click = "root/rich/link" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("Count 9", (try node(snapshot, "root/status")).label);
    try std.testing.expect((try node(snapshot, "root/rich/link")).focused);
    try std.testing.expect(!(try node(snapshot, "root/rich/disabled")).enabled);
    try std.testing.expect(!(try node(snapshot, "root/narrow/short/hidden")).visible);
    try std.testing.expectError(error.DevelopmentTargetHidden, dev.Playback.init(&f.runtime, snapshot.token, .{ .click = "root/narrow/short/hidden" }));
}

test "custom selection items repaint nested content without rebuilding and isolate child activation" {
    const f = try Fixture.create(
        \\builds=0; requests=0; closes=0
        \\local Item=ouro.stateless(function(p, children, theme, context)
        \\ assert(context.selection.role=='listbox' and context.selection.selected==41)
        \\ return ouro.box {key=p.key, option=p.value, label='Semantic '..p.key, height=50,
        \\   border_width=3, border='#234567', background='#102030', states={hover='#405060',selected='#708090'},
        \\   ouro.row {key='row', semantic=false, gap=0,
        \\     ouro.box {key='swatch', width=30, height=40, background='#112233', states={hover='#445566',selected='#778899',focus='#abcdef'}},
        \\     ouro.text {key='title', text='Visible', foreground='#213243', states={hover='#546576',selected='#8798a9'}},
        \\     ouro.box {key='close', role='button', label='Close', activate=true, width=190, height=40,
        \\       on_press=function() closes=closes+1 end,
        \\       ouro.text {key='glyph', text='X', foreground='#321043',states={hover='#654376'}}}}}
        \\end)
        \\function build() builds=builds+1; return ouro.listbox {key='items',selected=41,
        \\ on_select=function(v) requests=requests+v end,
        \\ Item {key='first',value=41}, Item {key='second',value=-7}} end
    );
    defer f.destroy();
    const Color = @import("../core/color.zig").Color;
    const check = struct {
        fn object(fixture: *Fixture, path: []const u8) !ui.render_object.types.Object {
            const id = (try fixture.runtime.semantics.findPath(path)).id;
            return fixture.runtime.tree.objectAt(try fixture.runtime.instances.renderObject(fixture.runtime.instances.handleForId(id).?));
        }
        fn colors(fixture: *Fixture, box: Color, swatch: Color, title: Color) !void {
            try std.testing.expectEqual(box, (try object(fixture, "items/second")).box.background.?);
            try std.testing.expectEqual(swatch, (try object(fixture, "items/second/swatch")).box.background.?);
            try std.testing.expectEqual(title, (try object(fixture, "items/second/title")).text.color);
        }
        fn selected(fixture: *Fixture) !void {
            var snapshot = try fixture.snapshot();
            defer snapshot.deinit();
            try std.testing.expect((try node(snapshot, "items/second")).selected);
            try std.testing.expect(!(try node(snapshot, "items/first")).selected);
        }
    };
    try check.colors(f, .rgba(0x10, 0x20, 0x30, 255), .rgba(0x11, 0x22, 0x33, 255), .rgba(0x21, 0x32, 0x43, 255));
    try f.play(.{ .hover = "items/second" });
    try check.colors(f, .rgba(0x40, 0x50, 0x60, 255), .rgba(0x44, 0x55, 0x66, 255), .rgba(0x54, 0x65, 0x76, 255));
    // Its geometric center is covered by the wide close button. Semantic
    // playback must find another point without relying on a stock label ID.
    try f.play(.{ .click = "items/second" });
    try check.colors(f, .rgba(0x70, 0x80, 0x90, 255), .rgba(0x77, 0x88, 0x99, 255), .rgba(0x87, 0x98, 0xa9, 255));
    try check.selected(f);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_up } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    try std.testing.expectEqual(@as(f32, 2), (try check.object(f, "items/second")).box.outline_width);
    try std.testing.expectEqual(Color.rgba(0xab, 0xcd, 0xef, 255), (try check.object(f, "items/second/swatch")).box.outline_color.?);
    try f.play(.{ .click = "items/second/close" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try check.selected(f);
    try std.testing.expectEqual(@as(f32, 0), (try check.object(f, "items/second/swatch")).box.outline_width);
    try std.testing.expectEqual(Color.rgba(0x65, 0x43, 0x76, 255), (try check.object(f, "items/second/close/glyph")).text.color);
    const assertions = "assert(builds==1 and requests==27 and closes==2)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, assertions.ptr, assertions.len, "@check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "selection groups keep layout independent of native keyboard and controlled policies" {
    inline for (.{ "listbox", "radio_group", "tab_list" }) |policy| {
        const f = try Fixture.create("policy='" ++ policy ++ "'\n" ++
            \\builds=0; requested=0; activated=0; canceled=0
            \\local Item=ouro.stateless(function(p, children, theme, context)
            \\ assert(context.selection.role==policy and context.selection.selected==41)
            \\ assert(context.selection.enabled and context.selection.appearance=='sidebar')
            \\ return ouro.box {key=p.key,option=p.value,label=p.key,width=p.width,height=p.height}
            \\end)
            \\function build() builds=builds+1; return ouro.column {key='root',gap=0,
            \\ ouro.row {key='choices',selection=policy,selected=41,appearance='sidebar',
            \\   gap=11,cross_alignment='center',main_axis_size='min',
            \\   on_select=function(v) requested=requested+v end,
            \\   on_activate=function(v) activated=activated+v end,
            \\   on_cancel=function() canceled=canceled+1 end,
            \\   Item {key='first',value=41,width=30,height=20},
            \\   Item {key='second',value=-7,width=50,height=80}},
            \\ ouro.row {key='flex',selection=policy,selected=41,gap=0,main_axis_size='max',on_select=function() end,
            \\   ouro.box {key='first',option=41,label='First',flex=1,height=20},
            \\   ouro.box {key='second',option=-7,label='Second',flex=3,height=20}}} end
        );
        defer f.destroy();
        const group = try f.runtime.semanticTarget("root/choices");
        const first = try f.runtime.semanticTarget("root/choices/first");
        const second = try f.runtime.semanticTarget("root/choices/second");
        try std.testing.expectEqual(@as(f32, 91), group.bounds.width);
        try std.testing.expectEqual(@as(f32, 80), group.bounds.height);
        try std.testing.expectEqual(@as(f32, 41), second.bounds.x - first.bounds.x);
        try std.testing.expectEqual(@as(f32, 30), first.bounds.y - second.bounds.y);
        // The 324px window has 12px root padding on each side. Split the
        // remaining 300px in a 1:3 ratio, not equal-width stock items.
        try std.testing.expectEqual(@as(f32, 75), (try f.runtime.semanticTarget("root/flex/first")).bounds.width);
        try std.testing.expectEqual(@as(f32, 225), (try f.runtime.semanticTarget("root/flex/second")).bounds.width);
        try f.play(.{ .click = "root/choices/second" });
        try f.play(.{ .key = .{ .keycode = 0, .logical = if (comptime std.mem.eql(u8, policy, "tab_list")) .arrow_right else .arrow_down } });
        var snapshot = try f.snapshot();
        defer snapshot.deinit();
        try std.testing.expect((try node(snapshot, "root/choices")).focused);
        try std.testing.expectEqual(comptime std.mem.eql(u8, policy, "listbox"), (try node(snapshot, "root/choices/second")).selected);
        try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
        try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
        const assertions = if (comptime std.mem.eql(u8, policy, "listbox"))
            "assert(builds==1 and requested==-14 and activated==-14 and canceled==1)"
        else
            "assert(builds==1 and requested==-14 and activated==34 and canceled==1)";
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, assertions.ptr, assertions.len, "@check-group", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    }
}

test "selection primitive rejects conflicting policies and rolls back staged items and text" {
    const f = try Fixture.create("function build() return ouro.box {key='original'} end");
    defer f.destroy();
    const original = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("original")).id).?;
    const cases = [_][]const u8{
        "ouro.box {key='bad',option=17,label='Bad'}",
        "ouro.box {key='bad',option=1.5,label='Bad'}",
        "ouro.box {key='bad',option=23,label='Bad',activate=false}",
        "ouro.box {key='bad',option=23,label='Bad',enabled=true}",
        "ouro.box {key='bad',option=23,label='Bad',checked=false}",
        "ouro.box {key='bad',option=23,label='Bad',role='group'}",
        "ouro.box {key='bad',option=23,label='Bad',semantic=false}",
        "ouro.box {key='bad',option=23}",
        "ouro.box {key='bad',option=23,label='Bad',states={pressed='#123456'}}",
        "ouro.box {key='bad',option=23,label='Bad',states={disabled='#123456'}}",
        "ouro.box {key='wrap',ouro.box {key='bad',option=23,label='Bad'}}",
        "ouro.text {key='bad',text='No owner',states={hover='#123456'}}",
        "ouro.box {key='bad',activate=true,states={selected='#123456'}}",
        "ouro.box {key='bad',option=23,label='Bad',ouro.text {key='label',text='Bad',states={focus='#123456'}}}",
        "ouro.option {key='bad',label='Missing value'}",
        "ouro.option {key='bad',value=23,label='Bad',hover=false}",
        "ouro.option {key='bad',value=23,label='Bad',height=0}",
        "ouro.option {key='bad',value=23,label='Bad',height='auto'}",
        "ouro.row {key='bad',selection=false}",
        "ouro.column {key='bad',selection='multiple'}",
        "ouro.row {key='bad',selection='listbox',selected=23,on_select=function() end,semantic=false}",
        "ouro.row {key='bad',selection='listbox',on_select=function() end}",
        "ouro.row {key='bad',selection='listbox',selected=1.5,on_select=function() end}",
        "ouro.row {key='bad',selection='listbox',selected=23}",
        "ouro.row {key='bad',selection='listbox',selected=23,on_select=false}",
        "ouro.row {key='bad',selection='listbox',selected=23,on_select=function() end,enabled=0}",
        "ouro.row {key='bad',selection='listbox',selected=23,on_select=function() end,appearance=false}",
        "ouro.row {key='bad',main_axis_size='fill'}",
    };
    for (cases) |invalid| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return ouro.listbox {{key='list',selected=17,on_select=function() end," ++
            "ouro.box {{key='valid',option=17,label='Valid',ouro.text {{key='label',text='Staged',states={{selected='#123456'}}}}}}, {s}}} end", .{invalid});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@invalid-selection", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.settle());
        try std.testing.expectEqual(original, f.runtime.instances.handleForId((try f.runtime.semantics.findPath("original")).id).?);
        try std.testing.expectEqual(@as(usize, 0), f.builder.pending_option_count);
        try std.testing.expectEqual(@as(usize, 0), f.builder.pending_listbox_count);
        try std.testing.expectEqual(@as(usize, 0), f.builder.pending_handler_count);
        try std.testing.expectEqual(@as(usize, 0), f.sources.count());
    }
}

test "split controls preserve grab offset and clamp both axes at actual layout limits" {
    inline for (.{ "horizontal", "vertical" }) |axis| {
        const f = try Fixture.create("axis='" ++ axis ++ "'\n" ++
            \\position=ouro.signal(0.25)
            \\function build() return ouro.split_view {key='split', axis=axis, position=position(),
            \\ min_first=40, min_second=70, on_change=function(v) position:set(v) end,
            \\ ouro.box {key='first'}, ouro.box {key='second'}} end
        );
        defer f.destroy();
        const horizontal = comptime std.mem.eql(u8, axis, "horizontal");
        const before = try f.runtime.semanticTarget("split/divider");
        const divider = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("split/divider")).id).?;
        const divider_render = try f.runtime.instances.renderObject(divider);
        try std.testing.expectEqual(@as(f32, 8), if (horizontal) before.bounds.width else before.bounds.height);
        try std.testing.expect((try f.runtime.tree.objectAt(divider_render)).box.background == null);
        const chrome = f.runtime.tree.firstChild(divider_render).?;
        try std.testing.expectEqual(@as(u8, 0), (try f.runtime.tree.objectAt(chrome)).box.background.?.a);
        try f.play(.{ .hover = "split/divider" });
        try std.testing.expectEqual(if (horizontal) .col_resize else .row_resize, try f.runtime.pointerCursor());
        try f.play(.{ .pointer_down = "split/divider" });
        var position = before.center;
        if (horizontal) position.x += 23 else position.y += 23;
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = position } });
        try f.settle();
        const moved = try f.runtime.semanticTarget("split/divider");
        try std.testing.expectApproxEqAbs(@as(f32, 23), if (horizontal) moved.center.x - before.center.x else moved.center.y - before.center.y, 0.001);
        try std.testing.expectEqual(if (horizontal) .col_resize else .row_resize, try f.runtime.pointerCursor());
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = -500, .y = -500 } } });
        try f.settle();
        const first = (try f.runtime.semanticTarget("split/first")).bounds;
        try std.testing.expectApproxEqAbs(@as(f32, 40), if (horizontal) first.width else first.height, 0.001);
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 3, .button = 0x110, .state = .released } });
        try f.settle();
        try std.testing.expect(f.runtime.split_drag == null);
        try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
        const second = (try f.runtime.semanticTarget("split/second")).bounds;
        try std.testing.expectApproxEqAbs(@as(f32, 70), if (horizontal) second.width else second.height, 0.001);
        try f.play(.{ .key = .{ .keycode = 0, .logical = .home } });
        try f.play(.{ .key = .{ .keycode = 0, .logical = if (horizontal) .arrow_right else .arrow_down } });
        const stepped = (try f.runtime.semanticTarget("split/first")).bounds;
        try std.testing.expectApproxEqAbs(@as(f32, 50), if (horizontal) stepped.width else stepped.height, 0.001);
    }
}

test "custom split content inherits resize state without rebuilding ignored requests" {
    inline for (.{ "horizontal", "vertical" }) |axis| {
        const f = try Fixture.create("axis='" ++ axis ++ "'\n" ++
            \\position=ouro.signal(0.25); connected=ouro.signal(true); accepting=false; requests={}; builds=0
            \\function build() builds=builds+1; return ouro.split {key='split',axis=axis,position=position(),
            \\ divider_size=24,min_first=30,min_second=50,
            \\ on_change=connected() and function(v) requests[#requests+1]=v;if accepting then position:set(v) end end or nil,
            \\ ouro.box {key='first'},ouro.box {key='second'},
            \\ ouro.box {key='chrome',semantic=false,alignment='center',background='#123456',
            \\   states={hover='#234567',pressed='#345678',focus='#456789'},
            \\   ouro.box {key='grip',width=12,height=12,background='#abcdef',
            \\     states={hover='#56789a',pressed='#6789ab',focus='#789abc'}}}} end
        );
        defer f.destroy();
        const horizontal = comptime std.mem.eql(u8, axis, "horizontal");
        const available: f64 = if (horizontal) 276 else 176;
        const before = try f.runtime.semanticTarget("split/divider/grip");
        const divider = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("split/divider")).id).?;
        const bounds = (try f.runtime.semanticTarget("split/divider")).bounds;
        try std.testing.expectEqual(@as(f32, 24), if (horizontal) bounds.width else bounds.height);
        const grip = try f.runtime.instances.renderObject(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("split/divider/grip")).id).?);
        const Color = @import("../core/color.zig").Color;
        try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
        try std.testing.expectEqual(divider, f.runtime.focus.current().?);
        try std.testing.expectEqual(Color.rgba(0x78, 0x9a, 0xbc, 255), (try f.runtime.tree.objectAt(grip)).box.outline_color.?);
        try f.play(.{ .hover = "split/divider/grip" });
        try std.testing.expectEqual(if (horizontal) .col_resize else .row_resize, try f.runtime.pointerCursor());
        try std.testing.expectEqual(Color.rgba(0x56, 0x78, 0x9a, 255), (try f.runtime.tree.objectAt(grip)).box.background.?);
        try f.play(.{ .pointer_down = "split/divider" });
        try std.testing.expectEqual(grip, try f.runtime.instances.renderObject(f.runtime.router.captured.?));
        try std.testing.expectEqual(Color.rgba(0x67, 0x89, 0xab, 255), (try f.runtime.tree.objectAt(grip)).box.background.?);
        for ([_]f32{ 17, 31 }) |delta| {
            var point = before.center;
            if (horizontal) point.x += delta else point.y += delta;
            try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = point } });
            try f.settle();
            try std.testing.expectEqual(before.center, (try f.runtime.semanticTarget("split/divider/grip")).center);
        }
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 2, .button = 0x110, .state = .released } });
        try f.settle();
        try f.play(.{ .key = .{ .keycode = 0, .logical = if (horizontal) .arrow_down else .arrow_right } });
        try f.play(.{ .key = .{ .keycode = 0, .logical = if (horizontal) .arrow_right else .arrow_down } });
        try f.play(.{ .key = .{ .keycode = 0, .logical = .home } });
        try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
        const check = try std.fmt.allocPrint(std.testing.allocator, "local expected={{{d},{d},{d},{d},{d}}}; assert(#requests==5 and builds==1); for i,v in ipairs(expected) do assert(math.abs(requests[i]-v)<0.000001) end; accepting=true", .{ 0.25 + 17 / available, 0.25 + 31 / available, 0.25 + 10 / available, 30 / available, (available - 50) / available });
        defer std.testing.allocator.free(check);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-split", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        try f.play(.{ .pointer_down = "split/divider" });
        var point = before.center;
        if (horizontal) point.x += 17 else point.y += 17;
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 3, .position = point } });
        try f.settle();
        const moved = try f.runtime.semanticTarget("split/divider/grip");
        try std.testing.expectApproxEqAbs(@as(f32, 17), if (horizontal) moved.center.x - before.center.x else moved.center.y - before.center.y, 0.001);
        try std.testing.expectEqual(divider, f.runtime.split_drag.?.target);
        const disconnect = "assert(#requests==6 and builds==2); connected:set(false)";
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, disconnect.ptr, disconnect.len, "@disconnect-split", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        try f.settle();
        try std.testing.expect(f.runtime.split_drag == null);
        try std.testing.expectEqual(divider, f.runtime.instances.handleForId((try f.runtime.semantics.findPath("split/divider")).id).?);
        try std.testing.expectEqual(.default, try f.runtime.pointerCursor());
    }
}

test "split divider content keeps nested activation independent" {
    const f = try Fixture.create(
        \\changes=0; presses=0
        \\function build() return ouro.split {key='split',divider_size=40,
        \\ on_change=function() changes=changes+1 end,
        \\ ouro.box {key='first'},ouro.box {key='second'},
        \\ ouro.box {key='chrome',semantic=false,alignment='center',
        \\   ouro.button {key='action',label='X',width=24,on_press=function() presses=presses+1 end}}} end
    );
    defer f.destroy();
    try f.play(.{ .hover = "split/divider/action" });
    try std.testing.expectEqual(.default, try f.runtime.pointerCursor());
    try f.play(.{ .click = "split/divider/action" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expect(f.runtime.split_drag == null);
    const check = "assert(changes==0 and presses==3)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-split-child", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "invalid split content rolls back its resize binding and geometry" {
    const f = try Fixture.create(
        \\changes=0
        \\function build() return ouro.split_view {key='split',position=0.25,
        \\ on_change=function() changes=changes+1 end,
        \\ ouro.box {key='first'},ouro.box {key='second'}} end
        \\good=build
    );
    defer f.destroy();
    try f.play(.{ .pointer_down = "split/divider" });
    const divider = f.runtime.split_drag.?.target;
    const before = try f.runtime.semanticTarget("split/divider");
    for ([_][]const u8{
        "ouro.split {key='bad',ouro.box {key='one'},ouro.box {key='two'}}",
        "ouro.split_view {key='bad',ouro.box {key='one'},ouro.box {key='two'},ouro.box {key='three'}}",
        "ouro.split {key='bad',divider_size=-1,ouro.box {key='one'},ouro.box {key='two'},ouro.box {key='three'}}",
        "ouro.split {key='bad',divider_size=math.huge,ouro.box {key='one'},ouro.box {key='two'},ouro.box {key='three'}}",
        // This fails inside the third child, after the resize callback is staged.
        "ouro.split {key='bad',on_change=function() changes=999 end,ouro.box {key='one'},ouro.box {key='two'},ouro.box {key='three',background='invalid'}}",
    }) |invalid| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{invalid});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@invalid-split", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.settle());
        try std.testing.expectEqual(divider, f.runtime.split_drag.?.target);
        try std.testing.expectEqual(@as(usize, 0), f.builder.pending_handler_count);
    }
    const restore = "build=good";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, restore.ptr, restore.len, "@restore-split", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = before.center.x + 19, .y = before.center.y } } });
    try f.settle();
    try std.testing.expectEqual(before.bounds, (try f.runtime.semanticTarget("split/divider")).bounds);
    const check = "assert(changes==1)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-split-rollback", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "tabs retain hidden editor state and reject hidden input without selecting on close" {
    const f = try Fixture.create(
        \\selected=ouro.signal(17); closed=0
        \\function build() return ouro.tabs {key='tabs', label='Editors', selected=selected(),
        \\ on_select=function(v) selected:set(v) end, on_close=function(v) closed=v end,
        \\ tabs={{value=17,label='First',content=ouro.text_input {key='edit',default_text='',multiline=true,height=70}},
        \\ {value=29,label='Second',closable=true,content=ouro.text_input {key='edit',default_text='other'}}}} end
    );
    defer f.destroy();
    try f.play(.{ .click = "tabs/control/panels/17/edit" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    const text_value = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve";
    try f.play(.{ .text = text_value });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left, .modifiers = .{ .shift = true } } });
    const selection = session.model.selection;
    const content = try f.runtime.text_inputs.content(target);
    const render = try f.runtime.instances.renderObject(content);
    const offset = try f.runtime.tree.textScrollOffset(render, .vertical);
    try std.testing.expect(offset > 0);
    // A close request for a background tab does not implicitly select it.
    try f.play(.{ .click = "tabs/control/strip/bar/29/close" });
    _ = c.lua_getglobal(f.vm.state, "closed");
    var is_number: c_int = 0;
    try std.testing.expectEqual(@as(c.Integer, 29), c.lua_tointegerx(f.vm.state, -1, &is_number));
    c.lua_settop(f.vm.state, -2);
    try std.testing.expect((try f.runtime.semantics.findPath("tabs/control/strip/bar/17")).selected);
    // Selecting a narrow closable tab must hit its label, not its close button.
    try f.play(.{ .click = "tabs/control/strip/bar/29" });
    try std.testing.expect((try f.runtime.semantics.findPath("tabs/control/strip/bar/29")).selected);
    // Focus the tab list, then switch using its native horizontal policy.
    try f.play(.{ .click = "tabs/control/strip/bar/17" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect(!f.runtime.instances.isFocusable(target));
    try std.testing.expectError(error.DevelopmentTargetHidden, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "tabs/control/panels/17/edit" }));
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expect(!(try node(snapshot, "tabs/control/panels/17/edit")).visible);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect((try f.runtime.semantics.findPath("tabs/control/strip/bar/17")).selected);
    try std.testing.expectEqual(target, f.runtime.instances.handleForId((try f.runtime.semantics.findPath("tabs/control/panels/17/edit")).id).?);
    try std.testing.expectEqual(selection, session.model.selection);
    try std.testing.expectEqual(offset, try f.runtime.tree.textScrollOffset(render, .vertical));
    try f.play(.{ .click = "tabs/control/panels/17/edit" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    try f.play(.{ .text = "!" });
    try f.play(.{ .click = "tabs/control/strip/bar/17" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left } });
    try f.play(.{ .click = "tabs/control/panels/17/edit" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings(text_value, session.model.text());
}

test "development click releases capture when a tab close removes its own target" {
    const f = try Fixture.create(
        \\closed=ouro.signal(false); closes=0; replacements=0
        \\function build()
        \\ if closed() then return ouro.button {key='replacement',label='Replacement',
        \\   on_press=function() replacements=replacements+1 end} end
        \\ return ouro.tabs {key='tabs',label='Tabs',selected=17,on_select=function() end,
        \\   on_close=function() closes=closes+1; closed:set(true) end,
        \\   tabs={{value=17,label='First',closable=true,content=ouro.box {key='body'}}}}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "tabs/control/strip/bar/17/close" });
    try std.testing.expect(f.runtime.router.captured == null);
    try std.testing.expect(f.runtime.buttons.armed == null);
    const check = "assert(closes==1 and replacements==0)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.play(.{ .click = "replacement" });
    const check_replacement = "assert(replacements==1)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check_replacement.ptr, check_replacement.len, "@check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "hiding a focused retained editor releases IME ownership and composition" {
    const f = try Fixture.create(
        \\hidden=ouro.signal(false)
        \\function build() return ouro.box {key='panel', hidden=hidden(),
        \\ ouro.text_input {key='edit',default_text='keep'}} end
    );
    defer f.destroy();
    try f.play(.{ .click = "panel/edit" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    try std.testing.expect((try f.runtime.textInputStatus()) != null);
    _ = try session.apply(.{ .preedit = .{ .text = "compose", .cursor = null } });
    const hide = "hidden:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, hide.ptr, hide.len, "@hide", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expect(f.runtime.focus.current() == null);
    try std.testing.expect((try f.runtime.textInputStatus()) == null);
    try std.testing.expect(session.preedit() == null);
    try std.testing.expect(f.runtime.instances.isActive(target));
    try std.testing.expectEqualStrings("keep", session.model.text());
    try std.testing.expect((try f.runtime.animationDelay()) == null);
}

test "multiline development editing preserves lines and navigates visual rows" {
    const f = try Fixture.create(
        \\value=ouro.signal('')
        \\function build() return ouro.text_input {key='body', multiline=true, height=84, text=value(),
        \\ on_change=function(v) value:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .click = "body" });
    try f.play(.{ .text = "alpha\nb\nthird\n" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    try std.testing.expectEqualStrings("alpha\nb\nthird\n", session.model.text());
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expect((try node(snapshot, "body")).multiline);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .home, .modifiers = .{ .control = true } } });
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    try std.testing.expectEqual(@as(usize, 6), session.model.selection.extent);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try std.testing.expectEqual(@as(usize, 7), session.model.selection.extent);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(@as(usize, 7), session.model.selection.anchor);
    try std.testing.expect(session.model.selection.extent > 8);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    try std.testing.expectEqual(@as(usize, 14), session.model.selection.extent);
    // Native paste uses the same normalization/history as IME commits, not dev text playback.
    try std.testing.expect(try f.runtime.applyClipboardPaste(&f.callbacks, target, "é\r\nlast"));
    try f.settle();
    try std.testing.expectEqualStrings("alpha\nb\nthird\né\nlast", session.model.text());
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings("alpha\nb\nthird\n", session.model.text());
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true, .shift = true } } });
    try std.testing.expectEqualStrings("alpha\nb\nthird\né\nlast", session.model.text());
    try std.testing.expectError(error.DevelopmentTextContainsControl, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "bad\ttext" }));
    var bottom = try f.snapshot();
    defer bottom.deinit();
    try std.testing.expect((try node(bottom, "body")).scroll_offset.? > 0);
    try f.play(.{ .scroll = .{ .target = "body", .delta = -10000 } });
    var top = try f.snapshot();
    defer top.deinit();
    try std.testing.expectEqual(@as(f32, 0), (try node(top, "body")).scroll_offset.?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    var revealed = try f.snapshot();
    defer revealed.deinit();
    try std.testing.expect((try node(revealed, "body")).scroll_offset.? > 0);
}

test "text entry policy preserves retained editing and multiline command navigation" {
    const f = try Fixture.create(
        \\entry = ouro.signal(true)
        \\commands = 0
        \\function build() return ouro.text_input {key='body', multiline=true, height=64,
        \\ autofocus=true, text_entry=entry(), default_text='alpha\nβeta',
        \\ on_command=function() commands=commands+1 end} end
    );
    defer f.destroy();
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    try f.play(.{ .text = "!" });
    try f.exec("entry:set(false)");
    try f.settle();
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expect(!(try node(snapshot, "body")).text_entry);
    try std.testing.expect(!(try node(snapshot, "body")).read_only);
    try std.testing.expectError(error.DevelopmentTargetTextEntryDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "blocked" }));
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_up } });
    try std.testing.expect(session.model.selection.extent < "alpha\n".len);
    try f.exec("assert(commands == 0)");
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings("alpha\nβeta", session.model.text());
    try f.exec("entry:set(true)");
    try f.settle();
    try f.play(.{ .text = "?" });
    try std.testing.expectEqualStrings("alpha\nβeta?", session.model.text());
}

test "double-click shows block caret with word selection before pointer release" {
    const f = try Fixture.create(
        \\shape=ouro.signal('block')
        \\function build() return ouro.text_editor {key='body',height=64,autofocus=true,
        \\ default_text='alpha beta',caret_shape=shape(),caret_blink=false} end
    );
    defer f.destroy();
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(target));
    const bounds = (try f.runtime.semanticTarget("body")).bounds;
    try f.runtime.routePointer(.{ .enter = .{
        .window = f.runtime.window,
        .serial = 1,
        .position = .{ .x = bounds.x + 10, .y = bounds.y + 10 },
    } });
    try f.settle();
    for ([_]@import("../platform/window.zig").PointerButtonState{ .pressed, .released, .pressed }, 0..) |state, index| {
        try f.runtime.routePointer(.{ .button = .{
            .window = f.runtime.window,
            .serial = 2,
            .time_ms = @intCast(index + 1),
            .button = 0x110,
            .state = state,
        } });
        try f.settle();
    }
    try std.testing.expect(session.isSelecting());
    const pressed = (try f.runtime.tree.objectAt(render)).text_input;
    try std.testing.expectEqual(@as(usize, 0), pressed.selection_start);
    try std.testing.expectEqual(@as(usize, 5), pressed.selection_end);
    try std.testing.expectEqual(@as(usize, 5), pressed.caret_offset);
    try std.testing.expect(pressed.show_caret);
    try std.testing.expect(!pressed.reveal_caret); // Drag auto-scroll owns the viewport.
    try f.play(.pointer_up);
    const released = (try f.runtime.tree.objectAt(render)).text_input;
    try std.testing.expect(!session.isSelecting());
    try std.testing.expect(released.show_caret and released.reveal_caret);
    try std.testing.expectEqual(pressed.caret_offset, released.caret_offset);
    try std.testing.expectEqual(pressed.selection_start, released.selection_start);
    try std.testing.expectEqual(pressed.selection_end, released.selection_end);

    // Ordinary beam fields still hide the caret during pointer selection.
    try f.exec("shape:set('beam')");
    try f.settle();
    try f.play(.{ .pointer_down = "body" });
    try std.testing.expect(session.isSelecting());
    const beam = (try f.runtime.tree.objectAt(render)).text_input;
    try std.testing.expect(!beam.show_caret and !beam.reveal_caret);
    try f.play(.pointer_up);
}

test "multiline read-only selection auto-scrolls vertically without editing" {
    const f = try Fixture.create(
        \\function build() return ouro.text_input {key='body', multiline=true, height=64, read_only=true,
        \\ default_text='one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n'} end
    );
    defer f.destroy();
    try f.play(.{ .pointer_down = "body" });
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    const render = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(target));
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = 50, .y = 190 } } });
    try f.settle();
    const initial = session.model.selection.extent;
    for (0..100) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.settle();
    }
    try std.testing.expect(session.model.selection.extent > initial);
    try std.testing.expectEqual(session.model.text().len, session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollDelta(render, .vertical, 100));
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = 0, .y = -80 } } });
    try f.settle();
    for (100..200) |tick| {
        try f.runtime.advanceAnimations(tick * 16 * std.time.ns_per_ms);
        try f.settle();
    }
    try std.testing.expectEqual(@as(usize, 0), session.model.selection.extent);
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.tree.textScrollOffset(render, .vertical));
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 3, .button = 0x110, .state = .released } });
    try f.settle();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try std.testing.expect(!try f.runtime.applyClipboardPaste(&f.callbacks, target, "overwrite\n"));
    try std.testing.expectEqualStrings("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n", session.model.text());
}

test "multiline mode changes replace retained sessions even for equal uncontrolled text" {
    const f = try Fixture.create(
        \\multi=ouro.signal(false)
        \\function build() return ouro.column {key='root',
        \\ ouro.text_input {key='body', default_text='same', multiline=multi()},
        \\ ouro.button {key='toggle', label='Toggle', on_press=function() multi:set(not multi()) end}} end
    );
    defer f.destroy();
    const semantic = try f.runtime.semantics.findPath("root/body");
    const target = f.runtime.instances.handleForId(semantic.id).?;
    try f.play(.{ .click = "root/body" });
    try std.testing.expectError(error.DevelopmentTextContainsControl, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "a\nb" }));
    try f.play(.{ .click = "root/toggle" });
    try std.testing.expect((try f.runtime.text_inputs.session(target)).model.multiline);
    try std.testing.expectEqualStrings("same", (try f.runtime.text_inputs.session(target)).model.text());
    try f.play(.{ .click = "root/body" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end, .modifiers = .{ .control = true } } });
    try f.play(.{ .text = "\nmore" });
    try std.testing.expectEqualStrings("same\nmore", (try f.runtime.text_inputs.session(target)).model.text());
    try f.play(.{ .click = "root/toggle" });
    try std.testing.expect(!(try f.runtime.text_inputs.session(target)).model.multiline);
    try std.testing.expectEqualStrings("same", (try f.runtime.text_inputs.session(target)).model.text());
}

test "focus rings follow keyboard navigation without changing logical pointer focus" {
    const Color = @import("../core/color.zig").Color;
    const f = try Fixture.create(
        \\function build() return ouro.column {key='root', gap=8,
        \\ ouro.button {key='flat', label='Workspace', border_width=0},
        \\ ouro.button {key='bordered', label='Bordered', border_width=1, border='#123456'},
        \\ ouro.text_input {key='edit', default_text='Text'},
        \\} end
    );
    defer f.destroy();
    const flat = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/flat")).id).?;
    const render = try f.runtime.instances.renderObject(flat);
    try f.play(.{ .click = "root/flat" });
    try std.testing.expectEqual(flat, f.runtime.focus.current().?);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_width);
    // Keyboard activation of the SAME pointer-focused button reveals the ring.
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expectEqual(@as(f32, 2), (try f.runtime.tree.objectAt(render)).box.outline_width);
    try std.testing.expect((try f.runtime.tree.objectAt(render)).box.outline_inset);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_gap);
    try f.play(.{ .click = "root/flat" });
    try std.testing.expectEqual(flat, f.runtime.focus.current().?);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_width);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    const bordered = f.runtime.focus.current().?;
    const bordered_render = try f.runtime.instances.renderObject(bordered);
    try std.testing.expectEqual(f.runtime.focus_color, (try f.runtime.tree.objectAt(bordered_render)).box.border_color.?);
    try f.play(.{ .click = "root/bordered" });
    try std.testing.expectEqual(Color.rgba(0x12, 0x34, 0x56, 255), (try f.runtime.tree.objectAt(bordered_render)).box.border_color.?);
    try f.play(.{ .click = "root/edit" });
    const edit_render = try f.runtime.instances.renderObject(f.runtime.focus.current().?);
    try std.testing.expectEqual(f.runtime.focus_color, (try f.runtime.tree.objectAt(edit_render)).box.border_color.?);
    // A keyboard-ineligible layer panel must never show a ring on click.
    try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 0 } });
    try f.settle();
    try f.play(.{ .click = "root/flat" });
    try std.testing.expectEqual(flat, f.runtime.focus.current().?);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.outline_width);
}

test "borderless text inputs keep autofocus and editing without adding field chrome" {
    const f = try Fixture.create(
        \\function build() return ouro.box {key='shell',border_width=1,
        \\ ouro.text_input {key='edit',default_text='',autofocus=true,
        \\   border_width=0,padding_x=0,background='#00000000'}} end
    );
    defer f.destroy();
    const target = f.runtime.focus.current().?;
    const render = try f.runtime.instances.renderObject(target);
    try std.testing.expect(f.runtime.text_inputs.contains(target));
    try std.testing.expect((try f.runtime.tree.objectAt(render)).box.outline_color == null);
    const bounds = (try f.runtime.semanticTarget("shell/edit")).bounds;
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .text = "query" });
    const box = (try f.runtime.tree.objectAt(render)).box;
    try std.testing.expect(box.outline_color == null and box.border_color == null);
    try std.testing.expectEqual(@as(f32, 0), box.outline_width);
    try std.testing.expectEqual(@as(f32, 0), box.border_width);
    try std.testing.expectEqual(bounds, (try f.runtime.semanticTarget("shell/edit")).bounds);
    try std.testing.expectEqualStrings("query", (try f.runtime.text_inputs.session(target)).model.text());
    try std.testing.expect((try f.runtime.textInputStatus()) != null);
}

test "Lua focus requests return from pointer callbacks without remounting the editor" {
    const f = try Fixture.create(
        \\request=ouro.signal(0)
        \\function build() return ouro.column {key='root', gap=8,
        \\ ouro.text_input {key='query', default_text='seed', autofocus=true, focus_request=request()},
        \\ ouro.button {key='scope', label='Scope', on_press=function() request:set(request()+1) end},
        \\ ouro.button {key='other', label='Other'},
        \\} end
    );
    defer f.destroy();
    const target = f.runtime.focus.current().?;
    const session = try f.runtime.text_inputs.session(target);
    const scope = try f.runtime.instances.scope(target);
    const generation = try f.runtime.text_inputs.sessionGeneration(target);
    try f.play(.{ .text = "tail" });
    _ = try session.model.setSelection(.{ .anchor = 6, .extent = 2 });
    const selection = session.model.selection;
    for (0..2) |_| {
        try f.play(.{ .click = "root/other" });
        try std.testing.expect(!std.meta.eql(target, f.runtime.focus.current().?));
        try f.play(.{ .click = "root/scope" });
        try std.testing.expectEqual(target, f.runtime.focus.current().?);
        try std.testing.expectEqual(scope, try f.runtime.instances.scope(target));
        try std.testing.expectEqual(generation, try f.runtime.text_inputs.sessionGeneration(target));
        try std.testing.expectEqual(session, try f.runtime.text_inputs.session(target));
        try std.testing.expectEqualStrings("seedtail", session.model.text());
        try std.testing.expectEqual(selection, session.model.selection);
        try std.testing.expect((try f.runtime.textInputStatus()) != null);
        var snapshot = try f.snapshot();
        defer snapshot.deinit();
        try std.testing.expect((try node(snapshot, "root/query")).focused);
        // Neither autofocus nor an unchanged request may steal focus on rebuild.
        try f.play(.{ .click = "root/other" });
        const other = f.runtime.focus.current().?;
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try f.settle();
        try std.testing.expectEqual(other, f.runtime.focus.current().?);
    }
    try f.play(.{ .click = "root/scope" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings("seed", session.model.text());
    try f.play(.{ .text = "!" });
    try std.testing.expectEqualStrings("seed!", session.model.text());
}

test "forms checkbox requests remain controlled and disabled controls skip focus" {
    const f = try Fixture.create(
        \\requested=false
        \\function build() return ouro.column {key='form', gap=8,
        \\ ouro.checkbox {key='check', label='Enabled', checked=false, on_change=function(v) requested=v end},
        \\ ouro.checkbox {key='disabled', label='Disabled', checked=true, enabled=false},
        \\ ouro.button {key='after', label='After'},
        \\} end
    );
    defer f.destroy();
    try f.play(.{ .click = "form/check" });
    _ = c.lua_getglobal(f.vm.state, "requested");
    try std.testing.expect(c.lua_toboolean(f.vm.state, -1) != 0);
    c.lua_settop(f.vm.state, -2);
    try std.testing.expect(!(try f.runtime.semantics.findPath("form/check")).checked);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("form/after")).id).?, f.runtime.focus.current().?);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "form/disabled" }));
}

test "forms checkbox accepts toggles without losing its focus identity" {
    const f = try Fixture.create(
        \\checked=ouro.signal(false)
        \\function build() return ouro.checkbox {key='check', label='Check', checked=checked(),
        \\ on_change=function(v) checked:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .click = "check" });
    const focused = f.runtime.focus.current().?;
    try std.testing.expect((try f.runtime.semantics.findPath("check")).checked);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expect(!(try f.runtime.semantics.findPath("check")).checked);
    try std.testing.expectEqual(focused, f.runtime.focus.current().?);
}

test "forms radio navigation wraps and follows reordered declarations" {
    const f = try Fixture.create(
        \\selected=ouro.signal(17)
        \\function build()
        \\ local a=ouro.radio {key='a', value=17, label='Seventeen'}
        \\ local b=ouro.radio {key='b', value=29, label='Twenty nine'}
        \\ local d=ouro.radio {key='d', value=43, label='Forty three'}
        \\ return ouro.radio_group {key='choices', selected=selected(),
        \\   on_select=function(v) selected:set(v) end,
        \\   children=selected()==29 and {d,b,a} or {a,b,d}}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect((try f.runtime.semantics.findPath("choices/b")).checked);
    // Now d,b,a: moving right from b must choose a, not its old slot successor d.
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expect((try f.runtime.semantics.findPath("choices/a")).checked);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left } });
    try std.testing.expect((try f.runtime.semantics.findPath("choices/d")).checked);
}

test "forms radio indicators stay centered independently of label font metrics" {
    const f = try Fixture.create(
        \\function build() return ouro.radio_group {key='choices', selected=17, on_select=function() end,
        \\ ouro.radio {key='large', value=17, label='Large', height=44, font_size=28},
        \\ ouro.radio {key='small', value=29, label='Small', height=32, font_size=14}} end
    );
    defer f.destroy();
    for ([_][]const u8{ "choices/large", "choices/small" }, [_]f32{ 22, 16 }) |path, center| {
        const semantic = try f.runtime.semantics.findPath(path);
        const render = try f.runtime.instances.renderObject(f.runtime.instances.handleForId(semantic.id).?);
        const content = f.runtime.tree.firstChild(render).?;
        const indicator = f.runtime.tree.firstChild(content).?;
        const circle = (try f.runtime.tree.objectAt(indicator)).box;
        try std.testing.expectEqual(@as(f32, 12), circle.width.?);
        try std.testing.expectEqual(@as(f32, 12), circle.height.?);
        try std.testing.expectEqual(semantic.checked, circle.background != null);
        const y = (try f.runtime.tree.nodeOffset(content)).y + (try f.runtime.tree.nodeOffset(indicator)).y;
        try std.testing.expectApproxEqAbs(center, y + 6, 0.001);
    }
}

test "forms slider keyboard bounds and captured drag use the declared range" {
    const f = try Fixture.create(
        \\value=ouro.signal(-1.25)
        \\function build() return ouro.slider {key='level', label='Level', width=200,
        \\ value=value(), min=-2.25, max=3, step=0.5, on_change=function(v) value:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_right } });
    try std.testing.expectEqual(@as(f64, -0.75), (try f.runtime.semantics.findPath("level")).range.?.value);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try std.testing.expectEqual(@as(f64, 3), (try f.runtime.semantics.findPath("level")).range.?.value);
    try f.play(.{ .pointer_down = "level" });
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = -80, .y = 180 } } });
    try f.settle();
    try std.testing.expectEqual(@as(f64, -2.25), (try f.runtime.semantics.findPath("level")).range.?.value);
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 2, .button = 0x110, .state = .released } });
    try f.settle();
    try std.testing.expect(f.runtime.range_drag == null);
}

test "forms slider thumb follows constrained width not requested width" {
    const f = try Fixture.create(
        \\value=ouro.signal(7.5)
        \\function build() return ouro.box {key='narrow', width=160,
        \\ ouro.slider {key='level', label='Level', width=300, value=value(), min=0, max=10, step=0.5}} end
    );
    defer f.destroy();
    const semantic = try f.runtime.semantics.findPath("narrow/level");
    const render = try f.runtime.instances.renderObject(f.runtime.instances.handleForId(semantic.id).?);
    const layers = f.runtime.tree.firstChild(render).?;
    const track = f.runtime.tree.firstChild(layers).?;
    const rail = f.runtime.tree.nextSibling(track).?;
    const thumb = f.runtime.tree.nextSibling(f.runtime.tree.firstChild(rail).?).?;
    try std.testing.expectEqual(@as(f32, 160), (try f.runtime.tree.nodeSize(render)).width);
    try std.testing.expectApproxEqAbs(@as(f32, 99), (try f.runtime.tree.nodeOffset(thumb)).x, 0.01);
    try std.testing.expectEqual(@as(f32, 16), (try f.runtime.tree.nodeSize(thumb)).width);
    for ([_][]const u8{ "value:set(0)", "value:set(10)" }, [_]f32{ 0, 132 }) |source, expected| {
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@slider-edge", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        try f.settle();
        try std.testing.expectEqual(expected, (try f.runtime.tree.nodeOffset(thumb)).x);
    }
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    for (snapshot.nodes) |item| if (item.path) |path| {
        try std.testing.expect(std.mem.indexOf(u8, path, "layers") == null);
    };
}

test "forms slider converts wide Lua integer bounds before computing thumb position" {
    const f = try Fixture.create(
        \\function build() return ouro.slider {key='level',label='Wide',width=160,
        \\ value=0,min=math.mininteger,max=math.maxinteger,step=1} end
    );
    defer f.destroy();
    const render = try f.runtime.instances.renderObject(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("level")).id).?);
    const layers = f.runtime.tree.firstChild(render).?;
    const rail = f.runtime.tree.nextSibling(f.runtime.tree.firstChild(layers).?).?;
    const thumb = f.runtime.tree.nextSibling(f.runtime.tree.firstChild(rail).?).?;
    // 160px minus 12px chrome and a 16px thumb leaves 132px travel.
    try std.testing.expectApproxEqAbs(@as(f32, 66), (try f.runtime.tree.nodeOffset(thumb)).x, 0.01);
}

test "forms disabling slider on change cancels the active drag" {
    const f = try Fixture.create(
        \\enabled=ouro.signal(true)
        \\function build() return ouro.slider {key='level', label='Level', width=200,
        \\ value=0, min=0, max=10, step=1, enabled=enabled(),
        \\ on_change=function() enabled:set(false) end} end
    );
    defer f.destroy();
    try f.play(.{ .pointer_down = "level" });
    try std.testing.expect(!(try f.runtime.semantics.findPath("level")).enabled);
    try std.testing.expect(f.runtime.range_drag == null);
}

test "custom range boxes use declared geometry and keep ignored requests controlled" {
    const f = try Fixture.create(
        \\inset=ouro.signal(30); ranged=ouro.signal(true); requests={}; builds=0
        \\function build() builds=builds+1; return ouro.box {key='level', label='Custom', width=200,height=40,
        \\ range=ranged() and {value=-0.25,min=-2.25,max=3,step=0.5,inset=inset()} or nil,
        \\ on_change=function(v) requests[#requests+1]=v end,
        \\ ouro.stack {key='chrome',semantic=false,
        \\   ouro.text {key='caption',text='Custom range'}}} end
    );
    defer f.destroy();
    const semantic = try f.runtime.semantics.findPath("level");
    try std.testing.expectEqual(.slider, semantic.role);
    const handle = f.runtime.instances.handleForId(semantic.id).?;
    _ = try f.runtime.semantics.findPath("level/caption");
    const bounds = (try f.runtime.semanticTarget("level")).bounds;
    try f.play(.{ .pointer_down = "level" });
    try std.testing.expectEqual(handle, f.runtime.focus.current().?);
    // 44 is 10% along the custom 30..170 rail. A stock 14px inset
    // would request -1.25 here instead of -1.75.
    for ([_]f32{ 44, 170, -50 }) |x| {
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = bounds.x + x, .y = bounds.y + 20 } } });
        try f.settle();
    }
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 2, .button = 0x110, .state = .released } });
    try f.settle();
    const Logical = @import("../platform/window.zig").LogicalKey;
    for ([_]Logical{ .arrow_up, .arrow_down, .page_up, .page_down, .home, .end, .enter, .space }) |key|
        try f.play(.{ .key = .{ .keycode = 0, .logical = key } });
    try std.testing.expectEqual(@as(f64, -0.25), (try f.runtime.semantics.findPath("level")).range.?.value);
    const check =
        \\local expected={0.25,-1.75,3,-2.25,0.25,-0.75,3,-2.25,-2.25,3}
        \\assert(#requests==#expected and builds==1)
        \\for i,v in ipairs(expected) do assert(requests[i]==v) end
        \\inset:set(0)
    ;
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-range", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.instances.rangeInset(handle));
    try f.play(.{ .pointer_down = "level" });
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 3, .position = .{ .x = bounds.x + 44, .y = bounds.y + 20 } } });
    try f.settle();
    const remove = "assert(#requests==12 and requests[12]==-1.25); ranged:set(false)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, remove.ptr, remove.len, "@remove-range", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expectEqual(handle, f.runtime.instances.handleForId(semantic.id).?);
    try std.testing.expect(f.runtime.range_drag == null);
    try std.testing.expect(!f.runtime.buttons.contains(handle));
    try std.testing.expectEqual(.group, (try f.runtime.semantics.findPath("level")).role);
}

test "invalid range candidates preserve committed geometry and handlers" {
    const f = try Fixture.create(
        \\requests={}
        \\function build() return ouro.box {key='level',label='Custom',width=200,height=40,
        \\ range={value=-0.25,min=-2.25,max=3,step=0.5,inset=30},
        \\ on_change=function(v) requests[#requests+1]=v end} end
        \\good=build
    );
    defer f.destroy();
    try f.play(.{ .pointer_down = "level" });
    const handle = f.runtime.range_drag.?;
    const bounds = (try f.runtime.semanticTarget("level")).bounds;
    const valid_range = "range={value=0,min=-1,max=1,step=0.5}";
    for ([_][]const u8{
        "range=false",
        "range={value=0,min=1,max=1,step=1}",
        "range={value=2,min=-1,max=1,step=1}",
        "range={value=0,min=-1,max=1,step=0}",
        "range={value=0,min=-1,max=1,step=1,inset=-1}",
        "range={value=0,min=-1,max=1,step=1,inset=math.huge}",
        valid_range ++ ",semantic=false",
        valid_range ++ ",activate=true",
        valid_range ++ ",role='button'",
        valid_range ++ ",option=1",
        valid_range ++ ",checked=false",
        valid_range ++ ",on_press=function() end",
        valid_range ++ ",label=nil",
        valid_range ++ ",on_change=false",
    }) |invalid| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return ouro.box {{key='level',label='Bad',{s}}} end", .{invalid});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@invalid-range", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(error.LuaBuildFailed, f.settle());
        try std.testing.expectEqual(handle, f.runtime.range_drag.?);
        try std.testing.expectEqual(handle, f.runtime.focus.current().?);
        try std.testing.expectEqual(@as(f32, 30), try f.runtime.instances.rangeInset(handle));
        try std.testing.expectEqual(@as(usize, 0), f.builder.pending_handler_count);
    }
    const restore = "build=good";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, restore.ptr, restore.len, "@restore-range", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 1, .position = .{ .x = bounds.x + 44, .y = bounds.y + 20 } } });
    try f.settle();
    const check = "assert(#requests==2 and requests[1]==0.25 and requests[2]==-1.75)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-range", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "outside pointer listeners skip descendants and hidden scopes and can propagate" {
    const f = try Fixture.create(
        \\shown=ouro.signal(true); outside=0; presses=0; inside=0
        \\function build() return ouro.row {key='root',gap=20,
        \\ ouro.box {key='scope',hidden=not shown(),
        \\   on_pointer_down_outside={button=272,propagate=true,handler=function(e)
        \\     assert(e.phase=='capture' and e.kind=='press'); outside=outside+3;shown:set(false)
        \\   end},
        \\   ouro.button {key='inside',label='Inside',on_press=function() inside=inside+5 end}},
        \\ ouro.button {key='outside',label='Outside',on_press=function() presses=presses+7 end}}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "root/scope/inside" });
    try f.play(.{ .click = "root/outside" });
    try f.play(.{ .click = "root/outside" });
    const check = "assert(inside==5 and outside==3 and presses==14)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-outside", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "floating scroll at its limit does not chain to the trigger viewport" {
    const f = try Fixture.create(
        \\function build() return ouro.box {key='frame',height=70,
        \\ ouro.scroll {key='outer',ouro.column {key='body',
        \\  ouro.anchored {key='anchor',side='right',
        \\   ouro.box {key='trigger',width=30,height=20},
        \\   ouro.scroll {key='popup',ouro.box {key='content',width=80,height=500}}},
        \\  ouro.box {key='tail',height=400}}}} end
    );
    defer f.destroy();
    try f.play(.{ .scroll = .{ .target = "frame/outer/body/anchor/popup", .delta = 1000 } });
    var bottom = try f.snapshot();
    defer bottom.deinit();
    try std.testing.expect((try node(bottom, "frame/outer/body/anchor/popup")).scroll_offset.? > 0);
    try f.play(.{ .scroll = .{ .target = "frame/outer/body/anchor/popup", .delta = 37 } });
    var after = try f.snapshot();
    defer after.deinit();
    try std.testing.expectEqual(@as(f32, 0), (try node(after, "frame/outer")).scroll_offset.?);
    try std.testing.expectEqual((try node(bottom, "frame/outer/body/anchor/popup")).scroll_offset.?, (try node(after, "frame/outer/body/anchor/popup")).scroll_offset.?);
}

test "anchored declarations reject invalid options and child counts" {
    for ([_][]const u8{
        "function build() return ouro.anchored {key='a'} end",
        "function build() return ouro.anchored {key='a',side='middle',ouro.box {key='t'}} end",
        "function build() return ouro.anchored {key='a',alignment='stretch',ouro.box {key='t'}} end",
        "function build() return ouro.anchored {key='a',gap=-1,ouro.box {key='t'}} end",
        "function build() return ouro.anchored {key='a',margin=0/0,ouro.box {key='t'}} end",
        "function build() return ouro.anchored {key='a',flip=0,ouro.box {key='t'}} end",
        "function build() return ouro.anchored {key='a',ouro.box {key='t'},ouro.box {key='p'},ouro.box {key='extra'}} end",
    }) |source| try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
}

test "animation frames retain components and identity and stop at the exact endpoint" {
    const f = try Fixture.create(
        \\roots=0; initializes=0; renders=0; frames=0; unrelated=ouro.signal(0)
        \\local Motion=ouro.stateful(function()
        \\ initializes=initializes+1
        \\ return function()
        \\  renders=renders+1
        \\  return ouro.animation {key='motion',duration=100,easing='ease_in',render=function(p)
        \\   frames=frames+1
        \\   return ouro.box {key='bar',width=43+200*p,height=17,background='#234567'}
        \\  end}
        \\ end
        \\end)
        \\function build() roots=roots+1; return ouro.column {key='root',
        \\ ouro.text {key='other',text='Other '..unrelated()},Motion {key='component'}} end
    );
    defer f.destroy();
    const path = "root/component/motion/bar";
    const id = (try f.runtime.semantics.findPath(path)).id;
    const handle = f.runtime.instances.handleForId(id).?;
    try std.testing.expectEqual(@as(f32, 43), (try f.runtime.semanticTarget(path)).bounds.width);
    try f.runtime.advanceAnimations(1000 * std.time.ns_per_ms);
    try f.settle();
    try f.runtime.advanceAnimations(1025 * std.time.ns_per_ms);
    try f.settle();
    // At one quarter, quadratic ease-in is 1/16, not linear 1/4.
    try std.testing.expectEqual(@as(f32, 55.5), (try f.runtime.semanticTarget(path)).bounds.width);
    const check = "assert(roots==1 and initializes==1 and renders==1 and frames==2); unrelated:set(7)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@animation-check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expectEqual(@as(f32, 55.5), (try f.runtime.semanticTarget(path)).bounds.width);
    try std.testing.expectEqual(handle, f.runtime.instances.handleForId(id).?);
    try f.runtime.advanceAnimations(1099 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(?u64, std.time.ns_per_ms), try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(1100 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(f32, 243), (try f.runtime.semanticTarget(path)).bounds.width);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    const builds = f.runtime.metrics.builds.count;
    try f.runtime.advanceAnimations(9000 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(builds, f.runtime.metrics.builds.count);
}

test "animation sampling between frames preserves development tokens and pending endpoint work" {
    const f = try Fixture.create(
        \\extra=ouro.signal(0)
        \\function build() local e=extra(); return ouro.animation {key='motion',duration=100,
        \\ render=function(p) return ouro.box {key='bar',width=43+200*p+e,height=17} end} end
    );
    defer f.destroy();
    try f.runtime.advanceAnimations(0);
    const initial_token = dev.Token.current(&f.runtime);
    const initial_builds = f.runtime.metrics.builds.count;
    try f.runtime.advanceAnimations(5 * std.time.ns_per_ms);
    try f.settle();
    try initial_token.validate(&f.runtime);
    try std.testing.expectEqual(initial_builds, f.runtime.metrics.builds.count);
    try std.testing.expectEqual(@as(f32, 43), (try f.runtime.semanticTarget("motion/bar")).bounds.width);
    try std.testing.expectEqual(@as(?u64, 11 * std.time.ns_per_ms), try f.runtime.animationDelay());

    // An unrelated build consumes the current sample without postponing the
    // already requested frame or restarting its timeline.
    const update = "extra:set(1)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, update.ptr, update.len, "@animation-external", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expectEqual(@as(f32, 54), (try f.runtime.semanticTarget("motion/bar")).bounds.width);
    const token = dev.Token.current(&f.runtime);
    try f.runtime.advanceAnimations(6 * std.time.ns_per_ms);
    try f.settle();
    try token.validate(&f.runtime);
    try f.runtime.advanceAnimations(16 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectError(error.StaleDevelopmentTarget, token.validate(&f.runtime));
    try std.testing.expectEqual(@as(f32, 76), (try f.runtime.semanticTarget("motion/bar")).bounds.width);
    try f.runtime.advanceAnimations(99 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(?u64, std.time.ns_per_ms), try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(f32, 244), (try f.runtime.semanticTarget("motion/bar")).bounds.width);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
}

test "animation can render nil and restart after removal without retaining timer demand" {
    const f = try Fixture.create(
        \\shown=ouro.signal(true); measured=-1
        \\function build()
        \\ if not shown() then return nil end
        \\ return ouro.animation {key='empty',duration=80,loop=true,
        \\  render=function(p) measured=p;return nil end}
        \\end
    );
    defer f.destroy();
    try f.runtime.advanceAnimations(0);
    try f.runtime.advanceAnimations(30 * std.time.ns_per_ms);
    try f.settle();
    const hide = "assert(measured==0.375); shown:set(false)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, hide.ptr, hide.len, "@hide-animation", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expect((try f.runtime.animationDelay()) == null);
    try f.runtime.advanceAnimations(97 * std.time.ns_per_ms);
    const show = "shown:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, show.ptr, show.len, "@show-animation", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    const restarted = "assert(measured==0)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, restarted.ptr, restarted.len, "@restarted-animation", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try std.testing.expect((try f.runtime.animationDelay()) != null);
}

test "animation validates declarations and zero duration settles immediately" {
    for ([_][]const u8{
        "function build() return ouro.animation {key='a',render=function() end} end",
        "function build() return ouro.animation {duration=10,render=function() end} end",
        "function build() return ouro.animation {key='a',duration=-1,render=function() end} end",
        "function build() return ouro.animation {key='a',duration=1.5,render=function() end} end",
        "function build() return ouro.animation {key='a',duration='10',render=function() end} end",
        "function build() return ouro.animation {key='a',duration=math.huge,render=function() end} end",
        "function build() return ouro.animation {key='a',duration=0,loop=true,render=function() end} end",
        "function build() return ouro.animation {key='a',duration=10,loop=1,render=function() end} end",
        "function build() return ouro.animation {key='a',duration=10,easing='typo',render=function() end} end",
        "function build() return ouro.animation {key='a',duration=10,render=1} end",
        "function build() local a=ouro.animation {key='same',duration=10,render=function() end}; return ouro.row {key='row',a,a} end",
        "function build() return ouro.animation {key='a',duration=10,render=function() return 7 end} end",
    }) |source| try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
    const f = try Fixture.create(
        \\function build() return ouro.animation {key='instant',duration=0,
        \\ render=function(p) assert(p==1);return ouro.box {key='bar',width=73,height=19} end} end
    );
    defer f.destroy();
    try std.testing.expectEqual(@as(f32, 73), (try f.runtime.semanticTarget("instant/bar")).bounds.width);
    try std.testing.expect((try f.runtime.animationDelay()) == null);
}

test "transition retargets committed paint without layout and cancels on removal" {
    const f = try Fixture.create(
        \\target=ouro.signal(90); shown=ouro.signal(true); initial=ouro.signal(10)
        \\duration=ouro.signal(100); noise=ouro.signal(0); measured=0
        \\function build()
        \\ local ignored=noise()
        \\ return ouro.column {key='root', shown() and ouro.transition {
        \\  key='motion',target=target(),initial=initial(),duration=duration(),
        \\  render=function(value)
        \\   measured=value
        \\   return ouro.box {key='bar',width=40,height=17,transform={x=value},background='#234567'}
        \\  end} or nil}
        \\end
    );
    defer f.destroy();
    const path = "root/motion/bar";
    const id = (try f.runtime.semantics.findPath(path)).id;
    const handle = f.runtime.instances.handleForId(id).?;
    const root = (try f.runtime.instances.rootRenderObject()).?;
    const layouts = try f.runtime.tree.layoutCount(root);
    const origin = (try f.runtime.semanticTarget("root")).bounds.x;
    const ms = std.time.ns_per_ms;
    // At t=30 an unpublished sample is 34. Retarget must keep the displayed
    // 30, then reverse a second time from 20 rather than jumping to an endpoint.
    for ([_]struct { time: u64, source: []const u8 = "", x: f32 }{
        .{ .time = 0, .x = 10 },
        .{ .time = 25, .x = 30 },
        .{ .time = 30, .source = "assert(measured==30);target:set(-10)", .x = 30 },
        .{ .time = 55, .x = 20 },
        .{ .time = 56, .source = "target:set(60)", .x = 20 },
        .{ .time = 81, .x = 30 },
        .{ .time = 81, .source = "noise:set(1);initial:set(-999)", .x = 30 },
        .{ .time = 156, .x = 60 },
        .{ .time = 200, .source = "target:set(123);duration:set(0)", .x = 123 },
    }) |step| {
        try f.runtime.advanceAnimations(step.time * ms);
        if (step.source.len != 0) {
            try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, step.source.ptr, step.source.len, "@transition-retarget", "t"));
            try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        }
        try f.settle();
        try std.testing.expectEqual(origin + step.x, (try f.runtime.semanticTarget(path)).bounds.x);
        try std.testing.expectEqual(handle, f.runtime.instances.handleForId(id).?);
        try std.testing.expectEqual(layouts, try f.runtime.tree.layoutCount(root));
    }
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    const builds = f.runtime.metrics.builds.count;
    try f.runtime.advanceAnimations(400 * ms);
    try f.settle();
    try std.testing.expectEqual(builds, f.runtime.metrics.builds.count);
    for ([_][]const u8{
        "duration:set(100);target:set(-20)",
        "shown:set(false)",
        "shown:set(true);initial:set(7)",
    }, 0..) |source, index| {
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@transition-lifecycle", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        try f.settle();
        try std.testing.expectEqual(index == 1, (try f.runtime.animationDelay()) == null);
    }
    try std.testing.expectEqual(origin + 7, (try f.runtime.semanticTarget(path)).bounds.x);
}

test "transition validates finite numeric declarations and mounts settled by default" {
    for ([_][]const u8{
        "duration=100",                    "target='3',duration=100",             "target=0/0,duration=100",
        "target=math.huge,duration=100",   "target=1,initial=false,duration=100", "target=1,initial=-math.huge,duration=100",
        "target=1,duration=100,loop=true", "target=1,duration=0,loop=true",       "target=1,duration=-1",
        "target=1,duration=1.5",           "target=1,duration='100'",             "target=1,duration=100,easing='spring'",
    }) |properties| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return ouro.transition {{key='t',{s},render=function() end}} end", .{properties});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
    }
    const f = try Fixture.create(
        \\function build() return ouro.transition {key='t',target=-12.5,duration=100,
        \\ render=function(value) assert(value==-12.5);return ouro.box {key='bar',width=40,height=17} end} end
    );
    defer f.destroy();
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "presence retains exit state reverses continuously and disposes at zero" {
    const f = try Fixture.create(
        \\shown=ouro.signal(true); mounted=ouro.signal(true); initializes=0; value=0
        \\local Child=ouro.stateful(function()
        \\ initializes=initializes+1
        \\ return function() return ouro.box {key='child',width=40,height=17,background='#234567'} end
        \\end)
        \\function build() return ouro.column {key='root',mounted() and ouro.presence {
        \\ key='life',present=shown(),duration=100,render=function(p)
        \\  value=p
        \\  return ouro.box {key='paint',width=40,height=17,opacity=p,transform={x=32*p},Child {key='state'}}
        \\ end} or nil} end
    );
    defer f.destroy();
    const path = "root/life/paint/state/child";
    const id = (try f.runtime.semantics.findPath(path)).id;
    const handle = f.runtime.instances.handleForId(id).?;
    const render = try f.runtime.instances.renderObject(handle);
    const root = (try f.runtime.instances.rootRenderObject()).?;
    const layouts = try f.runtime.tree.layoutCount(root);
    const origin = (try f.runtime.semanticTarget(path)).bounds.x;
    for ([_]struct { time: u64, source: []const u8 = "", value: f32, interactive: bool = true }{
        .{ .time = 0, .value = 0 },
        .{ .time = 100, .value = 1 },
        .{ .time = 100, .source = "shown:set(false)", .value = 1, .interactive = false },
        .{ .time = 125, .value = 0.75, .interactive = false },
        .{ .time = 125, .source = "shown:set(true)", .value = 0.75 },
        .{ .time = 150, .value = 0.8125 },
        .{ .time = 225, .value = 1 },
        .{ .time = 225, .source = "shown:set(false)", .value = 1, .interactive = false },
    }) |step| {
        try f.runtime.advanceAnimations(step.time * std.time.ns_per_ms);
        if (step.source.len != 0) {
            try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, step.source.ptr, step.source.len, "@presence", "t"));
            try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        }
        try f.settle();
        try std.testing.expectEqual(origin + 32 * step.value, (try f.runtime.semanticTarget(path)).bounds.x);
        try std.testing.expectEqual(handle, f.runtime.instances.handleForId(id).?);
        try std.testing.expectEqual(render, try f.runtime.instances.renderObject(handle));
        try std.testing.expectEqual(layouts, try f.runtime.tree.layoutCount(root));
        try std.testing.expect(f.runtime.instances.isVisible(handle));
        try std.testing.expectEqual(step.interactive, f.runtime.instances.isInteractive(handle));
        try std.testing.expectEqual(step.interactive, (try f.runtime.semantics.findPath(path)).enabled);
    }
    try f.runtime.advanceAnimations(325 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expect(f.runtime.instances.handleForId(id) == null);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    const builds = f.runtime.metrics.builds.count;
    try f.runtime.advanceAnimations(400 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(builds, f.runtime.metrics.builds.count);
    for ([_][]const u8{ "assert(initializes==1);shown:set(true)", "assert(initializes==2);mounted:set(false)" }, 0..) |source, i| {
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@presence-remount", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        try f.settle();
        if (i == 0) {
            try std.testing.expect(!std.meta.eql(handle, f.runtime.instances.handleForId((try f.runtime.semantics.findPath(path)).id).?));
            try std.testing.expectEqual(origin, (try f.runtime.semanticTarget(path)).bounds.x);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), f.runtime.animations.count());
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "presence exit releases modal focus and capture while nested content stays painted" {
    const f = try Fixture.create(
        \\opened=ouro.signal(false); hits=0
        \\function build() return ouro.stack {key='root',
        \\ ouro.button {key='open',label='Open',on_press=function() opened:set(true) end},
        \\ ouro.presence {key='life',present=opened(),duration=100,render=function(p)
        \\  return ouro.dialog {key='dialog',label='Confirm',width=240,on_cancel=function() opened:set(false) end,
        \\   ouro.presence {key='nested',present=true,duration=0,render=function()
        \\    return ouro.button {key='save',label='Save',on_press=function() hits=hits+1 end}
        \\   end}}
        \\ end}} end
    );
    defer f.destroy();
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try f.play(.{ .click = "root/open" });
    try f.runtime.advanceAnimations(0);
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    const path = "root/life/dialog/nested/save";
    const handle = f.runtime.instances.handleForId((try f.runtime.semantics.findPath(path)).id).?;
    try f.play(.{ .pointer_down = path });
    try std.testing.expect(f.runtime.router.captured != null);
    // Native buttons activate on press, before exit is requested.
    var valid: c_int = 0;
    _ = c.lua_getglobal(f.vm.state, "hits");
    try std.testing.expectEqual(@as(c.Integer, 1), c.lua_tointegerx(f.vm.state, -1, &valid));
    c.lua_settop(f.vm.state, -2);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.instances.isVisible(handle));
    try std.testing.expect(!f.runtime.instances.isInteractive(handle));
    try std.testing.expect(f.runtime.router.captured == null);
    try std.testing.expect(f.runtime.buttons.armed == null);
    try std.testing.expect(f.runtime.focus.boundary == null);
    const opener = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/open")).id).?;
    try std.testing.expectEqual(opener, f.runtime.focus.current().?);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = path }));
    // Reopen while the old dialog still paints. Hit testing must fall through it.
    try f.play(.{ .click = "root/open" });
    try std.testing.expectEqual(handle, f.runtime.instances.handleForId((try f.runtime.semantics.findPath(path)).id).?);
    try std.testing.expect(f.runtime.instances.isInteractive(handle));
    try f.play(.{ .click = path });
    _ = c.lua_getglobal(f.vm.state, "hits");
    try std.testing.expectEqual(@as(c.Integer, 2), c.lua_tointegerx(f.vm.state, -1, &valid));
    c.lua_settop(f.vm.state, -2);
}

test "presence excludes floated hits outside listeners and queued input and rolls back failed exits" {
    const f = try Fixture.create(
        \\shown=ouro.signal(true); broken=ouro.signal(false); hits=0; outside=0
        \\function build() return ouro.row {key='root',gap=100,
        \\ ouro.presence {key='life',present=shown(),duration=100,render=function()
        \\  return ouro.box {key='scope',on_pointer_down_outside={propagate=true,handler=function() outside=outside+1 end},
        \\   broken() and 'invalid description' or ouro.anchored {key='anchor',side='bottom',gap=8,
        \\    ouro.box {key='trigger',width=40,height=20},
        \\    ouro.button {key='popup',label='Popup',on_press=function() hits=hits+1 end}}}
        \\ end},ouro.button {key='other',label='Other'}} end
    );
    defer f.destroy();
    try f.runtime.advanceAnimations(0);
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    const path = "root/life/scope/anchor/popup";
    const handle = f.runtime.instances.handleForId((try f.runtime.semantics.findPath(path)).id).?;
    const center = (try f.runtime.semanticTarget(path)).center;
    // A rejected exit must not disable the still-committed tree or retarget it.
    const bad = "shown:set(false);broken:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, bad.ptr, bad.len, "@presence-bad", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try std.testing.expectError(error.LuaBuildFailed, f.settle());
    try std.testing.expect(f.runtime.instances.isInteractive(handle));
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    const repair = "broken:set(false)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, repair.ptr, repair.len, "@presence-repair", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 0, .position = center } });
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 0, .time_ms = 0, .button = 272, .state = .pressed } });
    // Commit exit before draining already-routed events.
    _ = c.lua_getglobal(f.vm.state, "build");
    const reference = c.luaL_ref(f.vm.state, c.registry_index);
    defer c.luaL_unref(f.vm.state, c.registry_index, reference);
    try f.runtime.reconcile(.{ .width = 324, .height = 224 }, &f.builder, reference);
    try f.settle();
    const root = (try f.runtime.instances.rootRenderObject()).?;
    const hit = try f.runtime.tree.hitTest(root, center);
    if (hit) |target| try std.testing.expect(try f.runtime.tree.isInteractive(target));
    try std.testing.expect(f.runtime.instances.isVisible(handle));
    try std.testing.expect(!f.runtime.instances.isInteractive(handle));
    try f.play(.{ .click = "root/other" });
    const check = "assert(hits==0 and outside==0);shown:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@presence-check", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try f.play(.{ .click = path });
    const fresh = "assert(hits==1 and outside==0)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, fresh.ptr, fresh.len, "@presence-fresh", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "presence validates declarations even absent and zero duration removes immediately" {
    for ([_][]const u8{
        "duration=100",                               "present=1,duration=100",                  "present='false',duration=100",
        "present=false,duration=-1",                  "present=false,duration=1.5",              "present=false,duration=100,loop=true",
        "present=false,duration=100,easing='spring'", "present=false,duration=100,render=false",
    }) |properties| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return ouro.presence {{key='p',render=function() end,{s}}} end", .{properties});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
    }
    const f = try Fixture.create(
        \\shown=ouro.signal(true)
        \\function build() return ouro.presence {key='p',present=shown(),duration=0,render=function(p)
        \\ assert(p==1);return ouro.box {key='paint',width=20,height=20}
        \\end} end
    );
    defer f.destroy();
    const id = (try f.runtime.semantics.findPath("p/paint")).id;
    const source = "shown:set(false)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@presence-zero", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expect(f.runtime.instances.handleForId(id) == null);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "forms dialog contains focus and restores opener after escape" {
    const f = try Fixture.create(
        \\opened=ouro.signal(false)
        \\function build()
        \\ local children={ouro.button {key='open', label='Open', on_press=function() opened:set(true) end}}
        \\ if opened() then children[2]=ouro.dialog {key='dialog', label='Confirm', width=240,
        \\   on_cancel=function() opened:set(false) end,
        \\   ouro.row {key='actions', gap=8,
        \\     ouro.button {key='first', label='Keep'}, ouro.button {key='last', label='Discard'}}} end
        \\ return ouro.stack {key='root', children=children}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "root/open" });
    const first = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/dialog/actions/first")).id).?;
    const last = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/dialog/actions/last")).id).?;
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(last, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary == null);
    try std.testing.expectEqual(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/open")).id).?, f.runtime.focus.current().?);
}

test "custom dialog boxes gate outside input and restore focus when hidden" {
    const f = try Fixture.create(
        \\opened=ouro.signal(false); empty=ouro.signal(false); opens=0; cancels=0; inner=0
        \\function build() return ouro.row {key='root',gap=20,
        \\ ouro.button {key='open',label='Open',width=80,on_press=function() opens=opens+1;opened:set(true) end},
        \\ ouro.box {key='dialog',role='dialog',label='Custom',hidden=not opened(),
        \\   width=180,height=140,padding=9,background='#123456',
        \\   on_cancel=function() cancels=cancels+1;opened:set(false) end,
        \\   not empty() and ouro.column {key='actions',semantic=false,
        \\     ouro.button {key='first',label='First'},
        \\     ouro.button {key='last',label='Last',on_cancel=function() inner=inner+1 end}} or nil}}
        \\end
    );
    defer f.destroy();
    try std.testing.expect(f.runtime.focus.boundary == null);
    try f.play(.{ .click = "root/open" });
    const dialog = f.runtime.focus.boundary.?;
    const first = f.runtime.focus.current().?;
    const bounds = (try f.runtime.semanticTarget("root/dialog")).bounds;
    try std.testing.expectEqual(@as(f32, 180), bounds.width);
    try std.testing.expectEqual(@as(f32, 140), bounds.height);
    try std.testing.expect(!f.runtime.buttons.contains(dialog));
    // The custom surface does not cover the opener. Hit testing can reach it,
    // but the native modal boundary must suppress its callback and focus.
    try f.play(.{ .click = "root/open" });
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab, .modifiers = .{ .shift = true } } });
    try std.testing.expectEqual(f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/dialog/last")).id).?, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expectEqual(dialog, f.runtime.focus.boundary.?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(first, f.runtime.focus.current().?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary == null);
    const opener = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("root/open")).id).?;
    try std.testing.expectEqual(opener, f.runtime.focus.current().?);
    const prepare = "assert(opens==1 and cancels==1 and inner==1); empty:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, prepare.ptr, prepare.len, "@empty-dialog", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try f.play(.{ .click = "root/open" });
    try std.testing.expectEqual(dialog, f.runtime.focus.boundary.?);
    try std.testing.expect(f.runtime.focus.current() == null);
    // With no focusable child, Escape must fall back to the dialog boundary.
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary == null);
    try std.testing.expectEqual(opener, f.runtime.focus.current().?);
    const check = "assert(opens==2 and cancels==2 and inner==1)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-dialog", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "invalid dialog candidates preserve the committed modal boundary" {
    const f = try Fixture.create(
        \\cancels=0
        \\function build() return ouro.dialog {key='dialog',label='Original',
        \\ on_cancel=function() cancels=cancels+1 end,ouro.button {key='action',label='Keep'}} end
        \\good=build
    );
    defer f.destroy();
    const boundary = f.runtime.focus.boundary.?;
    const focused = f.runtime.focus.current().?;
    for ([_][]const u8{
        "ouro.box {key='bad',role='dialog',label='Bad',semantic=false}",
        "ouro.box {key='bad',role='dialog',label='Bad',activate=true}",
        "ouro.box {key='bad',role='dialog',label='Bad',enabled=false}",
        "ouro.box {key='bad',role='dialog'}",
        "ouro.box {key='bad',role='dialog',label='Bad',on_cancel=false}",
        "ouro.dialog {key='bad',label='Bad',width=false}",
        "ouro.dialog {key='bad',label='Bad',width='fill'}",
        "ouro.dialog {key='bad',label='Bad',width=-1}",
        "ouro.dialog {key='bad',label='Bad',ouro.box {key='a'},ouro.box {key='b'}}",
        "ouro.stack {key='two',ouro.box {key='a',role='dialog',label='A'},ouro.dialog {key='b',label='B'}}",
    }, 0..) |invalid, index| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{invalid});
        defer std.testing.allocator.free(source);
        try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, source.ptr, source.len, "@invalid-dialog", "t"));
        try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
        _ = try f.runtime.build_owners.markDirty(f.runtime.root_owner);
        try std.testing.expectError(if (index == 9) error.MultipleDialogsUnsupported else error.LuaBuildFailed, f.settle());
        try std.testing.expectEqual(boundary, f.runtime.focus.boundary.?);
        try std.testing.expectEqual(focused, f.runtime.focus.current().?);
        try std.testing.expectEqual(@as(usize, 0), f.builder.pending_handler_count);
    }
    const restore = "build=good";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, restore.ptr, restore.len, "@restore-dialog", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    // Dispatch against the committed handler before rebuilding the restored
    // source; development playback requires a settled successful build.
    try f.runtime.routeKeyboard(.{ .key = .{ .window = f.runtime.window, .serial = 0, .time_ms = 0, .state = .pressed, .translated = .{ .keycode = 0, .logical = .escape } } });
    try f.settle();
    const check = "assert(cancels==1)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-dialog", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "forms dialog escape bubbles from plain fields but not active composition" {
    const f = try Fixture.create(
        \\opened=ouro.signal(true)
        \\function build() return ouro.stack {key='root',
        \\ opened() and ouro.dialog {key='dialog', label='Edit', on_cancel=function() opened:set(false) end,
        \\ ouro.text_input {key='name', default_text='name'}} or ouro.button {key='done', label='Done'}} end
    );
    defer f.destroy();
    const session = try f.runtime.text_inputs.session(f.runtime.focus.current().?);
    _ = try session.apply(.{ .preedit = .{ .text = "composing", .cursor = null } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary != null);
    _ = try session.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .escape } });
    try std.testing.expect(f.runtime.focus.boundary == null);
}

test "forms spinbox commits typed drafts and applies native bounds" {
    const f = try Fixture.create(
        \\value=ouro.signal(-1.25)
        \\function build() return ouro.spinbox {key='number', label='Number', value=value(),
        \\ min=-2.25, max=3, step=0.5, on_change=function(v) value:set(v) end} end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_a, .modifiers = .{ .control = true } } });
    try f.play(.{ .text = "99" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("3.0", (try node(snapshot, "number/control/value")).value.?);
    try std.testing.expect(!(try node(snapshot, "number/control/increase")).enabled);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    var changed = try f.snapshot();
    defer changed.deinit();
    try std.testing.expectEqualStrings("2.75", (try node(changed, "number/control/value")).value.?);
}

test "development click releases a button disabled by its own press handler" {
    const f = try Fixture.create(
        \\busy = ouro.signal(false)
        \\function build()
        \\  return ouro.button {key='save', label='Save', enabled=not busy(), on_press=function() busy:set(true) end}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .click = "save" });
    try std.testing.expect(!(try f.runtime.semantics.findPath("save")).enabled);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "save" }));
}

test "development click and hover use dispatch, reject disabled and stale targets, and own bounded snapshots" {
    const f = try Fixture.create(
        \\checked = ouro.signal(false)
        \\function build()
        \\  return ouro.column {key='root', gap=13,
        \\    ouro.switch {key='left', label='Left', checked=checked(), on_change=function(v) checked:set(v) end},
        \\    ouro.switch {key='right', label='Right', checked=true, enabled=false},
        \\  }
        \\end
    );
    defer f.destroy();
    var before = try f.snapshot();
    defer before.deinit();
    const left = try node(before, "root/left");
    const right = try node(before, "root/right");
    try std.testing.expect(!left.checked and right.checked and !right.enabled);
    try std.testing.expect(left.bounds.y < right.bounds.y and left.bounds.width > 0);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, before.token, .{ .click = "root/right" }));
    try std.testing.expectError(error.DevelopmentSnapshotCapacityExceeded, dev.inspect(std.testing.allocator, &f.runtime, .{ .nodes = 1 }));
    try std.testing.expectError(error.DevelopmentSnapshotCapacityExceeded, dev.inspect(std.testing.allocator, &f.runtime, .{ .text_bytes = 5 }));

    var playback = try dev.Playback.init(&f.runtime, before.token, .{ .click = "root/left" });
    try std.testing.expectEqual(.routed, try playback.advance(&f.runtime));
    try std.testing.expectError(error.DevelopmentRuntimeNotSettled, playback.advance(&f.runtime));
    try f.settle();
    try std.testing.expectEqual(.routed, try playback.advance(&f.runtime));
    try std.testing.expect(!(try f.runtime.semantics.findPath("root/left")).checked);
    try f.settle();
    try std.testing.expectEqual(.routed, try playback.advance(&f.runtime));
    try std.testing.expectError(error.DevelopmentRuntimeNotSettled, playback.advance(&f.runtime));
    try f.settle();
    try std.testing.expectEqual(.complete, try playback.advance(&f.runtime));
    var after = try f.snapshot();
    defer after.deinit();
    try std.testing.expect((try node(after, "root/left")).checked);
    try std.testing.expect((try node(after, "root/right")).checked);
    try std.testing.expect(!(try node(before, "root/left")).checked);
    try std.testing.expectError(error.StaleDevelopmentTarget, dev.Playback.init(&f.runtime, before.token, .{ .click = "root/left" }));
    try f.play(.{ .hover = "root/right" });
    var wrong_window = dev.Token.current(&f.runtime);
    wrong_window.window.generation += 1;
    try std.testing.expectError(error.StaleDevelopmentTarget, wrong_window.validate(&f.runtime));
    const old_generation = dev.Token.current(&f.runtime);
    try f.runtime.clear(&f.builder);
    try std.testing.expectError(error.StaleDevelopmentTarget, old_generation.validate(&f.runtime));
}

test "development reports retained list selection and cancels a pressed pointer through routing" {
    const f = try Fixture.create(
        \\function build()
        \\  return ouro.listbox {key='choices', selected=7, on_select=function() end,
        \\    ouro.option {key='first', value=7, label='Seven'},
        \\    ouro.option {key='second', value=29, label='Twenty nine'},
        \\  }
        \\end
    );
    defer f.destroy();
    var initial = try f.snapshot();
    defer initial.deinit();
    try std.testing.expect((try node(initial, "choices/first")).selected);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_down } });
    var changed = try f.snapshot();
    defer changed.deinit();
    try std.testing.expectEqual(@as(?i64, 29), (try node(changed, "choices")).selected_value);
    try std.testing.expect(!(try node(changed, "choices/first")).selected);
    try std.testing.expect((try node(changed, "choices/second")).selected);
    // No Lua signal/callback rebuilt the old semantic descriptor.
    try std.testing.expect((try f.runtime.semantics.findPath("choices/first")).selected);
    var playback = try dev.Playback.init(&f.runtime, changed.token, .{ .click = "choices/first" });
    _ = try playback.advance(&f.runtime);
    try f.settle();
    _ = try playback.advance(&f.runtime);
    try f.settle();
    try std.testing.expect(f.runtime.router.captured != null);
    try playback.cancel(&f.runtime);
    try f.settle();
    try std.testing.expect(f.runtime.router.captured == null);
    try std.testing.expectEqual(.complete, try playback.advance(&f.runtime));
}

test "unstyled text editor ignores stock chrome and accepts explicit viewport paint" {
    const f = try Fixture.create(
        \\function build() return ouro.theme {key='theme', controls={height=61,radius=13,border_width=4},
        \\ widgets={text_input={height=73,padding_x=19,background='#ff0000',foreground='#00ff00'}},
        \\ ouro.column {key='root',gap=7,
        \\   ouro.text_editor {key='bare',default_text='Bare'},
        \\   ouro.text_editor {key='custom',text='',placeholder='Hint',height=53,padding_x=11,padding_y=7,
        \\     background='#123456',foreground='#234567',border='#345678',border_width=3,focus='#456789',radius=9,
        \\     placeholder_color='#56789a',selection_color='#6789ab',caret_color='#789abc'},
        \\   ouro.text_input {key='stock',text='Stock'}}} end
    );
    defer f.destroy();
    const bare = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("theme/root/bare")).id).?;
    const bare_render = try f.runtime.instances.renderObject(bare);
    const box = (try f.runtime.tree.objectAt(bare_render)).box;
    try std.testing.expect(box.background == null and box.border_color == null and box.height == null);
    try std.testing.expectEqual(@as(f32, 0), box.border_width);
    try std.testing.expectEqual(@as(f32, 0), box.corner_radius);
    try std.testing.expectEqual(@as(f32, 0), box.padding.left);
    try std.testing.expectEqual(@as(f32, 0), box.padding.top);
    try std.testing.expect((try f.runtime.semanticTarget("theme/root/bare")).bounds.height > 0);
    const bare_content = try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(bare));
    try std.testing.expectEqual(@import("../design/root.zig").tokens.light.foreground, (try f.runtime.tree.objectAt(bare_content)).text_input.color);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(bare, f.runtime.focus.current().?);
    try std.testing.expectEqual(box, (try f.runtime.tree.objectAt(bare_render)).box);
    const Color = @import("../core/color.zig").Color;
    const custom = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("theme/root/custom")).id).?;
    const custom_render = try f.runtime.instances.renderObject(custom);
    const custom_box = (try f.runtime.tree.objectAt(custom_render)).box;
    try std.testing.expectEqual(@as(?f32, 53), custom_box.height);
    try std.testing.expectEqual(@as(f32, 11), custom_box.padding.left);
    try std.testing.expectEqual(@as(f32, 7), custom_box.padding.top);
    try std.testing.expectEqual(Color.rgba(0x12, 0x34, 0x56, 255), custom_box.background.?);
    try std.testing.expectEqual(Color.rgba(0x34, 0x56, 0x78, 255), custom_box.border_color.?);
    const content = (try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(try f.runtime.text_inputs.content(custom)))).text_input;
    try std.testing.expectEqual(Color.rgba(0x56, 0x78, 0x9a, 255), content.placeholder_color);
    try std.testing.expectEqual(Color.rgba(0x67, 0x89, 0xab, 255), content.selection_color);
    try std.testing.expectEqual(Color.rgba(0x78, 0x9a, 0xbc, 255), content.caret_color);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectEqual(Color.rgba(0x45, 0x67, 0x89, 255), (try f.runtime.tree.objectAt(custom_render)).box.border_color.?);
    const stock = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("theme/root/stock")).id).?;
    const stock_box = (try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(stock))).box;
    try std.testing.expectEqual(@as(?f32, 73), stock_box.height);
    try std.testing.expectEqual(@as(f32, 19), stock_box.padding.left);
    try std.testing.expectEqual(@as(f32, 13), stock_box.corner_radius);
    try std.testing.expectEqual(@as(f32, 4), stock_box.border_width);
}

test "text editor and stock recipe retain the same native session across chrome changes" {
    const f = try Fixture.create(
        \\custom=ouro.signal(false); invalid=ouro.signal(false); changes={}
        \\function build()
        \\ local input=custom() and ouro.text_editor or ouro.text_input
        \\ return input {key='edit',default_text=custom() and 'must not reset' or 'aéZ',
        \\   height=43,padding_x=custom() and 13 or 7,foreground='#123456',
        \\   on_change=function(v) changes[#changes+1]=v end,
        \\   on_command=invalid() and 'not a callback' or function() end}
        \\end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    const target = f.runtime.focus.current().?;
    const generation = try f.runtime.text_inputs.sessionGeneration(target);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left, .modifiers = .{ .shift = true } } });
    try f.play(.{ .text = "Ω" });
    const session = try f.runtime.text_inputs.session(target);
    try std.testing.expectEqualStrings("aéΩ", session.model.text());
    _ = try session.apply(.{ .preedit = .{ .text = "候補", .cursor = null } });
    const selection = session.model.selection;
    const switch_source = "custom:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, switch_source.ptr, switch_source.len, "@editor-chrome", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try std.testing.expectEqual(generation, try f.runtime.text_inputs.sessionGeneration(target));
    try std.testing.expectEqualStrings("aéΩ", session.model.text());
    try std.testing.expectEqual(selection, session.model.selection);
    try std.testing.expectEqualStrings("候補", session.preedit().?.text);
    // Fail after staging a new session and on_change callback; preserve the live owner.
    const invalidate = "invalid:set(true)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, invalidate.ptr, invalidate.len, "@invalid-editor", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try std.testing.expectError(error.LuaBuildFailed, f.settle());
    try std.testing.expectEqual(@as(usize, 0), f.builder.pending_text_input_count);
    try std.testing.expectEqual(@as(usize, 0), f.builder.pending_handler_count);
    try std.testing.expectEqual(generation, try f.runtime.text_inputs.sessionGeneration(target));
    try std.testing.expectEqualStrings("候補", session.preedit().?.text);
    const restore = "invalid:set(false)";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, restore.ptr, restore.len, "@restore-editor", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
    try f.settle();
    _ = try session.apply(.{ .preedit = .{ .text = null, .cursor = null } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .key_z, .modifiers = .{ .control = true } } });
    try std.testing.expectEqualStrings("aéZ", session.model.text());
    const check = "assert(#changes==2 and changes[1]=='aéΩ' and changes[2]=='aéZ')";
    try std.testing.expectEqual(c.ok, c.luaL_loadbufferx(f.vm.state, check.ptr, check.len, "@check-editor", "t"));
    try std.testing.expectEqual(c.ok, c.lua_pcallk(f.vm.state, 0, 0, 0, 0, null));
}

test "development keyboard and text preserve asymmetric UTF-8 selection through real editing" {
    const f = try Fixture.create(
        \\function build()
        \\  return ouro.column {key='root', gap=11,
        \\    ouro.text_input {key='edit', label='Query', default_text='aéZ'},
        \\    ouro.text_input {key='locked', label='Locked', default_text='keep', read_only=true},
        \\  }
        \\end
    );
    defer f.destroy();
    try std.testing.expectError(error.DevelopmentTargetNotFocused, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "bad" }));
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .end } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .arrow_left, .modifiers = .{ .shift = true } } });
    var selected = try f.snapshot();
    defer selected.deinit();
    const edit = try node(selected, "root/edit");
    try std.testing.expect(edit.focused);
    try std.testing.expectEqualStrings("aéZ", edit.value.?);
    try std.testing.expectEqual(@as(usize, 4), edit.selection.?.anchor);
    try std.testing.expectEqual(@as(usize, 3), edit.selection.?.extent);
    // A native window can retain semantic focus without seat/IME ownership.
    try f.runtime.routeKeyboard(.{ .leave = .{ .window = f.runtime.window, .serial = 0 } });
    try f.settle();
    try std.testing.expect((try f.runtime.textInputStatus()) == null);
    try std.testing.expectError(error.DevelopmentTextContainsControl, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "a\nb" }));
    try f.play(.{ .text = "Ω!" });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .backspace } });
    var after = try f.snapshot();
    defer after.deinit();
    const changed = try node(after, "root/edit");
    try std.testing.expectEqualStrings("aéΩ", changed.value.?);
    try std.testing.expectEqual(@as(usize, 5), changed.selection.?.extent);
    try std.testing.expectEqualStrings("keep", (try node(after, "root/locked")).value.?);
    try std.testing.expectError(error.StaleDevelopmentTarget, dev.Playback.init(&f.runtime, selected.token, .{ .text = "stale" }));
    var canceled = try dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "λnot typed" });
    try std.testing.expectEqual(.routed, try canceled.advance(&f.runtime));
    try f.settle();
    try canceled.cancel(&f.runtime);
    try f.settle();
    try canceled.cancel(&f.runtime);
    try std.testing.expectEqual(.complete, try canceled.advance(&f.runtime));
    var partial = try f.snapshot();
    defer partial.deinit();
    try std.testing.expectEqualStrings("aéΩλ", (try node(partial, "root/edit")).value.?);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try std.testing.expectError(error.DevelopmentTargetReadOnly, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .text = "bad" }));
}

test "development scrolling, actual phase counts and full PNG replay after submission" {
    const f = try Fixture.create(
        \\function build()
        \\  return ouro.virtual_list {key='rows', item_count=20, item_height=40,
        \\    item_key=function(i) return 'item-' .. i end,
        \\    render_item=function(i) return ouro.box {key='box', height=40, background=i % 2 == 0 and '#d02010' or '#1030c0'} end,
        \\  }
        \\end
    );
    defer f.destroy();
    const metrics = f.runtime.metrics;
    try std.testing.expect(metrics.builds.count > 0 and metrics.layouts.count > 0 and metrics.paints.count > 0);
    try std.testing.expectEqual(metrics.builds.count, metrics.builds.timed_count);
    try f.runtime.prepareFrame(1);
    try std.testing.expectEqualDeep(metrics, f.runtime.metrics);
    try f.play(.{ .scroll = .{ .target = "rows", .delta = 73 } });
    var scrolled = try f.snapshot();
    defer scrolled.deinit();
    try std.testing.expectEqual(@as(f32, 73), (try node(scrolled, "rows")).scroll_offset.?);
    try f.play(.{ .scroll = .{ .target = "rows", .delta = -19 } });
    var back = try f.snapshot();
    defer back.deinit();
    try std.testing.expectEqual(@as(f32, 54), (try node(back, "rows")).scroll_offset.?);
    try std.testing.expectError(error.InvalidScrollDelta, dev.Playback.init(&f.runtime, back.token, .{ .scroll = .{ .target = "rows", .delta = std.math.nan(f32) } }));

    if (!@import("../renderer/software/root.zig").has_freetype) return error.SkipZigTest;
    const state = f.runtime.frame_state;
    const before_capture = f.runtime.metrics;
    var image = try dev.capture(std.testing.allocator, &f.runtime, back.token);
    defer image.deinit();
    var repeated = try dev.capture(std.testing.allocator, &f.runtime, back.token);
    defer repeated.deinit();
    try std.testing.expectEqual(.software_scene_replay, image.kind);
    try std.testing.expectEqualDeep(state, f.runtime.frame_state);
    try std.testing.expectEqualDeep(before_capture, f.runtime.metrics);
    try std.testing.expectEqualSlices(u8, image.png, repeated.png);
    var decoded = try @import("../image/codec.zig").decode(std.testing.allocator, image.png, .{});
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u32, 324), decoded.width);
    try std.testing.expectEqual(@as(u32, 224), decoded.height);
    // At offset 54, visible row 2 is red and row 3 is blue. Sample well
    // inside both, independent of the replay implementation.
    const red = (20 * 324 + 40) * 4;
    const blue = (60 * 324 + 40) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 0xd0, 0x20, 0x10, 0xff }, decoded.pixels[red..][0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x30, 0xc0, 0xff }, decoded.pixels[blue..][0..4]);
    try std.testing.expectError(error.StaleDevelopmentTarget, dev.capture(std.testing.allocator, &f.runtime, scrolled.token));
}

test "scrollbars capture transformed thumbs on both axes without relayout and publish copied metrics" {
    const source =
        \\calls=0; feedback=ouro.signal(0)
        \\function build()
        \\ feedback()
        \\ return ouro.box {key='frame',width=120,height=80,transform={x=20,y=5,scale=.75},
        \\  ouro.scroll {key='view',axis=horizontal and 'horizontal' or 'vertical',scrollbar=true,
        \\   on_scroll=function(m) calls=calls+1; latest=m; feedback:set(calls) end,
        \\   ouro.box {key='body',width=horizontal and 480 or 'fill',height=horizontal and 'fill' or 320,
        \\    background='#d02010'}}}
        \\end
    ;
    for ([_]bool{ false, true }) |horizontal| {
        const f = try Fixture.create(if (horizontal) "horizontal=true;" ++ source else source);
        defer f.destroy();
        try f.exec("assert(calls==1 and latest.offset==0); saved=latest; latest.offset=999");
        try f.settle();
        try f.exec("assert(calls==1)"); // Mutating the copied table cannot cause another notification.
        const id = (try f.runtime.semantics.findPath("frame/view")).id;
        const target = f.runtime.instances.handleForId(id).?;
        const render = try f.runtime.instances.renderObject(target);
        const transform = try f.runtime.tree.paintTransform(render);
        const root = (try f.runtime.instances.rootRenderObject()).?;
        const layouts = try f.runtime.tree.layoutCount(root);
        const child = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("frame/view/body")).id).?;
        const size = try f.runtime.tree.nodeSize(try f.runtime.instances.renderObject(child));
        try std.testing.expectEqual(@as(f32, if (horizontal) 68 else 108), if (horizontal) size.height else size.width);
        // Viewport/content=1/4. Horizontal thumb is 30, vertical is minimum 24.
        // Grab seven pixels into the thumb; move its leading edge to half travel.
        const start = transform.point(if (horizontal) .{ .x = 7, .y = 74 } else .{ .x = 114, .y = 7 });
        const half = transform.point(if (horizontal) .{ .x = 52, .y = 74 } else .{ .x = 114, .y = 35 });
        try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = start } });
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 1, .button = 272, .state = .pressed } });
        try f.settle();
        try std.testing.expectEqual(target, f.runtime.router.captured.?);
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = half } });
        try f.settle();
        try std.testing.expectEqual(@as(f32, if (horizontal) 180 else 120), try f.runtime.instances.scrollOffset(target));
        try f.exec(if (horizontal) "assert(calls==2 and latest.axis=='horizontal' and latest.offset==180 and latest.max_offset==360)" else "assert(calls==2 and latest.axis=='vertical' and latest.offset==120 and latest.max_offset==240)");
        // Capture remains active outside both the viewport and window.
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 3, .position = .{ .x = 1000, .y = 1000 } } });
        try f.settle();
        try std.testing.expectEqual(@as(f32, if (horizontal) 360 else 240), try f.runtime.instances.scrollOffset(target));
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 4, .button = 272, .state = .released } });
        try f.settle();
        try std.testing.expect(f.runtime.scrollbar_drag == null and f.runtime.router.captured == null);
        // Clicking above the thumb pages this viewport rather than activating content.
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 5, .position = start } });
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 6, .button = 272, .state = .pressed } });
        try f.settle();
        try std.testing.expectEqual(@as(f32, if (horizontal) 240 else 160), try f.runtime.instances.scrollOffset(target));
        try std.testing.expect(f.runtime.scrollbar_drag == null);
        try std.testing.expectEqual(layouts, try f.runtime.tree.layoutCount(root));
        try f.exec("assert(calls==4 and saved.offset==999)");
        // A press and compositor leave may both arrive before the task safe
        // point. The queued press must not re-arm a drag after pointer leave.
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 7, .button = 272, .state = .released } });
        try f.settle();
        const thumb_point = transform.point(if (horizontal) .{ .x = 70, .y = 74 } else .{ .x = 114, .y = 50 });
        try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 8, .position = thumb_point } });
        try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 9, .button = 272, .state = .pressed } });
        try f.runtime.routePointer(.{ .leave = .{ .window = f.runtime.window, .serial = 2 } });
        try f.settle();
        try std.testing.expect(f.runtime.scrollbar_drag == null);
    }
}

test "scroll requests are tokened clamped and transactional and callbacks survive replacement" {
    const f = try Fixture.create(
        \\request=ouro.signal({offset=155,token=1}); extent=ouro.signal(400); bar=ouro.signal(true)
        \\watch=ouro.signal(true); calls=0
        \\function build() return ouro.box {key='frame',width=120,height=80,
        \\ ouro.scroll {key='view',scrollbar=bar(),scroll_to=request(),
        \\ on_scroll=watch() and function(m) calls=calls+1; latest=m end or nil,
        \\ ouro.box {key='body',height=extent(),width='fill'}}} end
    );
    defer f.destroy();
    const id = (try f.runtime.semantics.findPath("frame/view")).id;
    const target = f.runtime.instances.handleForId(id).?;
    try f.exec("assert(calls==1 and latest.offset==155 and latest.content==400 and latest.viewport==80)");
    try f.play(.{ .scroll = .{ .target = "frame/view", .delta = 23 } });
    try f.exec("assert(calls==2 and latest.offset==178); request:set({offset=0,token=1})");
    try f.settle();
    try std.testing.expectEqual(@as(f32, 178), try f.runtime.instances.scrollOffset(target));
    try f.exec("assert(calls==2); request:set({offset=9999,token=2})");
    try f.settle();
    try f.exec("assert(calls==3 and latest.offset==320); extent:set(110)");
    try f.settle();
    try f.exec("assert(calls==4 and latest.offset==30 and latest.max_offset==30); watch:set(false)");
    try f.settle();
    try f.exec("watch:set(true)");
    try f.settle();
    try f.exec("assert(calls==5)");
    const invalid = [_][]const u8{
        "request:set({offset=-1,token=3})",           "request:set({offset=0/0,token=3})",
        "request:set({offset=1/0,token=3})",          "request:set({offset=0,token=0})",
        "request:set({offset=0,token=1.5})",          "request:set({offset='2',token=3})",
        "request:set({offset=2,token=3,extra=true})", "bar:set(1)",
    };
    for (invalid) |mutation| {
        try f.exec(mutation);
        try std.testing.expectError(error.LuaBuildFailed, f.settle());
        try std.testing.expectEqual(target, f.runtime.instances.handleForId(id).?);
        try std.testing.expectEqual(@as(f32, 30), try f.runtime.instances.scrollOffset(target));
        try f.exec("request:set({offset=9999,token=2}); bar:set(true)");
        try f.settle();
    }
    try f.exec("assert(calls==5); request:set({offset=11,token=3})");
    try f.settle();
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    const metrics = (try node(snapshot, "frame/view")).scroll_metrics.?;
    try std.testing.expectEqual(@as(f32, 11), metrics.offset);
    try std.testing.expectEqual(@as(f32, 110), metrics.content);
    try f.exec("assert(calls==6 and latest.offset==11)");
}

test "virtual scrollbars share metrics and token requests while keeping distant rows bounded" {
    const f = try Fixture.create(
        \\request=ouro.signal({offset=200003,token=1}); count=ouro.signal(10000); calls=0; renders=0
        \\function build() return ouro.virtual_list {key='rows',scrollbar=true,scroll_to=request(),
        \\ item_count=count(),item_height=40,item_key=function(i) return 'item-'..i end,
        \\ on_scroll=function(m) calls=calls+1; latest=m end,
        \\ render_item=function(i) renders=renders+1; return ouro.box {key='body',height=40,width='fill'} end} end
    );
    defer f.destroy();
    try f.exec("assert(calls==1 and latest.offset==200003 and latest.viewport==200 and latest.content==400000 and renders<100)");
    const list = f.runtime.virtual_lists.lists[0];
    try std.testing.expectEqual(@as(f32, 288), list.width);
    try std.testing.expect(f.runtime.virtual_lists.row_count < 20);
    _ = try f.runtime.semantics.findPath("rows/item-5001/body");
    try f.play(.{ .scroll = .{ .target = "rows", .delta = 57 } });
    try f.exec("assert(calls==2 and latest.offset==200060); request:set({offset=1,token=1})");
    try f.settle();
    try f.exec("assert(calls==2 and latest.offset==200060); request:set({offset=403,token=2})");
    try f.settle();
    _ = try f.runtime.semantics.findPath("rows/item-11/body");
    try f.exec("assert(calls==3 and latest.offset==403); count:set(4)");
    try f.settle();
    try f.exec("assert(calls==4 and latest.offset==0 and latest.max_offset==0 and latest.content==160)");
    try f.exec("count:set(10000)");
    try f.settle();
    // Grabbing the virtual thumb focuses the viewport; recycling rows must
    // preserve capture until release and retain keyboard navigation afterward.
    const target = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("rows")).id).?;
    try f.runtime.routePointer(.{ .enter = .{ .window = f.runtime.window, .serial = 1, .position = .{ .x = 306, .y = 19 } } });
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 1, .button = 272, .state = .pressed } });
    try f.settle();
    try std.testing.expectEqual(target, f.runtime.focus.current().?);
    try f.runtime.routePointer(.{ .motion = .{ .window = f.runtime.window, .time_ms = 2, .position = .{ .x = 306, .y = 1000 } } });
    try f.settle();
    try std.testing.expectEqual(target, f.runtime.router.captured.?);
    try std.testing.expectEqual(@as(f32, 399800), try f.runtime.instances.scrollOffset(target));
    _ = try f.runtime.semantics.findPath("rows/item-10000/body");
    try f.runtime.routePointer(.{ .button = .{ .window = f.runtime.window, .serial = 1, .time_ms = 3, .button = 272, .state = .released } });
    try f.settle();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .home } });
    try std.testing.expectEqual(@as(f32, 0), try f.runtime.instances.scrollOffset(target));
    try std.testing.expect(f.runtime.scrollbar_drag == null and f.runtime.router.captured == null);
}

test "animated controls retain identity reverse in flight and honor reduced motion" {
    const f = try Fixture.create(
        \\checked=ouro.signal(false); reduced=ouro.signal(false); active=ouro.signal(true)
        \\function build() return ouro.theme {key='policy',reduced_motion=reduced(),
        \\ ouro.column {key='root',gap=8,
        \\ ouro.switch {key='switch',label='Sync',checked=checked(),duration=100,enabled=active(),on_change=function(v) checked:set(v) end},
        \\ ouro.checkbox {key='check',label='Save',checked=checked(),duration=100,on_change=function(v) checked:set(v) end}}} end
    );
    defer f.destroy();
    const path = "policy/root/switch";
    const id = (try f.runtime.semantics.findPath(path)).id;
    const handle = f.runtime.instances.handleForId(id).?;
    const root = (try f.runtime.instances.rootRenderObject()).?;
    const track = f.runtime.tree.firstChild(try f.runtime.instances.renderObject(handle)).?;
    const thumb = f.runtime.tree.firstChild(track).?;
    const check_handle = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("policy/root/check")).id).?;
    const check_track = f.runtime.tree.firstChild(try f.runtime.instances.renderObject(check_handle)).?;
    const mark = f.runtime.tree.firstChild(check_track).?;
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(0);
    const layouts = try f.runtime.tree.layoutCount(root);
    try f.play(.{ .click = path });
    try std.testing.expect((try f.runtime.semantics.findPath(path)).checked);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(thumb)).box.transform.translation.x);
    try f.runtime.advanceAnimations(50 * std.time.ns_per_ms);
    try f.settle();
    // ease_out(1/2) = 3/4; the switch travels 15px and the check fades in.
    try std.testing.expectEqual(@as(f32, 11.25), (try f.runtime.tree.objectAt(thumb)).box.transform.translation.x);
    try std.testing.expectEqual(@as(f32, 0.75), (try f.runtime.tree.objectAt(mark)).box.opacity);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expect(!(try f.runtime.semantics.findPath(path)).checked);
    try std.testing.expectEqual(@as(f32, 11.25), (try f.runtime.tree.objectAt(thumb)).box.transform.translation.x);
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(f32, 2.8125), (try f.runtime.tree.objectAt(thumb)).box.transform.translation.x);
    try std.testing.expectEqual(layouts, try f.runtime.tree.layoutCount(root));
    try f.exec("reduced:set(true);checked:set(true)");
    try f.settle();
    try std.testing.expectEqual(@as(f32, 15), (try f.runtime.tree.objectAt(thumb)).box.transform.translation.x);
    try std.testing.expectEqual(@as(f32, 1), (try f.runtime.tree.objectAt(mark)).box.opacity);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try std.testing.expectEqual(handle, f.runtime.instances.handleForId(id).?);
    try f.exec("active:set(false)");
    try f.settle();
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = path }));
    try f.exec("reduced:set(false)");
    try f.settle();
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "collapsible reveals natural height and preserves state during reversals" {
    const f = try Fixture.create(
        \\opened=ouro.signal(false); reduced=ouro.signal(false); hits=0
        \\function build() return ouro.theme {key='policy',reduced_motion=reduced(),
        \\ ouro.column {key='root',cross_alignment='stretch',
        \\ ouro.collapsible {key='details',label='Details',expanded=opened(),duration=100,
        \\ on_change=function(v) opened:set(v) end,
        \\ ouro.button {key='action',label='Action',height=32,on_press=function() hits=hits+1 end}},
        \\ ouro.text {key='tail',text='After'}}} end
    );
    defer f.destroy();
    const trigger = "policy/root/details/trigger";
    const reveal = "policy/root/details/presence/reveal";
    const child = "policy/root/details/presence/reveal/content/action";
    try std.testing.expectEqual(@as(?bool, false), (try f.runtime.semantics.findPath(trigger)).expanded);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try f.runtime.advanceAnimations(0);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try std.testing.expectEqual(@as(?bool, true), (try f.runtime.semantics.findPath(trigger)).expanded);
    const id = (try f.runtime.semantics.findPath(child)).id;
    const handle = f.runtime.instances.handleForId(id).?;
    const rendered = try f.runtime.instances.renderObject(handle);
    try std.testing.expectEqual(@as(f32, 32), (try f.runtime.tree.nodeSize(rendered)).height);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.semanticTarget(reveal)).bounds.height);
    try f.runtime.advanceAnimations(50 * std.time.ns_per_ms);
    try f.settle();
    // 32px content + 12px bottom padding, revealed at ease_out(1/2)=3/4.
    try std.testing.expectEqual(@as(f32, 33), (try f.runtime.semanticTarget(reveal)).bounds.height);
    try std.testing.expectEqual(@as(f32, 32), (try f.runtime.tree.nodeSize(rendered)).height);
    const child_layouts = try f.runtime.tree.layoutCount(rendered);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try std.testing.expectEqual(@as(?bool, false), (try f.runtime.semantics.findPath(trigger)).expanded);
    try std.testing.expect(!f.runtime.instances.isInteractive(handle));
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = child }));
    try f.runtime.advanceAnimations(75 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(f32, 18.5625), (try f.runtime.semanticTarget(reveal)).bounds.height);
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try std.testing.expectEqual(handle, f.runtime.instances.handleForId(id).?);
    try std.testing.expect(f.runtime.instances.isInteractive(handle));
    try std.testing.expectEqual(@as(f32, 18.5625), (try f.runtime.semanticTarget(reveal)).bounds.height);
    try f.runtime.advanceAnimations(175 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(f32, 44), (try f.runtime.semanticTarget(reveal)).bounds.height);
    try std.testing.expectEqual(child_layouts, try f.runtime.tree.layoutCount(rendered));
    try f.play(.{ .click = child });
    try f.exec("assert(hits==1);reduced:set(true);opened:set(false)");
    try f.settle();
    try std.testing.expect(f.runtime.instances.handleForId(id) == null);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try f.exec("opened:set(true)");
    try f.settle();
    try std.testing.expectEqual(@as(f32, 44), (try f.runtime.semanticTarget(reveal)).bounds.height);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "collapsible reversals preserve the editor session and draft until removal" {
    const f = try Fixture.create(
        \\opened=ouro.signal(true)
        \\function build() return ouro.column {key='root',
        \\ ouro.collapsible {key='details',label='Details',expanded=opened(),duration=100,
        \\ on_change=function(v) opened:set(v) end,
        \\ ouro.text_input {key='editor',label='Name',default_text='draft'}}} end
    );
    defer f.destroy();
    try f.runtime.advanceAnimations(0);
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    const path = "root/details/presence/reveal/content/editor";
    const id = (try f.runtime.semantics.findPath(path)).id;
    const handle = f.runtime.instances.handleForId(id).?;
    const session = try f.runtime.text_inputs.session(handle);
    _ = try session.apply(.{ .commit = .{ .text = "edited " } });
    const expected = try std.testing.allocator.dupe(u8, session.model.text());
    defer std.testing.allocator.free(expected);
    try f.exec("opened:set(false)");
    try f.settle();
    try f.runtime.advanceAnimations(125 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expect(!f.runtime.instances.isInteractive(handle));
    try f.exec("opened:set(true)");
    try f.settle();
    try f.runtime.advanceAnimations(225 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(handle, f.runtime.instances.handleForId(id).?);
    try std.testing.expectEqual(session, try f.runtime.text_inputs.session(handle));
    try std.testing.expectEqualStrings(expected, session.model.text());
    try f.exec("opened:set(false)");
    try f.settle();
    try f.runtime.advanceAnimations(325 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expect(f.runtime.instances.handleForId(id) == null);
    try std.testing.expect(!f.runtime.text_inputs.contains(handle));
}

test "accordion controls a single expanded key and skips disabled triggers" {
    const f = try Fixture.create(
        \\selection=ouro.signal(nil)
        \\function build() return ouro.accordion {key='faq',motion='reduce',expanded=selection(),
        \\ on_change=function(v) selection:set(v) end,items={
        \\ {key='one',label='First',content=ouro.text {key='body',text='One'}},
        \\ {key='two',label='Second',content=ouro.text {key='body',text='Two'}},
        \\ {key='locked',label='Locked',enabled=false,content=ouro.text {key='body',text='Locked'}}}} end
    );
    defer f.destroy();
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try f.exec("assert(selection()=='one')");
    try f.play(.{ .key = .{ .keycode = 0, .logical = .tab } });
    try f.play(.{ .key = .{ .keycode = 0, .logical = .enter } });
    try f.exec("assert(selection()=='two')");
    var snapshot = try f.snapshot();
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(?bool, false), (try node(snapshot, "faq/item-one/trigger")).expanded);
    try std.testing.expectEqual(@as(?bool, true), (try node(snapshot, "faq/item-two/trigger")).expanded);
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "faq/item-locked/trigger" }));
    try f.play(.{ .key = .{ .keycode = 0, .logical = .space } });
    try f.exec("assert(selection()==nil)");
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "menu entry samples opacity and scale and inherits the opener motion policy" {
    const f = try Fixture.create(
        \\opened=ouro.signal(false); reduced=ouro.signal(false); payload=nil
        \\ouro.popup=function(p) assert(p.transparent); payload=p.content; opened:set(true)
        \\ return {close=function() opened:set(false) end} end
        \\function build() return ouro.theme {key='policy',reduced_motion=reduced(),
        \\ ouro.column {key='root',
        \\ ouro.menu_button {key='menu',label='Menu',duration=100,popup_width=120,popup_height=90,
        \\ content=function(close) return ouro.button {key='item',label='Done',on_press=close} end},
        \\ opened() and payload() or nil}} end
    );
    defer f.destroy();
    try f.runtime.advanceAnimations(0);
    try f.play(.{ .click = "policy/root/menu/trigger" });
    const surface = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("policy/root/motion/surface")).id).?;
    const render = try f.runtime.instances.renderObject(surface);
    try std.testing.expectEqual(@as(f32, 0), (try f.runtime.tree.objectAt(render)).box.opacity);
    try f.runtime.advanceAnimations(25 * std.time.ns_per_ms);
    try f.settle();
    const box = (try f.runtime.tree.objectAt(render)).box;
    try std.testing.expectEqual(@as(f32, 0.4375), box.opacity);
    try std.testing.expectApproxEqAbs(@as(f32, 0.98875), box.transform.scale, 0.00001);
    try std.testing.expectEqual(@as(f32, 120), box.transform.origin.x);
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectEqual(@as(f32, 1), (try f.runtime.tree.objectAt(render)).box.opacity);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try f.play(.{ .click = "policy/root/motion/surface/theme/item" });
    try f.exec("assert(not opened()); reduced:set(true)");
    try f.settle();
    try f.play(.{ .click = "policy/root/menu/trigger" });
    const reduced_surface = f.runtime.instances.handleForId((try f.runtime.semantics.findPath("policy/root/motion/surface")).id).?;
    try std.testing.expectEqual(@as(f32, 1), (try f.runtime.tree.objectAt(try f.runtime.instances.renderObject(reduced_surface))).box.opacity);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "toast exit closes stack space continuously and reversal and reduced motion settle" {
    const f = try Fixture.create(
        \\shown=ouro.signal(true); reduced=ouro.signal(false); calls=0
        \\function build() return ouro.theme {key='policy',reduced_motion=reduced(),
        \\ ouro.column {key='stack',gap=0,cross_alignment='stretch',
        \\ ouro.toast {key='first',present=shown(),message='Saved',timeout=0,duration=100,
        \\ on_dismiss=function(reason) assert(reason=='manual'); calls=calls+1; shown:set(false) end},
        \\ ouro.toast {key='second',present=true,message='Ready',timeout=0,duration=100,on_dismiss=function() end}}} end
    );
    defer f.destroy();
    try f.runtime.advanceAnimations(0);
    try f.runtime.advanceAnimations(100 * std.time.ns_per_ms);
    try f.settle();
    const first = try f.runtime.semanticTarget("policy/stack/first/reveal");
    const second = try f.runtime.semanticTarget("policy/stack/second/reveal");
    try f.play(.{ .click = "policy/stack/first/reveal/spacing/live-0/card/row/dismiss" });
    try f.exec("assert(calls==1)");
    try std.testing.expectError(error.DevelopmentTargetDisabled, dev.Playback.init(&f.runtime, dev.Token.current(&f.runtime), .{ .click = "policy/stack/first/reveal/spacing/card/row/dismiss" }));
    try f.runtime.advanceAnimations(150 * std.time.ns_per_ms);
    try f.settle();
    try std.testing.expectApproxEqAbs(first.bounds.height * 0.25, (try f.runtime.semanticTarget("policy/stack/first/reveal")).bounds.height, 0.001);
    try std.testing.expectApproxEqAbs(second.bounds.y - first.bounds.height * 0.75, (try f.runtime.semanticTarget("policy/stack/second/reveal")).bounds.y, 0.001);
    try f.exec("shown:set(true)");
    try f.settle();
    try std.testing.expectApproxEqAbs(first.bounds.height * 0.25, (try f.runtime.semanticTarget("policy/stack/first/reveal")).bounds.height, 0.001);
    try f.exec("reduced:set(true)");
    try f.settle();
    try std.testing.expectEqual(first.bounds.height, (try f.runtime.semanticTarget("policy/stack/first/reveal")).bounds.height);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
    try f.exec("shown:set(false)");
    try f.settle();
    try std.testing.expectEqual(first.bounds.y, (try f.runtime.semanticTarget("policy/stack/second/reveal")).bounds.y);
    try std.testing.expectEqual(null, try f.runtime.animationDelay());
}

test "menu and toast declarations validate before opening or showing" {
    for ([_][]const u8{
        "ouro.menu_button {key='m',label='Menu'}",
        "ouro.menu_button {key='m',label='Menu',popup_width=0,content=function() end}",
        "ouro.menu_button {key='m',label='Menu',motion='sometimes',content=function() end}",
        "ouro.toast {key='t',present=false,message='M',timeout=false,on_dismiss=function() end}",
        "ouro.toast {key='t',present=false,message='M',timeout=-1,on_dismiss=function() end}",
        "ouro.toast {key='t',present=false,message='M',timeout=1.5,on_dismiss=function() end}",
        "ouro.toast {key='t',present=false,message='M'}",
        "ouro.toast {key='t',present=1,message='M',on_dismiss=function() end}",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
    }
}

test "tooltip declarations reject invalid trigger timing placement and dimensions" {
    for ([_][]const u8{
        "ouro.tooltip {key='t',text='Tip'}",
        "ouro.tooltip {key='t',text='',ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',ouro.box{key='one'},ouro.box{key='two'}}",
        "ouro.tooltip {key='t',text='Tip',delay=-1,ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',delay=false,ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',width=0,ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',height=1.5,ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',gap=1025,ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',side='above',ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',enabled=0,ouro.box{key='child'}}",
        "ouro.tooltip {key='t',text='Tip',motion='sometimes',ouro.box{key='child'}}",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
    }
}

test "animated component declarations reject invalid motion disclosure and factor inputs" {
    for ([_][]const u8{
        "ouro.switch {key='s',label='Switch',checked=true,motion='sometimes'}",
        "ouro.checkbox {key='s',label='Check',checked=true,duration=0/0}",
        "ouro.collapsible {key='c',label='Details',expanded='yes',on_change=function() end,ouro.text {key='t',text='Text'}}",
        "ouro.collapsible {key='c',label='Details',expanded=false,ouro.text {key='t',text='Text'}}",
        "ouro.collapsible {key='c',label='Details',expanded=false,on_change=function() end}",
        "ouro.accordion {key='a',expanded='missing',on_change=function() end,items={{key='x',label='X',content=ouro.text {key='t',text='Text'}}}}",
        "ouro.accordion {key='a',on_change=function() end,items={{key='x',label='X',content=ouro.box {key='t'}},{key='x',label='Again',content=ouro.box {key='t'}}}}",
        "ouro.box {key='b',height_factor='0.5'}",
        "ouro.box {key='b',height_factor=0/0}",
        "ouro.box {key='b',height_factor=1.1}",
        "ouro.box {key='b',height_factor=0.5,height='fill'}",
        "ouro.box {key='b',height_factor=0.5,height=20}",
        "ouro.box {key='b',expanded=true}",
        "ouro.box {key='b',activate=true,role='button',label='B',expanded='yes'}",
    }) |declaration| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function build() return {s} end", .{declaration});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.LuaBuildFailed, Fixture.create(source));
    }
}
