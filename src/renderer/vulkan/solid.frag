#version 450

layout(location = 0) in vec4 fragment_color;
layout(location = 0) out vec4 target_color;

void main() {
    target_color = fragment_color;
}
