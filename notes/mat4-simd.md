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

The decomposition methods `unpack`, `getOrientation`, and `getPose` are also
implemented in traceable Lua now.  They retain the original native
angle/axis algorithm and edge handling, while avoiding the Lua C API boundary
and allowing repeated calls to be folded into a surrounding trace.

Compatibility overloads for table-shaped inputs can still use the native Lua
C closures.  Matrix inversion remains native because the large cofactor
kernel is a poor tracing target.

## Explicit output and packed arrays

Allocation-sensitive composition can use either
`matrix:mul(other, output)` or `mat4.multiply(left, right, output)`.  The
operator form still creates a result, while explicit-output forms write
directly to an existing Mat4 and safely permit either input to alias the
output.

The math globals expose variable-length FFI storage:

```lua
local matrices = mat4.array(count)
local points = vector.array(count)
local rotations = quaternion.array(count)
```

Each allocation has an immutable 32-bit length followed by a 16-byte-aligned,
contiguous payload.  Numeric indexing remains one-based.  Mat4 elements are
live FFI references, so `matrices[i]:translate(...)` updates the packed array
in place instead of copying a 64-byte value.

The bulk kernels are:

- `mat4.multiplyArray(left, right, output[, count])`;
- `mat4.transformVectors(matrices, input, output[, weight[, count]])`;
- `mat4.transformPoints(matrices, input, output[, count])`;
- `mat4.transformDirections(matrices, input, output[, count])`.

A single Mat4 can be broadcast across an array, or a Mat4 array can provide
one transform per element.  The steady inner traces have no Lua calls or heap
allocations.

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
ctype.  An exact FFI reference to that ctype is dereferenced as well; this is
what lets a live `matrices[i]` view pass directly through native APIs.  LÖVR
caches the Mat4 and packed-array ctypes in each Lua state and uses the helper
without field lookups, constructor calls, or copies through a userdata
wrapper.

The direct boundary is used by generic matrix argument parsing, graphics
buffers, model transforms, pass view/projection I/O, and the native
compatibility methods.  Thread and channel variants copy all 16 lanes so
matrices round-trip between Lua states as the same cdata type.

Graphics buffers recognize packed Mat4, vector, and quaternion arrays.
Matching `mat4` and `vec4` formats use one bulk copy; other vector/matrix
formats use a native conversion loop without Lua table traversal.

`Model:getNodeTransforms` and `Model:setNodeTransforms` accept Mat4 arrays.
Root-space reads update the model hierarchy once and then copy the contiguous
global-matrix range directly.  Parent-space reads compose local TRS values,
and packed writes decompose the input range while marking the model dirty
only once.

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

Mutating and explicit-output matrix composition emit four independent column kernels.  Each
kernel is four broadcasts, one packed multiply, and three packed FMAs.  The
steady loop has no calls, scalar lane loop, temporary cdata allocation, or
memory round-trip beyond loading and storing the matrix columns.

Transpose compiles to four packed unpack operations, four packed shuffles,
and four stores.  Packed quaternion-to-matrix construction and the three
result-column products in rotation also stay entirely in SIMD registers.

The nonmutating `a * b` form necessarily creates one 64-byte result cdata per
iteration.  Use `a:mul(b)` when mutating `a` is acceptable, or pass an
explicit output when both inputs need to remain unchanged.

Inspect the current trace with:

```sh
LUA_PATH='deps/luajit/src/?.lua;;' \
DYLD_LIBRARY_PATH="$PWD/deps/luajit/src" \
./deps/luajit/src/luajit -jdump=im \
notes/benchmarks/mat4_jit.lua point
```

The final argument can also be `mul`, `direction`, `compose`,
`compose_mutating`, `compose_output`, `orientation`, `multiply_array`,
`transform_points`, `transpose`, or `rotate`.

## Representative benchmark

`notes/benchmarks/mat4.lua` compares the original native Lua C API closures
with the traced implementation.  A best-of-seven run with 5,000,000
iterations on the development x86-64 Mac produced:

| Kernel | Native boundary | New path | Speedup |
| --- | ---: | ---: | ---: |
| `matrix:mul(vector)` | 253.30 ns | 3.83 ns | 66.1x |
| `matrix * vector` | 253.30 ns | 4.44 ns | 57.0x |
| Mutating composition | 144.10 ns | 5.02 ns | 28.7x |
| Explicit-output composition | 144.10 ns | 5.52 ns | 26.1x |
| Allocating composition | 144.10 ns | 56.85 ns | 2.5x |
| Rotation | 241.99 ns | 7.72 ns | 31.3x |
| Transpose | 70.65 ns | 2.13 ns | 33.2x |
| Inversion | 120.65 ns | 52.68 ns | 2.3x |
| Orientation | 119.47 ns | 4.23 ns | 28.2x |
| Pose | 135.71 ns | 7.66 ns | 17.7x |
| Raw unpack | 120.30 ns | 17.50 ns | 6.9x |

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

`notes/benchmarks/mat4_bulk` measures 1,024-element batches.  On the same
development x86-64 Mac:

| Workload | Table/per-item API | Packed path | Speedup |
| --- | ---: | ---: | ---: |
| Mat4 composition | 49.19 ns/item | 4.35 ns/item | 11.3x |
| Point transform | 36.27 ns/item | 1.76 ns/item | 20.6x |
| Mat4 buffer upload | 91.26 ns/item | 32.92 ns/item | 2.8x |
| Vector buffer upload | 75.64 ns/item | 14.58 ns/item | 5.2x |
| Model transform write | 185.29 ns/item | 43.42 ns/item | 4.3x |
| Model transform read | 150.79 ns/item | 1.49 ns/item | 101.2x |

Run it with:

```sh
./build/bin/lovr notes/benchmarks/mat4_bulk 1024 1000
```

## Precision and compatibility

The old native Mat4 payload was already 16 float32 values, so the new cdata
representation does not reduce matrix precision.  Matrix/vector transforms
continue to use LÖVR's existing homogeneous-coordinate behavior, including
perspective division for the `matrix * vector` point operator and an explicit
zero weight for direction transforms.

Code that checks `type(matrix) == "userdata"` must change to accept cdata.
The supported API methods, numeric lane order, graphics uploads, and
thread/channel behavior are preserved.
