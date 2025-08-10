function love.conf(t)
  t.identity = "tentacles_snack_time"
  t.appendidentity = false
  t.version = "11.5"
  t.console = false

  t.window.title = "Tentacles: Snack Time"
  t.window.width = 1280
  t.window.height = 720
  t.window.fullscreen = true
  t.window.resizable = false
  t.window.msaa = 2

  t.modules.joystick = false
  t.modules.physics = false
end


