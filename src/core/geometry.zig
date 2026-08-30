pub const SizeU = struct {
    width: u32,
    height: u32,
};

/// Integer device-pixel rectangle. Negative origins are valid and clipped by
/// raster backends; width and height are always non-negative.
pub const RectI = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};
