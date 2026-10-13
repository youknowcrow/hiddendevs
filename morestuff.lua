local PlayerData = require(game.ServerScriptService.PlayerData.Manager)
local Economy = require(game.ServerScriptService.Economy)

local debounce = {}

game.ReplicatedStorage.BuyItem.OnServerEvent:Connect(function(plr,name)
	if debounce[plr] then return end
	local item = Economy.Items[name]
	if not item then return end
	debounce[plr] = true
	if Economy.Money(plr,-item.Price) then
		Economy.Give(plr,name,1)
		game.ReplicatedStorage.Notify:FireClient(plr,"Bought "..item.Display.."!",true)
	else
		game.ReplicatedStorage.Notify:FireClient(plr,"Not enough money",false)
	end
	task.wait(0.2)
	debounce[plr] = nil
end)

game.ReplicatedStorage.SellItem.OnServerEvent:Connect(function(plr,name)
	if debounce[plr] then return end
	local item = Economy.Items[name]
	if not item then return end
	debounce[plr] = true
	if Economy.Take(plr,name,1) then
		local value = math.floor(item.Price / 2)
		Economy.Money(plr,value)
		game.ReplicatedStorage.Notify:FireClient(plr,"Sold "..item.Display.." for $"..value,true)
	end
	task.wait(0.2)
	debounce[plr] = nil
end)

game.Players.PlayerRemoving:Connect(function(plr)
	if debounce[plr] then
		debounce[plr] = nil
	end
end)

while true do
	task.wait(1)
	for _, plr in pairs(game.Players:GetPlayers()) do
		local profile = PlayerData.Profiles[plr]
		local folder = workspace.PlacedItems:FindFirstChild(plr.Name)
		if profile and folder then
			local total = 0
			for _, m in pairs(folder:GetChildren()) do
				local item = Economy.Items[m.Name]
				if item then
					total += item.Income
				end
			end
			if total > 0 then
				profile.Data.Articles += total
				if plr:FindFirstChild("leaderstats") then
					plr.leaderstats.Articles.Value = profile.Data.Articles
				end
			end
		end
	end
end
