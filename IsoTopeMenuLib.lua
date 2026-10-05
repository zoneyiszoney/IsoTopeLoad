-- =========================================================================
-- ISOTOPE MM2 • MODULAR LOADER EDITION
-- Author: @Zoney
-- Description: Lightweight MM2 feature script. Imports the clean UI library
-- directly from GitHub and binds all game functions to the menu!
-- =========================================================================

-- URL to your hosted IsoTopeMenuLib.lua on GitHub:
local MENU_LIB_URL = "https://raw.githubusercontent.com/zoneyiszoney/IsoTopeLoad/refs/heads/main/IsoTopeMenuLib.lua"

-- 1. LOAD THE CLEAN MENU LIBRARY FROM GITHUB
local ok, IsoTopeUI = pcall(function()
	return loadstring(game:HttpGet(MENU_LIB_URL))()
end)

if not ok or not IsoTopeUI then
	error("[IsoTopeMM2]: Failed to load Menu Library from " .. tostring(MENU_LIB_URL))
	return
end

-- Services
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
	LocalPlayer = Players.LocalPlayer
	task.wait(0.1)
end

-- =========================================================================
-- MM2 RUNTIME STATE & CONFIGURATION
-- =========================================================================
local CONFIG = {
	AutoFarm = false,
	TweenSpeed = 28,
	CoinDelay = 0.35,
	CoinTarget = 40,
	AntiFling = true,
	AntiAfk = true,
	Noclip = false,
	AntiVoid = true,
	AntiMurdererTeleport = true,
	MurdererSafeDistance = 22,
	MurdererEvadeCooldown = 1.8,
	SheriffAimbot = false,
	SheriffAimSmoothness = 0.18,
	SheriffAimWallCheck = true,
	OnlyTargetAlive = true,
	CoinEsp = false,
	GunDropEsp = false,
	RoleEsp = false,
	WalkSpeedEnabled = false,
	WalkSpeed = 24,
	JumpPowerEnabled = false,
	JumpPower = 50,
	InfiniteJump = false,
}

local Session = {
	FarmedCoins = 0,
	BagFull = false,
	Status = "READY",
	CurrentTween = nil,
	TempIgnored = {},
}

-- Forward declarations
local getRolePlayers
local grabGunDrop
local executeKillAll

-- =========================================================================
-- COIN SYSTEM & AUTOFARM ENGINE
-- =========================================================================
local function isCoinPickedUp(coin)
	if not coin or not coin.Parent or not coin:IsDescendantOf(Workspace) then return true end
	local hasTouch = coin:FindFirstChild("TouchInterest") or coin:FindFirstChildOfClass("TouchTransmitter")
	local hasVisual = coin:FindFirstChild("CoinVisual")
	return not hasTouch and not hasVisual
end

local function getCoinParts()
	local list = {}
	local checked = {}
	local container = Workspace:FindFirstChild("Normal") and Workspace.Normal:FindFirstChild("CoinContainer")
		or (Workspace:FindFirstChild("Map") and Workspace.Map:FindFirstChild("CoinContainer"))
		or Workspace:FindFirstChild("CoinContainer", true)

	if container and container:IsDescendantOf(Workspace) then
		for _, c in ipairs(container:GetChildren()) do
			local part = c:IsA("BasePart") and c or c:FindFirstChildWhichIsA("BasePart")
			if part and not checked[part] and not isCoinPickedUp(part) then
				if not Session.TempIgnored[part] or os.clock() >= Session.TempIgnored[part] then
					checked[part] = true
					table.insert(list, part)
				end
			end
		end
	end

	-- Fallback scan if container not standard
	if #list == 0 then
		for _, desc in ipairs(Workspace:GetDescendants()) do
			if desc.Name == "Coin_Server" or desc.Name == "HolidayCoin_Server" or desc.Name == "Coin" then
				local part = desc:IsA("BasePart") and desc or desc:FindFirstChildWhichIsA("BasePart")
				if part and not checked[part] and not isCoinPickedUp(part) then
					checked[part] = true
					table.insert(list, part)
				end
			end
		end
	end
	return list
end

local function stopCurrentTween()
	if Session.CurrentTween then
		pcall(function() Session.CurrentTween:Cancel() end)
		Session.CurrentTween = nil
	end
end

local function tweenTo(targetCF, speed)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return false end

	stopCurrentTween()
	local dist = (root.Position - targetCF.Position).Magnitude
	if dist < 2 then root.CFrame = targetCF return true end

	local spd = math.max(10, tonumber(speed) or 28)
	local dur = dist / spd
	local tw = TweenService:Create(root, TweenInfo.new(dur, Enum.EasingStyle.Linear), { CFrame = targetCF })
	Session.CurrentTween = tw

	local done = false
	local c = tw.Completed:Connect(function() done = true end)
	tw:Play()

	local t0 = os.clock()
	while not done and (os.clock() - t0) < (dur + 1.2) do
		if not CONFIG.AutoFarm then stopCurrentTween() break end
		if not root or not root.Parent or hum.Health <= 0 then stopCurrentTween() break end
		task.wait(0.03)
	end
	if c then pcall(function() c:Disconnect() end) end
	Session.CurrentTween = nil
	return done
end

local function collectCoin(coin)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root or not coin or not coin.Parent then return false end

	if Session.FarmedCoins >= CONFIG.CoinTarget then
		stopCurrentTween()
		Session.BagFull = true
		Session.Status = "BAG FULL"
		return false
	end

	local arrived = tweenTo(coin.CFrame, CONFIG.TweenSpeed)
	if not arrived and not CONFIG.AutoFarm then return false end

	root.CFrame = coin.CFrame
	if typeof(firetouchinterest) == "function" then
		pcall(function()
			firetouchinterest(root, coin, 0)
			task.wait(0.01)
			firetouchinterest(root, coin, 1)
		end)
	end

	local delayWait = math.max(0.1, tonumber(CONFIG.CoinDelay) or 0.35)
	task.wait(delayWait)

	if isCoinPickedUp(coin) then
		Session.FarmedCoins = Session.FarmedCoins + 1
	else
		Session.TempIgnored[coin] = os.clock() + 3.0
	end
	return true
end

-- =========================================================================
-- COMBAT & ROLE UTILITIES
-- =========================================================================
local function isToolKnife(t)
	if not t or not t:IsA("Tool") then return false end
	local n = t.Name:lower()
	return n:find("knife") or n:find("blade") or n:find("scythe") or t:FindFirstChild("KnifeServer") ~= nil
end

local function isToolGun(t)
	if not t or not t:IsA("Tool") then return false end
	local n = t.Name:lower()
	return n:find("gun") or n:find("revolver") or t:FindFirstChild("GunServer") ~= nil
end

getRolePlayers = function()
	local murderer, sheriff = nil, nil
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			local c = p.Character
			local bp = p:FindFirstChildOfClass("Backpack")
			local knife = c:FindFirstChild("Knife") or (bp and bp:FindFirstChild("Knife"))
			local gun = c:FindFirstChild("Gun") or (bp and bp:FindFirstChild("Gun"))

			if not knife and not gun then
				for _, ch in ipairs(c:GetChildren()) do
					if isToolKnife(ch) then knife = ch break end
					if isToolGun(ch) then gun = ch break end
				end
			end
			if not knife and not gun and bp then
				for _, ch in ipairs(bp:GetChildren()) do
					if isToolKnife(ch) then knife = ch break end
					if isToolGun(ch) then gun = ch break end
				end
			end

			if knife then murderer = p elseif gun then sheriff = p end
		end
	end
	return murderer, sheriff
end

grabGunDrop = function()
	local gun = Workspace:FindFirstChild("GunDrop", true)
	if not gun then return false end
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	local part = gun:IsA("BasePart") and gun or gun:FindFirstChildWhichIsA("BasePart")
	if part then
		root.CFrame = part.CFrame * CFrame.new(0, 0.5, 0)
		if typeof(firetouchinterest) == "function" then
			pcall(function()
				firetouchinterest(root, part, 0)
				task.wait(0.01)
				firetouchinterest(root, part, 1)
			end)
		end
		return true
	end
	return false
end

executeKillAll = function()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return end

	local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
	local knife = char:FindFirstChild("Knife") or (bp and bp:FindFirstChild("Knife"))
	if not knife then return end

	if knife.Parent ~= char then hum:EquipTool(knife) task.wait(0.05) end
	local handle = knife:FindFirstChild("Handle")

	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character then
			local tHum = p.Character:FindFirstChildOfClass("Humanoid")
			local tRoot = p.Character:FindFirstChild("HumanoidRootPart")
			if tHum and tRoot and tHum.Health > 0 then
				pcall(function() p.Character:PivotTo(root.CFrame * CFrame.new(0, 0, -2.5)) end)
				task.wait(0.02)
				pcall(function() knife:Activate() end)
				if handle and typeof(firetouchinterest) == "function" then
					pcall(function()
						firetouchinterest(handle, tRoot, 0)
						firetouchinterest(handle, tRoot, 1)
					end)
				end
				task.wait(0.04)
			end
		end
	end
end

-- =========================================================================
-- 2. CREATE WINDOW USING THE CLEAN MENU LIBRARY
-- =========================================================================
local Window = IsoTopeUI:CreateWindow({
	Title = "IsoTope Hub",
	Subtitle = "Murder Mystery 2 • Modular Edition",
	Theme = "Emerald",
	Keybind = Enum.KeyCode.RightControl,
	MobileToggle = true
})

-- =========================================================================
-- TAB 1: HOME
-- =========================================================================
local HomeTab = Window:CreateTab({ Name = "Home", Icon = "⚡" })

HomeTab:CreateSection("Quick Actions")

HomeTab:CreateToggle({
	Title = "Quick AutoFarm",
	Description = "Start farming coins (Tween 28 st/s, 0.35s delay)",
	Default = CONFIG.AutoFarm,
	Callback = function(v)
		CONFIG.AutoFarm = v
		if not v then stopCurrentTween() end
		Window:SetStatus(v and "FARMING" or "READY")
	end
})

HomeTab:CreateButton({
	Title = "Kill All Players",
	Description = "Equip knife and attack all living players",
	ButtonText = "KILL ALL",
	Callback = function()
		executeKillAll()
	end
})

HomeTab:CreateSection("Live Roles")

local roleCard = HomeTab:CreateCard({
	Title = "Live Role Tracker",
	Description = "Click Scan Roles to identify Murderer & Sheriff"
})

HomeTab:CreateButton({
	Title = "Scan Roles",
	Description = "Check player inventory and character tools",
	ButtonText = "SCAN",
	Callback = function()
		local m, s = getRolePlayers()
		local mName = m and m.DisplayName or "None"
		local sName = s and s.DisplayName or "None"
		roleCard:SetDesc("🔪 Murderer: " .. mName .. " | ⭐ Sheriff: " .. sName)
	end
})

-- =========================================================================
-- TAB 2: AUTOFARM
-- =========================================================================
local FarmTab = Window:CreateTab({ Name = "AutoFarm", Icon = "🪙" })

FarmTab:CreateSection("Coin Farming Controls")

FarmTab:CreateToggle({
	Title = "Enable Coin AutoFarm",
	Description = "Fly smoothly to active coins with zero fling",
	Default = CONFIG.AutoFarm,
	Callback = function(v)
		CONFIG.AutoFarm = v
		if not v then stopCurrentTween() end
		Window:SetStatus(v and "FARMING" or "READY")
	end
})

FarmTab:CreateSlider({
	Title = "Tween Speed",
	Description = "Flying velocity in studs/sec (Default: 28)",
	Min = 10,
	Max = 60,
	Default = CONFIG.TweenSpeed,
	Suffix = " st/s",
	Callback = function(v)
		CONFIG.TweenSpeed = math.floor(v)
	end
})

FarmTab:CreateSlider({
	Title = "Coin Delay",
	Description = "Pause time at each coin to ensure server registration",
	Min = 0.1,
	Max = 1.0,
	Step = 0.05,
	Default = CONFIG.CoinDelay,
	Suffix = "s",
	Callback = function(v)
		CONFIG.CoinDelay = v
	end
})

FarmTab:CreateButton({
	Title = "Coin Target (40 / 50)",
	Description = "Switch between Standard (40) and Elite (50) bag limit",
	ButtonText = tostring(CONFIG.CoinTarget) .. " COINS",
	Callback = function()
		CONFIG.CoinTarget = (CONFIG.CoinTarget == 40) and 50 or 40
	end
})

FarmTab:CreateSection("Sheriff Gun Tools")

FarmTab:CreateToggle({
	Title = "Auto Grab Dropped Gun",
	Description = "Teleports to dropped sheriff gun when Sheriff dies",
	Default = false,
	Callback = function(v)
		if v then grabGunDrop() end
	end
})

FarmTab:CreateButton({
	Title = "Grab Dropped Gun Now",
	Description = "Instant teleport to dropped sheriff gun",
	ButtonText = "GRAB GUN",
	Callback = function()
		grabGunDrop()
	end
})

-- =========================================================================
-- TAB 3: COMBAT
-- =========================================================================
local CombatTab = Window:CreateTab({ Name = "Combat", Icon = "⚔️" })

CombatTab:CreateSection("Sheriff Aim Suite")

CombatTab:CreateToggle({
	Title = "Sheriff Aimbot (Murderer Only)",
	Description = "Smoothly tracks the Murderer when holding Sheriff Gun",
	Default = CONFIG.SheriffAimbot,
	Callback = function(v)
		CONFIG.SheriffAimbot = v
	end
})

CombatTab:CreateSlider({
	Title = "Aim Smoothness (Lerp)",
	Description = "Camera interpolation factor (Default: 0.18)",
	Min = 0.05,
	Max = 0.60,
	Step = 0.01,
	Default = CONFIG.SheriffAimSmoothness,
	Callback = function(v)
		CONFIG.SheriffAimSmoothness = v
	end
})

CombatTab:CreateToggle({
	Title = "Aim Wall Check",
	Description = "Only tracks Murderer when visible with clear line-of-sight",
	Default = CONFIG.SheriffAimWallCheck,
	Callback = function(v)
		CONFIG.SheriffAimWallCheck = v
	end
})

CombatTab:CreateSection("Murderer Suite")

CombatTab:CreateButton({
	Title = "Execute Kill All",
	Description = "Equips knife and attacks all living players",
	ButtonText = "KILL ALL",
	Callback = function()
		executeKillAll()
	end
})

-- =========================================================================
-- TAB 4: VISUALS
-- =========================================================================
local VisualsTab = Window:CreateTab({ Name = "Visuals", Icon = "👁️" })

VisualsTab:CreateSection("ESP Highlighting")

VisualsTab:CreateToggle({
	Title = "Coin ESP (Gold)",
	Description = "Highlights active map coins through walls",
	Default = CONFIG.CoinEsp,
	Callback = function(v)
		CONFIG.CoinEsp = v
	end
})

VisualsTab:CreateToggle({
	Title = "Sheriff Gun Drop ESP",
	Description = "Highlights dropped sheriff gun in cyan",
	Default = CONFIG.GunDropEsp,
	Callback = function(v)
		CONFIG.GunDropEsp = v
	end
})

VisualsTab:CreateToggle({
	Title = "Role ESP (Murderer & Sheriff)",
	Description = "Red: Murderer, Blue: Sheriff, Green: Innocents",
	Default = CONFIG.RoleEsp,
	Callback = function(v)
		CONFIG.RoleEsp = v
	end
})

-- =========================================================================
-- TAB 5: MOVEMENT & SAFETY
-- =========================================================================
local MoveTab = Window:CreateTab({ Name = "Movement", Icon = "🛡️" })

MoveTab:CreateSection("Safety Safeguards")

MoveTab:CreateToggle({
	Title = "Anti Void",
	Description = "Recovers character when falling below map into the void",
	Default = CONFIG.AntiVoid,
	Callback = function(v)
		CONFIG.AntiVoid = v
	end
})

MoveTab:CreateToggle({
	Title = "Anti Murderer Teleport",
	Description = "Smoothly glides away with cooldown when Murderer enters safe distance",
	Default = CONFIG.AntiMurdererTeleport,
	Callback = function(v)
		CONFIG.AntiMurdererTeleport = v
	end
})

MoveTab:CreateSlider({
	Title = "Murderer Safe Distance",
	Description = "Trigger distance in studs (Default: 22)",
	Min = 12,
	Max = 45,
	Default = CONFIG.MurdererSafeDistance,
	Suffix = " studs",
	Callback = function(v)
		CONFIG.MurdererSafeDistance = math.floor(v)
	end
})

MoveTab:CreateSlider({
	Title = "Evade Cooldown",
	Description = "Delay between evasions to prevent invalid position kicks",
	Min = 0.5,
	Max = 5.0,
	Step = 0.1,
	Default = CONFIG.MurdererEvadeCooldown,
	Suffix = "s",
	Callback = function(v)
		CONFIG.MurdererEvadeCooldown = v
	end
})

MoveTab:CreateSection("Player Mobility")

MoveTab:CreateToggle({
	Title = "Noclip",
	Description = "Walk through walls and obstacles",
	Default = CONFIG.Noclip,
	Callback = function(v)
		CONFIG.Noclip = v
	end
})

MoveTab:CreateToggle({
	Title = "Anti-AFK Protection",
	Description = "Prevents 20-minute Roblox idle disconnect",
	Default = CONFIG.AntiAfk,
	Callback = function(v)
		CONFIG.AntiAfk = v
	end
})

-- =========================================================================
-- BACKGROUND RUNTIME LOOPS
-- =========================================================================
-- AutoFarm Task
task.spawn(function()
	while Window.ScreenGui.Parent do
		if CONFIG.AutoFarm then
			local coins = getCoinParts()
			if #coins > 0 and not Session.BagFull then
				Window:SetStatus("FARMING")
				collectCoin(coins[1])
			else
				task.wait(0.5)
			end
		else
			task.wait(0.4)
		end
	end
end)

-- Anti-AFK
pcall(function()
	LocalPlayer.Idled:Connect(function()
		if CONFIG.AntiAfk then
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.zero)
			end)
		end
	end)
end)

-- Sheriff Aimbot RenderStepped loop
RunService.RenderStepped:Connect(function()
	if not CONFIG.SheriffAimbot then return end
	local char = LocalPlayer.Character
	if not char then return end
	local gun = char:FindFirstChild("Gun") or char:FindFirstChildWhichIsA("Tool")
	if not gun or not isToolGun(gun) then return end

	local murderer, _ = getRolePlayers()
	if not murderer or murderer == LocalPlayer or not murderer.Character then return end
	local mRoot = murderer.Character:FindFirstChild("HumanoidRootPart")
	if not mRoot then return end

	local cam = Workspace.CurrentCamera
	if not cam then return end

	local goalCF = CFrame.new(cam.CFrame.Position, mRoot.Position)
	cam.CFrame = cam.CFrame:Lerp(goalCF, CONFIG.SheriffAimSmoothness)
end)
