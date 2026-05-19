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

## Open implementation details (decide while building)

- Bunker/tank replenish UX: auto-draw buffer (recommended, low-UI) vs.
  explicit "load from cargo" interaction.
- Downed/revive model: revive cost, downed player's allowed actions,
  spectate vs. stay-on-deck.
- Survival drain/restore tuning and the heat/weather coupling curves.
- Workshop node disposition (remove vs. repurpose).
- Cargo capacity rebalance now that fuel + provisions + kits share the hold.

---

## Future (post–Tier 1, not scheduled)

- **World impact**: purchase buildings at settlements; settlement reputation
  affecting prices/access.
- **Dynamic market**: supply/demand price movement + per-settlement stock
  variety, replacing static `Goods.PRICES`.
- **Unique quests / contracts**: per-location jobs — find a location,
  deliver cargo, fetch cargo — using the navigational sun/stars as the
  routing tool.
- **Bandit overhaul**: smarter AI, multiple/escalating raiders, retreat,
  loot/bounty — the parked T1.0 system, rebuilt to be fun.
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
