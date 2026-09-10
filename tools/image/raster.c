// Private raster bridge. Output is straight RGBA; codec.zig premultiplies once.
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__PNG
#include "wuffs-v0.4.c"
#include "src/webp/decode.h"
#include "src/webp/demux.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  void* decoder;
  int kind;
  wuffs_base__io_buffer input;
  WebPDemuxer* webp;
  uint32_t width, height;
} ourokit_raster;

void ourokit_raster_close(ourokit_raster* image) {
  free(image->decoder);
  if (image->webp) WebPDemuxDelete(image->webp);
  free(image);
}

// kind: 1 PNG, 2 JPEG, 3 WebP. Input must outlive the returned handle.
// status: 0 success, 1 invalid data, 2 allocation failure, 3 resource limit.
int ourokit_raster_open(const uint8_t* data, size_t len, int kind,
                        ourokit_raster** out, uint32_t* width, uint32_t* height) {
  ourokit_raster* image = calloc(1, sizeof(*image));
  if (!image) return 2;
  image->kind = kind;
  if (kind == 3) {
    WebPData input = {data, len};
    image->webp = WebPDemux(&input);
    if (!image->webp) goto invalid;
    image->width = WebPDemuxGetI(image->webp, WEBP_FF_CANVAS_WIDTH);
    image->height = WebPDemuxGetI(image->webp, WEBP_FF_CANVAS_HEIGHT);
  } else {
    image->decoder = kind == 1 ? (void*)wuffs_png__decoder__alloc()
                              : (void*)wuffs_jpeg__decoder__alloc();
    if (!image->decoder) { ourokit_raster_close(image); return 2; }
    image->input = wuffs_base__make_io_buffer(
        wuffs_base__make_slice_u8((uint8_t*)data, len),
        wuffs_base__make_io_buffer_meta(len, 0, 0, true));
    wuffs_base__image_config config = wuffs_base__null_image_config();
    // Concrete calls avoid Wuffs' generic vtable's incompatible function-pointer
    // casts, which are diagnosed by Clang's ReleaseSafe function sanitizer.
    wuffs_base__status status = kind == 1
        ? wuffs_png__decoder__decode_image_config(image->decoder, &config, &image->input)
        : wuffs_jpeg__decoder__decode_image_config(image->decoder, &config, &image->input);
    if (status.repr) goto invalid;
    image->width = wuffs_base__pixel_config__width(&config.pixcfg);
    image->height = wuffs_base__pixel_config__height(&config.pixcfg);
  }
  *width = image->width;
  *height = image->height;
  *out = image;
  return 0;
invalid:
  ourokit_raster_close(image);
  return 1;
}

int ourokit_raster_render(ourokit_raster* image, uint8_t* pixels, size_t len) {
  memset(pixels, 0, len);
  if (image->webp) {
    WebPIterator frame;
    if (!WebPDemuxGetFrame(image->webp, 1, &frame)) return 1;
    // The first frame is composited onto a transparent canvas, as specified by
    // libwebp's animation decoder (the ANIM background color is not used).
    int valid = frame.complete && frame.width > 0 && frame.height > 0 &&
        frame.x_offset >= 0 && frame.y_offset >= 0 &&
        (uint64_t)frame.x_offset + frame.width <= image->width &&
        (uint64_t)frame.y_offset + frame.height <= image->height &&
        image->width <= INT_MAX / 4;
    if (valid) {
      size_t offset = ((size_t)frame.y_offset * image->width + frame.x_offset) * 4;
      valid = WebPDecodeRGBAInto(frame.fragment.bytes, frame.fragment.size,
                                pixels + offset, len - offset, (int)image->width * 4) != NULL;
    }
    WebPDemuxReleaseIterator(&frame);
    return valid ? 0 : 1;
  }
  uint64_t work_len = image->kind == 1
      ? wuffs_png__decoder__workbuf_len(image->decoder).max_incl
      : wuffs_jpeg__decoder__workbuf_len(image->decoder).max_incl;
  if (work_len > SIZE_MAX) return 3;
  uint8_t* work = work_len ? malloc((size_t)work_len) : NULL;
  if (work_len && !work) return 2;
  wuffs_base__pixel_config config = wuffs_base__null_pixel_config();
  wuffs_base__pixel_config__set(&config, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
      WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, image->width, image->height);
  wuffs_base__pixel_buffer buffer = wuffs_base__null_pixel_buffer();
  wuffs_base__status status = wuffs_base__pixel_buffer__set_from_slice(
      &buffer, &config, wuffs_base__make_slice_u8(pixels, len));
  if (!status.repr) {
    wuffs_base__slice_u8 workbuf = wuffs_base__make_slice_u8(work, (size_t)work_len);
    status = image->kind == 1
        ? wuffs_png__decoder__decode_frame(image->decoder, &buffer, &image->input,
                                          WUFFS_BASE__PIXEL_BLEND__SRC, workbuf, NULL)
        : wuffs_jpeg__decoder__decode_frame(image->decoder, &buffer, &image->input,
                                           WUFFS_BASE__PIXEL_BLEND__SRC, workbuf, NULL);
  }
  free(work);
  return status.repr ? 1 : 0;
}
