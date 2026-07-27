# SIMD vectors and quaternions

## Representation

LÖVR's Lua-side math values are now genuine LuaJITMT FFI vector types:

```c
typedef float lovr_vector4 __attribute__((vector_size(16)));
typedef const float lovr_quaternion4 __attribute__((vector_size(16)));
```

Both occupy one 128-bit SIMD register.  The const-qualified element type gives
quaternions an exact, distinct ctype and metatype without wrapping the SIMD
payload in a struct.  A private volatile-qualified float4 is used for
metatype-free packed intermediates.

The four-column FFI matrix representation built on these values is documented
separately in `notes/mat4-simd.md`.

Vectors preserve a zero fourth lane.  Public component access remains
`x/y/z`, and quaternions remain `x/y/z/w`.  All constructors, constants,
operators, vector methods, and quaternion methods return these cdata vector
types.

The implementation uses:

- packed shuffles and reductions for dot/cross/normalize;
- sign-bit XOR and a balanced FMA tree for Hamilton products;
- precomputed packed rotation-matrix columns for quaternion-vector rotation;
- an FMA-at-load-time specialization with a multiply/add fallback on CPUs
  without FMA.

## C API boundary

LuaJITMT exposes two small public helpers:

```c
const float* lua_tofloatvector(lua_State* L, int index, size_t* lanes);
int lua_pushfloatvector(
  lua_State* L,
  int ctypeIndex,
  const float* values,
  size_t lanes
);
```

LÖVR uses them to read SIMD payloads without field lookups and to construct
results directly as cdata without calling a Lua constructor.  The integration
covers common vector/quaternion readers, matrix multiplication, variants used
by channels and threads, graphics buffers/uniform data, immediate-mode vertex
lists, and endpoint parsing.

Thread and channel variants store quaternion lanes as floats instead of the
old Luau-specific normalized int16 representation, so SIMD values round-trip
without quantization.

## Generated hot-loop code

On the development x86-64 host, the steady-state vector affine loop is exactly:

```asm
vaddps xmm7, xmm7, xmm1
vmulps xmm7, xmm7, xmm0
```

Quaternion multiplication keeps both values in registers.  With FMA, the
steady loop is four broadcasts, two packed multiplies, two packed FMAs, and
one packed add.  Quaternion-vector rotation is:

```asm
vpshufd      xmm6, xmm7, 0x00
vmulps       xmm5, xmm2, xmm6
vpshufd      xmm4, xmm7, 0x55
vfmadd132ps  xmm6, xmm5, xmm4
vpshufd      xmm5, xmm7, 0xaa
vfmadd132ps  xmm7, xmm6, xmm5
```

There are no calls, cdata allocations, scalarized lane loops, or memory
round-trips in any of these steady-state loops.

Inspect the current machine code with:

```sh
LUA_PATH='deps/luajit/src/?.lua;;' \
DYLD_LIBRARY_PATH="$PWD/deps/luajit/src" \
./deps/luajit/src/luajit -jdump=im \
notes/benchmarks/vector_quaternion_jit.lua rotate
```

## Representative benchmark

`notes/benchmarks/vector_quaternion.lua` measures the old table-shaped kernels
against the SIMD implementation.  A representative best-of-five run with
50,000,000 iterations on the development x86-64 Mac produced:

| Kernel | Tables | SIMD | Speedup |
| --- | ---: | ---: | ---: |
| Vector affine | 2.14 ns/op | 2.16 ns/op | 0.99x |
| Quaternion multiply | 5.54 ns/op | 4.28 ns/op | 1.29x |
| Quaternion rotate vector | 7.46 ns/op | 3.56 ns/op | 2.09x |

Exact timings vary by CPU and load.  The stronger invariant is the inspected
loop shape above: packed register operations only.  The simple affine vector
recurrence is latency-bound and effectively ties optimized scalar table code;
the quaternion kernels benefit directly from doing their coupled math in one
register.

Run the benchmark from the repository root:

```sh
DYLD_LIBRARY_PATH="$PWD/deps/luajit/src" \
./deps/luajit/src/luajit notes/benchmarks/vector_quaternion.lua 50000000
```

## Precision

The old Lua tables held double-precision Lua numbers.  The SIMD ABI is
float32, matching LÖVR's C math types and GPU-facing data.  Long artificial
recurrences can therefore diverge from the former double-precision result.
Callers accumulating orientations for long periods should continue the usual
practice of normalizing periodically.
