--!strict

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local workspace = game:GetService("Workspace")

-- union type catches bad state strings at edit time instead of silently breaking at runtime
type NPCState = "Idle" | "Patrol" | "Chase" | "Attack" | "Flee"

-- one of these per npc, fully isolated so npc A never touches npc B's data
type NPCData = {
	State: NPCState,
	Target: Player?,               -- nil when no target, set when entering Chase/Attack/Flee
	Model: Model,
	RootPart: BasePart,
	Humanoid: Humanoid,
	Path: Path?,                   -- nil when not pathfinding, Patrol uses direct MoveTo instead
	PathBlockedConnection: RBXScriptConnection?,  -- stored separately so we can disconnect before each recompute
	MoveFinishedConnection: RBXScriptConnection?, -- needs its own disconnect when state changes
	CurrentWaypoint: number,       -- index into Waypoints, steps forward as npc walks the path
	Health: number,                -- tracked here instead of reading Humanoid.Health directly
	LastAttackTime: number,        -- os.clock timestamp, diff against ATTACK_COOLDOWN each frame
	LastPathTime: number,          -- when path was last computed, drives PATH_RECOMPUTE_INTERVAL
	LastLOSCheckTime: number,      -- LOS is throttled, not run every frame
	LastAggroCheckTime: number,    -- radius scan is also throttled
	PatrolPoints: { Vector3 },     -- world positions to loop between during Patrol
	Connections: { RBXScriptConnection }, -- all event connections, disconnected together on cleanup
	Waypoints: { PathWaypoint },   -- waypoints from the last successful path compute
	PatrolIndex: number,           -- which patrol point we're walking toward
	IdleStartTime: number,         -- when Idle started, compared against IDLE_DURATION
	FleeDirection: Vector3,
	LastTargetPosition: Vector3?,  -- last destination we pathed to, detects when target moved enough to recompute
	Destroyed: boolean,            -- set true on first cleanup, prevents double-cleanup race condition
	MoveIssuedAt: number,
	LastPathDestination: Vector3?,
	LastWaypointDistance: number,  -- decreases as npc approaches waypoint, detects when stuck
	PathGeneration: number,        -- bumps each path compute so stale Blocked callbacks know to do nothing
	LastProgressTime: number,      -- last time distance to waypoint actually shrank
}

local CONFIG = {
	IDLE_DURATION = 3,              -- why 3: long enough to look deliberate, short enough to not look broken
	AGGRO_RANGE = 60,               -- why 60: good coverage without scanning the whole map every check
	ATTACK_RANGE = 7,               -- why 7: feels melee, forgiving enough that hits actually land
	ATTACK_DAMAGE = 20,             -- 5 hits to kill at default 100hp
	ATTACK_COOLDOWN = 1.5,          -- why 1.5: punishing but gives player a window to react
	ATTACK_KNOCKBACK = 65,          -- why 65: satisfying impact without launching players off the map
	PATH_RECOMPUTE_INTERVAL = 1.25, -- tracks moving targets well without computing paths every frame
	PATH_RETRY_DELAY = 2,           -- dont hammer pathfinding immediately after a failure
	LOS_CHECK_INTERVAL = 0.35,      -- raycasts are cheap but there's no need to fire 60 per second
	AGGRO_CHECK_INTERVAL = 0.5,     -- slow enough to not be expensive, fast enough to feel reactive
	FLEE_HEALTH_THRESHOLD = 30,     -- why 30: 30% hp left, makes npcs feel like they know they're losing
	FLEE_DISTANCE = 45,
	MAX_HEALTH = 100,
	WALK_SPEED = 14,                -- slightly under player default (16) so players can outrun npcs
	FLEE_SPEED = 18,                -- faster than walk so fleeing actually works
	PATH_AGENT_RADIUS = 2,          -- npc body radius for pathfinding, matches rig roughly
	PATH_AGENT_HEIGHT = 5,          -- npc height for pathfinding, matches R15 rig roughly
	PATH_WAYPOINT_SPACING = 4,      -- fewer waypoints = less MoveToFinished overhead per path
	WAYPOINT_REACHED_DISTANCE = 3,  -- forgiving so npcs dont get stuck constantly overshooting
	MOVE_TIMEOUT = 2.5,             -- no progress for this long = stuck, clear path and retry
	HEAD_OFFSET = Vector3.new(0, 2, 0), -- fallback eye position if Head part is missing
	DEFAULT_NPC_COUNT = 4,
}

-- model as key because humanoid.Died gives us the model, not a player object
local ActiveNPCs: { [Model]: NPCData } = {}

-- WaitForChild because script can run before ReplicatedStorage is fully populated
local Template = ReplicatedStorage:WaitForChild("NPCModel") :: Model

-- forward declared because these three functions reference each other
local disconnectPathBlockedConnection: (npc: NPCData) -> ()
local disconnectMoveFinishedConnection: (npc: NPCData) -> ()
local clearPath: (npc: NPCData) -> ()

local function now(): number
	return os.clock()
end

-- covers every way an npc can go invalid without going through cleanupNPC
local function isAliveNPC(npc: NPCData?): boolean
	return npc ~= nil and not npc.Destroyed and npc.Model.Parent ~= nil and npc.RootPart.Parent ~= nil and npc.Health > 0
end

-- full teardown: disconnects everything, removes from table, destroys model
-- Destroyed flag is checked first so this is safe to call from multiple places
local function cleanupNPC(model: Model)
	local npc = ActiveNPCs[model]
	if not npc or npc.Destroyed then
		return
	end
	npc.Destroyed = true
	-- path connections arent stored in npc.Connections so we handle them separately here
	disconnectPathBlockedConnection(npc)
	disconnectMoveFinishedConnection(npc)
	for _, connection in ipairs(npc.Connections) do
		connection:Disconnect()
	end
	ActiveNPCs[model] = nil
	if model.Parent then
		model:Destroy()
	end
end

-- routes all state changes through here so side effects like WalkSpeed stay in one place
-- without this, speed assignments end up scattered across every handler function
local function setState(npc: NPCData, newState: NPCState)
	if npc.Destroyed or npc.State == newState then
		return
	end
	-- old waypoints shouldnt bleed into states that dont use pathfinding
	if newState ~= "Chase" and newState ~= "Flee" then
		clearPath(npc)
	end
	npc.State = newState
	if newState == "Idle" then
		npc.IdleStartTime = now()
	elseif newState == "Patrol" then
		npc.Humanoid.WalkSpeed = CONFIG.WALK_SPEED
	elseif newState == "Chase" then
		npc.Humanoid.WalkSpeed = CONFIG.WALK_SPEED
	elseif newState == "Attack" then
		-- zero speed + MoveTo self = stop in place
		-- without this the npc slides into the target during every hit
		npc.Humanoid.WalkSpeed = 0
		npc.Humanoid:MoveTo(npc.RootPart.Position)
	elseif newState == "Flee" then
		npc.Humanoid.WalkSpeed = CONFIG.FLEE_SPEED
	end
end

-- head position is more accurate for LOS since its at eye level, not floor level
local function getHeadPosition(npc: NPCData): Vector3
	local head = npc.Model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return npc.RootPart.Position + CONFIG.HEAD_OFFSET
end

-- called when a player leaves so any npc chasing them can pick a new state
-- without this they'd try to chase a nil target forever
local function cleanupTargetForPlayer(player: Player)
	for _, npc in pairs(ActiveNPCs) do
		if npc.Target == player then
			npc.Target = nil
			if npc.Health <= CONFIG.FLEE_HEALTH_THRESHOLD then
				setState(npc, "Flee")
			else
				setState(npc, "Patrol")
			end
		end
	end
end

local function getCharacterRoot(character: Model?): BasePart?
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function getTargetCharacter(player: Player): Model?
	local character = player.Character
	if character and character.Parent then
		return character
	end
	return nil
end

local function createRaycastParams(npc: NPCData): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { npc.Model } -- dont let the npc raycast hit its own parts
	params.IgnoreWater = true
	return params
end

local function createOverlapParams(npc: NPCData): OverlapParams
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { npc.Model }
	params.MaxParts = 0
	return params
end

-- fires a ray from npc head toward target, clear LOS if nothing blocks it
-- IsDescendantOf handles the ray clipping the target itself (still counts as LOS)
-- stops npcs from chasing players through walls
local function hasLineOfSight(npc: NPCData, targetRoot: BasePart): boolean
	local origin = getHeadPosition(npc)
	local direction = targetRoot.Position - origin
	local result = workspace:Raycast(origin, direction, createRaycastParams(npc))
	return result == nil or result.Instance:IsDescendantOf(targetRoot.Parent)
end

-- keeps the billboard health bar in sync with npc.Health
-- called on HealthChanged so it always reflects the current value
local function updateHealthBar(model: Model, health: number)
	local billboardGui = model:FindFirstChild("HealthBar")
	if not billboardGui or not billboardGui:IsA("BillboardGui") then
		return
	end
	local background = billboardGui:FindFirstChild("Background")
	if not background or not background:IsA("Frame") then
		return
	end
	local fill = background:FindFirstChild("Fill")
	if not fill or not fill:IsA("Frame") then
		return
	end
	local ratio = math.clamp(health / CONFIG.MAX_HEALTH, 0, 1)
	fill.Size = UDim2.fromScale(ratio, 1)
end

-- path.Blocked fires when something walks into the path mid-travel
-- disconnecting before each recompute stops old callbacks from clearing the new path
function disconnectPathBlockedConnection(npc: NPCData)
	if npc.PathBlockedConnection then
		npc.PathBlockedConnection:Disconnect()
		npc.PathBlockedConnection = nil
	end
end

function disconnectMoveFinishedConnection(npc: NPCData)
	if npc.MoveFinishedConnection then
		npc.MoveFinishedConnection:Disconnect()
		npc.MoveFinishedConnection = nil
	end
end

-- wipes all path state so the next handler call knows to recompute
function clearPath(npc: NPCData)
	disconnectPathBlockedConnection(npc)
	npc.Path = nil
	npc.Waypoints = {}
	npc.CurrentWaypoint = 0
	npc.LastPathDestination = nil
	npc.LastWaypointDistance = 0
end

-- radius search to find the nearest valid player to target
-- GetPartBoundsInRadius returns real parts so we can do ancestor checks
-- CollectionService tag "NPCTarget" is what controls who counts as a valid target
-- seenCharacters deduplicates since one character has many parts
-- distance check runs before LOS since its cheaper
local function findNearestTarget(npc: NPCData): Player?
	local bestPlayer: Player? = nil
	local bestDistance = CONFIG.AGGRO_RANGE
	local parts = workspace:GetPartBoundsInRadius(npc.RootPart.Position, CONFIG.AGGRO_RANGE, createOverlapParams(npc))
	local seenCharacters: { [Model]: boolean } = {}
	for _, part in ipairs(parts) do
		local character = part:FindFirstAncestorOfClass("Model")
		if character and not seenCharacters[character] and CollectionService:HasTag(character, "NPCTarget") then
			seenCharacters[character] = true
			local player = Players:GetPlayerFromCharacter(character)
			if player then
				local root = getCharacterRoot(character)
				if root then
					local distance = (root.Position - npc.RootPart.Position).Magnitude
					if distance <= bestDistance and hasLineOfSight(npc, root) then
						bestDistance = distance
						bestPlayer = player
					end
				end
			end
		end
	end
	return bestPlayer
end

-- skip waypoint 1 if we're already standing on it, avoids a stutter at path start
local function getInitialWaypointIndex(npc: NPCData, waypoints: { PathWaypoint }): number
	if #waypoints > 1 and (waypoints[1].Position - npc.RootPart.Position).Magnitude <= CONFIG.WAYPOINT_REACHED_DISTANCE then
		return 2
	end
	return 1
end

-- only triggers a recompute if target actually moved, not just from standing in place
local function targetMovedEnough(npc: NPCData, targetPosition: Vector3): boolean
	local last = npc.LastTargetPosition
	if not last then
		return true
	end
	return (targetPosition - last).Magnitude >= CONFIG.WAYPOINT_REACHED_DISTANCE * 2
end

-- paths slightly behind the target so the npc stops just in front of them
-- without this the npc tries to walk into the exact center and stutters
local function getPathDestination(targetRoot: BasePart): Vector3
	local targetPosition = targetRoot.Position
	local offset = targetRoot.CFrame.LookVector * -2
	local destination = targetPosition + offset
	return Vector3.new(destination.X, targetPosition.Y, destination.Z)
end

-- builds a new path from npc position to destination and stores it
-- pcall wraps ComputeAsync because it errors if origin/destination are inside geometry
-- PathGeneration bumps each call so stale Blocked callbacks can tell they're outdated
local function computePath(npc: NPCData, destination: Vector3): boolean
	disconnectPathBlockedConnection(npc)
	npc.PathGeneration += 1
	local generation = npc.PathGeneration
	local path = PathfindingService:CreatePath({
		AgentRadius = CONFIG.PATH_AGENT_RADIUS,
		AgentHeight = CONFIG.PATH_AGENT_HEIGHT,
		AgentCanJump = true,
		WaypointSpacing = CONFIG.PATH_WAYPOINT_SPACING,
	})
	local ok = pcall(function()
		path:ComputeAsync(npc.RootPart.Position, destination)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		clearPath(npc)
		return false
	end
	local waypoints = path:GetWaypoints()
	if #waypoints == 0 then
		clearPath(npc)
		return false
	end
	npc.Path = path
	npc.Waypoints = waypoints
	npc.CurrentWaypoint = getInitialWaypointIndex(npc, waypoints)
	npc.LastPathTime = now()
	npc.LastPathDestination = destination
	npc.LastWaypointDistance = math.huge
	npc.LastProgressTime = now()
	-- connect after storing generation so the closure captures the right value
	npc.PathBlockedConnection = path.Blocked:Connect(function(blockedIndex)
		if isAliveNPC(npc) and npc.PathGeneration == generation and blockedIndex >= npc.CurrentWaypoint then
			clearPath(npc)
		end
	end)
	return npc.Waypoints[npc.CurrentWaypoint] ~= nil
end

-- issues MoveTo for the current waypoint, triggers Jump if pathfinding flagged it
local function moveToWaypoint(npc: NPCData)
	local waypoint = npc.Waypoints[npc.CurrentWaypoint]
	if not waypoint then
		return
	end
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		npc.Humanoid.Jump = true
	end
	npc.Humanoid:MoveTo(waypoint.Position)
	npc.MoveIssuedAt = now()
	npc.LastWaypointDistance = (waypoint.Position - npc.RootPart.Position).Magnitude
	npc.LastProgressTime = now()
end

-- returns true when close enough to count as reaching the waypoint
-- also updates LastWaypointDistance so MOVE_TIMEOUT can tell if npc is genuinely stuck
local function trackProgress(npc: NPCData): boolean
	local waypoint = npc.Waypoints[npc.CurrentWaypoint]
	if not waypoint then
		return false
	end
	local distance = (waypoint.Position - npc.RootPart.Position).Magnitude
	if distance < npc.LastWaypointDistance - 0.25 then
		npc.LastWaypointDistance = distance
		npc.LastProgressTime = now()
	end
	return distance <= CONFIG.WAYPOINT_REACHED_DISTANCE
end

-- deals damage and knocks target back away from the npc
-- ApplyImpulse scaled by AssemblyMass so knockback is consistent regardless of accessories
local function attackTarget(npc: NPCData, targetRoot: BasePart)
	local t = now()
	if t - npc.LastAttackTime < CONFIG.ATTACK_COOLDOWN then
		return
	end
	npc.LastAttackTime = t
	local targetHumanoid = targetRoot.Parent and targetRoot.Parent:FindFirstChildOfClass("Humanoid")
	if targetHumanoid then
		targetHumanoid:TakeDamage(CONFIG.ATTACK_DAMAGE)
	end
	local delta = targetRoot.Position - npc.RootPart.Position
	local direction = if delta.Magnitude > 0 then delta.Unit else npc.RootPart.CFrame.LookVector
	targetRoot:ApplyImpulse(direction * CONFIG.ATTACK_KNOCKBACK * targetRoot.AssemblyMass)
end

-- direct MoveTo between patrol points, no pathfinding needed since theyre hand-placed
-- using pathfinding here would be wasted compute for something this simple
local function patrolStep(npc: NPCData)
	if #npc.PatrolPoints == 0 then
		setState(npc, "Idle")
		return
	end
	local targetPoint = npc.PatrolPoints[npc.PatrolIndex]
	if not targetPoint then
		npc.PatrolIndex = 1
		targetPoint = npc.PatrolPoints[1]
	end
	if not targetPoint then
		setState(npc, "Idle")
		return
	end
	if (npc.RootPart.Position - targetPoint).Magnitude <= CONFIG.WAYPOINT_REACHED_DISTANCE then
		npc.PatrolIndex += 1
		if npc.PatrolIndex > #npc.PatrolPoints then
			npc.PatrolIndex = 1
		end
	else
		npc.Humanoid:MoveTo(targetPoint)
	end
end

-- "away" is npc position minus target position, naturally points away from the threat
-- scaled by FLEE_DISTANCE to get a usable world destination
local function fleeDestination(npc: NPCData, targetRoot: BasePart?): Vector3
	local away = npc.RootPart.Position - (targetRoot and targetRoot.Position or npc.RootPart.Position + npc.RootPart.CFrame.LookVector)
	if away.Magnitude < 0.001 then
		away = npc.RootPart.CFrame.LookVector * -1
	end
	return npc.RootPart.Position + away.Unit * CONFIG.FLEE_DISTANCE
end

-- fixes up freshly cloned rigs before use
-- Anchored must be false or physics wont move the npc at all
-- PrimaryPart must be set for PivotTo to work correctly at spawn
local function setupTemplate(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")
	local upperTorso = model:FindFirstChild("UpperTorso")
	local lowerTorso = model:FindFirstChild("LowerTorso")
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") then
		root.Anchored = false
		root.CanCollide = true
		root.Position = Vector3.zero
		model.PrimaryPart = root
	end
	if head and head:IsA("BasePart") then
		head.Position = Vector3.new(0, 3, 0)
		head.Anchored = false
	end
	if upperTorso and upperTorso:IsA("BasePart") then
		upperTorso.Position = Vector3.new(0, 2, 0)
		upperTorso.Anchored = false
	end
	if lowerTorso and lowerTorso:IsA("BasePart") then
		lowerTorso.Position = Vector3.new(0, 1, 0)
		lowerTorso.Anchored = false
	end
	if humanoid then
		-- hide default nametag and health bar, we use our own BillboardGui instead
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
end

-- WeldConstraints over Motor6Ds because npcs dont need animation, just a solid body physics can push
local function weldParts(model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")
	local upperTorso = model:FindFirstChild("UpperTorso")
	local lowerTorso = model:FindFirstChild("LowerTorso")
	local function weld(part0: Instance?, part1: Instance?)
		if part0 and part1 and part0:IsA("BasePart") and part1:IsA("BasePart") then
			local weldConstraint = Instance.new("WeldConstraint")
			weldConstraint.Part0 = part0
			weldConstraint.Part1 = part1
			weldConstraint.Parent = model
		end
	end
	weld(root, upperTorso)
	weld(upperTorso, lowerTorso)
	weld(upperTorso, head)
end

-- clones the template, wires all connections, registers in ActiveNPCs
-- SetNetworkOwner(nil) keeps physics server-authoritative on every limb
-- without this roblox hands ownership to a nearby client and the npc jitters
local function spawnNPC(position: Vector3, patrolPoints: { Vector3 }): Model?
	local clone = Template:Clone()
	clone.Parent = workspace
	setupTemplate(clone)
	weldParts(clone)
	local root = clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart")
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid then
		clone:Destroy()
		return nil
	end
	clone:PivotTo(CFrame.new(position))
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant:SetNetworkOwner(nil)
		end
	end
	local npc: NPCData = {
		State = "Idle",
		Target = nil,
		Model = clone,
		RootPart = root,
		Humanoid = humanoid,
		Path = nil,
		PathBlockedConnection = nil,
		MoveFinishedConnection = nil,
		CurrentWaypoint = 0,
		Health = CONFIG.MAX_HEALTH,
		LastAttackTime = 0,
		LastPathTime = 0,
		LastLOSCheckTime = 0,
		LastAggroCheckTime = 0,
		PatrolPoints = patrolPoints,
		Connections = {},
		Waypoints = {},
		PatrolIndex = 1,
		IdleStartTime = now(),
		FleeDirection = Vector3.zero,
		LastTargetPosition = nil,
		Destroyed = false,
		MoveIssuedAt = 0,
		LastPathDestination = nil,
		LastWaypointDistance = 0,
		PathGeneration = 0,
		LastProgressTime = now(),
	}
	ActiveNPCs[clone] = npc
	humanoid.MaxHealth = CONFIG.MAX_HEALTH
	humanoid.Health = CONFIG.MAX_HEALTH
	humanoid.WalkSpeed = CONFIG.WALK_SPEED
	humanoid.AutoRotate = true
	updateHealthBar(clone, npc.Health)

	-- sync our npc.Health field whenever Humanoid.Health changes
	-- this way damage from any source (sword, script, etc) gets picked up correctly
	table.insert(npc.Connections, humanoid.HealthChanged:Connect(function(health)
		npc.Health = math.clamp(health, 0, CONFIG.MAX_HEALTH)
		updateHealthBar(clone, npc.Health)
	end))

	table.insert(npc.Connections, humanoid.Died:Connect(function()
		cleanupNPC(clone)
	end))

	-- stored separately from npc.Connections so it can be disconnected independently
	-- if it stayed connected during Attack state it would try to advance waypoints that dont exist
	npc.MoveFinishedConnection = humanoid.MoveToFinished:Connect(function(reached)
		if not isAliveNPC(npc) or (npc.State ~= "Chase" and npc.State ~= "Flee") then
			return
		end
		if reached then
			npc.CurrentWaypoint += 1
			if npc.Waypoints[npc.CurrentWaypoint] then
				moveToWaypoint(npc)
			else
				clearPath(npc) -- end of path, handler will recompute next frame if still chasing
			end
			return
		end
		clearPath(npc) -- MoveTo timed out, handler will recompute
	end)
	setState(npc, "Idle")
	return clone
end

-- patrol points form a small triangle around spawn so npcs look active from the start
local function initializeNPCs()
	local positions = { Vector3.new(0, 5, 0), Vector3.new(20, 5, 10), Vector3.new(-25, 5, 15), Vector3.new(35, 5, -12) }
	for i = 1, CONFIG.DEFAULT_NPC_COUNT do
		local base = positions[i] or Vector3.new(i * 8, 5, i * 6)
		spawnNPC(base, { base + Vector3.new(10, 0, 0), base + Vector3.new(10, 0, 10), base + Vector3.new(0, 0, 10) })
	end
end

-- waits out IDLE_DURATION then moves to Patrol
-- also checks for players so npc reacts immediately even if it just spawned
local function handleIdle(npc: NPCData)
	if now() - npc.IdleStartTime >= CONFIG.IDLE_DURATION then
		setState(npc, "Patrol")
		return
	end
	local target = findNearestTarget(npc)
	if target then
		npc.Target = target
		setState(npc, "Chase")
	end
end

-- walks the patrol loop while scanning for players on a throttled interval
local function handlePatrol(npc: NPCData)
	patrolStep(npc)
	if now() - npc.LastAggroCheckTime >= CONFIG.AGGRO_CHECK_INTERVAL then
		npc.LastAggroCheckTime = now()
		local target = findNearestTarget(npc)
		if target then
			npc.Target = target
			setState(npc, "Chase")
		end
	end
end

-- pathfinds toward target, handles three interruptions:
-- target gone/dead -> Patrol, target breaks LOS -> Patrol, close enough -> Attack
-- trackProgress + MOVE_TIMEOUT handles stuck npcs by clearing and recomputing the path
local function handleChase(npc: NPCData)
	local target = npc.Target
	local character = target and getTargetCharacter(target)
	local targetRoot = getCharacterRoot(character)
	if not target or not character or not targetRoot then
		npc.Target = nil
		setState(npc, "Patrol")
		return
	end
	-- throttled LOS check, drops chase if target ducks behind cover
	if now() - npc.LastLOSCheckTime >= CONFIG.LOS_CHECK_INTERVAL then
		npc.LastLOSCheckTime = now()
		if not hasLineOfSight(npc, targetRoot) then
			npc.Target = nil
			setState(npc, "Patrol")
			return
		end
	end
	local distance = (targetRoot.Position - npc.RootPart.Position).Magnitude
	if distance <= CONFIG.ATTACK_RANGE then
		setState(npc, "Attack")
		return
	end
	local destination = getPathDestination(targetRoot)
	npc.LastTargetPosition = destination
	-- recompute if: no path, interval elapsed, or target moved significantly
	local needsPath = not npc.Path or now() - npc.LastPathTime >= CONFIG.PATH_RECOMPUTE_INTERVAL or targetMovedEnough(npc, destination)
	if needsPath then
		if not computePath(npc, destination) then
			npc.Target = nil
			setState(npc, "Patrol")
			return
		end
		moveToWaypoint(npc)
	elseif trackProgress(npc) then
		npc.CurrentWaypoint += 1
		if npc.Waypoints[npc.CurrentWaypoint] then
			moveToWaypoint(npc)
		else
			clearPath(npc)
		end
	elseif now() - npc.LastProgressTime >= CONFIG.MOVE_TIMEOUT then
		clearPath(npc) -- stuck, will recompute next frame
	end
	if npc.Health <= CONFIG.FLEE_HEALTH_THRESHOLD then
		setState(npc, "Flee")
	end
end

-- stands still and hits target on cooldown
-- backs off to Chase if target moves away, Flee if health gets low mid-fight
local function handleAttack(npc: NPCData)
	local target = npc.Target
	local character = target and getTargetCharacter(target)
	local targetRoot = getCharacterRoot(character)
	if not target or not targetRoot then
		npc.Target = nil
		setState(npc, "Patrol")
		return
	end
	local distance = (targetRoot.Position - npc.RootPart.Position).Magnitude
	if distance > CONFIG.ATTACK_RANGE then
		setState(npc, "Chase")
		return
	end
	attackTarget(npc, targetRoot)
	if npc.Health <= CONFIG.FLEE_HEALTH_THRESHOLD then
		setState(npc, "Flee")
	end
end

-- same path infrastructure as Chase but destination points away from the threat
-- returns to Patrol (not Idle) once far enough so the npc stays active
local function handleFlee(npc: NPCData)
	local target = npc.Target
	local character = target and getTargetCharacter(target)
	local targetRoot = getCharacterRoot(character)
	local destination = fleeDestination(npc, targetRoot)
	npc.LastTargetPosition = destination
	local needsPath = not npc.Path or now() - npc.LastPathTime >= CONFIG.PATH_RECOMPUTE_INTERVAL or targetMovedEnough(npc, destination)
	if needsPath then
		if computePath(npc, destination) then
			moveToWaypoint(npc)
		end
	elseif trackProgress(npc) then
		npc.CurrentWaypoint += 1
		if npc.Waypoints[npc.CurrentWaypoint] then
			moveToWaypoint(npc)
		else
			clearPath(npc)
		end
	elseif now() - npc.LastProgressTime >= CONFIG.MOVE_TIMEOUT then
		clearPath(npc)
	end
	if targetRoot and (targetRoot.Position - npc.RootPart.Position).Magnitude >= CONFIG.FLEE_DISTANCE then
		npc.Target = nil
		setState(npc, "Patrol")
	end
end

Players.PlayerRemoving:Connect(function(player)
	cleanupTargetForPlayer(player)
end)

-- single Heartbeat drives all npcs at once
-- Heartbeat fires after physics so positions are settled for this frame
-- Stepped fires before physics (stale data), RenderStepped is client-only
-- one connection for all npcs is cheaper than spinning up N separate loops
--
-- state machine:
-- Idle -> Patrol -> Chase -> Attack -> Flee
--                     
RunService.Heartbeat:Connect(function()
	for model, npc in pairs(ActiveNPCs) do
		if not isAliveNPC(npc) then
			cleanupNPC(model)
		elseif npc.State == "Idle" then
			handleIdle(npc)
		elseif npc.State == "Patrol" then
			handlePatrol(npc)
		elseif npc.State == "Chase" then
			handleChase(npc)
		elseif npc.State == "Attack" then
			handleAttack(npc)
		elseif npc.State == "Flee" then
			handleFlee(npc)
		end
	end
end)

initializeNPCs()
