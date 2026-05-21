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

**T2.0 — Region/biome field (foundation) — SHIPPED**
- `Regions` autoload (`scripts/autoloads/regions.gd`): three v1 regions
  (`dunes`, `salt_flats`, `badlands`) with per-region noise params, tint,
  hazard modifiers. Sampler strategy (`RegionSampler` interface,
  `NoiseRegionSampler` v1) so a `TextureRegionSampler` (T2.1) drops in
  via `set_sampler`.
- `chunk_gen.gd` does **per-vertex weighted blend** of region heights and
  paints region tints via vertex colour — smooth borders, no chunk seams.
  Per-region `FastNoiseLite` cached on `ChunkGen` keyed by `region × seed`.
- Hazards wired: `HAZ_THIRST_MULT` (player_controller), `HAZ_ROLLING_MULT`
  (ship_controller). Both are point queries at the ship's `world_offset`.
- Editor dock now syncs its `noise_seed` into `Regions.world_seed`; the
  per-region noise knobs that used to live on the dock moved into
  `Regions.gd`. Preview parity preserved.
- Spec sync: "Regions" section in `instructions.md`.

**T2.1 — World bounds + border biomes — SHIPPED**
- `Regions.WORLD_HALF_EXTENT` (2000 m default) + `BORDER_BAND` (240 m)
  define a finite world. `BoundedRegionSampler` wraps the interior noise
  sampler and ramps into a border biome on each edge.
- `coast` (height_offset −8, dips under SEA_LEVEL), `mountains`
  (height_offset +25, unclimbable by `grade_speed_sensitivity`), and
  `jungle` (heavy `HAZ_ROLLING_MULT`) added to `Regions._REGION_DATA`.
- Code-built `SeaPlane` (Y = `SEA_LEVEL`) under `WorldMap` reads as ocean
  where coast terrain dips below it.
- Border placement: +x → coast, −x → mountains, +z → mountains, −z →
  jungle. Corner ties favour the X axis.
- Hero edge sites via the bespoke chunk editor are still on the table as
  a follow-up; the dock works against the new sampler today.

**T2.2 — POI / settlement registry — SHIPPED (curated tier)**
- New `POIRegistry` autoload owns the four named settlements (Rust Pump,
  Tin Lantern, Dust Anvil, Salt Thread) with `oasis_subtype` + service
  flags (`market`, `fuel`, `water`, `provisions`, `repair`, `contracts`).
- `ChunkGen.build_object_records` reads `settlements_in_chunk(key, ...)`
  instead of the old `HAND_PLACED_OASES` dict (kept as an empty const for
  compat). Yaw stable per settlement id.
- `DebugPanel` teleport dropdown reads from the registry.
- **Deferred**: deterministic minor POIs seeded per region (salvage /
  wrecks / ruins). Stub left in `POIRegistry` for the future generator —
  pure function of `Regions.world_seed`.

**T2.3 — Navigation overhaul (earn position) — Slices A + B SHIPPED**

Slice A (foundation, shipped):
- `ChartState` autoload (host-authoritative; ship.cargo-style replication;
  full snapshot to joining peers). Owns `discovered_pois`, `markers`,
  `bearing_lines`, `last_fix`, `dr_enabled`.
- `ChartMap` pre-renders a region tint map from `Regions.region_at`.
- `ChartPanel` (code-built, full-screen overlay): region map background,
  discovered POI pins, player markers (16 cap), ship arrow / DR estimate /
  uncertainty circle / static last-fix marker.
- `ChartTable` interactable (player places in `ship.tscn`).

Slice B (telescope + triangulation + DR, shipped):
- `Telescope` interactable (manned, deck-gun pattern;
  `NetworkManager.current_observer` parallels `current_gunner`).
- Mouse-motion + held-key aim, batched per physics tick into one
  `request_aim_delta` unreliable RPC. Left-click = spot; result RPC'd back
  only to the spotter as POI name + bearing + range. No artificial range
  gate — storm/night degrade visibility *visually* through fog/dim light.
- `TelescopeOverlay` (code-built crosshair + live BRG readout + sighting).
- Chart bearing entry (POI dropdown + degree spinbox) + line rendering
  (per-spotter peer-id tint) + **Take fix (2+)** → 2D intersection of the
  two newest lines, stamps `last_fix`.
- Deterministic dead-reckoning drift (sin/cos of elapsed) + uncertainty
  circle. Hard mode (`dr_enabled = false`, host toggle) hides the live
  estimate entirely; only the static last-fix marker remains.

Slice C — DEFERRED (Future-ish):
- Replace HUD `X/Z` with HDG + speed (already shown) + a DR-blurred
  position. The user kept `X/Z` for now to cross-check Slice B math.
- Telescope storm/night range UI cues (current range readout; subtle fade
  in heavy weather). The data model supports it; not surfaced yet.
- Multi-observer handoff (more than one telescope; per-spotter colour
  legend on the chart).

**T2.4 — Spec sync + re-slot Future**
- `instructions.md` updated as each piece landed (ongoing norm).
- Success-criteria tests still reference live `X/Z` — to be rewritten
  once Slice C lands and HUD changes.

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

- **Free-fly camera** *(deferred)*: a real decoupled flight camera (separate
  rig, no collision, mouse-driven look) for inspecting the world from above.
  The shipped debug overlay (F1) covers most testing with speed × / jump × /
  no-clip — free-fly stays parked until inspection from arbitrary angles is
  actually needed (e.g. when validating Tier 2 regions / settlement layout).
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
