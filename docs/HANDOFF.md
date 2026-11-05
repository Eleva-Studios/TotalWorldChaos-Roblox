# Hand-off: how to continue the build in a new chat

Read this after `CLAUDE.md` at the start of every new chat. It holds the state of the build, the order of the remaining work, and exactly how the owner wants the work done. Keep it short and up to date: the coordinator updates it before every chat change.

## Start a new chat with

> Read CLAUDE.md and docs/HANDOFF.md, then continue the build on branch `claude/zen-pascal-446t9e` as the coordinator: one builder at a time, and remind me when it's time for a new chat.

## 1. State (5 November 2026)

- **Main** = `claude/zen-pascal-446t9e`, pushed. Merged and fully checked: everything up to navies stage 3, plus map pings, Slate & Brass GUI step 7, smarter PvP (counters, morale, flanking), bots at sea. Newest plans and docs: `docs/NEXT_FEATURES.md` 9.10–9.14, `docs/RIVALS.md`, `docs/COMPETITOR_VIDEOS.md`.
- **In progress: EU4 missions + fog of war.** WIP commit `97612d5` ("WIP (paused for the day): missions and fog after the navy merge"); its commit body lists what is done and the remaining steps. It is pushed on branch `claude/zen-pascal-446t9e-missions-fog-wip` (owner approved): the builder continues from there (`git worktree add <dir> -b missions-fog origin/claude/zen-pascal-446t9e-missions-fog-wip`) and the coordinator merges the finished stage into main as usual.
  - Done: merged with everything up to navy; fog consistent (bots, fleets, counter hints, pings keep to sight); quick checks pass (43 spec files); `smoke`, `fog`, `missions`, `private` pass.
  - The builder's decision for the owner to confirm: the Missions and Fog switches sit on a third private-server tab, "More".
  - Left: all scenarios with fog on; soaks with the ten-viewer network numbers; tournaments missions on/off and fog on/off (200 seeds per map); BALANCE.md sections 24 (missions) and 25 (fog); final commits; merge main.

## 2. The remaining work, in order

| # | Stage | Effort | Hours | Plan |
| --- | --- | --- | --- | --- |
| 1 | Missions + fog of war (finish from the WIP) | xhigh | ~3 | the WIP's commit body |
| 2 | Generals + keep morale aboard fleets (bug: a broken army that sails lands at full morale) | high | 2.5–3.5 | DESIGN EU4 pack; BALANCE 23 "Watch" |
| 3 | Bot strategy: Hard must clearly beat Normal (now ~35%), mass armies, time attacks to Peace's end, help allies | xhigh | 3–4 | BALANCE 16, 22, 23 |
| 4 | Combat feel: battle preview, split and send a share, multi-select, rally points, readable battles, war overlay | high | 6–8 | NEXT_FEATURES 9.14 |
| 5 | GUI step 8 (the event card covers the province sheet on phones; toasts dropped when 4 are queued) + tap help | high | 3–4.5 | UI_DIRECTION; NEXT_FEATURES 9.10 C |
| 6 | Replay + awards (tell the match's story; comeback and underdog labels) | high | 2–3 | NEXT_FEATURES 5; COMPETITOR_VIDEOS |
| 7 | Play with friends | high | ~2 | NEXT_FEATURES 8 |
| 8 | Game modes (Easy, Blitz, Long) + Classic (no Primordials) + one queue per playlist with the in-server map vote, join in progress | medium–high | 3–5 | NEXT_FEATURES 9.11, 9.13 |
| 9 | Combined balance pass (Earth's Volga 2.14× with navies, Yangtze 0.33×, Skyshards races, event and mission pace) | xhigh | 3–4 | BALANCE 17, 22, 23 |
| 10 | Final review → owner's Studio playtest → soft launch | high | ~2 | LAUNCH |

That is the launch scope, about 30–40 hours. **After the soft launch, ordered by the data:** Primordials stage 1 (9.11, xhigh, 8–9 h), the bigger Earth (9.10 A+B, 3–4 h), Primordials stage 2, the sandbox stages (9.12; S1 painter + S3 powers first, then sharing and the map maker), Earth Ages and nukes (9.9), monetization stages and the flag art pass.

## 3. How the work is done (the owner's rules; keep them exactly)

**Roles.** The chat itself is the **coordinator**: it briefs builders, verifies, merges and pushes, and talks to the owner. Builders are subagents that each finish **one stage**.

**Usage (the owner is careful with it; the weekly limit was hit once with five parallel builders):**
- **One builder at a time.** Never more. No second machine or session unless the owner asks.
- **Effort:** high by default; **xhigh** only for missions + fog, bot strategy, the balance pass and Primordials; **medium** only for well-specified data or content work with strong automated checks. Quality must never drop. Never a cheaper model unless the owner asks.
- **A fresh builder per stage.** A builder hands off (commits a WIP with a precise status) when its context passes about **300k tokens**: a subagent's prompt cache lasts 5 minutes, so every wake-up after a long run re-writes its whole context.
- **No polling.** Long runs (all scenarios, soaks, tournaments) start detached or in the background, the agent ends its turn and waits for the notification. Background runs die at 2 hours: use `setsid nohup … & disown` plus an until-loop waiter for longer ones.
- **Short outputs:** grep and tail results; never print whole logs or read agent transcripts.
- The coordinator verifies near-done work itself (its own cache lasts an hour, so checks cost it little).

**Builder brief (what every brief contains):** the worktree and branch to work in (never the main checkout, never push); "read CLAUDE.md first" and the DESIGN/BALANCE sections to read; what main gained since the branch's base and the conflicts to expect; numbered steps (merge, resolve keeping all sides, checks, balance with numbers, docs, commits); the usage rules above; the final report format (SHAs, each conflict and how it was resolved, check numbers, then What changed / How to test in Studio / Decisions).

**Verification before main moves (the coordinator, every stage):**
1. A scratch worktree at main (`git worktree add --detach <dir> claude/zen-pascal-446t9e`), then `git merge --no-ff <stage commit>`.
2. `tools/checks/fullrun.sh <dir> <prefix> <GUI scenarios for 667×375>` detached (40–70 min): stylua, selene, Lune tests, rojo build, every scenario, the soak on three maps (GUI peak under 2,000, network under budget), the no-EditableImage runs, the small-phone runs.
3. For GUI changes, `tools/checks/shots.sh` at 844×390, 667×375 and 1366×1024 and **look at the screenshots**.
4. A small fix after a green full run: `tools/checks/delta.sh` with the affected scenarios.
5. All green → `git merge --ff-only` on the main checkout → `git push -u origin claude/zen-pascal-446t9e` (retry with backoff on network errors). Remove finished scratch worktrees.
6. Known harmless: `progression` fails at 667×375 by design (the top bar hides the level on narrow phones); don't run it at that size.

**Quality bar:** every new Sim rule has a Lune test; balance changes only with tournament evidence (200 seeds per map; Gate 3: no start slot wins most matches; section 17's spread under about 2×); Config holds every number; GUI follows the Slate & Brass kit and fits 667×375; screenshots get looked at; builders' reports are claims until the coordinator's own run is green.

**Git:** branch `claude/zen-pascal-446t9e`; no pull request unless the owner asks; no model names in commits or docs. Commit trailers:
`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: <the current chat's session link>`.

**Talking to the owner:** short status updates at each merge or when something needs a decision; final messages follow CLAUDE.md (What changed, How to test in Studio, Decisions). The owner writes English or Swedish; answer in the same language. Show progress with screenshots from the harness when asked.

## 4. When to start a new chat (the coordinator reminds the owner)

A chat's cost per step grows with its length: every step re-reads the whole conversation. The coordinator says **"Time for a new chat"** (after updating this file and pushing) when any of these happens:
- **2–3 stages merged** in the same chat;
- the chat was **compacted** (a summary replaced the history), or it has run for more than a day of work;
- the topic **switches** from building to long planning or research (or back);
- before a **big xhigh stage** starts (missions + fog, bot strategy, the balance pass), so it begins from a small context.

Before switching: no builder running (or it has committed a WIP), main pushed, WIP branches pushed (with the owner's OK), this file updated.

**Local or cloud:** a local chat (on the owner's computer) for Roblox Studio tests, videos and screenshots (`ffmpeg` can pull frames from a video for review); a cloud chat for long builder runs and tournaments.

## 5. The owner's decisions to keep

- **Game:** a fun chaos EU4-style game, readable rather than twitch-skill. Fog of war on by default and easy to switch off. Primordials stay ("Chaos" playlist) and a **Classic** playlist has none. One queue per playlist; the map is chosen by the in-server vote (rotation as its backbone, no repeat of the last map). Sandbox players will make PvP maps and host matches (9.12 S7).
- **Primordials (9.11):** chaos leans on the leader, never on the weak; announced, dodgeable hits; land scars that heal; toys for constant play; balance gated by bot Primordials with four personalities.
- **Sandbox (9.12):** WorldBox-level and clearly above World Sim, with a ModernBox-style ages pack; never copy WorldBox's or mods' art, names or wording; some tools sold as sandbox-only passes; built after the PvP launch.
- **Combat (9.14):** at or above RoFront and Conquer The World in feel; battles stay short and automatic.
- **Map (9.10):** a bigger Earth with Europe enlarged; province merges only if needed.
- **Money:** no strength for sale in matches; options stay open (MONETIZATION 13.7). Flags and banners get a big art pass before launch (hire a pixel artist for hero art).
- **Launch:** PvP first, sandbox and the big extras after the soft launch, guided by data; seed creators (COMPETITOR_VIDEOS).
- **Banned words:** see CLAUDE.md's golden rules; rival games whose names contain them are named by description or game id.

## 6. Tools

- `tools/checks/fullrun.sh`, `delta.sh`, `shots.sh`, `runset.sh`: the verification runs above (logs in `$CHECK_LOGS`, default `../check-logs`).
- `tools/checks/usage_cost.py <session.jsonl>`: what a chat would have cost at API prices (the first chat: about $1,420 over 11,100 calls; one stage finished the careful way: about $12–15).
- `tools/harness/tournament.luau`: bot tournaments (see its header for options).
