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
    uint gradient_index;
    layout(offset = 96) uint clip_index;
};

#include "image.glsl"
#include "gradient.glsl"
#include "clip.glsl"

layout(location = 0) out vec4 target_color;

void main() {
    uint clip = clipCoverage(clip_index, gl_FragCoord.xy);
    if (clip == 0u) discard;
    float clip_alpha = float(clip) / 255.0;
    if (image_mode == 1u) {
        target_color = vec4(imageSampleLinear(gl_FragCoord.xy)) / 65535.0 * clip_alpha;
        return;
    }
    uvec2 local = uvec2(ivec2(gl_FragCoord.xy) - bounds.xy);
    if (image_mode == 2u || image_mode == 3u) {
        uint offset = ((atlas_origin.y + local.y) * atlas_width + atlas_origin.x + local.x * 8u) / 4u;
        uvec2 pixel = uvec2(masks[offset], masks[offset + 1u]);
        uvec4 channels = uvec4(pixel.x & 65535u, pixel.x >> 16u, pixel.y & 65535u, pixel.y >> 16u);
        if (image_mode == 3u) {
            uint opacity = uint(color.a * 65535.0 + 0.5);
            channels = (channels * opacity + 32767u) / 65535u;
            target_color = vec4(clipScale(channels, clip)) / 65535.0;
            return;
        }
        target_color = vec4(channels) / 65535.0 * color.a * clip_alpha;
        return;
    }
    uint index = (atlas_origin.y + local.y) * atlas_width + atlas_origin.x + local.x;
    uint coverage = (masks[index / 4u] >> ((index % 4u) * 8u)) & 255u;
    vec4 tint = gradient_index != 0u ? vec4(gradientSample(gradient_index, gl_FragCoord.xy)) / 65535.0 : color;
    target_color = tint * (float(coverage) / 255.0) * clip_alpha;
}
