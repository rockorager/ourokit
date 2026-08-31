#version 450

layout(location = 0) out vec4 target_color;

layout(push_constant) uniform Push {
    vec4 background;
    vec4 border;
    vec2 target_size;
    float corner_radius;
    float border_width;
    ivec4 bounds;
    uint has_background;
    uint has_border;
};

float roundedRectangleCoverage(vec2 point, vec4 rectangle, float radius_value) {
    vec2 size = rectangle.zw - rectangle.xy;
    if (size.x <= 0.0 || size.y <= 0.0) return 0.0;
    float radius = min(radius_value, min(size.x, size.y) * 0.5);
    if (radius == 0.0) return all(greaterThanEqual(point, rectangle.xy)) && all(lessThan(point, rectangle.zw)) ? 1.0 : 0.0;
    vec2 half_size = size * 0.5;
    vec2 delta = abs(point - (rectangle.xy + rectangle.zw) * 0.5) - (half_size - radius);
    float distance = length(max(delta, 0.0)) + min(max(delta.x, delta.y), 0.0) - radius;
    return clamp(0.5 - distance, 0.0, 1.0);
}

void main() {
    vec2 point = gl_FragCoord.xy;
    vec4 outer = vec4(bounds);
    float outer_coverage = roundedRectangleCoverage(point, outer, corner_radius);
    if (outer_coverage == 0.0) discard;
    float inset = min(border_width, min(outer.z - outer.x, outer.w - outer.y) * 0.5);
    vec4 inner = outer + vec4(inset, inset, -inset, -inset);
    float inner_coverage = has_border != 0u
        ? roundedRectangleCoverage(point, inner, max(0.0, corner_radius - inset))
        : 1.0;
    float border_coverage = has_border != 0u ? outer_coverage * (1.0 - inner_coverage) : 0.0;
    float background_coverage = has_background != 0u ? outer_coverage * inner_coverage : 0.0;
    target_color = border * border_coverage + background * background_coverage;
}
