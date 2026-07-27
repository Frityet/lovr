-- Run from the repository root with:
--   ./build/bin/lovr notes/benchmarks/mat4.lua 5000000

local clock = os.clock
local native = debug.getregistry().Mat4

local transform = mat4(
  .999, 0, 0, 0,
  0, .999, 0, 0,
  0, 0, .999, 0,
  .001, -.002, .003, 1
)

local function nativeMul(n)
  local value = vector(1, 2, 3)
  for _ = 1, n do
    value = native.mul(transform, value)
  end
  return value.x + value.y + value.z
end

local function simdMul(n)
  local value = vector(1, 2, 3)
  for _ = 1, n do
    value = transform:mul(value)
  end
  return value.x + value.y + value.z
end

local function simdPoint(n)
  local value = vector(1, 2, 3)
  for _ = 1, n do
    value = transform * value
  end
  return value.x + value.y + value.z
end

local composition = mat4(
  1, 0, 0, 0,
  0, 1, 0, 0,
  0, 0, 1, 0,
  .001, -.002, .003, 1
)

local function nativeCompose(n)
  local value = mat4()
  for _ = 1, n do
    native.mul(value, composition)
  end
  return value[1] + value[13]
end

local function simdCompose(n)
  local value = mat4()
  for _ = 1, n do
    value:mul(composition)
  end
  return value[1] + value[13]
end

local function simdComposeOperator(n)
  local value = mat4()
  for _ = 1, n do
    value = value * composition
  end
  return value[1] + value[13]
end

local rotation = quaternion(.0001, .2, .7, -.4)

local function nativeRotate(n)
  local value = mat4()
  for _ = 1, n do
    native.rotate(value, rotation)
  end
  return value[1] + value[6] + value[11]
end

local function simdRotate(n)
  local value = mat4()
  for _ = 1, n do
    value:rotate(rotation)
  end
  return value[1] + value[6] + value[11]
end

local function matrixValues()
  return mat4(
    1, 2, 3, 0,
    0, 1, 4, 0,
    5, 6, 0, 0,
    7, 8, 9, 1
  )
end

local function nativeTranspose(n)
  local value = matrixValues()
  for _ = 1, n do native.transpose(value) end
  return value[2] + value[5]
end

local function simdTranspose(n)
  local value = matrixValues()
  for _ = 1, n do value:transpose() end
  return value[2] + value[5]
end

local function nativeInvert(n)
  local value = matrixValues()
  for _ = 1, n do native.invert(value) end
  return value[1] + value[16]
end

local function ffiInvert(n)
  local value = matrixValues()
  for _ = 1, n do value:invert() end
  return value[1] + value[16]
end

local function measure(name, fn, iterations)
  fn(10000)
  local best = math.huge
  local result
  for _ = 1, 7 do
    collectgarbage()
    local start = clock()
    result = fn(iterations)
    best = math.min(best, clock() - start)
  end
  print(('%-24s %8.2f ns/op  result=%g'):format(
    name,
    best * 1e9 / iterations,
    result
  ))
end

function lovr.load()
  local iterations = tonumber(arg[1]) or 5000000
  print(('iterations: %d'):format(iterations))
  measure('Lua C API :mul', nativeMul, iterations)
  measure('SIMD Lua :mul', simdMul, iterations)
  measure('SIMD Lua point operator', simdPoint, iterations)
  measure('Lua C API compose', nativeCompose, iterations)
  measure('SIMD Lua compose', simdCompose, iterations)
  measure('SIMD Lua compose op', simdComposeOperator, iterations)
  measure('Lua C API rotate', nativeRotate, iterations)
  measure('SIMD Lua rotate', simdRotate, iterations)
  measure('Lua C API transpose', nativeTranspose, iterations)
  measure('SIMD Lua transpose', simdTranspose, iterations)
  measure('Lua C API invert', nativeInvert, iterations)
  measure('FFI C invert', ffiInvert, iterations)
  lovr.event.quit()
end
