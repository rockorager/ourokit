//! Native destination for a masked field bound to an authentication prompt.
//! Only the runtime calls `respond`, with bytes read from the field's locked
//! buffer on submit; Lua never receives them.
pub const Secret = struct {
    context: *anyopaque,
    job: u64,
    prompt: u64,
    respond_fn: *const fn (*anyopaque, u64, u64, []const u8) bool,

    /// Sends one response. False for a stale prompt or a closed conversation.
    pub fn respond(self: Secret, bytes: []const u8) bool {
        return self.respond_fn(self.context, self.job, self.prompt, bytes);
    }

    pub fn eql(a: Secret, b: Secret) bool {
        return a.context == b.context and a.job == b.job and a.prompt == b.prompt;
    }
};
