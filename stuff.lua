local Economy = {}

local PlayerData = require(game.ServerScriptService.PlayerData.Manager)
local config = require(game.ReplicatedStorage.ItemConfig)

Economy.Items = {}
for _, v in pairs(config) do
	Economy.Items[v.Name] = v
end

function Economy.Setup(plr,profile)
	local inv = profile.Data.ItemsInInventory
	if #inv > 0 then
		local fixed = {}
		for _, v in pairs(inv) do
			local n = typeof(v) == "table" and v.Name or v
			if typeof(n) == "string" then
				fixed[n] = (fixed[n] or 0) + 1
			end
		end
		profile.Data.ItemsInInventory = fixed
		inv = fixed
	end
	local folder = plr:FindFirstChild("Inventory") or Instance.new("Folder")
	folder.Name = "Inventory"
	folder:ClearAllChildren()
	for name, count in pairs(inv) do
		if Economy.Items[name] and count > 0 then
			local v = Instance.new("IntValue")
			v.Name = name
			v.Value = count
			v.Parent = folder
		end
	end
	folder.Parent = plr
end

local function sync(plr,name,count)
	local folder = plr:FindFirstChild("Inventory")
	if not folder then return end
	local v = folder:FindFirstChild(name)
	if count <= 0 then
		if v then v:Destroy() end
		return
	end
	if not v then
		v = Instance.new("IntValue")
		v.Name = name
		v.Parent = folder
	end
	v.Value = count
end

function Economy.Count(plr,name)
	local profile = PlayerData.Profiles[plr]
	return profile and profile.Data.ItemsInInventory[name] or 0
end

function Economy.Give(plr,name,n)
	local profile = PlayerData.Profiles[plr]
	if not profile then return false end
	local inv = profile.Data.ItemsInInventory
	inv[name] = (inv[name] or 0) + n
	if inv[name] <= 0 then inv[name] = nil end
	sync(plr,name,inv[name] or 0)
	return true
end

function Economy.Take(plr,name,n)
	if Economy.Count(plr,name) < n then return false end
	return Economy.Give(plr,name,-n)
end

function Economy.Money(plr,n)
	local profile = PlayerData.Profiles[plr]
	if not profile then return false end
	if n < 0 and profile.Data.Currency < -n then return false end
	profile.Data.Currency += n
	if plr:FindFirstChild("leaderstats") then
		plr.leaderstats.Currency.Value = profile.Data.Currency
	end
	return true
end

return Economy
