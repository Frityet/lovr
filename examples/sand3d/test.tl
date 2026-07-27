package.path = 'examples/sand3d/?.lua;' .. package.path

local ffi = require 'ffi'
local Sand3D = require 'sim'
local Effects = require 'effects'
local ecs = require 'ecs'

ecs.define!(do
  local record TestArchetype
  end
end, {
  position = u32,
  kind = u8,
})
local archetype = TestArchetype.newECS(4)
local first = archetype:allocate()
local second = archetype:allocate()
local third = archetype:allocate()
archetype.position[first], archetype.kind[first] = 11, 1
archetype.position[second], archetype.kind[second] = 22, 2
archetype.position[third], archetype.kind[third] = 33, 3
archetype:removeSwap(second)
assert(archetype.count == 2, 'ECS swap removal did not reduce the dense count')
assert(
  archetype.position[second] == 33 and archetype.kind[second] == 3,
  'ECS swap removal did not keep components dense'
)
assert(archetype:componentMemoryBytes() == 20, 'ECS component memory accounting is incorrect')

local sim = Sand3D.new(12, 12, 12, 12345)
assert(type(sim.cell) == 'cdata', 'cell components are not FFI arrays')
assert(type(sim.materialSlots[Sand3D.SAND]) == 'cdata', 'material archetype is not FFI-backed')

sim:set(6, 3, 6, Sand3D.SAND, 0)
assert(sim.population == 1)
sim:step()
assert(sim:get(6, 2, 6) == Sand3D.SAND, 'sand did not fall one cell')
sim:step()
assert(sim:get(6, 1, 6) == Sand3D.SAND, 'sand did not reach the floor')
sim:step()
assert(sim.population == 1, 'floor collision lost a particle')

sim:clear()
sim:set(6, 1, 6, Sand3D.WATER, 0)
for z = 5, 7 do
  for x = 5, 7 do
    if x ~= 6 or z ~= 6 then sim:set(x, 1, z, Sand3D.ROCK, 0) end
  end
end
sim:set(6, 2, 6, Sand3D.SAND, 0)
sim:step()
assert(sim:get(6, 1, 6) == Sand3D.SAND, 'sand did not sink through water')
assert(sim:get(6, 2, 6) == Sand3D.WATER, 'water did not swap above sinking sand')

sim:clear()
sim:emit(6, 10, 6, Sand3D.SAND, 4, 200)
sim:emit(8, 11, 8, Sand3D.WATER, 3, 100)
sim:emit(4, 9, 4, Sand3D.LAVA, 2, 40)
local population = sim.population
for _ = 1, 120 do sim:step() end
assert(sim.population == population, 'simulation did not conserve particles')
assert(sim:assertIntegrity())

sim:paintSphere(6, 6, 6, 2, Sand3D.ROCK, true)
assert(sim:countMaterial(Sand3D.ROCK) > 0)
sim:paintSphere(6, 6, 6, 2, Sand3D.EMPTY, true)
assert(sim:assertIntegrity())

local effects = Effects.new(128, .17, 6789)
for material = Sand3D.EMPTY, Sand3D.LAVA do
  effects:spawn(0, 2, 0, material, 20, 1)
end
assert(type(effects.x) == 'cdata', 'effect positions are not FFI arrays')
assert(effects.simdWidth == 4 or effects.simdWidth == 8, 'effect SIMD width is invalid')
assert(effects.count == 100, 'effect spawn count is incorrect')
assert(effects:memoryBytes() == 128 * 46, 'effect memory accounting is incorrect')
effects:update(1 / 60)
assert(effects.count > 0 and effects.y[0] ~= 2, 'effects did not advance')
for _ = 1, 360 do effects:update(1 / 60) end
assert(effects.count == 0, 'expired effects were not compacted')

print('sand3d simulation tests passed')
