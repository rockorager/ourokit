pub const hb = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ot.h");
});

pub const sb = @cImport({
    @cInclude("SheenBidi/SheenBidi.h");
});
