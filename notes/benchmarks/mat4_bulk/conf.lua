function lovr.conf(t)
  for module in pairs(t.modules) do
    t.modules[module] =
      module == 'event' or module == 'math' or module == 'timer' or
      module == 'graphics' or module == 'data'
  end
  t.headset = false
  t.window = nil
end
