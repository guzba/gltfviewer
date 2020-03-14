import json, opengl, os, strformat, strutils, vmath

type
  BufferView = object
    buffer: int
    byteOffset, byteLength, byteStride: Natural
    target: GLenum

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
    position, normal: int

  Primative = object
    attributes: PrimativeAttributes
    indices, material: int
    mode: GLenum
    number: Natural
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
    # All of the data that is indexed into
    buffers: seq[string]
    bufferViews: seq[BufferView]
    materials: seq[Material]
    accessors: seq[Accessor]
    meshes: seq[Mesh]
    nodes: seq[Node]

    # Scene properties
    rootNodes: seq[Natural]

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
  scene: Scene,
  shader: GLuint,
  transform, view, proj: Mat4
) =
  var trs: Mat4
  if node.applyMatrix:
    trs = transform * node.matrix
  else:
    trs = transform * translate(node.translation) * scale(node.scale)

  for kid in node.kids:
    scene.nodes[kid].draw(scene, shader, trs, view, proj)

  if node.mesh < 0:
    return

  var model = trs

  var modelUniform = glGetUniformLocation(shader, "model")
  var modelArray = model.toFloat32()
  glUniformMatrix4fv(modelUniform, 1, GL_FALSE, modelArray[0].addr)

  var viewUniform = glGetUniformLocation(shader, "view")
  var viewArray = view.toFloat32()
  glUniformMatrix4fv(viewUniform, 1, GL_FALSE, viewArray[0].addr)

  var projUniform = glGetUniformLocation(shader, "proj")
  var projArray = proj.toFloat32()
  glUniformMatrix4fv(projUniform, 1, GL_FALSE, projArray[0].addr)

  for primative in scene.meshes[node.mesh].primatives:
    let positionAccessor = scene.accessors[primative.attributes.position]

    glBindVertexArray(primative.vertexArrayId)

    if primative.indices < 0:
      glDrawArrays(primative.mode, 0, positionAccessor.count.cint)
    else:
      let indicesAccessor = scene.accessors[primative.indices]
      glBindBuffer(
        scene.bufferViews[indicesAccessor.bufferView].target,
        indicesAccessor.bufferId
      )
      glDrawElements(
        primative.mode,
        indicesAccessor.count.GLint,
        indicesAccessor.componentType,
        nil
      )

proc draw*(scene: Scene, shader: GLuint, view, proj: Mat4) =
  for index in scene.rootNodes:
    scene.nodes[index].draw(scene, shader, identity(), view, proj)

proc bindBuffer(scene: Scene, bufferView: BufferView, bufferId: GLuint) =
  glBindBuffer(bufferView.target, bufferId)
  glBufferData(
    bufferView.target,
    bufferView.byteLength,
    scene.buffers[bufferView.buffer][bufferView.byteOffset].addr,
    GL_STATIC_DRAW
  )

proc uploadToGpu*(scene: Scene) =
  for i, node in scene.nodes:
    if node.mesh < 0:
      continue

    for primative in scene.meshes[node.mesh].primatives.mitems:
      var positionAccessor = scene.accessors[primative.attributes.position].addr
      let positionBufferView = scene.bufferViews[positionAccessor.bufferView]
      glGenBuffers(1, positionAccessor.bufferId.addr)
      scene.bindBuffer(positionBufferView, positionAccessor.bufferId)

      if primative.indices >= 0:
        var indicesAccessor = scene.accessors[primative.indices].addr
        glGenBuffers(1, indicesAccessor.bufferId.addr)
        scene.bindBuffer(
          scene.bufferViews[indicesAccessor.bufferView],
          indicesAccessor.bufferId
        )

      glGenVertexArrays(1, primative.vertexArrayId.addr)
      glBindVertexArray(primative.vertexArrayId)
      glBindBuffer(
        positionBufferView.target,
        positionAccessor.bufferId
      )
      glVertexAttribPointer(
        0,
        positionAccessor.kind.componentCount().GLint,
        positionAccessor.componentType,
        GL_FALSE,
        positionBufferView.byteStride.GLint,
        nil
      )
      glEnableVertexAttribArray(0)

proc clearFromGpu*(scene: Scene) =
  var bufferIds, vertexArrayIds: seq[GLuint]

  for node in scene.nodes:
    if node.mesh < 0:
      continue

    for primative in scene.meshes[node.mesh].primatives.mitems:
      bufferIds.add(scene.accessors[primative.attributes.position].bufferId)
      scene.accessors[primative.attributes.position].bufferId = 0

      if primative.indices > 0:
        bufferIds.add(scene.accessors[primative.indices].bufferId)
        scene.accessors[primative.indices].bufferId = 0

      vertexArrayIds.add(primative.vertexArrayId)
      primative.vertexArrayId = 0

  glDeleteVertexArrays(len(vertexArrayIds).GLint, vertexArrayIds[0].addr)
  glDeleteBuffers(len(bufferIds).GLint, bufferIds[0].addr)

proc loadModel*(file: string): Scene =
  echo &"Loading {file}"
  let jsonRoot = parseJson(readFile(file))

  var scenes: seq[Scene]
  for entry in jsonRoot["scenes"]:
    var scene = Scene()
    for node in entry["nodes"]:
      scene.rootNodes.add(node.getInt())
    scenes.add(scene)

  result = scenes[jsonRoot["scene"].getInt()]

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
    bufferView.byteOffset = entry["byteOffset"].getInt()
    bufferView.byteLength = entry["byteLength"].getInt()
    bufferView.byteStride = entry{"byteStride"}.getInt()

    let target = entry["target"].getInt()
    case target:
      of 34962:
        bufferView.target = GL_ARRAY_BUFFER
      of 34963:
        bufferView.target = GL_ELEMENT_ARRAY_BUFFER
      else:
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
    accessor.byteOffset = entry["byteOffset"].getInt()
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

  var primativeCount = 0
  for entry in jsonRoot["meshes"]:
    var mesh = Mesh()
    mesh.name = entry{"name"}.getStr()

    for entry in entry["primitives"]:
      var
        primative = Primative()
        attributes = entry["attributes"]

      primative.number = primativeCount

      if attributes.hasKey("POSITION"):
        primative.attributes.position = attributes["POSITION"].getInt()
      else:
        primative.attributes.position = -1

      if attributes.hasKey("NORMAL"):
        primative.attributes.normal = attributes["NORMAL"].getInt()
      else:
        primative.attributes.normal = -1

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
      inc(primativeCount)

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
