//! Private C ABI, version 2. No font discovery, file IO or network resources.
//! The caller owns the encoded input during parsing and the RGBA output buffer.
//! Version 2 adds bounded native path rasterization into caller-owned A8 output.
use resvg::{tiny_skia, usvg};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ourokit_svg_open(
    data: *const u8,
    len: usize,
    width: *mut f32,
    height: *mut f32,
) -> *mut usvg::Tree {
    let mut options = usvg::Options::default();
    // Both overrides are necessary: the defaults can read local files and
    // recursively decode embedded SVG/raster images. Text features are disabled.
    options.image_href_resolver = usvg::ImageHrefResolver {
        resolve_data: Box::new(|_, _, _| None),
        resolve_string: Box::new(|_, _| None),
    };
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    let Ok(tree) = usvg::Tree::from_data(bytes, &options) else {
        return std::ptr::null_mut();
    };
    unsafe {
        *width = tree.size().width();
        *height = tree.size().height();
    }
    Box::into_raw(Box::new(tree))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ourokit_svg_close(tree: *mut usvg::Tree) {
    drop(unsafe { Box::from_raw(tree) });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ourokit_svg_render(
    tree: *const usvg::Tree,
    data: *mut u8,
    len: usize,
    width: u32,
    height: u32,
    scale: f32,
) -> bool {
    let tree = unsafe { &*tree };
    let bytes = unsafe { std::slice::from_raw_parts_mut(data, len) };
    let Some(mut pixmap) = tiny_skia::PixmapMut::from_bytes(bytes, width, height) else {
        return false;
    };
    pixmap.fill(tiny_skia::Color::TRANSPARENT);
    // Zig sized the raster as ceil(viewport * scale), not an arbitrary box.
    // usvg already applied the document's own preserveAspectRatio transform.
    let transform = tiny_skia::Transform::from_scale(scale, scale);
    resvg::render(tree, transform, &mut pixmap);
    true
}

// Private native path ABI. Zig validates/copies immutable logical commands and
// translates them into bounded, mask-local device coordinates before this call.
// Keep these repr(C) records in sync with src/path/root.zig; no Rust enum crosses
// the boundary. No colors or compositing policy belong in this bridge.
#[repr(C)]
pub struct PathCommand {
    tag: u32,
    points: [f32; 6],
}

#[repr(C)]
pub struct PathStyle {
    kind: u32, // 0: nonzero fill, 1: even-odd fill, 2: stroke
    cap: u32,  // butt, round, square
    join: u32, // miter, round, bevel
    width: f32,
    miter_limit: f32,
}

// 0: success (including empty painting), 1: invalid input/rasterization failure,
// 2: recoverable mask-buffer OOM. tiny-skia's internal allocations, like resvg's,
// use Rust's process-abort OOM policy. Release builds also abort on panic; the
// catch prevents unwinding across C in builds which enable panic unwinding.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ourokit_path_mask(
    commands: *const PathCommand,
    count: usize,
    style: *const PathStyle,
    data: *mut u8,
    len: usize,
    width: u32,
    height: u32,
) -> u32 {
    if commands.is_null() || style.is_null() || data.is_null() {
        return 1;
    }
    if width == 0 || height == 0 || width > 8192 || height > 8192 {
        return 1;
    }
    let Some(expected) = (width as usize).checked_mul(height as usize) else {
        return 1;
    };
    if len != expected || len > 16 * 1024 * 1024 || count > 8192 {
        return 1;
    }
    std::panic::catch_unwind(|| {
        let commands = unsafe { std::slice::from_raw_parts(commands, count) };
        let style = unsafe { &*style };
        let output = unsafe { std::slice::from_raw_parts_mut(data, len) };
        path_mask(commands, style, output, width, height)
    })
    .unwrap_or(1)
}

fn path_mask(
    commands: &[PathCommand],
    style: &PathStyle,
    output: &mut [u8],
    width: u32,
    height: u32,
) -> u32 {
    if style.kind > 2 || style.cap > 2 || style.join > 2 {
        return 1;
    }
    if style.kind == 2
        && (!style.width.is_finite()
            || style.width < 0.0
            || style.width > 8192.0
            || !style.miter_limit.is_finite()
            || style.miter_limit < 1.0)
    {
        return 1;
    }
    let mut builder = tiny_skia::PathBuilder::new();
    let mut active = false;
    for command in commands {
        // The native hull and raster dimension checks imply this tighter bound;
        // recheck it here before arithmetic in the rasterizer or stroker.
        if command
            .points
            .iter()
            .any(|p| !p.is_finite() || p.abs() > 16384.0)
        {
            return 1;
        }
        let p = command.points;
        match command.tag {
            0 => {
                builder.move_to(p[0], p[1]);
                active = true;
            }
            1 if active => builder.line_to(p[0], p[1]),
            2 if active => builder.quad_to(p[0], p[1], p[2], p[3]),
            3 if active => builder.cubic_to(p[0], p[1], p[2], p[3], p[4], p[5]),
            4 if active => {
                builder.close();
                active = false;
            }
            _ => return 1,
        }
    }
    output.fill(0);
    let Some(mut path) = builder.finish() else {
        return 0;
    };
    if style.kind == 2 {
        // Tiny positive logical widths can underflow after device scaling.
        if style.width == 0.0 {
            return 0;
        }
        let stroke = tiny_skia::Stroke {
            width: style.width,
            miter_limit: style.miter_limit,
            line_cap: match style.cap {
                1 => tiny_skia::LineCap::Round,
                2 => tiny_skia::LineCap::Square,
                _ => tiny_skia::LineCap::Butt,
            },
            line_join: match style.join {
                1 => tiny_skia::LineJoin::Round,
                2 => tiny_skia::LineJoin::Bevel,
                _ => tiny_skia::LineJoin::Miter,
            },
            ..tiny_skia::Stroke::default()
        };
        // Stroke once, then fill the entire outline once. Compositing separate
        // segment masks would create alpha seams at joins and intersections.
        let Some(outline) = path.stroke(&stroke, 1.0) else {
            return 0;
        };
        path = outline;
    }
    let Some(size) = tiny_skia::IntSize::from_wh(width, height) else {
        return 1;
    };
    // Mask cannot borrow a caller-owned A8 slice. Do not create a Vec from Zig's
    // allocation: its allocator/deallocation contract is different from Rust's.
    let mut bytes = Vec::new();
    if bytes.try_reserve_exact(output.len()).is_err() {
        return 2;
    }
    bytes.resize(output.len(), 0);
    let Some(mut mask) = tiny_skia::Mask::from_vec(bytes, size) else {
        return 1;
    };
    mask.fill_path(
        &path,
        if style.kind == 1 {
            tiny_skia::FillRule::EvenOdd
        } else {
            tiny_skia::FillRule::Winding
        },
        true,
        tiny_skia::Transform::identity(),
    );
    output.copy_from_slice(mask.data());
    0
}
