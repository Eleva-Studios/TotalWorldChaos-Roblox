--!strict
-- Sends a full snapshot to a player when they join (or a new match starts), then one delta per tick.
-- Records carry what clients need: every nation's race, every army's composition, the fleets with the men aboard,
-- each coast's blockade (Shared.Snapshot). Moving armies and sailing fleets report their progress on the unreliable
-- channel instead, so their records don't change every tick.
-- Fog of war (Sim.Fog, a match setting): with it off, one delta and one positions stream go to everyone. With it on,
-- each player gets their own: the armies and fleets their nation (and its allies) see, what it sees, and only the
-- events that give nothing away. Players who see the same (a nation and its allies; everyone who sees everything)
-- share one view, worked out once a tick; what everyone sees alike (provinces, nations, diplomacy...) is diffed
-- once, and each player's armies, fleets and vision against what that player was last sent.
-- The EU4 pack's event cards and missions are private too: each player gets their own nation's, on their own remotes
-- (sendCards, sendMissions).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Shared")
local Shared = ReplicatedStorage.Shared
local EventCards = require(Shared.Sim.EventCards)
local Fog = require(Shared.Sim.Fog)
local Lobby = require(Shared.Sim.Lobby)
local Missions = require(Shared.Sim.Missions)
local Movement = require(Shared.Sim.Movement)
local Remotes = require(Shared.Remotes)
local Snapshot = require(Shared.Snapshot)
local Types = require(Shared.Types)

-- UnreliableRemoteEvent payloads must stay under ~900 bytes, so positions go out as flat number arrays in chunks.
local POSITIONS_PER_MESSAGE = 16

local Replicator = {}

local snapshotRemote: RemoteEvent
local deltaRemote: RemoteEvent
local notifyRemote: RemoteEvent
local positionsRemote: UnreliableRemoteEvent
local lobbyRemote: RemoteEvent
local cardRemote: RemoteEvent
local missionRemote: RemoteEvent
local lastSent: Snapshot.SnapshotData? = nil -- the all-seeing view last broadcast (the fog off: what everyone has)
local sentTo: { [Player]: Snapshot.SnapshotData } = {} -- the fog on: the view each player was last sent
local cardsSent: { [Player]: string } = {} -- what each player was last told about their event cards
local missionsSent: { [Player]: string } = {} -- ...and about their missions
local nationOf: (Player) -> number? = function(_player: Player): number?
	return nil
end

function Replicator.init()
	snapshotRemote = Remotes.event("Snapshot")
	deltaRemote = Remotes.event("Delta")
	notifyRemote = Remotes.event("Notify")
	positionsRemote = Remotes.unreliableEvent("ArmyPositions")
	lobbyRemote = Remotes.event("Lobby")
	cardRemote = Remotes.event("EventCard")
	missionRemote = Remotes.event("Missions")
	Players.PlayerRemoving:Connect(function(player: Player)
		sentTo[player] = nil
		cardsSent[player] = nil
		missionsSent[player] = nil
	end)
end

-- Every nation's equipped cosmetics travel next to the match state (ShopService sets this).
local cosmeticsOf: ((Types.MatchState) -> { Types.NationCosmetics })? = nil

function Replicator.setCosmetics(fn: (Types.MatchState) -> { Types.NationCosmetics })
	cosmeticsOf = fn
end

-- Whose eyes a player sees the match with while the fog of war is on (GameLoop: MatchService.nationOf).
function Replicator.setViewer(fn: (Player) -> number?)
	nationOf = fn
end

local function full(state: Types.MatchState, viewer: number?): Snapshot.SnapshotData
	return Snapshot.full(state, if cosmeticsOf then cosmeticsOf(state) else nil, viewer)
end

-- Snapshot(data, yourNationId or 0): what that nation sees (everything with the fog off, or with no nation).
function Replicator.sendSnapshot(player: Player, state: Types.MatchState, nationId: number?)
	local data = full(state, nationId)
	snapshotRemote:FireClient(player, data, nationId or 0)
	sentTo[player] = data
end

-- A new match: forget the old baseline so the next delta is computed against the new state.
function Replicator.reset(state: Types.MatchState)
	lastSent = full(state)
	table.clear(sentTo) -- everyone gets a snapshot of the new match before its first delta
	table.clear(cardsSent) -- card and mission ids start again: everyone hears about theirs afresh
	table.clear(missionsSent)
end

-- The EU4 pack's event cards (Sim.EventCards): each player is told about their own nation's open card and its last
-- closed one, when that changes, and nobody else's. An event's words never travel: the client looks them up by id.
function Replicator.sendCards(state: Types.MatchState, nationFor: (Player) -> number?)
	for _, player in Players:GetPlayers() do
		local view = EventCards.view(state, nationFor(player))
		local key = view.card .. ":" .. view.lastCard
		if cardsSent[player] ~= key then
			cardsSent[player] = key
			cardRemote:FireClient(player, view)
		end
	end
end

-- The EU4 pack's missions (Sim.Missions): each player is told about their own nation's goals and their progress, and
-- the last one closed, when that changes, and nobody else's.
function Replicator.sendMissions(state: Types.MatchState, nationFor: (Player) -> number?)
	for _, player in Players:GetPlayers() do
		local view = Missions.view(state, nationFor(player))
		local key = Missions.key(view)
		if missionsSent[player] ~= key then
			missionsSent[player] = key
			missionRemote:FireClient(player, view)
		end
	end
end

-- ArmyPositions(tick, armies, fleets): id, from, to, progress in percent, armies and fleets in separate arrays, in
-- chunks. `fire` sends one chunk (to everyone, or to one player).
local function sendPositions(
	tick: number,
	positions: { Snapshot.Position },
	fire: (number, { number }, { number }) -> ()
)
	local armies, fleets = {}, {}
	for i, p in positions do
		local flat = if p.fleet then fleets else armies
		table.insert(flat, p.id)
		table.insert(flat, p.from)
		table.insert(flat, p.to)
		table.insert(flat, math.floor(p.progress * 100 + 0.5))
		if i % POSITIONS_PER_MESSAGE == 0 or i == #positions then
			fire(tick, armies, fleets)
			armies, fleets = {}, {}
		end
	end
end

-- The positions of the armies and fleets a view holds.
local function positionsIn(view: Snapshot.SnapshotData, positions: { Snapshot.Position }): { Snapshot.Position }
	local armies, fleets = {}, {}
	for _, a in view.armies do
		armies[a.id] = true
	end
	for _, f in view.fleets do
		fleets[f.id] = true
	end
	local out = {}
	for _, p in positions do
		if if p.fleet then fleets[p.id] else armies[p.id] then
			table.insert(out, p)
		end
	end
	return out
end

type View = {
	data: Snapshot.SnapshotData,
	events: { Types.MatchEvent },
	positions: { Snapshot.Position },
	deltas: { [Snapshot.SnapshotData]: Snapshot.DeltaData | false }, -- by baseline: players who had the same share it
}

-- Tick order step 9: a delta with only what changed since the last tick, plus this tick's events. Then moving
-- armies' and sailing fleets' positions on the unreliable channel. Events are spent once sent.
function Replicator.broadcast(state: Types.MatchState)
	local current = full(state)
	local positions = Snapshot.positions(state, function(provinceId, army)
		return Movement.moveTicks(state, army, provinceId) -- its slowest troop's speed (Elves: forest as plains)
	end)
	if not Fog.enabled(state) then
		if lastSent then
			local delta = Snapshot.diff(lastSent, current, state.events)
			if delta then
				deltaRemote:FireAllClients(delta)
			end
		end
		lastSent = current
		table.clear(state.events)
		sendPositions(state.tick, positions, function(tick, armies, fleets)
			positionsRemote:FireAllClients(tick, armies, fleets)
		end)
		return
	end
	-- what everyone sees alike changed the same for every player: diff it once (Snapshot.diffView)
	local shared = if lastSent then Snapshot.diff(lastSent, current) else nil
	local views: { [string]: View } = {}
	for _, player in Players:GetPlayers() do
		local before = sentTo[player]
		if before == nil then
			continue -- no snapshot yet (still in the start menu before any match): nothing to diff against
		end
		local viewer = nationOf(player) or 0
		local key = Fog.group(state, viewer)
		local view = views[key]
		if view == nil then
			local vision = Fog.vision(state, viewer)
			local data = Snapshot.view(current, state, vision)
			view = {
				data = data,
				events = Snapshot.events(state.events, vision),
				positions = positionsIn(data, positions),
				deltas = {},
			}
			views[key] = view
		end
		local v = view :: View
		local delta = v.deltas[before]
		if delta == nil then
			delta = (
				if lastSent
					then Snapshot.diffView(before, v.data, shared, v.events)
					else Snapshot.diff(before, v.data, v.events)
			) or false
			v.deltas[before] = delta
		end
		if delta then
			deltaRemote:FireClient(player, delta)
		end
		sentTo[player] = v.data
		sendPositions(state.tick, v.positions, function(tick, armies, fleets)
			positionsRemote:FireClient(player, tick, armies, fleets)
		end)
	end
	lastSent = current
	table.clear(state.events)
end

-- The lobby (map vote, draft, or "None" once the match starts) to one player, or to everyone.
function Replicator.sendLobby(view: Lobby.LobbyView, player: Player?)
	if player then
		lobbyRemote:FireClient(player, view)
	else
		lobbyRemote:FireAllClients(view)
	end
end

-- Toast on every client: Notify(kind, text).
function Replicator.notifyAll(kind: string, text: string)
	notifyRemote:FireAllClients(kind, text)
end

-- Toast on one client.
function Replicator.notify(player: Player, kind: string, text: string)
	notifyRemote:FireClient(player, kind, text)
end

return Replicator
