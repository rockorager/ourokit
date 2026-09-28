//! Opaque, generation-owned authentication capability. No credential bytes,
//! lengths, Lua values, text editor state or IME state enter the UI tree.
pub const Command = enum { insert, backspace, delete, left, right, home, end, clear, select_all, submit, cancel };
pub const Result = enum { ok, stale, full };
pub const Input = struct {
    context: *anyopaque,
    job: u64,
    prompt: u64,
    dispatch: *const fn (*anyopaque, u64, u64, Command, u32) Result,

    pub fn act(self: Input, command: Command, unicode: u32) Result {
        return self.dispatch(self.context, self.job, self.prompt, command, unicode);
    }
    pub fn clear(self: Input) void {
        _ = self.act(.clear, 0);
    }
};

// Constant display intentionally reveals neither byte nor character count.
pub const mask = "••••••••";
