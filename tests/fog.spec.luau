--!strict
-- Fog of war (docs/DESIGN.md "Fog of war"): what a nation sees, what its player's snapshot and deltas hold, which
-- events reach it, and bots and powers that keep to what they see.
local Army = require("../src/shared/Sim/Army")
local Bot = require("../src/shared/Sim/Bot")
local Commands = require("../src/shared/Sim/Commands")
local Config = require("../src/shared/Config")
local Diplomacy = require("../src/shared/Sim/Diplomacy")
local Fog = require("../src/shared/Sim/Fog")
local Maps = require("../src/shared/Maps")
local Match = require("../src/shared/Sim/Match")
local Navy = require("../src/shared/Sim/Navy")
local Rng = require("../src/shared/Sim/Rng")
local Settings = require("../src/shared/Sim/Settings")
local Snapshot = require("../src/shared/Snapshot")
local T = require("./TestKit")
local Types = require("../src/shared/Types")

type MatchState = Types.MatchState

local A, B, C = 1, 2, 3

local function fresh(): MatchState
	local state = Match.new(Maps.get("earth"))
	T.expect(state.setup.settings.fog == Config.Features.FogOfWar, "the match setting comes from Config")
	state.setup.settings.fog = true
	return state
end

-- A province `id` doesn't see (nobody's near it), owned by `owner` or neutral.
local function farFrom(state: MatchState, id: number, owner: number?): number
	local vision = Fog.vision(state, id)
	for pid, p in state.provinces do
		if not vision.provinces[pid] and p.owner == owner and p.terrain ~= "Mountain" then
			return pid
		end
	end
	error("no province out of sight")
end

local function armyIds(list: { Snapshot.ArmyRecord }): { [number]: boolean }
	local out = {}
	for _, a in list do
		out[a.id] = true
	end
	return out
end

T.test(
	"a nation sees its own land and the land next to it, where its armies stand, and the seas off its coasts",
	function()
		local state = fresh()
		local vision = Fog.vision(state, A)
		T.expect(not vision.all)
		for id, p in state.provinces do
			if p.owner == A then
				T.expect(vision.provinces[id], "its own province")
				for _, n in p.neighbors do
					T.expect(vision.provinces[n], "the land next to it")
				end
				for _, z in state.shores[id] or {} do
					T.expect(vision.zones[z], "the sea off its coast")
				end
			end
		end
		local far = farFrom(state, A, B)
		T.expect(not vision.provinces[far], "not far away")
		Army.spawn(state, A, far, 1000)
		vision = Fog.vision(state, A)
		T.expect(vision.provinces[far], "where its army stands")
		if Config.Fog.ArmySight == 0 then
			for _, n in state.provinces[far].neighbors do
				if state.provinces[n].owner ~= A then
					local nextToMine = false
					for _, m in state.provinces[n].neighbors do
						nextToMine = nextToMine or state.provinces[m].owner == A
					end
					T.expect((vision.provinces[n] == true) == nextToMine, "an army sees only where it stands")
				end
			end
		end
		-- a fleet sees the zone it is in
		local zone: number? = nil
		for id in state.zones do
			if not vision.zones[id] then
				zone = id
			end
		end
		assert(zone, "a zone out of sight")
		Navy.spawn(state, A, zone, 1)
		T.expect(Fog.vision(state, A).zones[zone], "where its fleet is")
	end
)

T.test(
	"allies share what they see; everyone sees it all with the fog off, from no nation or once eliminated",
	function()
		local state = fresh()
		local far = farFrom(state, A, B)
		T.expect(Fog.vision(state, B).provinces[far], "B sees its own land")
		assert(Diplomacy.ally(state, A, B))
		T.expect(Fog.vision(state, A).provinces[far], "A sees what its ally sees")
		T.equal(Fog.group(state, A), Fog.group(state, B), "one view for the alliance")
		T.expect(Fog.group(state, A) ~= Fog.group(state, C))
		T.expect(Fog.vision(state, 0).all, "no nation (a spectator, a Primordial in the menu): everything")
		state.nations[C].eliminated = true
		T.expect(Fog.vision(state, C).all and Fog.group(state, C) == "all", "a Primordial sees everything")
		state.setup.settings.fog = false
		T.expect(Fog.vision(state, A).all, "the fog off")
		T.equal(Settings.defaults().fog, Config.Features.FogOfWar, "on by default: one Config line")
	end
)

T.test("neutral garrisons stay in sight; other nations' armies and Rebels only where you see", function()
	local state = fresh()
	local vision = Fog.vision(state, A)
	local garrisonFar, rebelFar = farFrom(state, A, nil), farFrom(state, A, nil)
	local garrison: Types.Army? = nil
	for _, a in state.armies do
		if a.owner == 0 and a.location == garrisonFar then
			garrison = a
		end
	end
	assert(garrison, "neutral land has a garrison")
	T.expect(Fog.seesArmy(vision, garrison), "a garrison never moves: it stays public")
	local rebels = Army.spawn(state, 0, rebelFar, 3000)
	rebels.rebel = true
	T.expect(not Fog.seesArmy(vision, rebels), "Rebels out of sight")
	local enemy = Army.spawn(state, B, farFrom(state, A, B), 5000)
	T.expect(not Fog.seesArmy(vision, enemy), "an army out of sight")
	enemy.location = state.nations[A].capital
	T.expect(Fog.seesArmy(Fog.vision(state, A), enemy), "...in sight once it marches in")
end)

T.test(
	"a player's snapshot holds only what their nation sees, and its vision; deltas bring armies in and out",
	function()
		local state = fresh()
		local hiddenAt = farFrom(state, A, B)
		local enemy = Army.spawn(state, B, hiddenAt, 5000)
		local mine = Snapshot.full(state, nil, A)
		T.expect(not armyIds(mine.armies)[enemy.id], "an army out of sight isn't in the snapshot")
		T.expect(armyIds(Snapshot.full(state).armies)[enemy.id], "the all-seeing snapshot has it")
		local vision = mine.vision :: Types.VisionData
		T.expect(vision and not vision.all and #vision.provinces > 0, "the snapshot says what the nation sees")
		for i = 2, #vision.provinces do
			T.expect(vision.provinces[i - 1] < vision.provinces[i], "sorted ids")
		end
		-- Snapshot.view of the all-seeing snapshot is the same as the viewer's own
		local view = Snapshot.view(Snapshot.full(state), state, Fog.vision(state, A))
		T.equal(#view.armies, #mine.armies)
		T.equal(#view.fleets, #mine.fleets)
		T.equal(#(view.vision :: Types.VisionData).provinces, #vision.provinces)
		-- the army marches into sight, then out again
		local capital = state.nations[A].capital
		local before = Snapshot.full(state, nil, A)
		enemy.location = state.provinces[capital].neighbors[1]
		local seen = Snapshot.full(state, nil, A)
		local delta = Snapshot.diff(before, seen) :: Snapshot.DeltaData
		T.expect(delta and armyIds(delta.armies)[enemy.id], "it comes into sight")
		enemy.location = hiddenAt
		local gone = Snapshot.diff(seen, Snapshot.full(state, nil, A)) :: Snapshot.DeltaData
		T.expect(gone and table.find(gone.removedArmies, enemy.id) ~= nil, "it goes out of sight")
		-- the vision travels in a delta when it changes
		local ownArmy = Army.spawn(state, A, hiddenAt, 1000)
		local moved = Snapshot.diff(Snapshot.full(state, nil, A), Snapshot.full(state, nil, A))
		T.equal(moved, nil, "nothing changed")
		ownArmy.location = capital
		local back = Snapshot.full(state, nil, A)
		ownArmy.location = hiddenAt
		local out = Snapshot.diff(back, Snapshot.full(state, nil, A)) :: Snapshot.DeltaData
		T.expect(out and out.vision ~= nil, "my army marched off: what I see changed")
		local copy = Snapshot.apply(back, out)
		T.equal(#(copy.vision :: Types.VisionData).provinces, #(out.vision :: Types.VisionData).provinces)
		-- the fog off: no vision at all
		state.setup.settings.fog = false
		T.equal(Snapshot.full(state, nil, A).vision, nil)
		T.expect(armyIds(Snapshot.full(state, nil, A).armies)[enemy.id], "every army")
	end
)

T.test("a player's delta built on the shared one is the same as diffing their whole view", function()
	local state = fresh()
	state.tick = Config.Phases.PeaceEndTick + 10
	state.phase = "War"
	local all0 = Snapshot.full(state)
	local before = Snapshot.view(all0, state, Fog.vision(state, A))
	-- a tick's worth of changes: land changes hands, a war, an army walks into sight, one walks out of it
	local far = farFrom(state, A, B)
	local enemy = Army.spawn(state, B, far, 4000)
	local mine = Army.spawn(state, A, state.nations[A].capital, 2000)
	state.provinces[farFrom(state, A, C)].owner = B
	assert(Diplomacy.declareWar(state, B, C))
	local all1 = Snapshot.full(state)
	local shared = Snapshot.diff(all0, all1)
	local mid = Snapshot.view(all1, state, Fog.vision(state, A))
	enemy.location = state.provinces[state.nations[A].capital].neighbors[1]
	mine.location = far
	local all2 = Snapshot.full(state)
	local after = Snapshot.view(all2, state, Fog.vision(state, A))
	local function same(x: Snapshot.DeltaData?, y: Snapshot.DeltaData?)
		T.expect((x == nil) == (y == nil), "both deltas or neither")
		if x and y then
			T.equal(#x.provinces, #y.provinces, "provinces")
			T.equal(#x.nations, #y.nations, "nations")
			T.equal(#x.armies, #y.armies, "armies")
			T.equal(#x.removedArmies, #y.removedArmies, "armies gone")
			T.equal(x.diplomacy ~= nil, y.diplomacy ~= nil, "diplomacy")
			T.equal(x.vision ~= nil, y.vision ~= nil, "vision")
		end
	end
	same(Snapshot.diffView(before, mid, shared, {}), Snapshot.diff(before, mid, {}))
	same(Snapshot.diffView(mid, after, Snapshot.diff(all1, all2), {}), Snapshot.diff(mid, after, {}))
	T.equal(Snapshot.diffView(after, after, nil, {}), nil, "nothing changed: no delta")
end)

T.test("events that would give a unit away reach only those who see where they happen (or fought there)", function()
	local state = fresh()
	local vision = Fog.vision(state, A)
	local far = farFrom(state, A, B)
	local near = state.nations[A].capital
	local function ev(kind: string, a: number, b: number, province: number): Types.MatchEvent
		return { kind = kind, a = a, b = b, province = province }
	end
	T.expect(not Fog.seesEvent(vision, ev("Merged", 7, 8, far)), "a merge out of sight")
	T.expect(Fog.seesEvent(vision, ev("Merged", 7, 8, near)), "a merge in sight")
	T.expect(not Fog.seesEvent(vision, ev("BattleEnded", B, C, far)), "someone else's battle out of sight")
	T.expect(Fog.seesEvent(vision, ev("BattleEnded", A, C, far)), "my own battle, wherever it was")
	T.expect(Fog.seesEvent(vision, ev("ProvinceTaken", B, C, far)), "who owns what stays public")
	T.expect(Fog.seesEvent(vision, ev("WarDeclared", B, C, 0)))
	local list = Snapshot.events({ ev("Merged", 1, 2, far), ev("PeaceMade", B, C, 0) }, vision)
	T.equal(#list, 1, "one event left")
	T.equal(list[1].kind, "PeaceMade")
end)

T.test("bots and powers keep to what their nation sees", function()
	local state = fresh()
	state.tick = Config.Phases.PeaceEndTick + 10
	state.phase = "War"
	local far = farFrom(state, A, B)
	assert(Diplomacy.declareWar(state, A, B))
	local hidden = Army.spawn(state, B, far, 20000)
	-- a nation can't Meteor an army it can't see: the server answers as if there were none
	state.nations[A].charges = 5
	local ok, err = Commands.apply(state, A, { kind = "Power", power = "Meteor", target = hidden.id })
	T.expect(not ok and err == "UnknownArmy", "out of sight")
	-- a bot never plans one either
	for _, c in Bot.plan(state, A, Rng.new(1), "Normal") do
		T.expect(not (c.kind == "Power" and (c :: any).target == hidden.id), "the bot can't see it")
	end
	-- in sight, it can
	hidden.location = state.provinces[state.nations[A].capital].neighbors[1]
	local found = false
	for _, c in Bot.plan(state, A, Rng.new(1), "Normal") do
		found = found or (c.kind == "Power" and (c :: any).target == hidden.id)
	end
	T.expect(found, "the bot Meteors the big army it sees")
	T.expect(
		(Commands.apply(state, A, { kind = "Power", power = "Meteor", target = hidden.id })),
		"and the server takes it"
	)
end)

T.finish()
