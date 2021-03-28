#version 410

in vec4 color;
in vec3 normal;
in vec2 uv;

uniform bool sampleTex = false;
uniform sampler2D rgbaTex;

out vec4 fragColor;

void main() {
  if (sampleTex) {
    fragColor.rgb = texture(rgbaTex, uv).rgb;
  } else {
    fragColor.rgb = color.rgb;
    fragColor.rgb += normal;
  }

  vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
  fragColor.rgb = fragColor.rgb * dot(lightDir, normal);

  fragColor.a = 1.0;
}
