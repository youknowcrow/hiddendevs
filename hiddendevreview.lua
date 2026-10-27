-- Github: @YouKnowCrow 
-- Discord: 1i5c (1187402552283775076)
-- Roblox: YouKnowCro
local Debris = game:GetService("Debris") -- local stores the Debris service; GetService gets it from the game
local TweenService = game:GetService("TweenService") -- TweenService is the service used to create smooth property animations
local PhysicsService = game:GetService("PhysicsService") -- PhysicsService handles collision groups and their collision rules
local CollectionService = game:GetService("CollectionService") -- CollectionService handles tags added to Roblox instances

local settings = { -- local creates a settings table, and the braces hold all the options
	-- i go off CollectionService tags instead of breaking everything, so i can choose which parts can

	tag = "Destructible", -- tag is a string used to identify breakable parts with CollectionService
	toolTag = "DestructionTool", -- toolTag is the tag name used to find destruction tools

	health = 1, -- make stuff harder to break can be changed but i did wtv 

	materialHealth = { -- materialHealth is a table with material enums as its keys
		[Enum.Material.Glass] = 15, -- Enum.Material.Glass is the key, and 15 is the health assigned to glass
		[Enum.Material.Wood] = 60, -- Enum.Material.Wood is the key, and 60 is the health for wood
		[Enum.Material.WoodPlanks] = 60, -- WoodPlanks uses its own material enum but gets the same health as wood
		[Enum.Material.Brick] = 120, -- Enum.Material.Brick maps to 120 health
		[Enum.Material.Concrete] = 200, -- Enum.Material.Concrete maps to 200 health
		[Enum.Material.Slate] = 250, -- Enum.Material.Slate maps to 250 health
	},
	minChunk = 1, -- minChunk is the smallest length a chunk is allowed to split at
	minChunks = 4, -- minChunks sets the lower limit when calculating how many chunks to make
	maxChunks = 28, -- maxChunks sets the upper limit so the chunk count doesn't get too high
	chunksPerStud = 1.6, -- chunksPerStud is the multiplier used when figuring out the chunk count
	focus = 0.5, -- focus controls how much distance affects which box gets split next

	minImpactSpeed = 30, -- minImpactSpeed is the speed a hit has to reach before doing damage
	damagePerSpeed = 2, -- damagePerSpeed multiplies how much damage extra impact speed deals

	push = 45, -- push is the starting amount of force used when launching broken pieces
	pushFalloff = 0.3, -- pushFalloff makes that force weaker the farther a chunk is from the hit
	lift = 0.35, -- lift adds an upward Vector3 component to a chunk's launch direction
	spin = 6, -- spin controls the angular impulse used to rotate debris

	debrisTime = 10, -- debrisTime is the delay before a chunk starts fading out
	fadeTime = 1.5, -- fadeTime tells TweenInfo how long the fade animation lasts
	maxDebris = 250, -- maxDebris limits how many debris parts the pool can keep at once

	respawnTime = 15, -- respawnTime is how many seconds task.delay waits before restoring a part
	respawnRetry = 2, -- respawnRetry is the extra delay if the respawn area has a character in it
	respawnFade = 0.6, -- respawnFade controls how long the returning part takes to fade back in

	toolRange = 10, -- toolRange is the radius checked around a character for breakable parts
	toolDamage = 40, -- toolDamage is the damage value passed when a player uses a tool
	toolPush = 70, -- toolPush is the force value passed to the damage function for a tool hit

	boomDamage = 300, -- boomDamage is the base damage used when an Explosion hits a breakable
	boomPush = 2, -- boomPush multiplies how hard an explosion launches the debris
	barrelRadius = 14, -- barrelRadius is the fallback BlastRadius for explosive parts

	dust = 18, -- dust is the number of particles the ParticleEmitter emits at once


	instantBreak = true, -- true makes damage instantly use the part's remaining health
}

local rng = Random.new() -- Random.new creates an RNG object so the chunk cuts and spin can vary

local debrisFolder = workspace:FindFirstChild("DestructionDebris") or Instance.new("Folder") -- FindFirstChild checks for an existing folder; or makes a new Folder if nil
debrisFolder.Name = "DestructionDebris" -- Name is the string shown for this folder in the Explorer
debrisFolder.Parent = workspace -- Parent puts the folder directly under workspace

-- debris leaves with a big impulse, if it could hit characters it would fling players across the map.
local function setupGroups() -- local function declares setupGroups without making it global
	for _, group in pairs({"DestructionDebris","DestructionCharacters"}) do -- pairs loops the table; _ ignores the index, group stores each group name
		if not PhysicsService:IsCollisionGroupRegistered(group) then -- not checks whether IsCollisionGroupRegistered returned false
			PhysicsService:RegisterCollisionGroup(group) -- RegisterCollisionGroup creates the named collision group
		end
	end
	PhysicsService:CollisionGroupSetCollidable("DestructionDebris","DestructionCharacters",false) -- false tells PhysicsService these two collision groups should not collide
end

local function setCharGroup(obj) -- obj is the instance passed into this function
	if obj:IsA("BasePart") then -- IsA checks whether obj is a BasePart or one of its subclasses
		obj.CollisionGroup = "DestructionCharacters" -- CollisionGroup is the BasePart property being changed here
	end
end

local function onCharacter(char) -- char is the character Model passed into onCharacter
	for _, v in pairs(char:GetDescendants()) do -- GetDescendants returns all nested instances; v is each instance in the loop
		setCharGroup(v) -- passes the current descendant v to the setCharGroup function
	end
	
	char.DescendantAdded:Connect(setCharGroup) -- DescendantAdded is an event; Connect runs setCharGroup for new descendants
end


local function closestPoint(cf,size,point) -- cf is a CFrame, size is a Vector3, and point is the Vector3 being tested
	local rel = cf:PointToObjectSpace(point) -- PointToObjectSpace converts point from world coordinates into cf's local space
	local half = size / 2 -- Vector3 division makes half the part's X, Y, and Z dimensions
	local clamped = Vector3.new( -- Vector3.new builds a Vector3 from the three clamped coordinates below
		math.clamp(rel.X,-half.X,half.X), -- math.clamp keeps the local X value between the negative and positive half width
		math.clamp(rel.Y,-half.Y,half.Y), -- math.clamp keeps the local Y value between the bottom and top bounds
		math.clamp(rel.Z,-half.Z,half.Z) -- math.clamp keeps the local Z value between the front and back bounds
	)
	return cf:PointToWorldSpace(clamped) -- PointToWorldSpace converts the clamped local position back into world space
end

local function longestAxis(size) -- size is the Vector3 used to compare the lengths of the three axes
	if size.X >= size.Y and size.X >= size.Z then -- >= checks whether X is at least as long as both Y and Z
		return Enum.Axis.X, size.X -- Enum.Axis.X identifies X, while size.X returns its actual length
	elseif size.Y >= size.Z then -- elseif checks the Y case only if the X condition was false
		return Enum.Axis.Y, size.Y -- Enum.Axis.Y identifies Y, while size.Y is its length
	end
	return Enum.Axis.Z, size.Z -- the remaining case uses the Z axis and size.Z
end

-- cutting at a random ratio instead of the middle is what stops it looking like a grid of perfect cubes.
-- offsets go through the box's own cframe so rotated parts split along their real faces not world axes
local function splitBox(box) -- box is the table containing the original part's CFrame and Size
	local axis, length = longestAxis(box.Size) -- longestAxis returns two values, which go into axis and length
	local dir = Vector3.FromAxis(axis) -- Vector3.FromAxis turns the Enum.Axis value into an axis direction vector
	local a = length * rng:NextNumber(0.35,0.65) -- NextNumber chooses a random decimal from 0.35 to 0.65, then scales it
	local b = length - a -- subtracting a from length gives the other chunk's length

	local first = { -- first is a table holding the first chunk's CFrame and Size
		CFrame = box.CFrame * CFrame.new(-dir * (length - a) / 2), -- CFrame multiplication moves the first piece along the selected local axis
		Size = box.Size - dir * b, -- subtracting dir times b shortens the first chunk on the split axis
	}
	local second = { -- second is another table for the other side of the split
		CFrame = box.CFrame * CFrame.new(dir * (length - b) / 2), -- CFrame.new gives the second piece its offset along the same local axis
		Size = box.Size - dir * a, -- subtracting dir times a shortens the second chunk on that axis
	}
	return first, second -- return gives both tables back as two separate values
end


local function pickBox(boxes,hitPos) -- boxes is a table of chunks, and hitPos is the position the impact came from
	local best, bestScore = nil, 0 -- nil means no chosen index yet; 0 is the starting score
	for i, box in pairs(boxes) do -- pairs gives i as the table index and box as its current value
		local _, length = longestAxis(box.Size) -- _ ignores the axis result and length keeps the returned axis length
		if length >= settings.minChunk * 2 then -- only boxes at least twice minChunk on their longest axis can split
			local volume = box.Size.X * box.Size.Y * box.Size.Z -- multiplying X, Y, and Z calculates the volume of the box
			local dist = (box.CFrame.Position - hitPos).Magnitude -- subtracting Vector3 positions and using Magnitude calculates distance
			local score = volume / (1 + dist * settings.focus) -- volume divided by this distance factor creates the box's priority score
			if score > bestScore then -- > compares this box's score with the highest score so far
				best, bestScore = i, score -- the comma assignment updates best index and bestScore together
			end
		end
	end
	return best -- return gives back the best matching index or nil if none qualified
end

local function fracture(cf,size,hitPos,count) -- count is the target amount of boxes and hitPos influences which gets cut
	local boxes = {{CFrame = cf, Size = size}} -- the double braces make a list containing one table with CFrame and Size
	while #boxes < count do -- #boxes is the length operator; while repeats until it reaches count
		local i = pickBox(boxes,hitPos) -- pickBox returns the index of the box chosen for the next split
		if not i then break end -- not checks for nil and break ends the while loop immediately
		local a, b = splitBox(table.remove(boxes,i)) -- table.remove takes out that box; splitBox returns the two replacement boxes
		table.insert(boxes,a) -- table.insert adds the first new box to the list
		table.insert(boxes,b) -- table.insert adds the second new box to the same list
	end
	return boxes -- return passes the completed boxes list back to the caller
end

-- cube root of volume so a pillar and a wall with the same bulk break into about the same amount,
-- otherwise huge walls would spawn hundreds of parts and lag the server for everyone and stuff so yheaa
local function chunkCount(size) -- size is the Vector3 used to work out how many pieces to make
	local volume = size.X * size.Y * size.Z -- X times Y times Z gives the total part volume
	local count = math.floor(volume ^ (1/3) * settings.chunksPerStud) -- ^ raises volume to one third; math.floor rounds the multiplied result down
	return math.clamp(count,settings.minChunks,settings.maxChunks) -- math.clamp keeps count between settings.minChunks and settings.maxChunks
end

-- fading looks cool
local function fadeOut(part,time) -- part is the BasePart to fade, and time is the animation duration
	local tween = TweenService:Create(part,TweenInfo.new(time),{Transparency = 1}) -- TweenInfo.new configures duration; Create targets Transparency = 1
	tween.Completed:Once(function() -- Completed is the tween event; Once connects a callback only once
		part:Destroy() -- Destroy removes the part instance after the animation completes
	end)
	tween:Play() -- Play starts the tween that was created above
end

local Pool = {} -- Pool starts as an empty table used as a class
Pool.__index = Pool -- __index points missing instance fields back to methods stored on Pool

function Pool.new(max) -- the dot defines a constructor receiving the max debris count
	local self = setmetatable({}, Pool) -- setmetatable connects a new instance table to the Pool class table
	self.max = max -- self.max stores the maximum number of parts this pool allows
	self.count = 0 -- self.count starts the current active debris count at zero
	self.alive = {} -- alive is a table used to track which instances are counted
	self.queue = {} -- queue is a table holding pieces in the order they were added
	self.head = 1 -- head marks the front of that queue
	self.tail = 0 -- tail marks the back of that queue
	return self -- return gives the new Pool instance to whatever called Pool.new
end

-- Destroying fires deferred with the default SignalBehavior, so the count also gets lowered straight
-- away in trim(). the alive table makes sure a part only gets subtracted once
function Pool:forget(part) -- the colon passes self automatically, while part is the item being removed
	if self.alive[part] then -- alive[part] checks the table entry keyed by this exact part instance
		self.alive[part] = nil -- nil clears that entry so the same part cannot be counted twice
		self.count -= 1 -- -= is the Luau subtraction assignment operator; this lowers the count by one
	end
end

function Pool:add(part) -- part is the piece being added; self refers to this Pool instance
	self.tail += 1 -- += adds one to the tail index before storing the new item
	self.queue[self.tail] = part -- square brackets use self.tail as the index in the queue table
	self.alive[part] = true -- true marks this part as currently tracked in alive
	self.count += 1 -- the += operator adds one to the active part count
	part.Destroying:Once(function() -- Destroying is an event and Once only calls this callback one time
		self:forget(part) -- the colon call removes this exact part from the tracked count
	end)

	-- Debris is the backup, if the fade tween gets interrupted or the server hitches the part still
	-- gets removed instead of sitting there forever
	Debris:AddItem(part,settings.debrisTime + settings.fadeTime + 1) -- AddItem schedules Roblox Debris cleanup after both delays plus one extra second
	task.delay(settings.debrisTime,function() -- task.delay waits debrisTime seconds and then runs this function
		if part.Parent then -- Parent being non-nil checks that the part still exists in the DataModel
			fadeOut(part,settings.fadeTime) -- passes this part and fadeTime into the fadeOut helper
		end
	end)

	self:dropDead() -- colon calls dropDead with this pool as self
	self:trim() -- colon calls trim with this pool as self
end

-- every chunk has the same lifetime so they die in roughly the order they were added.
-- popping the dead ones off the front keeps the queue from growing for the whole server
function Pool:dropDead() -- the colon method uses the queue indices stored on self
	while self.head <= self.tail and self.queue[self.head].Parent == nil do -- <= checks for queue items, and Parent == nil detects an already removed part
		self.queue[self.head] = nil -- setting this queue slot to nil clears the dead entry
		self.head += 1 -- += moves head forward to the next queued part
	end
end

-- chain reactions can make debris faster than it expires. removing the oldest first keeps physics
-- cheap and the newest rubble (the stuff players are looking at) stays
function Pool:trim() -- trim uses self.max as the active debris limit
	while self.count > self.max and self.head <= self.tail do -- > compares the count to max while <= confirms the queue still has entries
		local oldest = self.queue[self.head] -- the local variable oldest gets the Part at the head of queue
		self.queue[self.head] = nil -- nil deletes the oldest entry from the queue table
		self.head += 1 -- incrementing head moves the queue front forward
		self:forget(oldest) -- forget updates the alive table and active count for this part
		oldest:Destroy() -- Destroy deletes the old debris instance from the game
	end
end

local pool = Pool.new(settings.maxDebris) -- Pool.new returns a new pool with maxDebris as its maximum size

-- only copy how it looks. cloning the original would copy the tag + attributes too and every chunk
-- would turn into a new destructible and keep breaking forever
local function makeChunk(source,box) -- source is the original part and box holds the CFrame and Size to copy
	local chunk = Instance.new("Part") -- Instance.new creates a fresh Part instead of cloning the source
	chunk.Size = box.Size -- Size is copied from the box table's Size Vector3
	chunk.CFrame = box.CFrame -- CFrame is copied from the box table so the piece keeps its exact position
	chunk.Color = source.Color -- Color copies the source part's Color3
	chunk.Material = source.Material -- Material copies the source's Enum.Material value
	chunk.MaterialVariant = source.MaterialVariant -- MaterialVariant copies the source part's material variant string
	chunk.Reflectance = source.Reflectance -- Reflectance copies the source part's reflectance property
	chunk.Transparency = source.Transparency -- Transparency copies the source part's transparency value
	chunk.TopSurface = Enum.SurfaceType.Smooth -- Enum.SurfaceType.Smooth sets a smooth top surface
	chunk.BottomSurface = Enum.SurfaceType.Smooth -- Enum.SurfaceType.Smooth also sets a smooth bottom surface
	chunk.CollisionGroup = "DestructionDebris" -- assigns the chunk to the debris collision group created earlier
	chunk:SetAttribute("IsDebris",true) -- SetAttribute stores a boolean named IsDebris on this Part
	chunk.Parent = debrisFolder -- Parent moves the new chunk into the workspace debris folder
	-- server keeps ownership because impulses from the server get ignored on parts a client owns,
	-- and the debris dies too fast for handing it off to save anything
	chunk:SetNetworkOwner(nil) -- SetNetworkOwner(nil) assigns physics ownership to the server
	return chunk -- return passes the newly created Part back to the caller
end

-- times the chunk's mass so big and small pieces fly at about the same speed.
-- without it tiny shards go into orbit and the big slabs barely move
local function launch(chunk,hitPos,force) -- chunk is the Part, hitPos is the impact Vector3, and force is the push amount
	local offset = chunk.Position - hitPos -- subtracting positions gives a Vector3 pointing away from the impact
	local dist = offset.Magnitude -- Magnitude returns the distance represented by that Vector3
	local dir = if dist > 0.001 then offset.Unit else rng:NextUnitVector() -- Luau if expression chooses Unit for normal offsets or random direction at zero
	dir = (dir + Vector3.yAxis * settings.lift).Unit -- Vector3.yAxis adds upward lift and Unit normalizes the new direction

	local speed = force / (1 + dist * settings.pushFalloff) -- this division weakens the force using distance and pushFalloff
	chunk:ApplyImpulse(dir * speed * chunk.AssemblyMass) -- ApplyImpulse takes a Vector3 impulse; AssemblyMass scales it by mass
	chunk:ApplyAngularImpulse(rng:NextUnitVector() * settings.spin * chunk.AssemblyMass) -- ApplyAngularImpulse rotates the chunk with a random axis and spin strength
end

-- a quick dust puff sells the hit way more than chunks alone. Debris cleans the attachment up after
-- the particles are gone so nothing is left behind
local function dust(pos,color) -- pos is the world position and color is the Color3 used for the effect
	local att = Instance.new("Attachment") -- Instance.new creates an Attachment to hold the particle emitter
	att.Parent = workspace.Terrain -- Terrain is used as the Parent for the Attachment
	att.WorldPosition = pos -- WorldPosition places the Attachment at the supplied world position

	local emitter = Instance.new("ParticleEmitter") -- Instance.new creates a ParticleEmitter object
	emitter.Color = ColorSequence.new(color:Lerp(Color3.new(1,1,1),0.4)) -- ColorSequence.new sets a color gradient from a Color3 mixed with white
	emitter.Size = NumberSequence.new(1.5,4) -- NumberSequence.new sets the particle size from 1.5 to 4 over its lifetime
	emitter.Transparency = NumberSequence.new(0.3,1) -- NumberSequence.new sets particle transparency from 0.3 to 1
	emitter.Lifetime = NumberRange.new(0.6,1.2) -- NumberRange.new makes particle lifetimes vary between 0.6 and 1.2 seconds
	emitter.Speed = NumberRange.new(6,14) -- NumberRange.new makes particle speeds vary from 6 to 14
	emitter.SpreadAngle = Vector2.new(180,180) -- Vector2.new gives the horizontal and vertical spread angles
	emitter.Drag = 4 -- Drag is the particle speed resistance property
	emitter.Enabled = false -- false stops this emitter from continuously emitting particles
	emitter.Parent = att -- Parent attaches the ParticleEmitter to the Attachment
	emitter:Emit(settings.dust) -- Emit sends out the number of particles stored in settings.dust

	Debris:AddItem(att,2) -- AddItem removes the temporary Attachment after two seconds
end

local Breakable = {} -- Breakable is an empty table used for the breakable object class
Breakable.__index = Breakable -- __index lets Breakable instances access methods from the class table

local breakables = {} -- breakables is a lookup table using Roblox Parts as keys

local queryParams = OverlapParams.new() -- OverlapParams.new builds settings for spatial overlap queries
queryParams.FilterType = Enum.RaycastFilterType.Exclude -- Exclude means items inside the filter list get ignored by the query
queryParams.FilterDescendantsInstances = {debrisFolder} -- FilterDescendantsInstances receives the list of instances to exclude

-- explosive parts go through a real Explosion so the blast hits other breakables through the same
-- Hit handler as everything else, which is what makes barrels chain into each other.
-- joints stay intact so a barrel flings players instead of insta killing them
local function explode(pos,radius) -- pos is the explosion center and radius is the blast size
	local boom = Instance.new("Explosion") -- Instance.new creates Roblox's built-in Explosion instance
	boom.Position = pos -- Position is the world Vector3 for the center of the explosion
	boom.BlastRadius = radius -- BlastRadius sets how far the Explosion can reach
	boom.DestroyJointRadiusPercent = 0 -- zero stops this Explosion from destroying joints directly
	boom.Parent = workspace -- parenting to workspace makes the Explosion activate in the world
end

-- a part only counts as held up if something anchored is right under it. unanchored stuff
-- doesnt count because it might be falling itself
local function hasSupport(part) -- part is the BasePart being checked for anchored support below it
	local probe = part.CFrame * CFrame.new(0,-part.Size.Y / 2 - 0.25,0) -- CFrame multiplication moves the probe just below the bottom face
	local area = Vector3.new(part.Size.X * 0.9,0.5,part.Size.Z * 0.9) -- Vector3.new creates the width, height, and depth of the probe box
	for _, v in pairs(workspace:GetPartBoundsInBox(probe,area,queryParams)) do -- GetPartBoundsInBox finds overlapping parts; v is each result
		if v ~= part and v.Anchored then -- ~= means not equal and Anchored checks whether the supporting part is fixed
			return true -- true tells the caller an anchored supporting part was found
		end
	end
	return false -- false means no matching anchored support was found
end

-- anchored builds never fall by themselves, so after something breaks we check what was sitting
-- on it and drop it. without this you could take out the bottom of a tower and the top would float
local function collapseAbove(cf,size) -- cf is the removed part's CFrame and size is its size Vector3
	local above = cf * CFrame.new(0,size.Y / 2 + 1,0) -- CFrame.new offsets the search location upward from the old part
	for _, v in pairs(workspace:GetPartBoundsInBox(above,size + Vector3.new(1,2,1),queryParams)) do -- GetPartBoundsInBox looks through nearby parts with queryParams filtering
		local b = breakables[v] -- breakables[v] looks up the Breakable object stored under part v
		if b and v.Anchored and not hasSupport(v) then -- and requires a registered breakable, an anchored part, and no support
			b:drop() -- colon calls drop on that Breakable instance
		end
	end
end

-- respawned parts pass in the template they came from. recloning the live part would grab its
-- mid fade transparency and the next respawn would come back invisible
function Breakable.new(part,template) -- dot declares a constructor with a Part and an optional saved template
	local self = setmetatable({}, Breakable) -- setmetatable makes self a new instance linked to Breakable methods
	self.part = part -- self.part stores the actual Roblox Part this object manages
	self.parent = part.Parent -- Parent saves where the original Part belongs in the hierarchy
	self.template = template or part:Clone() -- or uses the supplied template, otherwise Clone copies the current part
	self.maxHealth = part:GetAttribute("Health") or settings.materialHealth[part.Material] or settings.health -- GetAttribute checks Health, then materialHealth, then default health via or
	self.health = self.maxHealth -- self.health copies maxHealth as the current starting health
	self.color = part.Color -- self.color saves the original Color3 before the part gets darkened
	self.broken = false -- false marks the breakable as not already broken
	self.touch = part.Touched:Connect(function(hit) -- Touched is a BasePart event; Connect receives the touching hit Part
		self:onTouched(hit) -- colon passes the hit part to this object's onTouched method
	end)
	part:SetAttribute("CurrentHealth",self.health) -- SetAttribute stores CurrentHealth so other scripts can read it
	breakables[part] = self -- uses the Roblox Part itself as the key for this Breakable instance
	return self -- return gives the newly set up Breakable object back
end

function Breakable:onTouched(hit) -- colon defines an instance method; hit is the Part that touched this one
	-- ignore our own debris, otherwise shards keep hitting the wall they came out of and it
	-- chain reacts until the whole build is gone
	if hit:GetAttribute("IsDebris") then return end -- GetAttribute reads IsDebris and return skips the rest for tagged chunks

	local speed = (hit.AssemblyLinearVelocity - self.part.AssemblyLinearVelocity).Magnitude -- subtracting AssemblyLinearVelocity vectors gives relative collision speed
	if speed < settings.minImpactSpeed then return end -- the < check returns early when that speed is below the configured minimum

	-- heavier stuff hits harder. clamped so a giant car doesnt one shot everything and a small
	-- ball still does something
	local weight = math.clamp(hit.AssemblyMass / 10,0.25,4) -- AssemblyMass / 10 is clamped to a multiplier between 0.25 and 4
	local damage = (speed - settings.minImpactSpeed) * settings.damagePerSpeed * weight -- subtracting minimum speed then multiplying gives the calculated hit damage
	local pos = closestPoint(self.part.CFrame,self.part.Size,hit.Position) -- closestPoint finds a world point on this part nearest the hitting part
	self:damage(damage,pos,settings.push + speed * 0.5) -- damage gets the amount, hit position, and scaled push force as arguments
end

function Breakable:damage(amount,pos,force) -- amount is damage, pos is the hit location, and force is the impulse
	if self.broken or amount <= 0 then return end -- or checks either condition; return ignores already broken or invalid hits
	if settings.instantBreak then -- the boolean instantBreak setting decides whether to override the damage
		amount = self.health -- self.health becomes the amount so this hit uses all remaining health
	end
	self.health -= amount -- -= reduces current health by the amount passed into the method
	if self.health <= 0 then -- <= checks whether the remaining health is zero or lower
		self:shatter(pos,force) -- shatter gets the impact position and push force from damage
		return -- return exits early after shatter instead of running the damage visuals
	end

	self.part:SetAttribute("CurrentHealth",self.health) -- SetAttribute updates CurrentHealth with the latest value
	-- gets darker as it takes damage so players can tell how close it is to breaking without
	-- needing a health bar
	local ratio = 1 - self.health / self.maxHealth -- health divided by maxHealth makes a fraction; 1 minus it is damage taken
	local goal = self.color:Lerp(Color3.new(0,0,0),ratio * 0.6) -- Color3.new(0,0,0) is black; Lerp mixes toward it using the damage ratio
	TweenService:Create(self.part,TweenInfo.new(0.15),{Color = goal}):Play() -- TweenInfo.new(0.15) controls duration; Play starts the Color tween
	dust(pos,self.color) -- calls the dust helper with the hit position and saved original Color3
end

function Breakable:shatter(pos,force) -- colon defines the shatter method with a hit Vector3 and force number
	if self.broken then return end -- true in self.broken returns early to prevent shattering the same part twice
	self.broken = true -- setting broken to true marks this Breakable as already destroyed
	self:disconnect() -- disconnect clears the old touch event and removes its lookup entry

	local part = self.part -- local part is an alias for the stored Roblox Part instance
	local cf, size = part.CFrame, part.Size -- the comma assignment stores the part's CFrame and Vector3 Size
	local respawns = part:GetAttribute("Respawn") ~= false and self.template ~= nil -- ~= false allows respawn unless disabled, and ~= nil checks for a template
	local blast = part:GetAttribute("Explosive") and (part:GetAttribute("BlastRadius") or settings.barrelRadius) -- and checks Explosive; or uses barrelRadius when BlastRadius isn't set
	local boxes = fracture(cf,size,pos,chunkCount(size)) -- fracture gets the chunk count returned by chunkCount(size)

	-- the chunks sit exactly inside the original. thats only ok because physics wont step until
	-- this thread yields, so the original has to be gone before anything here waits
	local chunks = {} -- chunks is an empty list for the new Part instances
	for _, box in pairs(boxes) do -- pairs iterates the generated box tables; _ ignores the index
		table.insert(chunks,makeChunk(part,box)) -- makeChunk returns a Part; table.insert adds it to the chunks list
	end
	part:Destroy() -- Destroy removes the original Part after the replacements are created

	for _, chunk in pairs(chunks) do -- pairs iterates the new chunk Part instances
		launch(chunk,pos,force) -- launch applies force to this chunk from the original hit position
		pool:add(chunk) -- pool:add tracks this piece in the active debris pool
	end
	dust(pos,self.color) -- calls dust with the hit location and original part color

	if blast then -- if runs the explosion block only when blast isn't nil or false
		explode(cf.Position,blast) -- explode creates an Explosion at the original CFrame Position
	end
	collapseAbove(cf,size) -- collapseAbove checks parts supported by the removed part's old position

	if respawns then -- respawns is the boolean calculated from the part's Respawn attribute
		task.delay(settings.respawnTime,function() -- task.delay waits respawnTime seconds before running the callback
			self:respawn() -- colon calls this Breakable object's respawn method
		end)
	end
end

-- the dropped part stays a breakable so it smashes when it lands, and anything stacked on it gets
-- checked next which is what turns one broken brick into a whole wall coming down
function Breakable:drop() -- drop is a Breakable instance method, so self is supplied automatically
	local part = self.part -- local stores a short alias for self.part
	part.Anchored = false -- false removes the part's Anchored restriction so it can fall
	part:SetNetworkOwner(nil) -- nil gives the server network ownership of the falling part
	collapseAbove(part.CFrame,part.Size) -- calls collapseAbove with the falling part's CFrame and Size
end

-- respawning on top of someone would trap them inside it, so wait until nobody is standing there
function Breakable:respawn() -- respawn is the instance method that rebuilds the saved part
	if not self.parent or not self.parent:IsDescendantOf(game) then return end -- not checks missing Parent and IsDescendantOf checks hierarchy membership

	local template = self.template -- template is a local reference to the saved original part
	for _, v in pairs(workspace:GetPartBoundsInBox(template.CFrame,template.Size,queryParams)) do -- GetPartBoundsInBox checks what is occupying the original part's space
		local model = v:FindFirstAncestorOfClass("Model") -- FindFirstAncestorOfClass finds the nearest ancestor that is a Model
		if model and model:FindFirstChildOfClass("Humanoid") then -- FindFirstChildOfClass checks whether that Model contains a Humanoid
			task.delay(settings.respawnRetry,function() -- task.delay retries after respawnRetry seconds when a character is present
				self:respawn() -- calls the same respawn method again during that delayed retry
			end)
			return -- return stops this respawn attempt when the area is occupied
		end
	end

	local part = template:Clone() -- Clone makes a new Part from the saved template
	part.Transparency = 1 -- Transparency = 1 makes the cloned part fully invisible at first
	part.Parent = self.parent -- Parent restores the part to its original container
	-- register it here before the tag signal fires so we can hand over the clean template
	Breakable.new(part,template) -- Breakable.new registers the cloned Part with the saved template
	TweenService:Create(part,TweenInfo.new(settings.respawnFade),{Transparency = template.Transparency}):Play() -- Create animates Transparency back to the template value; Play starts it
end

function Breakable:disconnect() -- disconnect is a method that removes listeners and table references
	if self.touch then -- if checks whether a Touched connection is still stored
		self.touch:Disconnect() -- Disconnect stops the stored RBXScriptConnection from firing again
		self.touch = nil -- nil clears the stored reference to that old connection
	end
	breakables[self.part] = nil -- nil removes the old Part key from the breakables lookup table
end

local function onTagged(obj) -- obj is the instance passed by CollectionService's tag signal
	if obj:IsA("BasePart") and not breakables[obj] then -- IsA checks BasePart and not prevents duplicate registration
		Breakable.new(obj) -- the constructor makes a Breakable object for the tagged part
	end
end

local function onUntagged(obj) -- onUntagged receives the instance whose CollectionService tag was removed
	if breakables[obj] then -- checks the table for an existing Breakable object for obj
		breakables[obj]:disconnect() -- disconnect removes this object's touch connection and lookup
	end
end

-- the server picks the target from the character instead of trusting where the client says it hit,
-- so exploiters cant break walls across the map. the server cant see the camera though, and in third
-- person your character often isnt facing what you clicked, so we search all around you and just
-- prefer stuff in front instead of only looking straight ahead
local function findTarget(char,hrp) -- char is the character Model and hrp is its HumanoidRootPart
	local params = OverlapParams.new() -- OverlapParams.new creates a fresh filter for this search
	params.FilterType = Enum.RaycastFilterType.Exclude -- Exclude tells the overlap query to ignore objects in the filter list
	params.FilterDescendantsInstances = {char,debrisFolder} -- the list excludes the character Model and the debris folder

	local target, targetPos, best = nil, nil, math.huge -- nil starts without a target; math.huge is the starting best score
	for _, v in pairs(workspace:GetPartBoundsInRadius(hrp.Position,settings.toolRange,params)) do -- GetPartBoundsInRadius returns nearby parts; v loops each result
		if breakables[v] then -- breakables[v] is nil for any part not registered as breakable
			-- distance to the surface, not the center, or big walls would always lose to small parts
			local pos = closestPoint(v.CFrame,v.Size,hrp.Position) -- closestPoint finds the nearest point on this candidate's surface
			local offset = pos - hrp.Position -- subtracting Vector3 values creates an offset from the player to the part
			local flat = Vector3.new(offset.X,0,offset.Z) -- Vector3.new keeps X and Z but sets Y to zero to get horizontal direction
			local facing = if flat.Magnitude > 0.001 then hrp.CFrame.LookVector:Dot(flat.Unit) else 1 -- the if expression uses Dot for front-facing weight or 1 when too close
			local score = offset.Magnitude * (1.6 - facing * 0.6) -- Magnitude measures distance; the facing value changes the ranking weight
			if score < best then -- < selects a score smaller than the best one found so far
				target, targetPos, best = v, pos, score -- multiple assignment stores the chosen part, hit position, and score
			end
		end
	end
	return target, targetPos -- return gives both the selected Part and world-space hit position
end

local function swing(char) -- char is the character Model passed to this tool swing function
	local hrp = char and char:FindFirstChild("HumanoidRootPart") -- and checks char exists before FindFirstChild looks for HumanoidRootPart
	if not hrp then return end -- return cancels the swing if no HumanoidRootPart was found

	local target, pos = findTarget(char,hrp) -- findTarget returns target and pos as two separate local variables
	if not target then return end -- return cancels this swing if findTarget didn't locate a breakable

	breakables[target]:damage(settings.toolDamage,pos,settings.toolPush) -- looks up the target Breakable and calls damage using the tool settings
end

-- tweening Grip swings the tool on everyone's screen without needing an animation asset or a
-- client script. reverses so it always ends back at the grip it started with
local function swingVisual(tool,rest) -- tool is the Roblox Tool and rest is its original Grip CFrame
	local hit = rest * CFrame.Angles(math.rad(-80),0,0) -- CFrame.Angles creates an 80-degree rotation, converted with math.rad
	TweenService:Create(tool,TweenInfo.new(0.08,Enum.EasingStyle.Quad,Enum.EasingDirection.Out,0,true),{Grip = hit}):Play() -- Create tweens Grip; Quad is easing and the true option reverses it
end

local function onTool(tool) -- onTool receives a Roblox instance with the DestructionTool tag
	if not tool:IsA("Tool") then return end -- IsA tests for Tool and return skips non-tool instances
	local rest = tool.Grip -- Grip is a CFrame property; rest saves its original value
	tool.Activated:Connect(function() -- Activated is the tool event; Connect runs the callback when used
		if game.Players:GetPlayerFromCharacter(tool.Parent) then -- GetPlayerFromCharacter verifies the tool's parent is a player's character
			swingVisual(tool,rest) -- calls the tween helper with this Tool and its original grip
			swing(tool.Parent) -- passes the tool's parent character Model to swing
		end
	end)
end

-- Explosion.Hit already gives every part in range plus its distance, so we get falloff for free
-- instead of doing our own overlap check
local function onExplosion(boom) -- boom is the Explosion instance to attach a Hit listener to
	if boom.BlastRadius <= 0 then return end -- BlastRadius <= 0 filters out explosions with no effective radius
	boom.Hit:Connect(function(part,dist) -- Hit is the Explosion event; part and dist are the touched part and distance
		local b = breakables[part] -- looks up a Breakable object by the part hit by the explosion
		if not b then return end -- return skips this Hit callback when the part isn't registered
		local falloff = 1 - math.clamp(dist / boom.BlastRadius,0,1) -- math.clamp limits distance fraction to 0 through 1; 1 minus it is falloff
		b:damage(settings.boomDamage * falloff,boom.Position,settings.push * settings.boomPush) -- damage takes the scaled blast damage, explosion Position, and push force
	end)
end

setupGroups() -- calls setupGroups before tagging players and creating debris

local function onPlayer(plr) -- plr is the Roblox Player instance passed by the player events
	if plr.Character then -- Character is a Player property; if checks whether one already spawned
		onCharacter(plr.Character) -- passes the existing character Model to onCharacter
	end
	plr.CharacterAdded:Connect(onCharacter) -- CharacterAdded is an event; Connect applies onCharacter after each spawn
end

for _, plr in pairs(game.Players:GetPlayers()) do -- GetPlayers returns all current Players; _ ignores index and plr stores each
	onPlayer(plr) -- runs onPlayer for each player that was already in the game
end
game.Players.PlayerAdded:Connect(onPlayer) -- PlayerAdded is an event; Connect handles any player who joins later

for _, obj in pairs(CollectionService:GetTagged(settings.tag)) do -- GetTagged returns all instances with settings.tag; obj is each one
	onTagged(obj) -- registers this tagged instance using onTagged
end
CollectionService:GetInstanceAddedSignal(settings.tag):Connect(onTagged) -- GetInstanceAddedSignal connects onTagged when the tag is added later
CollectionService:GetInstanceRemovedSignal(settings.tag):Connect(onUntagged) -- GetInstanceRemovedSignal connects onUntagged when a tag is removed

for _, tool in pairs(CollectionService:GetTagged(settings.toolTag)) do -- GetTagged finds all tagged tools; tool is the current instance
	onTool(tool) -- registers this tool's Activated listener using onTool
end
CollectionService:GetInstanceAddedSignal(settings.toolTag):Connect(onTool) -- GetInstanceAddedSignal registers tools tagged after startup

workspace.DescendantAdded:Connect(function(obj) -- DescendantAdded fires for new workspace descendants; obj is the instance
	if obj:IsA("Explosion") then -- IsA checks whether the added instance is an Explosion
		onExplosion(obj) -- connects that Explosion instance to the onExplosion Hit handler
	end
end)
