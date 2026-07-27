# Vector arithmetic metatypes

## Observation

LuaJITMT's packed vector arithmetic originally ran before FFI arithmetic
metamethod lookup.  A vector ctype could have an `__mul` metatype, but `a * b`
still performed component-wise multiplication.

That blocks a true SIMD quaternion type: quaternion multiplication and
quaternion-vector rotation need Hamilton/rotation semantics, while ordinary
vectors need packed component-wise multiplication.

The smallest reproducer is:

```lua
local ffi = require 'ffi'
ffi.cdef[[
typedef const float meta_float4 __attribute__((vector_size(16)));
]]

local float4 = ffi.metatype('meta_float4', {
  __mul = function() return 42 end
})

assert(float4(1) * float4(2) == 42)
```

## Resolution

`lj_carith.c` now checks actual vector operands for an explicitly registered
arithmetic metamethod before using built-in packed arithmetic.
`lj_crecord.c` applies the same precedence while recording a trace.

Packed vector types without an arithmetic metatype retain the original direct
SIMD behavior.  The regression in `test/simd/test_jit.lua` runs the custom
operator in interpreter, JIT, and mixed modes.

## Related type-system detail

`const float __attribute__((vector_size(16)))` is a distinct ctype from the
plain float vector and can have a different metatype.  This makes it useful
for the quaternion tag while keeping a genuine SIMD value.

`ffi.istype` intentionally accepts qualifier-compatible types, however.  It
reports both the plain and const float vectors as compatible.  Code that needs
to distinguish LÖVR vectors from quaternions must use exact ctype identity:

```lua
ffi.typeof(value) == quaternion.ctype
```
