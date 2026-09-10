//! Private C ABI, version 1. No font discovery, file IO or network resources.
//! The caller owns the encoded input during parsing and the RGBA output buffer.
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
