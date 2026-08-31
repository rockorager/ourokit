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

bool insideRoundedRectangle(vec2 point, vec4 rectangle, float radius_value) {
    vec2 size = rectangle.zw - rectangle.xy;
    if (size.x <= 0.0 || size.y <= 0.0) return false;
    float radius = min(radius_value, min(size.x, size.y) * 0.5);
    if (radius == 0.0) return true;
    vec2 center = clamp(point, rectangle.xy + radius, rectangle.zw - radius);
    vec2 delta = point - center;
    return dot(delta, delta) <= radius * radius;
}

void main() {
    vec2 point = gl_FragCoord.xy;
    vec4 outer = vec4(bounds);
    if (!insideRoundedRectangle(point, outer, corner_radius)) discard;
    float inset = min(border_width, min(outer.z - outer.x, outer.w - outer.y) * 0.5);
    vec4 inner = outer + vec4(inset, inset, -inset, -inset);
    if (has_border != 0u && !insideRoundedRectangle(point, inner, max(0.0, corner_radius - inset))) {
        target_color = border;
    } else if (has_background != 0u) {
        target_color = background;
    } else {
        discard;
    }
}
