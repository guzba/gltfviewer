import base64, json, pixie, opengl, os, strformat, strutils, vmath, flatty/binny

type
  BufferView = object
    buffer: int
    byteOffset, byteLength, byteStride: Natural

  Texture = object
    source: Natural
    sampler: int

  Sampler = object
    magFilter, minFilter, wrapS, wrapT: GLint

  BaseColorTexture = object
    index: int

  PBRMetallicRoughness = object
    apply: bool
    baseColorTexture: BaseColorTexture

  Material = object
    name: string
    pbrMetallicRoughness: PBRMetallicRoughness

  InterpolationKind = enum
    iLinear, iStep, iCubicSpline

  AnimationSampler = object
    input, output: Natural # Accessor indices
    interpolation: InterpolationKind

  AnimationPath = enum
    pTranslation, pRotation, pScale, pWeights

  AnimationTarget = object
    node: Natural
    path: AnimationPath

  AnimationChannel = object
    sampler: Natural
    target: AnimationTarget

  AnimationState = object
    prevTime: float
    prevKey: int

  Animation = object
    samplers: seq[AnimationSampler]
    channels: seq[AnimationChannel]

  AccessorKind = enum
    atSCALAR, atVEC2, atVEC3, atVEC4, atMAT2, atMAT3, atMAT4

  Accessor = object
    bufferView, byteOffset, count: Natural
    componentType: GLenum
    kind: AccessorKind

  PrimitiveAttributes = object
    position, normal, color0, texcoord0: int

  Primitive = object
    attributes: PrimitiveAttributes
    indices, material: int
    mode: GLenum

  Mesh = object
    name: string
    primitives: seq[Natural]

  Node = object
    name: string
    kids: seq[Natural]
    mesh: int
    applyMatrix: bool
    matrix: Mat4
    rotation: Quat
    translation, scale: Vec3

  Scene = object
    nodes: seq[Natural]

  Model* = ref object
    # All of the data that is indexed into
    buffers: seq[string]
    bufferViews: seq[BufferView]
    textures: seq[Texture]
    samplers: seq[Sampler]
    images: seq[Image]
    animations: seq[Animation]
    materials: seq[Material]
    accessors: seq[Accessor]
    primitives: seq[Primitive]
    meshes: seq[Mesh]
    nodes: seq[Node]
    scenes: seq[Scene]

    # State
    bufferIds, textureIds, vertexArrayIds: seq[GLuint]
    animationState: seq[AnimationState]

    # Model properties
    scene: Natural

func size(componentType: GLenum): Natural =
  case componentType:
    of cGL_BYTE, cGL_UNSIGNED_BYTE:
      1
    of cGL_SHORT, cGL_UNSIGNED_SHORT:
      2
    of GL_UNSIGNED_INT, cGL_FLOAT:
      4
    else:
      raise newException(Exception, "Unexpected componentType")

func componentCount(accessorKind: AccessorKind): Natural =
  case accessorKind:
    of atSCALAR:
      1
    of atVEC2:
      2
    of atVEC3:
      3
    of atVEC4, atMAT2:
      4
    of atMAT3:
      9
    of atMAT4:
      16

template read[T](buffer: ptr string, byteOffset: int, index = 0): auto =
  cast[ptr T](buffer[byteOffset + (index * sizeof(T))].addr)[]

template readVec3(buffer: ptr string, byteOffset, index: int): Vec3 =
  var v: Vec3
  v.x = read[float32](buffer, byteOffset, index)
  v.y = read[float32](buffer, byteOffset, index + 1)
  v.z = read[float32](buffer, byteOffset, index + 2)
  v

template readQuat(buffer: ptr string, byteOffset, index: int): Quat =
  var q: Quat
  q.x = read[float32](buffer, byteOffset, index)
  q.y = read[float32](buffer, byteOffset, index + 1)
  q.z = read[float32](buffer, byteOffset, index + 2)
  q.w = read[float32](buffer, byteOffset, index + 3)
  q

proc advanceAnimations*(model: Model, totalTime: float) =
  for animationIndex in 0..<len(model.animations):
    let animation = model.animations[animationIndex]
    var animationState = model.animationState[animationIndex]

    for channelIndex in 0..<len(animation.channels):
      # Get the various things we need from the glTF tree
      let
        channel = animation.channels[channelIndex]
        sampler = animation.samplers[channel.sampler]
        input = model.accessors[sampler.input]
        output = model.accessors[sampler.output]
        inputBufferView = model.bufferViews[input.bufferView]
        outputBufferView = model.bufferViews[output.bufferView]
        inputBuffer = model.buffers[inputBufferView.buffer].addr
        outputBuffer = model.buffers[outputBufferView.buffer].addr
        inputByteOffset = input.byteOffset + inputBufferView.byteOffset
        outputByteOffset = output.byteOffset + outputBufferView.byteOffset

      # Ensure time is within the bounds of the animation interval
      let
        min = read[float32](inputBuffer, inputByteOffset)
        max = read[float32](inputBuffer, inputByteOffset, input.count - 1)
        time = max(totalTime mod max, min).float32

      if animationState.prevTime > time:
        animationState.prevKey = 0

      animationState.prevTime = time

      var nextKey: int
      for i in animationState.prevKey..<input.count:
        if time <= read[float32](inputBuffer, inputByteOffset, i):
          nextKey = clamp(i, 1, input.count - 1)
          break

      animationState.prevKey = clamp(nextKey - 1, 0, nextKey)

      let
        prevStartTime = read[float32](
          inputBuffer,
          inputByteOffset,
          animationState.prevKey
        )
        nextStartTime = read[float32](
          inputBuffer,
          inputByteOffset,
          nextKey
        )
        timeDelta = nextStartTime - prevStartTime
        normalizedTime = (time - prevStartTime) / timeDelta # Between [0, 1]

      case sampler.interpolation:
        of iStep:
          case channel.target.path:
            of pTranslation, pScale:
              let transform = readVec3(
                outputBuffer,
                outputByteOffset,
                animationState.prevKey * output.kind.componentCount
              )

              if channel.target.path == pTranslation:
                model.nodes[channel.target.node].translation = transform
              else:
                model.nodes[channel.target.node].scale = transform
            of pRotation:
              model.nodes[channel.target.node].rotation = readQuat(
                outputBuffer,
                outputByteOffset,
                animationState.prevKey * output.kind.componentCount
              )
            of pWeights:
              discard
        of iLinear:
          case channel.target.path:
            of pTranslation, pScale:
              let
                v0 = readVec3(
                  outputBuffer,
                  outputByteOffset,
                  animationState.prevKey * output.kind.componentCount
                )
                v1 = readVec3(
                  outputBuffer,
                  outputByteOffset,
                  nextKey * output.kind.componentCount
                )
                transform = lerp(v0, v1, normalizedTime)

              if channel.target.path == pTranslation:
                model.nodes[channel.target.node].translation = transform
              else:
                model.nodes[channel.target.node].scale = transform
            of pRotation:
              let
                q0 = readQuat(
                  outputBuffer,
                  outputByteOffset,
                  animationState.prevKey * output.kind.componentCount
                )
                q1 = readQuat(
                  outputBuffer,
                  outputByteOffset,
                  nextKey * output.kind.componentCount
                )
              model.nodes[channel.target.node].rotation =
                nlerp(q0, q1, normalizedTime)
            of pWeights:
              discard
        of iCubicSpline:
          let
            t = normalizedTime
            t2 = pow(normalizedTime, 2)
            t3 = pow(normalizedTime, 3)
            prevIndex = animationState.prevKey * output.kind.componentCount * 3
            nextIndex = nextKey * output.kind.componentCount * 3

          template cubicSpline[T](): T =
            var transform: T
            for i in 0..<output.kind.componentCount:
              let
                v0 = read[float32](
                  outputBuffer,
                  outputByteOffset,
                  prevIndex + i + output.kind.componentCount
                )
                a = timeDelta * read[float32](
                  outputBuffer,
                  outputByteOffset,
                  nextIndex + i
                )
                b = timeDelta * read[float32](
                  outputBuffer,
                  outputByteOffset,
                  prevIndex + i + (2 * output.kind.componentCount)
                )
                v1 = read[float32](
                  outputBuffer,
                  outputByteOffset,
                  nextIndex + i + output.kind.componentCount
                )

              transform[i] = ((2*t3 - 3*t2 + 1) * v0) +
                ((t3 - 2*t2 + t) * b) +
                ((-2*t3 + 3*t2) * v1) +
                ((t3 - t2) * a)

            transform

          case channel.target.path:
            of pTranslation, pScale:
              let transform = cubicSpline[Vec3]()
              if channel.target.path == pTranslation:
                model.nodes[channel.target.node].translation = transform
              else:
                model.nodes[channel.target.node].scale = transform
            of pRotation:
              model.nodes[channel.target.node].rotation = cubicSpline[Quat]()
            of pWeights:
              discard

proc draw(
  node: Node,
  model: Model,
  shader: GLuint,
  transform, view, proj: Mat4
) =
  var trs: Mat4
  if node.applyMatrix:
    trs = transform * node.matrix
  else:
    trs = transform *
        translate(node.translation) *
        node.rotation.mat4() *
        scale(node.scale)

  for kid in node.kids:
    model.nodes[kid].draw(model, shader, trs, view, proj)

  # This node just applies a transform to children
  if node.mesh < 0:
    return

  let
    modelUniform = glGetUniformLocation(shader, "model")
    viewUniform = glGetUniformLocation(shader, "view")
    projUniform = glGetUniformLocation(shader, "proj")

  var
    modelArray = trs
    viewArray = view
    projArray = proj

  glUniformMatrix4fv(modelUniform, 1, GL_FALSE, cast[ptr float32](modelArray.addr))
  glUniformMatrix4fv(viewUniform, 1, GL_FALSE, cast[ptr float32](viewArray.addr))
  glUniformMatrix4fv(projUniform, 1, GL_FALSE, cast[ptr float32](projArray.addr))

  for primitiveIndex in model.meshes[node.mesh].primitives:
    let primitive = model.primitives[primitiveIndex]

    glBindVertexArray(model.vertexArrayIds[primitiveIndex])

    var textureId: GLuint
    if primitive.material >= 0:
      let material = model.materials[primitive.material]
      if material.pbrMetallicRoughness.apply:
        let textureIndex = material.pbrMetallicRoughness.baseColorTexture.index
        if textureIndex >= 0:
          textureId = model.textureIds[textureIndex]

    # Bind the material texture (or 0 to ensure no previous texture is bound)
    glBindTexture(GL_TEXTURE_2D, textureId)

    let sampleTexUniform = glGetUniformLocation(shader, "sampleTex")
    glUniform1i(sampleTexUniform, textureId.GLint)

    if primitive.indices < 0:
      let positionAccessor = model.accessors[primitive.attributes.position]
      glDrawArrays(primitive.mode, 0, positionAccessor.count.cint)
    else:
      let indicesAccessor = model.accessors[primitive.indices]
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, model.bufferIds[primitive.indices])
      glDrawElements(
        primitive.mode,
        indicesAccessor.count.GLint,
        indicesAccessor.componentType,
        nil
      )

proc draw*(model: Model, shader: GLuint, transform, view, proj: Mat4) =
  let scene = model.scenes[model.scene]
  for node in scene.nodes:
    model.nodes[node].draw(model, shader, transform, view, proj)

proc bindBuffer(
  model: Model,
  accessorIndex: Natural,
  target: GLenum,
  vertexAttribIndex: int
) =
  let
    accessor = model.accessors[accessorIndex]
    bufferView = model.bufferViews[accessor.bufferView]
    byteOffset = accessor.byteOffset + bufferView.byteOffset
    byteLength = accessor.count *
        accessor.kind.componentCount() *
        accessor.componentType.size()

  var bufferId: GLuint
  glGenBuffers(1, bufferId.addr)
  glBindBuffer(GL_ARRAY_BUFFER, bufferId)

  model.bufferIds[accessorIndex] = bufferId

  glBufferData(
    GL_ARRAY_BUFFER,
    byteLength,
    model.buffers[bufferView.buffer][byteOffset].addr,
    GL_STATIC_DRAW
  )

  if vertexAttribIndex >= 0:
    glVertexAttribPointer(
      vertexAttribIndex.GLuint,
      accessor.kind.componentCount().GLint,
      accessor.componentType,
      GL_FALSE,
      bufferView.byteStride.GLint,
      nil
    )
    glEnableVertexAttribArray(vertexAttribIndex.GLuint)

proc bindTexture(model: Model, materialIndex: Natural) =
  let
    material = model.materials[materialIndex]
    baseColorTexture = material.pbrMetallicRoughness.baseColorTexture
    texture = model.textures[baseColorTexture.index]
    image = model.images[texture.source].addr

  var textureId: GLuint
  glGenTextures(1, textureId.addr)
  glBindTexture(GL_TEXTURE_2D, textureId)

  model.textureIds[baseColorTexture.index] = textureId

  glTexImage2D(
    GL_TEXTURE_2D,
    0,
    GL_RGBA.GLint,
    image.width.GLint,
    image.height.GLint,
    0,
    GL_RGBA,
    GL_UNSIGNED_BYTE,
    image.data[0].addr
  )

  if texture.sampler >= 0:
    let sampler = model.samplers[texture.sampler]
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, sampler.magFilter)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, sampler.minFilter)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, sampler.wrapS)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, sampler.wrapT)
  else:
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT)

  glGenerateMipmap(GL_TEXTURE_2D)

proc uploadToGpu*(model: Model) =
  model.bufferIds.setLen(len(model.accessors))
  model.textureIds.setLen(len(model.textures))
  model.vertexArrayIds.setLen(len(model.primitives))
  model.animationState.setLen(len(model.animations))

  for node in model.nodes:
    if node.mesh < 0:
      continue

    for primitiveIndex in model.meshes[node.mesh].primitives:
      let primitive = model.primitives[primitiveIndex]

      var vertexArrayId: GLuint
      glGenVertexArrays(1, vertexArrayId.addr)
      glBindVertexArray(vertexArrayId)

      model.vertexArrayIds[primitiveIndex] = vertexArrayId

      model.bindBuffer(primitive.attributes.position, GL_ARRAY_BUFFER, 0)

      if primitive.indices >= 0:
        model.bindBuffer(primitive.indices, GL_ELEMENT_ARRAY_BUFFER, -1)
      if primitive.attributes.color0 >= 0:
        model.bindBuffer(primitive.attributes.color0, GL_ARRAY_BUFFER, 1)
      if primitive.attributes.normal >= 0:
        model.bindBuffer(primitive.attributes.normal, GL_ARRAY_BUFFER, 2)
      if primitive.attributes.texcoord0 >= 0:
        model.bindBuffer(primitive.attributes.texcoord0, GL_ARRAY_BUFFER, 3)

      if primitive.material >= 0:
        let material = model.materials[primitive.material]
        if material.pbrMetallicRoughness.apply:
          if material.pbrMetallicRoughness.baseColorTexture.index >= 0:
            model.bindTexture(primitive.material)

proc clearFromGpu*(model: Model) =
  glDeleteVertexArrays(
    len(model.vertexArrayIds).GLint,
    model.vertexArrayIds[0].addr
  )

  glDeleteBuffers(len(model.bufferIds).GLint, model.bufferIds[0].addr)

  if len(model.textureIds) > 0:
    glDeleteTextures(len(model.textureIds).GLint, model.textureIds[0].addr)
    model.textureIds.setLen(0)

proc loadModelJson*(
    jsonRoot: JsonNode,
    modelDir = "",
    buffers: seq[string] = @[]
  ): Model =

  result = Model()

  var bufferIndex = 0
  for entry in jsonRoot["buffers"]:
    var data: string
    if "uri" in entry:
      let uri = entry["uri"].getStr()
      if uri.startsWith("data:application/"):
        data = decode(uri.split(',')[1])
      else:
        data = readFile(joinPath(modelDir, uri))
    else:
      data = buffers[bufferIndex][0 ..< entry["byteLength"].getInt()]
      inc bufferIndex
    assert len(data) == entry["byteLength"].getInt()
    result.buffers.add(data)

  for entry in jsonRoot["bufferViews"]:
    var bufferView = BufferView()
    bufferView.buffer = entry["buffer"].getInt()
    bufferView.byteOffset = entry{"byteOffset"}.getInt()
    bufferView.byteLength = entry["byteLength"].getInt()
    bufferView.byteStride = entry{"byteStride"}.getInt()

    if entry.hasKey("target"):
      let target = entry["target"].getInt()
      if target notin @[GL_ARRAY_BUFFER.int, GL_ELEMENT_ARRAY_BUFFER.int]:
        raise newException(Exception, &"Invalid bufferView target {target}")

    result.bufferViews.add(bufferView)

  if jsonRoot.hasKey("textures"):
    for entry in jsonRoot["textures"]:
      var texture = Texture()
      texture.source = entry["source"].getInt()

      if entry.hasKey("sampler"):
        texture.sampler = entry["sampler"].getInt()
      else:
        texture.sampler = -1

      result.textures.add(texture)

  if jsonRoot.hasKey("images"):
    for entry in jsonRoot["images"]:
      var image: Image
      if entry.hasKey("uri"):
        let uri = entry["uri"].getStr()
        if uri.startsWith("data:image/png"):
          image = decodeImage(decode(uri.split(',')[1]))
        elif uri.endsWith(".png"):
          image = readImage(joinPath(modelDir, uri))
        else:
          raise newException(Exception, &"Unsupported file extension {uri}")
      elif entry.hasKey("bufferView"):
        let
          bufferViewIndex = entry["bufferView"].getInt()
          bv = result.bufferViews[bufferViewIndex]
          ib = result.buffers[bv.buffer]
          imageData = ib[bv.byteOffset ..< bv.byteOffset + bv.byteLength]
        image = decodeImage(imageData)
      else:
        raise newException(Exception, "Unsupported image type")

      result.images.add(image)

  if jsonRoot.hasKey("samplers"):
    for entry in jsonRoot["samplers"]:
      var sampler = Sampler()

      if entry.hasKey("magFilter"):
        sampler.magFilter = entry["magFilter"].getInt().GLint
      else:
        sampler.magFilter = GL_LINEAR

      if entry.hasKey("minFilter"):
        sampler.minFilter = entry["minFilter"].getInt().GLint
      else:
        sampler.minFilter = GL_LINEAR_MIPMAP_LINEAR

      if entry.hasKey("wrapS"):
        sampler.wrapS = entry["wrapS"].getInt().GLint
      else:
        sampler.wrapS = GL_REPEAT

      if entry.hasKey("wrapT"):
        sampler.wrapT = entry["wrapT"].getInt().GLint
      else:
        sampler.wrapT = GL_REPEAT

      result.samplers.add(sampler)

  if jsonRoot.hasKey("materials"):
    for entry in jsonRoot["materials"]:
      var material = Material()
      material.name = entry{"name"}.getStr()

      if entry.hasKey("pbrMetallicRoughness"):
        let pbrMetallicRoughness = entry["pbrMetallicRoughness"]
        material.pbrMetallicRoughness.apply = true
        if pbrMetallicRoughness.hasKey("baseColorTexture"):
          let baseColorTexture = pbrMetallicRoughness["baseColorTexture"]
          material.pbrMetallicRoughness.baseColorTexture.index =
            baseColorTexture["index"].getInt()
        else:
          material.pbrMetallicRoughness.baseColorTexture.index = -1

      result.materials.add(material)

  if jsonRoot.hasKey("animations"):
    for entry in jsonRoot["animations"]:
      var animation = Animation()

      for entry in entry["samplers"]:
        var animationSampler = AnimationSampler()
        animationSampler.input = entry["input"].getInt()
        animationSampler.output = entry["output"].getInt()

        let interpolation = entry["interpolation"].getStr()
        case interpolation:
          of "LINEAR":
            animationSampler.interpolation = iLinear
          of "STEP":
            animationSampler.interpolation = iStep
          of "CUBICSPLINE":
            animationSampler.interpolation = iCubicSpline
          else:
            raise newException(
              Exception,
              &"Unsupported animation sampler interpolation {interpolation}"
            )

        animation.samplers.add(animationSampler)

      for entry in entry["channels"]:
        var animationChannel = AnimationChannel()
        animationChannel.sampler = entry["sampler"].getInt()
        animationChannel.target.node = entry["target"]["node"].getInt()

        let path = entry["target"]["path"].getStr()
        case path:
          of "translation":
            animationChannel.target.path = pTranslation
          of "rotation":
            animationChannel.target.path = pRotation
          of "scale":
            animationChannel.target.path = pScale
          of "weights":
            animationChannel.target.path = pWeights
          else:
            raise newException(
              Exception,
              &"Unsupported animation channel path {path}"
            )

        animation.channels.add(animationChannel)

      result.animations.add(animation)

  for entry in jsonRoot["accessors"]:
    var accessor = Accessor()
    accessor.bufferView = entry["bufferView"].getInt()
    accessor.byteOffset = entry{"byteOffset"}.getInt()
    accessor.count = entry["count"].getInt()
    accessor.componentType = entry["componentType"].getInt().GLenum

    let accessorKind = entry["type"].getStr()
    case accessorKind:
      of "SCALAR":
        accessor.kind = atSCALAR
      of "VEC2":
        accessor.kind = atVEC2
      of "VEC3":
        accessor.kind = atVEC3
      of "VEC4":
        accessor.kind = atVEC4
      of "MAT2":
        accessor.kind = atMAT2
      of "MAT3":
        accessor.kind = atMAT3
      of "MAT4":
        accessor.kind = atMAT4
      else:
        raise newException(
          Exception,
          &"Invalid accessor type {accessorKind}"
        )

    result.accessors.add(accessor)

  for entry in jsonRoot["meshes"]:
    var mesh = Mesh()
    mesh.name = entry{"name"}.getStr()

    for entry in entry["primitives"]:
      var
        primitive = Primitive()
        attributes = entry["attributes"]

      if attributes.hasKey("POSITION"):
        primitive.attributes.position = attributes["POSITION"].getInt()
      else:
        primitive.attributes.position = -1

      if attributes.hasKey("NORMAL"):
        primitive.attributes.normal = attributes["NORMAL"].getInt()
      else:
        primitive.attributes.normal = -1

      if attributes.hasKey("COLOR_0"):
        primitive.attributes.color0 = attributes["COLOR_0"].getInt()
      else:
        primitive.attributes.color0 = -1

      if attributes.hasKey("TEXCOORD_0"):
        primitive.attributes.texcoord0 = attributes["TEXCOORD_0"].getInt()
      else:
        primitive.attributes.texcoord0 = -1

      if entry.hasKey("indices"):
        primitive.indices = entry["indices"].getInt()
      else:
        primitive.indices = -1

      if entry.hasKey("material"):
        primitive.material = entry["material"].getInt()
      else:
        primitive.material = -1

      if entry.hasKey("mode"):
        primitive.mode = entry["mode"].getInt().GLenum
      else:
        primitive.mode = GL_TRIANGLES

      result.primitives.add(primitive)
      mesh.primitives.add(len(result.primitives) - 1)

    result.meshes.add(mesh)

  for entry in jsonRoot["nodes"]:
    var node = Node()
    node.name = entry{"name"}.getStr()

    if entry.hasKey("children"):
      for child in entry["children"]:
        node.kids.add(child.getInt())

    if entry.hasKey("mesh"):
      node.mesh = entry["mesh"].getInt()
    else:
      node.mesh = -1

    if entry.hasKey("matrix"):
      node.applyMatrix = true

      let values = entry["matrix"]
      assert len(values) == 16
      for i in 0 ..< 4:
        for j in 0 ..< 4:
          node.matrix[i, j] = values[j * 4 + i].getFloat()

    if entry.hasKey("rotation"):
      let values = entry["rotation"]
      assert len(values) == 4
      node.rotation.x = values[0].getFloat()
      node.rotation.y = values[1].getFloat()
      node.rotation.z = values[2].getFloat()
      node.rotation.w = values[3].getFloat()
    else:
      node.rotation.w = 1

    if entry.hasKey("translation"):
      let values = entry["translation"]
      assert len(values) == 3
      node.translation.x = values[0].getFloat()
      node.translation.y = values[1].getFloat()
      node.translation.z = values[2].getFloat()

    if entry.hasKey("scale"):
      let values = entry["scale"]
      assert len(values) == 3
      node.scale.x = values[0].getFloat()
      node.scale.y = values[1].getFloat()
      node.scale.z = values[2].getFloat()
    else:
      node.scale.x = 1
      node.scale.y = 1
      node.scale.z = 1

    result.nodes.add(node)

  for entry in jsonRoot["scenes"]:
    var scene = Scene()
    for node in entry["nodes"]:
      scene.nodes.add(node.getInt())
    result.scenes.add(scene)

  result.scene = jsonRoot["scene"].getInt()

proc loadModelJsonFile*(file: string): Model =
  result = Model()
  let
    jsonRoot = parseJson(readFile(file))
    modelDir = splitPath(file)[0]

  return loadModelJson(jsonRoot, modelDir=modelDir)

proc loadModelBinaryFile*(file: string): Model =
  let
    data = string(readFile(file))
    magic = data.readUint32(0)
    version = data.readUint32(4)
    length = data.readUint32(8)

  doAssert magic == 0x46546C67
  doAssert version == 2
  doAssert length.int == data.len

  var
    i = 12
    jsonData: string
    buffers: seq[string]
  while i < data.len:
    var
      chunkLength = data.readUint32(i)
      chunkType = data.readUint32(i+4)
      chunkData = data.readStr(i+8, chunkLength.int)
      isJson = chunkType == 0x4E4F534A
    i += 8 + chunkLength.int
    if isJson:
      jsonData = chunkData
    else:
      buffers.add(chunkData)

  loadModelJson(parseJson(jsonData), buffers=buffers)

proc loadModel*(file: string): Model =
  echo &"Loading {file}"
  if file.endsWith(".glb"):
    loadModelBinaryFile(file)
  else:
    loadModelJsonFile(file)
