local headless = arg[1] == '--benchmark' or arg[1] == '--smoke'

function lovr.conf(t)
  for module in pairs(t.modules) do
    t.modules[module] =
      module == 'event' or
      module == 'math' or
      module == 'timer' or
      module == 'graphics' or
      module == 'data' or
      module == 'system' or
      module == 'task'
  end

  t.modules.headset = false
  t.headset = false
  t.identity = 'sand3d-simd'
  t.graphics.vsync = false
  t.graphics.antialias = true
  t.graphics.debug = false

  t.window = headless and nil or {
    width = 1280,
    height = 800,
    centered = true,
    resizable = true,
    title = 'LÖVR FFI + SIMD ECS Sand Lab'
  }
end
