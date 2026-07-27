-- Run from the repository root with:
--   ./deps/luajit/src/luajit notes/benchmarks/vector_quaternion.lua
--
-- This compares the old table representation's hot loop shape with the SIMD
-- representation.  The kernels carry their result around the loop, preventing
-- LuaJIT from hoisting the work out of the measurement.

dofile('src/api/l_math.lua')

local clock = os.clock
local min = math.min

local function tableVector(x, y, z)
  return { x = x, y = y, z = z }
end

local function tableQuaternion(x, y, z, w)
  return { x = x, y = y, z = z, w = w }
end

local function tableVectorAffine(n)
  local a = tableVector(1, 2, 3)
  local b = tableVector(.25, -.5, .75)
  local scale = .999999

  for _ = 1, n do
    a = tableVector(
      (a.x + b.x) * scale,
      (a.y + b.y) * scale,
      (a.z + b.z) * scale
    )
  end

  return a.x + a.y + a.z
end

local function simdVectorAffine(n)
  local a = vector(1, 2, 3)
  local b = vector(.25, -.5, .75)
  local scale = .999999

  for _ = 1, n do
    a = (a + b) * scale
  end

  return a.x + a.y + a.z
end

local function tableQuaternionMultiply(n)
  local q = tableQuaternion(0, 0, 0, 1)
  local r = tableQuaternion(.5, -.5, .5, .5)

  for _ = 1, n do
    q = tableQuaternion(
      q.x * r.w + q.w * r.x + q.y * r.z - q.z * r.y,
      q.y * r.w + q.w * r.y + q.z * r.x - q.x * r.z,
      q.z * r.w + q.w * r.z + q.x * r.y - q.y * r.x,
      q.w * r.w - q.x * r.x - q.y * r.y - q.z * r.z
    )
  end

  return q.x + q.y + q.z + q.w
end

local function simdQuaternionMultiply(n)
  local q = quaternion.identity
  local r = quaternion.pack(.5, -.5, .5, .5)

  for _ = 1, n do
    q = q * r
  end

  return q.x + q.y + q.z + q.w
end

local function tableQuaternionRotate(n)
  local q = tableQuaternion(.5, -.5, .5, .5)
  local v = tableVector(1, 2, 3)

  for _ = 1, n do
    local ux, uy, uz = q.x, q.y, q.z
    local cx = q.y * v.z - q.z * v.y
    local cy = q.z * v.x - q.x * v.z
    local cz = q.x * v.y - q.y * v.x
    local uu = ux * ux + uy * uy + uz * uz
    local uv = ux * v.x + uy * v.y + uz * v.z
    local s = q.w * q.w - uu
    v = tableVector(
      v.x * s + ux * 2 * uv + cx * 2 * q.w,
      v.y * s + uy * 2 * uv + cy * 2 * q.w,
      v.z * s + uz * 2 * uv + cz * 2 * q.w
    )
  end

  return v.x + v.y + v.z
end

local function simdQuaternionRotate(n)
  local q = quaternion.pack(.5, -.5, .5, .5)
  local v = vector(1, 2, 3)

  for _ = 1, n do
    v = q * v
  end

  return v.x + v.y + v.z
end

local function measure(name, fn, iterations)
  fn(10000)
  local best = math.huge
  local result

  for _ = 1, 5 do
    collectgarbage()
    local start = clock()
    result = fn(iterations)
    best = min(best, clock() - start)
  end

  return {
    name = name,
    seconds = best,
    nanoseconds = best * 1e9 / iterations,
    result = result
  }
end

local iterations = tonumber(arg[1]) or 1000000
local pairs = {
  {
    'vector affine',
    measure('table', tableVectorAffine, iterations),
    measure('SIMD', simdVectorAffine, iterations)
  },
  {
    'quaternion multiply',
    measure('table', tableQuaternionMultiply, iterations),
    measure('SIMD', simdQuaternionMultiply, iterations)
  },
  {
    'quaternion rotate vector',
    measure('table', tableQuaternionRotate, iterations),
    measure('SIMD', simdQuaternionRotate, iterations)
  }
}

print(('iterations: %d'):format(iterations))
for _, benchmark in ipairs(pairs) do
  local name, baseline, simdResult = unpack(benchmark)
  print(('\n%s'):format(name))
  print(('  table  %8.2f ns/op  result=%g'):format(baseline.nanoseconds, baseline.result))
  print(('  SIMD   %8.2f ns/op  result=%g'):format(simdResult.nanoseconds, simdResult.result))
  print(('  speedup %8.2fx'):format(baseline.seconds / simdResult.seconds))
end
