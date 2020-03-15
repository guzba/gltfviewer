#version 410

in vec4 color;
in vec3 normal;
out vec4 fragColor;

void main() {
  fragColor.rgb = color.rgb;
  fragColor.a = 1.0;
  fragColor.rgb += normal;
}
