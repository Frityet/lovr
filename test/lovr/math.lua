local ffi = require 'ffi'
local simd = require 'ffi.simd'

local function expectVector(v, x, y, z)
  expect(type(v)).to.be('cdata')
  expect(simd.isvector(v)).to.be(true)
  expect(ffi.typeof(v)).to.be(vector.ctype)
  expect(v:unpack()).to.approximately.equal(x, y, z)
  expect(v[3]).to.be(0)
end

local function expectQuaternion(q, x, y, z, w)
  expect(type(q)).to.be('cdata')
  expect(simd.isvector(q)).to.be(true)
  expect(ffi.typeof(q)).to.be(quaternion.ctype)
  expect(q:unpack()).to.approximately.equal(x, y, z, w)
end

group('math', function()
  group('vector', function()
    test('constructors and fields', function()
      expectVector(vector(), 0, 0, 0)
      expectVector(vector(2), 2, 2, 2)
      expectVector(vector(2, 3), 2, 3, 0)
      expectVector(vector.pack(2, 3, 4), 2, 3, 4)

      local v = vector(5, 6, 7)
      expect(vector(v)).to.be(v)
      expect(v.x, v.y, v.z).to.equal(5, 6, 7)
      expect(function() vector(quaternion()) end).to.fail()
    end)

    test('constants', function()
      expectVector(vector.zero, 0, 0, 0)
      expectVector(vector.one, 1, 1, 1)
      expectVector(vector.left, -1, 0, 0)
      expectVector(vector.right, 1, 0, 0)
      expectVector(vector.up, 0, 1, 0)
      expectVector(vector.down, 0, -1, 0)
      expectVector(vector.forward, 0, 0, -1)
      expectVector(vector.backward, 0, 0, 1)
      expect(vector.back).to.be(vector.backward)
    end)

    test('packed operators', function()
      local a = vector(2, 4, 8)
      local b = vector(1, 2, 4)
      expectVector(a + b, 3, 6, 12)
      expectVector(a - b, 1, 2, 4)
      expectVector(a * b, 2, 8, 32)
      expectVector(a / b, 2, 2, 2)
      expectVector(a + 1, 3, 5, 9)
      expectVector(1 + a, 3, 5, 9)
      expectVector(a - 1, 1, 3, 7)
      expectVector(10 - a, 8, 6, 2)
      expectVector(a * 2, 4, 8, 16)
      expectVector(2 * a, 4, 8, 16)
      expectVector(a / 2, 1, 2, 4)
      expectVector(16 / a, 8, 4, 2)
      expectVector(-a, -2, -4, -8)
    end)

    test('length and normalize', function()
      expect(vector(2, 3, 6):length()).to.approximately.equal(7)
      expectVector(vector(0, 3, 4):normalize(), 0, .6, .8)
      expectVector(vector.zero:normalize(), 0, 0, 0)
    end)

    test('distance', function()
      expect(vector(1, 2, 3):distance(vector(4, 6, 3))).to.approximately.equal(5)
    end)

    test('cross', function()
      expectVector(vector.right:cross(vector.up), 0, 0, 1)
      expectVector(vector.up:cross(vector.right), 0, 0, -1)
    end)

    test('dot', function()
      expect(vector(1, 2, 3):dot(vector(4, 5, 6))).to.approximately.equal(32)
    end)

    test('angle', function()
      expect(vector.right:angle(vector.up)).to.approximately.equal(math.pi / 2)
      expect(vector.right:angle(vector.up, vector.forward)).to.approximately.equal(-math.pi / 2)
      expect(vector.right:angle(vector.up, vector.backward)).to.approximately.equal(math.pi / 2)
    end)

    test('lerp', function()
      expectVector(vector(1, 2, 3):lerp(vector(5, 6, 7), .25), 2, 3, 4)
    end)

    test('rotate', function()
      local q = quaternion(math.pi / 2, 0, 0, 1)
      expectVector(vector.right:rotate(q), 0, 1, 0)
    end)

    test('tostring', function()
      expect(tostring(vector(1, 2, 3))).to.be('1.000000, 2.000000, 3.000000')
    end)
  end)

  group('Curve', function()
    test(':slice', function()
      local points = {
        vec3(0, 0, 0),
        vec3(0, 1, 0),
        vec3(1, 2, 0),
        vec3(2, 1, 0),
        vec3(2, 0, 0)
      }

      curve = lovr.math.newCurve(points)
      slice = curve:slice(0, 1)
      for i = 1, #points do
        expect(curve:getPoint(i)).to.equal(slice:getPoint(i))
      end
    end)
  end)

  group('Mat4', function()
    test(':set', function()
      local position = vector(1, 2, 3)
      local rotation = quaternion(1.2, 1, 0, 0)
      local scale = vector(1.5, 2.5, 3.5)
      local matrix = lovr.math.newMat4()

      matrix:set(position, scale, rotation)
      expect(matrix:unpack()).to.approximately.equal(1, 2, 3, 1.5, 2.5, 3.5, 1.2, 1, 0, 0)

      matrix:set(position, scale)
      expect(matrix:unpack()).to.approximately.equal(1, 2, 3, 1.5, 2.5, 3.5, 0, 0, 0, 0)

      matrix:set(position, 1.5, 2.5, 3.5)
      expect(matrix:unpack()).to.approximately.equal(1, 2, 3, 1.5, 2.5, 3.5, 0, 0, 0, 0)

      matrix:set(position, rotation)
      expect(matrix:unpack()).to.approximately.equal(1, 2, 3, 1, 1, 1, 1.2, 1, 0, 0)

      matrix:set(position, 1.2, 1, 0, 0)
      expect(matrix:unpack()).to.approximately.equal(1, 2, 3, 1, 1, 1, 1.2, 1, 0, 0)

      matrix:set(position, { rotation:unpack() })
      expect(matrix:unpack()).to.approximately.equal(1, 2, 3, 1, 1, 1, 1.2, 1, 0, 0)
    end)

    group(':mul', function()
      test('Mat4', function()
        local a = lovr.math.newMat4():perspective(math.rad(80), 1440 / 900, .01, 0)
        local b = lovr.math.newMat4(vector(0, 1.7, 0), quaternion.pack(0, 0, 0, 1)):invert()
        local r = {
          0.74484598636627, 0, 0, 0,
          0, -1.1917536258698, 0, 0,
          0, 0, 0, -1,
          0, 2.0259811878204, 0.0099999997764826, 0
        }
        expect({ (a * b):unpack(true) }).to.approximately.equal(r)
        expect({ (a * b):unpack(true) }).to.approximately.equal(r)
        expect({ (a:mul(b)):unpack(true) }).to.approximately.equal(r)
      end)

      test('vector', function()
        v = vector(1, 2, 3)
        array = setmetatable({ 1, 2, 3 }, {})
        keyval = setmetatable({ x = 1, y = 2, z = 3 }, {})

        matrix = lovr.math.newMat4(vector(0, 2, 0), quaternion(0, 0, 0, 1))

        expect(matrix * array).to.equal({ 1, 4, 3 })
        expect(matrix:mul(array)).to.equal({ 1, 4, 3 })
        expect(matrix * v).to.equal(vector(1, 4, 3))
        expect(matrix:mul(v)).to.equal(vector(1, 4, 3))
        expect(matrix * keyval).to.equal({ x = 1, y = 4, z = 3 })
        expect(matrix:mul(keyval)).to.equal({ x = 1, y = 4, z = 3 })

        expect(getmetatable(matrix * array)).to.be(getmetatable(array))
        expect(getmetatable(matrix * keyval)).to.be(getmetatable(keyval))
        expect(getmetatable(matrix * v)).to.be(getmetatable(v))
      end)
    end)

    test(':setPosition', function()
      matrix = lovr.math.newMat4():setPosition(1, 2, 3)
      expect(matrix:unpack()).to.approximately.equal(1,2,3, 1,1,1, 0,0,0,0)
      matrix:setPosition(vector(3, 4, 5))
      expect(matrix:unpack()).to.approximately.equal(3,4,5, 1,1,1, 0,0,0,0)
    end)

    test(':getOrientation', function()
      matrix = lovr.math.newMat4():target({ 0, 1, -1 }, { 0, 1.7, 0 })
      expect(matrix:getOrientation()).to.approximately.equal(3.1415, 0, 0.9537, -0.3006)
    end)

    test(':setOrientation', function()
      matrix = lovr.math.newMat4():setOrientation(1, 0, 1, 0)
      expect(matrix:unpack()).to.approximately.equal(0,0,0, 1,1,1, 1,0,1,0)
      matrix:setScale(2)
      matrix:setOrientation(quaternion(2, 1, 0, 0))
      expect(matrix:unpack()).to.approximately.equal(0,0,0, 2,2,2, 2,1,0,0)
    end)

    test(':setScale', function()
      matrix = lovr.math.newMat4():setScale(1.5, 2.5, 3.5)
      expect(matrix:unpack()).to.equal(0,0,0, 1.5,2.5,3.5, 0,0,0,0)
      matrix:setScale(vector(3.5, 4.5, 5.5))
      expect(matrix:unpack()).to.equal(0,0,0, 3.5,4.5,5.5, 0,0,0,0)
    end)

    test(':setPose', function()
      matrix = lovr.math.newMat4():setPose(7,8,9, 1,0,0,1)
      expect(matrix:unpack()).to.approximately.equal(7,8,9, 1,1,1, 1,0,0,1)
      matrix:setScale(2)
      matrix:setPose(vector(2, 5, 7), quaternion(3, 1, 0, 0))
      expect(matrix:unpack()).to.approximately.equal(2,5,7, 2,2,2, 3,1,0,0)
    end)
  end)

  test('random', function()
    lovr.math.setRandomSeed(7)
    local a = lovr.math.random()
    local b = lovr.math.random()

    lovr.math.setRandomSeed(7)
    expect(lovr.math.random()).to.equal(a)
    expect(lovr.math.random()).to.equal(b)
  end)

  test('randomNormal', function()
    lovr.math.setRandomSeed(7)
    local a = lovr.math.randomNormal()
    local b = lovr.math.randomNormal()

    lovr.math.setRandomSeed(7)
    expect(lovr.math.randomNormal()).to.equal(a)
    expect(lovr.math.randomNormal()).to.equal(b)
  end)

  group('quaternion', function()
    test('constructors and fields', function()
      expectQuaternion(quaternion(), 0, 0, 0, 1)
      expectQuaternion(quaternion.pack(1, 2, 3, 4), 1, 2, 3, 4)

      local q = quaternion.pack(5, 6, 7, 8)
      expect(quaternion(q)).to.be(q)
      expect(q.x, q.y, q.z, q.w).to.equal(5, 6, 7, 8)
      expect(function() quaternion(vector.one) end).to.fail()
      expect(ffi.typeof(vector.one) == ffi.typeof(quaternion.identity)).to.be(false)
    end)

    test('identity', function()
      expectQuaternion(quaternion.identity, 0, 0, 0, 1)
    end)

    test('conjugate', function()
      expectQuaternion(quaternion.pack(1, 2, 3, 4):conjugate(), -1, -2, -3, 4)
    end)

    test('angleaxis and toangleaxis', function()
      local q = quaternion(1.2, 1, 0, 0)
      expectQuaternion(q, .564642, 0, 0, .825336)
      expectQuaternion(quaternion(1.2, 0, 0, 0), 0, 0, 0, 1)
      expect(q:toangleaxis()).to.approximately.equal(1.2, 1, 0, 0)
      expect(quaternion.identity:toangleaxis()).to.approximately.equal(0, 0, 0, 0)
    end)

    test('euler and toeuler', function()
      local ax, ay, az = .3, -.4, .7
      local q = quaternion.euler(ax, ay, az)
      expectQuaternion(q, q.x, q.y, q.z, q.w)
      expect(q:toeuler()).to.approximately.equal(ax, ay, az)

      local north = quaternion.euler(math.pi / 2, .25, 0)
      expect(north:toeuler()).to.approximately.equal(math.pi / 2, .25, 0)

      local south = quaternion.euler(-math.pi / 2, .25, 0)
      expect(south:toeuler()).to.approximately.equal(-math.pi / 2, .25 - 2 * math.pi, 0)
    end)

    test('between', function()
      local q = quaternion.between(vector.right, vector.up)
      expectQuaternion(q, 0, 0, math.sqrt(.5), math.sqrt(.5))
      expectVector(q * vector.right, 0, 1, 0)
      expect(quaternion.between(vector.right, vector.right)).to.be(quaternion.identity)
      expect(quaternion.between(vector.right, vector.left)).to.be(quaternion.identity)
    end)

    test('lookdir and direction', function()
      local identity = quaternion.lookdir(vector.forward)
      expectQuaternion(identity, 0, 0, 0, 1)
      expectVector(identity:direction(), 0, 0, -1)

      local right = quaternion.lookdir(vector.right)
      expectVector(right:direction(), 1, 0, 0)

      expect(quaternion.lookdir(vector.zero)).to.be(quaternion.identity)
      expectVector(quaternion.lookdir(vector.up, vector.up):direction(), 0, 1, 0)
    end)

    test('slerp', function()
      local q = quaternion.identity
      local r = quaternion(math.pi, 0, 1, 0)
      local halfway = q:slerp(r, .5)
      expectQuaternion(halfway, 0, math.sqrt(.5), 0, math.sqrt(.5))
      expectVector(halfway:direction(), -1, 0, 0)
      expect(q:slerp(q, .25)).to.be(q)

      local near = quaternion(.01, 0, 1, 0)
      expectQuaternion(q:slerp(near, .5), 0, math.sin(.0025), 0, math.cos(.0025))
    end)

    test('multiply', function()
      local q = quaternion(math.pi / 2, 0, 0, 1)
      expectVector(q * vector(1, 2, 3), -2, 1, 3)
      expectQuaternion(q * q, 0, 0, 1, 0)
      expect(function() return q * 2 end).to.fail()
    end)

    test('tostring', function()
      expect(tostring(quaternion.pack(1, 2, 3, 4))).to.be('1.000000, 2.000000, 3.000000, 4.000000')
    end)

    test('hot loop JIT', function()
      local r = quaternion.pack(.5, -.5, .5, .5)
      local q = quaternion.identity
      local v = vector(1, 2, 3)
      local a = vector(9, 8, 7)
      local b = vector(1, 2, 3)

      for _ = 1, 600 do
        q = q * r
        v = r * v
        a = (a + b) * .5
      end

      expectQuaternion(q, 0, 0, 0, 1)
      expectVector(v, 1, 2, 3)
      expectVector(a, 1, 2, 3)
    end)
  end)

  test('gammaToLinear', function()
    expect(function() lovr.math.gammaToLinear() end).to.fail()
    expect(lovr.math.gammaToLinear(.5, .5, .5)).to.approximately.equal(.214, .214, .214)
    expect(lovr.math.gammaToLinear(.5, .5, .5, .5)).to.approximately.equal(.214, .214, .214, .5)
    expect(lovr.math.gammaToLinear(.5, .5, .5, .5, 7)).to.approximately.equal(.214, .214, .214, .5)
    expect(lovr.math.gammaToLinear({ .5, .5, .5, .5 })).to.approximately.equal(.214, .214, .214, .5)
    expect(lovr.math.gammaToLinear({ .5, .5, .5 })).to.approximately.equal(.214, .214, .214)
    expect(lovr.math.gammaToLinear(.5)).to.approximately.equal(.214)
  end)

  test('linearToGamma', function()
    expect(function() lovr.math.linearToGamma() end).to.fail()
    expect(lovr.math.linearToGamma(.5, .5, .5)).to.approximately.equal(.735, .735, .735)
    expect(lovr.math.linearToGamma(.5, .5, .5, .5)).to.approximately.equal(.735, .735, .735, .5)
    expect(lovr.math.linearToGamma(.5, .5, .5, .5, 7)).to.approximately.equal(.735, .735, .735, .5)
    expect(lovr.math.linearToGamma({ .5, .5, .5, .5 })).to.approximately.equal(.735, .735, .735, .5)
    expect(lovr.math.linearToGamma({ .5, .5, .5 })).to.approximately.equal(.735, .735, .735)
    expect(lovr.math.linearToGamma(.5)).to.approximately.equal(.735)
  end)
end)
