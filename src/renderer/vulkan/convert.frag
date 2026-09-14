#version 450

layout(input_attachment_index = 0, set = 0, binding = 0) uniform subpassInput working;
layout(location = 0) out vec4 target_color;

void main() {
    vec4 linear = subpassLoad(working);
    float alpha = clamp(linear.a, 0.0, 1.0);
    vec3 straight = alpha > 0.0 ? clamp(linear.rgb / alpha, 0.0, 1.0) : vec3(0.0);
    vec3 encoded = pow(straight, vec3(1.0 / 2.2));
    // The compositor consumes encoded-premultiplied BGRA8, NOT encoded
    // linear-premultiplied channels. Alpha never goes through the transfer.
    target_color = vec4(encoded * alpha, alpha);
}
