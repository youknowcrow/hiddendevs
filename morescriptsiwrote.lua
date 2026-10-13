local servss = game:GetService("ServerScriptService")
local PlayerData = require(servss.PlayerData.Manager)
game.Players.PlayerAdded:Connect(function(plr)
	local profile
	local timeout = 5
	local t = 0
	repeat
		profile = PlayerData.Profiles[plr]
		if not profile then
			task.wait(0.1)
			t += 0.1
		end
	until profile or t >= timeout
	if not profile then
		return
	end
	local Plot = game.ServerStorage.Plot:Clone()
	Plot.Parent = game.Workspace.Plots
	Plot.PlaceableGround.Owner.Value = plr.Name
	Plot.Name = plr.Name
	local spot = game.Workspace.Plots:FindFirstChild("PlotSpot")
	Plot:PivotTo(spot.CFrame)
	spot.Name = plr.UserId

	local PlacedItemFolder = Instance.new("Folder")
	PlacedItemFolder.Parent = game.Workspace.PlacedItems
	PlacedItemFolder.Name = plr.Name

	for i,PlacedItem in ipairs(profile.Data.PlacedItems) do
		local newitem = game.ReplicatedStorage.PlaceableItems:FindFirstChild(PlacedItem.Name):Clone()
		newitem.Parent = game.Workspace.PlacedItems:FindFirstChild(plr.Name)
		
		local components = PlacedItem.CFrame
		local newCFrame = CFrame.new(unpack(components))
		newitem:PivotTo(newCFrame)
	end	

	plr.CharacterAdded:Connect(function(char)
		char.HumanoidRootPart:PivotTo(Plot.Bounderies.CFrame)
	end)
end)
game.Players.PlayerRemoving:Connect(function(plr)
	local Plot = game.Workspace.Plots:FindFirstChild(plr.Name)
	if Plot then
		local spot = game.Workspace.Plots:FindFirstChild(plr.UserId)
		spot.Name = "PlotSpot"
		Plot:Destroy()
		game.Workspace.PlacedItems:FindFirstChild(plr.Name):Destroy()
	end
end)
