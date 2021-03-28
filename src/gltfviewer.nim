import gltfviewer/gltf, gltfviewer/shaders, opengl, os, staticglfw, strformat,
    times, vmath, strutils

const
  vertShaderSrc = staticRead("gltfviewer/basic.vert")
  fragShaderSrc = staticRead("gltfviewer/basic.frag")

var
  models: seq[string]
  activeModel: int
  shader: GLuint
  model: Model
  mousePos, mousePosPrev, mouseDelta: Vec2
  mouseClicked: bool
  hpr: Vec3
  zoom = -140.0
  mouseWheelDelta = 40.0
  view, proj: Mat4
  startTime: float

for path in walkDirRec("models"):
  if path.endsWith(".glb"): # or path.endsWith(".gltf"):
    models.add(path)

if len(models) == 0:
  raise newException(Exception, "No models found")

if init() == 0:
  raise newException(Exception, "Failed to initialize GLFW")

windowHint(CONTEXT_VERSION_MAJOR, 4)
windowHint(CONTEXT_VERSION_MINOR, 1)
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
  else:
    return

  model.clearFromGpu()
  model = loadModel(models[activeModel])
  model.uploadToGpu()

proc onMouseButton(
  window: Window,
  button, action, modifiers: cint
) {.cdecl.} =
  if action == RELEASE:
    mouseClicked = false
  elif action == PRESS:
    mouseClicked = true

proc onScroll(window: Window, xoffset, yoffset: cdouble) {.cdecl.} =
  mouseWheelDelta += yoffset

discard window.setKeyCallback(onKey)
discard window.setMouseButtonCallback(onMouseButton)
discard window.setScrollCallback(onScroll)

loadExtensions()

echo getVersionString()
echo "GL_VERSION:", cast[cstring](glGetString(GL_VERSION))
echo "GL_SHADING_LANGUAGE_VERSION:",
  cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))

shader = compileShaderFiles(vertShaderSrc, fragShaderSrc)

glDepthMask(GL_TRUE)
glEnable(GL_DEPTH_TEST)
glEnable(GL_MULTISAMPLE)

glEnable(GL_CULL_FACE)
glCullFace(GL_BACK)
glFrontFace(GL_CCW)

glClearColor(0.1, 0.1, 0.1, 1.0)

# Load the first model while starting up
model = loadModel(models[activeModel])
model.uploadToGpu()

startTime = epochTime()

while windowShouldClose(window) == 0:
  pollEvents()

  var framebufferWidth, framebufferHeight: cint
  getFramebufferSize(window, framebufferWidth.addr, framebufferHeight.addr)

  glViewport(0, 0, framebufferWidth, framebufferHeight)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glUseProgram(shader)

  block:
    var x, y: float64
    window.getCursorPos(addr x, addr y)
    mousePos = vec2(x, y)
    mouseDelta = mousePos - mousePosPrev
    mousePosPrev = mousePos

  if mouseClicked:
    hpr.x -= mouseDelta.x / 100
    hpr.y -= mouseDelta.y / 100

  zoom += mouseWheelDelta * 4
  mouseWheelDelta = 0

  let transform = translate(vec3(0, 0, -zoom)) * rotateX(hpr.y) * rotateY(hpr.x)

  view = mat4()
  proj = perspective(45.float32, framebufferWidth / framebufferHeight, 0.1, 1000)

  model.advanceAnimations(epochTime() - startTime)
  model.draw(shader, transform, view, proj)

  var error: GLenum
  while (error = glGetError(); error != GL_NO_ERROR):
    echo "gl error: " & $error.uint32

  window.swapBuffers()

terminate()
