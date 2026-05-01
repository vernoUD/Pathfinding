-- escort npc with combat & fleeing
-- comments explain the important bits, not every line

local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- remote so UI knows what state the npc is in
local eventsFolder = Instance.new("Folder")
eventsFolder.Name = "NPCEvents"
eventsFolder.Parent = ReplicatedStorage

local stateChangedEvent = Instance.new("RemoteEvent")
stateChangedEvent.Name = "StateChanged"
stateChangedEvent.Parent = eventsFolder

-- === tunable numbers ===
local ATTACK_RADIUS = 20
local ATTACK_RANGE = 5
local ATTACK_COOLDOWN = 1.2
local ATTACK_DAMAGE = 15

local FLEE_HEALTH_THRESHOLD = 0.25  -- 25% hp = run
local FLEE_DURATION = 8

local ROTATION_ALPHA = 0.15

local STUCK_CHECK_INTERVAL = 1.2
local STUCK_MOVE_MINIMUM = 1.5
local STUCK_JUMP_THRESHOLD = 2
local STUCK_TELEPORT_THRESHOLD = 4
local STUCK_NUDGE_DISTANCE = 3

local PATH_REBUILD_DIST = 10
local PATH_REBUILD_COOLDOWN = 0.4   -- don't spam pathfinding cause it's expensive
local FOLLOW_STOP_DIST = 4

local SPEED_NORMAL = 18
local SPEED_CATCHUP = 28
local SPEED_FLEE = 24
local CATCHUP_DIST = 18

local SPEED_LERP_RATE = 6
local AI_TICK_RATE = 15
local AI_TICK_INTERVAL = 1 / AI_TICK_RATE

-- radius 3 so it doesn't hug walls
local PATH_AGENT_PARAMS = {
    AgentRadius = 3,
    AgentHeight = 5,
    AgentCanJump = true,
    AgentCanClimb = false,
    WaypointSpacing = 4,
}

-- froze so i can't typo state names
local State = table.freeze({
    IDLE = "Idle",
    FOLLOW = "Follow",
    ATTACK = "Attack",
    FLEE = "Flee",
})

-- === NPC CLASS ===
local NPCController = {}
NPCController.__index = NPCController

function NPCController.new(model: Model, assignedPlayer: Player?)
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local rootPart = model:FindFirstChild("HumanoidRootPart")

    -- unanchor everything in the npc model
    for _, desc in model:GetDescendants() do
        if desc:IsA("BasePart") then
            desc.Anchored = false
        end
    end

    if not model.PrimaryPart then
        model.PrimaryPart = rootPart :: BasePart
    end

    local hum = humanoid :: Humanoid
    hum.WalkSpeed = SPEED_NORMAL

    -- if we have a player, start in follow so it can walk out of weird spawn positions
    local startState = if assignedPlayer then State.FOLLOW else State.IDLE

    local self = setmetatable({
        model = model,
        humanoid = humanoid,
        rootPart = rootPart,
        assignedPlayer = assignedPlayer,
        currentState = startState,
        _waypoints = {},
        _waypointIdx = 1,
        _lastPos = (rootPart :: BasePart).Position,
        _lastTargetPos = Vector3.zero,
        _stuckTimer = 0,
        _stuckCount = 0,
        _attackTimer = 0,
        _fleeTimer = 0,
        _pathCooldown = 0,
        _targetSpeed = SPEED_NORMAL,
        _aiAccumulator = 0,
        _connections = {},
    }, NPCController)

    -- clean up when npc dies
    local deathConn = (humanoid :: Humanoid).Died:Once(function()
        self:destroy()
    end)
    table.insert(self._connections, deathConn)

    stateChangedEvent:FireAllClients(model, startState)
    return self
end

-- change state and tell all clients
function NPCController:setState(newState: string)
    if self.currentState == newState then return end
    self.currentState = newState
    stateChangedEvent:FireAllClients(self.model, newState)
end

-- ask pathfinding for a route. has cooldown so we don't spam it.
function NPCController:_buildPath(target: Vector3): boolean
    if self._pathCooldown > 0 then
        return #self._waypoints > 0
    end
    self._pathCooldown = PATH_REBUILD_COOLDOWN

    local root = self.rootPart :: BasePart
    local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)

    local ok = pcall(function()
        path:ComputeAsync(root.Position, target)
    end)

    if not ok or path.Status ~= Enum.PathStatus.Success then
        warn("[NPCController] Path failed: " .. tostring(path.Status))
        return false
    end

    self._waypoints = path:GetWaypoints()
    self._waypointIdx = 2  -- skip first, it's our current position
    self._lastTargetPos = target
    return true
end

-- move toward the next waypoint.
-- not using MoveToFinished because it times out after 8 seconds on long paths.
function NPCController:_stepPath(): boolean
    if self._waypointIdx > #self._waypoints then
        return false
    end

    local wp = self._waypoints[self._waypointIdx]
    local hum = self.humanoid :: Humanoid

    if wp.Action == Enum.PathWaypointAction.Jump then
        hum.Jump = true
    end

    hum:MoveTo(wp.Position)

    local root = self.rootPart :: BasePart
    if (root.Position - wp.Position).Magnitude < 3 then
        self._waypointIdx += 1
    end

    return true
end

-- rotate to face target. ONLY used in idle.
-- turning while moving makes the npc glitch out 
function NPCController:_faceTarget(target: Vector3)
    local root = self.rootPart :: BasePart
    local cf = root.CFrame
    local flatGoal = Vector3.new(target.X, cf.Position.Y, target.Z)

    if (flatGoal - cf.Position).Magnitude < 0.1 then return end

    local lookCF = CFrame.lookAt(cf.Position, flatGoal)
    root.CFrame = cf:Lerp(lookCF, ROTATION_ALPHA)
end

-- find nearest enemy player (exclude the one we're escorting)
function NPCController:_getNearestEnemy(): (BasePart?, Humanoid?)
    local root = self.rootPart :: BasePart
    local closestDist = ATTACK_RADIUS
    local closestRoot = nil :: BasePart?
    local closestHum = nil :: Humanoid?

    for _, player in Players:GetPlayers() do
        if player == self.assignedPlayer then continue end  -- don't attack our guy

        local char = player.Character
        if not char then continue end

        local enemyRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
        local enemyHum = char:FindFirstChildOfClass("Humanoid")
        if not enemyRoot or not enemyHum then continue end
        if enemyHum.Health <= 0 then continue end

        local dist = (enemyRoot.Position - root.Position).Magnitude
        if dist < closestDist then
            closestDist = dist
            closestRoot = enemyRoot
            closestHum = enemyHum
        end
    end

    return closestRoot, closestHum
end

function NPCController:_getAssignedRoot(): BasePart?
    if not self.assignedPlayer then return nil end
    local char = (self.assignedPlayer :: Player).Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- stuck handling: progressively more aggressive
-- 1st: rebuild path, 2nd: jump, 4th: teleport sideways
function NPCController:_checkStuck(dt: number)
    self._stuckTimer += dt
    if self._stuckTimer < STUCK_CHECK_INTERVAL then return end
    self._stuckTimer = 0

    local root = self.rootPart :: BasePart
    local hum = self.humanoid :: Humanoid
    local moved = (root.Position - self._lastPos).Magnitude

    if moved < STUCK_MOVE_MINIMUM then
        self._stuckCount += 1

        -- always force a path rebuild when stuck
        self._waypoints = {}
        self._waypointIdx = 1

        if self._stuckCount == STUCK_JUMP_THRESHOLD then
            hum.Jump = true
        end

        if self._stuckCount >= STUCK_TELEPORT_THRESHOLD then
            -- nudge to the right relative to facing. works better than forward.
            local nudgeDir = root.CFrame.RightVector
            root.CFrame = root.CFrame + nudgeDir * STUCK_NUDGE_DISTANCE
            self._stuckCount = 0
        end
    else
        self._stuckCount = 0
    end

    self._lastPos = root.Position
end

-- only rebuild if target moved a lot since last path request
function NPCController:_shouldRebuildPath(currentTarget: Vector3): boolean
    return (currentTarget - self._lastTargetPos).Magnitude > PATH_REBUILD_DIST
end

-- main navigation: check stuck, rebuild if needed, step
function NPCController:_navigate(target: Vector3, dt: number)
    self:_checkStuck(dt)

    local needsRebuild = (#self._waypoints == 0)
        or (self._waypointIdx > #self._waypoints)
        or self:_shouldRebuildPath(target)

    if needsRebuild then
        self:_buildPath(target)
    end

    self:_stepPath()
end

-- runs every frame. handles smoothing and throttles ai logic.
function NPCController:update(dt: number)
    local hum = self.humanoid :: Humanoid
    if hum.Health <= 0 then return end

    if self._pathCooldown > 0 then
        self._pathCooldown = math.max(0, self._pathCooldown - dt)
    end

    -- exponential smoothing for speed changes (feels natural)
    local alpha = 1 - math.exp(-SPEED_LERP_RATE * dt)
    hum.WalkSpeed = hum.WalkSpeed + (self._targetSpeed - hum.WalkSpeed) * alpha

    -- throttle AI logic to 15hz so we're not doing expensive scans every frame
    self._aiAccumulator += dt
    if self._aiAccumulator < AI_TICK_INTERVAL then return end

    local tickDt = self._aiAccumulator
    self._aiAccumulator = 0

    self:_aiTick(tickDt)
end

-- the actual state machine. runs at lower frequency.
function NPCController:_aiTick(dt: number)
    local hum = self.humanoid :: Humanoid
    local assignedRoot = self:_getAssignedRoot()

    if self.currentState == State.IDLE then
        if assignedRoot then
            self:setState(State.FOLLOW)
        end

    elseif self.currentState == State.FOLLOW then
        if not assignedRoot then
            hum:MoveTo((self.rootPart :: BasePart).Position)
            self._waypoints = {}
            self:setState(State.IDLE)
            return
        end

        -- check for enemies to fight
        local enemyRoot = self:_getNearestEnemy()
        if enemyRoot then
            self._waypoints = {}
            self:setState(State.ATTACK)
            return
        end

        local root = self.rootPart :: BasePart
        local playerDist = (assignedRoot.Position - root.Position).Magnitude

        -- sprint if we're far behind
        if playerDist > CATCHUP_DIST then
            self._targetSpeed = SPEED_CATCHUP
        else
            self._targetSpeed = SPEED_NORMAL
        end

        if playerDist > FOLLOW_STOP_DIST then
            self:_navigate(assignedRoot.Position, dt)
        end

    elseif self.currentState == State.ATTACK then
        -- low health? run away
        if hum.Health / hum.MaxHealth < FLEE_HEALTH_THRESHOLD then
            self._waypoints = {}
            self:setState(State.FLEE)
            return
        end

        local enemyRoot, enemyHum = self:_getNearestEnemy()
        if not enemyRoot or not enemyHum then
            -- no enemies left, go back to following
            self._waypoints = {}
            self:setState(State.FOLLOW)
            return
        end

        local root = self.rootPart :: BasePart
        local meleeDist = (enemyRoot.Position - root.Position).Magnitude

        if meleeDist <= ATTACK_RANGE then
            -- in range: stop moving and attack on cooldown
            hum:MoveTo(root.Position)
            self._attackTimer += dt
            if self._attackTimer >= ATTACK_COOLDOWN then
                self._attackTimer = 0
                enemyHum:TakeDamage(ATTACK_DAMAGE)
            end
        else
            -- out of range: chase
            self._targetSpeed = SPEED_CATCHUP
            self._attackTimer = 0
            self:_navigate(enemyRoot.Position, dt)
        end

    elseif self.currentState == State.FLEE then
        self._fleeTimer += dt
        self._targetSpeed = SPEED_FLEE

        local enemyRoot = self:_getNearestEnemy()
        if enemyRoot then
            local root = self.rootPart :: BasePart
            -- run away: direction from enemy to us, then extend 30 studs
            local awayDir = (root.Position - (enemyRoot :: BasePart).Position).Unit
            local fleeDest = root.Position + awayDir * 30
            self:_navigate(fleeDest, dt)
        end

        if self._fleeTimer >= FLEE_DURATION then
            self._fleeTimer = 0
            self._waypoints = {}
            self:setState(State.FOLLOW)
        end
    end
end

-- cleanup so we don't leak connections
function NPCController:destroy()
    for _, conn in self._connections do
        conn:Disconnect()
    end
    table.clear(self._connections)
    local hum = self.humanoid :: Humanoid
    local root = self.rootPart :: BasePart
    hum:MoveTo(root.Position)
end

-- === BOOTSTRAP ===
local npcModel = workspace:WaitForChild("EscortNPC", 10)
if not npcModel then
    error("EscortNPC not found in Workspace within 10 seconds")
end

local controller = nil

local function initController(player: Player?)
    if controller then
        controller:destroy()
    end
    controller = NPCController.new(npcModel :: Model, player)
end

-- start with the first player who's already in the game
initController(Players:GetPlayers()[1])

-- when a new player joins, assign them if we don't have a follow target
Players.PlayerAdded:Connect(function(player: Player)
    if not controller or not controller.assignedPlayer then
        initController(player)
    end
end)

-- when the followed player leaves, switch to another player or go idle
Players.PlayerRemoving:Connect(function(player: Player)
    if not controller then return end
    if controller.assignedPlayer ~= player then return end

    local nextPlayer = nil :: Player?
    for _, p in Players:GetPlayers() do
        if p ~= player then
            nextPlayer = p
            break
        end
    end
    controller.assignedPlayer = nextPlayer
    if not nextPlayer then
        controller:setState(State.IDLE)
    else
        initController(nextPlayer)
    end
end)

-- main loop
RunService.Heartbeat:Connect(function(dt: number)
    if controller then
        controller:update(dt)
    end
end)
