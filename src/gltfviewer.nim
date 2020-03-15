import gltf, opengl, os, shaders, staticglfw, strformat, vmath

const
  vertShaderSrc = staticRead("basic.vert")
  fragShaderSrc = staticRead("basic.frag")

var
  models: seq[string]
  activeModel: int
  shader: GLuint
  model: Model
  view, proj: Mat4

for kind, path in walkDir("models"):
  if kind == pcDir:
    models.add(splitPath(path)[1])

if len(models) == 0:
  raise newException(Exception, "No models found")

if init() == 0:
  raise newException(Exception, "Failed to initialize GLFW")

windowHint(CONTEXT_VERSION_MAJOR, 4)
windowHint(CONTEXT_VERSION_MINOR, 0)
windowHint(OPENGL_FORWARD_COMPAT, TRUE)
windowHint(OPENGL_PROFILE, OPENGL_CORE_PROFILE)

windowHint(SAMPLES, 8.cint)

var window = createWindow(1280, 800, "GLTF Viewer", nil, nil)
window.makeContextCurrent()

proc onKey(
  window: Window,
  key, scancode, action, modifiers: cint
) {.cdecl.} =
  if action != PRESS:
    return
  if key == KEY_ESCAPE:
    window.setWindowShouldClose(1)
    return

  if key == KEY_LEFT:
    activeModel = max(activeModel - 1, 0)
  elif key == KEY_RIGHT:
    activeModel = min(activeModel + 1, len(models) - 1)

  model.clearFromGpu()
  model = loadModel(joinPath(
    "models", models[activeModel], "glTF", &"{models[activeModel]}.gltf"
  ))
  model.uploadToGpu()

discard window.setKeyCallback(onKey)

loadExtensions()

echo getVersionString()
echo "GL_VERSION:", cast[cstring](glGetString(GL_VERSION))
echo "GL_SHADING_LANGUAGE_VERSION:",
  cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))

shader = compileShaderFiles(vertShaderSrc, fragShaderSrc)

glDepthMask(GL_TRUE)
glEnable(GL_DEPTH_TEST)
glEnable(GL_MULTISAMPLE)

glClearColor(1, 1, 1, 1)

# load the first model while starting up
model = loadModel(joinPath(
  "models", models[activeModel], "glTF", &"{models[activeModel]}.gltf"
))
model.uploadToGpu()

while windowShouldClose(window) == 0:
  pollEvents()

  var framebufferWidth, framebufferHeight: cint
  getFramebufferSize(window, framebufferWidth.addr, framebufferHeight.addr)

  glViewport(0, 0, framebufferWidth, framebufferHeight)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glUseProgram(shader)

  view = lookAt(vec3(0, 5, 10), vec3(0, 0, 0), vec3(0, 1, 0)) # translate(vec3(0, 0, -10))
  proj = perspective(45, framebufferWidth / framebufferHeight, 0.1, 100)

  # where does shader actually go?
  model.draw(shader, view, proj)

  var error: GLenum
  while (error = glGetError(); error != GL_NO_ERROR):
    echo "gl error: " & $error.uint32

  window.swapBuffers()

terminate()
