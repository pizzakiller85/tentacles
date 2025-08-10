-- Minimal LÖVE 2D simulation: a monster with tentacles that grab particles and eat them

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

function Monster.new(x, y, radius, tentacleCount)
  local self = setmetatable({}, Monster)
  self.x = x
  self.y = y
  self.radius = radius
  self.score = 0
  self.tentacles = {}
  self.color = { 0.16, 0.72, 0.66 }
  self.tentacleBaseJitter = 0

  local totalTentacles = tentacleCount or 8
  for i = 1, totalTentacles do
    local angle = (i - 1) / totalTentacles * 2 * math.pi
    local baseRadius = radius - 2
    local baseX = x + math.cos(angle) * baseRadius
    local baseY = y + math.sin(angle) * baseRadius
    local segments = 16
    local segmentLength = 16
    local t = Tentacle.new(baseX, baseY, angle, segments, segmentLength)
    self.tentacles[i] = t
  end

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

  -- IK: backward pass (follow target) then forward pass (re-anchor base)
  local tx, ty = targetX, targetY
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
    end
  elseif self.targetParticle and not self.targetParticle._removed then
    if distance(tipX, tipY, self.targetParticle.x, self.targetParticle.y) <= self.grabRadius then
      self.grabbedParticle = self.targetParticle
      self.targetParticle = nil
      self.state = 'retracting'
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
    nearest.claimedBy = self
  else
    self.state = 'idle'
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
  particleRespawnTimer = 0,
}

function love.load()
  love.window.setMode(world.width, world.height, { resizable = false, msaa = 2 })
  love.window.setTitle("Tentacles: Snack Time")
  love.graphics.setBackgroundColor(0.07, 0.09, 0.10)

  local cx, cy = world.width * 0.5, world.height * 0.55
  world.monster = Monster.new(cx, cy, 38, 8)

  for _ = 1, 60 do
    table.insert(world.particles, spawnParticleRing(cx, cy, 160, 240))
  end
end

function love.update(dt)
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

  -- Respawn new particles over time
  world.particleRespawnTimer = world.particleRespawnTimer - dt
  if world.particleRespawnTimer <= 0 then
    world.particleRespawnTimer = 0.4
    table.insert(world.particles, spawnParticleRing(world.monster.x, world.monster.y, 180, 260))
  end

  -- Update monster and tentacles
  world.monster:update(dt, world.particles)

  -- Optional: Move monster toward mouse slowly for fun
  if love.mouse.isDown(1) then
    local mx, my = love.mouse.getPosition()
    local dirx, diry = normalize(mx - world.monster.x, my - world.monster.y)
    local speed = 60
    world.monster.x = world.monster.x + dirx * speed * dt
    world.monster.y = world.monster.y + diry * speed * dt
  end
end

local function drawTentacle(t)
  love.graphics.setLineWidth(3)
  love.graphics.setColor(t.color)
  local prevx, prevy = t.segments[1].ax, t.segments[1].ay
  for i = 1, #t.segments do
    local s = t.segments[i]
    love.graphics.line(prevx, prevy, s.bx, s.by)
    prevx, prevy = s.bx, s.by
  end
  local tipx, tipy = t.segments[#t.segments].bx, t.segments[#t.segments].by
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
  for _, t in ipairs(world.monster.tentacles) do
    drawTentacle(t)
  end

  -- Monster body last
  world.monster:draw()

  -- Hint
  love.graphics.setColor(1, 1, 1, 0.7)
  love.graphics.print("Hold Left Mouse Button to gently move the monster", 12, world.height - 24)
end


