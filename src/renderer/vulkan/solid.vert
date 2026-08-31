#version 450

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

void main() {
    const vec2 corners[6] = vec2[6](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
        vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0)
    );
    vec2 position = corners[gl_VertexIndex] * 2.0 - 1.0;
    gl_Position = vec4(position, 0.0, 1.0);
}
