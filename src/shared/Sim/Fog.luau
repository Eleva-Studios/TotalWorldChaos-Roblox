--!strict
-- Fog of war (docs/DESIGN.md "Fog of war"): what each nation sees of the other nations' armies and fleets. A nation
-- sees its own provinces and the land Config.Fog.LandSight steps round them, the provinces its armies stand in (and
-- Config.Fog.ArmySight steps round them), the sea zones off its coasts and the zones its fleets are in; allies share
-- what they see. Map ownership, the nations and diplomacy stay public: the fog hides only other nations' armies,
-- fleets and Rebels outside that vision (and the events that would give them away). Neutral garrisons never move and
-- stay public. A match setting (MatchSettings.fog, Config.Features.FogOfWar); viewer 0 (no nation: a spectator in
-- the menu, a Primordial) and an eliminated nation see everything. Pure: the Replicator filters each player's view
-- with it, bots plan with it (Sim.Bot), Sim.Navy.visible asks it about fleets.

local Config = require("../Config")
local Diplomacy = require("./Diplomacy")
local Types = require("../Types")

type MatchState = Types.MatchState

-- What one viewer sees. all: everything (fog off, viewer 0, an eliminated nation). friends: the viewer and its allies,
-- whose armies and fleets it always sees. provinces and zones: the land and the sea in sight.
export type Vision = {
	all: boolean,
	friends: { [number]: boolean },
	provinces: { [number]: boolean },
	zones: { [number]: boolean },
}

local Fog = {}

-- Is the setting on in this match?
function Fog.enabled(state: MatchState): boolean
	return state.setup.settings.fog == true
end

local EVERYTHING: Vision = { all = true, friends = {}, provinces = {}, zones = {} }

-- Mark `from` and the land `steps` steps round it.
local function look(state: MatchState, seen: { [number]: boolean }, from: number, steps: number)
	seen[from] = true
	local ring = { from }
	for _ = 1, steps do
		local nextRing = {}
		for _, id in ring do
			for _, n in state.provinces[id].neighbors do
				if not seen[n] then
					seen[n] = true
					table.insert(nextRing, n)
				end
			end
		end
		ring = nextRing
	end
end

-- What `viewer` sees now.
function Fog.vision(state: MatchState, viewer: number): Vision
	local nation = state.nations[viewer]
	if not Fog.enabled(state) or nation == nil or nation.eliminated then
		return EVERYTHING
	end
	local friends: { [number]: boolean } = {}
	for _, id in Diplomacy.allianceMembers(state, viewer) do
		friends[id] = true
	end
	local provinces: { [number]: boolean } = {}
	local zones: { [number]: boolean } = {}
	local land, sight = Config.Fog.LandSight, Config.Fog.ArmySight
	for id, p in state.provinces do
		if p.owner and friends[p.owner] then
			look(state, provinces, id, land)
			for _, z in state.shores[id] or {} do
				zones[z] = true
			end
		end
	end
	for _, a in state.armies do
		if friends[a.owner] then
			look(state, provinces, a.location, sight)
		end
	end
	for _, f in state.fleets or {} do
		if friends[f.owner] then
			zones[f.zone] = true
		end
	end
	return { all = false, friends = friends, provinces = provinces, zones = zones }
end

-- Does this vision see an army of `owner` standing in `location`? (Works on Army and Snapshot.ArmyRecord alike.)
function Fog.seesArmyAt(vision: Vision, owner: number, location: number, rebel: boolean?): boolean
	if vision.all or vision.friends[owner] then
		return true
	end
	if owner == 0 and not rebel then
		return true -- a neutral garrison
	end
	return vision.provinces[location] == true
end

function Fog.seesArmy(vision: Vision, army: Types.Army): boolean
	return Fog.seesArmyAt(vision, army.owner, army.location, army.rebel)
end

-- Does this vision see a fleet of `owner` in `zone`?
function Fog.seesFleetAt(vision: Vision, owner: number, zone: number): boolean
	return vision.all or vision.friends[owner] == true or vision.zones[zone] == true
end

function Fog.seesFleet(vision: Vision, fleet: Types.Fleet): boolean
	return Fog.seesFleetAt(vision, fleet.owner, fleet.zone)
end

-- Events that would give away an army or a fleet out of sight: they reach a viewer only when it sees where they
-- happen ("province" or "zone"), or (a battle's end) when one of its friends fought it.
local UNIT_EVENTS: { [string]: string } = {
	Merged = "province",
	Embarked = "province",
	Landed = "province",
	BattleEnded = "province",
	FleetMerged = "zone",
	SeaBattle = "zone",
}
local FOUGHT: { [string]: boolean } = { BattleEnded = true, SeaBattle = true }

function Fog.seesEvent(vision: Vision, e: Types.MatchEvent): boolean
	local place = UNIT_EVENTS[e.kind]
	if vision.all or place == nil then
		return true
	end
	if FOUGHT[e.kind] and (vision.friends[e.a] or vision.friends[e.b]) then
		return true
	end
	if place == "zone" then
		return vision.zones[e.zone or 0] == true
	end
	return vision.provinces[e.province] == true
end

-- A vision as sorted id lists, for the network (all = true and no lists when it sees everything).
function Fog.lists(vision: Vision): Types.VisionData
	local provinces, zones = {}, {}
	if vision.all then
		return { all = true, provinces = provinces, zones = zones }
	end
	for id in vision.provinces do
		table.insert(provinces, id)
	end
	for id in vision.zones do
		table.insert(zones, id)
	end
	table.sort(provinces)
	table.sort(zones)
	return { all = false, provinces = provinces, zones = zones }
end

-- Players who see the same: a nation and its allies share a vision, and everyone who sees everything shares one.
-- A key per group (the Replicator builds one view per group).
function Fog.group(state: MatchState, viewer: number): string
	local nation = state.nations[viewer]
	if not Fog.enabled(state) or nation == nil or nation.eliminated then
		return "all"
	end
	return if nation.allianceId then "a" .. nation.allianceId else "n" .. viewer
end

return Fog
