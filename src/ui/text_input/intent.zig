/// Platform-neutral editing operations. Platform keymaps, command bindings,
/// and future accessibility actions translate into these intents rather than
/// mutating an editable model directly.
pub const Intent = union(enum) {
    select_all,
    collapse_selection,
    undo,
    redo,
    insert_newline,
    insert_line_above,
    insert_line_below,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    move: Move,
};

pub const Move = struct {
    destination: Destination,
    extend: bool = false,
};

pub const Destination = enum {
    visual_left,
    visual_right,
    word_previous,
    word_next,
    line_up,
    line_down,
    line_start,
    line_end,
    logical_line_start,
    logical_line_end,
    document_start,
    document_end,
};
