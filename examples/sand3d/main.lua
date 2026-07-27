local ffi = require 'ffi'
local simd = require 'ffi.simd'
local Sand3D = require 'sim'
local Effects = require 'effects'

local clock = os.clock
local floor = math.floor
local min = math.min
local max = math.max
local sin = math.sin
local cos = math.cos
local exp = math.exp
local pi = math.pi

local GRID_WIDTH = 64
local GRID_HEIGHT = 48
local GRID_DEPTH = 64
local CELL_SIZE = .17
local TOP_Y = GRID_HEIGHT * CELL_SIZE
local PARTICLE_SIZE = CELL_SIZE * .72
local EFFECT_CAPACITY = 8192
local FIXED_STEP = 1 / 120
local MAX_STEPS_PER_FRAME = 8

local benchmarkMode = arg[1] == '--benchmark'
local smokeMode = arg[1] == '--smoke'

local sim
local palette
local gridPositions
local worldPositions
local particleColors
local positionBuffer
local colorBuffer
local particleMesh
local particleShader
local effects
local effectPositions
local effectColors
local effectData
local effectPositionBuffer
local effectColorBuffer
local effectDataBuffer
local effectShader

local identity
local gridToWorld
local viewMatrix
local projectionMatrix
local uiProjection
local cameraTarget
local fogColor

local renderedParticles = 0
local renderedEffects = 0
local accumulator = 0
local brushAccumulator = 0
local selectedMaterial = Sand3D.SAND
local materialOrder = ffi.new('uint8_t[5]', {
  Sand3D.SAND,
  Sand3D.WATER,
  Sand3D.ROCK,
  Sand3D.LAVA,
  Sand3D.EMPTY
})
local selectedMaterialIndex = 0
local brushRadius = 2
local cursorX = floor((GRID_WIDTH + 1) / 2)
local cursorY = GRID_HEIGHT
local cursorZ = floor((GRID_DEPTH + 1) / 2)
local cursorWorldX = 0
local cursorWorldY = TOP_Y
local cursorWorldZ = 0
local cursorValid = false
local brushHeld = false
local orbitHeld = false
local paused = false
local showHud = true
local cameraYaw = .72
local cameraPitch = .48
local cameraDistance = 18
local hudText = ''
local fmaEnabled = simd.features().fma
local effectTime = 0
local effectAccumulator = 0
local burstAge = 1
local burstX, burstY, burstZ = 0, 0, 0
local burstMaterial = Sand3D.SAND

local profile = {
  simulation = 0,
  compaction = 0,
  transform = 0,
  upload = 0,
  cellRate = 0,
  moveRate = 0,
  uploadRate = 0,
  gpu = 0,
  draws = 0
}

local vertexShader = [[
readonly buffer ParticlePositions {
  vec4 ParticlePosition[];
};

readonly buffer ParticleColors {
  vec4 ParticleColor[];
};

uniform float ParticleSize;

vec4 lovrmain() {
  vec3 world = ParticlePosition[InstanceIndex].xyz + VertexPosition.xyz * ParticleSize;
  PositionWorld = world;
  Normal = VertexNormal;
  Color = vec4(ParticleColor[InstanceIndex].xyz, 1.);
  return ViewProjection * vec4(world, 1.);
}
]]

local fragmentShader = [[
uniform vec3 FogColor;

float particleHash(vec3 p) {
  return fract(sin(dot(floor(p * 19.), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

vec4 lovrmain() {
  vec3 normal = normalize(Normal);
  vec3 lightDirection = normalize(vec3(-.46, .82, .31));
  vec3 viewDirection = normalize(CameraPositionWorld - PositionWorld);
  float diffuse = max(dot(normal, lightDirection), 0.);
  float sky = normal.y * .16 + .18;
  float rim = pow(1. - max(dot(normal, viewDirection), 0.), 3.);
  float variation = particleHash(PositionWorld) * .13 + .94;

  vec3 base = Color.rgb * variation;
  vec3 lit = base * (.42 + diffuse * .72 + sky);
  lit += base * rim * .18;

  float water = smoothstep(.18, .65, base.b - base.r);
  float specular = pow(max(dot(reflect(-lightDirection, normal), viewDirection), 0.), 28.);
  lit += vec3(.35, .64, 1.) * specular * water * .9;

  float lava = smoothstep(.55, .9, base.r) * (1. - smoothstep(.22, .5, base.g));
  float pulse = sin(PositionWorld.y * 7. + PositionWorld.x * 3.) * .12 + .88;
  lit = mix(lit, base * 1.45 + vec3(.65, .055, .005) * pulse, lava);

  float distanceToCamera = length(CameraPositionWorld - PositionWorld);
  float fog = smoothstep(17., 31., distanceToCamera);
  return vec4(mix(lit, FogColor, fog), 1.);
}
]]

local effectVertexShader = [[
readonly buffer EffectPositions {
  vec4 EffectPosition[];
};

readonly buffer EffectColors {
  vec4 EffectColor[];
};

readonly buffer EffectData {
  vec4 Effect[];
};

uniform float EffectTime;

vec4 lovrmain() {
  vec4 effect = Effect[InstanceIndex];
  vec3 offset = VertexPosition.xyz * effect.x;
  offset.y *= 1. + effect.w;
  vec3 world = EffectPosition[InstanceIndex].xyz + offset;
  float flicker = .82 + .18 * sin(
    EffectTime * (9. + effect.z * 7.) +
    dot(EffectPosition[InstanceIndex].xyz, vec3(11., 17., 23.))
  );

  PositionWorld = world;
  Normal = VertexNormal;
  Color = vec4(
    EffectColor[InstanceIndex].rgb * (1. + effect.z * flicker),
    effect.y
  );
  return ViewProjection * vec4(world, 1.);
}
]]

local effectFragmentShader = [[
uniform vec3 FogColor;

vec4 lovrmain() {
  vec3 normal = normalize(Normal);
  vec3 lightDirection = normalize(vec3(-.46, .82, .31));
  float diffuse = max(dot(normal, lightDirection), 0.);
  vec3 lit = Color.rgb * (.42 + diffuse * .8);
  float distanceToCamera = length(CameraPositionWorld - PositionWorld);
  float fog = smoothstep(18., 32., distanceToCamera);
  return vec4(mix(lit, FogColor, fog * .35), Color.a);
}
]]

local function smooth(current, sample, amount)
  if current == 0 then return sample end
  return current + (sample - current) * amount
end

local function clamp(value, low, high)
  return min(max(value, low), high)
end

local function grouped(number)
  local text = tostring(floor(number + .5))
  while true do
    local replaced, count = text:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
    text = replaced
    if count == 0 then return text end
  end
end

local function materialName(material)
  if material == Sand3D.SAND then return 'SAND'
  elseif material == Sand3D.WATER then return 'WATER'
  elseif material == Sand3D.ROCK then return 'ROCK'
  elseif material == Sand3D.LAVA then return 'LAVA'
  else return 'ERASER'
  end
end

local function setMaterialColor(pass, material, alpha)
  if material == Sand3D.SAND then
    pass:setColor(.98, .68, .19, alpha or 1)
  elseif material == Sand3D.WATER then
    pass:setColor(.08, .48, 1., alpha or 1)
  elseif material == Sand3D.ROCK then
    pass:setColor(.36, .4, .48, alpha or 1)
  elseif material == Sand3D.LAVA then
    pass:setColor(1., .12, .015, alpha or 1)
  else
    pass:setColor(1., .22, .22, alpha or 1)
  end
end

local function buildPalette()
  local result = vector.array(20)
  local scales = ffi.new('float[4]', { .78, .9, 1., 1.1 })
  local Vector = vector.ctype

  local function add(material, r, g, b)
    for variant = 0, 3 do
      local scale = scales[variant]
      result.data[material * 4 + variant] = Vector(
        min(r * scale, 1),
        min(g * scale, 1),
        min(b * scale, 1),
        0
      )
    end
  end

  add(Sand3D.EMPTY, 1., .08, .045)
  add(Sand3D.SAND, .96, .66, .18)
  add(Sand3D.WATER, .07, .43, .98)
  add(Sand3D.ROCK, .34, .37, .44)
  add(Sand3D.LAVA, 1., .12, .012)
  return result
end

local function createParticleMesh()
  local vertices = {
    {  0,  .5,   0,  0,  1,  0, .5, 1 },
    {  0, -.5,   0,  0, -1,  0, .5, 0 },
    { .5,   0,   0,  1,  0,  0,  1, .5 },
    {-.5,   0,   0, -1,  0,  0,  0, .5 },
    {  0,   0,  .5,  0,  0,  1, .5, .5 },
    {  0,   0, -.5,  0,  0, -1, .5, .5 }
  }

  local indices = {
    1, 5, 3,
    1, 3, 6,
    1, 6, 4,
    1, 4, 5,
    2, 3, 5,
    2, 6, 3,
    2, 4, 6,
    2, 5, 4
  }

  local mesh = lovr.graphics.newMesh(vertices, 'gpu')
  mesh:setIndices(indices)
  return mesh
end

local function initializeSimulation()
  sim = Sand3D.new(GRID_WIDTH, GRID_HEIGHT, GRID_DEPTH, 0x5a17d3)
end

local function initializeGraphics()
  lovr.graphics.setBackgroundColor(.018, .032, .061)
  lovr.graphics.setTimingEnabled(true)

  palette = buildPalette()
  gridPositions = vector.array(sim.capacity)
  worldPositions = vector.array(sim.capacity)
  particleColors = vector.array(sim.capacity)
  sim:bindRender(gridPositions, particleColors, palette)
  positionBuffer = lovr.graphics.newBuffer('vec4', sim.capacity)
  colorBuffer = lovr.graphics.newBuffer('vec4', sim.capacity)
  effects = Effects.new(EFFECT_CAPACITY, CELL_SIZE, 0x17ac3e)
  effectPositions = vector.array(EFFECT_CAPACITY)
  effectColors = vector.array(EFFECT_CAPACITY)
  effectData = vector.array(EFFECT_CAPACITY)
  effectPositionBuffer = lovr.graphics.newBuffer('vec4', EFFECT_CAPACITY)
  effectColorBuffer = lovr.graphics.newBuffer('vec4', EFFECT_CAPACITY)
  effectDataBuffer = lovr.graphics.newBuffer('vec4', EFFECT_CAPACITY)
  particleMesh = createParticleMesh()
  particleShader = lovr.graphics.newShader(vertexShader, fragmentShader, {
    label = 'SIMD Sand Particles'
  })
  effectShader = lovr.graphics.newShader(effectVertexShader, effectFragmentShader, {
    label = 'SIMD Sand Effects'
  })

  identity = mat4()
  gridToWorld = mat4():scale(CELL_SIZE)
  viewMatrix = mat4()
  projectionMatrix = mat4()
  uiProjection = mat4()
  cameraTarget = vector(0, GRID_HEIGHT * CELL_SIZE * .34, 0)
  fogColor = vector(.018, .032, .061)
end

local function stageParticles()
  local started = clock()
  -- Position/color vectors are SIMD components on the dense cell archetype.
  -- The render system consumes the linear FFI move log, so it never rescans
  -- the sparse occupancy grid.
  sim:syncRender()
  renderedParticles = sim.count
  local compacted = clock()

  mat4.transformPoints(gridToWorld, gridPositions, worldPositions, renderedParticles)
  local transformed = clock()

  if renderedParticles > 0 then
    positionBuffer:setData(worldPositions, 1, 1, renderedParticles)
    colorBuffer:setData(particleColors, 1, 1, renderedParticles)
  end
  renderedEffects = effects:stage(effectPositions, effectColors, effectData, palette)
  if renderedEffects > 0 then
    effectPositionBuffer:setData(effectPositions, 1, 1, renderedEffects)
    effectColorBuffer:setData(effectColors, 1, 1, renderedEffects)
    effectDataBuffer:setData(effectData, 1, 1, renderedEffects)
  end
  local uploaded = clock()

  local compactSeconds = compacted - started
  local transformSeconds = transformed - compacted
  local uploadSeconds = uploaded - transformed
  profile.compaction = smooth(profile.compaction, compactSeconds, .12)
  profile.transform = smooth(profile.transform, transformSeconds, .12)
  profile.upload = smooth(profile.upload, uploadSeconds, .12)
  if uploadSeconds > 0 then
    profile.uploadRate = smooth(
      profile.uploadRate,
      (renderedParticles * 2 + renderedEffects * 3) * 16 / uploadSeconds,
      .12
    )
  end
end

local function setSelectedMaterial(index)
  selectedMaterialIndex = index % 5
  selectedMaterial = materialOrder[selectedMaterialIndex]
end

local function cycleMaterial(direction)
  setSelectedMaterial(selectedMaterialIndex + direction)
end

local function applyBrush(dt)
  if not cursorValid or not (brushHeld or lovr.system.isMouseDown(1)) then
    brushAccumulator = 0
    return
  end

  local changed = 0
  if selectedMaterial == Sand3D.ROCK then
    changed = sim:paintSphere(
      cursorX, cursorY, cursorZ, brushRadius,
      Sand3D.ROCK, true
    )
  elseif selectedMaterial == Sand3D.EMPTY then
    changed = sim:paintSphere(
      cursorX, cursorY, cursorZ, brushRadius,
      Sand3D.EMPTY, true
    )
  else
    brushAccumulator = brushAccumulator + dt * (170 + brushRadius * 65)
    local count = floor(brushAccumulator)
    if count > 0 then
      brushAccumulator = brushAccumulator - count
      changed = sim:emit(
        cursorX, cursorY, cursorZ,
        selectedMaterial, brushRadius, count
      )
    end
  end

  effectAccumulator = effectAccumulator + dt
  if changed > 0 and effectAccumulator >= .025 then
    local count = min(18, max(3, floor(math.sqrt(changed) * 2)))
    effects:spawn(
      cursorWorldX, cursorWorldY, cursorWorldZ,
      selectedMaterial, count, .75 + brushRadius * .09
    )
    effectAccumulator = 0
  end
end

local function updateHud()
  local fps = lovr.timer.getFPS()
  local simulationState = paused and 'PAUSED' or '120 Hz fixed step'
  local jitState = jit.status() and 'JIT ON' or 'JIT OFF'

  hudText = ([[
FFI + SIMD ECS SAND LAB  |  %s  |  FMA %s
%s cells occupied  •  %s grains rendered  •  %s live FX
%5.1f FPS  •  GPU %5.2f ms  •  %d total pass draws
%5.1f M cells/s  •  %5.1f M moves/s
FFI ECS step %5.2f ms  •  cached view %5.3f ms
SIMD Mat4 batch %5.3f ms  •  packed upload %5.2f ms (%4.1f GB/s)
%s  •  empty start  •  user emission only

LMB pour/paint  RMB drag orbit  wheel zoom
Q/E or MMB cycle material  •  1-5 select directly
Cursor pours from top face  •  [/] brush size
Space mega burst  •  P pause  •  R/C clear  •  Tab HUD
]]):format(
    jitState,
    fmaEnabled and 'ON' or 'OFF',
    grouped(sim.population),
    grouped(renderedParticles),
    grouped(renderedEffects),
    fps,
    profile.gpu * 1e3,
    profile.draws,
    profile.cellRate / 1e6,
    profile.moveRate / 1e6,
    profile.simulation * 1e3,
    profile.compaction * 1e3,
    profile.transform * 1e3,
    profile.upload * 1e3,
    profile.uploadRate / 1e9,
    simulationState
  )
end

local function configureCamera(pass)
  local width, height = pass:getDimensions()
  local horizontal = cos(cameraPitch) * cameraDistance
  local eye = cameraTarget + vector(
    sin(cameraYaw) * horizontal,
    sin(cameraPitch) * cameraDistance,
    cos(cameraYaw) * horizontal
  )

  viewMatrix:lookAt(eye, cameraTarget)
  projectionMatrix:perspective(pi / 3.15, width / max(height, 1), .04, 50)
  pass:setViewPose(1, viewMatrix, true)
  pass:setProjection(1, projectionMatrix)
  return width, height
end

local function updateCursor(pass)
  local mouseX, mouseY = lovr.system.getMousePosition()
  local density = lovr.system.getWindowDensity()
  local ox, oy, oz, dx, dy, dz = pass:getViewRay(mouseX * density, mouseY * density)
  cursorValid = math.abs(dy) > 1e-7
  if not cursorValid then return end

  local distance = (TOP_Y - oy) / dy
  cursorValid = distance > 0
  if not cursorValid then return end

  cursorWorldX, cursorWorldY, cursorWorldZ =
    ox + dx * distance, TOP_Y, oz + dz * distance

  local halfWidth = GRID_WIDTH * CELL_SIZE * .5
  local halfDepth = GRID_DEPTH * CELL_SIZE * .5
  cursorValid =
    cursorWorldX >= -halfWidth and cursorWorldX <= halfWidth and
    cursorWorldZ >= -halfDepth and cursorWorldZ <= halfDepth
  if not cursorValid then return end

  cursorX = clamp(
    floor(cursorWorldX / CELL_SIZE + (GRID_WIDTH + 1) * .5 + .5),
    1,
    GRID_WIDTH
  )
  cursorY = GRID_HEIGHT
  cursorZ = clamp(
    floor(cursorWorldZ / CELL_SIZE + (GRID_DEPTH + 1) * .5 + .5),
    1,
    GRID_DEPTH
  )
end

local function drawWorld(pass, interactive)
  local width, height = configureCamera(pass)
  if interactive then updateCursor(pass) end

  pass:setShader()
  pass:setDepthTest('gequal')
  pass:setDepthWrite(true)
  pass:setBlendMode()
  pass:setFaceCull('back')
  pass:setViewCull(false)

  -- The floor is visual guidance only.  It deliberately never writes depth,
  -- so grains resting in the bottom layer can not be hidden by it.
  pass:setDepthWrite(false)
  pass:setBlendMode('alpha')
  pass:setFaceCull(false)
  pass:setColor(.045, .078, .12, .34)
  pass:plane(
    0, -CELL_SIZE * .08, 0,
    GRID_WIDTH * CELL_SIZE,
    GRID_DEPTH * CELL_SIZE,
    -pi / 2, 1, 0, 0
  )
  pass:setColor(.09, .22, .31, .2)
  pass:plane(
    0, -CELL_SIZE * .065, 0,
    GRID_WIDTH * CELL_SIZE,
    GRID_DEPTH * CELL_SIZE,
    -pi / 2, 1, 0, 0,
    'line', 16, 16
  )
  pass:setBlendMode()
  pass:setDepthWrite(true)
  pass:setFaceCull('back')

  pass:setColor(.13, .32, .46, .42)
  pass:box(
    0, GRID_HEIGHT * CELL_SIZE * .5, 0,
    GRID_WIDTH * CELL_SIZE + .08,
    GRID_HEIGHT * CELL_SIZE,
    GRID_DEPTH * CELL_SIZE + .08,
    nil,
    'line'
  )

  if renderedParticles > 0 then
    pass:setShader(particleShader)
    pass:send('ParticlePositions', positionBuffer)
    pass:send('ParticleColors', colorBuffer)
    pass:send('ParticleSize', PARTICLE_SIZE)
    pass:send('FogColor', fogColor)
    pass:setColor(1, 1, 1, 1)
    pass:draw(particleMesh, identity, renderedParticles)
    pass:setShader()
  end

  if renderedEffects > 0 then
    pass:setShader(effectShader)
    pass:send('EffectPositions', effectPositionBuffer)
    pass:send('EffectColors', effectColorBuffer)
    pass:send('EffectData', effectDataBuffer)
    pass:send('EffectTime', effectTime)
    pass:send('FogColor', fogColor)
    pass:setDepthWrite(false)
    pass:setBlendMode('add')
    pass:setColor(1, 1, 1, 1)
    pass:draw(particleMesh, identity, renderedEffects)
    pass:setShader()
    pass:setBlendMode()
    pass:setDepthWrite(true)
  end

  if burstAge < .42 then
    local progress = burstAge / .42
    pass:setShader()
    pass:setDepthWrite(false)
    pass:setBlendMode('add')
    setMaterialColor(pass, burstMaterial, (1 - progress) * .2)
    pass:sphere(
      burstX, burstY, burstZ,
      (brushRadius + 1) * CELL_SIZE * (.7 + progress * 3.1),
      18, 9
    )
    pass:setBlendMode()
    pass:setDepthWrite(true)
  end

  if interactive and cursorValid then
    local cursorRadius = (brushRadius + .55) * CELL_SIZE
    local cursorDrawY = TOP_Y + CELL_SIZE * .025
    pass:setDepthWrite(false)
    pass:setBlendMode('alpha')
    pass:setFaceCull(false)
    setMaterialColor(pass, selectedMaterial, .16)
    pass:circle(
      cursorWorldX, cursorDrawY, cursorWorldZ,
      cursorRadius,
      -pi / 2, 1, 0, 0
    )
    setMaterialColor(pass, selectedMaterial, .9)
    pass:circle(
      cursorWorldX, cursorDrawY + .001, cursorWorldZ,
      cursorRadius,
      -pi / 2, 1, 0, 0,
      'line', 0, pi * 2, 40
    )
    pass:setColor(1, 1, 1, .58)
    pass:line(
      cursorWorldX - cursorRadius * .36, cursorDrawY + .002, cursorWorldZ,
      cursorWorldX + cursorRadius * .36, cursorDrawY + .002, cursorWorldZ
    )
    pass:line(
      cursorWorldX, cursorDrawY + .002, cursorWorldZ - cursorRadius * .36,
      cursorWorldX, cursorDrawY + .002, cursorWorldZ + cursorRadius * .36
    )
    pass:setDepthWrite(true)
    pass:setBlendMode()
    pass:setFaceCull('back')
  end

  if interactive and showHud then
    local density = lovr.system.getWindowDensity()
    local uiWidth = width / density
    local uiHeight = height / density
    pass:setShader()
    pass:setDepthTest()
    pass:setDepthWrite(false)
    pass:setFaceCull(false)
    pass:setBlendMode('alpha')
    uiProjection:orthographic(0, uiWidth, 0, uiHeight, -1, 1)
    pass:setViewPose(1, identity, true)
    pass:setProjection(1, uiProjection)

    pass:setColor(.012, .02, .038, .88)
    pass:plane(338, uiHeight - 145, 0, 644, 270)
    pass:setColor(.42, .84, 1., 1)
    pass:text(hudText, 30, uiHeight - 262, .01, 13.5, 0, 0, 1, 0, nil, 'left', 'top')

    setMaterialColor(pass, selectedMaterial, 1)
    pass:text(
      ('%s  •  brush %d  •  top cell %d/%d'):format(
        materialName(selectedMaterial),
        brushRadius,
        cursorX,
        cursorZ
      ),
      uiWidth - 28, 28, .01, 15., 0, 0, 1, 0, nil, 'right', 'top'
    )
  end

  local stats = pass:getStats()
  profile.gpu = stats.gpuTime or profile.gpu
  profile.draws = stats.draws or profile.draws
end

local function measure(fn, iterations, trials)
  fn(3)
  local best = math.huge
  local result
  for _ = 1, trials or 4 do
    collectgarbage()
    local started = clock()
    result = fn(iterations)
    best = min(best, clock() - started)
  end
  return best, result
end

local function runBenchmark()
  local steps = tonumber(arg[2]) or 240
  local benchmarkPalette = buildPalette()

  local function benchmarkSystems(bindRender)
    local bestTime = math.huge
    local bestMoves = 0
    local bestSim
    local bestPositions
    local bestColors

    for _ = 1, 3 do
      local candidate = Sand3D.new(GRID_WIDTH, GRID_HEIGHT, GRID_DEPTH, 0x5a17d3)
      candidate:populateBenchmark()
      local positions
      local colors
      if bindRender then
        positions = vector.array(candidate.capacity)
        colors = vector.array(candidate.capacity)
        candidate:bindRender(positions, colors, benchmarkPalette)
      end
      for _ = 1, 24 do candidate:step() end
      if bindRender then candidate:syncRender() end

      local moves = 0
      local started = clock()
      for step = 1, steps do
        moves = moves + candidate:step()
        if bindRender and (step % 2 == 0 or step == steps) then
          candidate:syncRender()
        end
      end
      local elapsed = clock() - started
      if elapsed < bestTime then
        bestTime = elapsed
        bestMoves = moves
        bestSim = candidate
        bestPositions = positions
        bestColors = colors
      end
    end

    return bestTime, bestMoves, bestSim, bestPositions, bestColors
  end

  print(('3D sand grid: %d x %d x %d = %s cells'):format(
    GRID_WIDTH,
    GRID_HEIGHT,
    GRID_DEPTH,
    grouped(GRID_WIDTH * GRID_HEIGHT * GRID_DEPTH)
  ))
  print(('State: dense FFI ECS + O(1) occupancy map + %d-wide SIMD FX'):format(
    effects and effects.simdWidth or (simd.features().vecsize >= 32 and 8 or 4)
  ))

  local bestStepTime, bestMoves, headlessSim = benchmarkSystems(false)
  local cells = steps * headlessSim.capacity
  print(('FFI ECS systems (headless)   %8.2f M cells/s eq  %7.2f M entities/s  (%5.2f ms/step)'):format(
    cells / bestStepTime / 1e6,
    steps * headlessSim.lastVisits / bestStepTime / 1e6,
    bestStepTime / steps * 1e3
  ))

  local boundTime
  local benchmarkSim
  local packedGrid
  local packedColors
  boundTime, bestMoves, benchmarkSim, packedGrid, packedColors = benchmarkSystems(true)
  print(('FFI ECS + cached SIMD view  %8.2f M cells/s eq  %7.2f M moves/s     (%5.2f ms/step)'):format(
    cells / boundTime / 1e6,
    bestMoves / boundTime / 1e6,
    boundTime / steps * 1e3
  ))

  local packedWorld = vector.array(benchmarkSim.capacity)
  local transform = mat4():scale(CELL_SIZE)
  local visible = benchmarkSim.count
  local coldGrid = vector.array(benchmarkSim.capacity)
  local coldColors = vector.array(benchmarkSim.capacity)

  local compactTime = measure(function(iterations)
    local count
    for _ = 1, iterations do
      count = benchmarkSim:compact(coldGrid, coldColors, benchmarkPalette, false)
    end
    return count
  end, 80, 4)

  print(('ECS cold render gather       %8.2f M entities/s (%s particles; cached during play)'):format(
    visible * 80 / compactTime / 1e6,
    grouped(visible)
  ))
  print('ECS move-log render sync          moved entities only (zero grid scans)')

  local transformIterations = max(100, floor(8e6 / max(visible, 1)))
  local transformTime = measure(function(iterations)
    for _ = 1, iterations do
      mat4.transformPoints(transform, packedGrid, packedWorld, visible)
    end
    return packedWorld.data[0][0]
  end, transformIterations, 5)

  print(('SIMD Mat4 point batch        %8.2f ns/particle (%5.2f M particles/s)'):format(
    transformTime * 1e9 / transformIterations / max(visible, 1),
    transformIterations * visible / transformTime / 1e6
  ))

  local benchmarkEffects = Effects.new(EFFECT_CAPACITY, CELL_SIZE, 0x17ac3e)
  local effectsPerMaterial = floor(EFFECT_CAPACITY / 5)
  for material = Sand3D.EMPTY, Sand3D.LAVA do
    benchmarkEffects:spawn(0, 4, 0, material, effectsPerMaterial, 1)
  end
  benchmarkEffects:spawn(
    0, 4, 0, Sand3D.LAVA,
    EFFECT_CAPACITY - benchmarkEffects.count,
    1
  )

  local packedEffectPositions = vector.array(EFFECT_CAPACITY)
  local packedEffectColors = vector.array(EFFECT_CAPACITY)
  local packedEffectData = vector.array(EFFECT_CAPACITY)
  local effectIterations = max(100, floor(8e6 / benchmarkEffects.count))

  local effectUpdateTime = measure(function(iterations)
    for _ = 1, iterations do benchmarkEffects:update(1e-5) end
    return benchmarkEffects.count
  end, effectIterations, 5)

  print(('FFI transient FX update      %8.2f ns/effect   (%5.2f M effects/s)'):format(
    effectUpdateTime * 1e9 / effectIterations / benchmarkEffects.count,
    effectIterations * benchmarkEffects.count / effectUpdateTime / 1e6
  ))

  local effectStageTime = measure(function(iterations)
    for _ = 1, iterations do
      benchmarkEffects:stage(
        packedEffectPositions,
        packedEffectColors,
        packedEffectData,
        benchmarkPalette
      )
    end
    return packedEffectPositions.data[0][0]
  end, effectIterations, 5)

  print(('FFI -> SIMD FX staging       %8.2f ns/effect   (%5.2f M effects/s)'):format(
    effectStageTime * 1e9 / effectIterations / benchmarkEffects.count,
    effectIterations * benchmarkEffects.count / effectStageTime / 1e6
  ))

  local sample = min(visible, 32768)
  local uploadBuffer = lovr.graphics.newBuffer('vec4', sample)
  local tableVectors = {}
  for i = 1, sample do tableVectors[i] = packedWorld[i] end
  local uploadIterations = max(30, floor(3e6 / max(sample, 1)))

  local packedUpload = measure(function(iterations)
    for _ = 1, iterations do
      uploadBuffer:setData(packedWorld, 1, 1, sample)
    end
  end, uploadIterations, 5)

  local tableUpload = measure(function(iterations)
    for _ = 1, iterations do
      uploadBuffer:setData(tableVectors)
    end
  end, uploadIterations, 5)

  print(('packed vector upload         %8.2f ns/particle'):format(
    packedUpload * 1e9 / uploadIterations / max(sample, 1)
  ))
  print(('Lua table vector upload       %8.2f ns/particle'):format(
    tableUpload * 1e9 / uploadIterations / max(sample, 1)
  ))
  print(('packed upload speedup         %8.2fx'):format(tableUpload / packedUpload))
  print(('FFI ECS core memory           %8.2f MiB'):format(benchmarkSim:memoryBytes() / 1048576))
  print(('FFI render log/cache memory   %8.2f MiB'):format(
    benchmarkSim:renderCacheBytes() / 1048576
  ))
  print(('FFI FX pool memory            %8.2f MiB'):format(benchmarkEffects:memoryBytes() / 1048576))
  print(('LuaJIT: %s  JIT=%s  FMA=%s'):format(
    jit.version,
    jit.status() and 'on' or 'off',
    fmaEnabled and 'on' or 'off'
  ))

  lovr.event.quit()
end

function lovr.load()
  initializeSimulation()

  if benchmarkMode then
    runBenchmark()
    return
  end

  initializeGraphics()
  stageParticles()
  updateHud()

  if smokeMode then
    local cx = floor((GRID_WIDTH + 1) * .5)
    local cz = floor((GRID_DEPTH + 1) * .5)
    sim:paintSphere(cx, 5, cz, 4, Sand3D.ROCK, false)
    sim:emit(cx - 8, GRID_HEIGHT - 8, cz - 5, Sand3D.SAND, 5, 900)
    sim:emit(cx + 8, GRID_HEIGHT - 10, cz + 4, Sand3D.WATER, 4, 650)
    sim:emit(cx, GRID_HEIGHT - 5, cz, Sand3D.LAVA, 2, 120)
    effects:spawn(0, GRID_HEIGHT * CELL_SIZE * .7, 0, Sand3D.LAVA, 96, 1.4)
    for _ = 1, 12 do sim:step() end
    effects:update(.08)
    stageParticles()
    local target = lovr.graphics.newTexture(640, 400)
    local pass = lovr.graphics.newPass(target)
    drawWorld(pass, false)
    lovr.graphics.submit(pass)
    lovr.graphics.wait()
    print(('sand3d graphics smoke test passed: %d grains, %d effects, %d draws'):format(
      renderedParticles,
      renderedEffects,
      pass:getStats().draws
    ))
    lovr.event.quit()
  end
end

function lovr.update(dt)
  dt = min(dt, .05)
  effectTime = effectTime + dt
  burstAge = burstAge + dt
  effects:update(dt)
  applyBrush(dt)

  local steps = 0
  local moves = 0
  local started = clock()

  if paused then
    accumulator = 0
  else
    accumulator = accumulator + dt
    while accumulator >= FIXED_STEP and steps < MAX_STEPS_PER_FRAME do
      moves = moves + sim:step()
      steps = steps + 1
      accumulator = accumulator - FIXED_STEP
    end
    if steps == MAX_STEPS_PER_FRAME then accumulator = min(accumulator, FIXED_STEP) end
  end

  local elapsed = clock() - started
  if steps > 0 and elapsed > 0 then
    profile.simulation = smooth(profile.simulation, elapsed / steps, .12)
    profile.cellRate = smooth(profile.cellRate, steps * sim.capacity / elapsed, .12)
    profile.moveRate = smooth(profile.moveRate, moves / elapsed, .12)
  end

  stageParticles()
  updateHud()
end

function lovr.draw(pass)
  drawWorld(pass, true)
end

function lovr.mousemoved(_, _, dx, dy)
  if orbitHeld or lovr.system.isMouseDown(2) then
    cameraYaw = cameraYaw - dx * .006
    cameraPitch = clamp(cameraPitch - dy * .005, .08, 1.25)
  end
end

function lovr.wheelmoved(_, y)
  cameraDistance = clamp(cameraDistance * exp(-y * .11), 8, 31)
end

function lovr.mousepressed(_, _, button)
  if button == 1 then
    brushHeld = true
  elseif button == 2 then
    orbitHeld = true
  elseif button == 3 then
    cycleMaterial(1)
  end
end

function lovr.mousereleased(_, _, button)
  if button == 1 then
    brushHeld = false
    brushAccumulator = 0
  elseif button == 2 then
    orbitHeld = false
  end
end

function lovr.keypressed(key)
  if key == 'escape' then
    lovr.event.quit()
  elseif key == '1' then
    setSelectedMaterial(0)
  elseif key == '2' then
    setSelectedMaterial(1)
  elseif key == '3' then
    setSelectedMaterial(2)
  elseif key == '4' then
    setSelectedMaterial(3)
  elseif key == '5' or key == 'x' then
    setSelectedMaterial(4)
  elseif key == 'q' then
    cycleMaterial(-1)
  elseif key == 'e' then
    cycleMaterial(1)
  elseif key == '[' then
    brushRadius = max(0, brushRadius - 1)
  elseif key == ']' then
    brushRadius = min(7, brushRadius + 1)
  elseif key == 'p' then
    paused = not paused
  elseif key == 'tab' then
    showHud = not showHud
  elseif key == 'r' or key == 'c' then
    sim:clear()
    effects:clear()
  elseif key == 'space' and cursorValid then
    local changed
    if selectedMaterial == Sand3D.ROCK or selectedMaterial == Sand3D.EMPTY then
      changed = sim:paintSphere(
        cursorX, cursorY, cursorZ,
        brushRadius + 2,
        selectedMaterial,
        true
      )
    else
      changed = sim:emit(
        cursorX, cursorY, cursorZ,
        selectedMaterial,
        brushRadius + 3,
        650
      )
    end
    if changed > 0 then
      effects:spawn(
        cursorWorldX, cursorWorldY, cursorWorldZ,
        selectedMaterial, min(180, 38 + changed), 2.15
      )
      burstAge = 0
      burstX, burstY, burstZ = cursorWorldX, cursorWorldY, cursorWorldZ
      burstMaterial = selectedMaterial
    end
  end
end
