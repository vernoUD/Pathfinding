local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
 
-- make the remote stuff for the hud
local eventsFolder      = Instance.new("Folder")
eventsFolder.Name       = "NPCEvents"
eventsFolder.Parent     = ReplicatedStorage
 
local stateChangedEvent = Instance.new("RemoteEvent")
stateChangedEvent.Name  = "StateChanged"
stateChangedEvent.Parent = eventsFolder
 
-- numbers to tweak
local ATTACK_RADIUS         = 20    -- when to start attacking
local ATTACK_RANGE          = 5     -- melee reach
local ATTACK_COOLDOWN       = 1.2
local ATTACK_DAMAGE         = 15
local FLEE_HEALTH_THRESHOLD = 0.25  -- 25% hp
local FLEE_DURATION         = 8
local ROTATION_ALPHA        = 0.15  -- how fast it turns to face you in idle
local STUCK_CHECK_INTERVAL  = 1.2
local STUCK_MOVE_MINIMUM    = 1.5   -- if it moved less than this in the interval its stuck
local PATH_REBUILD_DIST     = 10    -- only rebuild path if you move this far
local FOLLOW_STOP_DIST      = 4
local PATH_REBUILD_COOLDOWN = 0.4   -- min seconds between path rebuilds
local SPEED_LERP_RATE       = 6
 
-- just the tickrate to make sure it runs smoothly

local AI_TICK_RATE     = 15
local AI_TICK_INTERVAL = 1 / AI_TICK_RATE
 
-- player default walkspeed is 16
local SPEED_NORMAL    = 18
local SPEED_CATCHUP   = 28  -- when its falling behind
local SPEED_FLEE      = 24
local CATCHUP_DIST    = 18
 
-- how to handle being stuck on walls
-- first stuck = rebuild path
-- 2nd stuck = jump
-- 4th stuck = nudge sideways
local STUCK_JUMP_THRESHOLD     = 2
local STUCK_TELEPORT_THRESHOLD = 4
local STUCK_NUDGE_DISTANCE     = 3
 
-- agent radius 3 keeps it away from wall corners
local PATH_AGENT_PARAMS = {
	AgentRadius     = 3,
	AgentHeight     = 5,
	AgentCanJump    = true,
	AgentCanClimb   = false,
	WaypointSpacing = 4,
}
 
-- freeze it so i cant typo state names
local State = table.freeze({
	IDLE   = "Idle",
	FOLLOW = "Follow",
	ATTACK = "Attack",
	FLEE   = "Flee",
})
 
-- npc class
local NPCController = {}
NPCController.__index = NPCController
 
-- assigned player is just the followed player
function NPCController.new(model: Model, assignedPlayer: Player?)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
 
	-- unanchor everything so it doesnt get stuck
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
 
	-- start in follow if theres a player so it can pathfind out of walls etc
	-- idle is only when nobodys there
	local startState = if assignedPlayer then State.FOLLOW else State.IDLE
 
	local self = setmetatable({
		model           = model,
		humanoid        = humanoid,
		rootPart        = rootPart,
		assignedPlayer  = assignedPlayer,
		currentState    = startState,
		_waypoints      = {} :: { PathWaypoint },
		_waypointIdx    = 1,
		_lastPos        = (rootPart :: BasePart).Position,
		_lastTargetPos  = Vector3.zero,
		_stuckTimer     = 0,
		_stuckCount     = 0,
		_attackTimer    = 0,
		_fleeTimer      = 0,
		_pathCooldown   = 0,
		_targetSpeed    = SPEED_NORMAL,
		_aiAccumulator  = 0,
		_connections    = {} :: { RBXScriptConnection },
	}, NPCController)
 
	-- :Once cleans itself up so no need to disconnect
	local deathConn = (humanoid :: Humanoid).Died:Once(function()
		self:destroy()
	end)
	table.insert(self._connections, deathConn)
 
	-- tell the hud what state we started in
	stateChangedEvent:FireAllClients(model, startState)
 
	return self
end
 
-- changes state by firing the remote
function NPCController:setState(newState: string)
	if self.currentState == newState then return end
	self.currentState = newState
	stateChangedEvent:FireAllClients(self.model, newState)
end
 
-- ask pathfindingservice for a route to target
-- has a cooldown so it cant be called nonstop
function NPCController:_buildPath(target: Vector3): boolean
	if self._pathCooldown > 0 then
		return #self._waypoints > 0
	end
	self._pathCooldown = PATH_REBUILD_COOLDOWN
 
	local root = self.rootPart :: BasePart
	local path = PathfindingService:CreatePath(PATH_AGENT_PARAMS)
 
	-- ComputeAsync errors if the target is unreachable
	local ok = pcall(function()
		path:ComputeAsync(root.Position, target)
	end)
 
	if not ok or path.Status ~= Enum.PathStatus.Success then
		warn("[NPCController] Path failed: " .. tostring(path.Status))
		return false
	end
 
	self._waypoints     = path:GetWaypoints()
	self._waypointIdx   = 2  -- skip waypoint 1, its our current pos
	self._lastTargetPos = target
	return true
end
 
-- walk to the next waypoint
-- not using MoveToFinished cuz it has an 8 sec timeout that ruins long paths
function NPCController:_stepPath(): boolean
	if self._waypointIdx > #self._waypoints then
		return false
	end
 
	local wp  = self._waypoints[self._waypointIdx]
	local hum = self.humanoid :: Humanoid
 
	-- have to manually jump for jump waypoints
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
 
-- rotate the npc to face a target (only in idle)
-- doing this while moving makes the cframe fight the humanoid physics and the
-- npc just freezes in place. found out the hard way
function NPCController:_faceTarget(target: Vector3)
	local root     = self.rootPart :: BasePart
	local cf       = root.CFrame
	local flatGoal = Vector3.new(target.X, cf.Position.Y, target.Z)  -- only rotate yaw
 
	if (flatGoal - cf.Position).Magnitude < 0.1 then return end
 
	local lookCF = CFrame.lookAt(cf.Position, flatGoal)
	root.CFrame  = cf:Lerp(lookCF, ROTATION_ALPHA)
end
 
-- find the closest other player within attack range
function NPCController:_getNearestEnemy(): (BasePart?, Humanoid?)
	local root        = self.rootPart :: BasePart
	local closestDist = ATTACK_RADIUS
	local closestRoot = nil :: BasePart?
	local closestHum  = nil :: Humanoid?
 
	for _, player in Players:GetPlayers() do
		if player == self.assignedPlayer then continue end
 
		local char = player.Character
		if not char then continue end
 
		local enemyRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local enemyHum  = char:FindFirstChildOfClass("Humanoid")
		if not enemyRoot or not enemyHum then continue end
		if enemyHum.Health <= 0 then continue end
 
		local dist = (enemyRoot.Position - root.Position).Magnitude
		if dist < closestDist then
			closestDist = dist
			closestRoot = enemyRoot
			closestHum  = enemyHum
		end
	end
 
	return closestRoot, closestHum
end
 
-- get the players HRP, returns nil if they left or havent loaded
function NPCController:_getAssignedRoot(): BasePart?
	if not self.assignedPlayer then return nil end
	local char = (self.assignedPlayer :: Player).Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end
 
-- checks if it hasent moved for a whhile
-- if it hasnt: rebuild > jump > nudging sideways
function NPCController:_checkStuck(dt: number)
	self._stuckTimer += dt
	if self._stuckTimer < STUCK_CHECK_INTERVAL then return end
	self._stuckTimer = 0
 
	local root  = self.rootPart :: BasePart
	local hum   = self.humanoid :: Humanoid
	local moved = (root.Position - self._lastPos).Magnitude
 
	if moved < STUCK_MOVE_MINIMUM then
		self._stuckCount += 1
 
		-- always rebuild
		self._waypoints   = {}
		self._waypointIdx = 1
 
		-- jump if still stuck
		if self._stuckCount == STUCK_JUMP_THRESHOLD then
			hum.Jump = true
		end
 
		-- last resort, push it sideways. uses RightVector so it follows facing
		if self._stuckCount >= STUCK_TELEPORT_THRESHOLD then
			local nudgeDir = root.CFrame.RightVector
			root.CFrame = root.CFrame + nudgeDir * STUCK_NUDGE_DISTANCE
			self._stuckCount = 0
		end
	else
		self._stuckCount = 0
	end
 
	self._lastPos = root.Position
end
 
-- only rebuild the path if the target moved a lot since last rebuild
function NPCController:_shouldRebuildPath(currentTarget: Vector3): boolean
	return (currentTarget - self._lastTargetPos).Magnitude > PATH_REBUILD_DIST
end
 
-- handles the path rebuild + step logic, used by follow/attack/flee
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
 
--  only does cheap stuff like ticking timers and lerping speed cause it runs every heartbeat
-- the actual ai logic only runs every 1/15 seconds via _aiTick as i set it above
function NPCController:update(dt: number)
	local hum = self.humanoid :: Humanoid
	if hum.Health <= 0 then return end
 
	-- tick the path cooldown
	if self._pathCooldown > 0 then
		self._pathCooldown = math.max(0, self._pathCooldown - dt)
	end
 
	local alpha = 1 - math.exp(-SPEED_LERP_RATE * dt)
	hum.WalkSpeed = hum.WalkSpeed + (self._targetSpeed - hum.WalkSpeed) * alpha
 
	-- we pass the accumulated dt so timers inside still work correctly
	self._aiAccumulator += dt
	if self._aiAccumulator < AI_TICK_INTERVAL then return end
 
	local tickDt = self._aiAccumulator
	self._aiAccumulator = 0
 
	self:_aiTick(tickDt)
end
 
-- the actual ai brain logic 
function NPCController:_aiTick(dt: number)
	local hum          = self.humanoid :: Humanoid
	local assignedRoot = self:_getAssignedRoot()
 
	-- idle state ig?
	if self.currentState == State.IDLE then
		if assignedRoot then
			self:setState(State.FOLLOW)
		end
 
		-- follows a player
	elseif self.currentState == State.FOLLOW then
		if not assignedRoot then
			hum:MoveTo((self.rootPart :: BasePart).Position)
			self._waypoints = {}
			self:setState(State.IDLE)
			return
		end
 
		-- checks for enemies
		local enemyRoot = self:_getNearestEnemy()
		if enemyRoot then
			self._waypoints = {}
			self:setState(State.ATTACK)
			return
		end
 
		local root       = self.rootPart :: BasePart
		local playerDist = (assignedRoot.Position - root.Position).Magnitude
 
		-- sprint if its way behind
		if playerDist > CATCHUP_DIST then
			self._targetSpeed = SPEED_CATCHUP
		else
			self._targetSpeed = SPEED_NORMAL
		end
 
		-- stops at follow_stop_dist
		if playerDist > FOLLOW_STOP_DIST then
			self:_navigate(assignedRoot.Position, dt)
		end
 
 -- attacking state
	elseif self.currentState == State.ATTACK then
		if hum.Health / hum.MaxHealth < FLEE_HEALTH_THRESHOLD then
			self._waypoints = {}
			self:setState(State.FLEE)
			return
		end
 
		local enemyRoot, enemyHum = self:_getNearestEnemy()
		if not enemyRoot or not enemyHum then
			--  goes back to following
			self._waypoints = {}
			self:setState(State.FOLLOW)
			return
		end
 
		local root      = self.rootPart :: BasePart
		local meleeDist = (enemyRoot.Position - root.Position).Magnitude
 
		if meleeDist <= ATTACK_RANGE then
			hum:MoveTo(root.Position)
			self._attackTimer += dt
			if self._attackTimer >= ATTACK_COOLDOWN then
				self._attackTimer = 0
				enemyHum:TakeDamage(ATTACK_DAMAGE)
			end
		else
			-- run at them
			self._targetSpeed = SPEED_CATCHUP
			self._attackTimer = 0
			self:_navigate(enemyRoot.Position, dt)
		end
 
		-- runs away the opposite side for a few seeconds
	elseif self.currentState == State.FLEE then
		self._fleeTimer += dt
		self._targetSpeed = SPEED_FLEE
 
		local enemyRoot = self:_getNearestEnemy()
		if enemyRoot then
			local root    = self.rootPart :: BasePart
			-- flip the vector to enemy to get the run away direction
			local awayDir  = (root.Position - (enemyRoot :: BasePart).Position).Unit
			local fleeDest = root.Position + awayDir * 30
			self:_navigate(fleeDest, dt)
		end
 
		-- after flee duration go back to follow 
		if self._fleeTimer >= FLEE_DURATION then
			self._fleeTimer = 0
			self._waypoints = {}
			self:setState(State.FOLLOW)
		end
	end
end
 
-- cleanup
function NPCController:destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	local hum  = self.humanoid :: Humanoid
	local root = self.rootPart :: BasePart
	hum:MoveTo(root.Position)
end
 
-- setup
local npcModel = workspace:WaitForChild("EscortNPC", 10)
if not npcModel then
	error(" EscortNPC not found in Workspace within 10 seconds")
end
 
local controller = nil
 
local function initController(player: Player?)
	if controller then
		controller:destroy()
	end
	controller = NPCController.new(npcModel :: Model, player)
end
 
-- start now in case PlayerAdded already fired
initController(Players:GetPlayers()[1])
 
Players.PlayerAdded:Connect(function(player: Player)
	if not controller or not controller.assignedPlayer then
		initController(player)
	end
end)
 
Players.PlayerRemoving:Connect(function(player: Player)
	if not controller then return end
	if controller.assignedPlayer ~= player then return end
 
	-- find someone else to follow
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
