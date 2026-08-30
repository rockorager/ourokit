#version 450

layout(set = 0, binding = 0, std430) readonly buffer Atlas {
    uint masks[];
};

layout(push_constant) uniform Push {
    vec4 color;
    vec2 target_size;
    vec2 padding;
    ivec4 bounds;
    uvec2 atlas_origin;
    uint atlas_width;
};

layout(location = 0) in vec4 fragment_color;
layout(location = 0) out vec4 target_color;

void main() {
    uvec2 local = uvec2(ivec2(gl_FragCoord.xy) - bounds.xy);
    uint index = (atlas_origin.y + local.y) * atlas_width + atlas_origin.x + local.x;
    uint coverage = (masks[index / 4u] >> ((index % 4u) * 8u)) & 255u;
    target_color = fragment_color * (float(coverage) / 255.0);
}
