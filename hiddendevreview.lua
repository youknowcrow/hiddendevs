-- Github: @YouKnowCrow 
-- Discord: 1i5c (1187402552283775076)

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")

local settings = {
	-- i go off CollectionService tags instead of breaking everything, so i can choose which parts can

	tag = "Destructible",
	toolTag = "DestructionTool",

	health = 1, -- make stuff harder to break can be changed but i did wtv 

	materialHealth = {
		[Enum.Material.Glass] = 15,
		[Enum.Material.Wood] = 60,
		[Enum.Material.WoodPlanks] = 60,
		[Enum.Material.Brick] = 120,
		[Enum.Material.Concrete] = 200,
		[Enum.Material.Slate] = 250,
	},
	minChunk = 1,
	minChunks = 4,
	maxChunks = 28,
	chunksPerStud = 1.6,
	focus = 0.5,

	minImpactSpeed = 30,
	damagePerSpeed = 2,

	push = 45,
	pushFalloff = 0.3,
	lift = 0.35,
	spin = 6,

	debrisTime = 10,
	fadeTime = 1.5,
	maxDebris = 250,

	respawnTime = 15,
	respawnRetry = 2,
	respawnFade = 0.6,

	toolRange = 10,
	toolDamage = 40,
	toolPush = 70,

	boomDamage = 300,
	boomPush = 2,
	barrelRadius = 14,

	dust = 18,


	instantBreak = true,
}

local rng = Random.new()

local debrisFolder = workspace:FindFirstChild("DestructionDebris") or Instance.new("Folder")
debrisFolder.Name = "DestructionDebris"
debrisFolder.Parent = workspace

-- debris leaves with a big impulse, if it could hit characters it would fling players across the map.
local function setupGroups()
	for _, group in pairs({"DestructionDebris","DestructionCharacters"}) do
		if not PhysicsService:IsCollisionGroupRegistered(group) then
			PhysicsService:RegisterCollisionGroup(group)
		end
	end
	PhysicsService:CollisionGroupSetCollidable("DestructionDebris","DestructionCharacters",false)
end

local function setCharGroup(obj)
	if obj:IsA("BasePart") then
		obj.CollisionGroup = "DestructionCharacters"
	end
end

local function onCharacter(char)
	for _, v in pairs(char:GetDescendants()) do
		setCharGroup(v)
	end
	
	char.DescendantAdded:Connect(setCharGroup)
end


local function closestPoint(cf,size,point)
	local rel = cf:PointToObjectSpace(point)
	local half = size / 2
	local clamped = Vector3.new(
		math.clamp(rel.X,-half.X,half.X),
		math.clamp(rel.Y,-half.Y,half.Y),
		math.clamp(rel.Z,-half.Z,half.Z)
	)
	return cf:PointToWorldSpace(clamped)
end

local function longestAxis(size)
	if size.X >= size.Y and size.X >= size.Z then
		return Enum.Axis.X, size.X
	elseif size.Y >= size.Z then
		return Enum.Axis.Y, size.Y
	end
	return Enum.Axis.Z, size.Z
end

-- cutting at a random ratio instead of the middle is what stops it looking like a grid of perfect cubes.
-- offsets go through the box's own cframe so rotated parts split along their real faces not world axes
local function splitBox(box)
	local axis, length = longestAxis(box.Size)
	local dir = Vector3.FromAxis(axis)
	local a = length * rng:NextNumber(0.35,0.65)
	local b = length - a

	local first = {
		CFrame = box.CFrame * CFrame.new(-dir * (length - a) / 2),
		Size = box.Size - dir * b,
	}
	local second = {
		CFrame = box.CFrame * CFrame.new(dir * (length - b) / 2),
		Size = box.Size - dir * a,
	}
	return first, second
end


local function pickBox(boxes,hitPos)
	local best, bestScore = nil, 0
	for i, box in pairs(boxes) do
		local _, length = longestAxis(box.Size)
		if length >= settings.minChunk * 2 then
			local volume = box.Size.X * box.Size.Y * box.Size.Z
			local dist = (box.CFrame.Position - hitPos).Magnitude
			local score = volume / (1 + dist * settings.focus)
			if score > bestScore then
				best, bestScore = i, score
			end
		end
	end
	return best
end

local function fracture(cf,size,hitPos,count)
	local boxes = {{CFrame = cf, Size = size}}
	while #boxes < count do
		local i = pickBox(boxes,hitPos)
		if not i then break end
		local a, b = splitBox(table.remove(boxes,i))
		table.insert(boxes,a)
		table.insert(boxes,b)
	end
	return boxes
end

-- cube root of volume so a pillar and a wall with the same bulk break into about the same amount,
-- otherwise huge walls would spawn hundreds of parts and lag the server for everyone and stuff so yheaa
local function chunkCount(size)
	local volume = size.X * size.Y * size.Z
	local count = math.floor(volume ^ (1/3) * settings.chunksPerStud)
	return math.clamp(count,settings.minChunks,settings.maxChunks)
end

-- fading looks cool
local function fadeOut(part,time)
	local tween = TweenService:Create(part,TweenInfo.new(time),{Transparency = 1})
	tween.Completed:Once(function()
		part:Destroy()
	end)
	tween:Play()
end

local Pool = {}
Pool.__index = Pool

function Pool.new(max)
	local self = setmetatable({}, Pool)
	self.max = max
	self.count = 0
	self.alive = {}
	self.queue = {}
	self.head = 1
	self.tail = 0
	return self
end

-- Destroying fires deferred with the default SignalBehavior, so the count also gets lowered straight
-- away in trim(). the alive table makes sure a part only gets subtracted once
function Pool:forget(part)
	if self.alive[part] then
		self.alive[part] = nil
		self.count -= 1
	end
end

function Pool:add(part)
	self.tail += 1
	self.queue[self.tail] = part
	self.alive[part] = true
	self.count += 1
	part.Destroying:Once(function()
		self:forget(part)
	end)

	-- Debris is the backup, if the fade tween gets interrupted or the server hitches the part still
	-- gets removed instead of sitting there forever
	Debris:AddItem(part,settings.debrisTime + settings.fadeTime + 1)
	task.delay(settings.debrisTime,function()
		if part.Parent then
			fadeOut(part,settings.fadeTime)
		end
	end)

	self:dropDead()
	self:trim()
end

-- every chunk has the same lifetime so they die in roughly the order they were added.
-- popping the dead ones off the front keeps the queue from growing for the whole server
function Pool:dropDead()
	while self.head <= self.tail and self.queue[self.head].Parent == nil do
		self.queue[self.head] = nil
		self.head += 1
	end
end

-- chain reactions can make debris faster than it expires. removing the oldest first keeps physics
-- cheap and the newest rubble (the stuff players are looking at) stays
function Pool:trim()
	while self.count > self.max and self.head <= self.tail do
		local oldest = self.queue[self.head]
		self.queue[self.head] = nil
		self.head += 1
		self:forget(oldest)
		oldest:Destroy()
	end
end

local pool = Pool.new(settings.maxDebris)

-- only copy how it looks. cloning the original would copy the tag + attributes too and every chunk
-- would turn into a new destructible and keep breaking forever
local function makeChunk(source,box)
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
	chunk.CollisionGroup = "DestructionDebris"
	chunk:SetAttribute("IsDebris",true)
	chunk.Parent = debrisFolder
	-- server keeps ownership because impulses from the server get ignored on parts a client owns,
	-- and the debris dies too fast for handing it off to save anything
	chunk:SetNetworkOwner(nil)
	return chunk
end

-- times the chunk's mass so big and small pieces fly at about the same speed.
-- without it tiny shards go into orbit and the big slabs barely move
local function launch(chunk,hitPos,force)
	local offset = chunk.Position - hitPos
	local dist = offset.Magnitude
	local dir = if dist > 0.001 then offset.Unit else rng:NextUnitVector()
	dir = (dir + Vector3.yAxis * settings.lift).Unit

	local speed = force / (1 + dist * settings.pushFalloff)
	chunk:ApplyImpulse(dir * speed * chunk.AssemblyMass)
	chunk:ApplyAngularImpulse(rng:NextUnitVector() * settings.spin * chunk.AssemblyMass)
end

-- a quick dust puff sells the hit way more than chunks alone. Debris cleans the attachment up after
-- the particles are gone so nothing is left behind
local function dust(pos,color)
	local att = Instance.new("Attachment")
	att.Parent = workspace.Terrain
	att.WorldPosition = pos

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color:Lerp(Color3.new(1,1,1),0.4))
	emitter.Size = NumberSequence.new(1.5,4)
	emitter.Transparency = NumberSequence.new(0.3,1)
	emitter.Lifetime = NumberRange.new(0.6,1.2)
	emitter.Speed = NumberRange.new(6,14)
	emitter.SpreadAngle = Vector2.new(180,180)
	emitter.Drag = 4
	emitter.Enabled = false
	emitter.Parent = att
	emitter:Emit(settings.dust)

	Debris:AddItem(att,2)
end

local Breakable = {}
Breakable.__index = Breakable

local breakables = {}

local queryParams = OverlapParams.new()
queryParams.FilterType = Enum.RaycastFilterType.Exclude
queryParams.FilterDescendantsInstances = {debrisFolder}

-- explosive parts go through a real Explosion so the blast hits other breakables through the same
-- Hit handler as everything else, which is what makes barrels chain into each other.
-- joints stay intact so a barrel flings players instead of insta killing them
local function explode(pos,radius)
	local boom = Instance.new("Explosion")
	boom.Position = pos
	boom.BlastRadius = radius
	boom.DestroyJointRadiusPercent = 0
	boom.Parent = workspace
end

-- a part only counts as held up if something anchored is right under it. unanchored stuff
-- doesnt count because it might be falling itself
local function hasSupport(part)
	local probe = part.CFrame * CFrame.new(0,-part.Size.Y / 2 - 0.25,0)
	local area = Vector3.new(part.Size.X * 0.9,0.5,part.Size.Z * 0.9)
	for _, v in pairs(workspace:GetPartBoundsInBox(probe,area,queryParams)) do
		if v ~= part and v.Anchored then
			return true
		end
	end
	return false
end

-- anchored builds never fall by themselves, so after something breaks we check what was sitting
-- on it and drop it. without this you could take out the bottom of a tower and the top would float
local function collapseAbove(cf,size)
	local above = cf * CFrame.new(0,size.Y / 2 + 1,0)
	for _, v in pairs(workspace:GetPartBoundsInBox(above,size + Vector3.new(1,2,1),queryParams)) do
		local b = breakables[v]
		if b and v.Anchored and not hasSupport(v) then
			b:drop()
		end
	end
end

-- respawned parts pass in the template they came from. recloning the live part would grab its
-- mid fade transparency and the next respawn would come back invisible
function Breakable.new(part,template)
	local self = setmetatable({}, Breakable)
	self.part = part
	self.parent = part.Parent
	self.template = template or part:Clone()
	self.maxHealth = part:GetAttribute("Health") or settings.materialHealth[part.Material] or settings.health
	self.health = self.maxHealth
	self.color = part.Color
	self.broken = false
	self.touch = part.Touched:Connect(function(hit)
		self:onTouched(hit)
	end)
	part:SetAttribute("CurrentHealth",self.health)
	breakables[part] = self
	return self
end

function Breakable:onTouched(hit)
	-- ignore our own debris, otherwise shards keep hitting the wall they came out of and it
	-- chain reacts until the whole build is gone
	if hit:GetAttribute("IsDebris") then return end

	local speed = (hit.AssemblyLinearVelocity - self.part.AssemblyLinearVelocity).Magnitude
	if speed < settings.minImpactSpeed then return end

	-- heavier stuff hits harder. clamped so a giant car doesnt one shot everything and a small
	-- ball still does something
	local weight = math.clamp(hit.AssemblyMass / 10,0.25,4)
	local damage = (speed - settings.minImpactSpeed) * settings.damagePerSpeed * weight
	local pos = closestPoint(self.part.CFrame,self.part.Size,hit.Position)
	self:damage(damage,pos,settings.push + speed * 0.5)
end

function Breakable:damage(amount,pos,force)
	if self.broken or amount <= 0 then return end
	if settings.instantBreak then
		amount = self.health
	end
	self.health -= amount
	if self.health <= 0 then
		self:shatter(pos,force)
		return
	end

	self.part:SetAttribute("CurrentHealth",self.health)
	-- gets darker as it takes damage so players can tell how close it is to breaking without
	-- needing a health bar
	local ratio = 1 - self.health / self.maxHealth
	local goal = self.color:Lerp(Color3.new(0,0,0),ratio * 0.6)
	TweenService:Create(self.part,TweenInfo.new(0.15),{Color = goal}):Play()
	dust(pos,self.color)
end

function Breakable:shatter(pos,force)
	if self.broken then return end
	self.broken = true
	self:disconnect()

	local part = self.part
	local cf, size = part.CFrame, part.Size
	local respawns = part:GetAttribute("Respawn") ~= false and self.template ~= nil
	local blast = part:GetAttribute("Explosive") and (part:GetAttribute("BlastRadius") or settings.barrelRadius)
	local boxes = fracture(cf,size,pos,chunkCount(size))

	-- the chunks sit exactly inside the original. thats only ok because physics wont step until
	-- this thread yields, so the original has to be gone before anything here waits
	local chunks = {}
	for _, box in pairs(boxes) do
		table.insert(chunks,makeChunk(part,box))
	end
	part:Destroy()

	for _, chunk in pairs(chunks) do
		launch(chunk,pos,force)
		pool:add(chunk)
	end
	dust(pos,self.color)

	if blast then
		explode(cf.Position,blast)
	end
	collapseAbove(cf,size)

	if respawns then
		task.delay(settings.respawnTime,function()
			self:respawn()
		end)
	end
end

-- the dropped part stays a breakable so it smashes when it lands, and anything stacked on it gets
-- checked next which is what turns one broken brick into a whole wall coming down
function Breakable:drop()
	local part = self.part
	part.Anchored = false
	part:SetNetworkOwner(nil)
	collapseAbove(part.CFrame,part.Size)
end

-- respawning on top of someone would trap them inside it, so wait until nobody is standing there
function Breakable:respawn()
	if not self.parent or not self.parent:IsDescendantOf(game) then return end

	local template = self.template
	for _, v in pairs(workspace:GetPartBoundsInBox(template.CFrame,template.Size,queryParams)) do
		local model = v:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			task.delay(settings.respawnRetry,function()
				self:respawn()
			end)
			return
		end
	end

	local part = template:Clone()
	part.Transparency = 1
	part.Parent = self.parent
	-- register it here before the tag signal fires so we can hand over the clean template
	Breakable.new(part,template)
	TweenService:Create(part,TweenInfo.new(settings.respawnFade),{Transparency = template.Transparency}):Play()
end

function Breakable:disconnect()
	if self.touch then
		self.touch:Disconnect()
		self.touch = nil
	end
	breakables[self.part] = nil
end

local function onTagged(obj)
	if obj:IsA("BasePart") and not breakables[obj] then
		Breakable.new(obj)
	end
end

local function onUntagged(obj)
	if breakables[obj] then
		breakables[obj]:disconnect()
	end
end

-- the server picks the target from the character instead of trusting where the client says it hit,
-- so exploiters cant break walls across the map. the server cant see the camera though, and in third
-- person your character often isnt facing what you clicked, so we search all around you and just
-- prefer stuff in front instead of only looking straight ahead
local function findTarget(char,hrp)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {char,debrisFolder}

	local target, targetPos, best = nil, nil, math.huge
	for _, v in pairs(workspace:GetPartBoundsInRadius(hrp.Position,settings.toolRange,params)) do
		if breakables[v] then
			-- distance to the surface, not the center, or big walls would always lose to small parts
			local pos = closestPoint(v.CFrame,v.Size,hrp.Position)
			local offset = pos - hrp.Position
			local flat = Vector3.new(offset.X,0,offset.Z)
			local facing = if flat.Magnitude > 0.001 then hrp.CFrame.LookVector:Dot(flat.Unit) else 1
			local score = offset.Magnitude * (1.6 - facing * 0.6)
			if score < best then
				target, targetPos, best = v, pos, score
			end
		end
	end
	return target, targetPos
end

local function swing(char)
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local target, pos = findTarget(char,hrp)
	if not target then return end

	breakables[target]:damage(settings.toolDamage,pos,settings.toolPush)
end

-- tweening Grip swings the tool on everyone's screen without needing an animation asset or a
-- client script. reverses so it always ends back at the grip it started with
local function swingVisual(tool,rest)
	local hit = rest * CFrame.Angles(math.rad(-80),0,0)
	TweenService:Create(tool,TweenInfo.new(0.08,Enum.EasingStyle.Quad,Enum.EasingDirection.Out,0,true),{Grip = hit}):Play()
end

local function onTool(tool)
	if not tool:IsA("Tool") then return end
	local rest = tool.Grip
	tool.Activated:Connect(function()
		if game.Players:GetPlayerFromCharacter(tool.Parent) then
			swingVisual(tool,rest)
			swing(tool.Parent)
		end
	end)
end

-- Explosion.Hit already gives every part in range plus its distance, so we get falloff for free
-- instead of doing our own overlap check
local function onExplosion(boom)
	if boom.BlastRadius <= 0 then return end
	boom.Hit:Connect(function(part,dist)
		local b = breakables[part]
		if not b then return end
		local falloff = 1 - math.clamp(dist / boom.BlastRadius,0,1)
		b:damage(settings.boomDamage * falloff,boom.Position,settings.push * settings.boomPush)
	end)
end

setupGroups()

local function onPlayer(plr)
	if plr.Character then
		onCharacter(plr.Character)
	end
	plr.CharacterAdded:Connect(onCharacter)
end

for _, plr in pairs(game.Players:GetPlayers()) do
	onPlayer(plr)
end
game.Players.PlayerAdded:Connect(onPlayer)

for _, obj in pairs(CollectionService:GetTagged(settings.tag)) do
	onTagged(obj)
end
CollectionService:GetInstanceAddedSignal(settings.tag):Connect(onTagged)
CollectionService:GetInstanceRemovedSignal(settings.tag):Connect(onUntagged)

for _, tool in pairs(CollectionService:GetTagged(settings.toolTag)) do
	onTool(tool)
end
CollectionService:GetInstanceAddedSignal(settings.toolTag):Connect(onTool)

workspace.DescendantAdded:Connect(function(obj)
	if obj:IsA("Explosion") then
		onExplosion(obj)
	end
end)
