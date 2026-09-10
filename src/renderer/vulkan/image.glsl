// The CPU reference uses the same pixel-center mapping and 8-bit bilinear
// weights. Interpolate premultiplied encoded-sRGB channels, including alpha.
uint imageSample(vec2 position) {
    precise vec2 local = position - vec2(image_left, image_top);
    vec2 extent = vec2(image_width, image_height);
    if (any(lessThan(local, vec2(0))) || any(greaterThanEqual(local, extent))) return 0u;
    uvec2 size = uvec2(atlas_width, image_rows);
    precise vec2 source_position = local / extent * vec2(size) - vec2(0.5);
    vec2 p = clamp(source_position, vec2(0), vec2(size - 1u));
    uvec2 a = uvec2(floor(p));
    uvec2 b = min(a + 1u, size - 1u);
    uvec2 f = uvec2(floor(fract(p) * 256.0 + 0.5));
    uint aa = masks[a.y * size.x + a.x];
    uint ba = masks[a.y * size.x + b.x];
    uint ab = masks[b.y * size.x + a.x];
    uint bb = masks[b.y * size.x + b.x];
    uint result = 0u;
    for (uint shift = 0u; shift <= 24u; shift += 8u) {
        uint top = ((aa >> shift) & 255u) * (256u - f.x) + ((ba >> shift) & 255u) * f.x;
        uint bottom = ((ab >> shift) & 255u) * (256u - f.x) + ((bb >> shift) & 255u) * f.x;
        uint value = (top * (256u - f.y) + bottom * f.y + 32768u) / 65536u;
        result |= value << shift;
    }
    return result;
}
