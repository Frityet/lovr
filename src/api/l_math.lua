local ffi = require 'ffi'
local simd = require 'ffi.simd'
local _, _, _, _, mat4_native = ...
local abs, sqrt, sin, cos, tan, asin, acos, atan2 =
  math.abs, math.sqrt, math.sin, math.cos, math.tan, math.asin, math.acos, math.atan2
local floor = math.floor

ffi.cdef[[
typedef float lovr_vector4 __attribute__((vector_size(16)));
typedef const float lovr_quaternion4 __attribute__((vector_size(16)));
typedef volatile float lovr_raw4 __attribute__((vector_size(16)));
typedef uint32_t lovr_bits4 __attribute__((vector_size(16)));
typedef struct {
  lovr_raw4 columns[4];
} lovr_mat4;

void lovrMathMat4Invert(lovr_mat4* matrix);
]]

local vector_ctype
local quaternion_ctype
local mat4_ctype
local vector
local quaternion
local mat4
local raw_ctype = ffi.typeof('lovr_raw4')
local bits_ctype = ffi.typeof('lovr_bits4')
local conjugate_mask
local euler_sign
local quaternion_x_sign
local quaternion_y_sign
local quaternion_z_sign
local matrix_identity0
local matrix_identity1
local matrix_identity2
local matrix_identity3
local matrix_quaternion_sign0
local matrix_quaternion_sign1
local matrix_quaternion_sign2
local matrix_one
local native_invert_ffi
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
matrix_identity0 = raw_ctype(1, 0, 0, 0)
matrix_identity1 = raw_ctype(0, 1, 0, 0)
matrix_identity2 = raw_ctype(0, 0, 1, 0)
matrix_identity3 = raw_ctype(0, 0, 0, 1)
matrix_quaternion_sign0 = raw_ctype(0, 2, -2, 0)
matrix_quaternion_sign1 = raw_ctype(-2, 0, 2, 0)
matrix_quaternion_sign2 = raw_ctype(2, -2, 0, 0)
matrix_one = raw_ctype(1, 1, 1, 1)

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

local function matrix_quaternion_columns(q)
  local qv = quaternion_raw(q)
  local u = simd.insert(qv, 3, 0)
  local norm = u * u
  norm = norm + simd.shuffle(norm, 1, 0, 3, 2)
  norm = norm + simd.shuffle(norm, 2, 3, 0, 1)
  local diagonal = matrix_one - norm * 2
  local w = simd.shuffle(qv, 3, 3, 3, 3)
  local c0 =
    qv * simd.shuffle(qv, 0, 0, 0, 0) * 2 +
    simd.shuffle(qv, 0, 2, 1, 3) * w * matrix_quaternion_sign0 +
    diagonal * matrix_identity0
  local c1 =
    qv * simd.shuffle(qv, 1, 1, 1, 1) * 2 +
    simd.shuffle(qv, 2, 1, 0, 3) * w * matrix_quaternion_sign1 +
    diagonal * matrix_identity1
  local c2 =
    qv * simd.shuffle(qv, 2, 2, 2, 2) * 2 +
    simd.shuffle(qv, 1, 0, 2, 3) * w * matrix_quaternion_sign2 +
    diagonal * matrix_identity2
  return
    simd.insert(c0, 3, 0),
    simd.insert(c1, 3, 0),
    simd.insert(c2, 3, 0)
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

---

mat4 = {}
mat4.__index = mat4

local function matrix_is(value)
  return type(value) == 'cdata' and ffi.typeof(value) == mat4_ctype
end

local function matrix_assign(matrix, c0, c1, c2, c3)
  matrix.columns[0] = c0
  matrix.columns[1] = c1
  matrix.columns[2] = c2
  matrix.columns[3] = c3
  return matrix
end

local function matrix_identity(matrix)
  return matrix_assign(
    matrix,
    matrix_identity0,
    matrix_identity1,
    matrix_identity2,
    matrix_identity3
  )
end

local function matrix_copy(matrix, other)
  return matrix_assign(
    matrix,
    other.columns[0],
    other.columns[1],
    other.columns[2],
    other.columns[3]
  )
end

local function matrix_mul_column(matrix, column)
  local result = matrix.columns[3] * simd.shuffle(column, 3, 3, 3, 3)
  result = muladd(
    matrix.columns[0],
    simd.shuffle(column, 0, 0, 0, 0),
    result
  )
  result = muladd(
    matrix.columns[1],
    simd.shuffle(column, 1, 1, 1, 1),
    result
  )
  return muladd(
    matrix.columns[2],
    simd.shuffle(column, 2, 2, 2, 2),
    result
  )
end

local function matrix_mul_direction(matrix, direction)
  local result =
    matrix.columns[0] * simd.shuffle(direction, 0, 0, 0, 0)
  result = muladd(
    matrix.columns[1],
    simd.shuffle(direction, 1, 1, 1, 1),
    result
  )
  return muladd(
    matrix.columns[2],
    simd.shuffle(direction, 2, 2, 2, 2),
    result
  )
end

local function matrix_mul_affine(matrix, point)
  local p = vector_raw(point)
  local result = muladd(
    matrix.columns[0],
    simd.shuffle(p, 0, 0, 0, 0),
    matrix.columns[3]
  )
  result = muladd(
    matrix.columns[1],
    simd.shuffle(p, 1, 1, 1, 1),
    result
  )
  result = muladd(
    matrix.columns[2],
    simd.shuffle(p, 2, 2, 2, 2),
    result
  )
  return result
end

local function matrix_mul_point(matrix, point)
  local result = matrix_mul_affine(matrix, point)
  local weight = result[3]
  return weight == 1 and result or result / weight
end

local function matrix_table_components(value)
  local array = #value > 0
  if array then
    return value[1], value[2], value[3], array
  else
    return value.x, value.y, value.z, array
  end
end

local function matrix_table_result(source, result)
  local value
  if #source > 0 then
    value = { result[0], result[1], result[2] }
  else
    value = { x = result[0], y = result[1], z = result[2] }
  end
  return setmetatable(value, getmetatable(source))
end

local function matrix_read_components(value, y, z)
  if type(value) == 'cdata' and ffi.typeof(value) == vector_ctype then
    return value[0], value[1], value[2]
  elseif type(value) == 'table' then
    local x
    x, y, z = matrix_table_components(value)
    return x or 0, y or 0, z or 0
  else
    return value, y or value, z or value
  end
end

local native_set = mat4_native and mat4_native.set
local native_set_orientation = mat4_native and mat4_native.setOrientation
local native_set_pose = mat4_native and mat4_native.setPose
local native_rotate = mat4_native and mat4_native.rotate
local native_look_at = mat4_native and mat4_native.lookAt
local native_target = mat4_native and mat4_native.target
local native_reflect = mat4_native and mat4_native.reflect

function mat4.set(matrix, ...)
  local count = select('#', ...)
  local first = ...

  if first == nil then
    return matrix_identity(matrix)
  elseif matrix_is(first) then
    return matrix_copy(matrix, first)
  elseif type(first) == 'cdata' and ffi.typeof(first) == vector_ctype then
    local second, third = select(2, ...), select(3, ...)
    if count == 2 and
       type(second) == 'cdata' and ffi.typeof(second) == quaternion_ctype then
      matrix_identity(matrix)
      mat4.setPosition(matrix, first)
      return mat4.setOrientation(matrix, second)
    elseif count == 3 and
           type(second) == 'cdata' and ffi.typeof(second) == vector_ctype and
           type(third) == 'cdata' and ffi.typeof(third) == quaternion_ctype then
      matrix_identity(matrix)
      mat4.setPosition(matrix, first)
      mat4.setOrientation(matrix, third)
      return mat4.scale(matrix, second)
    end
    if native_set then return native_set(matrix, ...) end
  elseif count == 1 and type(first) == 'number' then
    local zero = raw_ctype(0, 0, 0, 0)
    return matrix_assign(
      matrix,
      simd.insert(zero, 0, first),
      simd.insert(zero, 1, first),
      simd.insert(zero, 2, first),
      simd.insert(zero, 3, first)
    )
  elseif count == 16 then
    local m00, m01, m02, m03,
          m10, m11, m12, m13,
          m20, m21, m22, m23,
          m30, m31, m32, m33 = ...
    return matrix_assign(
      matrix,
      raw_ctype(m00, m01, m02, m03),
      raw_ctype(m10, m11, m12, m13),
      raw_ctype(m20, m21, m22, m23),
      raw_ctype(m30, m31, m32, m33)
    )
  elseif native_set then
    return native_set(matrix, ...)
  end

  error('transform-form Mat4 construction requires lovr.math', 2)
end

function mat4.equals(matrix, other)
  if not matrix_is(other) then return false end
  for i = 0, 3 do
    local difference = matrix.columns[i] - other.columns[i]
    if simd.hsum(difference * difference) > 1e-10 then
      return false
    end
  end
  return true
end

function mat4.getPosition(matrix)
  local position = matrix.columns[3]
  return position[0], position[1], position[2]
end

function mat4.setPosition(matrix, x, y, z)
  x, y, z = matrix_read_components(x, y, z)
  matrix.columns[3] = raw_ctype(x, y, z, matrix.columns[3][3])
  return matrix
end

function mat4.getScale(matrix)
  local c0 = simd.insert(matrix.columns[0], 3, 0)
  local c1 = simd.insert(matrix.columns[1], 3, 0)
  local c2 = simd.insert(matrix.columns[2], 3, 0)
  return
    sqrt(simd.hsum(c0 * c0)),
    sqrt(simd.hsum(c1 * c1)),
    sqrt(simd.hsum(c2 * c2))
end

function mat4.setScale(matrix, x, y, z)
  x, y, z = matrix_read_components(x, y, z)
  local sx, sy, sz = matrix:getScale()
  local c0, c1, c2 = matrix.columns[0], matrix.columns[1], matrix.columns[2]
  matrix.columns[0] = simd.insert(c0 * (x / sx), 3, c0[3])
  matrix.columns[1] = simd.insert(c1 * (y / sy), 3, c1[3])
  matrix.columns[2] = simd.insert(c2 * (z / sz), 3, c2[3])
  return matrix
end

function mat4.setOrientation(matrix, orientation, ax, ay, az)
  local q
  if type(orientation) == 'cdata' and ffi.typeof(orientation) == quaternion_ctype then
    q = orientation
  elseif type(orientation) == 'number' and
         type(ax) == 'number' and type(ay) == 'number' and type(az) == 'number' then
    q = quaternion.angleaxis(orientation, ax, ay, az)
  elseif native_set_orientation then
    return native_set_orientation(matrix, orientation, ax, ay, az)
  else
    error('expected a quaternion or angle-axis rotation', 2)
  end

  local sx, sy, sz = matrix:getScale()
  local c0, c1, c2 = matrix_quaternion_columns(q)
  matrix.columns[0] = simd.insert(c0 * sx, 3, matrix.columns[0][3])
  matrix.columns[1] = simd.insert(c1 * sy, 3, matrix.columns[1][3])
  matrix.columns[2] = simd.insert(c2 * sz, 3, matrix.columns[2][3])
  return matrix
end

function mat4.setPose(matrix, position, orientation, ...)
  if type(position) == 'cdata' and ffi.typeof(position) == vector_ctype and
     type(orientation) == 'cdata' and ffi.typeof(orientation) == quaternion_ctype then
    mat4.setPosition(matrix, position)
    return mat4.setOrientation(matrix, orientation)
  elseif native_set_pose then
    return native_set_pose(matrix, position, orientation, ...)
  end

  error('expected a vector position and quaternion orientation', 2)
end

function mat4.identity(matrix)
  return matrix_identity(matrix)
end

function mat4.invert(matrix)
  native_invert_ffi = native_invert_ffi or ffi.C.lovrMathMat4Invert
  native_invert_ffi(matrix)
  return matrix
end

function mat4.transpose(matrix)
  local c0, c1 = matrix.columns[0], matrix.columns[1]
  local c2, c3 = matrix.columns[2], matrix.columns[3]
  local t0 = simd.shuffle2(c0, c1, 0, 4, 1, 5)
  local t1 = simd.shuffle2(c0, c1, 2, 6, 3, 7)
  local t2 = simd.shuffle2(c2, c3, 0, 4, 1, 5)
  local t3 = simd.shuffle2(c2, c3, 2, 6, 3, 7)
  return matrix_assign(
    matrix,
    simd.shuffle2(t0, t2, 0, 1, 4, 5),
    simd.shuffle2(t0, t2, 2, 3, 6, 7),
    simd.shuffle2(t1, t3, 0, 1, 4, 5),
    simd.shuffle2(t1, t3, 2, 3, 6, 7)
  )
end

function mat4.translate(matrix, x, y, z)
  x, y, z = matrix_read_components(x, y, z)
  local translation = muladd(matrix.columns[0], x, matrix.columns[3])
  translation = muladd(matrix.columns[1], y, translation)
  matrix.columns[3] = muladd(matrix.columns[2], z, translation)
  return matrix
end

function mat4.scale(matrix, x, y, z)
  x, y, z = matrix_read_components(x, y, z)
  matrix.columns[0] = matrix.columns[0] * x
  matrix.columns[1] = matrix.columns[1] * y
  matrix.columns[2] = matrix.columns[2] * z
  return matrix
end

function mat4.rotate(matrix, rotation, ax, ay, az)
  local q
  if type(rotation) == 'cdata' and ffi.typeof(rotation) == quaternion_ctype then
    q = rotation
  elseif type(rotation) == 'number' and
         type(ax) == 'number' and type(ay) == 'number' and type(az) == 'number' then
    q = quaternion.angleaxis(rotation, ax, ay, az)
  elseif native_rotate then
    return native_rotate(matrix, rotation, ax, ay, az)
  else
    error('expected a quaternion or angle-axis rotation', 2)
  end

  local r0, r1, r2 = matrix_quaternion_columns(q)
  local c0 = matrix_mul_direction(matrix, r0)
  local c1 = matrix_mul_direction(matrix, r1)
  local c2 = matrix_mul_direction(matrix, r2)
  matrix.columns[0] = c0
  matrix.columns[1] = c1
  matrix.columns[2] = c2
  return matrix
end

function mat4.orthographic(matrix, ...)
  local count = select('#', ...)
  local left, right, bottom, top, near, far = ...
  if count <= 4 then
    near, far = bottom or -1, top or 1
    left, right, bottom, top = 0, left, 0, right
  end

  local rl = right - left
  local tb = top - bottom
  local fn = far - near
  return matrix_assign(
    matrix,
    raw_ctype(2 / rl, 0, 0, 0),
    raw_ctype(0, 2 / tb, 0, 0),
    raw_ctype(0, 0, -1 / fn, 0),
    raw_ctype(-(right + left) / rl, -(top + bottom) / tb, -near / fn, 1)
  )
end

function mat4.perspective(matrix, fovy, aspect, near, far)
  local cotangent = 1 / tan(fovy * .5)
  far = far or 0
  local z, depth
  if far == 0 then
    z, depth = 0, near
  else
    z, depth = far / (near - far), near * far / (near - far)
  end
  return matrix_assign(
    matrix,
    raw_ctype(cotangent / aspect, 0, 0, 0),
    raw_ctype(0, -cotangent, 0, 0),
    raw_ctype(0, 0, z, -1),
    raw_ctype(0, 0, depth, 0)
  )
end

function mat4.fov(matrix, left, right, up, down, near, far)
  left, right = -tan(left), tan(right)
  up, down = tan(up), -tan(down)
  far = far or 0
  local z, depth
  if far == 0 then
    z, depth = 0, near
  else
    z, depth = far / (near - far), near * far / (near - far)
  end
  return matrix_assign(
    matrix,
    raw_ctype(2 / (right - left), 0, 0, 0),
    raw_ctype(0, 2 / (down - up), 0, 0),
    raw_ctype(
      (right + left) / (right - left),
      (down + up) / (down - up),
      z,
      -1
    ),
    raw_ctype(0, 0, depth, 0)
  )
end

local function matrix_look_basis(from, to, up)
  local z = vector.normalize(from - to)
  local x = vector.normalize(vector.cross(up, z))
  return x, vector.cross(z, x), z
end

function mat4.lookAt(matrix, from, to, up, ...)
  if type(from) == 'cdata' and ffi.typeof(from) == vector_ctype and
     type(to) == 'cdata' and ffi.typeof(to) == vector_ctype and
     (up == nil or type(up) == 'cdata' and ffi.typeof(up) == vector_ctype) then
    up = up or vector.up
    local x, y, z = matrix_look_basis(from, to, up)
    return matrix_assign(
      matrix,
      raw_ctype(x[0], y[0], z[0], 0),
      raw_ctype(x[1], y[1], z[1], 0),
      raw_ctype(x[2], y[2], z[2], 0),
      raw_ctype(-dot3(x, from), -dot3(y, from), -dot3(z, from), 1)
    )
  elseif native_look_at then
    return native_look_at(matrix, from, to, up, ...)
  end

  error('expected vector arguments', 2)
end

function mat4.target(matrix, from, to, up, ...)
  if type(from) == 'cdata' and ffi.typeof(from) == vector_ctype and
     type(to) == 'cdata' and ffi.typeof(to) == vector_ctype and
     (up == nil or type(up) == 'cdata' and ffi.typeof(up) == vector_ctype) then
    up = up or vector.up
    local x, y, z = matrix_look_basis(from, to, up)
    return matrix_assign(
      matrix,
      x,
      y,
      z,
      raw_ctype(from[0], from[1], from[2], 1)
    )
  elseif native_target then
    return native_target(matrix, from, to, up, ...)
  end

  error('expected vector arguments', 2)
end

function mat4.reflect(matrix, position, normal, ...)
  if type(position) == 'cdata' and ffi.typeof(position) == vector_ctype and
     type(normal) == 'cdata' and ffi.typeof(normal) == vector_ctype then
    local nx, ny, nz = normal[0], normal[1], normal[2]
    local d = dot3(position, normal)
    return matrix_assign(
      matrix,
      raw_ctype(1 - 2 * nx * nx, -2 * nx * ny, -2 * nx * nz, 0),
      raw_ctype(-2 * ny * nx, 1 - 2 * ny * ny, -2 * ny * nz, 0),
      raw_ctype(-2 * nz * nx, -2 * nz * ny, 1 - 2 * nz * nz, 0),
      raw_ctype(2 * d * nx, 2 * d * ny, 2 * d * nz, 1)
    )
  elseif native_reflect then
    return native_reflect(matrix, position, normal, ...)
  end

  error('expected vector arguments', 2)
end

function mat4.mul(matrix, value, y, z, w)
  if matrix_is(value) then
    local c0 = matrix_mul_column(matrix, value.columns[0])
    local c1 = matrix_mul_column(matrix, value.columns[1])
    local c2 = matrix_mul_column(matrix, value.columns[2])
    local c3 = matrix_mul_column(matrix, value.columns[3])
    return matrix_assign(matrix, c0, c1, c2, c3)
  elseif type(value) == 'number' then
    local weight = w or 1
    local point = raw_ctype(value, y, z, weight)
    local result = weight == 0
      and matrix_mul_direction(matrix, point)
      or weight == 1 and matrix_mul_affine(matrix, point)
      or matrix_mul_column(matrix, point)
    return result[0], result[1], result[2], result[3]
  elseif type(value) == 'cdata' and ffi.typeof(value) == vector_ctype then
    local point = vector_raw(value)
    local weight = y or 1
    local result = weight == 0
      and matrix_mul_direction(matrix, point)
      or weight == 1 and matrix_mul_affine(matrix, point)
      or matrix_mul_column(matrix, simd.insert(point, 3, weight))
    return vector_result(result)
  elseif type(value) == 'table' then
    local weight = y or 1
    local x
    x, y, z = matrix_table_components(value)
    local point = raw_ctype(x or 0, y or 0, z or 0, weight)
    local result = weight == 0
      and matrix_mul_direction(matrix, point)
      or weight == 1 and matrix_mul_affine(matrix, point)
      or matrix_mul_column(matrix, point)
    return matrix_table_result(value, result)
  end

  error('expected a number, vector, table, or Mat4', 2)
end

function mat4.__mul(matrix, value)
  if matrix_is(value) then
    return matrix_assign(
      mat4_ctype(),
      matrix_mul_column(matrix, value.columns[0]),
      matrix_mul_column(matrix, value.columns[1]),
      matrix_mul_column(matrix, value.columns[2]),
      matrix_mul_column(matrix, value.columns[3])
    )
  elseif type(value) == 'cdata' and ffi.typeof(value) == vector_ctype then
    return vector_result(matrix_mul_point(matrix, value))
  elseif type(value) == 'table' then
    local x, y, z = matrix_table_components(value)
    local point = raw_ctype(x or 0, y or 0, z or 0, 0)
    return matrix_table_result(value, matrix_mul_point(matrix, point))
  end

  error('Mat4 can only multiply another Mat4, table, or vector', 2)
end

function mat4.__tostring(matrix)
  local c0, c1 = matrix.columns[0], matrix.columns[1]
  local c2, c3 = matrix.columns[2], matrix.columns[3]
  return (
    '(%f, %f, %f, %f,\n %f, %f, %f, %f,\n' ..
    ' %f, %f, %f, %f,\n %f, %f, %f, %f)'
  ):format(
    c0[0], c1[0], c2[0], c3[0],
    c0[1], c1[1], c2[1], c3[1],
    c0[2], c1[2], c2[2], c3[2],
    c0[3], c1[3], c2[3], c3[3]
  )
end

function mat4.type()
  return 'Mat4'
end

function mat4.release()
end

if mat4_native then
  local native_methods = {
    'unpack',
    'getOrientation',
    'getPose'
  }
  for i = 1, #native_methods do
    local name = native_methods[i]
    mat4[name] = mat4_native[name]
  end
end

local function matrix_index(matrix, key)
  if type(key) == 'number' then
    local index = floor(key)
    if index >= 1 and index <= 16 then
      index = index - 1
      return matrix.columns[floor(index / 4)][index % 4]
    end
  else
    local method = mat4[key]
    if method ~= nil then return method end
  end

  error(('attempt to index field %s of Mat4 (invalid property)'):format(tostring(key)), 2)
end

local function matrix_newindex(matrix, key, value)
  if type(key) == 'number' then
    local index = floor(key)
    if index >= 1 and index <= 16 then
      index = index - 1
      local column = floor(index / 4)
      matrix.columns[column] = simd.insert(matrix.columns[column], index % 4, value)
      return
    end
  end

  error(('attempt to assign property %s of Mat4 (invalid property)'):format(tostring(key)), 2)
end

mat4_ctype = ffi.metatype('lovr_mat4', {
  __index = matrix_index,
  __newindex = matrix_newindex,
  __mul = mat4.__mul,
  __tostring = mat4.__tostring
})

setmetatable(mat4, {
  __call = function(_, ...)
    return mat4.set(mat4_ctype(), ...)
  end
})

mat4.ctype = mat4_ctype

_G.vector = vector
_G.quaternion = quaternion
_G.mat4 = mat4
