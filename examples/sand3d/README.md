# SIMD Sand Lab

A 3D falling-sand sandbox built to exercise LÖVR's LuaJIT-only fast paths:

- macro-generated Teal ECS records with statically typed FFI components;
- an O(1) padded occupancy grid for spatial collision queries;
- per-material FFI archetype indices for traced sand, water, and lava systems;
- packed cell, material, shade, epoch, and list-index component arrays;
- an FFI movement log that updates SIMD render components without a grid scan;
- one bulk `mat4.transformPoints` SIMD transform;
- direct packed `vec4` buffer uploads;
- a top-face cursor that pours into the full 3D volume;
- small octahedral grains that keep the interior volume visible;
- a typed FFI/SIMD FX archetype for dust, droplets, chips, sparks, and bursts;
- eight-wide AVX2/FMA effect integration and branchless material staging;
- one instanced grain draw plus one instanced FX draw.

## Run it

From the repository root:

```sh
./build/bin/lovr examples/sand3d
```

`sim.tl`, `effects.tl`, and `ecs.tl` are the source of truth.  Their generated
Lua files are committed so running the example has no Teal dependency.  To
type-check and regenerate them with the pinned
[`frityet/tl`](https://github.com/frityet/tl/tree/tl-ng) `tl-ng` submodule:

```sh
git submodule update --init deps/tl
luajit examples/sand3d/build_teal.lua
```

For a no-write compiler check:

```sh
luajit examples/sand3d/build_teal.lua --check
```

The `ecs.define!` macro takes a Teal record plus a component schema such as
`{ x = f32, material = u8 }`.  Before type checking, it adds typed
`ffi.Array<T>` fields, a dense constructor, allocation methods, memory
accounting, and an unrolled swap-remove implementation.  The schema and macro
exist only at compile time—generated hot loops access cdata arrays directly.

[`showcase.mp4`](showcase.mp4) is a capture of top-face pouring, material
switching, transient effects, and camera orbiting.

The world starts completely empty.  Nothing is seeded or emitted
automatically: every simulated grain and every effect comes from user input.
Aim anywhere on the top face of the wireframe volume, then pour.

## Controls

| Input | Action |
| --- | --- |
| Left mouse | Pour or paint the selected material |
| Right mouse drag | Orbit the camera |
| Mouse wheel | Zoom |
| `1` / `2` / `3` / `4` / `5` | Sand / water / rock / lava / eraser |
| `Q` / `E` or middle mouse | Cycle backward / forward through materials |
| `[` / `]` | Shrink / grow the brush |
| `Space` | Emit a large material burst and shockwave |
| `P` | Pause |
| `R` / `C` | Clear all grains and effects |
| `Tab` | Toggle the profiler HUD |

## Profile it

The visual HUD reports simulation throughput, per-step time, movement-log
render synchronization, SIMD transform time, packed upload time, upload
bandwidth, the live effect count, and the brush's top-face grid cell.

For a repeatable headless profile:

```sh
./build/bin/lovr examples/sand3d --benchmark
```

An optional second argument changes the number of simulation steps:

```sh
./build/bin/lovr examples/sand3d --benchmark 500
```

The benchmark separately measures headless ECS systems and the real
ECS-plus-SIMD-render-cache path.  It also measures cold dense gathering, the
SIMD transient-effect integrator, branchless effect staging, and packed vector
uploads versus the equivalent Lua table path.

The ECS intentionally spends a few extra MiB on dense material indices and a
bounded movement log.  In return, cellular systems skip unrelated entities,
rendering never rescans all 196,608 cells, and transient effects update eight
at a time on AVX2 machines.

### Measured result

Three 600-step runs on the development machine, using the same scene before
and after the ECS conversion, produced these median results:

| Stage | Original grid | FFI/SIMD ECS |
| --- | ---: | ---: |
| Cellular step | 1.53 ms | 1.22 ms including periodic render-log sync |
| Equivalent cell throughput | 128.3 M/s | 161.3 M/s |
| Render preparation | 1.13 ms full-grid scan | zero grid scans; moved entities only |
| Transient FX integration | 5.77 ns/effect | 0.82 ns/effect |
| FX render staging | 19.54 ns/effect | 6.07 ns/effect |

At two 120 Hz simulation steps per rendered frame, the simulation plus
particle-view preparation fell from approximately 4.19 ms to 2.44 ms, a
roughly 42% reduction.  The tradeoff is memory: the ECS core uses 5.52 MiB and
its bounded render log/cache uses 10.01 MiB.

Run the logic and graphics checks with:

```sh
DYLD_LIBRARY_PATH="$PWD/deps/luajit/src" \
  ./deps/luajit/src/luajit examples/sand3d/test.lua

./build/bin/lovr examples/sand3d --smoke
```
