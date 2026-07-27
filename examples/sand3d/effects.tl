local ffi = require 'ffi'
local bit = require 'bit'
local simd = require 'ffi.simd'
local ecs = require 'ecs'

local record VectorArray
  length: integer
  data: {integer: any}
end

local type VectorConstructor =
  function(number, number, number, number): any

local record VectorModule
  ctype: VectorConstructor
end

local interface SIMDVector is ffi.CData
  metamethod __add: function(SIMDVector, SIMDVector): SIMDVector
  metamethod __sub: function(SIMDVector, SIMDVector): SIMDVector
  metamethod __mul: function(SIMDVector, SIMDVector): SIMDVector
end

local type SIMDConstructor = function(number): SIMDVector
local type SIMDArray = ffi.Array<SIMDVector>
local type SIMDOperation =
  function(SIMDVector, SIMDVector, SIMDVector): SIMDVector

local vector = (_G as {string: any})['vector'] as VectorModule

local band = bit.band
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
local abs = math.abs
local cos = math.cos
local floor = math.floor
local min = math.min
local sin = math.sin
local sqrt = math.sqrt
local tau = math.pi * 2

ffi.cdef[[
typedef float sand3d_float4 __attribute__((vector_size(16)));
typedef float sand3d_float8 __attribute__((vector_size(32)));
]]

ecs.define!(do
  local record Effects
    cellSize: number
    randomState: integer
    simdWidth: integer
    FloatVector: SIMDConstructor
    xv: SIMDArray
    yv: SIMDArray
    zv: SIMDArray
    vxv: SIMDArray
    vyv: SIMDArray
    vzv: SIMDArray
    agev: SIMDArray
    lifev: SIMDArray
    gravityv: SIMDArray

    new: function(
      capacity: integer, cellSize: number, seed?: integer | nil
    ): Effects
    clear: function(self)
    spawn: function(
      self, x: number, y: number, z: number, material: integer,
      count?: integer | nil, power?: number | nil
    ): integer
    update: function(self, dt: number)
    stage: function(
      self, positions: VectorArray, colors: VectorArray,
      data: VectorArray, palette: VectorArray
    ): integer
    memoryBytes: function(self): integer
  end
end, {
  x = f32,
  y = f32,
  z = f32,
  vx = f32,
  vy = f32,
  vz = f32,
  age = f32,
  life = f32,
  invLife = f32,
  size = f32,
  gravity = f32,
  material = u8,
  variant = u8,
})

local features = simd.features()
local simdWidth = features.avx2 and features.vecsize >= 32 and 8 or 4
local FloatVector = ffi.typeof(
  simdWidth == 8 and 'sand3d_float8' or 'sand3d_float4'
) as SIMDConstructor
local FloatVectorPointer: any = ffi.typeof('$ *', FloatVector)
local muladd: SIMDOperation =
  features.fma and (simd.fma as SIMDOperation) or function(
    a: SIMDVector, b: SIMDVector, c: SIMDVector
  ): SIMDVector
  return a * b + c
end
local glowByMaterial: ffi.Array<number> =
  ffi.new('float[5]', { .08, .08, .28, .08, 1.35 })
local stretchScaleByMaterial: ffi.Array<number> =
  ffi.new('float[5]', { 0, 0, .32, 0, .12 })
local stretchBaseByMaterial: ffi.Array<number> =
  ffi.new('float[5]', { .65, .08, 0, .08, 0 })
local stretchLimitByMaterial: ffi.Array<number> =
  ffi.new('float[5]', { .65, .08, 1.4, .08, .5 })

local function randomBits(self: Effects): integer
  local value = self.randomState
  value = bxor(value, lshift(value, 13))
  value = bxor(value, rshift(value, 17))
  value = bxor(value, lshift(value, 5))
  self.randomState = value
  return band(value, 0x7fffffff)
end

local function random01(self: Effects): number
  return band(randomBits(self), 0xffffff) / 0xffffff
end

function Effects.new(
  capacity: integer, cellSize: number, seed?: integer
): Effects
  assert(capacity > 0, 'effect capacity must be positive')
  local self = Effects.newECS(capacity)
  self.cellSize = cellSize
  self.randomState = seed or 0x25e77a
  self.simdWidth = simdWidth
  self.FloatVector = FloatVector
  self.xv = ffi.cast(FloatVectorPointer, self.x) as SIMDArray
  self.yv = ffi.cast(FloatVectorPointer, self.y) as SIMDArray
  self.zv = ffi.cast(FloatVectorPointer, self.z) as SIMDArray
  self.vxv = ffi.cast(FloatVectorPointer, self.vx) as SIMDArray
  self.vyv = ffi.cast(FloatVectorPointer, self.vy) as SIMDArray
  self.vzv = ffi.cast(FloatVectorPointer, self.vz) as SIMDArray
  self.agev = ffi.cast(FloatVectorPointer, self.age) as SIMDArray
  self.lifev = ffi.cast(FloatVectorPointer, self.life) as SIMDArray
  self.gravityv = ffi.cast(FloatVectorPointer, self.gravity) as SIMDArray
  return self
end

function Effects:clear()
  self.count = 0
end

function Effects:spawn(
  x: number, y: number, z: number, material: integer,
  count?: integer, power?: number
): integer
  local requested = min(count or 1, self.capacity - self.count)
  local first, allocated = self:allocateMany(requested)
  local effectPower = power or 1

  for index = first, first + allocated - 1 do

    local angle = random01(self) * tau
    local radial = sqrt(random01(self))
    local speed: number
    local lift: number
    local gravity: number
    local lifetime: number
    local size: number

    if material == 0 then
      speed = (1.1 + random01(self) * 1.8) * effectPower
      lift = (.25 + random01(self) * .9) * effectPower
      gravity = 1.1
      lifetime = .24 + random01(self) * .42
      size = self.cellSize * (.09 + random01(self) * .16)
    elseif material == 2 then
      speed = (.65 + random01(self) * 1.35) * effectPower
      lift = (.55 + random01(self) * 1.35) * effectPower
      gravity = 4.8
      lifetime = .45 + random01(self) * .7
      size = self.cellSize * (.15 + random01(self) * .18)
    elseif material == 3 then
      speed = (.45 + random01(self) * 1.15) * effectPower
      lift = (.35 + random01(self) * 1.1) * effectPower
      gravity = 5.8
      lifetime = .3 + random01(self) * .55
      size = self.cellSize * (.12 + random01(self) * .2)
    elseif material == 4 then
      speed = (.25 + random01(self) * .8) * effectPower
      lift = (1.15 + random01(self) * 2.2) * effectPower
      gravity = 1.25
      lifetime = .6 + random01(self) * 1.15
      size = self.cellSize * (.12 + random01(self) * .22)
    else
      speed = (.3 + random01(self) * .9) * effectPower
      lift = (.35 + random01(self) * 1.15) * effectPower
      gravity = 4.2
      lifetime = .35 + random01(self) * .7
      size = self.cellSize * (.11 + random01(self) * .17)
    end

    local jitter = self.cellSize * .42
    self.x[index] = x + (random01(self) - .5) * jitter
    self.y[index] = y + (random01(self) - .5) * jitter
    self.z[index] = z + (random01(self) - .5) * jitter
    self.vx[index] = cos(angle) * radial * speed
    self.vy[index] = lift
    self.vz[index] = sin(angle) * radial * speed
    self.age[index] = 0
    self.life[index] = lifetime
    self.invLife[index] = 1 / lifetime
    self.size[index] = size
    self.gravity[index] = gravity
    self.material[index] = material
    self.variant[index] = band(randomBits(self), 3)
  end

  return allocated
end

function Effects:update(dt: number)
  local count = self.count
  local width = self.simdWidth
  local vectorCount = floor(count / width)
  local Float = self.FloatVector
  local delta = Float(dt)
  local zero = Float(0)
  local divergent = false
  local xv, yv, zv = self.xv, self.yv, self.zv
  local vxv, vyv, vzv = self.vxv, self.vyv, self.vzv
  local agev, lifev, gravityv = self.agev, self.lifev, self.gravityv

  for i = 0, vectorCount - 1 do
    local y = muladd(vyv[i], delta, yv[i])
    local age = agev[i] + delta
    xv[i] = muladd(vxv[i], delta, xv[i])
    yv[i] = y
    zv[i] = muladd(vzv[i], delta, zv[i])
    vyv[i] = vyv[i] - gravityv[i] * delta
    agev[i] = age
    if simd.movemask(simd.lt(y, zero)) ~= 0 or
       simd.movemask(simd.ge(age, lifev[i])) ~= 0 then
      divergent = true
    end
  end

  local firstScalar = vectorCount * width
  if not divergent then
    local index = firstScalar
    while index < self.count do
      local age = self.age[index] + dt
      local y = self.y[index] + self.vy[index] * dt
      self.x[index] = self.x[index] + self.vx[index] * dt
      self.y[index] = y
      self.z[index] = self.z[index] + self.vz[index] * dt
      self.vy[index] = self.vy[index] - self.gravity[index] * dt
      self.age[index] = age

      if y < 0 then
        self.y[index] = -y * .18
        self.vy[index] = abs(self.vy[index]) * .28
        self.vx[index] = self.vx[index] * .72
        self.vz[index] = self.vz[index] * .72
        self.age[index] = age + dt * 2
      end

      if self.age[index] >= self.life[index] then
        self:removeSwap(index)
      else
        index = index + 1
      end
    end
    return
  end

  for index = firstScalar, count - 1 do
    self.x[index] = self.x[index] + self.vx[index] * dt
    self.y[index] = self.y[index] + self.vy[index] * dt
    self.z[index] = self.z[index] + self.vz[index] * dt
    self.vy[index] = self.vy[index] - self.gravity[index] * dt
    self.age[index] = self.age[index] + dt
  end

  local index = 0
  while index < self.count do
    if self.y[index] < 0 then
      self.y[index] = -self.y[index] * .18
      self.vy[index] = abs(self.vy[index]) * .28
      self.vx[index] = self.vx[index] * .72
      self.vz[index] = self.vz[index] * .72
      self.age[index] = self.age[index] + dt * 2
    end

    if self.age[index] >= self.life[index] then
      self:removeSwap(index)
    else
      index = index + 1
    end
  end
end

function Effects:stage(
  positions: VectorArray, colors: VectorArray,
  data: VectorArray, palette: VectorArray
): integer
  assert(vector and vector.ctype, 'effect staging requires the LÖVR SIMD math module')
  local Vector = vector.ctype
  local positionData = positions.data
  local colorData = colors.data
  local effectData = data.data
  local paletteData = palette.data

  for i = 0, self.count - 1 do
    local normalizedAge = self.age[i] * self.invLife[i]
    local fade = 1 - normalizedAge
    local material = self.material[i]
    local stretch = min(
      abs(self.vy[i]) * stretchScaleByMaterial[material] +
      stretchBaseByMaterial[material],
      stretchLimitByMaterial[material]
    )
    positionData[i] = Vector(self.x[i], self.y[i], self.z[i], 0)
    colorData[i] = paletteData[material * 4 + self.variant[i]]
    effectData[i] = Vector(
      self.size[i] * (.6 + fade * .55),
      min(fade * 1.25, 1),
      glowByMaterial[material],
      stretch
    )
  end

  return self.count
end

function Effects:memoryBytes(): integer
  return self:componentMemoryBytes()
end

return Effects
