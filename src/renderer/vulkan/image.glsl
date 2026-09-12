uvec4 decodeSource(uint pixel) {
    vec4 encoded = vec4(pixel & 255u, (pixel >> 8u) & 255u, (pixel >> 16u) & 255u, pixel >> 24u) / 255.0;
    float alpha = encoded.a;
    vec3 straight = alpha == 0.0 ? vec3(0.0) : clamp(encoded.rgb / alpha, 0.0, 1.0);
    bvec3 low = lessThanEqual(straight, vec3(0.04045));
    vec3 linear = mix(pow((straight + 0.055) / 1.055, vec3(2.4)), straight / 12.92, low);
    return uvec4(floor(vec4(linear * alpha, alpha) * 65535.0 + 0.5));
}

// Decode each texel before interpolation: filtering encoded premultiplied
// samples produces dark fringes and is not linear-light filtering.
uvec4 imageSampleLinear(vec2 position) {
    precise vec2 local = position - vec2(image_left, image_top);
    vec2 extent = vec2(image_width, image_height);
    if (any(lessThan(local, vec2(0))) || any(greaterThanEqual(local, extent))) return uvec4(0);
    uvec2 size = uvec2(atlas_width, image_rows);
    precise vec2 source_position = local / extent * vec2(size) - vec2(0.5);
    vec2 p = clamp(source_position, vec2(0), vec2(size - 1u));
    uvec2 a = uvec2(floor(p));
    uvec2 b = min(a + 1u, size - 1u);
    uvec2 f = uvec2(floor(fract(p) * 256.0 + 0.5));
    uvec4 aa = decodeSource(masks[a.y * size.x + a.x]);
    uvec4 ba = decodeSource(masks[a.y * size.x + b.x]);
    uvec4 ab = decodeSource(masks[b.y * size.x + a.x]);
    uvec4 bb = decodeSource(masks[b.y * size.x + b.x]);
    // Match the CPU's RGBA16 texels and 8-bit bilinear weights. The maximum
    // numerator is 65535*65536+32768, which fits in a 32-bit unsigned integer.
    uvec4 top = aa * (256u - f.x) + ba * f.x;
    uvec4 bottom = ab * (256u - f.x) + bb * f.x;
    return (top * (256u - f.y) + bottom * f.y + 32768u) / 65536u;
}
