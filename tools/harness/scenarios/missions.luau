--!nocheck
-- The EU4 pack's missions (docs/DESIGN.md "Missions"), on Earth. Twenty seconds in, Alice's three goals come as slot
-- tiles on a plate in the offers column (icon, province or progress, reward chips); Bob sees only his own. A tap on a
-- goal shows its province (with its sheet; the strip steps aside meanwhile) and says it in words. She develops her
-- capital for a Grow goal: it pays on the spot, a toast says so, and after a short wait a goal of another kind takes
-- the slot. The strip steps aside while an event card is open. Bots get goals by the same rules and finish some. `mission` reaches analytics. Studio's DevMissions fills
-- empty slots at once; with the setting off the strip is gone.

local Emulator = require("../Emulator")
local H = require("../H")

local function run()
	Emulator.run(1)
	local alice = Emulator.addClient("Alice")
	local bob = Emulator.addClient("Bob")
	Emulator.run(2)
	local state = H.state()
	local A, B = H.myNation(alice), H.myNation(bob)
	H.expect(A == 1 and B == 2 and state.mapId == "earth", "Alice is Rhine, Bob is Volga, on Earth")
	local Config = require("../../../src/shared/Config")
	local EventCards = require("../../../src/shared/Sim/EventCards")
	local Missions = require("../../../src/shared/Sim/Missions")
	local M = Config.Missions
	local AIService = H.server("Services.AIService")
	local botStep = AIService.step
	AIService.step = function() end -- the bots hold still for now
	H.expect(state.setup.settings.missions == true, "missions are on by default (Config.Features.Missions)")

	-- the first goals come twenty seconds in
	local deadline = Emulator.now() + M.FirstTicks + 5
	while #Missions.list(state, A) < M.Slots and Emulator.now() < deadline do
		Emulator.run(1)
	end
	Emulator.run(1.5)
	local goals = Missions.list(state, A)
	H.expect(#goals == M.Slots, "Rhine has three goals")
	H.expect(H.find(alice, "Missions") ~= nil, "Alice sees them at the top right")
	for _, m in goals do
		H.expect(H.hasButton(alice, "Mission_" .. m.kind), "a tile for " .. m.kind)
		H.expect(H.iconIn(alice, "Mission_" .. m.kind, require("../../../src/shared/Flavour/Missions").ICONS[m.kind]), "its icon")
	end
	for _, m in Missions.list(state, B) do
		H.expect(H.hasButton(bob, "Mission_" .. m.kind), "Bob's own goal " .. m.kind)
	end
	H.shot(alice, "goals")

	-- a Grow goal: develop the capital one level
	local capital = state.nations[A].capital
	local level = state.provinces[capital].development
	state.missions[A] = {
		missions = {
			{ id = state.nextMissionId, kind = "Grow", target = capital, base = level, need = level + 1, untilTick = state.tick + M.Ticks },
		},
		refills = { state.tick + 10000, state.tick + 10000 },
		last = nil,
		done = state.missions[A].done,
	}
	state.nextMissionId += 1
	Emulator.run(1.5)
	H.expect(H.hasButton(alice, "Mission_Grow") and H.within(alice, "Mission_Grow", "0/1"), "the Grow tile, 0 of 1")
	H.expect(H.within(alice, "Mission_Grow", "40"), "it pays 40 gold")
	Emulator.press(alice, "Mission_Grow")
	Emulator.run(1)
	local name = state.provinces[capital].name
	H.expect(H.waitText(alice, "Develop " .. name .. ": +40 gold"), "a tap says the goal in words")
	H.expect(H.hasButton(alice, "Develop"), "and shows its province with its sheet")
	H.expect(H.find(alice, "Missions") == nil, "the strip steps aside while a sheet is open")
	H.shot(alice, "goal_tapped")
	state.nations[A].gold = 500
	Emulator.run(1)
	Emulator.press(alice, "Develop")
	Emulator.run(2)
	H.expect(state.provinces[capital].development == level + 1, "the capital grew")
	H.expect(state.missions[A].last and state.missions[A].last.done, "the goal is done")
	H.expect(H.waitText(alice, "Mission done! Develop " .. name .. ": +40 gold"), "a toast says what it paid")
	H.shot(alice, "goal_done")
	Emulator.press(alice, "✕") -- close the sheet
	Emulator.run(M.RefillTicks + 1.5)
	local new = Missions.list(state, A)
	H.expect(#new == 1 and new[1].kind ~= "Grow", "a goal of another kind takes the slot")
	H.expect(H.hasButton(alice, "Mission_" .. new[1].kind), "on the strip, back once the sheet closed")

	-- an event card: the strip steps aside, and comes back once it's answered
	local seen = {}
	for _, def in EventCards.EVENTS do
		if def.id ~= "Cats" then
			table.insert(seen, def.id)
		end
	end
	state.chronicles[A] = { nextAt = state.tick + 1, seen = seen, card = nil, last = nil }
	Emulator.run(2.5)
	H.expect(H.find(alice, "EventCard") ~= nil and H.find(alice, "Missions") == nil, "the card, alone in the column")
	Emulator.press(alice, "EventChoice1")
	Emulator.run(2)
	H.expect(H.find(alice, "Missions") ~= nil, "the strip is back")

	-- Studio's DevMissions: the empty slots fill on the next game second
	local workspace = Emulator.server.dm:GetService("Workspace")
	workspace:SetAttribute("DevMissions", 1)
	Emulator.run(2)
	H.expect(#Missions.list(state, A) == M.Slots, "DevMissions: three goals again")

	-- bots get goals by the same rules and finish some
	AIService.step = botStep
	Emulator.run(150)
	local botsDone = 0
	for id, nation in state.nations do
		if nation.controller == "Bot" then
			H.expect(#Missions.list(state, id) <= M.Slots, nation.name .. ": three goals at most")
			botsDone += state.missions[id].done
		end
	end
	H.expect(botsDone >= 3, "the bots finished goals (" .. botsDone .. ")")

	-- analytics: a mission event for the goal Alice finished
	local logged = {}
	for _, r in Emulator.analytics do
		if r.method == "LogCustomEvent" and r.userId == alice.serverPlayer.UserId and r.args[1] == "mission" then
			local f = r.args[#r.args] or {}
			local keys = Emulator.roblox.Enum.AnalyticsCustomFieldKeys
			table.insert(logged, (f[keys.CustomField01.Name] or "") .. "," .. (f[keys.CustomField02.Name] or "") .. "," .. (f[keys.CustomField03.Name] or ""))
		end
	end
	H.expect(table.find(logged, "Grow,earth,done") ~= nil, "mission: Grow done (" .. table.concat(logged, " ") .. ")")

	-- the setting off: no goals, no strip
	state.setup.settings.missions = false
	Emulator.run(2)
	H.expect(H.find(alice, "Missions") == nil, "no strip with the setting off")
end

return {
	map = "earth", -- the map it needs (MAP overrides)
	run = run,
}
