-- Inspect one Mat4 kernel from the repository root:
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua mul
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua point
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua direction
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua compose
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/mat4_jit.lua compose_mutating
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
  'expected mul, point, direction, compose, compose_mutating, transpose, or rotate'
)
local kernel = assert(kernels[name], 'unknown kernel: ' .. name)
local result = kernel(1000)
io.stderr:write(name, ': ', tostring(result), '\n')
