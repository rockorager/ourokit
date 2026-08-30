//! Public text module boundary.

const api = @import("api.zig");
const shape_cache = @import("shape_cache.zig");

pub const has_fontconfig = api.has_fontconfig;
pub const discovery = api.discovery;
pub const Direction = api.Direction;
pub const Script = api.Script;
pub const Glyph = api.Glyph;
pub const Metrics = api.Metrics;
pub const ShapedRun = api.ShapedRun;
pub const RunSpec = api.RunSpec;
pub const Font = api.Font;
pub const Grapheme = api.Grapheme;
pub const FontHandle = api.FontHandle;
pub const FontCache = api.FontCache;
pub const FallbackCandidate = api.FallbackCandidate;
pub const ShapedSpan = api.ShapedSpan;
pub const FallbackResult = api.FallbackResult;
pub const graphemes = api.graphemes;
pub const supportsSimpleLabel = api.supportsSimpleLabel;
pub const shapeWithFallback = api.shapeWithFallback;
pub const ShapeHandle = shape_cache.ShapeHandle;
pub const ShapeCache = shape_cache.ShapeCache;

test {
    _ = api;
    _ = shape_cache;
}
