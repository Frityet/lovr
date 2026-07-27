-- Inspect one Mat4 kernel from the repository root:
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua mul
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua point
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua direction
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua compose
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua compose_mutating
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua compose_output
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua orientation
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua multiply_array
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua transform_points
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua transpose
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua rotate

dofile('src/api/l_math.lua')
jit.opt.start('hotloop=10', 'hotexit=2')

local kernels = {}

function kernels.mul(n)
  local matrix = mat4(
    .999, 0, 0, 0,
    0, .999, 0, 0,
    0, 0, .999, 0,
    .001, -.002, .003, 1
  )
  local point = vector(1, 2, 3)
  for _ = 1, n do
    point = matrix:mul(point)
  end
  return point
end

function kernels.point(n)
  local matrix = mat4(
    .999, 0, 0, 0,
    0, .999, 0, 0,
    0, 0, .999, 0,
    .001, -.002, .003, 1
  )
  local point = vector(1, 2, 3)
  for _ = 1, n do
    point = matrix * point
  end
  return point
end

function kernels.direction(n)
  local matrix = mat4(
    .999, 0, 0, 0,
    0, .999, 0, 0,
    0, 0, .999, 0,
    .001, -.002, .003, 1
  )
  local direction = vector(1, 2, 3)
  for _ = 1, n do
    direction = matrix:mul(direction, 0)
  end
  return direction
end

function kernels.compose(n)
  local matrix = mat4()
  local transform = mat4(
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    .001, -.002, .003, 1
  )
  for _ = 1, n do
    matrix = matrix * transform
  end
  return matrix
end

function kernels.compose_mutating(n)
  local matrix = mat4()
  local transform = mat4(
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    .001, -.002, .003, 1
  )
  for _ = 1, n do
    matrix:mul(transform)
  end
  return matrix
end

function kernels.compose_output(n)
  local matrix = mat4()
  local output = mat4()
  local transform = mat4(
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    .001, -.002, .003, 1
  )
  for _ = 1, n do
    mat4.multiply(matrix, transform, output)
    matrix, output = output, matrix
  end
  return matrix
end

function kernels.orientation(n)
  local matrix = mat4()
    :translate(1, 2, 3)
    :rotate(quaternion(1.1, .2, .7, -.4))
    :scale(2, 3, 4)
  local result = 0
  for _ = 1, n do
    local angle, x, y, z = matrix:getOrientation()
    result = result + angle + x + y + z
  end
  return result
end

function kernels.multiply_array(n)
  local count = 64
  local input = mat4.array(count, mat4():translate(.001, -.002, .003))
  local output = mat4.array(count)
  local transform = mat4():scale(.999)
  for _ = 1, n do
    mat4.multiplyArray(input, transform, output)
    input, output = output, input
  end
  return input.data[0].columns[0][0]
end

function kernels.transform_points(n)
  local count = 64
  local input = vector.array(count, vector(1, 2, 3))
  local output = vector.array(count)
  local transform = mat4():translate(.001, -.002, .003)
  for _ = 1, n do
    mat4.transformPoints(transform, input, output)
    input, output = output, input
  end
  return input.data[0][0]
end

function kernels.transpose(n)
  local matrix = mat4(
    1, 2, 3, 4,
    5, 6, 7, 8,
    9, 10, 11, 12,
    13, 14, 15, 16
  )
  for _ = 1, n do
    matrix:transpose()
  end
  return matrix
end

function kernels.rotate(n)
  local matrix = mat4()
  local rotation = quaternion(math.pi / 2, 0, 0, 1)
  for _ = 1, n do
    matrix:rotate(rotation)
  end
  return matrix
end

local name = assert(
  arg[1],
  'expected mul, point, direction, compose, compose_mutating, compose_output, ' ..
  'orientation, multiply_array, transform_points, transpose, or rotate'
)
local kernel = assert(kernels[name], 'unknown kernel: ' .. name)
local result = kernel(1000)
io.stderr:write(name, ': ', tostring(result), '\n')
