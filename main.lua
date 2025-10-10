-- Minimal LÖVE 2D simulation: a monster with tentacles that grab particles and eat them
-- what does this do?
local function clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

local function distance(x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  return math.sqrt(dx * dx + dy * dy)
end

local function lengthOf(vecx, vecy)
  return math.sqrt(vecx * vecx + vecy * vecy)
end

local function normalize(vecx, vecy)
  local len = lengthOf(vecx, vecy)
  if len == 0 then return 0, 0 end
  return vecx / len, vecy / len
end

local function randomInCircle(radius)
  local angle = love.math.random() * 2 * math.pi
  local r = math.sqrt(love.math.random()) * radius
  return math.cos(angle) * r, math.sin(angle) * r
end

local function moveTowards(x, y, tx, ty, maxStep)
  local dx, dy = tx - x, ty - y
  local dist = math.sqrt(dx * dx + dy * dy)
  if dist <= maxStep or dist == 0 then
    return tx, ty
  end
  local nx = x + dx / dist * maxStep
  local ny = y + dy / dist * maxStep
  return nx, ny
end

-- Robust atan2 for Lua variants
local function atan2(y, x)
  if x > 0 then
    return math.atan(y / x)
  elseif x < 0 and y >= 0 then
    return math.atan(y / x) + math.pi
  elseif x < 0 and y < 0 then
    return math.atan(y / x) - math.pi
  elseif x == 0 and y > 0 then
    return math.pi / 2
  elseif x == 0 and y < 0 then
    return -math.pi / 2
  else
    return 0
  end
end

-- Forward declare Tentacle so Monster can reference it in constructor
local Tentacle

local Monster = {}
Monster.__index = Monster

function Monster.new(x, y, radius, tentacleCount, segmentCount, segmentLength)
  local self = setmetatable({}, Monster)
  self.x = x
  self.y = y
  self.radius = radius
  self.initialRadius = radius -- Store initial size for reference
  self.score = 0
  self.tentacles = {}
  self.color = { 0.16, 0.72, 0.66 }
  self.tentacleBaseJitter = 0 -- what does this do?
  self.growthRate = 0.15 -- How much the radius grows per particle eaten

  self:rebuildTentacles(tentacleCount or 8, segmentCount or 16, segmentLength or 16)

  return self
end

function Monster:update(dt, particles)
  -- Slight organic wobble of tentacle bases around the body
  self.tentacleBaseJitter = self.tentacleBaseJitter + dt
  local wobble = math.sin(self.tentacleBaseJitter * 1.3) * 3

  local baseRadius = self.radius - 2
  local total = #self.tentacles
  for i, t in ipairs(self.tentacles) do
    local angle = (i - 1) / total * 2 * math.pi
    t.baseX = self.x + math.cos(angle) * (baseRadius + wobble * 0.1)
    t.baseY = self.y + math.sin(angle) * (baseRadius + wobble * 0.1)
    t.anchorAngle = angle
    t:update(dt, particles, self)
  end
end

function Monster:grow()
  self.radius = self.radius + self.growthRate
end

function Monster:draw()
  love.graphics.setColor(self.color)
  love.graphics.circle('fill', self.x, self.y, self.radius)

  -- Eye
  love.graphics.setColor(0.05, 0.12, 0.14)
  love.graphics.circle('fill', self.x + 5, self.y - 4, self.radius * 0.25)

  -- Score text
  love.graphics.setColor(1, 1, 1, 0.9)
  love.graphics.print("Eaten: " .. tostring(self.score), 12, 12)
end

function Monster:rebuildTentacles(tentacleCount, segmentCount, segmentLength)
  self.tentacles = {}
  local totalTentacles = math.max(1, math.floor(tentacleCount))
  local baseRadius = self.radius - 2
  for i = 1, totalTentacles do
    local angle = (i - 1) / totalTentacles * 2 * math.pi
    local baseX = self.x + math.cos(angle) * baseRadius
    local baseY = self.y + math.sin(angle) * baseRadius
    local t = Tentacle.new(baseX, baseY, angle, math.max(2, math.floor(segmentCount)), math.max(2, math.floor(segmentLength)))
    self.tentacles[i] = t
  end
end

-- Tentacle implementation using a simple 2-pass IK (follow + re-anchor base)
Tentacle = {}
Tentacle.__index = Tentacle

local function newSegment(x, y, length)
  return {
    ax = x, ay = y, -- start
    bx = x + length, by = y, -- end
    length = length,
  }
end

function Tentacle.new(baseX, baseY, anchorAngle, segmentCount, segmentLength)
  local self = setmetatable({}, Tentacle)
  self.baseX = baseX
  self.baseY = baseY
  self.anchorAngle = anchorAngle or 0
  self.segments = {}
  self.segmentLength = segmentLength
  self.color = { 0.10, 0.52, 0.48 }
  self.tipColor = { 0.98, 0.45, 0.35 }

  for i = 1, segmentCount do
    local s = newSegment(baseX, baseY, segmentLength)
    self.segments[i] = s
  end

  self.maxReach = segmentCount * segmentLength
  self.targetParticle = nil
  self.grabbedParticle = nil
  self.state = 'idle' -- idle | reaching | retracting
  self.grabRadius = 10
  self.searchCooldown = love.math.random() * 0.6

  -- Time spent in 'reaching' state
  self.reachingTime = 0

  -- Smoothed IK target and per-state speeds (pixels/second)
  self.ikTargetX = baseX
  self.ikTargetY = baseY
  self.reachSpeed = 280
  self.retractSpeed = 200
  self.idleSpeed = 100

  return self
end

local function segmentFollow(seg, tx, ty)
  local dx = tx - seg.ax
  local dy = ty - seg.ay
  local angle = atan2(dy, dx)
  -- Place the start so that the end is at the target
  seg.ax = tx - math.cos(angle) * seg.length
  seg.ay = ty - math.sin(angle) * seg.length
  seg.bx = tx
  seg.by = ty
end

local function segmentForward(seg, prevBx, prevBy)
  seg.ax = prevBx
  seg.ay = prevBy
  local dx = seg.bx - seg.ax
  local dy = seg.by - seg.ay
  local angle = atan2(dy, dx)
  seg.bx = seg.ax + math.cos(angle) * seg.length
  seg.by = seg.ay + math.sin(angle) * seg.length
end

function Tentacle:tipPosition()
  local last = self.segments[#self.segments]
  return last.bx, last.by
end

function Tentacle:update(dt, particles, monster)
  -- Acquire or maintain targets
  if self.grabbedParticle and self.grabbedParticle._removed then
    self.grabbedParticle = nil
    self.state = 'idle'
  end

  if not self.grabbedParticle then
    self.searchCooldown = self.searchCooldown - dt
    if self.searchCooldown <= 0 and (not self.targetParticle or self.targetParticle._removed) then
      self:findTarget(particles)
      self.searchCooldown = 0.25 + love.math.random() * 0.5
    end
  end

  local targetX, targetY
  if self.grabbedParticle then
    -- Retract towards the monster center
    targetX, targetY = monster.x, monster.y
  elseif self.targetParticle and not self.targetParticle._removed then
    targetX, targetY = self.targetParticle.x, self.targetParticle.y
  else
    -- Idle curl around the base
    local idleR = self.segmentLength * (#self.segments - 4)
    targetX = self.baseX + math.cos(self.anchorAngle + math.sin(love.timer.getTime() * 0.9) * 0.4) * idleR
    targetY = self.baseY + math.sin(self.anchorAngle + math.cos(love.timer.getTime() * 0.8) * 0.4) * idleR
  end

  -- Smooth the IK target toward desired target based on state speeds
  local speed = self.idleSpeed
  if self.grabbedParticle then
    speed = self.retractSpeed
  elseif self.targetParticle and not self.targetParticle._removed then
    speed = self.reachSpeed
  end
  self.ikTargetX, self.ikTargetY = moveTowards(self.ikTargetX, self.ikTargetY, targetX, targetY, speed * dt)

  -- IK: backward pass (follow target) then forward pass (re-anchor base)
  local tx, ty = self.ikTargetX, self.ikTargetY
  for i = #self.segments, 1, -1 do
    segmentFollow(self.segments[i], tx, ty)
    tx, ty = self.segments[i].ax, self.segments[i].ay
  end

  -- Re-anchor root
  self.segments[1].ax, self.segments[1].ay = self.baseX, self.baseY
  local first = self.segments[1]
  local dx1, dy1 = first.bx - first.ax, first.by - first.ay
  local len1 = lengthOf(dx1, dy1)
  if len1 == 0 then len1 = 1 end
  first.bx = first.ax + dx1 / len1 * first.length
  first.by = first.ay + dy1 / len1 * first.length
  for i = 2, #self.segments do
    segmentForward(self.segments[i], self.segments[i - 1].bx, self.segments[i - 1].by)
  end

  -- Interactions
  local tipX, tipY = self:tipPosition()

  -- Time-based abandon: if reaching too long, reset
  if self.targetParticle and not self.targetParticle._removed and self.state == 'reaching' then
    self.reachingTime = self.reachingTime + dt
    if self.reachingTime > 1.5 then -- seconds
      self.targetParticle.claimedBy = nil
      self.targetParticle = nil
      self.state = 'idle'
      self.reachingTime = 0
      return
    end
  else
    self.reachingTime = 0
  end

  if self.grabbedParticle then
    -- Attach particle to tip
    self.grabbedParticle.x = tipX
    self.grabbedParticle.y = tipY
    if distance(tipX, tipY, monster.x, monster.y) <= monster.radius - 4 then
      -- Eat
      self.grabbedParticle._removed = true
      self.grabbedParticle.claimedBy = nil
      self.grabbedParticle = nil
      self.state = 'idle'
      monster.score = monster.score + 1
      monster:grow() -- Monster grows when eating
      -- Immediately look for new target after eating
      self:findTarget(particles)
    end
  elseif self.targetParticle and not self.targetParticle._removed then
    if distance(tipX, tipY, self.targetParticle.x, self.targetParticle.y) <= self.grabRadius then
      self.grabbedParticle = self.targetParticle
      self.targetParticle = nil
      self.state = 'retracting'
      self.reachingTime = 0
    end
  end
end

function Tentacle:findTarget(particles)
  local px, py = self.baseX, self.baseY
  local nearest, bestDistSq = nil, math.huge
  local maxReachSq = (self.maxReach * 0.95)
  maxReachSq = maxReachSq * maxReachSq
  for _, p in ipairs(particles) do
    if not p._removed and not p.claimedBy then
      local dx = p.x - px
      local dy = p.y - py
      local d2 = dx * dx + dy * dy
      if d2 < bestDistSq and d2 <= maxReachSq then
        bestDistSq = d2
        nearest = p
      end
    end
  end
  if nearest then
    self.targetParticle = nearest
    self.state = 'reaching'
    self.reachingTime = 0
    nearest.claimedBy = self
  else
    self.state = 'idle'
    self.reachingTime = 0
  end
end

-- Particles
local function newParticle(x, y)
  return {
    x = x,
    y = y,
    vx = 0,
    vy = 0,
    r = 3 + love.math.random() * 2,
    color = { 0.98, 0.83, 0.35 },
    _removed = false,
    claimedBy = nil,
  }
end

local function spawnParticleRing(cx, cy, innerR, outerR)
  local angle = love.math.random() * math.pi * 2
  local r = innerR + (outerR - innerR) * math.sqrt(love.math.random())
  local x = cx + math.cos(angle) * r
  local y = cy + math.sin(angle) * r
  return newParticle(x, y)
end

local world = {
  width = 1920,
  height = 1080,
  monster = nil,
  particles = {},
  particleRespawnTimer = 0, -- legacy, not used after slider setup
  initialParticles = 800,
  spawnAccumulator = 0,
  settings = {
    tentacleCount = 32,
    tentacleSegmentCount = 32,
    tentacleSegmentLength = 8,
    particlesPerSecond = 5,
    simulationSpeed = 1.0,
  },
  ui = {
    sliders = {},
    dragging = nil,
  },
}

function love.load()
  love.window.setMode(world.width, world.height, { resizable = false, msaa = 2 })
  love.window.setTitle("Tentacles: Snack Time")
  love.graphics.setBackgroundColor(0.07, 0.09, 0.10)

  local cx, cy = world.width * 0.5, world.height * 0.55
  world.monster = Monster.new(
    cx, cy,
    40,
    world.settings.tentacleCount,
    world.settings.tentacleSegmentCount,
    world.settings.tentacleSegmentLength
  )

  for _ = 1, world.initialParticles do
    --table.insert(world.particles, spawnParticleRing(cx, cy, 160, 240))
    table.insert(world.particles, spawnParticleRing(cx, cy, 500, 500))
  end
end

function love.update(dt)
  updateUI(dt)
  local speed = world.settings.simulationSpeed or 1.0
  dt = dt * speed
  -- Gentle drift for particles
  for i = #world.particles, 1, -1 do
    local p = world.particles[i]
    if p._removed then
      table.remove(world.particles, i)
    else
      local jitterX, jitterY = randomInCircle(16 * dt)
      p.vx = clamp(p.vx + jitterX, -30, 30)
      p.vy = clamp(p.vy + jitterY, -30, 30)
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt

      -- Soft bounds: nudge back into play area
      if p.x < 24 then p.vx = p.vx + 20 * dt end
      if p.x > world.width - 24 then p.vx = p.vx - 20 * dt end
      if p.y < 24 then p.vy = p.vy + 20 * dt end
      if p.y > world.height - 24 then p.vy = p.vy - 20 * dt end
    end
  end

  -- Respawn new particles over time using particlesPerSecond
  world.spawnAccumulator = world.spawnAccumulator + dt * (world.settings.particlesPerSecond or 0)
  while world.spawnAccumulator >= 1 do
    world.spawnAccumulator = world.spawnAccumulator - 1
    table.insert(world.particles, spawnParticleRing(world.monster.x, world.monster.y, 200, 200))
  end

  -- Update monster and tentacles
  world.monster:update(dt, world.particles)

  -- Optional: Move monster toward mouse slowly for fun
  if love.mouse.isDown(1) then
    local mx, my = love.mouse.getPosition()
    local dirx, diry = normalize(mx - world.monster.x, my - world.monster.y)
    local moveSpeed = 60 * speed
    world.monster.x = world.monster.x + dirx * moveSpeed * dt / speed -- only scale by speed once
    world.monster.y = world.monster.y + diry * moveSpeed * dt / speed
  end
end

local function drawTentacle(t)
  -- Draw search radius
  love.graphics.setColor(0.2, 0.7, 1.0, 0.13)
  love.graphics.setLineWidth(1)
  love.graphics.circle('line', t.baseX, t.baseY, t.maxReach * 0.95)

  -- Draw red dot at base
  love.graphics.setColor(1, 0, 0, 0.9)
  love.graphics.circle('fill', t.baseX, t.baseY, 5)

  love.graphics.setLineWidth(3)
  love.graphics.setColor(t.color)
  local prevx, prevy = t.segments[1].ax, t.segments[1].ay
  for i = 1, #t.segments do
    local s = t.segments[i]
    love.graphics.line(prevx, prevy, s.bx, s.by)
    prevx, prevy = s.bx, s.by
  end
  local tipx, tipy = t.segments[#t.segments].bx, t.segments[#t.segments].by
  -- Draw line to target if reaching
  if t.targetParticle and not t.targetParticle._removed and t.state == 'reaching' then
    love.graphics.setColor(1, 0.2, 0.2, 0.7)
    love.graphics.setLineWidth(2)
    love.graphics.line(tipx, tipy, t.targetParticle.x, t.targetParticle.y)
  end
  love.graphics.setColor(t.tipColor)
  love.graphics.circle('fill', tipx, tipy, 4)
end

function love.draw()
  -- Draw particles first (behind tentacles)
  for _, p in ipairs(world.particles) do
    if not p._removed then
      love.graphics.setColor(p.color)
      love.graphics.circle('fill', p.x, p.y, p.r)
    end
  end

  -- Tentacles
  for _, tentacle in ipairs(world.monster.tentacles) do
    drawTentacle(tentacle)
  end

  -- Monster body last
  world.monster:draw()

  -- Hint
  love.graphics.setColor(1, 1, 1, 0.7)
  love.graphics.print("Hold Left Mouse Button to gently move the monster", 12, world.height - 24)

  drawUI()
end

-- Simple UI sliders
local function sliderToValue(slider, mx)
  local t = clamp((mx - slider.x) / slider.w, 0, 1)
  local value = slider.min + t * (slider.max - slider.min)
  if slider.isInteger then value = math.floor(value + 0.5) end
  return value
end

local function makeSlider(x, y, w, label, min, max, value, isInteger)
  return { x = x, y = y, w = w, h = 20, label = label, min = min, max = max, value = value, isInteger = isInteger }
end

local function formatValue(slider)
  if slider.isInteger then return tostring(math.floor(slider.value + 0.5)) end
  return string.format("%.1f", slider.value)
end

function initUI()
  local x, y, w, pad = 16, 16, 260, 10
  world.ui.sliders = {
    makeSlider(x, y + 0 * (20 + pad), w, "tentacleCount", 4, 64, world.settings.tentacleCount, true),
    makeSlider(x, y + 1 * (20 + pad), w, "tentacleSegmentCount", 4, 64, world.settings.tentacleSegmentCount, true),
    makeSlider(x, y + 2 * (20 + pad), w, "tentacleSegmentLength", 4, 24, world.settings.tentacleSegmentLength, true),
    makeSlider(x, y + 3 * (20 + pad), w, "particlesPerSecond", 0, 30, world.settings.particlesPerSecond, false),
    makeSlider(x, y + 4 * (20 + pad), w, "simulationSpeed", 0.05, 5.0, world.settings.simulationSpeed or 1.0, false),
  }
end

function drawUI()
  if #world.ui.sliders == 0 then initUI() end
  love.graphics.setColor(0, 0, 0, 0.35)
  love.graphics.rectangle('fill', 8, 8, 300, 4 * 30 + 20, 6, 6)
  for _, s in ipairs(world.ui.sliders) do
    -- bar
    love.graphics.setColor(1, 1, 1, 0.8)
    love.graphics.rectangle('line', s.x, s.y, s.w, s.h, 4, 4)
    love.graphics.setColor(1, 1, 1, 0.15)
    love.graphics.rectangle('fill', s.x, s.y, s.w, s.h, 4, 4)
    -- handle
    local t = (s.value - s.min) / (s.max - s.min)
    local hx = s.x + t * s.w
    love.graphics.setColor(0.98, 0.83, 0.35)
    love.graphics.circle('fill', hx, s.y + s.h * 0.5, 7)
    -- label
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.print(s.label .. ": " .. formatValue(s), s.x + s.w + 10, s.y - 2)
  end
end

local function applySettings()
  local s = world.settings
  world.monster:rebuildTentacles(s.tentacleCount, s.tentacleSegmentCount, s.tentacleSegmentLength)
end

function updateUI(dt)
  if #world.ui.sliders == 0 then initUI() end
  local mx, my = love.mouse.getPosition()
  local isDown = love.mouse.isDown(1)
  local changed = false

  if isDown then
    -- begin or continue drag
    if world.ui.dragging == nil then
      for idx, s in ipairs(world.ui.sliders) do
        if mx >= s.x and mx <= s.x + s.w and my >= s.y and my <= s.y + s.h then
          world.ui.dragging = idx
          break
        end
      end
    end
    if world.ui.dragging ~= nil then
      local s = world.ui.sliders[world.ui.dragging]
      local old = s.value
      s.value = sliderToValue(s, mx)
      if s.value ~= old then changed = true end
    end
  else
    world.ui.dragging = nil
  end

  if changed then
    -- sync to settings
    for _, s in ipairs(world.ui.sliders) do
      world.settings[s.label] = s.isInteger and math.floor(s.value + 0.5) or s.value
    end
    applySettings()
  end
end


