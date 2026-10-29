--!strict
-- Snapshot/delta encoding and the intent rate limit.
local Army = require("../src/shared/Sim/Army")
local Config = require("../src/shared/Config")
local Fog = require("../src/shared/Sim/Fog")
local Maps = require("../src/shared/Maps")
local Match = require("../src/shared/Sim/Match")
local Navy = require("../src/shared/Sim/Navy")
local RateLimit = require("../src/shared/RateLimit")
local Snapshot = require("../src/shared/Snapshot")
local T = require("./TestKit")
local Troops = require("../src/shared/Sim/Troops")

T.test("snapshots are flat arrays with 0 for neutral", function()
	local state = Match.new(Maps.get("eldmoor"))
	local snap = Snapshot.full(state)
	T.equal(#snap.provinces, #Maps.get("eldmoor").provinces)
	T.equal(#snap.nations, 10)
	local neutral = 0
	for i, p in snap.provinces do
		T.equal(p.id, i)
		if p.owner == 0 then
			neutral += 1
		end
	end
	T.expect(neutral > 0)
end)

T.test("no change, no delta", function()
	local state = Match.new(Maps.get("skyshards"))
	local a = Snapshot.full(state)
	state.tick += 1
	T.equal(Snapshot.diff(a, Snapshot.full(state)), nil)
end)

T.test("a delta carries only changed records, and applying it catches the client up", function()
	local state = Match.new(Maps.get("skyshards"))
	local server = Snapshot.full(state)
	local client = Snapshot.full(state)
	state.tick = 5
	state.nations[2].gold += 7
	state.provinces[3].owner = 2
	state.provinces[3].development = 4
	local army = Army.spawn(state, 2, 3, 2000)
	local delta = Snapshot.diff(server, Snapshot.full(state))
	assert(delta, "expected a delta")
	T.equal(#delta.nations, 1)
	T.equal(#delta.provinces, 1)
	T.equal(#delta.armies, 1)
	Snapshot.apply(client, delta)
	T.equal(client.tick, 5)
	T.equal(client.provinces[3].owner, 2)
	T.equal(client.provinces[3].development, 4)
	T.equal(client.nations[2].gold, state.nations[2].gold)
	local mirrored
	for _, a in client.armies do
		if a.id == army.id then
			mirrored = a
		end
	end
	T.equal(mirrored and mirrored.men, 2000)

	-- the army disappears
	local before = Snapshot.full(state)
	state.armies[army.id] = nil
	local delta2 = Snapshot.diff(before, Snapshot.full(state))
	assert(delta2, "expected a delta")
	T.equal(delta2.removedArmies[1], army.id)
	Snapshot.apply(client, delta2)
	for _, a in client.armies do
		T.expect(a.id ~= army.id, "the removed army is gone on the client")
	end
end)

T.test("a phase change alone is a delta", function()
	local state = Match.new(Maps.get("skyshards"))
	local a = Snapshot.full(state)
	state.phase = "War"
	local delta = Snapshot.diff(a, Snapshot.full(state))
	assert(delta, "expected a delta")
	T.equal(delta.phase, "War")
end)

T.test("fleets travel in the snapshot and in deltas: ships, men aboard, route, blockades", function()
	local state = Match.new(Maps.get("skyshards"))
	local client = Snapshot.full(state)
	T.equal(#client.fleets, 0)
	T.equal(client.provinces[2].blockade, 0, "no blockade is 0")

	-- three ships, one of them damaged, with men aboard, sailing two zones
	local before = Snapshot.full(state)
	local fleet = Navy.spawn(state, 1, 1, 3)
	fleet.hull = 2550
	Navy.setCargo(fleet, { Infantry = 2000, Archers = 500 })
	fleet.path = { 2, 3 }
	fleet.moveProgress = 2
	fleet.landAt = 94
	local delta = Snapshot.diff(before, Snapshot.full(state))
	assert(delta, "expected a delta")
	T.equal(#delta.fleets, 1)
	local r = delta.fleets[1]
	T.equal(r.id, fleet.id)
	T.equal(r.owner, 1)
	T.equal(r.zone, 1)
	T.equal(r.ships, 3, "2,550 hull is 3 ships")
	T.equal(r.hull, 2550)
	T.equal(r.men, 2500)
	T.equal(Troops.decode(r.troops).Archers, 500)
	T.equal(r.next, 2)
	T.equal(r.dest, 3)
	T.equal(r.landAt, 94)
	T.equal(r.inBattle, false)
	T.equal(r.retreating, false)
	Snapshot.apply(client, delta)
	T.equal(#client.fleets, 1)

	-- sailing on changes nothing in the record (its progress goes with the positions); stopping does
	before = Snapshot.full(state)
	fleet.moveProgress = 3
	T.equal(Snapshot.diff(before, Snapshot.full(state)), nil, "only its progress changed")
	fleet.path, fleet.moveProgress = {}, 0
	local stopped = Snapshot.diff(before, Snapshot.full(state))
	T.equal(stopped and #stopped.fleets, 1, "it stopped")
	before = Snapshot.full(state)
	state.tick += 1
	T.equal(Snapshot.diff(before, Snapshot.full(state)), nil)
	local still = Snapshot.full(state).fleets[1]
	T.equal(still.next, 0)
	T.equal(still.dest, 1, "standing still, it is heading where it is")

	-- a blockade is on the province record
	before = Snapshot.full(state)
	state.provinces[11].blockade = 1
	local blockaded = Snapshot.diff(before, Snapshot.full(state))
	assert(blockaded, "expected a delta")
	T.equal(blockaded.provinces[1].blockade, 1)

	-- the fleet sinks: removed on the client
	before = Snapshot.full(state)
	state.fleets[fleet.id] = nil
	local sunk = Snapshot.diff(before, Snapshot.full(state))
	assert(sunk, "expected a delta")
	T.equal(sunk.removedFleets[1], fleet.id)
	Snapshot.apply(client, sunk)
	T.equal(#client.fleets, 0)
end)

T.test("sailing fleets ride the positions channel after the moving armies, zone to zone", function()
	local state = Match.new(Maps.get("skyshards"))
	local function ticksToEnter(_province: number, _army: any): number
		return 4
	end
	T.equal(#Snapshot.positions(state, ticksToEnter), 0, "nothing moves at the start")

	local sailing = Navy.spawn(state, 1, 1, 2)
	sailing.path, sailing.moveProgress = { 2, 3 }, 2
	Navy.spawn(state, 2, 4, 1) -- standing still: no position
	local fighting = Navy.spawn(state, 3, 5, 1)
	fighting.path, fighting.moveProgress, fighting.inBattle = { 6 }, 4, true -- held up by a sea battle
	local army = Army.spawn(state, 2, 3, 2000)
	army.path, army.moveProgress = { 4 }, 1
	local list = Snapshot.positions(state, ticksToEnter)
	T.equal(#list, 2, "the marching army and the sailing fleet")
	T.equal(list[1].fleet, false, "armies first")
	T.equal(list[1].id, army.id)
	T.equal(list[1].from, 3)
	T.equal(list[1].to, 4)
	T.near(list[1].progress, 0.25, 1e-9, "1 of 4 ticks")
	local p = list[2]
	T.equal(p.fleet, true)
	T.equal(p.id, sailing.id)
	T.equal(p.from, 1, "from its zone")
	T.equal(p.to, 2, "to the next zone on its route")
	T.near(p.progress, 2 / Config.Navy.MoveTicks, 1e-9, "the share of the way it has sailed")

	-- it sails on: a new position every tick and no delta; it arrives: a delta, and the next leg from 0
	local before = Snapshot.full(state)
	sailing.moveProgress += 1
	T.equal(Snapshot.diff(before, Snapshot.full(state)), nil)
	T.near(Snapshot.positions(state, ticksToEnter)[2].progress, 3 / Config.Navy.MoveTicks, 1e-9)
	sailing.zone, sailing.path, sailing.moveProgress = 2, { 3 }, 0
	local arrived = Snapshot.diff(before, Snapshot.full(state))
	T.equal(arrived and #arrived.fleets, 1, "a new zone and next zone")
	local leg = Snapshot.positions(state, ticksToEnter)[2]
	T.equal(leg.from, 2)
	T.equal(leg.to, 3)
	T.equal(leg.progress, 0)

	-- with the fog of war, only what the viewer sees (Sim.Fog): its own fleet and army, never one out of sight
	state.setup.settings.fog = true
	local function ids(viewer: number): { [string]: boolean }
		local out = {}
		for _, q in Snapshot.positions(state, ticksToEnter, viewer) do
			out[(if q.fleet then "fleet " else "army ") .. q.id] = true
		end
		return out
	end
	T.expect(ids(1)["fleet " .. sailing.id], "nation 1 sees its own fleet sailing")
	T.expect(ids(2)["army " .. army.id], "nation 2 sees its own army marching")
	local far = Fog.vision(state, 3)
	T.equal(ids(3)["fleet " .. sailing.id] == true, Fog.seesFleet(far, sailing), "nation 3: as far as it sees")
	state.setup.settings.fog = false
	T.equal(#Snapshot.positions(state, ticksToEnter, 3), 2, "the fog off: everyone sees every one")
end)

T.test("the snapshot holds only the fleets Navy.visible shows the viewer (the fog of war)", function()
	local state = Match.new(Maps.get("skyshards"))
	state.setup.settings.fog = true
	-- a zone off nation 1's coast, and one nation 1 doesn't see
	local seen = Fog.vision(state, 1)
	local near, far
	for id in state.zones do
		if seen.zones[id] then
			near = near or id
		else
			far = far or id
		end
	end
	assert(near and far, "skyshards has zones in and out of nation 1's sight")
	local mine = Navy.spawn(state, 1, far, 1)
	local close = Navy.spawn(state, 2, near, 1)
	local hidden = Navy.spawn(state, 2, far, 1)
	T.expect(Navy.visible(state, 1, mine), "your own fleet, wherever it is")
	T.expect(Navy.visible(state, 1, close), "a fleet off your coast")
	-- your fleet sees its zone: the other fleet there too
	T.expect(Navy.visible(state, 1, hidden), "a fleet in the zone your fleet is in")
	state.fleets[mine.id] = nil
	T.expect(not Navy.visible(state, 1, hidden), "a fleet out of sight")
	local owners = {}
	for _, f in Snapshot.full(state, nil, 1).fleets do
		owners[f.id] = true
	end
	T.expect(owners[close.id] and not owners[hidden.id], "the snapshot as nation 1 sees it")
	T.equal(#Snapshot.full(state).fleets, 2, "no viewer: every fleet")
	T.equal(#Snapshot.fleets(state, 2), 2, "nation 2 sees its own")
	state.setup.settings.fog = false
	T.equal(#Snapshot.full(state, nil, 1).fleets, 2, "the fog off: every fleet")
end)

T.test("rate limit allows 10 intents per second per player", function()
	local limit = RateLimit.new(10)
	for i = 1, 10 do
		T.expect(RateLimit.allow(limit, 1, 100 + i * 0.01), "intent " .. i)
	end
	T.expect(not RateLimit.allow(limit, 1, 100.5), "11th intent in the same second")
	T.expect(RateLimit.allow(limit, 2, 100.5), "other players are separate")
	T.expect(RateLimit.allow(limit, 1, 101.2), "the window slides")
end)

T.finish()
