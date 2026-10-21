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
