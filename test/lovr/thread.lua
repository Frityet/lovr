group('thread', function()
  group('Thread', function()
    test(':start', function()
      local thread = lovr.thread.newThread([[
        require('lovr.data')
        assert((...):type() == 'Blob')
      ]])

      thread:start(lovr.data.newBlob(1))
      thread:wait()
    end)

    test('SIMD and matrix arguments', function()
      local thread = lovr.thread.newThread([[
        local ffi = require 'ffi'
        local simd = require 'ffi.simd'
        local m, v, q = ...
        assert(type(v) == 'cdata' and simd.isvector(v))
        assert(type(q) == 'cdata' and simd.isvector(q))
        assert(type(m) == 'cdata' and not simd.isvector(m))
        assert(ffi.typeof(v) == vector.ctype)
        assert(ffi.typeof(q) == quaternion.ctype)
        assert(ffi.typeof(m) == mat4.ctype)
        assert(v.x == 1 and v.y == 2 and v.z == 3)
        assert(q.x == 4 and q.y == 5 and q.z == 6 and q.w == 7)
        for i = 1, 16 do assert(m[i] == i) end
      ]])

      thread:start(
        mat4(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16),
        vector(1, 2, 3),
        quaternion.pack(4, 5, 6, 7)
      )
      thread:wait()
      expect(thread:getError()).to.be(nil)
    end)
  end)

  group('Channel', function()
    test('push/pop', function()
      local channel = lovr.thread.getChannel('test')
      local data = { 123, a = 1, b = channel, c = { 321, a = channel }, d = {} }
      channel:push(data)
      expect(channel:pop()).to.equal(data)

      local t = { 123, a = 1 }
      t.t = t
      expect(function() channel:push(t) end).to.fail()
    end)

    test('SIMD and matrix values', function()
      local ffi = require 'ffi'
      local simd = require 'ffi.simd'
      local channel = lovr.thread.getChannel('simd')
      local v = vector(1, 2, 3)
      local q = quaternion.pack(4, 5, 6, 7)
      local m = mat4(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16)

      channel:push(v)
      channel:push(q)
      channel:push(m)

      local poppedVector = channel:pop()
      local poppedQuaternion = channel:pop()
      local constructor = mat4
      _G.mat4 = nil
      local ok, poppedMatrix = pcall(function() return channel:pop() end)
      _G.mat4 = constructor
      expect(ok).to.be(true)
      expect(simd.isvector(poppedVector)).to.be(true)
      expect(simd.isvector(poppedQuaternion)).to.be(true)
      expect(ffi.typeof(poppedVector)).to.be(vector.ctype)
      expect(ffi.typeof(poppedQuaternion)).to.be(quaternion.ctype)
      expect(ffi.typeof(poppedMatrix)).to.be(mat4.ctype)
      expect(poppedVector:unpack()).to.equal(1, 2, 3)
      expect(poppedQuaternion:unpack()).to.equal(4, 5, 6, 7)
      expect(poppedMatrix:unpack(true)).to.equal(
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
      )
    end)
  end)
end)
