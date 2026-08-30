#version 450

layout(push_constant) uniform Push {
    vec4 color;
    vec2 target_size;
    vec2 padding;
    ivec4 bounds;
};

layout(location = 0) out vec4 fragment_color;

void main() {
    const vec2 corners[6] = vec2[6](
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
        vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0)
    );
    vec2 position = corners[gl_VertexIndex] * 2.0 - 1.0;
    gl_Position = vec4(position, 0.0, 1.0);
    fragment_color = color;
}
