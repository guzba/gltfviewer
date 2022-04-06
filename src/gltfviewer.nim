import gltfviewer/gltf, gltfviewer/shaders, opengl, os, windy, strformat,
    times, vmath, strutils

const
  vertShaderSrc = staticRead("gltfviewer/basic.vert")
  fragShaderSrc = staticRead("gltfviewer/basic.frag")

var
  models: seq[string]
  activeModel: int
  shader: GLuint
  model: Model
  hpr: Vec3
  zoom = 140.0
  view, proj: Mat4
  startTime: float

for path in walkDirRec("models"):
  if path.endsWith(".glb") or path.endsWith(".gltf"):
    models.add(path)

if len(models) == 0:
  raise newException(Exception, "No models found")

var window = newWindow("GLTF Viewer", ivec2(1280, 800))
window.makeContextCurrent()

window.onButtonPress = proc(button: Button) =

  if button == KeyEscape:
    window.closeRequested = true

  if button == KeyLeft:
    activeModel = max(activeModel - 1, 0)
  elif button == KeyRight:
    activeModel = min(activeModel + 1, len(models) - 1)
  else:
    return

  model.clearFromGpu()
  model = loadModel(models[activeModel])
  model.uploadToGpu()

loadExtensions()

echo "GL_VERSION:", cast[cstring](glGetString(GL_VERSION))
echo "GL_SHADING_LANGUAGE_VERSION:",
  cast[cstring](glGetString(GL_SHADING_LANGUAGE_VERSION))

shader = compileShaderFiles(vertShaderSrc, fragShaderSrc)

glDepthMask(GL_TRUE)
glEnable(GL_DEPTH_TEST)
glEnable(GL_MULTISAMPLE)

#glEnable(GL_CULL_FACE)
glCullFace(GL_BACK)
glFrontFace(GL_CCW)

glClearColor(0.1, 0.1, 0.1, 1.0)

# Load the first model while starting up
model = loadModel(models[activeModel])
model.uploadToGpu()

startTime = epochTime()

window.onFrame = proc() =
  glViewport(0, 0, window.size.x, window.size.y)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glUseProgram(shader)

  if window.buttonDown[MouseLeft]:
    hpr.x -= window.mouseDelta.x / 100
    hpr.y -= window.mouseDelta.y / 100

  zoom += window.scrollDelta.y * 4

  let transform = translate(vec3(0, 0, -zoom)) * rotateX(hpr.y) * rotateY(hpr.x)

  view = mat4()
  proj = perspective(45.float32, window.size.x.float32 / window.size.y.float32, 0.1, 2000)

  model.advanceAnimations(epochTime() - startTime)
  model.draw(shader, transform, view, proj)

  var error: GLenum
  while (error = glGetError(); error != GL_NO_ERROR):
    echo "gl error: " & $error.uint32

  window.swapBuffers()

while not window.closeRequested:
  pollEvents()
