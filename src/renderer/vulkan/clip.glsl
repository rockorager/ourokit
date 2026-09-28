// ClipRecord in root.zig, std430 stride 32. Zero indexes mean no rounded clip.
struct ClipRecord {
    ivec2 origin;
    uvec2 size;
    uint radius;
    uint parent;
    uvec2 padding;
};

layout(set = 2, binding = 0, std430) readonly buffer RoundedClips {
    ClipRecord rounded_clips[];
};

uint roundedClipCoverage(ClipRecord clip, vec2 point) {
    if (any(equal(clip.size, uvec2(0)))) return 0u;
    precise vec2 size = vec2(clip.size);
    precise vec2 origin = vec2(clip.origin);
    precise float radius = float(min(clip.radius, min(clip.size.x, clip.size.y) / 2u));
    if (radius == 0.0) {
        precise vec2 end = origin + size;
        return all(greaterThanEqual(point, origin)) && all(lessThan(point, end)) ? 255u : 0u;
    }
    // Match scene.RoundedClip.coverage operation-by-operation, without FMA.
    precise vec2 half_size = size * 0.5;
    precise vec2 center = origin + half_size;
    precise vec2 delta = abs(point - center) - (half_size - radius);
    precise vec2 outside_delta = max(delta, 0.0);
    precise float xx = outside_delta.x * outside_delta.x;
    precise float yy = outside_delta.y * outside_delta.y;
    precise float squared = xx + yy;
    precise float outside = sqrt(squared);
    precise float distance = outside + min(max(delta.x, delta.y), 0.0) - radius;
    precise float coverage = clamp(0.5 - distance, 0.0, 1.0);
    precise float scaled = coverage * 255.0;
    precise float rounded = scaled + 0.5;
    return uint(floor(rounded));
}

uint clipCoverage(uint index, vec2 point) {
    // scene.max_clip_depth, asserted by root.zig. Multiplication with A8
    // rounding is not associative: evaluate ancestors outermost first.
    uint ancestors[64];
    uint depth = 0u;
    while (index != 0u) {
        ancestors[depth++] = index;
        index = rounded_clips[index - 1u].parent;
    }
    uint coverage = 255u;
    while (depth != 0u) {
        uint next = roundedClipCoverage(rounded_clips[ancestors[--depth] - 1u], point);
        coverage = (coverage * next + 127u) / 255u;
        if (coverage == 0u) break;
    }
    return coverage;
}

uvec4 clipScale(uvec4 source, uint coverage) {
    return (source * (coverage * 257u) + 32767u) / 65535u;
}
