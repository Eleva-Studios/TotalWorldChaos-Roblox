--!strict
-- The EU4 pack's missions (docs/DESIGN.md "Missions"): your nation's goals as a row of slot tiles on a plate in the
-- offers column at the top right, under a "Missions" title plate. Each tile is the goal's icon, its province (Take) or
-- its progress ("1/2"), and its reward as icon chips. Tap one: the map shows its province and a toast says the goal
-- in words and the time left. When a goal is done a toast says what it paid; one that ran out says so. The strip
-- steps aside while the column holds anything else (an event card, an insult to answer, an offer), so the column
-- never reaches the power button on a phone, and while a bottom sheet is open (it reaches up under the column). The server tells this client about its own nation's goals only
-- (Replicator.sendMissions), by kind: the words come from Shared.Flavour.Missions. Built from the UI kit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

ReplicatedStorage:WaitForChild("Shared")
local Shared = ReplicatedStorage.Shared
local EventText = require(Shared.Flavour.EventCards)
local MissionText = require(Shared.Flavour.Missions)
local Missions = require(Shared.Sim.Missions)
local Remotes = require(Shared.Remotes)
local Types = require(Shared.Types)

local Client = script.Parent.Parent
local ClientState = require(Client.ClientState)
local RaceInfo = require(Client.RaceInfo)
local Offers = require(script.Parent.Offers)
local Widgets = require(script.Parent.Widgets)

local Theme = Widgets.Theme
local STRIP_ORDER = 30 -- in the offers column: under the event card (0), the insult card (1) and the offers (10 and up)
local PLATE_ROOM = 14 -- the title plate rides this far above the plate's top edge
local PLATE_SIDE = 10 -- a plate's padding at each side (Widgets.panel)
local OTHER_CARDS = { EventCard = true, Answer = true, Offer = true } -- the column's other cards: the strip steps aside
local REFRESH_SECONDS = 0.25 -- how soon the strip steps aside for a card or a sheet

local MissionsUI = {}

local view: Types.MissionView? = nil
local strip: Frame? = nil
local gap: Frame? = nil
local shownKey = "" -- the view on screen (Missions.key)
local shownHere: { [number]: boolean } = {} -- goals this client showed: only their outcome gets a toast
local toldId = 0 -- the last closed goal a toast told about
local toast: ((string) -> ())? = nil
local focus: ((number) -> ())? = nil
local sheetOpen: () -> boolean = function(): boolean
	return false
end

local function provinceName(id: number): string?
	local map = ClientState.map()
	return if map and map.provinces[id] then map.provinces[id].name else nil
end

local function words(kind: string, target: number, need: number): string
	return MissionText.goal(kind, if target ~= 0 then provinceName(target) else nil, need)
end

-- A reward as short icon chips that fit an 84 px tile beside its 32 px icon: gold "60", manpower "4k", regiments of
-- your line troop "2".
local function rewardChips(kind: string): { { string } }
	local reward = Missions.reward(kind)
	local out: { { string } } = {}
	if reward.gold then
		table.insert(out, { "gold", tostring(reward.gold) })
	end
	if reward.manpower then
		local m = reward.manpower
		table.insert(out, { "manpower", if m >= 1000 then string.format("%gk", m / 1000) else tostring(m) })
	end
	if reward.regiments then
		local me = ClientState.nation(ClientState.myNation())
		local troop = RaceInfo.lineTroop(if me then me.race else nil)
		table.insert(out, { RaceInfo.troopIcon(troop), tostring(reward.regiments) })
	end
	return out
end

local function drop()
	if strip then
		strip:Destroy()
	end
	if gap then
		gap:Destroy()
	end
	strip, gap, shownKey = nil, nil, ""
end

-- Is anything else in the offers column, or a bottom sheet open (on a phone it reaches up under the column)?
local function crowded(): boolean
	if sheetOpen() then
		return true
	end
	for _, child in Offers.column():GetChildren() do
		if OTHER_CARDS[child.Name] then
			return true
		end
	end
	return false
end

local function tapped(m: Types.MissionInfo)
	local left = math.max(0, m.untilTick - ClientState.tick())
	local text = string.format(
		"%s: %s · %d:%02d left",
		words(m.kind, m.target, m.need),
		EventText.summary(Missions.reward(m.kind), 0),
		left // 60,
		left % 60
	)
	if toast then
		toast("🏅 " .. text)
	end
	if m.target ~= 0 and focus then
		focus(m.target)
	end
end

local function build(v: Types.MissionView)
	drop()
	shownKey = Missions.key(v)
	if #v.missions == 0 then
		return
	end
	local column = Offers.column()
	local room = Instance.new("Frame")
	room.Name = "MissionsGap"
	room.BackgroundTransparency = 1
	room.Size = UDim2.new(1, 0, 0, PLATE_ROOM)
	room.LayoutOrder = STRIP_ORDER - 1
	room.Parent = column
	gap = room
	local made = Widgets.panel(column, Offers.WIDTH, "plate")
	made.Name = "Missions"
	made.LayoutOrder = STRIP_ORDER
	Widgets.list(made, false, Theme.space.s)
	Widgets.header(made, "Missions", "medal")
	strip = made
	local row = Instance.new("Frame")
	row.Name = "Goals"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, Widgets.TILE_HEIGHT)
	row.LayoutOrder = 1
	row.Parent = made
	Widgets.list(row, true, Theme.space.s)
	local width = Widgets.tileWidth(Offers.WIDTH - 2 * PLATE_SIDE, math.max(3, #v.missions), Theme.space.s)
	for i, m in v.missions do
		shownHere[m.id] = true
		local caption = if m.kind == "Take"
			then provinceName(m.target) or "?"
			else string.format("%d/%d", m.have, m.need)
		local chips = rewardChips(m.kind)
		local mission = m
		local tile = Widgets.slotTile(
			row,
			MissionText.ICONS[m.kind] or "star",
			caption,
			chips,
			Vector2.new(width, Widgets.TILE_HEIGHT),
			"build",
			function()
				tapped(mission)
			end,
			"Mission_" .. m.kind
		)
		tile.LayoutOrder = i
	end
end

-- What happened to the last goal this client showed: "🏅 Mission done! Take Kent: +60 gold", or that it ran out.
local function tell(v: Types.MissionView)
	if v.lastId == 0 or v.lastId == toldId or not shownHere[v.lastId] then
		return
	end
	toldId = v.lastId
	local goal = words(v.lastKind, v.lastTarget, 1)
	local text = if v.lastDone
		then "🏅 Mission done! " .. goal .. ": " .. EventText.summary(Missions.reward(v.lastKind), 0)
		else "⌛ Mission over: " .. goal
	if toast then
		toast(text)
	end
end

-- Show the strip when there are goals and nothing else in the column; rebuild it when the goals change.
local function refresh()
	local v = view
	if v == nil or #v.missions == 0 or crowded() then
		drop()
		return
	end
	if strip == nil or Missions.key(v) ~= shownKey then
		build(v)
	end
end

local function onView(v: Types.MissionView)
	view = v
	tell(v)
	refresh()
end

-- showToast: Hud.toast. showProvince: the map jumps to a goal's province (with its sheet). anySheet: is a bottom
-- sheet open (province, army, fleet)?
function MissionsUI.init(showToast: (string) -> (), showProvince: (number) -> (), anySheet: () -> boolean)
	toast = showToast
	focus = showProvince
	sheetOpen = anySheet
	ClientState.onReset(function()
		drop()
		view = nil
		shownHere = {}
		toldId = 0
	end)
	Remotes.event("Missions").OnClientEvent:Connect(onView)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= REFRESH_SECONDS then
			acc = 0
			refresh()
		end
	end)
end

return MissionsUI
