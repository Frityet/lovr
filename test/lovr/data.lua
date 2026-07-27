group('data', function()
  group('DataArray', function()
    local ffi = require 'ffi'

    ffi.cdef[[
      typedef struct {
        float position[4];
        uint32_t material;
        uint32_t padding[3];
      } lovr_test_particle;
    ]]

    test('owned typed storage', function()
      local array = lovr.data.newArray('float', 4)
      expect(type(array)).to.equal('cdata')
      expect(array:type()).to.equal('DataArray')
      expect(#array).to.equal(4)
      expect(array:getCount()).to.equal(4)
      expect(array:getStride()).to.equal(4)
      expect(array:getSize()).to.equal(16)
      expect(tonumber(ffi.cast('uintptr_t', array.data)) % 32).to.equal(0)

      array[1] = 1.25
      array[4] = -9.5
      expect(array[1]).to.equal(1.25)
      expect(array[4]).to.equal(-9.5)
      expect(lovr.data.isArray(array)).to.equal(true)
      expect(lovr.data.isSpan(array)).to.equal(false)
    end)

    test('arbitrary FFI structs', function()
      local array = lovr.data.newArray('lovr_test_particle', 2)
      local particles = array:getPointer()
      particles[0].position[0] = 1
      particles[0].position[1] = 2
      particles[0].position[2] = 3
      particles[0].position[3] = 4
      particles[0].material = 17
      particles[1].material = 23

      expect(array:getStride()).to.equal(32)
      expect(array[1].position[2]).to.equal(3)
      expect(array[1].material).to.equal(17)
      expect(array[2].material).to.equal(23)
    end)

    test('SIMD vector elements', function()
      local array = lovr.data.newArray(vector.ctype, 2)
      array[1] = vector.pack(1, 2, 3)
      array[2] = vector.pack(4, 5, 6)
      expect(array:getStride()).to.equal(16)
      expect(array[1]).to.equal(vector.pack(1, 2, 3))
      expect(array[2]).to.equal(vector.pack(4, 5, 6))
    end)

    test('spans retain and mutate their owner', function()
      local span
      do
        local array = lovr.data.newArray('uint32_t', 4, { 10, 20, 30, 40 })
        span = array:span(2, 2)
      end

      collectgarbage()
      collectgarbage()
      expect(span:type()).to.equal('DataSpan')
      expect(#span).to.equal(2)
      expect(span[1]).to.equal(20)
      span[2] = 99
      expect(span[2]).to.equal(99)
      expect(lovr.data.isSpan(span)).to.equal(true)
    end)

    test('external FFI array spans', function()
      local source = ffi.new('uint32_t[4]', 5, 6, 7, 8)
      local span = lovr.data.newSpan(source, 'uint32_t', 2, 2)
      source = nil
      collectgarbage()
      collectgarbage()
      expect(span[1]).to.equal(6)
      expect(span[2]).to.equal(7)
    end)

    test('copy, clear, and bounds', function()
      local array = lovr.data.newArray('int32_t', 4, { 1, 2, 3, 4 })
      array:copy(array, 2, 1, 3)
      expect(array[1]).to.equal(1)
      expect(array[2]).to.equal(1)
      expect(array[3]).to.equal(2)
      expect(array[4]).to.equal(3)

      array:copy(array, 1, 2, 3)
      expect(array[1]).to.equal(1)
      expect(array[2]).to.equal(2)
      expect(array[3]).to.equal(3)
      expect(array[4]).to.equal(3)

      array:clear(2, 2)
      expect(array[2]).to.equal(0)
      expect(array[3]).to.equal(0)

      expect(function() return array[0] end).to.fail()
      expect(function() array:span(4, 2) end).to.fail()
      expect(function() lovr.data.newArray('void', 1) end).to.fail()
      expect(function()
        lovr.data.newSpan(ffi.cast('float*', 0), 'float', 1)
      end).to.fail()
    end)
  end)

  group('Blob', function()
    test(':getName', function()
      -- Test that Blob copies its name instead of relying on Lua string staying live
      blob = lovr.data.newBlob('foo', 'b' .. 'ar')
      collectgarbage()
      expect(blob:getName()).to.equal('b' .. 'ar')
    end)

    test(':set* byte range', function()
      blob = lovr.data.newBlob(1)
      expect(function() blob:setU8(-10, 7) end).to.fail()
      expect(function() blob:setU8(10, 7) end).to.fail()
      expect(function() blob:setF32(0, 7) end).to.fail()
    end)

    test(':setI8', function()
      blob = lovr.data.newBlob(16)
      for i = 1, 16 do blob:setI8(i - 1, i - 8) end
      for i = 1, 16 do expect(blob:getI8(i - 1)).to.equal(i - 8) end
    end)

    test(':setU8', function()
      blob = lovr.data.newBlob(16)
      for i = 1, 16 do blob:setU8(i - 1, i + 150) end
      for i = 1, 16 do expect(blob:getU8(i - 1)).to.equal(i + 150) end
    end)

    test(':setI16', function()
      blob = lovr.data.newBlob(4)
      blob:setI16(0, -5000, 5000)
      expect(blob:getI16(0)).to.equal(-5000)
      expect(blob:getI16(2)).to.equal(5000)
    end)

    test(':setU16', function()
      blob = lovr.data.newBlob(6)
      blob:setU16(0, 0, 1, 60000)
      expect(blob:getU16()).to.equal(0)
      expect(blob:getU16(2, 2)).to.equal(1, 60000)
    end)

    test(':setI32', function()
      blob = lovr.data.newBlob(8)
      blob:setI32(4, -12345678)
      expect(blob:getI32(4)).to.equal(-12345678)
    end)

    test(':setU32', function()
      blob = lovr.data.newBlob(4)
      blob:setU32(0, 0xaabbccdd)
      expect(blob:getU32()).to.equal(0xaabbccdd)
      expect(blob:getU8(0)).to.equal(0xdd)
      expect(blob:getU8(1)).to.equal(0xcc)
      expect(blob:getU8(2)).to.equal(0xbb)
      expect(blob:getU8(3)).to.equal(0xaa)
    end)

    test(':setF32', function()
      blob = lovr.data.newBlob(12)
      blob:setF32(0, 1, -1000, 1000000)
      expect(blob:getF32(0, 3)).to.equal(1, -1000, 1000000)
    end)

    test(':setF64', function()
      blob = lovr.data.newBlob(8)
      blob:setF64(0, 2 ^ 53)
      expect(blob:getF64(0)).to.equal(2 ^ 53)
    end)

    test('.newBlobView', function ()
      local blob = lovr.data.newBlob(4)
      blob:setU8(0, 0, 1, 2, 3)
      expect(function() lovr.data.newBlobView(blob, -1) end).to.fail()
      expect(function() lovr.data.newBlobView(blob, 1, 4) end).to.fail()
      local blobView = lovr.data.newBlobView(blob, 1, 2, 'name')
      expect(blobView:getU8(0)).to.equal(1)
      expect(blobView:getU8(1)).to.equal(2)
      expect(function() blobView:getU8(2) end).to.fail()
      expect(blobView:getName()).to.equal('name')
    end)
  end)

  group('Image', function()
    test(':setPixel', function()
      local image = lovr.data.newImage(4, 4)
      image:setPixel(0, 0, 1, 0, 0, 1)
      expect(image:getPixel(0, 0)).to.equal(1, 0, 0, 1)

      -- Default alpha
      image:setPixel(1, 1, 0, 1, 0)
      expect(image:getPixel(1, 1)).to.equal(0, 1, 0, 1)

      -- Out of bounds
      expect(function() image:setPixel(4, 4, 0, 0, 0, 0) end).to.fail()
      expect(function() image:setPixel(-4, -4, 0, 0, 0, 0) end).to.fail()

      -- f16
      image = lovr.data.newImage(4, 4, 'rg16f')
      image:setPixel(0, 0, 1, 2, 3, 4)
      image:setPixel(3, 3, 9, 8, 7, 6)
      expect(image:getPixel(0, 0)).to.equal(1, 2, 0, 1)
      expect(image:getPixel(3, 3)).to.equal(9, 8, 0, 1)
    end)
  end)

  group('ModelData', function()
    local blob = lovr.data.newBlob([[{
      "asset": { "version": "2.0" },
      "scene": 0,
      "scenes": [{ "nodes": [0] }],
      "nodes": [{ "mesh": 0 }],
      "meshes": [
        {
          "primitives": [{ "attributes": { "POSITION": 0 } }]
        }
      ],
      "buffers": [
        {
          "uri": "data:application/octet-stream;base64,AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA",
          "byteLength": 36
        }
      ],
      "bufferViews": [
        {
          "buffer": 0,
          "byteOffset": 0,
          "byteLength": 36,
          "target": 34962
        }
      ],
      "accessors": [
        {
          "bufferView": 0,
          "byteOffset": 0,
          "componentType": 5126,
          "count": 3,
          "type": "VEC3",
          "max": [1, 1, 0],
          "min": [0, 0, 0]
        }
      ]
    }]])

    local model = lovr.data.newModelData(blob)

    test('getMetadata', function()
      expect(model:getMetadata()).to.equal(blob:getString())
    end)

    test('nodes', function()
      expect(model:getRootNode()).to.equal(1)
      expect(model:getNodeCount()).to.equal(1)
      expect(model:getNodeName(1)).to.equal(nil)
      expect(model:getNodeChild(1)).to.equal(nil)
      expect(model:getNodeSibling(1)).to.equal(nil)
      expect(model:getNodeParent(1)).to.equal(nil)
      expect(model:getNodeTransform(1)).to.equal(0, 0, 0, 1, 1, 1, 0, 0, 0, 0)
      expect(model:getNodeMesh(1)).to.equal(1)
      expect(model:getNodeSkin(1)).to.equal(nil)
      expect(function() model:getNodeChild(2) end).to.fail()
    end)

    test('meshes', function()
      expect(model:getMeshCount()).to.equal(1)
      expect(model:getMeshBlendShapeCount(1)).to.equal(0)
      expect(model:getMeshVertexCount(1)).to.equal(3)
      expect(model:getMeshIndexCount(1)).to.equal(0)
      expect(model:getMeshVertex(1, 1)).to.equal(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0)
      expect(model:getMeshVertex(1, 2)).to.equal(1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0)
      expect(model:getMeshVertex(1, 3)).to.equal(0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0)
      expect(model:getMeshPartCount(1)).to.equal(1)
      expect(model:getMeshDrawMode(1)).to.equal('triangles')
      expect(model:getMeshDrawRange(1)).to.equal(1, 3)
      expect(model:getMeshMaterial(1)).to.equal(nil)
    end)

    test('bounds', function()
      expect(model:getWidth()).to.equal(1)
      expect(model:getHeight()).to.equal(1)
      expect(model:getDepth()).to.equal(0)
      expect(model:getDimensions()).to.equal(1, 1, 0)
      expect(model:getCenter()).to.equal(.5, .5, 0)
      expect(model:getBoundingBox()).to.equal(0, 1, 0, 1, 0, 0)
    end)
  end)
end)
