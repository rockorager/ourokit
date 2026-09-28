// Matches GradientRecord in root.zig: std430, 160 bytes per record.
struct GradientRecord {
    vec2 start;
    vec2 direction;
    uint count;
    uint padding0;
    uint padding1;
    uint padding2;
    uvec4 stops[8]; // position, packed RG, packed BA, padding
};

layout(set = 1, binding = 0, std430) readonly buffer Gradients {
    GradientRecord gradients[];
};

uvec4 gradientColor(uvec4 stop) {
    return uvec4(stop.y & 65535u, stop.y >> 16u, stop.z & 65535u, stop.z >> 16u);
}

uvec4 gradientSample(uint index, vec2 point) {
    GradientRecord gradient = gradients[index - 1u];
    // Keep identical f32 operations to paint.Prepared.sample. In particular,
    // neither projection nor UNORM16 rounding may contract into an FMA.
    precise float dx = point.x - gradient.start.x;
    precise float dy = point.y - gradient.start.y;
    precise float x = dx * gradient.direction.x;
    precise float y = dy * gradient.direction.y;
    precise float projection = x + y;
    if (any(isnan(point)) || any(isinf(point)) || isnan(projection) || isinf(projection)) return uvec4(0);
    precise float scaled = clamp(projection, 0.0, 1.0) * 65535.0;
    precise float rounded = scaled + 0.5;
    uint position = uint(floor(rounded));
    uint upper = 0u;
    // Advancing across every equal stop makes the last quantized tie win.
    while (upper < gradient.count && gradient.stops[upper].x <= position) ++upper;
    if (upper == 0u) return gradientColor(gradient.stops[0]);
    if (upper == gradient.count) return gradientColor(gradient.stops[upper - 1u]);
    uvec4 low = gradient.stops[upper - 1u];
    uvec4 high = gradient.stops[upper];
    uint span = high.x - low.x;
    return (gradientColor(low) * (high.x - position) +
            gradientColor(high) * (position - low.x) + span / 2u) / span;
}
