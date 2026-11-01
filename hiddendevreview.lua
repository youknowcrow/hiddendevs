-- Github: @YouKnowCrow
-- Discord: 1i5c (1187402552283775076)
-- Roblox: YouKnowCro

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")

local DEBRIS_GROUP = "DestructionDebris"
local CHARACTER_GROUP = "DestructionCharacters"

local settings = {
	-- breaking is opt in through tags so you pick which parts can break instead of the whole map
	destructibleTag = "Destructible",
	toolTag = "DestructionTool",

	-- a part's own Health attribute wins, then its material, then this default
	defaultHealth = 1,
	materialHealth = {
		[Enum.Material.Glass] = 15,
		[Enum.Material.Wood] = 60,
		[Enum.Material.WoodPlanks] = 60,
		[Enum.Material.Brick] = 120,
		[Enum.Material.Concrete] = 200,
		[Enum.Material.Slate] = 250,
	},

	-- a box only gets split if its longest side is at least double this, so no chunk ends up thinner
	minChunkLength = 1,
	minChunkCount = 4,
	maxChunkCount = 28,
	chunksPerStud = 1.6,
	-- how much distance from the hit lowers a box's split priority. higher = small pieces bunch up
	-- tighter around the impact while the far side stays in big slabs
	splitFocus = 0.5,

	-- below this relative speed a touch is just a bump. only the speed above it counts toward damage,
	-- so damage ramps up from zero instead of jumping straight to a big number
	minImpactSpeed = 30,
	damagePerSpeed = 2,

	launchForce = 45,
	-- faster impacts throw the debris harder on top of the base force
	launchForcePerImpactSpeed = 0.5,
	-- chunks far from the hit get less speed, so the impact point bursts and the far side crumbles
	launchFalloff = 0.3,
	-- bias the launch upward so debris arcs through the air instead of skidding along the floor
	launchLift = 0.35,
	launchSpin = 6,

	debrisLifetime = 10,
	debrisFadeTime = 1.5,
	maxDebris = 250,

	respawnDelay = 15,
	respawnRetryDelay = 2,
	respawnFadeTime = 0.6,

	toolRange = 10,
	toolDamage = 40,
	toolLaunchForce = 70,

	-- full damage at the center, scaled down linearly to zero at the edge of the blast
	explosionDamage = 300,
	explosionLaunchMultiplier = 2,
	defaultBlastRadius = 14,

	dustParticleCount = 18,

	-- any hit that does damage breaks the part outright. turn off to use the health values above
	-- (which also turns on the darkening + dust feedback for hits that dont break it)
	instantBreak = true,
}

local rng = Random.new()

local debrisFolder = workspace:FindFirstChild("DestructionDebris") or Instance.new("Folder")
debrisFolder.Name = "DestructionDebris"
debrisFolder.Parent = workspace

-- support checks and respawn checks skip debris. otherwise a pile of rubble would count as holding a
-- part up, and loose chunks lying where a part used to be would block it from ever respawning
local ignoreDebrisParams = OverlapParams.new()
ignoreDebrisParams.FilterType = Enum.RaycastFilterType.Exclude
ignoreDebrisParams.FilterDescendantsInstances = {debrisFolder}



-- debris leaves with a big impulse, so if it could hit characters it would fling players across the
-- map. putting both in groups that ignore each other lets rubble pass straight through people
local function setupCollisionGroups()
	for _, group in ipairs({DEBRIS_GROUP, CHARACTER_GROUP}) do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(DEBRIS_GROUP, CHARACTER_GROUP, false)
end

local function assignCharacterGroup(instance)
	if not instance:IsA("BasePart") then return end
	instance.CollisionGroup = CHARACTER_GROUP
end

-- tools and accessories get added after the character spawns, so we keep listening instead of only
-- tagging what is there at the start
local function onCharacterAdded(character)
	for _, descendant in ipairs(character:GetDescendants()) do
		assignCharacterGroup(descendant)
	end
	character.DescendantAdded:Connect(assignCharacterGroup)
end

local function onPlayerAdded(player)
	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end



local function getVolume(size)
	return size.X * size.Y * size.Z
end

-- in the part's own space the box is axis aligned, so clamping each axis to the half size gives the
-- nearest point on it even when the part is rotated. then convert back to world space
local function closestPointOnPart(cframe, size, worldPoint)
	local localPoint = cframe:PointToObjectSpace(worldPoint)
	local halfSize = size / 2
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -halfSize.X, halfSize.X),
		math.clamp(localPoint.Y, -halfSize.Y, halfSize.Y),
		math.clamp(localPoint.Z, -halfSize.Z, halfSize.Z)
	)
	return cframe:PointToWorldSpace(clamped)
end

local function getLongestAxis(size)
	if size.X >= size.Y and size.X >= size.Z then
		return Enum.Axis.X, size.X
	end
	if size.Y >= size.Z then
		return Enum.Axis.Y, size.Y
	end
	return Enum.Axis.Z, size.Z
end



-- always cutting the longest side keeps chunks chunky instead of turning them into thin slivers.
-- cutting at a random ratio instead of the middle is what stops it looking like a grid of perfect cubes.
-- offsets go through the box's own cframe so rotated parts split along their real faces not world axes
local function splitBox(box)
	local axis, length = getLongestAxis(box.Size)
	local axisDirection = Vector3.FromAxis(axis)
	local firstLength = length * rng:NextNumber(0.35, 0.65)
	local secondLength = length - firstLength

	-- shrinking one side moves its center toward the other side by half of whatever got cut off,
	-- which is exactly half the length of the other piece
	local first = {
		CFrame = box.CFrame * CFrame.new(-axisDirection * secondLength / 2),
		Size = box.Size - axisDirection * secondLength,
	}
	local second = {
		CFrame = box.CFrame * CFrame.new(axisDirection * firstLength / 2),
		Size = box.Size - axisDirection * firstLength,
	}
	return first, second
end

-- big boxes close to the hit get split first. dividing volume by distance (instead of just taking the
-- biggest box) is what gives small pieces at the impact and big ones further away
local function pickBoxToSplit(boxes, hitPosition)
	local bestIndex, bestScore = nil, 0
	for index, box in ipairs(boxes) do
		local _, length = getLongestAxis(box.Size)
		if length < settings.minChunkLength * 2 then continue end

		local distance = (box.CFrame.Position - hitPosition).Magnitude
		local score = getVolume(box.Size) / (1 + distance * settings.splitFocus)
		if score > bestScore then
			bestIndex, bestScore = index, score
		end
	end
	return bestIndex
end

-- every split swaps one box for two, so the list grows by one each pass. stops early if every box
-- is already too small to split, so tiny parts just break into fewer pieces
local function fracture(cframe, size, hitPosition, targetCount)
	local boxes = {{CFrame = cframe, Size = size}}
	while #boxes < targetCount do
		local index = pickBoxToSplit(boxes, hitPosition)
		if not index then break end

		local first, second = splitBox(table.remove(boxes, index))
		table.insert(boxes, first)
		table.insert(boxes, second)
	end
	return boxes
end

-- cube root of volume so a pillar and a wall with the same bulk break into about the same amount,
-- otherwise huge walls would spawn hundreds of parts and lag the server for everyone
local function getChunkCount(size)
	local count = math.floor(getVolume(size) ^ (1 / 3) * settings.chunksPerStud)
	return math.clamp(count, settings.minChunkCount, settings.maxChunkCount)
end



local function fadeAndDestroy(part, duration)
	local tween = TweenService:Create(part, TweenInfo.new(duration), {Transparency = 1})
	tween.Completed:Once(function()
		part:Destroy()
	end)
	tween:Play()
end

-- Debris is the backup. if the fade tween gets interrupted or the server hitches, the part still gets
-- removed instead of sitting there forever
local function scheduleCleanup(part)
	Debris:AddItem(part, settings.debrisLifetime + settings.debrisFadeTime + 1)
	task.delay(settings.debrisLifetime, function()
		if not part.Parent then return end
		fadeAndDestroy(part, settings.debrisFadeTime)
	end)
end

-- a first in first out queue of live debris. it uses head/tail indices instead of
-- table.remove(queue, 1) so taking from the front doesnt shift the whole array every time
local DebrisPool = {}
DebrisPool.__index = DebrisPool

function DebrisPool.new(maxCount)
	local self = setmetatable({}, DebrisPool)
	self.maxCount = maxCount
	self.liveCount = 0
	self.tracked = {} -- parts that are currently counted in liveCount
	self.queue = {}
	self.head = 1
	self.tail = 0
	return self
end

function DebrisPool:isEmpty()
	return self.head > self.tail
end

function DebrisPool:popFront()
	local part = self.queue[self.head]
	self.queue[self.head] = nil
	self.head += 1
	return part
end

-- Destroying fires deferred with the default SignalBehavior, so trimToLimit() also lowers the count
-- straight away. the tracked set makes sure a part only gets subtracted once no matter which runs first
function DebrisPool:untrack(part)
	if not self.tracked[part] then return end
	self.tracked[part] = nil
	self.liveCount -= 1
end

function DebrisPool:add(part)
	self.tail += 1
	self.queue[self.tail] = part
	self.tracked[part] = true
	self.liveCount += 1
	part.Destroying:Once(function()
		self:untrack(part)
	end)

	scheduleCleanup(part)
	self:dropExpired()
	self:trimToLimit()
end

-- every chunk has the same lifetime so they die in roughly the order they were added. popping the
-- dead ones off the front keeps the queue from growing for the whole life of the server
function DebrisPool:dropExpired()
	while not self:isEmpty() and self.queue[self.head].Parent == nil do
		self:popFront()
	end
end

-- chain reactions can make debris faster than it expires. removing the oldest first keeps physics
-- cheap and the newest rubble (the stuff players are actually looking at) stays
function DebrisPool:trimToLimit()
	while self.liveCount > self.maxCount and not self:isEmpty() do
		local oldest = self:popFront()
		self:untrack(oldest)
		oldest:Destroy()
	end
end

local debrisPool = DebrisPool.new(settings.maxDebris)


-- only copy how it looks. cloning the original would copy the tag + attributes too and every chunk
-- would turn into a new destructible and keep breaking forever
local function createChunk(source, box)
	local chunk = Instance.new("Part")
	chunk.Size = box.Size
	chunk.CFrame = box.CFrame
	chunk.Color = source.Color
	chunk.Material = source.Material
	chunk.MaterialVariant = source.MaterialVariant
	chunk.Reflectance = source.Reflectance
	chunk.Transparency = source.Transparency
	chunk.TopSurface = Enum.SurfaceType.Smooth
	chunk.BottomSurface = Enum.SurfaceType.Smooth
	chunk.CollisionGroup = DEBRIS_GROUP
	chunk:SetAttribute("IsDebris", true)
	chunk.Parent = debrisFolder
	-- server keeps ownership because impulses from the server get ignored on parts a client owns,
	-- and the debris dies too fast for handing it off to save anything
	chunk:SetNetworkOwner(nil)
	return chunk
end

-- the impulse is multiplied by the chunk's mass so big and small pieces fly at about the same speed.
-- without it tiny shards go into orbit and the big slabs barely move
local function launchChunk(chunk, hitPosition, force)
	local offset = chunk.Position - hitPosition
	local distance = offset.Magnitude
	-- a chunk sitting right on the hit point has no "away" direction, so give it a random one
	local direction = if distance > 0.001 then offset.Unit else rng:NextUnitVector()
	direction = (direction + Vector3.yAxis * settings.launchLift).Unit

	local speed = force / (1 + distance * settings.launchFalloff)
	chunk:ApplyImpulse(direction * speed * chunk.AssemblyMass)
	chunk:ApplyAngularImpulse(rng:NextUnitVector() * settings.launchSpin * chunk.AssemblyMass)
end

-- a quick dust puff sells the hit way more than chunks alone. the attachment lives on Terrain because
-- the part it came from might be destroyed this frame, and Debris removes it once the particles are gone
local function emitDust(position, color)
	local attachment = Instance.new("Attachment")
	attachment.Parent = workspace.Terrain
	attachment.WorldPosition = position

	local emitter = Instance.new("ParticleEmitter")
	-- mixed toward white so it reads as powder instead of solid colored blobs
	emitter.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.4))
	emitter.Size = NumberSequence.new(1.5, 4)
	emitter.Transparency = NumberSequence.new(0.3, 1)
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Speed = NumberRange.new(6, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Drag = 4
	-- one burst with Emit() instead of a continuous stream
	emitter.Enabled = false
	emitter.Parent = attachment
	emitter:Emit(settings.dustParticleCount)

	Debris:AddItem(attachment, 2)
end

-- explosive parts go through a real Explosion so the blast hits other breakables through the same
-- Hit handler as everything else, which is what makes barrels chain into each other.
-- joints stay intact so a barrel flings players instead of insta killing them
local function createExplosion(position, radius)
	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = radius
	explosion.DestroyJointRadiusPercent = 0
	explosion.Parent = workspace
end


local Breakable = {}
Breakable.__index = Breakable

local breakablesByPart = {}

-- a part only counts as held up if something anchored is right under it. unanchored stuff doesnt
-- count because it might be falling itself. the probe is a bit narrower than the part so a neighbour
-- touching its side doesnt count as support
local function hasAnchoredSupport(part)
	local probeCFrame = part.CFrame * CFrame.new(0, -part.Size.Y / 2 - 0.25, 0)
	local probeSize = Vector3.new(part.Size.X * 0.9, 0.5, part.Size.Z * 0.9)
	for _, other in ipairs(workspace:GetPartBoundsInBox(probeCFrame, probeSize, ignoreDebrisParams)) do
		if other ~= part and other.Anchored then
			return true
		end
	end
	return false
end

-- anchored builds never fall by themselves, so after something breaks we check what was sitting on it
-- and drop it. without this you could take out the bottom of a tower and the top would float
local function collapseUnsupportedAbove(cframe, size)
	local searchCFrame = cframe * CFrame.new(0, size.Y / 2 + 1, 0)
	local searchSize = size + Vector3.new(1, 2, 1)
	for _, part in ipairs(workspace:GetPartBoundsInBox(searchCFrame, searchSize, ignoreDebrisParams)) do
		local breakable = breakablesByPart[part]
		if not breakable or not part.Anchored then continue end
		if hasAnchoredSupport(part) then continue end

		breakable:drop()
	end
end

-- the chunks sit exactly inside the original. thats only ok because physics wont step until this
-- thread yields, so the original has to be gone before anything here waits
local function replaceWithChunks(part, hitPosition, launchForce)
	local boxes = fracture(part.CFrame, part.Size, hitPosition, getChunkCount(part.Size))
	local chunks = {}
	for _, box in ipairs(boxes) do
		table.insert(chunks, createChunk(part, box))
	end
	part:Destroy()

	for _, chunk in ipairs(chunks) do
		launchChunk(chunk, hitPosition, launchForce)
		debrisPool:add(chunk)
	end
end

local function getMaxHealth(part)
	return part:GetAttribute("Health") or settings.materialHealth[part.Material] or settings.defaultHealth
end

-- heavier stuff hits harder. clamped so a giant car doesnt one shot everything and a small ball
-- still does something
local function getImpactDamage(impactSpeed, hitMass)
	local massMultiplier = math.clamp(hitMass / 10, 0.25, 4)
	return (impactSpeed - settings.minImpactSpeed) * settings.damagePerSpeed * massMultiplier
end

-- respawning on top of someone would trap them inside it, so anything with a Humanoid blocks it
local function isCharacterInside(cframe, size)
	for _, part in ipairs(workspace:GetPartBoundsInBox(cframe, size, ignoreDebrisParams)) do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			return true
		end
	end
	return false
end

-- respawned parts pass in the template they came from. recloning the live part would grab its
-- mid fade transparency and the next respawn would come back invisible
function Breakable.new(part, template)
	local self = setmetatable({}, Breakable)
	self.part = part
	self.originalParent = part.Parent
	self.template = template or part:Clone()
	self.maxHealth = getMaxHealth(part)
	self.health = self.maxHealth
	-- saved before any damage tint so darkening always works from the real color, not a darkened one
	self.originalColor = part.Color
	self.isBroken = false
	self.touchConnection = part.Touched:Connect(function(otherPart)
		self:onTouched(otherPart)
	end)

	-- exposed as an attribute so other scripts (health bars, UI) can read it without requiring this one
	part:SetAttribute("CurrentHealth", self.health)
	breakablesByPart[part] = self
	return self
end

function Breakable:onTouched(otherPart)
	-- ignore our own debris, otherwise shards keep hitting the wall they came out of and it chain
	-- reacts until the whole build is gone
	if otherPart:GetAttribute("IsDebris") then return end

	-- relative velocity, so a fast part hitting a still wall counts the same as the other way round
	local impactSpeed = (otherPart.AssemblyLinearVelocity - self.part.AssemblyLinearVelocity).Magnitude
	if impactSpeed < settings.minImpactSpeed then return end

	local damage = getImpactDamage(impactSpeed, otherPart.AssemblyMass)
	-- the other part's center can be well outside us, so snap it onto our surface to get roughly
	-- where the contact actually happened
	local hitPosition = closestPointOnPart(self.part.CFrame, self.part.Size, otherPart.Position)
	local launchForce = settings.launchForce + impactSpeed * settings.launchForcePerImpactSpeed
	self:damage(damage, hitPosition, launchForce)
end

function Breakable:damage(amount, hitPosition, launchForce)
	if self.isBroken or amount <= 0 then return end
	if settings.instantBreak then
		amount = self.health
	end

	self.health -= amount
	if self.health <= 0 then
		self:shatter(hitPosition, launchForce)
		return
	end
	self:showDamage(hitPosition)
end

-- gets darker as it takes damage so players can tell how close it is to breaking without needing a
-- health bar. capped at 60% toward black so a nearly broken part still shows what material it is
function Breakable:showDamage(hitPosition)
	self.part:SetAttribute("CurrentHealth", self.health)

	local damageTaken = 1 - self.health / self.maxHealth
	local darkenedColor = self.originalColor:Lerp(Color3.new(0, 0, 0), damageTaken * 0.6)
	TweenService:Create(self.part, TweenInfo.new(0.15), {Color = darkenedColor}):Play()
	emitDust(hitPosition, self.originalColor)
end

function Breakable:shatter(hitPosition, launchForce)
	if self.isBroken then return end
	self.isBroken = true
	self:disconnect()

	-- read everything off the part now, replaceWithChunks destroys it
	local part = self.part
	local cframe, size = part.CFrame, part.Size
	-- a missing Respawn attribute (nil) still respawns, only an explicit false turns it off
	local canRespawn = part:GetAttribute("Respawn") ~= false and self.template ~= nil
	local blastRadius = part:GetAttribute("Explosive")
		and (part:GetAttribute("BlastRadius") or settings.defaultBlastRadius)

	replaceWithChunks(part, hitPosition, launchForce)
	emitDust(hitPosition, self.originalColor)

	if blastRadius then
		createExplosion(cframe.Position, blastRadius)
	end
	collapseUnsupportedAbove(cframe, size)

	if canRespawn then
		task.delay(settings.respawnDelay, function()
			self:respawn()
		end)
	end
end

-- the dropped part stays a breakable so it smashes when it lands, and anything stacked on it gets
-- checked next, which is what turns one broken brick into a whole wall coming down
function Breakable:drop()
	local part = self.part
	part.Anchored = false
	part:SetNetworkOwner(nil)
	collapseUnsupportedAbove(part.CFrame, part.Size)
end

function Breakable:respawn()
	-- the container might have been deleted while we waited, then there is nowhere to put it back
	if not self.originalParent or not self.originalParent:IsDescendantOf(game) then return end

	local template = self.template
	if isCharacterInside(template.CFrame, template.Size) then
		task.delay(settings.respawnRetryDelay, function()
			self:respawn()
		end)
		return
	end

	local part = template:Clone()
	part.Transparency = 1
	part.Parent = self.originalParent
	-- the clone still has the tag, so the tag signal will fire for it too. registering here first
	-- means onTagged sees it already exists and skips it, so we get to hand over the clean template
	Breakable.new(part, template)
	TweenService:Create(part, TweenInfo.new(settings.respawnFadeTime), {Transparency = template.Transparency}):Play()
end

function Breakable:disconnect()
	if self.touchConnection then
		self.touchConnection:Disconnect()
		self.touchConnection = nil
	end
	breakablesByPart[self.part] = nil
end

local function onDestructibleTagged(instance)
	if not instance:IsA("BasePart") then return end
	if breakablesByPart[instance] then return end
	Breakable.new(instance)
end

local function onDestructibleUntagged(instance)
	local breakable = breakablesByPart[instance]
	if not breakable then return end
	breakable:disconnect()
end



-- lower score = better target. distance is measured to the surface, not the center, or big walls
-- would always lose to small parts. facing is 1 straight ahead and -1 behind (height ignored so a wall
-- above or below you still counts as in front), which turns into a 1x to 2.2x distance multiplier,
-- so something behind you has to be less than half as far away to win
local function scoreToolTarget(part, rootPart)
	local hitPosition = closestPointOnPart(part.CFrame, part.Size, rootPart.Position)
	local offset = hitPosition - rootPart.Position
	local flatOffset = Vector3.new(offset.X, 0, offset.Z)
	-- standing right on top of the point gives no horizontal direction, so treat it as in front
	local facing = if flatOffset.Magnitude > 0.001 then rootPart.CFrame.LookVector:Dot(flatOffset.Unit) else 1
	local score = offset.Magnitude * (1.6 - facing * 0.6)
	return hitPosition, score
end

-- the server picks the target from the character instead of trusting where the client says it hit,
-- so exploiters cant break walls across the map. the server cant see the camera though, and in third
-- person your character often isnt facing what you clicked, so we search all around you and just
-- prefer stuff in front instead of only looking straight ahead
local function findToolTarget(character, rootPart)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character, debrisFolder}

	local bestPart, bestHitPosition, bestScore = nil, nil, math.huge
	for _, part in ipairs(workspace:GetPartBoundsInRadius(rootPart.Position, settings.toolRange, params)) do
		if not breakablesByPart[part] then continue end

		local hitPosition, score = scoreToolTarget(part, rootPart)
		if score < bestScore then
			bestPart, bestHitPosition, bestScore = part, hitPosition, score
		end
	end
	return bestPart, bestHitPosition
end

local function swingTool(character)
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local target, hitPosition = findToolTarget(character, rootPart)
	if not target then return end

	breakablesByPart[target]:damage(settings.toolDamage, hitPosition, settings.toolLaunchForce)
end

-- tweening Grip swings the tool on everyone's screen without needing an animation asset or a client
-- script. the tween reverses so it always ends back at the grip it started with
local function playSwingVisual(tool, restGrip)
	local swungGrip = restGrip * CFrame.Angles(math.rad(-80), 0, 0)
	local tweenInfo = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
	TweenService:Create(tool, tweenInfo, {Grip = swungGrip}):Play()
end

local function onToolTagged(tool)
	if not tool:IsA("Tool") then return end

	-- saved once up front, reading Grip at swing time could catch it mid tween
	local restGrip = tool.Grip
	tool.Activated:Connect(function()
		-- a tool sitting in a backpack or on the ground has no player character as its parent
		if not Players:GetPlayerFromCharacter(tool.Parent) then return end
		playSwingVisual(tool, restGrip)
		swingTool(tool.Parent)
	end)
end



-- Explosion.Hit already gives every part in range plus its distance, so we get falloff for free
-- instead of doing our own overlap check
local function onExplosionAdded(explosion)
	if explosion.BlastRadius <= 0 then return end

	explosion.Hit:Connect(function(part, distance)
		local breakable = breakablesByPart[part]
		if not breakable then return end

		local falloff = 1 - math.clamp(distance / explosion.BlastRadius, 0, 1)
		breakable:damage(
			settings.explosionDamage * falloff,
			explosion.Position,
			settings.launchForce * settings.explosionLaunchMultiplier
		)
	end)
end



-- groups have to exist before any character or chunk gets assigned to one
setupCollisionGroups()

-- handle whatever already exists, then listen for anything added later. both are needed because
-- the script can start after players have joined and after tagged parts have loaded
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
Players.PlayerAdded:Connect(onPlayerAdded)

for _, instance in ipairs(CollectionService:GetTagged(settings.destructibleTag)) do
	onDestructibleTagged(instance)
end
CollectionService:GetInstanceAddedSignal(settings.destructibleTag):Connect(onDestructibleTagged)
CollectionService:GetInstanceRemovedSignal(settings.destructibleTag):Connect(onDestructibleUntagged)

for _, tool in ipairs(CollectionService:GetTagged(settings.toolTag)) do
	onToolTagged(tool)
end
CollectionService:GetInstanceAddedSignal(settings.toolTag):Connect(onToolTagged)

workspace.DescendantAdded:Connect(function(instance)
	if not instance:IsA("Explosion") then return end
	onExplosionAdded(instance)
end)
