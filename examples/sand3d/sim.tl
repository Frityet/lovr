local ffi = require 'ffi'
local bit = require 'bit'
local ecs = require 'ecs'

local record VectorArray
  length: integer
  data: {integer: any}
end

local type VectorConstructor =
  function(number, number, number, number): any

local record VectorModule
  ctype: VectorConstructor
  array: function(integer): VectorArray
end

local vector = (_G as {string: any})['vector'] as VectorModule

local band = bit.band
local bxor = bit.bxor
local lshift = bit.lshift
local rshift = bit.rshift
local floor = math.floor
local min = math.min
local max = math.max

local EMPTY = 0
local SAND = 1
local WATER = 2
local ROCK = 3
local LAVA = 4
local BOUNDARY = 255

ecs.define!(do
  local record Sand3D
    EMPTY: integer
    SAND: integer
    WATER: integer
    ROCK: integer
    LAVA: integer

    width: integer
    height: integer
    depth: integer
    strideX: integer
    strideZ: integer
    layerStride: integer
    allocation: integer
    materials: ffi.Array<integer>
    cellSlot: ffi.Array<integer>
    materialCounts: ffi.Array<integer>
    materialSlots: {integer: ffi.Array<integer>}
    sideOffsets: ffi.Array<integer>
    diagonalOffsets: ffi.Array<integer>
    sideDX: ffi.Array<integer>
    sideDZ: ffi.Array<integer>
    randomState: integer
    epoch: integer
    stepCount: integer
    population: integer
    lastMoves: integer
    lastVisits: integer

    renderPositions: VectorArray | nil
    renderColors: VectorArray | nil
    renderPalette: VectorArray | nil
    renderPositionData: {integer: any} | nil
    renderColorData: {integer: any} | nil
    renderPaletteData: {integer: any} | nil
    renderCellPositions: VectorArray | nil
    renderCellPositionData: {integer: any} | nil
    renderMoveLog: ffi.Array<integer> | nil
    renderMoveCount: integer
    renderMoveCapacity: integer
    renderColorLog: ffi.Array<integer> | nil
    renderColorCount: integer
    renderNeedsFullSync: boolean
    renderNeedsFullColorSync: boolean
    renderVector: VectorConstructor | nil
    renderCenterX: number
    renderCenterZ: number

    new: function(
      width: integer, height: integer, depth: integer,
      seed?: integer | nil
    ): Sand3D
    index: function(self, x: integer, y: integer, z: integer): integer
    clear: function(self): Sand3D
    get: function(self, x: integer, y: integer, z: integer): integer
    set: function(
      self, x: integer, y: integer, z: integer,
      material: integer, shade?: integer | nil
    ): boolean
    paintSphere: function(
      self, cx: number, cy: number, cz: number, radius: number,
      material: integer, overwrite?: boolean | nil
    ): integer
    emit: function(
      self, cx: number, cy: number, cz: number, material: integer,
      radius: number, count: number
    ): integer
    populateBenchmark: function(self): Sand3D
    step: function(self): integer
    bindRender: function(
      self, positions: VectorArray, colors: VectorArray, palette: VectorArray
    ): Sand3D
    syncRender: function(self): integer
    compact: function(
      self, positions: VectorArray, colors: VectorArray,
      palette: VectorArray, surfaceOnly?: boolean | nil
    ): integer
    countMaterial: function(self, material: integer): integer
    memoryBytes: function(self): integer
    renderCacheBytes: function(self): integer
    assertIntegrity: function(self): boolean
  end
end, {
  cell = i32,
  material = u8,
  shade = u8,
  stamp = u16,
  listIndex = u32,
})

Sand3D.EMPTY = EMPTY
Sand3D.SAND = SAND
Sand3D.WATER = WATER
Sand3D.ROCK = ROCK
Sand3D.LAVA = LAVA

local function randomBits(self: Sand3D): integer
  local value = self.randomState
  value = bxor(value, lshift(value, 13))
  value = bxor(value, rshift(value, 17))
  value = bxor(value, lshift(value, 5))
  self.randomState = value
  return band(value, 0x7fffffff)
end

local function random(self: Sand3D, limit: integer): integer
  return randomBits(self) % limit
end

local function writePosition(self: Sand3D, slot: integer)
  local positions = self.renderPositionData
  if positions then
    positions[slot] = self.renderCellPositionData[self.cell[slot]]
  end
end

local function writeColor(self: Sand3D, slot: integer)
  local colors = self.renderColorData
  if colors then
    colors[slot] = self.renderPaletteData[
      self.material[slot] * 4 + band(self.shade[slot], 3)
    ]
  end
end

local function recordPositionChange(self: Sand3D, slot: integer)
  local log = self.renderMoveLog
  if log then
    local count = self.renderMoveCount
    if count < self.renderMoveCapacity then
      log[count] = slot
      self.renderMoveCount = count + 1
    else
      self.renderNeedsFullSync = true
    end
  end
end

local function recordColorChange(self: Sand3D, slot: integer)
  local log = self.renderColorLog
  if log then
    local count = self.renderColorCount
    if count < self.capacity then
      log[count] = slot
      self.renderColorCount = count + 1
    else
      self.renderNeedsFullColorSync = true
    end
  end
end

local function addToMaterialList(
  self: Sand3D, slot: integer, material: integer
)
  local count = self.materialCounts[material]
  if material == ROCK then
    self.materialCounts[material] = count + 1
    return
  end
  self.materialSlots[material][count] = slot
  self.listIndex[slot] = count
  self.materialCounts[material] = count + 1
end

local function removeFromMaterialList(
  self: Sand3D, slot: integer, material: integer
)
  if material == ROCK then
    self.materialCounts[material] = self.materialCounts[material] - 1
    return
  end
  local list = self.materialSlots[material]
  local last = self.materialCounts[material] - 1
  local index = self.listIndex[slot]
  if index < last then
    local movedSlot = list[last]
    list[index] = movedSlot
    self.listIndex[movedSlot] = index
  end
  self.materialCounts[material] = last
end

local function changeMaterial(
  self: Sand3D, slot: integer, material: integer
)
  local previous = self.material[slot]
  if previous ~= material then
    removeFromMaterialList(self, slot, previous)
    self.material[slot] = material
    addToMaterialList(self, slot, material)
  end
end

local function insertEntity(
  self: Sand3D, index: integer, material: integer, shade?: integer
): integer
  local slot = self:allocate()
  self.cell[slot] = index
  self.material[slot] = material
  self.shade[slot] = shade or random(self, 256)
  self.stamp[slot] = self.epoch
  addToMaterialList(self, slot, material)
  self.materials[index] = material
  self.cellSlot[index] = slot + 1
  self.population = self.count
  writePosition(self, slot)
  writeColor(self, slot)
  return slot
end

local function removeEntity(self: Sand3D, index: integer, slot: integer)
  local last = self.count - 1
  removeFromMaterialList(self, slot, self.material[slot])
  self.materials[index] = EMPTY
  self.cellSlot[index] = 0

  if slot < last then
    if self.renderPositionData then
      self.renderPositionData[slot] = self.renderPositionData[last]
      self.renderColorData[slot] = self.renderColorData[last]
    end
    local movedCell = self.cell[last]
    self:removeSwap(slot)
    self.cellSlot[movedCell] = slot + 1
    if self.material[slot] ~= ROCK then
      self.materialSlots[self.material[slot]][self.listIndex[slot]] = slot
    end
  else
    self:removeSwap(slot)
  end

  self.population = self.count
end

function Sand3D.new(
  width: integer, height: integer, depth: integer, seed?: integer
): Sand3D
  assert(width > 0 and height > 0 and depth > 0, 'grid dimensions must be positive')
  assert(width < 256 and height < 256 and depth < 256, 'grid axes must fit in uint8_t')

  local strideX = width + 2
  local strideZ = depth + 2
  local layerStride = strideX * strideZ
  local allocation = layerStride * (height + 1)
  local self = Sand3D.newECS(width * height * depth)

  self.width = width
  self.height = height
  self.depth = depth
  self.strideX = strideX
  self.strideZ = strideZ
  self.layerStride = layerStride
  self.allocation = allocation
  self.materials = ffi.new('uint8_t[?]', allocation)
  self.cellSlot = ffi.new('uint32_t[?]', allocation)
  self.materialCounts = ffi.new('uint32_t[5]')
  self.materialSlots = {
    [SAND] = ffi.new('uint32_t[?]', self.capacity),
    [WATER] = ffi.new('uint32_t[?]', self.capacity),
    [LAVA] = ffi.new('uint32_t[?]', self.capacity)
  }
  self.sideOffsets = ffi.new('int32_t[8]')
  self.diagonalOffsets = ffi.new('int32_t[8]')
  self.sideDX = ffi.new('int8_t[8]', { 1, -1, 0, 0, 1, 1, -1, -1 })
  self.sideDZ = ffi.new('int8_t[8]', { 0, 0, 1, -1, 1, -1, 1, -1 })
  self.randomState = seed or 0x51f15e
  self.epoch = 0
  self.stepCount = 0
  self.population = 0
  self.lastMoves = 0
  self.lastVisits = 0
  self.renderPositions = nil
  self.renderColors = nil
  self.renderPalette = nil
  self.renderPositionData = nil
  self.renderColorData = nil
  self.renderPaletteData = nil
  self.renderCellPositions = nil
  self.renderCellPositionData = nil
  self.renderMoveLog = nil
  self.renderMoveCount = 0
  self.renderMoveCapacity = 0
  self.renderColorLog = nil
  self.renderColorCount = 0
  self.renderNeedsFullSync = false
  self.renderNeedsFullColorSync = false
  self.renderVector = nil
  self.renderCenterX = (width + 1) * .5
  self.renderCenterZ = (depth + 1) * .5

  for i = 0, 7 do
    local side = self.sideDX[i] + self.sideDZ[i] * strideX
    self.sideOffsets[i] = side
    self.diagonalOffsets[i] = side - layerStride
  end

  self:clear()
  return self
end

function Sand3D:index(x: integer, y: integer, z: integer): integer
  return x + z * self.strideX + y * self.layerStride
end

function Sand3D:clear(): Sand3D
  self.count = 0
  ffi.fill(self.materials, self.allocation)
  ffi.fill(self.cellSlot, self.allocation * ffi.sizeof('uint32_t'))
  ffi.fill(self.materialCounts, ffi.sizeof('uint32_t') * 5)
  self.renderMoveCount = 0
  self.renderColorCount = 0
  self.renderNeedsFullSync = false
  self.renderNeedsFullColorSync = false

  local materials = self.materials
  local width = self.width
  local height = self.height
  local depth = self.depth
  local strideX = self.strideX
  local layerStride = self.layerStride

  for i = 0, layerStride - 1 do
    materials[i] = BOUNDARY
  end

  for y = 1, height do
    local layer = y * layerStride
    for z = 0, depth + 1 do
      local row = layer + z * strideX
      materials[row] = BOUNDARY
      materials[row + width + 1] = BOUNDARY
    end
    local front = layer
    local back = layer + (depth + 1) * strideX
    for x = 0, width + 1 do
      materials[front + x] = BOUNDARY
      materials[back + x] = BOUNDARY
    end
  end

  self.epoch = 0
  self.stepCount = 0
  self.population = 0
  self.lastMoves = 0
  self.lastVisits = 0
  return self
end

function Sand3D:get(x: integer, y: integer, z: integer): integer
  if x < 1 or x > self.width or
     y < 1 or y > self.height or
     z < 1 or z > self.depth then
    return BOUNDARY
  end
  return self.materials[self:index(x, y, z)]
end

function Sand3D:set(
  x: integer, y: integer, z: integer,
  material: integer, shade?: integer
): boolean
  if x < 1 or x > self.width or
     y < 1 or y > self.height or
     z < 1 or z > self.depth then
    return false
  end

  local index = self:index(x, y, z)
  local previous = self.materials[index]

  if previous == EMPTY then
    if material == EMPTY then return false end
    insertEntity(self, index, material, shade)
  elseif material == EMPTY then
    removeEntity(self, index, self.cellSlot[index] - 1)
  else
    local slot = self.cellSlot[index] - 1
    self.materials[index] = material
    changeMaterial(self, slot, material)
    self.shade[slot] = shade or random(self, 256)
    self.stamp[slot] = self.epoch
    writeColor(self, slot)
  end

  return previous ~= material
end

function Sand3D:paintSphere(
  cx: number, cy: number, cz: number, radius: number,
  material: integer, overwrite?: boolean
): integer
  radius = max(0, floor(radius))
  local x1 = max(1, floor(cx - radius))
  local x2 = min(self.width, floor(cx + radius))
  local y1 = max(1, floor(cy - radius))
  local y2 = min(self.height, floor(cy + radius))
  local z1 = max(1, floor(cz - radius))
  local z2 = min(self.depth, floor(cz + radius))
  local radiusSquared = (radius + .35) * (radius + .35)
  local changed = 0

  for y = y1, y2 do
    local dy = y - cy
    for z = z1, z2 do
      local dz = z - cz
      for x = x1, x2 do
        local dx = x - cx
        if dx * dx + dy * dy + dz * dz <= radiusSquared then
          local index = x + z * self.strideX + y * self.layerStride
          if material == EMPTY or overwrite or self.materials[index] == EMPTY then
            if self:set(x, y, z, material) then changed = changed + 1 end
          end
        end
      end
    end
  end

  return changed
end

function Sand3D:emit(
  cx: number, cy: number, cz: number, material: integer,
  radius: number, count: number
): integer
  radius = max(0, floor(radius))
  count = max(0, floor(count))
  local diameter = radius * 2 + 1
  local radiusSquared = (radius + .45) * (radius + .45)
  local emitted = 0
  local attempts = 0
  local limit = max(count * 5, 1)
  local width, height, depth = self.width, self.height, self.depth
  local strideX, layerStride = self.strideX, self.layerStride

  while emitted < count and attempts < limit and self.count < self.capacity do
    attempts = attempts + 1
    local dx = radius == 0 and 0 or random(self, diameter as integer) - radius
    local dy = radius == 0 and 0 or random(self, diameter as integer) - radius
    local dz = radius == 0 and 0 or random(self, diameter as integer) - radius
    if dx * dx + dy * dy + dz * dz <= radiusSquared then
      local x = floor(cx + dx)
      local y = floor(cy + dy)
      local z = floor(cz + dz)
      if x >= 1 and x <= width and
         y >= 1 and y <= height and
         z >= 1 and z <= depth then
        local index = x + z * strideX + y * layerStride
        if self.materials[index] == EMPTY then
          insertEntity(self, index, material)
          emitted = emitted + 1
        end
      end
    end
  end

  return emitted
end

function Sand3D:populateBenchmark(): Sand3D
  self:clear()

  local width = self.width
  local height = self.height
  local depth = self.depth
  local cx = floor((width + 1) / 2)
  local cz = floor((depth + 1) / 2)
  local shelfY = max(5, floor(height * .27))

  for z = max(2, cz - 3), min(depth - 1, cz + 3) do
    for x = max(3, floor(width * .14)), min(width - 2, floor(width * .86)) do
      if math.abs(x - cx) > 4 then self:set(x, shelfY, z, ROCK, x + z) end
    end
  end

  for y = 1, shelfY do
    for _, x in ipairs({ floor(width * .16), floor(width * .84) }) do
      for z = cz - 3, cz + 3 do self:set(x, y, z, ROCK, x + y + z) end
    end
  end

  local bx1, bx2 = floor(width * .58), floor(width * .91)
  local bz1, bz2 = floor(depth * .58), floor(depth * .91)
  for y = 1, min(4, height) do
    for x = bx1, bx2 do
      self:set(x, y, bz1, ROCK, x + y)
      self:set(x, y, bz2, ROCK, x + y)
    end
    for z = bz1, bz2 do
      self:set(bx1, y, z, ROCK, y + z)
      self:set(bx2, y, z, ROCK, y + z)
    end
  end

  for y = 1, min(5, height) do
    for z = bz1 + 1, bz2 - 1 do
      for x = bx1 + 1, bx2 - 1 do
        self:set(x, y, z, WATER, x * 7 + z * 13 + y)
      end
    end
  end

  local function cone(px: integer, pz: integer, coneHeight: integer)
    for y = 1, min(coneHeight, height) do
      local radius = coneHeight - y + 1
      local radiusSquared = radius * radius
      for z = max(1, pz - radius), min(depth, pz + radius) do
        local dz = z - pz
        for x = max(1, px - radius), min(width, px + radius) do
          local dx = x - px
          if dx * dx + dz * dz <= radiusSquared then
            self:set(x, y, z, SAND, x * 11 + y * 17 + z * 23)
          end
        end
      end
    end
  end

  cone(floor(width * .25), floor(depth * .29), min(14, floor(height * .35)))
  cone(floor(width * .48), floor(depth * .76), min(10, floor(height * .25)))
  self:emit(cx, height - 5, cz, SAND, min(10, floor(width * .16)), 2600)
  self:emit(floor(width * .72), height - 7, floor(depth * .28), LAVA, 4, 260)

  local cloudBottom = max(shelfY + 5, floor(height * .54))
  for y = cloudBottom, height - 3 do
    for z = 4, depth - 3 do
      for x = 4, width - 3 do
        local hash = (x * 17 + y * 31 + z * 47 + x * z * 3) % 13
        if hash < 3 then
          local index = x + z * self.strideX + y * self.layerStride
          if self.materials[index] == EMPTY then
            self:set(x, y, z, hash == 2 and WATER or SAND, hash * 61 + x + z)
          end
        end
      end
    end
  end

  return self
end

local function moveEmpty(
  self: Sand3D, slot: integer, from: integer, to: integer, epoch: integer
): boolean
  if self.materials[to] ~= EMPTY then return false end

  self.materials[to] = self.material[slot]
  self.materials[from] = EMPTY
  self.cellSlot[to] = slot + 1
  self.cellSlot[from] = 0
  self.cell[slot] = to
  self.stamp[slot] = epoch
  recordPositionChange(self, slot)
  return true
end

local function moveSand(
  self: Sand3D, slot: integer, from: integer, to: integer, epoch: integer
): boolean
  local target = self.materials[to]
  if target == EMPTY then
    return moveEmpty(self, slot, from, to, epoch)
  elseif target ~= WATER then
    return false
  end

  local targetSlot = self.cellSlot[to] - 1
  self.materials[to] = SAND
  self.materials[from] = WATER
  self.cellSlot[to] = slot + 1
  self.cellSlot[from] = targetSlot + 1
  self.cell[slot] = to
  self.cell[targetSlot] = from
  self.stamp[slot] = epoch
  self.stamp[targetSlot] = epoch
  recordPositionChange(self, slot)
  recordPositionChange(self, targetSlot)
  return true
end

local function coolEntity(self: Sand3D, slot: integer, epoch: integer)
  changeMaterial(self, slot, ROCK)
  self.materials[self.cell[slot]] = ROCK
  self.stamp[slot] = epoch
  recordColorChange(self, slot)
end

local function traversal(
  self: Sand3D, count: integer
): integer, integer, integer
  local reverse = band(self.stepCount, 1) == 1
  return
    reverse and count - 1 or 0,
    reverse and 0 or count - 1,
    reverse and -1 or 1
end

local function stepSandSystem(self: Sand3D, epoch: integer): integer
  local slots = self.materialSlots[SAND]
  local count = tonumber(self.materialCounts[SAND]) as integer
  local stamps = self.stamp
  local cells = self.cell
  local layerStride = self.layerStride
  local diagonalOffsets = self.diagonalOffsets
  local first, last, directionStep = traversal(self, count)
  local moves = 0

  for listIndex = first, last, directionStep do
    local slot = slots[listIndex]
    if stamps[slot] ~= epoch then
      local index = cells[slot]
      if moveSand(self, slot, index, index - layerStride, epoch) then
        moves = moves + 1
      else
        local choice = randomBits(self)
        local start = band(choice, 7)
        local direction = band(choice, 8) == 0 and 1 or -1
        for attempt = 0, 7 do
          local side = band(start + attempt * direction, 7)
          local candidate = index + diagonalOffsets[side]
          if moveSand(self, slot, index, candidate, epoch) then
            moves = moves + 1
            break
          end
        end
      end
    end
  end

  return moves
end

local function stepWaterSystem(self: Sand3D, epoch: integer): integer
  local slots = self.materialSlots[WATER]
  local count = tonumber(self.materialCounts[WATER]) as integer
  local stamps = self.stamp
  local cells = self.cell
  local layerStride = self.layerStride
  local diagonalOffsets = self.diagonalOffsets
  local sideOffsets = self.sideOffsets
  local first, last, directionStep = traversal(self, count)
  local moves = 0

  for listIndex = first, last, directionStep do
    local slot = slots[listIndex]
    if stamps[slot] ~= epoch then
      local index = cells[slot]
      if moveEmpty(self, slot, index, index - layerStride, epoch) then
        moves = moves + 1
      else
        local moved = false
        local choice = randomBits(self)
        local start = band(choice, 7)
        local direction = band(choice, 8) == 0 and 1 or -1
        for attempt = 0, 7 do
          local side = band(start + attempt * direction, 7)
          local candidate = index + diagonalOffsets[side]
          if moveEmpty(self, slot, index, candidate, epoch) then
            moves = moves + 1
            moved = true
            break
          end
        end
        if not moved then
          start = band(randomBits(self), 7)
          for attempt = 0, 7 do
            local side = band(start + attempt * direction, 7)
            local candidate = index + sideOffsets[side]
            if moveEmpty(self, slot, index, candidate, epoch) then
              moves = moves + 1
              break
            end
          end
        end
      end
    end
  end

  return moves
end

local function stepLavaSystem(self: Sand3D, epoch: integer): integer
  local materials = self.materials
  local entityMaterials = self.material
  local slots = self.materialSlots[LAVA]
  local count = tonumber(self.materialCounts[LAVA]) as integer
  local stamps = self.stamp
  local cells = self.cell
  local strideX = self.strideX
  local layerStride = self.layerStride
  local diagonalOffsets = self.diagonalOffsets
  local first, last, directionStep = traversal(self, count)
  local moves = 0

  for listIndex = first, last, directionStep do
    local slot = slots[listIndex]
    if slot < self.count and
       entityMaterials[slot] == LAVA and
       stamps[slot] ~= epoch then
      local index = cells[slot]
      local waterIndex = 0
      if materials[index - 1] == WATER then waterIndex = index - 1
      elseif materials[index + 1] == WATER then waterIndex = index + 1
      elseif materials[index - strideX] == WATER then waterIndex = index - strideX
      elseif materials[index + strideX] == WATER then waterIndex = index + strideX
      elseif materials[index - layerStride] == WATER then waterIndex = index - layerStride
      end

      if waterIndex ~= 0 then
        coolEntity(self, slot, epoch)
        coolEntity(self, self.cellSlot[waterIndex] - 1, epoch)
      elseif band(self.stepCount + self.shade[slot], 3) == 0 then
        if moveEmpty(self, slot, index, index - layerStride, epoch) then
          moves = moves + 1
        else
          local start = band(randomBits(self), 7)
          for attempt = 0, 3 do
            local side = band(start + attempt, 7)
            local candidate = index + diagonalOffsets[side]
            if moveEmpty(self, slot, index, candidate, epoch) then
              moves = moves + 1
              break
            end
          end
        end
      end
    end
  end

  return moves
end

function Sand3D:step(): integer
  local epoch = self.epoch + 1
  if epoch >= 0xffff then
    ffi.fill(self.stamp, self.capacity * ffi.sizeof('uint16_t'))
    epoch = 1
  end
  self.epoch = epoch
  self.stepCount = self.stepCount + 1

  local visits = (
    tonumber(self.materialCounts[SAND]) +
    tonumber(self.materialCounts[WATER]) +
    tonumber(self.materialCounts[LAVA])
  ) as integer
  local moves =
    stepSandSystem(self, epoch) +
    stepWaterSystem(self, epoch) +
    stepLavaSystem(self, epoch)

  self.lastMoves = moves
  self.lastVisits = visits
  return moves
end

function Sand3D:bindRender(
  positions: VectorArray, colors: VectorArray, palette: VectorArray
): Sand3D
  assert(vector and vector.ctype, 'render binding requires the LÖVR SIMD math module')
  assert(tonumber(positions.length) >= self.capacity, 'position array is too small')
  assert(tonumber(colors.length) >= self.capacity, 'color array is too small')

  self.renderPositions = positions
  self.renderColors = colors
  self.renderPalette = palette
  self.renderPositionData = positions.data
  self.renderColorData = colors.data
  self.renderPaletteData = palette.data
  self.renderVector = vector.ctype
  local cellPositionArray = vector.array(self.allocation)
  self.renderCellPositions = cellPositionArray
  self.renderCellPositionData = cellPositionArray.data
  self.renderMoveCapacity = self.capacity * 8
  self.renderMoveLog = ffi.new('uint32_t[?]', self.renderMoveCapacity)
  self.renderMoveCount = 0
  self.renderColorLog = ffi.new('uint32_t[?]', self.capacity)
  self.renderColorCount = 0
  self.renderNeedsFullSync = false
  self.renderNeedsFullColorSync = false

  local cellPositions = self.renderCellPositionData as {integer: any}
  local Vector = self.renderVector as VectorConstructor
  for y = 1, self.height do
    local layer = y * self.layerStride
    for z = 1, self.depth do
      local row = layer + z * self.strideX
      for x = 1, self.width do
        cellPositions[row + x] = Vector(
          x - self.renderCenterX,
          y - .5,
          z - self.renderCenterZ,
          0
        )
      end
    end
  end

  for slot = 0, self.count - 1 do
    writePosition(self, slot)
    writeColor(self, slot)
  end

  return self
end

function Sand3D:syncRender(): integer
  if not self.renderPositionData then return 0 end

  local positionUpdates = self.renderMoveCount
  local moveLog = self.renderMoveLog as ffi.Array<integer>
  if self.renderNeedsFullSync then
    for slot = 0, self.count - 1 do writePosition(self, slot) end
    positionUpdates = self.count
  else
    for i = 0, positionUpdates - 1 do
      local slot = moveLog[i]
      if slot < self.count then writePosition(self, slot) end
    end
  end

  local colorUpdates = self.renderColorCount
  local colorLog = self.renderColorLog as ffi.Array<integer>
  if self.renderNeedsFullColorSync then
    for slot = 0, self.count - 1 do writeColor(self, slot) end
    colorUpdates = self.count
  else
    for i = 0, colorUpdates - 1 do
      local slot = colorLog[i]
      if slot < self.count then writeColor(self, slot) end
    end
  end

  self.renderMoveCount = 0
  self.renderColorCount = 0
  self.renderNeedsFullSync = false
  self.renderNeedsFullColorSync = false
  return positionUpdates + colorUpdates
end

function Sand3D:compact(
  positions: VectorArray, colors: VectorArray,
  palette: VectorArray, surfaceOnly?: boolean
): integer
  assert(vector and vector.ctype, 'compact requires the LÖVR SIMD math module')
  assert(tonumber(positions.length) >= self.capacity, 'position array is too small')
  assert(tonumber(colors.length) >= self.capacity, 'color array is too small')

  local Vector = vector.ctype
  local positionData = positions.data
  local colorData = colors.data
  local paletteData = palette.data
  local materials = self.materials
  local centerX = self.renderCenterX
  local centerZ = self.renderCenterZ
  local strideX = self.strideX
  local layerStride = self.layerStride
  local count = 0

  for slot = 0, self.count - 1 do
    local index = self.cell[slot]
    local y = floor(index / layerStride)
    local withinLayer = index - y * layerStride
    local z = floor(withinLayer / strideX)
    local x = withinLayer - z * strideX
    if not surfaceOnly or
       materials[index - 1] == EMPTY or materials[index + 1] == EMPTY or
       materials[index - strideX] == EMPTY or materials[index + strideX] == EMPTY or
       materials[index - layerStride] == EMPTY or
      y == self.height or materials[index + layerStride] == EMPTY then
      positionData[count] = Vector(
        x - centerX,
        y - .5,
        z - centerZ,
        0
      )
      colorData[count] = paletteData[
        self.material[slot] * 4 + band(self.shade[slot], 3)
      ]
      count = count + 1
    end
  end

  return count
end

function Sand3D:countMaterial(material: integer): integer
  if material == EMPTY then return self.capacity - self.count end
  if material >= SAND and material <= LAVA then
    return tonumber(self.materialCounts[material]) as integer
  end
  return 0
end

function Sand3D:memoryBytes(): integer
  return self:componentMemoryBytes() +
    self.allocation * (
      ffi.sizeof('uint8_t') +
      ffi.sizeof('uint32_t')
    ) +
    self.capacity * ffi.sizeof('uint32_t') * 3 +
    ffi.sizeof('uint32_t') * 5
end

function Sand3D:renderCacheBytes(): integer
  if not self.renderPositionData then return 0 end
  return
    self.allocation * 16 +
    self.renderMoveCapacity * ffi.sizeof('uint32_t') +
    self.capacity * ffi.sizeof('uint32_t')
end

function Sand3D:assertIntegrity(): boolean
  local occupied = 0
  local listCounts = { 0, 0, 0, 0 }

  for slot = 0, self.count - 1 do
    local index = self.cell[slot]
    local material = self.material[slot]
    assert(material >= SAND and material <= LAVA, 'invalid ECS material')
    assert(self.materials[index] == material, 'ECS material disagrees with occupancy grid')
    assert(self.cellSlot[index] == slot + 1, 'grid points to the wrong ECS slot')
    if material ~= ROCK then
      assert(
        self.materialSlots[material][self.listIndex[slot]] == slot,
        'material archetype list points to the wrong ECS slot'
      )
    end
    listCounts[material] = listCounts[material] + 1
  end

  for material = SAND, LAVA do
    assert(
      listCounts[material] == self.materialCounts[material],
      'material archetype count does not match ECS entities'
    )
  end

  for y = 1, self.height do
    local layer = y * self.layerStride
    for z = 1, self.depth do
      local row = layer + z * self.strideX
      for x = 1, self.width do
        local index = row + x
        local material = self.materials[index]
        assert(material >= EMPTY and material <= LAVA, 'invalid material in interior grid')
        if material ~= EMPTY then
          occupied = occupied + 1
          local slot = self.cellSlot[index] - 1
          assert(slot >= 0 and slot < self.count, 'occupied cell has no ECS entity')
          assert(self.cell[slot] == index, 'ECS entity points to the wrong cell')
        else
          assert(self.cellSlot[index] == 0, 'empty cell points to an ECS entity')
        end
      end
    end
  end

  assert(occupied == self.count, 'occupancy grid does not match ECS entity count')
  assert(self.population == self.count, 'population counter does not match ECS entity count')
  return true
end

return Sand3D
