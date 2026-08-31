//! Renderer-neutral paragraph presentation policy.

pub const Alignment = enum {
    /// Align to the paragraph direction's leading edge.
    start,
    /// Align to the paragraph direction's trailing edge.
    end,
    center,
    /// Expand eligible inter-word spaces on non-final soft-wrapped lines.
    justify,
};

pub const Overflow = enum {
    clip,
    /// Replace omitted text at a legal line-break boundary with a shaped U+2026.
    ellipsis,
};

pub const Style = struct {
    alignment: Alignment = .start,
    /// Null means unlimited. A value, when present, is always greater than zero.
    max_lines: ?u32 = null,
    overflow: Overflow = .clip,
};
