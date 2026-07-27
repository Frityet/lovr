local ffi = require 'ffi'
local simd = require 'ffi.simd'
local abs, sqrt, sin, cos, asin, acos, atan2 =
  math.abs, math.sqrt, math.sin, math.cos, math.asin, math.acos, math.atan2

ffi.cdef[[
typedef float lovr_vector4 __attribute__((vector_size(16)));
typedef const float lovr_quaternion4 __attribute__((vector_size(16)));
typedef volatile float lovr_raw4 __attribute__((vector_size(16)));
typedef uint32_t lovr_bits4 __attribute__((vector_size(16)));
]]

local vector_ctype
local quaternion_ctype
local raw_ctype = ffi.typeof('lovr_raw4')
local bits_ctype = ffi.typeof('lovr_bits4')
local conjugate_mask
local euler_sign
local quaternion_x_sign
local quaternion_y_sign
local quaternion_z_sign
local muladd = simd.features().fma and simd.fma or function(a, b, c)
  return a * b + c
end

vector = {}
vector.__index = vector

local function vector_raw(v)
  return type(v) == 'number' and v or simd.bitcast(raw_ctype, v)
end

local function vector_result(v)
  return simd.bitcast(vector_ctype, simd.insert(v, 3, 0))
end

local function vector_cast(v)
  return simd.bitcast(vector_ctype, v)
end

local function dot3(a, b)
  return simd.hsum(vector_raw(a) * vector_raw(b))
end

local function cross3raw(a, b)
  a, b = vector_raw(a), vector_raw(b)
  local ayzx = simd.shuffle(a, 1, 2, 0, 3)
  local byzx = simd.shuffle(b, 1, 2, 0, 3)
  local zxy = a * byzx - ayzx * b
  return simd.shuffle(zxy, 1, 2, 0, 3)
end

local function cross3(a, b)
  return vector_cast(cross3raw(a, b))
end

local function quaternion_raw(q)
  return simd.bitcast(raw_ctype, q)
end

local function quaternion_pack(v)
  return simd.bitcast(quaternion_ctype, v)
end

function vector.pack(x, y, z)
  return vector_ctype(x, y or x, z or (y and 0 or x), 0)
end

function vector.unpack(v)
  return v[0], v[1], v[2]
end

function vector.length(v)
  return sqrt(dot3(v, v))
end

function vector.normalize(v)
  local length = sqrt(dot3(v, v))
  return length == 0 and v or vector_cast(vector_raw(v) / length)
end

function vector.distance(v, u)
  local d = vector_raw(v) - vector_raw(u)
  return sqrt(dot3(d, d))
end

function vector.cross(v, u)
  return cross3(v, u)
end

function vector.dot(v, u)
  return dot3(v, u)
end

function vector.angle(v, u, axis)
  local cross = cross3(v, u)
  local angle = atan2(sqrt(dot3(cross, cross)), dot3(v, u))

  if axis and dot3(cross, axis) < 0 then
    angle = -angle
  end

  return angle
end

function vector.lerp(v, u, t)
  local a, b = vector_raw(v), vector_raw(u)
  return vector_cast(a + (b - a) * t)
end

-- Deprecated
function vector.rotate(v, q)
  return q * v
end

function vector.__tostring(v)
  return ('%f, %f, %f'):format(v[0], v[1], v[2])
end

function vector.__add(a, b)
  local result = vector_raw(a) + vector_raw(b)
  if type(a) == 'number' or type(b) == 'number' then
    return vector_result(result)
  end
  return vector_cast(result)
end

function vector.__sub(a, b)
  local result = vector_raw(a) - vector_raw(b)
  if type(a) == 'number' or type(b) == 'number' then
    return vector_result(result)
  end
  return vector_cast(result)
end

function vector.__mul(a, b)
  return vector_cast(vector_raw(a) * vector_raw(b))
end

function vector.__div(a, b)
  return vector_result(vector_raw(a) / vector_raw(b))
end

function vector.__unm(v)
  return vector_cast(-vector_raw(v))
end

local vector_fields = { x = 0, y = 1, z = 2 }

local function vector_index(v, key)
  local lane = vector_fields[key]
  return lane and v[lane] or vector[key]
end

vector_ctype = ffi.metatype('lovr_vector4', {
  __index = vector_index,
  __add = vector.__add,
  __sub = vector.__sub,
  __mul = vector.__mul,
  __div = vector.__div,
  __unm = vector.__unm,
  __tostring = vector.__tostring
})

conjugate_mask = raw_ctype(-1, -1, -1, 1)
euler_sign = raw_ctype(1, -1, -1, 1)
quaternion_x_sign = simd.bitcast(raw_ctype, bits_ctype(0, 0x80000000, 0, 0x80000000))
quaternion_y_sign = simd.bitcast(raw_ctype, bits_ctype(0, 0, 0x80000000, 0x80000000))
quaternion_z_sign = simd.bitcast(raw_ctype, bits_ctype(0x80000000, 0, 0, 0x80000000))

setmetatable(vector, {
  __call = function(_, x, y, z)
    x = x or 0
    if type(x) == 'table' then return x end -- Deprecated
    if type(x) == 'cdata' and ffi.typeof(x) == vector_ctype then return x end
    assert(type(x) == 'number', 'vector components must be numbers')
    return vector_ctype(x, y or x, z or (y and 0 or x), 0)
  end
})

vector.ctype = vector_ctype
vector.zero = vector(0, 0, 0)
vector.one = vector(1, 1, 1)
vector.left = vector(-1, 0, 0)
vector.right = vector(1, 0, 0)
vector.up = vector(0, 1, 0)
vector.down = vector(0, -1, 0)
vector.forward = vector(0, 0, -1)
vector.backward = vector(0, 0, 1)
vector.back = vector(0, 0, 1)

---

quaternion = {}
quaternion.__index = quaternion

function quaternion.pack(x, y, z, w)
  return quaternion_ctype(x, y, z, w)
end

function quaternion.unpack(q)
  return q[0], q[1], q[2], q[3]
end

function quaternion.conjugate(q)
  return quaternion_pack(quaternion_raw(q) * conjugate_mask)
end

function quaternion.angleaxis(angle, ax, ay, az)
  assert(type(angle) == 'number', 'quaternion angle must be a number')
  assert(
    type(ax) == 'number' and type(ay) == 'number' and type(az) == 'number',
    'quaternion axis components must be numbers'
  )

  local s = sin(angle * .5)
  local c = cos(angle * .5)
  local axis = raw_ctype(ax, ay, az, 0)
  local length = sqrt(dot3(axis, axis))

  if length > 0 then
    return quaternion_pack(simd.insert(axis * (s / length), 3, c))
  else
    return quaternion_ctype(0, 0, 0, 1)
  end
end

function quaternion.toangleaxis(q)
  local qv = quaternion_raw(q)
  local s = sqrt(1 - qv[3] * qv[3])
  s = s < 1e-6 and 1 or 1 / s
  local axis = qv * s
  return 2 * acos(qv[3]), axis[0], axis[1], axis[2]
end

function quaternion.euler(x, y, z)
  local cx, sx = cos(x * .5), sin(x * .5)
  local cy, sy = cos(y * .5), sin(y * .5)
  local cz, sz = cos(z * .5), sin(z * .5)
  local a = raw_ctype(
    cy * sx * cz,
    sy * cx * cz,
    cy * cx * sz,
    cy * cx * cz
  )
  local b = raw_ctype(
    sy * cx * sz,
    cy * sx * sz,
    sy * sx * cz,
    sy * sx * sz
  )
  return quaternion_pack(a + b * euler_sign)
end

function quaternion.toeuler(q)
  local qv = quaternion_raw(q)
  local x, y, z, w = qv[0], qv[1], qv[2], qv[3]
  local unit = simd.hsum(qv * qv)
  local test = x * w - y * z
  local ax, ay, az

  if test > (.5 - 1e-6) * unit then
    ax = math.pi / 2
    ay = 2 * atan2(y, x)
    az = 0
  elseif test < -(.5 - 1e-6) * unit then
    ax = -math.pi / 2
    ay = -2 * atan2(y, x)
    az = 0
  else
    ax = asin(2 * (w * x - y * z))
    ay = atan2(2 * w * y + 2 * z * x, 1 - 2 * (x * x + y * y))
    az = atan2(2 * w * z + 2 * x * y, 1 - 2 * (z * z + x * x))
  end

  return ax, ay, az
end

function quaternion.between(a, b)
  local dot = dot3(a, b)

  if dot > .99999 or dot < -.99999 then
    return quaternion.identity
  end

  local result = simd.insert(cross3raw(a, b), 3, 1 + dot)
  return quaternion_pack(result / sqrt(simd.hsum(result * result)))
end

function quaternion.lookdir(dir, up)
  up = up or vector.up

  local forward = -vector_raw(dir)
  local length = sqrt(dot3(forward, forward))

  if length == 0 then
    return quaternion.identity
  end

  forward = simd.insert(forward / length, 3, 0)

  local right = cross3raw(up, forward)
  length = sqrt(dot3(right, right))

  if length == 0 then
    if abs(forward[0]) < .9 then
      right = raw_ctype(0, forward[2], -forward[1], 0)
    else
      right = raw_ctype(forward[2], 0, -forward[0], 0)
    end

    length = sqrt(dot3(right, right))
  end

  right = simd.insert(right / length, 3, 0)
  local upward = cross3raw(forward, right)

  local m00, m01, m02 = right[0], right[1], right[2]
  local m10, m11, m12 = upward[0], upward[1], upward[2]
  local m20, m21, m22 = forward[0], forward[1], forward[2]
  local x, y, z, w

  if m22 < 0 then
    if m00 > m11 then
      local t = 1 + m00 - m11 - m22
      local s = .5 / sqrt(t)
      x = t * s
      y = (m01 + m10) * s
      z = (m20 + m02) * s
      w = (m12 - m21) * s
    else
      local t = 1 - m00 + m11 - m22
      local s = .5 / sqrt(t)
      x = (m01 + m10) * s
      y = t * s
      z = (m12 + m21) * s
      w = (m20 - m02) * s
    end
  else
    if m00 < -m11 then
      local t = 1 - m00 - m11 + m22
      local s = .5 / sqrt(t)
      x = (m20 + m02) * s
      y = (m12 + m21) * s
      z = t * s
      w = (m01 - m10) * s
    else
      local t = 1 + m00 + m11 + m22
      local s = .5 / sqrt(t)
      x = (m12 - m21) * s
      y = (m20 - m02) * s
      z = (m01 - m10) * s
      w = t * s
    end
  end

  return quaternion_ctype(x, y, z, w)
end

function quaternion.direction(q)
  local qv = quaternion_raw(q)
  local x, y, z, w = qv[0], qv[1], qv[2], qv[3]
  return vector_cast(raw_ctype(
    -2 * x * z - 2 * w * y,
    -2 * y * z + 2 * w * x,
    -1 + 2 * x * x + 2 * y * y,
    0
  ))
end

function quaternion.slerp(q, r, t)
  local qv = quaternion_raw(q)
  local rv = quaternion_raw(r)
  local dot = simd.hsum(qv * rv)

  if abs(dot) >= 1 then
    return q
  end

  if dot < 0 then
    qv = -qv
    dot = -dot
  end

  local halfTheta = acos(dot)
  local sinHalfTheta = sqrt(1 - dot * dot)
  local s = 1 - t

  if abs(sinHalfTheta) < .05 then
    local result = qv * s + rv * t
    return quaternion_pack(result / sqrt(simd.hsum(result * result)))
  end

  local a = sin(s * halfTheta) / sinHalfTheta
  local b = sin(t * halfTheta) / sinHalfTheta
  return quaternion_pack(qv * a + rv * b)
end

function quaternion.__mul(q, b)
  local qv = quaternion_raw(q)

  if type(b) == 'cdata' and ffi.typeof(b) == quaternion_ctype then
    local rv = quaternion_raw(b)
    local xterm = simd.bxor(simd.shuffle(rv, 3, 2, 1, 0), quaternion_x_sign)
    local yterm = simd.bxor(simd.shuffle(rv, 2, 3, 0, 1), quaternion_y_sign)
    local zterm = simd.bxor(simd.shuffle(rv, 1, 0, 3, 2), quaternion_z_sign)
    local xy = muladd(
      simd.shuffle(qv, 0, 0, 0, 0),
      xterm,
      rv * simd.shuffle(qv, 3, 3, 3, 3)
    )
    local yz = muladd(
      simd.shuffle(qv, 2, 2, 2, 2),
      zterm,
      yterm * simd.shuffle(qv, 1, 1, 1, 1)
    )
    return quaternion_pack(xy + yz)
  elseif type(b) == 'cdata' and ffi.typeof(b) == vector_ctype then
    local bv = vector_raw(b)
    local x, y, z, w = qv[0], qv[1], qv[2], qv[3]
    local xx, yy, zz, ww = x * x, y * y, z * z, w * w
    local xy, xz, yz = x * y, x * z, y * z
    local wx, wy, wz = w * x, w * y, w * z
    local column0 = raw_ctype(ww + xx - yy - zz, 2 * (xy + wz), 2 * (xz - wy), 0)
    local column1 = raw_ctype(2 * (xy - wz), ww - xx + yy - zz, 2 * (yz + wx), 0)
    local column2 = raw_ctype(2 * (xz + wy), 2 * (yz - wx), ww - xx - yy + zz, 0)
    local result = column0 * simd.shuffle(bv, 0, 0, 0, 0)
    result = muladd(column1, simd.shuffle(bv, 1, 1, 1, 1), result)
    result = muladd(column2, simd.shuffle(bv, 2, 2, 2, 2), result)
    return vector_cast(result)
  end

  error('quaternion can only multiply another quaternion or vector', 2)
end

function quaternion.__tostring(q)
  return ('%f, %f, %f, %f'):format(q[0], q[1], q[2], q[3])
end

local quaternion_fields = { x = 0, y = 1, z = 2, w = 3 }

local function quaternion_index(q, key)
  local lane = quaternion_fields[key]
  return lane and q[lane] or quaternion[key]
end

quaternion_ctype = ffi.metatype('lovr_quaternion4', {
  __index = quaternion_index,
  __mul = quaternion.__mul,
  __tostring = quaternion.__tostring
})

setmetatable(quaternion, {
  __call = function(_, ...)
    local first = ...
    if first then
      if type(first) == 'table' then return first end -- Deprecated
      if type(first) == 'cdata' and ffi.typeof(first) == quaternion_ctype then
        return first
      end
      return quaternion.angleaxis(...)
    else
      return quaternion_ctype(0, 0, 0, 1)
    end
  end
})

quaternion.ctype = quaternion_ctype
quaternion.identity = quaternion_ctype(0, 0, 0, 1)
