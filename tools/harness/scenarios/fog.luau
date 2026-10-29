--!nocheck
-- Fog of war (docs/DESIGN.md "Fog of war"), on Earth, on by default. Alice's snapshot says what Rhine sees and her
-- map hazes the rest; a Volga army far away exists only on Bob's screen, then shows on Alice's when it stands next to
-- her land and is gone again when it leaves (its positions too). Allied, Alice sees what Bob sees. A private
-- server's owner or Studio's Workspace FogOfWar switch turns it off: from the next match every army shows on every
-- screen, no haze.

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
	H.expect(state.setup.settings.fog == true, "the fog of war is on by default (Config.Features.FogOfWar)")
	local Army = require("../../../src/shared/Sim/Army")
	local Diplomacy = require("../../../src/shared/Sim/Diplomacy")
	local Fog = require("../../../src/shared/Sim/Fog")
	local AIService = H.server("Services.AIService")
	AIService.step = function() end -- the bots hold still
	local aliceState = H.client(alice, "ClientState")
	local bobState = H.client(bob, "ClientState")
	local fogged = H.client(alice, "MapRenderer").fogged

	local snap = aliceState.snapshot()
	H.expect(snap.vision ~= nil and not snap.vision.all and #snap.vision.provinces > 0, "Alice's snapshot: what she sees")
	local capital = state.nations[A].capital
	H.expect(not fogged(capital), "her own land is clear")

	-- a Volga army far from Rhine
	local vision = Fog.vision(state, A)
	local far: number? = nil
	for id, p in state.provinces do
		if p.owner == B and not vision.provinces[id] then
			far = id
		end
	end
	H.expect(far ~= nil, "Volga has land Rhine doesn't see")
	H.expect(fogged(far), "under the haze on Alice's map")
	local army = Army.spawn(state, B, far, 6000)
	Emulator.run(1.5)
	H.expect(bobState.army(army.id) ~= nil, "Bob sees his army")
	H.expect(aliceState.army(army.id) == nil, "Alice doesn't: it isn't in what the server sends her")
	H.expect(H.mapObject(alice, "Army" .. army.id) == nil and H.mapObject(bob, "Army" .. army.id) ~= nil, "no token")
	H.client(alice, "MapView").centreOn(H.provinceMap(alice, capital), false)
	Emulator.run(1.5)
	H.shot(alice, "fog_on")

	-- it stands next to her land: in sight; it leaves: gone
	local near: number? = nil
	for id, p in state.provinces do
		if p.owner == A then
			for _, n in p.neighbors do
				if state.provinces[n].owner ~= A and state.provinces[n].terrain ~= "Mountain" then
					near = n
				end
			end
		end
	end
	H.expect(near ~= nil, "a province next to Rhine's land")
	army.location = near
	Emulator.run(1.5)
	H.expect(aliceState.army(army.id) ~= nil, "in sight next to her land")
	H.expect(H.mapObject(alice, "Army" .. army.id) ~= nil, "its token shows")
	H.shot(alice, "in_sight")
	army.location = far
	Emulator.run(1.5)
	H.expect(aliceState.army(army.id) == nil and H.mapObject(alice, "Army" .. army.id) == nil, "out of sight again")
	-- marching out there: no positions for Alice either
	local onward: number? = nil
	for _, n in state.provinces[far].neighbors do
		if state.provinces[n].owner == B and not vision.provinces[n] then
			onward = n
		end
	end
	if onward then
		army.path, army.moveProgress = { onward }, 1
		Emulator.run(1.5)
		H.expect(bobState.position(army.id) ~= nil, "Bob's client slides his army")
		H.expect(aliceState.position(army.id) == nil, "Alice gets no positions for it")
		army.path, army.moveProgress = {}, 0
	end

	-- allies share what they see
	assert(Diplomacy.ally(state, A, B))
	Emulator.run(1.5)
	H.expect(aliceState.army(army.id) ~= nil, "allied: Alice sees Bob's army")
	H.expect(not fogged(far), "and his land is clear on her map")
	H.shot(alice, "allied")

	-- off from the next match: Studio's switch (a private server's setting does the same)
	local workspace = Emulator.server.dm:GetService("Workspace")
	workspace:SetAttribute("FogOfWar", false)
	workspace:SetAttribute("DevTick", 1499)
	local deadline = Emulator.now() + 45
	while H.state() == state and Emulator.now() < deadline do
		Emulator.run(1)
	end
	Emulator.run(2)
	local nextMatch = H.state()
	H.expect(nextMatch ~= state and nextMatch.setup.settings.fog == false, "the next match plays without the fog")
	local after = aliceState.snapshot()
	H.expect(after.vision == nil, "no vision in Alice's snapshot")
	local total = 0
	for _ in nextMatch.armies do
		total += 1
	end
	H.expect(#after.armies == total, "every army reaches Alice (" .. #after.armies .. " of " .. total .. ")")
	local hazed = 0
	for id in nextMatch.provinces do
		if fogged(id) then
			hazed += 1
		end
	end
	H.expect(hazed == 0, "no haze anywhere")
	H.client(alice, "MapView").centreOn(H.provinceMap(alice, nextMatch.nations[A].capital), false)
	Emulator.run(1.5)
	H.shot(alice, "fog_off")
end

return {
	map = "earth", -- the map it needs (MAP overrides)
	run = run,
}
