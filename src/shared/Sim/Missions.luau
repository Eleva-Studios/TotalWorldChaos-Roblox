--!strict
-- The EU4 pack, stage 3: missions (docs/DESIGN.md "Missions"). Every living nation has a few short, concrete goals at
-- a time (Config.Missions.Slots), each of another kind:
--   Take  take a named province next to your land (in Peace a neutral one; later anyone's but an ally's)
--   Grow  develop your capital one level
--   Fort  build a fort
--   Win   win battles
--   Ally  join an alliance
-- A goal pays its reward the tick it is done (gold, manpower, or regiments of the race's line troop at the capital:
-- Config.Missions.Kinds). A finished goal is replaced by one of another kind after Config.Missions.RefillTicks; so is
-- one that ran out of time (Config.Missions.Ticks) or can't be done any more (its province went to an ally, the
-- capital fell), with nothing paid. Players and bots get them by the same rules. They are private to each nation: the
-- server tells each player their own nation's (Replicator.sendMissions), never in the delta everyone gets. A match
-- setting (MatchSettings.missions, Config.Features.Missions). No command: the server sees a goal done and pays it.
-- Pure: randomness from the seeded Rng.

local Army = require("./Army")
local Config = require("../Config")
local Diplomacy = require("./Diplomacy")
local Economy = require("./Economy")
local Rng = require("./Rng")
local Types = require("../Types")

type MatchState = Types.MatchState
type Mission = Types.Mission
type MissionBoard = Types.MissionBoard

local M = Config.Missions
local ACTIVE_PHASES = { Peace = true, War = true, Cataclysm = true }

local Missions = {}

-- Every kind, in the order the UI lists them.
Missions.KINDS = { "Take", "Grow", "Fort", "Win", "Ally" } :: { string }

-- What a finished goal pays (Config.Missions.Kinds[kind].reward).
export type Reward = { gold: number?, manpower: number?, regiments: number? }

-- Is the setting on in this match?
function Missions.enabled(state: MatchState): boolean
	return state.setup.settings.missions == true
end

local function sortedKeys(t: { [number]: any }): { number }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

local function living(state: MatchState, nationId: number): boolean
	local nation = state.nations[nationId]
	return nation ~= nil and not nation.eliminated
end

-- The nation's capital while it still holds it.
local function capitalOf(state: MatchState, nationId: number): number?
	local id = state.nations[nationId].capital
	local p = state.provinces[id]
	return if p and p.owner == nationId then id else nil
end

local function forts(state: MatchState, nationId: number): number
	local n = 0
	for _, p in state.provinces do
		if p.owner == nationId and p.building == "Fort" then
			n += 1
		end
	end
	return n
end

local function hasFreePlot(state: MatchState, nationId: number): boolean
	for _, p in state.provinces do
		if p.owner == nationId and p.building == "None" then
			return true
		end
	end
	return false
end

-- Could this nation take this province? Not its own, not a mountain, not an ally's or a truce partner's; in Peace,
-- neutral land only (no wars yet).
local function takeable(state: MatchState, nationId: number, provinceId: number): boolean
	local p = state.provinces[provinceId]
	if p == nil or p.terrain == "Mountain" or p.owner == nationId then
		return false
	end
	local owner = p.owner
	if owner == nil then
		return true
	end
	return state.phase ~= "Peace"
		and living(state, owner)
		and not Diplomacy.allied(state, nationId, owner)
		and not Diplomacy.hasTruce(state, nationId, owner)
end

-- The provinces a Take goal could name: next to the nation's land and takeable. Sorted.
function Missions.takeTargets(state: MatchState, nationId: number): { number }
	local seen: { [number]: boolean } = {}
	local out = {}
	for _, id in sortedKeys(state.provinces) do
		if state.provinces[id].owner == nationId then
			for _, n in state.provinces[id].neighbors do
				if not seen[n] and takeable(state, nationId, n) then
					seen[n] = true
					table.insert(out, n)
				end
			end
		end
	end
	table.sort(out)
	return out
end

-- Could this nation get a goal of this kind now?
function Missions.eligible(state: MatchState, nationId: number, kind: string): boolean
	if kind == "Take" then
		return #Missions.takeTargets(state, nationId) > 0
	elseif kind == "Grow" then
		local capital = capitalOf(state, nationId)
		return capital ~= nil and state.provinces[capital].development < Config.Economy.MaxDevelopment
	elseif kind == "Fort" then
		return hasFreePlot(state, nationId)
	elseif kind == "Win" then
		return true
	elseif kind == "Ally" then
		if state.nations[nationId].allianceId ~= nil then
			return false
		end
		for _, id in sortedKeys(state.nations) do
			if id ~= nationId and living(state, id) and not Diplomacy.atWar(state, nationId, id) then
				return true
			end
		end
	end
	return false
end

-- How far along a goal is: what the nation has towards it and what it needs (both counted from when it came).
function Missions.progress(state: MatchState, nationId: number, m: Mission): (number, number)
	local nation = state.nations[nationId]
	if m.kind == "Take" then
		local p = state.provinces[m.target]
		return if p and p.owner == nationId then 1 else 0, 1
	elseif m.kind == "Grow" then
		local p = state.provinces[m.target]
		local level = if p and p.owner == nationId then p.development else m.base
		return math.max(0, level - m.base), m.need - m.base
	elseif m.kind == "Fort" then
		return math.max(0, forts(state, nationId) - m.base), m.need - m.base
	elseif m.kind == "Win" then
		return math.max(0, nation.battlesWon - m.base), m.need - m.base
	end
	return if nation.allianceId ~= nil then 1 else 0, 1
end

function Missions.done(state: MatchState, nationId: number, m: Mission): boolean
	local have, need = Missions.progress(state, nationId, m)
	return have >= need
end

-- Can the goal still be done? A Take goal's province gone to an ally (or a truce partner), a Grow goal's capital lost.
function Missions.possible(state: MatchState, nationId: number, m: Mission): boolean
	if m.kind == "Take" then
		local p = state.provinces[m.target]
		local owner = if p then p.owner else nil
		return p ~= nil
			and (
				owner == nil
				or owner == nationId
				or not (Diplomacy.allied(state, nationId, owner) or Diplomacy.hasTruce(state, nationId, owner))
			)
	elseif m.kind == "Grow" then
		local p = state.provinces[m.target]
		return p ~= nil and p.owner == nationId
	end
	return true
end

-- What a goal of this kind pays.
function Missions.reward(kind: string): Reward
	return (M.Kinds :: any)[kind].reward
end

local function boardOf(state: MatchState, nationId: number): MissionBoard
	local boards = state.missions
	local b = boards[nationId]
	if b == nil then
		local first = M.FirstTicks + (nationId - 1) * M.StaggerTicks
		local refills = {}
		for _ = 1, M.Slots do
			table.insert(refills, first)
		end
		b = { missions = {}, refills = refills, closed = {}, last = nil, done = 0 }
		boards[nationId] = b
	end
	return b
end

-- The nation's goals now (empty without any).
function Missions.list(state: MatchState, nationId: number): { Mission }
	local b = state.missions and state.missions[nationId]
	return if b then b.missions else {}
end

-- Give this nation a new goal, of a kind it may get and doesn't have (another than `avoid`, the one just closed, when
-- there is a choice). nil when there is none it may get.
function Missions.deal(state: MatchState, nationId: number, rng: Rng.Rng, avoid: string?): Mission?
	local b = boardOf(state, nationId)
	local held: { [string]: boolean } = {}
	for _, m in b.missions do
		held[m.kind] = true
	end
	local kinds, others = {}, {}
	for _, kind in Missions.KINDS do
		if not held[kind] and Missions.eligible(state, nationId, kind) then
			table.insert(kinds, kind)
			if kind ~= avoid then
				table.insert(others, kind)
			end
		end
	end
	if #others > 0 then
		kinds = others
	end
	if #kinds == 0 then
		return nil
	end
	local kind = kinds[Rng.int(rng, 1, #kinds)]
	local def = (M.Kinds :: any)[kind]
	local nation = state.nations[nationId]
	local target, base, need = 0, 0, 1
	if kind == "Take" then
		local options = Missions.takeTargets(state, nationId)
		target = options[Rng.int(rng, 1, #options)]
	elseif kind == "Grow" then
		target = capitalOf(state, nationId) :: number
		base = state.provinces[target].development
		need = math.min(Config.Economy.MaxDevelopment, base + def.levels)
	elseif kind == "Fort" then
		base = forts(state, nationId)
		need = base + def.forts
	elseif kind == "Win" then
		base = nation.battlesWon
		need = base + def.battles
	end
	local m: Mission = {
		id = state.nextMissionId,
		kind = kind,
		target = target,
		base = base,
		need = need,
		untilTick = state.tick + M.Ticks,
	}
	state.nextMissionId += 1
	table.insert(b.missions, m)
	return m
end

local function pay(state: MatchState, nationId: number, reward: Reward)
	local nation = state.nations[nationId]
	nation.gold += reward.gold or 0
	nation.manpower += reward.manpower or 0
	local regiments = reward.regiments or 0
	local capital = capitalOf(state, nationId)
	if regiments > 0 and capital then
		Army.reinforce(state, nationId, capital, regiments * Config.Army.MenPerRegiment)
	end
end

-- Tick order step 8: goals that are done pay their reward; goals done, out of time or impossible make room for a new
-- one after Config.Missions.RefillTicks; empty slots whose time has come get a goal (in Peace, War and the
-- Cataclysm). An eliminated nation's goals go with it.
function Missions.step(state: MatchState, rng: Rng.Rng)
	if not Missions.enabled(state) then
		return
	end
	if state.missions == nil then
		state.missions = {}
	end
	if state.nextMissionId == nil then
		state.nextMissionId = 1
	end
	for _, id in sortedKeys(state.nations) do
		local b = boardOf(state, id)
		if not living(state, id) then
			b.missions = {}
			b.refills = {}
			continue
		end
		local kept = {}
		for _, m in b.missions do
			local finished = Missions.done(state, id, m)
			if finished or state.tick >= m.untilTick or not Missions.possible(state, id, m) then
				if finished then
					pay(state, id, Missions.reward(m.kind))
					b.done += 1
				end
				local outcome = { id = m.id, kind = m.kind, target = m.target, done = finished }
				table.insert(b.closed, outcome)
				b.last = outcome
				table.insert(b.refills, state.tick + M.RefillTicks)
			else
				table.insert(kept, m)
			end
		end
		b.missions = kept
		if not ACTIVE_PHASES[state.phase] then
			continue
		end
		table.sort(b.refills)
		local waiting = {}
		for _, at in b.refills do
			if state.tick >= at and #b.missions < M.Slots then
				local avoid = if b.last then b.last.kind else nil
				if Missions.deal(state, id, rng, avoid) == nil then
					table.insert(waiting, state.tick + M.RefillTicks) -- nothing it may get now: try again later
				end
			else
				table.insert(waiting, at)
			end
		end
		b.refills = waiting
	end
end

-- Studio's DevMissions switch (DevService, docs/STUDIO.md): every nation's empty slots fill on the next step.
function Missions.soon(state: MatchState)
	for _, id in sortedKeys(state.nations) do
		local b = boardOf(state, id)
		for i in b.refills do
			b.refills[i] = state.tick
		end
	end
end

-- Bots -----------------------------------------------------------------------------------------------------------------

-- What a bot's plan leans towards for its goals (Sim.Bot): the province of its Take goal, whether it wants its capital
-- developed (Grow) and a fort built (Fort).
export type Goals = { take: number?, grow: number?, fort: boolean }

function Missions.goals(state: MatchState, nationId: number): Goals
	local goals: Goals = { take = nil, grow = nil, fort = false }
	if not Missions.enabled(state) then
		return goals
	end
	for _, m in Missions.list(state, nationId) do
		if m.kind == "Take" then
			goals.take = m.target
		elseif m.kind == "Grow" then
			goals.grow = m.target
		elseif m.kind == "Fort" then
			goals.fort = true
		end
	end
	return goals
end

-- What a bot builds first for its goals when `spare` gold pays for it (Sim.Bot's build step): its capital's next
-- level for a Grow goal, else a fort for a Fort goal (on a free plot facing another nation if it has one, the most
-- developed, lowest id on ties). nil when neither applies.
function Missions.botOrder(state: MatchState, nationId: number, spare: number): Types.Command?
	local goals = Missions.goals(state, nationId)
	local grow = goals.grow
	if grow then
		local p = state.provinces[grow]
		if
			p.owner == nationId
			and p.development < Config.Economy.MaxDevelopment
			and Economy.developCost(p.development) <= spare
		then
			return { kind = "Develop", province = grow }
		end
	end
	if goals.fort then
		local cost = Economy.buildingCost("Fort", state.nations[nationId].race) :: number
		if cost > spare then
			return nil
		end
		local best: number?, bestScore = nil, -math.huge
		for _, id in sortedKeys(state.provinces) do
			local p = state.provinces[id]
			if p.owner == nationId and p.building == "None" then
				local border = false
				for _, n in p.neighbors do
					local owner = state.provinces[n].owner
					border = border or (owner ~= nil and owner ~= nationId)
				end
				local score = (if border then 10 else 0) + p.development
				if score > bestScore then
					best, bestScore = id, score
				end
			end
		end
		if best then
			return { kind = "Build", province = best, building = "Fort" }
		end
	end
	return nil
end

-- The client ------------------------------------------------------------------------------------------------------------

-- What this nation's player is told (Types.MissionView): its goals with their progress, and the last one closed (for
-- the toast). Sent to that player alone (Replicator.sendMissions).
function Missions.view(state: MatchState, nationId: number?): Types.MissionView
	local b = if nationId and state.missions and Missions.enabled(state) then state.missions[nationId] else nil
	local list = {}
	if b and nationId then
		for _, m in b.missions do
			local have, need = Missions.progress(state, nationId, m)
			table.insert(list, {
				id = m.id,
				kind = m.kind,
				target = m.target,
				have = have,
				need = need,
				untilTick = m.untilTick,
			})
		end
	end
	local last = if b then b.last else nil
	return {
		missions = list,
		lastId = if last then last.id else 0,
		lastKind = if last then last.kind else "",
		lastTarget = if last then last.target else 0,
		lastDone = if last then last.done else false,
	}
end

-- A short text form of a view, to tell when it changed (Replicator sends a view only then).
function Missions.key(view: Types.MissionView): string
	local parts = { tostring(view.lastId) }
	for _, m in view.missions do
		table.insert(parts, string.format("%d:%d/%d", m.id, m.have, m.need))
	end
	return table.concat(parts, ",")
end

return Missions
