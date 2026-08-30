pub const Scheduler = @import("scheduler.zig").Scheduler;
pub const ScopeHandle = @import("scheduler.zig").ScopeHandle;
pub const TaskHandle = @import("scheduler.zig").TaskHandle;
pub const ResourceHandle = @import("scheduler.zig").ResourceHandle;
pub const ResourceKind = @import("scheduler.zig").ResourceKind;
pub const ResourceLifecycle = @import("scheduler.zig").ResourceLifecycle;

test {
    _ = @import("scheduler.zig");
}
