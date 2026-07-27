# Constant lane extraction and allocation sinking

## Observation

Indexing a loop-carried vector through a constant lane, especially after an
`ffi.simd.bitcast`, prevented its temporary cdata box from being sunk:

```lua
local raw = simd.bitcast(raw4, value)
local w = raw[3]
```

The recorder treated a vector as an FFI array, materialized the cdata, and
loaded the scalar through its payload pointer.  Quaternion hot loops therefore
called `lj_mem_newgco` once or more per iteration even though the packed value
already existed in an XMM register.

The vector IR already has `VEXTRACT`, but it had only been used for reduction
lane zero.  Its x86 backend ignored the encoded lane immediate.

## Resolution

For a constant lane of an F32x4 vector, `recff_cdata_index` now:

1. loads/forwards the complete vector value,
2. emits `VEXTRACT` with the constant lane,
3. converts the extracted float to a Lua number.

The x86 backend emits `VPSHUFD` for lanes 1 through 3.  Lane zero remains a
zero-instruction register alias.

This lets normal CNEW/XSTORE optimization sink all intermediate bitcast boxes.
`test/simd/test_jit.lua` checks nonzero-lane results across interpreter, JIT,
and mixed modes.  `test/simd/test_codegen.lua` additionally requires a
call-free loop body.

## Effect in LÖVR

Before this change, quaternion multiplication measured roughly 57 ns/op on the
development x86-64 machine because two cdata allocations survived in every
iteration.  After direct lane extraction and packed quaternion algebra, its
loop has no calls or allocations and measures roughly 4-5 ns/op.
