--!strict
-- The words and icons of the EU4 pack's missions (docs/DESIGN.md "Missions"): what each kind of goal asks, in a few
-- words (the rules and numbers are in Sim.Missions and Config.Missions). Shown only to the nation's own player: the
-- server sends a nation's goals to its own player alone, by kind, and that client looks the words up here.

local MissionText = {}

-- Each kind's icon (src/client/IconArt.luau): the goal at a glance.
MissionText.ICONS = {
	Take = "flag",
	Grow = "up",
	Fort = "castle",
	Win = "battle",
	Ally = "handshake",
} :: { [string]: string }

-- The longest a goal's words may be, with the longest province name (a Lune test checks).
MissionText.MAX = 32

-- What a goal asks: `place` is its province's name (Take, Grow), `count` what it needs (Fort, Win).
function MissionText.goal(kind: string, place: string?, count: number): string
	if kind == "Take" then
		return "Take " .. (place or "that province")
	elseif kind == "Grow" then
		return "Develop " .. (place or "your capital")
	elseif kind == "Fort" then
		return if count == 1 then "Build a fort" else string.format("Build %d forts", count)
	elseif kind == "Win" then
		return if count == 1 then "Win a battle" else string.format("Win %d battles", count)
	end
	return "Join an alliance"
end

return MissionText
