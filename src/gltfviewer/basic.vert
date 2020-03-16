#version 410

layout(location = 0) in vec3 vertexPosition;
layout(location = 1) in vec4 vertexColor;
layout(location = 2) in vec3 vertexNormal;
layout(location = 3) in vec2 vertexUV;

uniform mat4 model;
uniform mat4 view;
uniform mat4 proj;

out vec4 color;
out vec3 normal;
out vec2 uv;

void main() {
  color = vertexColor;
  uv = vertexUV;

  mat4 modelRotation = model;
  modelRotation[3].xyz = vec3(0, 0, 0); // remove translation
  // there may still be scale but ignore for now
  normal = (modelRotation * vec4(vertexNormal, 1.0)).xyz;

  gl_Position = proj * view * model * vec4(vertexPosition, 1.0);
}
