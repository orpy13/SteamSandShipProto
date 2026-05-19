# Steam Sand Ship — Roadmap

Status doc for the **Tier 1: close the loop** push and the longer-term
direction. `instructions.md` remains the spec mirror of *shipped* code; this
file is the plan for what's *next*. Keep both honest.

## Guiding decisions (locked)

- **Bandits are parked.** The combat/AI system needs a real overhaul to be
  fun; it's out of scope for Tier 1 and disabled, not deleted.
- **Everything is a market good.** No parallel "stores" inventory. `coal`,
  `water`, `spice` (existing) + `repair_kit`, `food`, `drinking_water` (new)
  are all bought/sold at oasis markets and held in `ship.cargo`. The same
  crate can be burned, used, or sold for arbitrage.
- **Stations buffer from cargo.** The coal bunker and a new water tank hold
  their own finite working stock, replenished from cargo; the boiler draws
  from those. Repair kits are consumed straight from cargo at the broken part.
- **Survival is fully per-player and item-driven.** Each crew member has
  hunger / thirst / energy. `food` and `drinking_water` are physical goods
  pulled from the hold and consumed. One generic food now; data-structured so
  future foods/drinks can carry different stats.
- **No ship game-over.** Running the ship dry strands it (immobile), it does
  not end the run. Stranded crew can disembark and walk for supplies, but the
  desert is lethal. The only hard end is the whole crew dying.

---

## Tier 1 — work breakdown

> **Status: shipped.** T1.0–T1.8 are all merged to `main` (commits
> `eac328c` → `3ae67c6` → `624b658`, with follow-up passes for the
> physical item set / two-way cargo hold / bed rest, and the
> over-the-shoulder character controller + animations on top). The
> sub-sections below remain as the design record of *what* was built and
> the integration points used; the unresolved knobs (drain tuning,
> capacity rebalance, etc.) are listed below under "Tier 1 follow-up".

Ordered roughly by dependency. Each item notes the integration points so
implementation stays grounded in the existing code.

### T1.0 — Park bandits
- `@export var spawn_enabled := false` gate on `bandit_director._process()`
  (code intact; weather→spawn hook and AI hold-fire just go dormant).
- Note it in `instructions.md`.

### T1.1 — Expand the goods registry
- Add `repair_kit`, `food`, `drinking_water` to `Goods.ALL` (display name,
  `carry_id`, tint) and `Goods.PRICES` for both oasis types.
- Carry visuals + match arms in `player_controller._refresh_carried_visual`.
- They flow through the existing market / cargo-crate / cargo-hold-deposit
  pipeline unchanged — provisions are just goods, sold at oasis markets
  (stock variety is a Future item).

### T1.2 — Finite coal bunker + new water tank
- Coal bunker: replace infinite supply with a finite working stock,
  auto-drawn from `cargo["coal"]` (recommended: small visible buffer that
  tops itself from cargo; explicit "load bunker" action is the alternative —
  decide at implementation).
- **New** `water_tank` interactable on the ship: boiler feedwater buffer,
  refilled from `cargo["water"]` *and* still from world water towers.
  `steam_plant` draws boiler water from the tank.
- Distinguish clearly: `water` (boiler feedwater) vs `drinking_water` (crew
  thirst) are different goods.
- Files: `coal_bunker.gd`, new `water_tank.gd` + scene, `steam_plant.gd`,
  `water_tower.gd` (retarget fill into the tank).

### T1.3 — Machine wear during use
- Server-applied passive degradation (reuses the existing `_apply_damage`
  RPC path — only sender 0/1 accepted, host has all state incl. the
  host-simulated steam plant).
- Sources → systems: `mobility` ← distance × speed × terrain roughness
  (slope/suspension data already computed); `power` ← boiler heat / pressure
  / engine-order; `control` ← hard turning at speed. Hull stays combat-only.
- Performance penalties already exist (speed/turn/boiler-leak), so wear has
  immediate teeth. Tuning is the deliverable — negligible on a short hop,
  real on a long haul.

### T1.4 — Relocate repair to the damaged part
- Kits now come from the market (T1.1), so the old `workshop.gd` dual role
  (dispense + auto-repair) is gone.
- New `repair_point.gd` interactable, one per worn system at its physical
  location: boiler → `power`, bridge → `control`, wheels → `mobility`.
  Carrying a `repair_kit`, press E to consume it and `ship.repair_system()`
  *that* system. Contextual prompt shows that system's integrity.
- Decide the fate of the existing workshop node (remove vs. convert to one
  RepairPoint / a hull bench). Keep `ship.tscn` edits minimal (scene-text
  edits are the fragile part here) — 3 points to start.

### T1.5 — Per-player survival (hunger / thirst / energy)
- Stats on the player (replicated via the existing player synchronizer).
- Drains: baseline over time + activity (carrying/working drains energy);
  **environmental modifiers tie into shipped systems** — thirst faster in a
  sandstorm (`weather.get_storm_intensity`) and at midday
  (`day_night.get_daylight`); energy drains harder off-ship in the heat.
- Consumption: pull a `food` / `drinking_water` good from the hold (becomes
  a carried item), a "use" action consumes it and refills the matching need.
- Zero need → player **downed** (incapacitated), revivable by another crew
  member (cost a food/water?) or at a settlement. **All crew down = the run
  ends** — the single hard fail (the crew died, not the ship).
- Open details: revive specifics, exact "downed" capabilities, drain rates,
  what low energy does (slower move/carry — recommended).

### T1.6 — Stranding (emergent, no new fail logic)
- Falls out of T1.2 + T1.5: no coal/water → ship immobile. Crew can
  disembark via the existing gangway and walk to a settlement for a kit /
  supplies, but desert survival pressure (T1.5) makes it desperate.
- No explicit ship-fail state or screen; the consequence is crew death.

### T1.7 — HUD
- Per-player needs (hunger/thirst/energy) bars for the local player.
- Ship resource readouts: bunker coal, boiler-water tank, key consumables in
  cargo; low-supply + needs warnings. Keep the existing HDG/phase/SANDSTORM
  line intact.

### T1.8 — Spec sync
- Update `instructions.md` (goods, stations, wear, repair points, survival,
  stranding, replication, tests, extension checklist) as each piece lands —
  ongoing project norm, not a final step.

### Dependencies
T1.0 anytime. T1.1 → T1.2/T1.4/T1.5 (goods first). T1.3 independent. T1.6 is
emergent from T1.2+T1.5. T1.7/T1.8 trail each feature.

---

## Tier 1 follow-up (outstanding from the items list above)

Resolved in flight:
- Bunker/tank replenish UX → **explicit load action** (locked).
- Workshop disposition → **kept as kit repository** (locked).
- Downed/revive → simple v1: frozen body, revive on any market trade.

Still open (mostly a **balance pass** waiting on playtesting):
- Survival drain/restore tuning and the heat/storm/exposed coupling
  curves (many `@export`s at first-guess values).
- Cargo capacity now that fuel + provisions + kits + items share the
  20-slot hold — likely needs a rebalance or differentiated capacities.
- Per-crew revive cost (food/water expended) as a richer model than the
  current "any trade revives everyone".
- Approximate transforms placed in `ship.tscn` during T1.4/T1.2 and the
  carry-prop offsets — eyeball in editor.

---

## Tier 2 — World structure (the world becomes a place)

The top priority after Tier 1. Today the world is infinite deterministic
dune-noise with a few oases pinned to arbitrary chunk keys — no geography,
so the sun-compass and "sail to a settlement" loop have nothing to navigate
*toward*. Tier 2 adds the missing structural layer; the Future items below
are re-slotted to build on it.

### Locked decisions
- **Finite, bounded world.** A designed map enclosed by border biomes:
  **coast** (hard edge), **mountains** (soft — unclimbable via the shipped
  grade dynamics), **jungle** (passable at a cost). Interior = biomes +
  curated settlements. Not a major restructure — borders are just the
  region field at the edges (see T2.1).
- **Position is earned.** Drop the always-on HUD `X/Z`. You get heading +
  speed + a dead-reckoning *estimate* whose error grows since the last
  fix; precise position comes from the chart, telescope, sun/pole star,
  and reaching known landmarks.
- **Hybrid placement.** Curated named settlements at fixed world coords
  (replacing `HAND_PLACED_OASES`) + deterministic seeded minor POIs
  (salvage / wrecks / refuel caches / ruins) scattered between.
- The single architectural lever: a **region/biome field** feeding
  `ChunkGen` + a **POI/settlement registry**, revealed progressively via
  the chart/telescope. Consistent with the world-scroll / streaming /
  determinism model and the bespoke-chunk editor.

### Work breakdown

**T2.0 — Region/biome field (foundation)**
- Deterministic `region_at(world_x, world_z)` (low-freq noise or a hand
  region map) → region id. A region table sets `ChunkGen` noise params,
  terrain tint, prop table, and hazard/feel modifiers (e.g. salt flats
  spike thirst; badlands raise rolling resistance / wear). Wires into the
  shipped vehicle-dynamics, survival and weather systems.
- `chunk_gen.gd` / `chunk_manager.gd` consume region; **must stay
  deterministic and match the bespoke-editor preview** (existing parity
  contract — update the editor dock params too).

**T2.1 — World bounds + border biomes**
- Define world extents in `world_offset` space.
- Coast: terrain below a sea level + a water plane (Forward+) → hard edge.
- Mountains: height ramps past the climbable grade (reuses
  `grade_gravity`/`grade_speed_sensitivity`) → diegetic soft wall, no
  invisible barriers.
- Jungle: dense collidable props (reuses the `_move_virtual_offset`
  hard-stop) — slow, hazardous, but unique resources.
- Hero edge sites authored via the bespoke chunk editor.

**T2.2 — POI / settlement registry (hybrid)**
- Curated registry: named settlements at fixed world coords with identity
  (services: market / fuel / water / provisions / repair / contracts).
  Replaces arbitrary `HAND_PLACED_OASES`.
- Deterministic minor POIs seeded per region between settlements (extends
  the existing water-tower seeding, region-aware).
- Resolved through the chunk registry/overlay tiers so streaming spawns
  them; bespoke editor authors the hero settlements.

**T2.3 — Navigation overhaul (earn position)**
- HUD: replace live `X/Z` with HDG + speed + a dead-reckoning estimate
  (integrated from heading/speed) with growing error since last fix.
- **Chart table** interactable: shared, host-authoritative crew state —
  discovered POIs + telescope sightings + the estimate + player-placed
  markers/route lines. Reaching a landmark/settlement = a position fix
  (error resets).
- **Telescope** interactable: manned (deck-gun pattern — lock player, swap
  to a zoomed traversing camera). Spotting reveals POIs/landmarks/storms
  as bearing markers / chart pins; range cut by storm + night
  (weather/day-night synergy).
- Sun + pole star stay the coarse compass (already shipped).

**T2.4 — Spec sync + re-slot Future**
- Update `instructions.md` as pieces land (ongoing norm); adjust the
  success-criteria/tests that referenced the live `X/Z` readout.

### Dependencies
T2.0 first (regions feed T2.1 borders and T2.2 POIs). T2.3 is largely
independent but the chart is only interesting once T2.2 has POIs to find.

### Open implementation details (decide while building)
- World size/shape (rectangle vs disk) and border thickness.
- Sea-level + water rendering (simple plane vs shader) for the coast.
- Chart UI: scene vs code-built (cf. trade/cargo panels); dead-reckoning
  error model (constant drift vs noise-walk); fix sources.
- Telescope camera approach (FOV zoom vs separate cam) and spot test.
- How the bespoke editor exposes per-region params.
- Migration path off `HAND_PLACED_OASES` to the settlement registry.

---

## Future (re-slotted to build on Tier 2)

- **Debug / god mode for testing** *(do early — high leverage)*: a toggle
  (key/console) granting test conveniences — no survival drain / no
  death, infinite fuel & cargo, instant repair, free-fly or teleport,
  force weather/time, spawn a bandit. Host-gated; off by default. Every
  system since Tier 1 is slow to hand-set-up a test state for, so this
  pays for itself fast.
- **Unique quests / contracts**: per-settlement jobs (find / deliver /
  fetch) routed via the Tier 2 chart + settlement registry.
- **World impact**: purchase buildings at settlements; per-settlement
  reputation affecting prices/access.
- **Dynamic market**: supply/demand price movement + per-settlement stock
  variety, replacing static `Goods.PRICES`.
- **Bandit overhaul**: smarter AI, multiple/escalating raiders, retreat,
  loot/bounty — the parked T1.0 system, rebuilt; spawns from Tier 2
  regions/POIs (bandit camps) rather than the parked timer.
- **Food/drink variety**: multiple consumables with differing stat effects
  (the T1.5 data model already leaves room).
- **Deck pseudo-forces**: sliding cargo / crew lean under accel/turn (deep
  immersion; fights the world-scroll architecture — needs a replicated
  acceleration channel).
- **Audio pass** and **visual model overhaul** (deferred force-multipliers;
  best after the loop exists).
- **Drop carried items into the world**: E with no target spawns the held
  item's RigidBody3D scene as a networked, re-pickupable world object
  (server-spawned under WorldMap so it stays put in the dunes; item scenes
  gain a pickup Area3D). Deferred from the items pass — it's a small
  networked subsystem, not an inline tweak.
- **Automated smoke test / CI** guard.
