pub const Loop = @import("io_uring.zig").Loop;
pub const OperationHandle = @import("io_uring.zig").OperationHandle;
pub const Completion = @import("io_uring.zig").Completion;
pub const Dispatch = @import("io_uring.zig").Dispatch;
pub const TimerHandle = @import("timer_heap.zig").TimerHandle;
pub const TimerHeap = @import("timer_heap.zig").TimerHeap;

test {
    _ = @import("io_uring.zig");
    _ = @import("timer_heap.zig");
}
