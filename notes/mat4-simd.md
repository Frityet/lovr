# SIMD Mat4

## Representation

Lua-side matrices are 64-byte FFI values made from four packed float columns:

```c
typedef volatile float lovr_raw4 __attribute__((vector_size(16)));
typedef struct {
  lovr_raw4 columns[4];
} lovr_mat4;
```

The layout is the same column-major 16-float layout used by LÖVR's native
math and graphics code.  `mat4()`, `Mat4()`, `lovr.math.mat4`, and
`lovr.math.newMat4` all construct this cdata type.  Numeric indexing and the
existing method surface remain intact; `release` is now a no-op because the
value no longer owns a refcounted native object.

The four-column shape lets LuaJIT keep each column in one XMM register.  The
hot implementations in `src/api/l_math.lua` include:

- point and direction transforms;
- mutating and nonmutating matrix composition;
- translate, scale, rotation, transpose, and equality;
- position, scale, orientation, and pose updates;
- orthographic, perspective, and field-of-view projections;
- look-at, target, and reflection matrices.

Compatibility overloads for table-shaped inputs can still use the native Lua
C closures.  Matrix inversion remains native because the large cofactor
kernel is a poor tracing target.

## LuaJIT C boundary

LuaJITMT exposes an exact-ctype payload helper:

```c
void* lua_tocdataof(
  lua_State* L,
  int index,
  int ctypeIndex,
  size_t* size
);
```

It returns the direct cdata payload only when the value has the requested
ctype.  LÖVR caches the Mat4 ctype in each Lua state and uses the helper to
read or write the 64-byte matrix without field lookups, constructor calls, or
copies through a userdata wrapper.

The direct boundary is used by generic matrix argument parsing, graphics
buffers, model transforms, pass view/projection I/O, and the native
compatibility methods.  Thread and channel variants copy all 16 lanes so
matrices round-trip between Lua states as the same cdata type.

Inversion is exported as a direct FFI symbol:

```c
void lovrMathMat4Invert(lovr_mat4* matrix);
```

This is intentionally a hybrid design.  An FFI call removes much of the Lua C
API dispatch and stack-marshalling cost, but the call is still opaque to the
trace compiler.  Small composable kernels therefore stay in traceable SIMD
Lua; only the large native inversion kernel crosses FFI.

## Generated x86-64 code

The common affine point transform is three broadcasts, three packed FMAs, a
weight guard, and a lane clear.  Perspective matrices take a side trace that
also performs homogeneous division.  The direction specialization omits
translation and division, leaving one packed multiply and two packed FMAs.

Mutating matrix composition emits four independent column kernels.  Each
kernel is four broadcasts, one packed multiply, and three packed FMAs.  The
steady loop has no calls, scalar lane loop, temporary cdata allocation, or
memory round-trip beyond loading and storing the matrix columns.

Transpose compiles to four packed unpack operations, four packed shuffles,
and four stores.  Packed quaternion-to-matrix construction and the three
result-column products in rotation also stay entirely in SIMD registers.

The nonmutating `a * b` form necessarily creates one 64-byte result cdata per
iteration.  Use `a:mul(b)` in allocation-sensitive loops when mutating `a` is
acceptable.

Inspect the current trace with:

```sh
LUA_PATH='deps/luajit/src/?.lua;;' \
DYLD_LIBRARY_PATH="$PWD/deps/luajit/src" \
./deps/luajit/src/luajit -jdump=im \
notes/benchmarks/mat4_jit.lua point
```

The final argument can also be `mul`, `direction`, `compose`,
`compose_mutating`, `transpose`, or `rotate`.

## Representative benchmark

`notes/benchmarks/mat4.lua` compares the original native Lua C API closures
with the traced implementation.  A best-of-seven run with 5,000,000
iterations on the development x86-64 Mac produced:

| Kernel | Native boundary | New path | Speedup |
| --- | ---: | ---: | ---: |
| `matrix:mul(vector)` | 238.44 ns | 3.75 ns | 63.6x |
| `matrix * vector` | 238.44 ns | 4.29 ns | 55.6x |
| Mutating composition | 139.21 ns | 4.99 ns | 27.9x |
| Allocating composition | 139.21 ns | 50.06 ns | 2.8x |
| Rotation | 236.74 ns | 7.53 ns | 31.4x |
| Transpose | 73.94 ns | 2.11 ns | 35.0x |
| Inversion | 119.91 ns | 54.63 ns | 2.2x |

The inversion row compares Lua C API dispatch with a direct FFI call to the
same native algorithm.  It demonstrates where FFI helps.  The much larger
speedups for the other rows come from allowing LuaJIT to inline and optimize
the whole packed operation, not merely from changing the call boundary.

Run the benchmark from the repository root:

```sh
./build/bin/lovr notes/benchmarks/mat4.lua 5000000
```

Exact timings vary by CPU and system load.  Machine-code shape is the stronger
invariant.

## Precision and compatibility

The old native Mat4 payload was already 16 float32 values, so the new cdata
representation does not reduce matrix precision.  Matrix/vector transforms
continue to use LÖVR's existing homogeneous-coordinate behavior, including
perspective division for the `matrix * vector` point operator and an explicit
zero weight for direction transforms.

Code that checks `type(matrix) == "userdata"` must change to accept cdata.
The supported API methods, numeric lane order, graphics uploads, and
thread/channel behavior are preserved.
