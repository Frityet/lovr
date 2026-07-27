-- Run one kernel from the repository root with LuaJIT's machine-code dump:
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/vector_quaternion_jit.lua vector
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/vector_quaternion_jit.lua quaternion
--   ./deps/luajit/src/luajit -jdump=im notes/benchmarks/vector_quaternion_jit.lua rotate

dofile('src/api/l_math.lua')
jit.opt.start('hotloop=10', 'hotexit=2')

local kernels = {}

function kernels.vector(n)
  local a = vector(1, 2, 3)
  local b = vector(.25, -.5, .75)
  for _ = 1, n do
    a = (a + b) * .999999
  end
  return a
end

function kernels.quaternion(n)
  local q = quaternion.identity
  local r = quaternion.pack(.5, -.5, .5, .5)
  for _ = 1, n do
    q = q * r
  end
  return q
end

function kernels.rotate(n)
  local q = quaternion.pack(.5, -.5, .5, .5)
  local v = vector(1, 2, 3)
  for _ = 1, n do
    v = q * v
  end
  return v
end

local name = assert(arg[1], 'expected vector, quaternion, or rotate')
local kernel = assert(kernels[name], 'unknown kernel: ' .. name)
local result = kernel(1000)
io.stderr:write(name, ': ', tostring(result), '\n')
