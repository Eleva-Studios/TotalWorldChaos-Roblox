--!strict
-- The EU4 pack, stage 3: missions (docs/DESIGN.md "Missions"). When goals come, what each kind asks and pays, when a
-- goal goes, the match setting, the bots, what a player's client is told, and the words.
local Bot = require("../src/shared/Sim/Bot")
local Commands = require("../src/shared/Sim/Commands")
local Config = require("../src/shared/Config")
local Diplomacy = require("../src/shared/Sim/Diplomacy")
local Economy = require("../src/shared/Sim/Economy")
local Maps = require("../src/shared/Maps")
local Match = require("../src/shared/Sim/Match")
local MissionText = require("../src/shared/Flavour/Missions")
local Missions = require("../src/shared/Sim/Missions")
local Rng = require("../src/shared/Sim/Rng")
local Sandbox = require("../src/shared/Sim/Sandbox")
local Settings = require("../src/shared/Sim/Settings")
local T = require("./TestKit")
local Tick = require("../src/shared/Sim/Tick")
local Tutorial = require("../src/shared/Sim/Tutorial")
local Types = require("../src/shared/Types")

type MatchState = Types.MatchState

local M = Config.Missions
local A, B = 1, 2

local function fresh(mapId: string?): MatchState
	return Match.new(Maps.get(mapId or "earth"))
end

local function war(state: MatchState)
	state.tick = Config.Phases.PeaceEndTick + 1
	state.phase = "War"
end

-- Give nation `id` exactly this goal (no other, and no new ones coming).
local function give(
	state: MatchState,
	id: number,
	kind: string,
	target: number,
	base: number,
	need: number
): Types.Mission
	local m: Types.Mission = {
		id = state.nextMissionId,
		kind = kind,
		target = target,
		base = base,
		need = need,
		untilTick = state.tick + M.Ticks,
	}
	state.nextMissionId += 1
	state.missions[id] = { missions = { m }, refills = {}, last = nil, done = 0 }
	return m
end

local function kinds(state: MatchState, id: number): { [string]: boolean }
	local out = {}
	for _, m in Missions.list(state, id) do
		T.expect(not out[m.kind], "one goal of each kind at a time: " .. m.kind)
		out[m.kind] = true
	end
	return out
end

local function forts(state: MatchState, id: number): number
	local n = 0
	for _, p in state.provinces do
		if p.owner == id and p.building == "Fort" then
			n += 1
		end
	end
	return n
end

-- Make nation `other` a neighbour of `id`: one of the neutral provinces next to `id`'s land becomes `other`'s.
local function neighbourOf(state: MatchState, id: number, other: number): (number, number)
	local p = Missions.takeTargets(state, id)[1]
	state.provinces[p].owner = other
	return other, p
end

-- Timing ---------------------------------------------------------------------------------------------------------------

T.test("each nation gets three goals of three kinds at its own time, in Peace too", function()
	local state = fresh()
	local rng = Rng.new(3)
	state.tick = M.FirstTicks - 1
	Missions.step(state, rng)
	T.equal(#Missions.list(state, A), 0, "not yet")
	state.tick = M.FirstTicks
	Missions.step(state, rng)
	T.equal(state.phase, "Peace")
	T.equal(#Missions.list(state, A), M.Slots, "nation 1's goals")
	kinds(state, A)
	T.equal(#Missions.list(state, B), 0, "nation 2's come a moment later")
	state.tick += M.StaggerTicks
	Missions.step(state, rng)
	T.equal(#Missions.list(state, B), M.Slots)
	for _, m in Missions.list(state, A) do
		T.equal(m.untilTick, M.FirstTicks + M.Ticks, "each runs for a few minutes")
		T.expect(Missions.eligible(state, A, m.kind), m.kind .. " is a goal A may get")
	end
end)

T.test("a Take goal names a province next to your land: neutral in Peace, later anyone's but an ally's", function()
	local state = fresh()
	local mine: { [number]: boolean } = {}
	for id, p in state.provinces do
		if p.owner == A then
			mine[id] = true
		end
	end
	local function nextToMine(id: number): boolean
		for _, n in state.provinces[id].neighbors do
			if mine[n] then
				return true
			end
		end
		return false
	end
	local peace = Missions.takeTargets(state, A)
	T.expect(#peace > 0, "neutral land to take")
	for _, id in peace do
		local p = state.provinces[id]
		T.expect(p.owner == nil and p.terrain ~= "Mountain" and nextToMine(id), "neutral, ownable and next door")
	end
	local other, theirs = neighbourOf(state, A, B)
	T.expect(table.find(Missions.takeTargets(state, A), theirs) == nil, "no other nation's land in Peace (no wars yet)")
	war(state)
	T.expect(table.find(Missions.takeTargets(state, A), theirs) ~= nil, "a neighbour's province once wars are on")
	assert(Diplomacy.ally(state, A, other))
	T.expect(table.find(Missions.takeTargets(state, A), theirs) == nil, "never an ally's")
end)

-- Rewards ----------------------------------------------------------------------------------------------------------------

T.test("a goal done pays its reward on the spot; its slot gets a goal of another kind after a short wait", function()
	local state = fresh()
	local rng = Rng.new(5)
	local capital = state.nations[A].capital
	local level = state.provinces[capital].development
	give(state, A, "Grow", capital, level, level + 1)
	local have, need = Missions.progress(state, A, Missions.list(state, A)[1])
	T.expect(have == 0 and need == 1, "0 of 1 level")
	local gold = state.nations[A].gold
	Missions.step(state, rng)
	T.equal(#Missions.list(state, A), 1, "not done yet")
	state.provinces[capital].development += 1
	Missions.step(state, rng)
	T.equal(state.nations[A].gold, gold + M.Kinds.Grow.reward.gold, "paid on the spot")
	local b = state.missions[A]
	T.expect(b.last and b.last.done and b.last.kind == "Grow", "the last goal closed, done")
	T.equal(b.done, 1)
	T.equal(#Missions.list(state, A), 0, "the slot waits")
	state.tick += M.RefillTicks - 1
	Missions.step(state, rng)
	T.equal(#Missions.list(state, A), 0)
	state.tick += 1
	Missions.step(state, rng)
	local new = Missions.list(state, A)
	T.equal(#new, 1, "a new goal")
	T.expect(new[1].kind ~= "Grow", "of another kind")
end)

T.test("Fort, Win and Take count from when the goal came; regiments go to the capital", function()
	local state = fresh()
	local rng = Rng.new(1)
	local nation = state.nations[A]
	give(state, A, "Fort", 0, forts(state, A), forts(state, A) + M.Kinds.Fort.forts)
	local spot: number? = nil
	for id, p in state.provinces do
		if p.owner == A and p.building == "None" then
			spot = id
		end
	end
	assert(spot, "a free plot")
	state.provinces[spot].building = "Fort"
	local manpower = nation.manpower
	Missions.step(state, rng)
	T.equal(nation.manpower, manpower + M.Kinds.Fort.reward.manpower, "a fort built: manpower")

	nation.battlesWon = 3
	give(state, A, "Win", 0, 3, 3 + M.Kinds.Win.battles)
	nation.battlesWon = 3 + M.Kinds.Win.battles - 1
	Missions.step(state, rng)
	T.equal(#Missions.list(state, A), 1, "one more battle to win")
	local capital = nation.capital
	local function menAtCapital(): number
		local n = 0
		for _, a in state.armies do
			if a.owner == A and a.location == capital then
				n += a.men
			end
		end
		return n
	end
	local before = menAtCapital()
	nation.battlesWon = 3 + M.Kinds.Win.battles
	Missions.step(state, rng)
	T.equal(menAtCapital(), before + M.Kinds.Win.reward.regiments * Config.Army.MenPerRegiment, "regiments at home")

	local target = Missions.takeTargets(state, A)[1]
	give(state, A, "Take", target, 0, 1)
	local gold = nation.gold
	state.provinces[target].owner = A
	Missions.step(state, rng)
	T.equal(nation.gold, gold + M.Kinds.Take.reward.gold, "the province taken: gold")
end)

T.test("a goal out of time, or one that can't be done any more, goes with nothing paid", function()
	local state = fresh()
	local rng = Rng.new(2)
	war(state)
	local other, theirs = neighbourOf(state, A, B)
	give(state, A, "Take", theirs, 0, 1)
	local gold = state.nations[A].gold
	assert(Diplomacy.ally(state, A, other))
	Missions.step(state, rng)
	local b = state.missions[A]
	T.expect(#b.missions == 0 and b.last and not b.last.done, "their province is an ally's now: the goal goes")
	T.equal(state.nations[A].gold, gold, "nothing paid")
	T.equal(#b.refills, 1, "its slot gets a new goal later")

	local capital = state.nations[A].capital
	give(state, A, "Grow", capital, 1, 2)
	state.provinces[capital].owner = B
	T.expect(not Missions.possible(state, A, Missions.list(state, A)[1]), "the capital lost")
	Missions.step(state, rng)
	T.equal(#Missions.list(state, A), 0)
	state.provinces[capital].owner = A

	local m = give(state, A, "Win", 0, 0, 2)
	state.tick = m.untilTick
	Missions.step(state, rng)
	T.expect(#Missions.list(state, A) == 0 and not state.missions[A].last.done, "out of time")
end)

T.test("Ally: done when the nation joins an alliance; never dealt to a nation in one", function()
	local state = fresh()
	give(state, A, "Ally", 0, 0, 1)
	local gold = state.nations[A].gold
	assert(Diplomacy.ally(state, A, B))
	Missions.step(state, Rng.new(1))
	T.equal(state.nations[A].gold, gold + M.Kinds.Ally.reward.gold)
	T.expect(not Missions.eligible(state, A, "Ally"), "already in an alliance")
	T.expect(Missions.eligible(state, 3, "Ally"), "a nation with no alliance may get one")
end)

-- Settings ---------------------------------------------------------------------------------------------------------------

T.test("the setting turns missions off (not a custom rule); the tutorial has none, a sandbox has no fog", function()
	local state = fresh()
	state.setup.settings.missions = false
	state.tick = M.FirstTicks + 20
	Missions.step(state, Rng.new(1))
	T.equal(next(state.missions), nil, "no goals")
	T.equal(Settings.defaults().missions, Config.Features.Missions)
	local s = Settings.defaults()
	T.expect(Settings.set(s, "missions", false, 0, {}))
	T.expect(Settings.set(s, "fog", false, 0, {}))
	T.expect(not Settings.set(s, "fog", "no", 0, {}), "on or off only")
	T.expect(Settings.isStandard(s), "off isn't a custom rule: full rewards")
	local tutorial = fresh(Config.Tutorial.Map)
	Tutorial.setup(tutorial, Config.Tutorial.PlayerSlot)
	T.equal(tutorial.setup.settings.missions, false, "the tutorial plays without missions")
	T.equal(tutorial.setup.settings.fog, false, "...and with the whole map in sight")
	T.equal(Sandbox.setup().settings.fog, false, "a sandbox world: every army in sight")
end)

T.test("an eliminated nation loses its goals; none come once the match is over", function()
	local state = fresh()
	local rng = Rng.new(4)
	state.tick = M.FirstTicks + 20
	Missions.step(state, rng)
	T.expect(#Missions.list(state, B) == M.Slots)
	state.nations[B].eliminated = true
	Missions.step(state, rng)
	T.equal(#Missions.list(state, B), 0, "gone with the nation")
	local next = state.nextMissionId
	state.phase = "Results"
	state.result = { kind = "Score", winners = { A }, scores = {}, endedAt = state.tick }
	state.missions[A].missions = {}
	state.missions[A].refills = { state.tick }
	for _ = 1, M.RefillTicks + 1 do
		Tick.advance(state, rng)
	end
	T.equal(state.nextMissionId, next, "no goals on Results")
end)

-- Bots -------------------------------------------------------------------------------------------------------------------

T.test("bots lean towards their goals: the capital's next level, a fort on the border, the Take province", function()
	local state = fresh()
	local capital = state.nations[A].capital
	local level = state.provinces[capital].development
	give(state, A, "Grow", capital, level, level + 1)
	local order = Missions.botOrder(state, A, 1000)
	T.expect(order and order.kind == "Develop" and (order :: any).province == capital, "develop the capital")
	T.equal(Missions.botOrder(state, A, Economy.developCost(level) - 1), nil, "only when it can pay")
	give(state, A, "Fort", 0, 0, 1)
	local fort = Missions.botOrder(state, A, 1000) :: any
	T.expect(fort and fort.kind == "Build" and fort.building == "Fort", "build a fort")
	T.expect((Commands.apply(state, A, fort)), "the server takes it")
	T.equal(Missions.goals(state, A).fort, true)
	local target = Missions.takeTargets(state, A)[1]
	give(state, A, "Take", target, 0, 1)
	T.equal(Missions.goals(state, A).take, target, "the province a bot's stacks look at first")
	state.setup.settings.missions = false
	T.equal(Missions.goals(state, A).take, nil, "no goals with the setting off")
end)

T.test("a whole match through the tick loop with bots: goals get done and replaced, three at a time", function()
	local state = fresh("eldmoor")
	local rng, botRng = Rng.new(17), Rng.new(18)
	local schedule = Bot.newSchedule()
	local queued: { Bot.Order } = {}
	for _ = 1, 12 * 60 do
		for _, order in queued do
			Commands.apply(state, order.nation, order.command)
		end
		Tick.advance(state, rng)
		queued = Bot.step(schedule, state, botRng, "Normal")
	end
	local done, byKind = 0, {}
	for id, nation in state.nations do
		local b = state.missions[id]
		if not nation.eliminated then
			T.expect(#b.missions <= M.Slots, "never more than three")
			kinds(state, id)
		end
		done += b.done
		if b.last and b.last.done then
			byKind[b.last.kind] = true
		end
	end
	T.expect(done >= 20, "the bots finished goals in 12 minutes (" .. done .. ")")
	T.expect(next(byKind) ~= nil, "of some kinds")
end)

-- The client -------------------------------------------------------------------------------------------------------------

T.test("a player's client hears about its own nation's goals only, as flat records", function()
	local state = fresh()
	state.tick = M.FirstTicks + 20
	Missions.step(state, Rng.new(9))
	local mine = Missions.view(state, A)
	T.equal(#mine.missions, M.Slots)
	for i, m in mine.missions do
		local real = Missions.list(state, A)[i]
		T.expect(m.id == real.id and m.kind == real.kind and m.target == real.target, "the goal as it is")
		for key, value in m :: { [string]: any } do
			T.expect(type(value) ~= "table", "flat for the network: " .. key)
		end
	end
	local theirs = Missions.view(state, B)
	for _, m in theirs.missions do
		for _, n in mine.missions do
			T.expect(m.id ~= n.id, "nothing about another nation's goals")
		end
	end
	T.equal(#Missions.view(state, nil).missions, 0, "a spectator hears nothing")
	local key = Missions.key(mine)
	local capital = state.nations[A].capital
	give(state, A, "Grow", capital, state.provinces[capital].development, state.provinces[capital].development + 1)
	local before = Missions.key(Missions.view(state, A))
	T.expect(before ~= key, "a new goal: a new view")
	state.provinces[capital].development += 1
	T.expect(Missions.key(Missions.view(state, A)) ~= before, "progress: a new view")
	Missions.step(state, Rng.new(1))
	local after = Missions.view(state, A)
	T.expect(after.lastDone and after.lastKind == "Grow" and after.lastTarget == capital, "the last goal, done")
end)

T.test("the words: every goal short enough with the longest province name, and clean", function()
	local banned = { string.reverse("dog"), string.reverse("enivid"), string.reverse("yloh"), "damn", "stupid" }
	local longest = ""
	for _, mapId in Maps.ids do
		for _, p in Maps.get(mapId).provinces do
			if #p.name > #longest then
				longest = p.name
			end
		end
	end
	for _, kind in Missions.KINDS do
		T.expect(MissionText.ICONS[kind] ~= nil, kind .. " has an icon")
		T.expect(M.Kinds[kind] ~= nil and M.Kinds[kind].reward ~= nil, kind .. " has a reward")
		for _, count in { 1, 2, 3 } do
			local words = MissionText.goal(kind, longest, count)
			T.expect(#words <= MissionText.MAX, "too long: " .. words)
			for _, word in banned do
				T.expect(string.find(string.lower(words), word, 1, true) == nil, "banned word in: " .. words)
			end
		end
	end
	T.equal(MissionText.goal("Win", nil, 2), "Win 2 battles")
	T.equal(MissionText.goal("Fort", nil, 1), "Build a fort")
	T.equal(MissionText.goal("Take", "Kent", 1), "Take Kent")
	-- a reward is gold, manpower or regiments only, about 30-60 gold's worth
	local W = Config.Bots.EventWorth
	for _, kind in Missions.KINDS do
		local r = Missions.reward(kind)
		local worth = (r.gold or 0) + (r.manpower or 0) * W.Manpower + (r.regiments or 0) * W.Regiment
		T.expect(worth >= 30 and worth <= 60, kind .. " is worth " .. worth .. " gold")
	end
end)

T.finish()
