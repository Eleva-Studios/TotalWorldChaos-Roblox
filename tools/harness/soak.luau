--!nocheck
-- A whole match, headlessly: one idle player and nine bots for the full 25 minutes, then Results and the start
-- of the next match. Fails on any script error or warn(), or if the player's screen ever holds more GUI objects
-- than the budget (docs/DESIGN.md "Performance budget"). Prints one line per game minute.
--
--   mkdir -p build && rojo build -o build/game.rbxlx
--   lune run tools/harness/soak                 # Config.DefaultMap; MAP=earth for another map
--   SHOTS=1 lune run tools/harness/soak         # plus a screenshot every 5 minutes in tools/harness/out/soak/
--   FOG=off lune run tools/harness/soak         # with the fog of war off (Workspace FogOfWar = false)
-- It also measures the network (what Alice's client is sent, by Emulator.wireSize: under NET_BUDGET a second over
-- the match) and the server's cost of the delta and the bots (Replicator.broadcast, AIService.step) per tick.
local fs = require("@lune/fs")
local process = require("@lune/process")

local Emulator = require("./Emulator")
local Scene = require("./Scene")

local OUT = "tools/harness/out/soak"
local GUI_BUDGET = 2000
local NET_BUDGET = 10 * 1024 -- bytes a second per client, over the whole match (docs/DESIGN.md "Performance budget")
local MINUTES = 26.5 -- the match, Results and the first seconds of the next match

local function server(path: string)
	local node = Emulator.server.dm:GetService("ServerScriptService").Server
	for _, name in string.split(path, ".") do
		node = node:FindFirstChild(name)
	end
	return Emulator.server.modules[node]
end

local function guiObjects(client): number
	local n = 0
	for _, d in client.localPlayer.PlayerGui:GetDescendants() do
		if d:IsA("GuiObject") then
			n += 1
		end
	end
	return n
end

local function shot(client, name: string)
	if fs.isDir(OUT) == false then
		fs.writeDir(OUT)
	end
	local base = OUT .. "/" .. name
	Scene.save(client, base .. ".json")
	local r = process.exec("python3", { "tools/harness/render_scene.py", base .. ".json", base .. ".png" })
	assert(r.ok, "render failed: " .. r.stderr)
	fs.removeFile(base .. ".json")
	for _, entry in fs.readDir(OUT) do
		if string.find(entry, "%.rgba$") then
			fs.removeFile(OUT .. "/" .. entry)
		end
	end
	print("  📸 " .. base .. ".png")
end

if fs.isDir(OUT) then
	fs.removeDir(OUT)
end
Emulator.setQuiet(true)
local fogOff = process.env.FOG == "off"
Emulator.boot(fs.readFile("build/game.rbxlx"), process.env.MAP, { SkipLobby = true, FogOfWar = not fogOff })
Emulator.run(1)
local alice = Emulator.addClient("Alice")
Emulator.run(1)

-- the server's cost: time spent in the delta (per-player views with the fog on) and in the bots' plans, per call
local cost = {}
local function timed(path: string, name: string)
	local module = server(path)
	local inner = module[name]
	local entry = { calls = 0, total = 0, peak = 0 }
	cost[path .. "." .. name] = entry
	module[name] = function(...)
		local t0 = os.clock()
		local a, b, c = inner(...)
		local dt = os.clock() - t0
		entry.calls += 1
		entry.total += dt
		entry.peak = math.max(entry.peak, dt)
		return a, b, c
	end
end
timed("Replicator", "broadcast")
timed("Services.AIService", "step")
local function aliceBytes(): number
	local n = 0
	for _, bytes in Emulator.netBytes.Alice or {} do
		n += bytes
	end
	return n
end

local MatchService = server("Services.MatchService")
local first = MatchService.state()
local me = alice.modules[alice.localPlayer.PlayerScripts.Client.ClientState].myNation()
print(
	string.format(
		"soak on %s: Alice is nation %d, nine bots, fog of war %s",
		first.mapId,
		me,
		if first.setup.settings.fog then "on" else "off"
	)
)
print(" clock   phase       gui  armies  Alice  wars  Lua MB  wall s  KB/s")
local bytes0 = aliceBytes()
local matchBytes, matchSeconds = 0, 0

-- The worst case the soak's one player can't show: ten players, one per nation, each with their own view while the
-- fog of war is on. Every tick, before the real broadcast spends the tick's events, do what the Replicator would do
-- for them: the shared snapshot and its delta, then each living nation's vision, view and delta against its last
-- view (Sim.Fog, Snapshot.view, Snapshot.diffView), timed; and count what each would be sent (the delta, and its
-- share of the positions: 4 numbers per moving army it sees, in chunks of 16), by Emulator.wireSize.
local Fog = require("../../src/shared/Sim/Fog")
local Snapshot = require("../../src/shared/Snapshot")
local tenViews = { ticks = 0, total = 0, peak = 0, bytes = 0, viewers = 0, busiest = 0 }
local lastViews: { [number]: any } = {}
local lastAll = nil
local perNation: { [number]: number } = {}
local function measureTenViews(state)
	if not Fog.enabled(state) or state.result ~= nil then
		return
	end
	local t0 = os.clock()
	local all = Snapshot.full(state)
	local shared = if lastAll then Snapshot.diff(lastAll, all) else nil
	lastAll = all
	local busiest = 0
	for id, nation in state.nations do
		if not nation.eliminated then
			local vision = Fog.vision(state, id)
			local data = Snapshot.view(all, state, vision)
			local before = lastViews[id]
			if before then
				local delta = Snapshot.diffView(before, data, shared, Snapshot.events(state.events, vision))
				local bytes = if delta then 9 + Emulator.wireSize(delta) else 0
				local moving = 0
				for _, a in data.armies do
					if a.next ~= 0 and not a.inBattle then
						moving += 1
					end
				end
				bytes += moving * 36 + math.ceil(moving / 16) * 33
				tenViews.bytes += bytes
				tenViews.viewers += 1
				perNation[id] = (perNation[id] or 0) + bytes
				busiest = math.max(busiest, bytes)
			end
			lastViews[id] = data
		end
	end
	local dt = os.clock() - t0
	tenViews.ticks += 1
	tenViews.total += dt
	tenViews.peak = math.max(tenViews.peak, dt)
	tenViews.busiest = math.max(tenViews.busiest, busiest)
end
do
	local replicator = server("Replicator")
	local broadcast = replicator.broadcast
	replicator.broadcast = function(state, ...)
		if state == first then
			measureTenViews(state)
		end
		return broadcast(state, ...)
	end
end

local peak, peakAt = 0, ""
local wall0 = os.clock()
for minute = 1, math.ceil(MINUTES) do
	local t0 = os.clock()
	Emulator.run(60)
	local state = MatchService.state()
	local gui = guiObjects(alice)
	local armies, wars, mine = 0, 0, 0
	for _ in state.armies do
		armies += 1
	end
	for _ in state.wars do
		wars += 1
	end
	for _, p in state.provinces do
		if p.owner == me then
			mine += 1
		end
	end
	local clock = string.format("%d:%02d", state.tick // 60, state.tick % 60)
	if state ~= first then
		clock = "next " .. clock
	end
	local sent = aliceBytes() - bytes0
	bytes0 = aliceBytes()
	if state == first and first.result == nil then
		matchBytes += sent
		matchSeconds += 60
	end
	print(
		string.format(
			"%6s  %-10s %4d  %6d  %5d  %4d  %6.1f  %6.1f  %4.1f",
			clock,
			state.phase,
			gui,
			armies,
			mine,
			wars,
			collectgarbage("count") / 1024,
			os.clock() - t0,
			sent / 60 / 1024
		)
	)
	if gui > peak then
		peak, peakAt = gui, clock
	end
	if process.env.SHOTS and minute % 5 == 0 then
		shot(alice, string.format("%02d_min", minute))
	end
end

-- who owns the armies at the end of the first match, and how big they are
local byOwner = {}
for _, army in first.armies do
	local entry = byOwner[army.owner] or { n = 0, men = 0, idle = 0 }
	entry.n += 1
	entry.men += army.men
	if #army.path == 0 and not army.inBattle then
		entry.idle += 1
	end
	byOwner[army.owner] = entry
end
print("\narmies at the end, by owner:")
for owner = 0, 10 do
	local entry = byOwner[owner]
	if entry then
		local name = if owner == 0 then "neutral" else first.nations[owner].name
		print(string.format("  %-10s %3d armies, %6d men, %3d standing", name, entry.n, entry.men, entry.idle))
	end
end
local stacked = 0
local seen = {}
for _, army in first.armies do
	local key = army.owner .. ":" .. army.location
	if #army.path == 0 and not army.inBattle then
		if seen[key] then
			stacked += 1
		end
		seen[key] = true
	end
end
print(string.format("standing armies sharing a province with another of the same owner: %d", stacked))

local result = first.result
print(string.format("\nresult: %s", if result then result.kind .. " at tick " .. result.endedAt else "none"))
print(string.format("peak GUI objects: %d at %s (budget %d)", peak, peakAt, GUI_BUDGET))
print(string.format("wall time: %.0f s", os.clock() - wall0))
local perSecond = if matchSeconds > 0 then matchBytes / matchSeconds else 0
print(
	string.format(
		"network: Alice was sent %.1f KB a second over the match (budget %.0f KB; fog of war %s)",
		perSecond / 1024,
		NET_BUDGET / 1024,
		if first.setup.settings.fog then "on" else "off"
	)
)
local remotes = {}
for name, bytes in Emulator.netBytes.Alice or {} do
	table.insert(remotes, { name = name, bytes = bytes })
end
table.sort(remotes, function(a, b)
	return a.bytes > b.bytes
end)
for i = 1, math.min(6, #remotes) do
	print(string.format("  %-14s %8.1f KB in all", remotes[i].name, remotes[i].bytes / 1024))
end
if tenViews.ticks > 0 then
	local worst = 0
	for _, bytes in perNation do
		worst = math.max(worst, bytes)
	end
	print(
		string.format(
			"network: with ten players, each would be sent %.1f KB a second on average (the busiest nation %.1f KB a "
				.. "second over the match, the busiest tick %.1f KB)",
			tenViews.bytes / math.max(1, tenViews.viewers) / 1024,
			worst / tenViews.ticks / 1024,
			tenViews.busiest / 1024
		)
	)
	print(
		string.format(
			"server: ten players' views %.2f ms a tick on average, %.1f ms at most",
			tenViews.total / tenViews.ticks * 1000,
			tenViews.peak * 1000
		)
	)
end
for _, name in { "Replicator.broadcast", "Services.AIService.step" } do
	local entry = cost[name]
	print(
		string.format(
			"server: %-24s %5d calls, %.2f ms a call on average, %.1f ms at most",
			name,
			entry.calls,
			if entry.calls > 0 then entry.total / entry.calls * 1000 else 0,
			entry.peak * 1000
		)
	)
end
assert(result ~= nil, "the match never ended")
assert(MatchService.state() ~= first, "the next match never started")
assert(peak <= GUI_BUDGET, "over the GUI budget")
assert(perSecond <= NET_BUDGET, "over the network budget")
Emulator.assertClean("soak")
print("== soak passed ==")
