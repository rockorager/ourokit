#version 450
#extension GL_GOOGLE_include_directive : require

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
    uint image_mode;
    uint image_rows;
    float image_left;
    float image_top;
    float image_width;
    float image_height;
};

#include "image.glsl"

layout(location = 0) out vec4 target_color;

void main() {
    if (image_mode != 0u) {
        uint sampled = imageSample(gl_FragCoord.xy);
        target_color = vec4(sampled & 255u, (sampled >> 8u) & 255u, (sampled >> 16u) & 255u, sampled >> 24u) / 255.0;
        return;
    }
    uvec2 local = uvec2(ivec2(gl_FragCoord.xy) - bounds.xy);
    uint index = (atlas_origin.y + local.y) * atlas_width + atlas_origin.x + local.x;
    uint coverage = (masks[index / 4u] >> ((index % 4u) * 8u)) & 255u;
    target_color = color * (float(coverage) / 255.0);
}
