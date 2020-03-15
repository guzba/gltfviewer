import json, opengl, os, strformat, strutils, vmath

type
  BufferView = object
    buffer: int
    byteOffset, byteLength, byteStride: Natural

  Material = object
    name: string

  AccessorKind = enum
    atSCALAR, atVEC2, atVEC3, atVEC4, atMAT2, atMAT3, atMAT4

  Accessor = object
    bufferView: int
    byteOffset, count: Natural
    componentType: GLenum
    kind: AccessorKind
    bufferId: GLuint

  PrimativeAttributes = object
    position, normal, color0: int

  Primative = object
    attributes: PrimativeAttributes
    indices, material: int
    mode: GLenum
    vertexArrayId: GLuint

  Mesh = object
    name: string
    primatives: seq[Primative]

  Node = object
    name: string
    kids: seq[Natural]
    mesh: int
    applyMatrix: bool
    matrix: Mat4
    rotation: Vec4
    translation, scale: Vec3

  Scene* = ref object
    nodes: seq[Natural]

  Model* = ref object
    # All of the data that is indexed into
    buffers: seq[string]
    bufferViews: seq[BufferView]
    materials: seq[Material]
    accessors: seq[Accessor]
    meshes: seq[Mesh]
    nodes: seq[Node]
    scenes: seq[Scene]

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

proc draw(
  node: Node,
  model: Model,
  shader: GLuint,
  transform, view, proj: Mat4
) =
  var trs: Mat4
  if node.applyMatrix:
    trs = node.matrix * transform
  else:
    trs = translate(node.translation) * scale(node.scale) * transform

  for kid in node.kids:
    model.nodes[kid].draw(model, shader, trs, view, proj)

  if node.mesh < 0:
    return

  var modelUniform = glGetUniformLocation(shader, "model")
  var modelArray = trs.toFloat32()
  glUniformMatrix4fv(modelUniform, 1, GL_FALSE, modelArray[0].addr)

  var viewUniform = glGetUniformLocation(shader, "view")
  var viewArray = view.toFloat32()
  glUniformMatrix4fv(viewUniform, 1, GL_FALSE, viewArray[0].addr)

  var projUniform = glGetUniformLocation(shader, "proj")
  var projArray = proj.toFloat32()
  glUniformMatrix4fv(projUniform, 1, GL_FALSE, projArray[0].addr)

  for primative in model.meshes[node.mesh].primatives:
    let positionAccessor = model.accessors[primative.attributes.position]

    glBindVertexArray(primative.vertexArrayId)

    if primative.indices < 0:
      glDrawArrays(primative.mode, 0, positionAccessor.count.cint)
    else:
      let indicesAccessor = model.accessors[primative.indices]
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indicesAccessor.bufferId)
      glDrawElements(
        primative.mode,
        indicesAccessor.count.GLint,
        indicesAccessor.componentType,
        nil
      )

proc draw*(model: Model, shader: GLuint, view, proj: Mat4) =
  let scene = model.scenes[model.scene]
  for node in scene.nodes:
    model.nodes[node].draw(model, shader, identity(), view, proj)

proc bindBuffer(
  model: Model,
  accessorIndex: Natural,
  target: GLenum,
  vertexAttribIndex: int
) =
  let
    accessor = model.accessors[accessorIndex].addr
    bufferView = model.bufferViews[accessor.bufferView]
    byteOffset = accessor.byteOffset + bufferView.byteOffset
    byteLength = accessor.count *
        accessor.kind.componentCount() *
        accessor.componentType.size()

  glGenBuffers(1, accessor.bufferId.addr)
  glBindBuffer(GL_ARRAY_BUFFER, accessor.bufferId)
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

proc uploadToGpu*(model: Model) =
  for node in model.nodes:
    if node.mesh < 0:
      continue

    for primative in model.meshes[node.mesh].primatives.mitems:
      block:
        glGenVertexArrays(1, primative.vertexArrayId.addr)
        glBindVertexArray(primative.vertexArrayId)

        model.bindBuffer(primative.attributes.position, GL_ARRAY_BUFFER, 0)

      if primative.indices >= 0:
        model.bindBuffer(primative.indices, GL_ELEMENT_ARRAY_BUFFER, -1)
      if primative.attributes.color0 >= 0:
        model.bindBuffer(primative.attributes.color0, GL_ARRAY_BUFFER, 1)
      if primative.attributes.normal >= 0:
        model.bindBuffer(primative.attributes.normal, GL_ARRAY_BUFFER, 2)

proc clearFromGpu*(model: Model) =
  var bufferIds, vertexArrayIds: seq[GLuint]

  for accessor in model.accessors.mitems:
    bufferIds.add(accessor.bufferId)
    accessor.bufferId = 0

  for node in model.nodes:
    if node.mesh < 0:
      continue

    for primative in model.meshes[node.mesh].primatives.mitems:
      vertexArrayIds.add(primative.vertexArrayId)
      primative.vertexArrayId = 0

  glDeleteVertexArrays(len(vertexArrayIds).GLint, vertexArrayIds[0].addr)
  glDeleteBuffers(len(bufferIds).GLint, bufferIds[0].addr)

proc loadModel*(file: string): Model =
  result = Model()

  echo &"Loading {file}"
  let jsonRoot = parseJson(readFile(file))

  for entry in jsonRoot["buffers"]:
    let uri = entry["uri"].getStr()

    var data: string
    if uri.startsWith("data:"):
      discard
    else:
      data = readFile(joinPath(splitPath(file)[0], uri))

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

  if jsonRoot.hasKey("materials"):
    for entry in jsonRoot["materials"]:
      var material = Material()
      material.name = entry{"name"}.getStr()
      result.materials.add(material)

  for entry in jsonRoot["accessors"]:
    var accessor = Accessor()
    accessor.bufferView = entry["bufferView"].getInt()
    accessor.byteOffset = entry{"byteOffset"}.getInt()
    accessor.count = entry["count"].getInt()

    let componentType = entry["componentType"].getInt()
    case componentType:
      of 5120:
        accessor.componentType = cGL_BYTE
      of 5121:
        accessor.componentType = cGL_UNSIGNED_BYTE
      of 5122:
        accessor.componentType = cGL_SHORT
      of 5123:
        accessor.componentType = cGL_UNSIGNED_SHORT
      of 5125:
        accessor.componentType = GL_UNSIGNED_INT
      of 5126:
        accessor.componentType = cGL_FLOAT
      else:
        raise newException(
          Exception,
          &"Invalid accessor componentType {componentType}"
        )

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
        primative = Primative()
        attributes = entry["attributes"]

      if attributes.hasKey("POSITION"):
        primative.attributes.position = attributes["POSITION"].getInt()
      else:
        primative.attributes.position = -1

      if attributes.hasKey("NORMAL"):
        primative.attributes.normal = attributes["NORMAL"].getInt()
      else:
        primative.attributes.normal = -1

      if attributes.hasKey("COLOR_0"):
        primative.attributes.color0 = attributes["COLOR_0"].getInt()
      else:
        primative.attributes.color0 = -1

      if entry.hasKey("indices"):
        primative.indices = entry["indices"].getInt()
      else:
        primative.indices = -1

      if entry.hasKey("material"):
        primative.material = entry["material"].getInt()
      else:
        primative.material = -1

      if entry.hasKey("mode"):
        let mode = entry["mode"].getInt()
        case mode:
          of 0:
            primative.mode = GL_POINTS
          of 1:
            primative.mode = GL_LINES
          of 4:
            primative.mode = GL_TRIANGLES
          else:
            raise newException(
              Exception,
              &"Invalid primative mode {mode}"
            )
      else:
        primative.mode = GL_TRIANGLES

      mesh.primatives.add(primative)

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
      for i in 0..<16:
        node.matrix[i] = values[i].getFloat()

    if entry.hasKey("rotation"):
      let values = entry["rotation"]
      assert len(values) == 4
      node.rotation.x = values[0].getFloat()
      node.rotation.y = values[1].getFloat()
      node.rotation.z = values[2].getFloat()
      node.rotation.w = values[3].getFloat()
      echo "rotation will not be applied"
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
