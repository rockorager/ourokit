/// Platform-neutral editing operations. Platform keymaps, command bindings,
/// and future accessibility actions translate into these intents rather than
/// mutating an editable model directly.
pub const Intent = union(enum) {
    select_all,
    select_word_inner,
    select_word_around,
    select_vim_word_inner,
    select_vim_word_around,
    select_vim_word_forward,
    select_vim_change_word,
    select_line,
    select_lines: LineDestination,
    select_paragraph_inner,
    select_paragraph_around,
    collapse_selection,
    collapse_selection_start,
    undo,
    redo,
    insert_newline,
    insert_line_above,
    insert_line_below,
    delete_line,
    delete_lines,
    clear_lines,
    delete_selection,
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

pub const LineDestination = enum { up, down, start, end, paragraph_previous, paragraph_next };

pub const Destination = enum {
    visual_left,
    visual_right,
    word_previous,
    word_next,
    vim_word_start_next,
    vim_word_start_previous,
    vim_word_end_next,
    line_up,
    line_down,
    line_start,
    line_end,
    logical_line_start,
    logical_line_end,
    paragraph_previous,
    paragraph_next,
    document_start,
    document_end,
};
