-- simple script that makes an npc follow a player fight other players and run when low hp


local RunService = game:GetService("RunService") -- for heartbeat and timers
local PathfindingService = game:GetService("PathfindingService") -- so npc knows how to walk around obstacles
local Players = game:GetService("Players") -- to find players to follow or fight
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- remote event goes here

-- make a folder to hold remote events
local eventsFolder = Instance.new("Folder")
eventsFolder.Name = "NPCEvents"
eventsFolder.Parent = ReplicatedStorage

-- this remote tells the UI what state the npc is in (idle follow attack flee)
local stateChangedEvent = Instance.new("RemoteEvent")
stateChangedEvent.Name = "StateChanged"
stateChangedEvent.Parent = eventsFolder

--numbers you can change for preferences
local ATTACK_RADIUS = 20  -- how far to look for someone to hit
local ATTACK_RANGE = 5    -- melee distance 
local ATTACK_COOLDOWN = 1.2 -- seconds between punches
local ATTACK_DAMAGE = 15   -- damage per hit

local FLEE_HEALTH_THRESHOLD = 0.25  -- run away when health drops below 25 percent
local FLEE_DURATION = 8             -- how many seconds to stay in flee mode

local ROTATION_ALPHA = 0.15  -- how fast npc turns to face you (idle only)

local STUCK_CHECK_INTERVAL = 1.2   -- check if stuck every 1.2 seconds
local STUCK_MOVE_MINIMUM = 1.5     -- if moved less than this npc is stuck
local STUCK_JUMP_THRESHOLD = 2     -- after 2 stuck checks make it jump
local STUCK_TELEPORT_THRESHOLD = 4 -- after 4 stuck checks teleport it sideways
local STUCK_NUDGE_DISTANCE = 3     -- how far to teleport when desperate

local PATH_REBUILD_DIST = 10       -- only rebuild path if target moved this far
local PATH_REBUILD_COOLDOWN = 0.4  -- do not spam pathfinding it is expensive
local FOLLOW_STOP_DIST = 4         -- stop moving when this close to target

local SPEED_NORMAL = 18            -- normal walk speed (player is 16)
local SPEED_CATCHUP = 28           -- sprint speed when falling behind
local SPEED_FLEE = 24              -- run away speed
local CATCHUP_DIST = 18            -- if distance is over this use catchup speed

local SPEED_LERP_RATE = 6          -- smooth speed changes no instant snap
local AI_TICK_RATE = 15            -- ai logic runs at 15 fps to save performance
local AI_TICK_INTERVAL = 1 / AI_TICK_RATE -- 0.0666 seconds

-- pathfinding settings
-- agent radius 3 makes sure npc does not hug walls too tight
local PATH_AGENT_PARAMS = {
    AgentRadius = 3,
    AgentHeight = 5,
    AgentCanJump = true,
    AgentCanClimb = false,
    WaypointSpacing = 4,
}

-- freeze this table so i cannot typo state names later
local State = table.freeze({
    IDLE = "Idle",
    FOLLOW = "Follow",
    ATTACK = "Attack",
    FLEE = "Flee",
})

-- NPC class start
local NPCController = {}
NPCController.__index = NPCController

-- constructor makes a new npc controller
function NPCController.new(model: Model assignedPlayer: Player?)
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local rootPart = model:FindFirstChild("HumanoidRootPart")

    -- unanchor every single part so it isnt stuck
    for _ desc in model:GetDescendants() do
        if desc:IsA("BasePart") then
            desc.Anchored = false
        end
    end

    -- set primary part so the model can be moved as a whole if needed
    if not model.PrimaryPart then
        model.PrimaryPart = rootPart :: BasePart
    end

    local hum = humanoid :: Humanoid
    hum.WalkSpeed = SPEED_NORMAL

    -- if there is a player to follow start in follow mode so npc walks out of weird spawns
    local startState = if assignedPlayer then State.FOLLOW else State.IDLE

    -- internal variables (underscore means that u should not touch from outside)
    local self = setmetatable({
        model = model,
        humanoid = humanoid,
        rootPart = rootPart,
        assignedPlayer = assignedPlayer,
        currentState = startState,
        _waypoints = {},           -- waypoints from pathfinding
        _waypointIdx = 1,          -- which waypoint npc is going to
        _lastPos = (rootPart :: BasePart).Position,  -- for stuck detection
        _lastTargetPos = Vector3.zero,   -- last position npc built a path to
        _stuckTimer = 0,           -- time since last stuck check
        _stuckCount = 0,           -- how many times stuck in a row
        _attackTimer = 0,          -- cooldown between punches
        _fleeTimer = 0,            -- how long npc has been fleeing
        _pathCooldown = 0,         -- cooldown for path rebuilds
        _targetSpeed = SPEED_NORMAL, -- desired speed (smoothly lerped to)
        _aiAccumulator = 0,        -- accumulates dt for ai throttling
        _connections = {},         -- list of connections to clean up later
    } NPCController)

    -- when the npc dies clean everything up (using :Once so it auto disconnects)
    local deathConn = (humanoid :: Humanoid).Died:Once(function()
        self:destroy()
    end)
    table.insert(self._connections deathConn)

    -- tell all clients what state npc started in
    stateChangedEvent:FireAllClients(model startState)

    return self
end

-- change state and broadcast to all players so UI updates
function NPCController:setState(newState: string)
    if self.currentState == newState then return end  -- no change ignore
    self.currentState = newState
    stateChangedEvent:FireAllClients(self.model newState)
end

-- ask pathfinding for a route to target. has a cooldown to avoid spam.
function NPCController:_buildPath(target: Vector3): boolean
    -- if on cooldown just return whether npc already has a path
    if self._pathCooldown > 0 then
        return #self._waypoints > 0
    end
    self._pathCooldown = PATH_REBUILD_COOLDOWN  -- start cooldown

    local root = self.rootPart :: BasePart
    local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)

    -- ComputeAsync can error if target is inside a wall or unreachable
    local ok = pcall(function()
        path:ComputeAsync(root.Position target)
    end)

    if not ok or path.Status ~= Enum.PathStatus.Success then
        warn("Path failed: " .. tostring(path.Status))
        return false
    end

    self._waypoints = path:GetWaypoints()
    self._waypointIdx = 2  -- skip first waypoint since the npc is standing there
    self._lastTargetPos = target
    return true
end

-- move toward the next waypoint
-- NOT using MoveToFinished because it times out after 8 seconds 
function NPCController:_stepPath(): boolean
    if self._waypointIdx > #self._waypoints then
        return false  -- no more waypoints npc is done
    end

    local wp = self._waypoints[self._waypointIdx]
    local hum = self.humanoid :: Humanoid

    -- jump waypoints need npc to manually jump (MoveTo does not auto jump)
    if wp.Action == Enum.PathWaypointAction.Jump then
        hum.Jump = true
    end

    hum:MoveTo(wp.Position)

    -- if npc is within 3 studs of the waypoint move to next one
    local root = self.rootPart :: BasePart
    if (root.Position - wp.Position).Magnitude < 3 then
        self._waypointIdx += 1
    end

    return true
end

-- rotate to face a target but its only used when npc is idle 
-- turning while moving makes the humanoid fight the cframe changes 
function NPCController:_faceTarget(target: Vector3)
    local root = self.rootPart :: BasePart
    local cf = root.CFrame
    -- keep Y level the same so npc does not tilt up or down
    local flatGoal = Vector3.new(target.X cf.Position.Y target.Z)

    if (flatGoal - cf.Position).Magnitude < 0.1 then return end

    local lookCF = CFrame.lookAt(cf.Position flatGoal)
    root.CFrame = cf:Lerp(lookCF ROTATION_ALPHA)
end

-- find the nearest enemy player and ignores the player that the npc is escorting
function NPCController:_getNearestEnemy(): (BasePart? Humanoid?)
    local root = self.rootPart :: BasePart
    local closestDist = ATTACK_RADIUS
    local closestRoot = nil :: BasePart?
    local closestHum = nil :: Humanoid?

    for _ player in Players:GetPlayers() do
        if player == self.assignedPlayer then continue end  -- do not attack our guy

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

    return closestRoot closestHum
end

-- get the root part of the player npc is supposed to follow
function NPCController:_getAssignedRoot(): BasePart?
    if not self.assignedPlayer then return nil end
    local char = (self.assignedPlayer :: Player).Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- stuck detection: if npc barely moves over time progressively escalate response
-- 1st stuck: rebuild path (maybe waypoint was bad)
-- 2nd stuck: jump (clear small obstacles)
-- 4th stuck: teleport sideways 
function NPCController:_checkStuck(dt: number)
    self._stuckTimer += dt
    if self._stuckTimer < STUCK_CHECK_INTERVAL then return end  
    self._stuckTimer = 0

    local root = self.rootPart :: BasePart
    local hum = self.humanoid :: Humanoid
    local moved = (root.Position - self._lastPos).Magnitude

    if moved < STUCK_MOVE_MINIMUM then
        self._stuckCount += 1

        -- always force a path rebuild when stuck (clears old invalid path)
        self._waypoints = {}
        self._waypointIdx = 1

        if self._stuckCount == STUCK_JUMP_THRESHOLD then
            hum.Jump = true
        end

        if self._stuckCount >= STUCK_TELEPORT_THRESHOLD then
            -- nudge to the right side relative to facing cause works better than forward 
            local nudgeDir = root.CFrame.RightVector
            root.CFrame = root.CFrame + nudgeDir * STUCK_NUDGE_DISTANCE
            self._stuckCount = 0  -- reset so npc does not spam teleport
        end
    else
        self._stuckCount = 0  -- moved enough not stuck
    end

    self._lastPos = root.Position
end

-- only rebuild the path if the target moved a lot since last path request
-- prevents constant rebuilding when target is barely moving
function NPCController:_shouldRebuildPath(currentTarget: Vector3): boolean
    return (currentTarget - self._lastTargetPos).Magnitude > PATH_REBUILD_DIST
end

-- main navigation driver which checks stuck rebuild if needed then step to next waypoint
function NPCController:_navigate(target: Vector3 dt: number)
    self:_checkStuck(dt)

    local needsRebuild = (#self._waypoints == 0)
        or (self._waypointIdx > #self._waypoints)
        or self:_shouldRebuildPath(target)

    if needsRebuild then
        self:_buildPath(target)
    end

    self:_stepPath()
end

-- runs every frame (heartbeat) handles cooldowns, speed, smoothing, etc
function NPCController:update(dt: number)
    local hum = self.humanoid :: Humanoid
    if hum.Health <= 0 then return end

    -- tick down the path rebuild cooldown
    if self._pathCooldown > 0 then
        self._pathCooldown = math.max(0 self._pathCooldown - dt)
    end

    -- exponential moving average for speed (smooth acceleration and deceleration)
    local alpha = 1 - math.exp(-SPEED_LERP_RATE * dt)
    hum.WalkSpeed = hum.WalkSpeed + (self._targetSpeed - hum.WalkSpeed) * alpha

    -- just accumulates dt until npc reaches AI_TICK_INTERVAL
    self._aiAccumulator += dt
    if self._aiAccumulator < AI_TICK_INTERVAL then return end

    local tickDt = self._aiAccumulator
    self._aiAccumulator = 0

    self:_aiTick(tickDt)
end

-- the actual ai whcih runs at 15hz to save performance
function NPCController:_aiTick(dt: number)
    local hum = self.humanoid :: Humanoid
    local assignedRoot = self:_getAssignedRoot()

    -- idle state meaning npc just stands around
    if self.currentState == State.IDLE then
        if assignedRoot then
            self:setState(State.FOLLOW)  -- got a player start following
        end

    -- follow state which just chases assigned player
    elseif self.currentState == State.FOLLOW then
        -- if no player to follow stop moving and go idle
        if not assignedRoot then
            hum:MoveTo((self.rootPart :: BasePart).Position)
            self._waypoints = {}
            self:setState(State.IDLE)
            return
        end

        -- check if there is an enemy nearby
        -- if yes it switches to attack
        local enemyRoot = self:_getNearestEnemy()
        if enemyRoot then
            self._waypoints = {}
            self:setState(State.ATTACK)
            return
        end

        local root = self.rootPart :: BasePart
        local playerDist = (assignedRoot.Position - root.Position).Magnitude

        -- sprint if npc is far behind otherwise normal speed
        if playerDist > CATCHUP_DIST then
            self._targetSpeed = SPEED_CATCHUP
        else
            self._targetSpeed = SPEED_NORMAL
        end

        -- only navigate if npc is farther than FOLLOW_STOP_DIST (do not get too close)
        if playerDist > FOLLOW_STOP_DIST then
            self:_navigate(assignedRoot.Position dt)
        end

    -- attack state npc just fights enemies
    elseif self.currentState == State.ATTACK then
        -- if it has low health it runs away
        if hum.Health / hum.MaxHealth < FLEE_HEALTH_THRESHOLD then
            self._waypoints = {}
            self:setState(State.FLEE)
            return
        end

        local enemyRoot enemyHum = self:_getNearestEnemy()
        if not enemyRoot or not enemyHum then
            -- if there are no enemies left it goes back to following
            self._waypoints = {}
            self:setState(State.FOLLOW)
            return
        end

        local root = self.rootPart :: BasePart
        local meleeDist = (enemyRoot.Position - root.Position).Magnitude

        if meleeDist <= ATTACK_RANGE then
            -- if its in melee range it stops moving and attacks on cooldown
            hum:MoveTo(root.Position)  -- stands still
            self._attackTimer += dt
            if self._attackTimer >= ATTACK_COOLDOWN then
                self._attackTimer = 0
                enemyHum:TakeDamage(ATTACK_DAMAGE)
            end
        else
            -- if out of range it chases the enemy
            self._targetSpeed = SPEED_CATCHUP
            self._attackTimer = 0
            self:_navigate(enemyRoot.Position dt)
        end

    -- flee state which just makes the npc runs away from enemies
    elseif self.currentState == State.FLEE then
        self._fleeTimer += dt
        self._targetSpeed = SPEED_FLEE

        local enemyRoot = self:_getNearestEnemy()
        if enemyRoot then
            local root = self.rootPart :: BasePart
            -- directs away from the enemy (npc position minus enemy position) then extend 30 studs
            local awayDir = (root.Position - (enemyRoot :: BasePart).Position).Unit
            local fleeDest = root.Position + awayDir * 30
            self:_navigate(fleeDest dt)
        end

        -- after FLEE_DURATION seconds stop running and go back to follow
        if self._fleeTimer >= FLEE_DURATION then
            self._fleeTimer = 0
            self._waypoints = {}
            self:setState(State.FOLLOW)
        end
    end
end

-- clean up connections so npc does not leak memory
function NPCController:destroy()
    for _ conn in self._connections do
        conn:Disconnect()
    end
    table.clear(self._connections)
    local hum = self.humanoid :: Humanoid
    local root = self.rootPart :: BasePart
    hum:MoveTo(root.Position)
end

--main setup/bootstrap 
local npcModel = workspace:WaitForChild("EscortNPC" 10)
if not npcModel then
    error("NPC not found in workspace")
end

local controller = nil

local function initController(player: Player?)
    if controller then
        controller:destroy()
    end
    controller = NPCController.new(npcModel :: Model player)
end

-- start with the first player already in the game (if any)
initController(Players:GetPlayers()[1])

-- when a new player joins assign them if npc does not have a follow target
Players.PlayerAdded:Connect(function(player: Player)
    if not controller or not controller.assignedPlayer then
        initController(player)
    end
end)

-- when the followed player leaves find another player or go idle
Players.PlayerRemoving:Connect(function(player: Player)
    if not controller then return end
    if controller.assignedPlayer ~= player then return end

    local nextPlayer = nil :: Player?
    for _ p in Players:GetPlayers() do
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

-- main game loop which just makes the heartbeat run every frame and passes delta time to update
RunService.Heartbeat:Connect(function(dt: number)
    if controller then
        controller:update(dt)
    end
end)
