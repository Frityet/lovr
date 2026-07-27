-- Run from the repository root with:
--   ./build/bin/lovr notes/benchmarks/mat4_bulk 1024 1000

local clock = os.clock

local function measure(name, fn, iterations, items)
  fn(10)
  local best = math.huge
  local result
  for _ = 1, 5 do
    collectgarbage()
    local start = clock()
    result = fn(iterations)
    best = math.min(best, clock() - start)
  end
  print(('%-28s %8.2f ns/item  result=%g'):format(
    name,
    best * 1e9 / iterations / items,
    result or 0
  ))
  return best
end

function lovr.load()
  local count = tonumber(arg[1]) or 1024
  local iterations = tonumber(arg[2]) or 1000
  local matrices, vectors = {}, {}
  local matrixOutput, vectorOutput = {}, {}
  local transform = mat4():translate(.25, -.5, .75)

  for i = 1, count do
    matrices[i] = mat4()
      :translate(i * .01, i * .02, i * .03)
      :rotate(i * .001, 0, 1, 0)
      :scale(1 + i * .0001)
    vectors[i] = vector(i, -i, i * .5)
  end

  local matrixArray = mat4.array(count, matrices)
  local vectorArray = vector.array(count, vectors)
  local matrixArrayOutput = mat4.array(count)
  local vectorArrayOutput = vector.array(count)
  local matrixBuffer = lovr.graphics.newBuffer('mat4', count)
  local vectorBuffer = lovr.graphics.newBuffer('vec3', count)

  measure('table Mat4 compose', function(n)
    for _ = 1, n do
      for i = 1, count do matrixOutput[i] = matrices[i] * transform end
    end
    return matrixOutput[1][1]
  end, iterations, count)

  measure('packed Mat4 compose', function(n)
    for _ = 1, n do
      mat4.multiplyArray(matrixArray, transform, matrixArrayOutput)
    end
    return matrixArrayOutput[1][1]
  end, iterations, count)

  measure('table point transform', function(n)
    for _ = 1, n do
      for i = 1, count do vectorOutput[i] = transform * vectors[i] end
    end
    return vectorOutput[1].x
  end, iterations, count)

  measure('packed point transform', function(n)
    for _ = 1, n do
      mat4.transformPoints(transform, vectorArray, vectorArrayOutput)
    end
    return vectorArrayOutput[1].x
  end, iterations, count)

  measure('table Mat4 upload', function(n)
    for _ = 1, n do matrixBuffer:setData(matrices) end
  end, iterations, count)

  measure('packed Mat4 upload', function(n)
    for _ = 1, n do matrixBuffer:setData(matrixArray) end
  end, iterations, count)

  measure('table vector upload', function(n)
    for _ = 1, n do vectorBuffer:setData(vectors) end
  end, iterations, count)

  measure('packed vector upload', function(n)
    for _ = 1, n do vectorBuffer:setData(vectorArray) end
  end, iterations, count)

  local nodes, roots = {}, {}
  for i = 1, count do
    nodes[i] = '{}'
    roots[i] = tostring(i - 1)
  end

  local blob = lovr.data.newBlob(([[{
    "asset": { "version": "2.0" },
    "nodes": [%s],
    "scenes": [{ "nodes": [%s] }],
    "scene": 0
  }]]):format(table.concat(nodes, ','), table.concat(roots, ',')), 'nodes.gltf')
  local model = lovr.graphics.newModel(lovr.data.newModelData(blob))

  measure('loop model set', function(n)
    for _ = 1, n do
      for i = 1, count do model:setNodeTransform(i, matrixArray[i]) end
    end
    return matrixArray[1][13]
  end, iterations, count)

  measure('packed model set', function(n)
    for _ = 1, n do model:setNodeTransforms(matrixArray) end
    return matrixArray[1][13]
  end, iterations, count)

  measure('loop model get', function(n)
    local result = 0
    for _ = 1, n do
      for i = 1, count do result = result + model:getNodeTransform(i) end
    end
    return result
  end, iterations, count)

  measure('packed model get', function(n)
    local result = 0
    for _ = 1, n do
      model:getNodeTransforms(matrixArrayOutput)
      result = result + matrixArrayOutput[1][13]
    end
    return result
  end, iterations, count)

  lovr.event.quit()
end
