# Typed FFI data arrays

`lovr.data.newArray` allocates owned, 32-byte-aligned FFI storage.  It is
intended for ECS components, instance data, simulation state, and other
packed values that should cross into LÖVR without becoming Lua tables.

```lua
local ffi = require 'ffi'

ffi.cdef[[
typedef struct {
  float position[4];
  float color[4];
} Particle;
]]

local particles = lovr.data.newArray('Particle', 10000)
local pointer = particles:getPointer()

pointer[0].position[0] = 1
pointer[0].position[1] = 2
pointer[0].position[2] = 3
pointer[0].position[3] = 1
```

The array itself and all of its elements are cdata.  Numeric indexing is
one-based, while the typed pointer returned by `getPointer` uses normal
zero-based C indexing.  The hot-loop form should cache this pointer.

## Spans

`array:span(first, count)` creates a lightweight cdata view.  A span retains
its source allocation, so it is safe for the span to outlive the local
variable that originally held the array.

```lua
local middle = particles:span(101, 500)
buffer:setData(middle)
```

Existing owning FFI arrays can be viewed without a copy:

```lua
local storage = ffi.new('Particle[?]', 10000)
local view = lovr.data.newSpan(storage, 'Particle', 10000)
```

Raw pointers are deliberately rejected because they do not provide an owner
or a verifiable byte range.

## Graphics buffers

`Buffer:setData` and `lovr.graphics.newBuffer` recognize DataArrays and
DataSpans.  Their element stride must exactly match the destination buffer
stride, after LÖVR applies the selected buffer layout.

```lua
local format = {
  { 'position', 'vec4' },
  { 'color', 'vec4' }
}

local buffer = lovr.graphics.newBuffer(format, particles)
buffer:setData(particles:span(1, activeCount), 1)
```

The matching stride permits a single bulk copy with no Lua element traversal.
For structured formats, the FFI structure is still responsible for matching
the field offsets and raw representations.  Add explicit padding to the FFI
type when using `std140`, `std430`, or custom strides.

Common LÖVR scalar and packed type names such as `float`, `vec4`, `i32`,
`u32x4`, and `mat4` are accepted as convenience aliases.  Any fixed-size FFI
ctype can be used directly, including LuaJITMT SIMD vector ctypes:

```lua
local vectors = lovr.data.newArray(vector.ctype, 4096)
```

Arrays provide `fill`, `clear`, `copy`, `span`, `getPointer`, `getCount`,
`getStride`, `getSize`, and `getElementType`.  DataArrays and DataSpans are
local to their Lua state; use a Blob when data needs to cross a LÖVR thread or
channel boundary.
