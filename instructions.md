# Steam Sand Ship — Co-op Prototype

A 3D co-op multiplayer game in Godot 4 (GDScript, ENet, no third-party
runtime addons; one in-editor authoring plugin). 2–4 players crew a
steam-powered **sand ship** that crosses a procedurally generated desert,
trading goods between oases and fighting off bandit raiders.

> This document is the up-to-date spec and mirrors the code. **Code is the
> source of truth.** If the two disagree, the code wins and this file is the
> bug. Keep it in sync when you extend the project.

---

## The fiction

The ship has a coal-fired boiler. Steam pressure drives the wheels. Without
fuel and water it coasts to a stop. The crew shares responsibilities, buys
low and sells high between desert markets, and mans a deck gun when raiders
appear. Any player can swap between roles freely.

| Role           | What they do                                                              |
|----------------|---------------------------------------------------------------------------|
| **Helmsman**   | Stands at the helm, sets engine order (Full Astern → Full Ahead), steers.  |
| **Stoker**     | Carries coal from the bunker and feeds the boiler firebox.                 |
| **Water hand** | When parked at a desert water tower, refills the boiler reservoir.         |
| **Gunner**     | Mans the deck gun, traverses/elevates, fires shells at bandits.            |
| **Loader**     | Carries ammo clips from the magazine to the gun, repair kits from workshop.|
| **Trader**     | At an oasis market, opens the trade panel; carries crates to the hold.     |

Roles are mutually exclusive only where it matters: you cannot hold the helm
and the gun at the same time. Carry-state (coal / clip / repair kit / cargo
crate) is per-player.

---

## Multiplayer model

- **Host / server**: peer ID 1, runs the world, spawns players, validates
  interactions, simulates the steam plant, bandit AI, and all damage.
- **Clients**: connect via IP, simulate their own player body locally,
  replicate position via `MultiplayerSynchronizer`.
- **Ship authority**: starts on the host. Taking the helm transfers
  multiplayer authority for the `Ship` node *and its
  `MultiplayerSynchronizer`* (set non-recursively so `Helm` stays
  server-owned) to the helmsman, so their inputs drive the ship for everyone.
- **Interact validation**: every interactable's `interact()` is server-only
  (`multiplayer.is_server()` gate). Clients send
  `_request_interact.rpc_id(1, target_path)` (player_controller).
- **Steam plant**: simulated host-side, broadcast to clients via
  `_receive_state` RPC throttled by per-field delta thresholds.
- **Combat**: hit detection is **host-only**; shells fly deterministically on
  every peer from spawn params. Damage and money/cargo mutations are
  host-authoritative and broadcast via `any_peer`/`call_local` RPCs that
  validate the sender id is 0 or 1 (because ship authority may have moved to
  the helmsman, but hits originate on the host).

---

## Project layout

```
res://
├── main.tscn                                  # Entry scene (Ship + WorldMap + UILayer)
├── project.godot                              # autoloads, input map, chunk_editor plugin enabled
├── instructions.md                            # This file
├── chunks/                                    # (created by the editor) registry.tres + scenes/ + overlays/
├── addons/chunk_editor/                       # In-editor bespoke-chunk authoring dock (@tool)
│   ├── plugin.gd / plugin.cfg
│   └── chunk_editor_dock.gd
├── scenes/
│   ├── world/world_map.tscn                   # ChunkManager + BanditDirector
│   ├── world/oasis.tscn                       # Village w/ Market child
│   ├── world/cargo_crate.tscn
│   ├── ship/ship.tscn                         # Player ship (hull faces, deck, wheels, helm, boiler, gun, hold…)
│   ├── ship/ai_ship.tscn                      # Bandit raider
│   ├── projectiles/cannonball.tscn            # Shared shell (player + bandit)
│   ├── player/player.tscn                     # CharacterBody3D + camera + interact ray + carry socket
│   ├── interactables/
│   │   ├── helm.tscn  coal_bunker.tscn  boiler_firebox.tscn  water_tower.tscn
│   │   ├── water_tank.tscn  repair_point.tscn  deck_gun.tscn  ammo_magazine.tscn  workshop.tscn
│   │   ├── oasis_market.tscn  cargo_hold_deposit.tscn  gangway.tscn  chart_table.tscn  telescope.tscn
│   └── ui/
│       ├── hud.tscn  lobby.tscn  name_tag.tscn
│       ├── gun_overlay.tscn                   # Crosshair / elevation / reload bar (gunner only)
│       └── trade_panel.tscn                   # Buy/sell modal at a market
└── scripts/
    ├── main.gd  network_manager.gd (autoload)  game_state.gd  audio_manager.gd  regions.gd (autoload)  poi_registry.gd (autoload)  chart_state.gd (autoload)
    ├── ship_controller.gd                     # Locomotion + damage model + economy state
    ├── steam_plant.gd                         # Coal → heat → pressure → power
    ├── player_controller.gd                   # Movement, look, interact, carry, helm/gun lock
    ├── player_nametag.gd  hud.gd  lobby.gd  gun_overlay.gd  trade_panel.gd  debug_panel.gd  chart_panel.gd  chart_map.gd  telescope_overlay.gd
    ├── ai_ship_controller.gd                  # Bandit brain (APPROACH/PACE, fires broadsides)
    ├── bandit_director.gd                     # Host-only bandit spawner + cannonball spawn/despawn hub
    ├── cannonball.gd                          # Deterministic ballistic shell, host-only hit detection
    ├── goods.gd                               # Static Goods registry (ids, prices, colours)
    ├── chunk_manager.gd                       # Streams chunks; world-scroll; registry resolution
    ├── chunk_gen.gd                           # ChunkGen — node-free mesh/prop generation (shared w/ editor)
    ├── chunk_registry.gd / chunk_overlay.gd / chunk_object.gd  # Bespoke-chunk resources
    ├── chunk_authoring.gd                     # ChunkAuthoring — editor-side save/register helpers
    ├── interactable.gd                        # Base Area3D class
    └── interactables/
        ├── helm.gd  coal_bunker.gd  water_tank.gd  boiler_firebox.gd  water_tower.gd
        ├── repair_point.gd  workshop.gd (kit repository)  bed.gd  chart_table.gd  telescope.gd
        ├── (scripts/cargo_panel.gd — code-built withdraw chooser)
        ├── (scenes/items/ — water_bottle.tscn, sausage.tscn physical consumables)
        ├── deck_gun.gd  ammo_magazine.gd  workshop.gd
        ├── oasis_market.gd  cargo_hold_deposit.gd  gangway.gd
```

---

## The world-scroll trick (important!)

The ship never moves in world space. Its `position.x` / `position.z` stay at
0; only `position.y` lerps to follow terrain height. Two pieces of state on
`ship_controller.gd` are authoritative:

- `virtual_yaw` — the heading the ship is "really" facing.
- `world_offset` — the position the ship is "really" at in the dunes.

`chunk_manager.gd` reads both each physics frame and applies the inverse to
the `WorldMap` node (`position = -(Basis(UP,-yaw) * offset)`, `rotation.y =
-yaw`). From the player's perspective the ship sails the desert;
mechanically the desert slides under a stationary ship.

**Consequences — internalize these before extending anything:**

- Players walking the deck need no vehicle-velocity compensation;
  `move_and_slide()` Just Works because ship-local space *is* world space.
- Anything that must stay put in the dunes (disembarked crew, oases,
  bandits, cannonballs) is a child of **WorldMap** and tracks its own
  `world_offset`. Anything that rides the ship (crew on deck, the gun) is a
  child of **Ship/PlayerContainer** (or Ship).
- For any world-space position use `ship.world_offset`, **never**
  `ship.global_position`.
- **Y convention for projectiles**: the ship's `world_offset.y` is always 0
  and WorldMap doesn't translate vertically, so cannonballs treat
  `world_offset.y` as scene-space Y directly. Muzzle/aim heights use the
  *visual* scene Y (`global_position.y` / the AI's `_current_y`), not the
  offset — otherwise shots fly through the dunes. See `deck_gun._spawn_shell`
  and `ai_ship_controller._fire_cannon`.

The gangway (`gangway.gd`) is the boarding point: it reparents a player
between `Ship/PlayerContainer` and `WorldMap`, server-validated and
RPC-broadcast, only while the ship is ~stopped.

---

## Vehicle dynamics

On top of the kinematic drive, `ship_controller.gd` layers three systems
that sell the mass of a large wheeled hull (all tunable via `@export`):

- **Terrain-coupled longitudinal dynamics** — the slope under the bow
  (`_slope_along_heading`) re-scales the speed the drivetrain can
  *sustain* while powered (`grade_speed_sensitivity`): the telegraph can
  read Full Ahead while you only crawl up a dune and overspeed down it
  (forward cap = `eff_max_forward × max_downhill_overspeed`) — so the HUD
  speed visibly tracks the terrain. Unpowered (Stop / starved boiler),
  raw `grade_gravity` rolls a parked hull down the grade. Steeper ground
  adds rolling resistance. Closes a feedback loop with the steam plant.
  Runs on the helm authority (mutates the replicated `current_speed`).
- **Suspension + weight transfer + wheel conform** — body heave is a
  spring-damper (`suspension_stiffness`/`damping`) instead of a flat lerp,
  with a rate-limited downward chase (`max_suspension_drop`) so the hull
  floats briefly off sharp crests. Longitudinal accel pitches the hull
  (squat / brake-dive), lateral load rolls it. Each `Wheel*` child is then
  planted on the sand directly under it (`_conform_wheels`, tuned via
  `wheel_ground_offset`) so the wheels track the dunes independently while
  the hull keeps the smoothed pose above. Runs on **every peer** — only
  needs the replicated speed/yaw, so no extra sync.
- **Yaw inertia & turning radius** — the bow swings with momentum
  (`yaw_inertia`), can't turn tighter than `min_turn_radius` (so high
  speed forces a planned wide arc), and self-centres via `caster_strength`
  when the wheel is released. A standstill hull can't pivot.

---

## Steam plant

`coal_in_firebox → fire_heat → steam_pressure → request_power → drive`.
Water is consumed proportional to steam generated; at 0 water steam
generation stops. Above `relief_pressure` the safety valve vents.
`engine_order` maps to a steam *demand* fraction (Full Ahead is
disproportionately hungry). Boiler **power-system damage** scales pressure
and water leak rates up to 3× — a wrecked boiler has far less range on the
same coal/water until repaired. Host-only sim; clients get
delta-thresholded `_receive_state` RPCs.

**Fuelling (Tier 1, T1.2).** The **coal bunker** (`coal_bunker.gd`) is now a
finite store: a stoker draws one load at a time (decrementing
`bunker_coal`, replicated for prompts); when empty, an explicit E *loads*
it in one batch from `ship.cargo["coal"]`. The new **water tank**
(`water_tank.gd`, `WaterTank` in ship.tscn) feeds the boiler reservoir from
`ship.cargo["water"]` (each cargo unit = `water_per_unit` boiler water);
desert water towers still top it up directly for free. Empty bunker + empty
hold → no fuel → the ship strands (T1.6 — not a game-over).

---

## Character controller

Third-person over-the-shoulder. In free-look the **body** carries the yaw
(`rotation.y = _yaw`) so the character model turns with the camera and it
replicates for free (`player.tscn` synchronises `position` + `rotation`);
the `SpringArm3D` only pitches. While helming, the body is locked and the
arm carries yaw instead (`_rig_spring_euler`). The spring arm has
`collision_mask = spring_collision_mask` (world solids) and excludes the
own body, so the camera pulls in front of walls/terrain instead of
clipping. `shoulder_offset`/`camera_height` frame the camera; if the
imported mesh faces backwards, set `model_yaw_offset_deg` (applied once,
scale-preserving).

Animations live on `characterMedium/Root/AnimationPlayer`. Clip names are
resolved by keyword (`_resolve_animations` — robust to `Root|Idle`,
`run/…`, `jump/…`); idle/run loop. The authority picks a state
(idle/run/jump from floor + horizontal speed; locked roles & dead → idle)
and broadcasts it only on change via `_set_anim_state` (call_local +
reliable), so every peer animates correctly off the same signal.

---

## Crew survival (Tier 1, T1.5)

Per-player `hunger` / `thirst` / `energy` (0–100) on `player_controller.gd`,
simulated on each player's own authority (`_tick_survival`). Drain scales
with activity and the **environment** — thirst rises with daylight
(`day_night.get_daylight`) and sandstorm intensity
(`weather.get_storm_intensity`), and hunger/thirst drain
`exposed_drain_mult`× faster when the player is **off-ship** (reparented
under WorldMap via the gangway — i.e. walking the open dunes). Low `energy`
scales movement speed down to `low_energy_speed_floor`.

Consumption is item-driven: carry a `cargo_food` / `cargo_drinking_water`
good (bought at a market like any cargo, T1.1) and press **E with nothing
targeted** to eat/drink it (`_try_consume_carried`). `hunger` or `thirst`
at 0 → **collapsing**: a `critical_grace`-second window where the crew
member can barely move (`critical_speed_mult`) — enough to crawl to
supplies or be carried — before they actually die. Eating/drinking back
above 0 cancels it. Death freezes the body (`set_survival_dead` RPC). The
HUD readout goes amber on a low need and pulses red while collapsing.
Reaching a settlement and making **any market trade** revives + re-provisions
the whole crew (`oasis_market._revive_crew` → `revive_survival` RPC). If
**every** crew member is dead the run ends — the host calls
`NetworkManager.report_all_dead`, which reuses the connection-failed path to
drop everyone back to the lobby ("All crew perished in the desert").

**Stranding (T1.6)** is emergent, no special code: an empty bunker + empty
hold (T1.2) leaves the ship immobile; the crew can disembark and walk for
supplies, but exposed desert drain makes that desperate. It is *not* a
ship-level game-over — only crew death ends the run.

HUD: a code-built bottom-left readout (`hud._on_survival_changed`) shows the
local crew member's needs (red "DOWNED" when dead), bound whether aboard or
disembarked.

**Items, withdraw & rest.** `water_bottle` / `sausage` (scenes/items, real
RigidBody3D meshes) are non-tradeable `Goods` entries — held as the actual
scene prop (frozen) and consumed via E-with-no-target to slake thirst /
hunger; a few of each are in the hold on spawn. The **cargo hold** is now
two-way: carrying a crate → deposit (host path); empty-handed → a code-built
`CargoPanel` chooser (opened locally like the trade panel) whose Take button
RPCs `CargoHoldDeposit.request_withdraw` so the host moves one unit from
`ship.cargo` into your hands. The **bed** (`bed.gd` on a `RestPoint` Area3D
child of bed_single.tscn) restores `rest_amount` energy per E press
(`player.rest_energy` RPC). *Dropping* carried items in the world is not yet
implemented — see ROADMAP "Future" (needs a networked world-item spawn +
re-pickup; the item scenes are RigidBody3D for exactly this).

---

## Combat & damage

**Deck gun** (`deck_gun.gd`, server-authoritative, no authority transfer —
discrete inputs are cheap to RPC). Gunner taps A/D to traverse, W/S to
elevate (clamped), left-click to fire. Ammo is clip-fed: `max_ammo` (5)
shells; a clip can only be loaded when the gun is fully empty. Firing is
reload-gated (`reload_time`) and ammo-gated. `traverse_yaw`/`elevate_pitch`/
`ammo` replicate via the gun's synchronizer.

**Ammo magazine** / **workshop** are CoalBunker-style carry sources. The
workshop is dual-mode: empty-handed → take a repair kit; carrying a kit →
consume it and repair the ship's *most-damaged* system by `repair_amount`.

**Cannonball** (`cannonball.gd`): spawned via `BanditDirector` (the central
spawn/despawn RPC hub for all shells). Trajectory is closed-form
(`origin + v·t + ½·g·t²`) computed on every peer; **only the host runs hit
detection** (shape query → classify struck part by collider name →
`register_hit(part, impact_world, velocity_world)`).

**Damage model** (`ship_controller.gd`): server-authoritative
`system_integrity` dict — 5 hull faces (`hull_left/right/fore/aft/deck`),
the external `mobility` (wheels), and 3 *internal* systems
(`power/control/cargo`). A direct hit subtracts `direct_hit_damage` from the
struck system — this is the **only** way `mobility` is damaged: the wheels
sit outside the hull, so a direct wheel hit degrades them and nothing else
reaches them. Hull-face hits additionally roll a **penetration cone**:
chance rises as that wall's HP falls (`(1-wall_hp)·penetration_base_max`),
projected forward along the shell's velocity from the impact point; each
**internal** system inside the cone gets an independent damage roll
(multiple per shell is intentional). The cone targets only
`power/control/cargo` — it models fragments reaching systems *behind* a
breached wall, so external `mobility` is deliberately excluded.
`mobility` caps top speed (min 30%), `control` caps turn responsiveness (min
20%), `power` worsens boiler leaks. Internal-system centroids are read live
from scene nodes (`BoilerFirebox`, `BridgeHouse`, `CargoHold`) with const
fallbacks. Damage/repair broadcast via sender-validated RPCs; HUD shows a
9-value readout; `damage_taken` drives per-peer screen shake.

**Machine wear (Tier 1, T1.3 + Balance pass).** `_apply_machine_wear` runs
**server-side**. Wear is nonlinear in two directions:

- **Engine-order scaling.** `power` wear ∝ `(order_frac)³`; `mobility` wear
  ∝ `(0.3 + 0.7 × speed_frac²)` per metre; `control` ∝ `speed_frac²`.
  Net effect: Slow / Half / Full barely wear, Flank (order 4 — the new
  redline label) is where almost all the wear comes from.
- **Damage spiral.** `_damage_amp(integrity) = 1 + 4 × (1 − integrity)²`
  multiplies every wear bucket: 100 % → ×1.0, 80 % → ×1.16, 60 % → ×1.64,
  40 % → ×2.44, 0 % → ×5.0. So an 80 % system reads "barely any change",
  60 % is "actively self-damaging — fix it", and below 40 % decays fast.

Performance penalties use the same squared-damage curve
(`_damage_curve`): `factor = 1 − damage² × penalty_max`. `mobility` floors
at 30 % top speed, `control` at 20 % turn rate. Boiler leak rate in
`steam_plant._physics_process` follows the same squared curve up to 3×.
Wear flushes through `_apply_damage` in `wear_apply_step` chunks
(0.005 = 0.5 HUD points per pulse) so the reliable RPC stays cheap and
feedback ticks smoothly even at the low base rates.

**Repair (Tier 1, T1.4).** Repair is now *spatial*. `workshop.gd` is a
**kit repository** (mirrors the coal bunker: take a `cargo_repair_kit`, or
batch-load the store from hold cargo); it no longer repairs. Three
`repair_point.gd` interactables (`RepairPower`/`RepairControl`/
`RepairMobility` in ship.tscn, `target_system` overridden per instance) sit
at the boiler / bridge / wheels — carry a kit there and E consumes it to
`ship.repair_system(target_system, repair_amount)`. Kits are ordinary cargo
(bought at markets, T1.1), so repair draws on the economy.

**Bandits** (`ai_ship_controller.gd` + `bandit_director.gd`): **parked for
Tier 1** — `bandit_director.spawn_enabled` defaults `false`, so no raiders
spawn (the combat/AI system is slated for an overhaul; see ROADMAP.md →
T1.0). The machinery below is intact and the cannonball spawn/despawn RPC
hub is still used by the player deck gun. When enabled, the host-only
director rolls on a timer to spawn one bandit at a time *behind* a moving
player. The bandit shares the `world_offset`/`virtual_yaw` model, lives
under WorldMap, and runs a two-state machine: **APPROACH** (drive straight
at the player) → **PACE** (slot to a fixed standoff on one side, match
heading/speed, fire `fire_interval` broadsides with ballistic drop
compensation + spread). Simpler 2-bucket damage (`hull`, `mobility`) — both
external, so every hit is a direct hit and there is no penetration cone
(bandits have no systems behind the hull). Hull at 0 →
`director.destroy_bandit`. No retreat — fights to the death.

---

## Economy & trade

`Goods` (`goods.gd`) is a static registry: tradeable goods (`coal`,
`water`, `spice`) plus Tier 1 provisions/supplies (`repair_kit`, `food`,
`drinking_water`) — each with display name, `carry_id` (`cargo_<good>`),
and tint. All six move through the *same* market / cargo-crate / hold
pipeline (and `ship_controller.cargo` has a key for each); the provisions
are also *consumable* (kits repair ship parts, food/drinking water satisfy
crew needs — see ROADMAP.md T1.4/T1.5). Prices are per **oasis type**
(`mining` vs `caravan`); buy > sell at every oasis, so profit comes only
from inter-oasis arbitrage (mining sells coal cheap / pays for spice;
caravan is the inverse).

Ship economy state lives on `ship_controller.gd`: `money` and a `cargo`
dict, `cargo_capacity` crates total. All mutations go through host-only
methods (`try_spend`, `receive_money`, `add_cargo`, `remove_cargo`) that
broadcast `_set_money`/`_set_cargo` RPCs and emit `money_changed`/
`cargo_changed`.

Flow: press E on an `oasis_market` → player_controller opens the local
`trade_panel` (UI-only, not routed through host). Buy/Sell buttons RPC
`request_buy`/`request_sell` to the host market node. Host validates funds +
capacity; **buy spawns physical crates** next to the stall. Crew carry
crates (`cargo_crate.gd`, picked up into the `cargo_<good>` carry slot) to
the ship's **cargo hold deposit**, which increments `ship.cargo`. Selling
reads `ship.cargo` directly — no need to physically haul crates back.

**Crate visuals.** Each tradeable good in `Goods.ALL` carries a `prop_scene`
path + `carry_scale`. The `CargoCrate` (Area3D wrapper) instantiates the
prop under its `Visual` slot at `_ready`, freezing the RigidBody and
zeroing collision so it sits as decoration alongside the interact volume.
The same prop is used in the player's `CarrySocket`, scaled by
`carry_scale`, so the silhouette you pick up matches the one you carry.
Paired goods share a prop intentionally (water / drinking_water → barrel,
food / repair_kit → crate) — a billboarded `Label3D` child of the crate
fades in when the local player is within `label_visible_range` (default
4.5 m) and shows the actual contents, so identification happens at pickup
range, not at distance. Each peer evaluates the label independently
against its own local player (no replication needed; purely cosmetic).

---

## Day/night & weather

> **Planned (ROADMAP → Tier 2 navigation):** the always-on HUD `X/Z`
> readout will be replaced by HDG + speed + a dead-reckoning *estimate*;
> precise position will be earned via a **chart table** + **telescope**
> (manned, deck-gun pattern) + the sun/pole-star compass, with landmark
> arrival as a fix. The sun/star compass below is the foundation that
> system builds on.

**Renderer**: the project runs **Forward+** (`rendering_method` and
`.mobile` both `forward_plus`) so volumetric fog and proper sky/light control
are available. No mobile/web target.

**Shared clock**: `GameState.world_epoch` (Unix timestamp) + `weather_seed`
are stamped by the host in `host_game` and replicated **once** to each
joining peer via `NetworkManager.notify_world_clock` (sent in
`_on_peer_connected`). `GameState.world_time()` returns seconds since the
epoch (falls back to a process-local clock solo/in-editor). Day/night and
storms are then computed **deterministically and locally on every peer** —
no per-frame replication. Assumes roughly synced wall clocks (LAN co-op);
a host-correction RPC can be added later if drift shows.

**DayNightCycle** (`day_night_cycle.gd`, under WorldMap). ~40-min cycle
(`day_length_seconds`, tunable). It does **not** spawn its own rig — it
finds and drives the existing `main.tscn` `WorldEnvironment` +
`DirectionalLight3D`, plus a code-built Moon light and a Pole Star marker.

Navigational relevance is the whole point: the sun/star direction is
computed in a **fixed world frame** (`+X`=East, `-X`=West, `+Z`=North,
`-Z`=South, `+Y`=up) and then rotated by `Basis(UP, -ship.virtual_yaw)` —
the *same inverse rotation ChunkManager applies to the dunes*. So the sun
sweeps across the sky in lock-step with the terrain as you steer; hold a
heading by keeping it at a constant screen angle. The Moon/PoleStar rig is
`top_level` and re-pinned to the ship's scene position every frame, then
only rotated, so finite-distance markers don't parallax as `world_offset`
grows (they read as if at infinity = a true bearing). At night the Pole
Star (fixed to world-North) is the compass; a dim Moon light + raised
ambient keep the dunes readable (Forward+ has no GI here). Energy/colour of
sun, moon, ambient, sky and fog are hand-authored ramps keyed on a smoothed
`daylight` factor.

Visuals are procedural (no asset files, per project ethos): a sun-glow and
moon billboard ride the same rig (camera-facing quads with code-generated
radial `GradientTexture2D`s — sun additive so it blooms, moon a crisper
emissive disc). The "too bright to look at" sun is sold by HDR `glow`
(ramped with daylight), a filmic tonemap, and optional auto-exposure
(`use_auto_exposure`) on the WorldEnvironment's camera attributes — not by a
texture. Tunable exports: disc angular sizes, `celestial_distance`,
`glow_day_intensity`. Public API: `get_time_of_day()`, `get_daylight()`,
`is_night()`, `get_phase_name()`.

**WeatherSystem** (`weather_system.gd`, under WorldMap, **must process
after DayNightCycle** — child order in `world_map.tscn` enforces this; it
reads the fog colour the cycle just set and lerps toward ochre so the two
compose). Sandstorms are **localized**: each storm has a centre in
`world_offset` space, a radius, and a time window, all a pure function of
`weather_seed` + the period index. The `FogVolume` is a child of this node
(hence of WorldMap) positioned at the storm's **world coordinates** — the
same convention chunk bodies use — so the world-scroll trick keeps the
storm fixed in the dunes while the ship sails through it, for free. The
centre is latched once from the live (replicated, deterministic)
`ship.world_offset` when a storm first goes active, so storms fall along
the crew's route (same idea as bandit_director). Three layers:
`Environment` depth fog (ochre distance tint), volumetric fog + the
`FogVolume` (the visible body), and a `GPUParticles3D` grit emitter pinned
to the ship. Intensity (0..1) = distance-to-centre × time-ramp. Gameplay
hooks: `bandit_director` multiplies spawn chance by storm intensity
(`storm_spawn_boost`), `ai_ship_controller` holds fire in a heavy whiteout
(intensity > 0.6), and the HUD heading line shows the sky phase + a
`SANDSTORM` warning. Public API: `get_storm_intensity()`, `is_storming()`.

---

## Regions (Tier 2, T2.0 + T2.1)

The desert is divided into named **regions** (biomes) by a single autoload,
`Regions` (`scripts/autoloads/regions.gd`). v1 ships six: three **interior**
regions — **dunes** (baseline), **salt_flats** (flat / pale / `thirst_mult`
1.5), **badlands** (rough / dark / `rolling_resistance_mult` 1.8) — plus
three **border biomes** that enforce the world bounds (T2.1): **coast**
(terrain offset well below sea level so the water plane reads as ocean),
**mountains** (height_offset 25m + noise — unclimbable by the
`grade_speed_sensitivity` model), and **jungle** (heavy rolling resistance).
Each `RegionData` row sets `noise_frequency` / `octaves` / `lacunarity` +
`height_scale` + `height_offset` (additive Y bias for borders), a `tint`
Color, and a `hazard_modifiers` Dictionary.

### Finite world bounds (T2.1)

The world is a rectangle of `±Regions.WORLD_HALF_EXTENT` (default 2000 m,
~50 chunks each way). A `BorderRegionSampler` wraps the interior sampler
and replaces its output with a border-biome blend inside `BORDER_BAND`
metres of the edge — linear ramp from "interior" to "100% border". Which
border is which depends on which axis is closest to the edge: **+x →
coast**, **−x → mountains**, **+z → mountains**, **−z → jungle**. Corner
ties favour the X axis so corners read as ocean or cliff rather than
jungle. Past the edge, weight is fully on the border (you can drive
through coast water onto submerged sand, but mountains and jungle make
that miserable through rolling resistance + the height wall).

A code-built **`SeaPlane`** under `WorldMap` (built by
`ChunkManager._build_sea_plane`) sits at `Regions.SEA_LEVEL` (Y = −8 m;
below the deepest interior dune trough) over the whole world extent +
border band. Coast terrain (height_offset −13) sits 2.5+ m below the
plane and reads as ocean; inland terrain is above and hides the plane.

### Authoring a region map from a texture (T2.1 paint workflow)

Assign a `Texture2D` to `ChunkManager.region_map` (and optionally
override `region_map_extent`, default `Regions.WORLD_HALF_EXTENT`). At
`_ready` the noise + bounded-border sampler is swapped for a
`TextureRegionSampler`. Workflow:

1. Paint a small image (256×256 covers ±2000 m at 16 m / pixel) using
   the colours in `Regions.REGION_PALETTE` — yellow=dunes, near-white=
   salt_flats, brown=badlands, blue=coast (water), grey=mountains,
   green=jungle. Paint your borders directly (no separate ring code).
2. Import with **Compress = Lossless** (or VRAM Uncompressed) and
   **Mipmaps = Off** so `get_image()` returns crisp palette pixels.
3. Drop the texture onto the WorldMap node's `region_map` field. World
   coords (x, z) ∈ [−extent, +extent] map to UV [0, 1]; out-of-bounds
   clamps to the texture edge, so painting your border biome up to the
   edge of the image continues the wall to ±∞.

Sampling is **bilinear**, then the resulting colour is classified
against the palette by squared-RGB distance. A sample very close to one
palette entry returns `{id: 1.0}`; in-between samples (the natural
pixel-edge gradient between two neighbouring colours) return the two
nearest entries inverse-distance-weighted. So borders are smooth
without any alpha or weight channel in the image — just paint flat
colours and let pixel interpolation do the blend.

POIs are a separate data layer (`POIRegistry` — see below). Paint the
biomes; edit settlements in the registry. Independent.

The (x, z) → region mapping is behind a strategy so it can be swapped
without touching consumers:

- `RegionSampler.sample(x, z) → Dictionary[id: float]` — weights sum to ~1.0.
- `NoiseRegionSampler` (v1) — a low-frequency simplex banded by thresholds;
  inside a small halfwidth around each threshold it returns two regions
  with a linear blend so borders fade instead of snapping. Seeded from
  `Regions.world_seed`, which `ChunkManager._ready` sets from its
  `noise_seed` export — every peer's region field agrees deterministically.
- `TextureRegionSampler` is planned for T2.1 (hand-drawn map of a finite
  world) and only requires `Regions.set_sampler(...)`.

Public API (read it from anywhere; the chart system in T2.3 will use the
same calls):

- `Regions.region_weights(x, z)` — the weight dict, for blending heights /
  tints inside `ChunkGen`.
- `Regions.region_at(x, z)` — dominant id, for point queries: where the
  ship is, where a prop got placed, future chart pins.
- `Regions.get_modifier(id, key, default=1.0)` — read one hazard mod.
- `Regions.get_modifier_at(x, z, key, default=1.0)` — convenience for the
  dominant region's modifier at a point. Used by `player_controller`
  (`HAZ_THIRST_MULT`) and `ship_controller` (`HAZ_ROLLING_MULT`).

Hazards are **point queries at the ship's `world_offset`**, not per-chunk —
so a single crew on one ship all share the same regional climate even
while standing in different scene-local spots near the deck.

---

## POI registry (Tier 2, T2.2)

Curated settlements + (future) minor POIs live on a single autoload,
`POIRegistry` (`scripts/autoloads/poi_registry.gd`). v1 holds four named
settlements at fixed `world_pos` coords, each with an `oasis_subtype`
(mining / caravan — drives the market price column) and a list of
**service flags** (`market`, `fuel`, `water`, `provisions`, `repair`,
`contracts`). This replaces the ad-hoc `ChunkGen.HAND_PLACED_OASES` dict;
the four existing oases were re-homed here under names (Rust Pump, Tin
Lantern, Dust Anvil, Salt Thread) so balance / playtests don't move.

Consumers:

- `ChunkGen.build_object_records` calls
  `POIRegistry.settlements_in_chunk(key, chunk_size)` to spawn oases at
  the registry's `world_pos`. Yaw is hashed off the settlement id so
  rebuilds are stable.
- `DebugPanel._build_teleport_targets` reads the curated list to populate
  the teleport dropdown — adding a settlement makes it appear there for
  free.
- Planned (T2.3 chart): pin marker text is `display_name`; the icon set
  reads from the service flags; "where am I?" uses `Regions.region_at`.

Minor POIs (salvage, wrecks, ruins seeded per region) are deferred — the
registry leaves a stub but no entries. Determinism for the future
generator: pure function of `Regions.world_seed` + per-region salt.

---

## Navigation chart (Tier 2, T2.3 — Slices A + B)

Crew-shared chart state lives on a third autoload, **`ChartState`**
(`scripts/autoloads/chart_state.gd`). Host-authoritative; replication
mirrors `ship.cargo` (per-mutation `any_peer / call_local / reliable`
RPCs, sender id ∈ {0, 1} gate, full snapshot to joining peers via
`NetworkManager.notify_chart_state`).

Tracked state:
- `discovered_pois` — id-keyed dict. All curated `POIRegistry` settlements
  are seeded as discovered at session start (the "important / main POIs"
  pre-marked on the chart). Future minor POIs require discovery via the
  telescope or landmark arrival (Slice B).
- `markers` (max **`MAX_MARKERS = 16`**) — `{world_pos, label, color,
  placed_by}`. Any crew member can drop a marker; host validates the cap.
- `bearing_lines` — `{poi_id, bearing_deg, placed_by}`, Slice B (telescope
  sightings the chart player enters from voice chat).
- `last_fix` — `{world_pos, time}` of the most recent confirmed position
  (triangulation intersection or landmark arrival). Resets DR error.
- `dr_enabled` — hard-mode toggle. False = chart shows no live position
  estimate; only `last_fix` plus drawn bearings. Host-only flip.

### Chart UI (`scripts/chart_panel.gd`)

Code-built `Control` parented to `UILayer` by `main.gd` (same instantiation
pattern as `DebugPanel`). Hidden until a `ChartTable` interactable opens
it — the panel intercepts the local interact press through
`player_controller._poll_interact` (mirrors trade-panel / cargo-panel) so
no host RPC is round-tripped for the open.

Layers (top-to-bottom on a 720 px square):
1. **Region tint background** — `ChartMap.build()` walks the
   `Regions.region_at` field on a 256×256 grid covering
   `WORLD_HALF_EXTENT + BORDER_BAND`, writing `REGION_PALETTE` colours.
   Works for both noise and texture-painted maps because both flow
   through `Regions`.
2. **POI pins** for every discovered settlement (display_name label).
3. **Player markers** with their labels.
4. **Ship arrow** (Polygon2D) re-positioned every `_process` from
   `ship.world_offset` / `virtual_yaw`. Slice B will branch this on
   `dr_enabled` (DR estimate + uncertainty circle vs. static last-fix).

Coordinate convention: pixel (0, 0) is top-left; **world +Z = north = top
of the chart**. Matches the inverted-V mapping used by the
`TextureRegionSampler` so an authored region map looks the same when you
read it on the in-game chart.

Controls:
- Toggle **Place marker** → click on the map; LineEdit label is captured
  before the click. Sends `ChartState.request_add_marker` to the host.
- **Clear markers** — `request_clear_markers`.
- **DR enabled** check (disabled-greyed-out for non-hosts).
- Esc / Close button → `close()`.

### Chart table (`scripts/interactables/chart_table.gd`,
`scenes/interactables/chart_table.tscn`)

A code-mesh table prop. Joins group `chart_table`; `interact()` is a no-op
since the panel is opened locally (see player_controller intercept). Place
it manually in `ship.tscn` wherever the bridge / chart room lives.

### Triangulation + telescope (Slice B — shipped)

**`Telescope`** is a deck-mounted spy-glass interactable
(`scripts/interactables/telescope.gd`, `scenes/interactables/telescope.tscn`).
Same manned pattern as the deck gun: server-authoritative traverse +
elevate (synchronised), one observer at a time
(`NetworkManager.current_observer` parallels `current_gunner`),
`player_controller` swaps to `TelescopeCamera` (15° FOV "zoom") and
freezes mouse-look while observing.

Observer inputs:
- **Mouse motion** drives fine aim (continuous; each physics tick the
  observer flushes accumulated mouse-pixels × `MOUSE_SENSITIVITY` into a
  single `request_aim_delta` unreliable RPC).
- **A / D / W / S held** sweep at `key_aim_rate` rad/sec (45°/sec default)
  — added into the same per-tick delta.
- **Left mouse** = `request_spot` → host finds the nearest discovered POI
  inside the `spot_cone_deg` (3°) crosshair cone. **No range gate** — if
  you can see it in the scope, you can spot it (storm/night degrade
  visibility *visually* through fog and dim light, which is the natural
  in-fiction limit). Result RPCs back **only to the spotter** as POI name
  + exact bearing + range ("Rust Pump — bearing 047.3° — 1.23 km" on the
  `TelescopeOverlay`).
- **E** unmounts.

Elevate clamp is −30° to +45°. Camera sits past the front of the tube so
the tube interior never clips the view, even at full depression.

Spotting a POI that was undiscovered (planned minor POIs) flags it via
`ChartState.host_mark_discovered`. v1 settlements are all pre-discovered
so this is a no-op today; the wiring is ready for T2.2 minor-POI work.

**Chart bearing entry.** The spotter reads the line over voice; the chart
player picks the POI from a dropdown (only **discovered** POIs appear),
types the bearing in degrees, clicks Add. `ChartState.request_add_bearing`
stores it (replicated to all peers). The chart panel draws the line
through `poi.world_pos` along the spotter's back-azimuth, extending in
both directions (`BEARING_LINE_LENGTH` = 4500 m). Lines are tinted by
**spotter peer id** so the chart reader can tell whose bearings cross.

**Take fix.** Once ≥ 2 bearing lines exist, **Take fix (2+)** intersects
the two most recent in 2D (`_compute_fix_from_two_latest`). The crew's
`last_fix` updates at the intersection (replicated), resetting DR error.
Bearing lines stay drawn — clearing is manual (**Clear lines** button)
so additional bearings can refine confidence visually.

**Dead reckoning.** `ChartState.dr_estimate(now, ship_pos)` and
`dr_uncertainty_radius(now)` return a deterministic drifted estimate +
growing uncertainty circle:

```
elapsed = now - last_fix.time
drift   = (sin(elapsed × ω + φ), cos(elapsed × 1.3ω + φ)) × min(elapsed × 0.4, 150)
radius  = clamp(elapsed × 0.7, 0, 200)
```

Every peer computes the same drift from `GameState.world_time()` +
`last_fix`, so all chart views agree.

**Hard mode** (`dr_enabled = false`, host-only toggle): chart shows no
live estimate at all. Only the static `last_fix` marker (green X)
remains. Triangulation is the only way to update position knowledge.

The chart's per-frame ship-arrow path branches:

| `dr_enabled` | `last_fix` | What's drawn                                    |
|--------------|-----------|--------------------------------------------------|
| true         | yes       | drifted-blue arrow + uncertainty circle, no real |
| true         | no        | real ship arrow (no drift accumulated yet)       |
| false        | yes       | only the static last-fix X — no arrow            |
| false        | no        | nothing (truly blind — must triangulate)         |

### Slice C scope (planned, not in this build)

- Minor POIs seeded per region (POIRegistry expansion). Spotting fills
  them onto the chart.
- Storm/night UI cues on the telescope (current range readout, fading
  text in heavy weather).
- Multi-observer support (more than one telescope; per-spotter handoff).
- Replace the HUD's `X / Z` readout with HDG + speed + (DR-blurred)
  position once the chart system has bedded in.

---

## Chunk system & bespoke editor

> **Planned (ROADMAP → Tier 2):** the world becomes finite & bounded with
> border biomes (coast/mountains/jungle) and a curated **POI/settlement
> registry** replacing the arbitrary `HAND_PLACED_OASES` chunk keys. The
> region/biome field (T2.0) is already shipped — see "Regions" above.

`chunk_manager.gd` streams `chunk_size` tiles within `load_radius`. All
mesh/prop construction is **node-free static code in `ChunkGen`**
(`chunk_gen.gd`) so the in-editor preview is bit-identical to the streamed
runtime. Heights and terrain tint at every vertex are a **per-vertex
weighted blend** of every active region's own noise + colour, with weights
read from `Regions.region_weights` — so a chunk straddling two regions
shows a smooth gradient instead of a chunk-aligned step. Tint is painted
via vertex colour on a StandardMaterial3D with `vertex_color_use_as_albedo`.
Adjacent chunks still share edge samples (noise is evaluated at world-grid
positions), so borders stay seamless. Prop layout is deterministic
(`rng.seed = hash(key)` — **draw order must not change** or previews
diverge). Oases are hand-placed (`ChunkGen.HAND_PLACED_OASES`, mirrored
from the manager); water towers are seeded/hand-placed outside the load
radius. Per-region FastNoiseLite instances are lazily cached on `ChunkGen`
keyed by `region_id × world_seed`.

**Bespoke overrides** resolve through an optional `ChunkRegistry`
(`res://chunks/registry.tres`, auto-loaded if present):

- **scene** (tier 1): a hand-authored `.tscn` fully replaces the procedural
  chunk. Edges are re-locked to the noise field on save
  (`ChunkGen.lock_chunk_edges`) so it stays seamless.
- **overlay** (tier 2): procedural mesh kept; `ChunkOverlay` lists procedural
  prop indices to `remove` and extra `ChunkObject`s to `add`.

The **chunk_editor** plugin (`addons/chunk_editor/`, enabled in
project.godot) adds a "Chunks" dock. It previews a chunk under the open
scene's root, lets you sculpt/add/delete, and on Save delegates to
`ChunkAuthoring` (`chunk_authoring.gd`) to edge-lock, pack/duplicate, write
`chunks/scenes|overlays/`, and merge the registry entry. The dock's
`noise_seed` syncs into `Regions.set_world_seed` before each load/save so
the preview reflects the actual region(s) at that chunk; per-region noise
params (frequency / octaves / lacunarity / height_scale) live in
`Regions.gd` and are no longer dock-tweakable.

---

## Replication summary

| Node                        | Authority                  | Replicated state |
|-----------------------------|----------------------------|------------------|
| `Ship`                      | Helmsman (or host)         | `virtual_yaw`, `current_speed`, `world_offset`, `engine_order` (SceneReplicationConfig in ship.tscn) |
| `Ship/SteamPlant`           | Host                       | pressure/heat/coal/water/load — delta-throttled `_receive_state` RPC (not a synchronizer) |
| `Ship.system_integrity`     | Host                       | per-system `_apply_damage`/`_apply_repair` RPCs (sender id ∈ {0,1}) |
| `Ship.money` / `Ship.cargo` | Host                       | `_set_money`/`_set_cargo` RPCs (sender id ∈ {0,1}) |
| `DeckGun`                   | Host                       | `traverse_yaw`, `elevate_pitch`, `ammo` (synchronizer); inputs RPC'd in |
| `AIShip` (bandit)           | Host                       | `world_offset`, `virtual_yaw`, `current_speed`, `state`, `hit_count` (synchronizer) |
| `Cannonball`                | n/a — deterministic        | spawn params only; host-only hit detection, despawn RPC'd |
| `PlayerContainer/<peer_id>` | The peer themselves        | position/rotation (synchronizer in player.tscn); `carried_item_type` via RPC |
| Interactables, gangway      | Host                       | side-effects RPC'd from `interact()` / reparent RPCs |
| `chunk_manager.gd`          | All peers (same noise seed)| — |
| `DayNightCycle` / `WeatherSystem` | All peers (deterministic from shared epoch+seed) | — (epoch+seed sent once via `notify_world_clock`) |
| Crew survival               | Player's own authority      | needs sim local; `is_dead` via `set_survival_dead`/`revive_survival` RPCs (permissive sender, co-op) |

Roles are tracked on the `NetworkManager` autoload (`current_helmsman`,
`current_gunner`) and broadcast via `notify_helmsman_changed` /
`notify_gunner_changed`. On disconnect the host releases any role the peer
held and frees their player node (checks both PlayerContainer and WorldMap).

---

## Debug / god mode

A host-only testing toggle, off by default. Press **F1** to open the
`DebugPanel` overlay (`scripts/debug_panel.gd`, code-built, parented to
`UILayer` in `main.gd`). The master button flips `GameState.debug_mode`;
`NetworkManager.set_debug_mode` → `notify_debug_mode` RPC broadcasts the flag
to every peer so consumers stay in sync. Clients see the panel hidden — only
the host can toggle the flag.

While debug is on:

- **No drain / no death** — `player_controller._tick_survival` pins
  hunger/thirst/energy to 100 and broadcasts a revive if already dead.
- **Infinite fuel** — `steam_plant._physics_process` re-clamps coal & water
  to max each tick (pressure still rises through the normal sim).
- **Speed × / Jump ×** — `GameState.debug_speed_mult` / `debug_jump_mult`
  multiply `MOVEMENT_SPEED` and `JUMP_VELOCITY`. A cheap substitute for
  free-fly (see ROADMAP Future).
- **No-clip** — toggles the player's `collision_mask` to 0 and rewires
  vertical input (jump = up, brake = down, no gravity) so the body flies
  through the ship/terrain/walls. Saved mask is restored on toggle-off.
- **Force daylight / Force storm** — `GameState.debug_force_daylight` /
  `debug_force_storm` (NAN = no override). `day_night_cycle._process` snaps
  `_time_of_day` so the requested daylight cascades through the lighting
  pipeline; `weather_system._process` overrides `_intensity` and parks the
  fog volume on the ship.

Panel buttons (host-only, route through existing host-authoritative paths):

- **Refill cargo + money** — `ship.receive_money` + `add_cargo` per good.
- **Repair all systems** — `ship.repair_system(k, 1.0)` for every key.
- **Refuel boiler now** — `SteamPlant.add_coal` / `add_water` to capacity.
- **Spawn bandit** — `bandit_director.debug_spawn_one()` (bypasses
  `spawn_enabled` / chance / timer; ignores the one-at-a-time guard so the
  director's natural loop can resume cleanly).
- **Kill all bandits** — destroys every `Bandit_*` under WorldMap.
- **Teleport →** — dropdown of curated `HAND_PLACED_OASES` offsets;
  `ship.debug_set_offset.rpc(world_offset)` lands on every peer regardless
  of who currently holds ship authority.

Toggle is `debug_toggle` (F1) in the input map. Free-fly camera remains a
Future item — speed × + jump × + no-clip cover most testing needs.

---

## Balance pass (world scale + wear curve + drain rates)

The first balance pass calibrated the loop against time-between-POIs and
the in-game day length (2400 s = 40 min real). See `Regions.WORLD_HALF_EXTENT`
(now 8000 m → 16 km × 16 km world), `POIRegistry.SETTLEMENTS` (curated
triangle), and the wear / drain tunings in `ship_controller`,
`steam_plant`, and `player_controller`.

**POI triangle.** At half-ahead (engine order 2, 6 m/s):
- Tin Lantern (caravan, SW) ↔ Rust Pump (mining, SE) = **5400 m ≈ 15 min**
  — the short leg. Mining/caravan trade pair, quick profitable loop.
- Either ↔ Dust Anvil (mining, N) = **~14400 m ≈ 40 min ≈ 1 in-game day**
  — both medium / long legs are symmetric.
- Salt Thread (caravan) sits off-triangle to the west at (−6000, 3000) —
  convenient from Dust Anvil (~7 km), an extended haul from the south.

**Expected single-leg costs (on-ship, half-ahead, normal daylight):**
- Short leg (15 min): hunger −33, thirst −50, no meaningful wear.
- Long leg (40 min): hunger −88, thirst −more-than-half (force a refill or
  consume rations en route), minor wear (a handful of HUD points on
  whichever system you stressed).
- Anything at Flank: wear spirals fast — Flank is the redline, not the
  cruise setting.

**Survival drains.** Old defaults (0.45 hunger/s, 0.65 thirst/s) emptied
the bars in ~2 min — fine for snap tests, terrible for 15-min legs. New
defaults (`hunger_drain = 0.037`, `thirst_drain = 0.020`, energy similar)
calibrate against the short-leg target. The heat / storm / exposed
multipliers and the region thirst modifier all still apply on top.

---

## Lobby flow

1. App opens on `main.tscn` → `Lobby` visible, `HUD` hidden.
2. Host enters name + port → `NetworkManager.host_game()` → server starts,
   host (peer 1) spawns on the deck.
3. Client enters name + IP + port → `join_game()` → on
   `connected_to_server`, client RPCs `register_player(name)` to host. Host
   stores them, rebroadcasts the roster + role state, and spawns their
   player node on every peer.
4. UI swaps to HUD on `server_started` / `connection_succeeded`.
5. Peer disconnect: host removes them, frees their node on all peers,
   releases helm/gun if held.

---

## Input map

| Action          | Key / Button |
|-----------------|--------------|
| `move_forward`  | W            |
| `move_back`     | S            |
| `move_left`     | A            |
| `move_right`    | D            |
| `jump`          | Space        |
| `brake`         | B            |
| `interact`      | E            |
| `fire`          | Left Mouse   |
| `debug_toggle`  | F1 — host-only god-mode overlay (see Debug / god mode) |

Context-sensitive remapping (additions for T2.3):

- **At the telescope**: mouse motion = continuous fine aim, A/D/W/S
  held = continuous sweep, Left-click spots, E leaves the scope.
- **At the chart table**: opens the chart overlay locally — no extra key
  bindings, the overlay handles its own input. Esc closes the chart and
  re-captures the mouse cleanly (the close handler consumes the event so
  the global debug Esc-release doesn't refire afterward).

Context-sensitive remapping (player_controller):

- **On foot**: WASD walks (camera-relative), Space jumps, E interacts.
- **At the helm**: W/S step the engine telegraph (Full Astern −2 … Stop 0 …
  Slow Ahead +1 … Half Ahead +2 … Full Ahead +3 … **Flank** +4), A/D steer,
  B brakes, E releases. Speeds are the same as before (1.0 / 0.75 / 0.5 /
  0.25 fractions of `max_forward_speed`); only the **Flank** label is new
  and the wear curve makes it punishing — see "Machine wear" in the
  Combat & damage section.
- **At the gun**: A/D traverse one step, W/S elevate one step (tap-tap, no
  auto-repeat), Left-click fires (server reload/ammo-gated), E leaves the
  gun. Mouse-look is frozen; the active camera is the gun's barrel camera.

---

## Success criteria (test these)

1. Two Godot instances on localhost — one hosts (`127.0.0.1:7777`), other joins.
2. Both see the ship and both player capsules in distinct colours.
3. Host takes the helm, W rings up Slow Ahead — ship drifts forward on both screens.
4. Other player walks the deck — both screens see them move.
5. Stoker picks up coal, feeds the firebox (E) — boiler coal rises on the HUD.
6. Pressure rises with the fire; above ~20% working pressure the ship accelerates.
7. Drive to a water tower, stop, press E inside it — water bar refills.
8. Run pressure or water to 0 — ship coasts to a stop.
9. Gangway: stop the ship, E to disembark (player stays in dunes as ship
   sails on), E again near the spot to climb back aboard.
10. Sail to a `mining` oasis, open the market, buy spice; carry crates to the
    cargo hold deposit; sail to a `caravan` oasis and sell at a profit.
11. While moving, a bandit eventually spawns behind, paces a side, and fires.
12. Gunner loads a clip from the magazine, mans the gun, lands hits — bandit
    integrity drops; enough hits destroy it (despawns on every peer).
13. Take hull damage, then repair via a workshop kit — the worst system heals.
14. Closing the client cleanly removes that player (and releases their roles)
    on the host, and vice-versa.
15. No errors in the Godot output panel on launch.
16. Sun rises, arcs, and sets; turning the ship sweeps the sun across the sky
    in lock-step with the dunes (it works as a compass). HUD heading line
    shows the sky phase.
17. Both peers see the same time of day and the same sky (deterministic from
    the shared epoch), including a client that joins mid-session.
18. A sandstorm rolls in: ochre haze + volumetric body + deck grit. It stays
    fixed in the dunes — sail out one side and back in. HUD shows `SANDSTORM`.
19. Storm raises bandit spawn rate; in a heavy whiteout the bandit holds fire.
    At night the Pole Star marks world-North as a bearing reference.
20. Climbing a dune visibly bleeds speed (and rolls back if under-powered);
    descending speeds up past the order. The hull bobs/settles over crests,
    squats under power, dives under braking, and can't turn tightly at speed
    or pivot from a standstill. Behaviour matches on both peers.
21. No bandits spawn (parked). Coal bunker / repair store deplete and must be
    batch-loaded from cargo; water tank feeds the boiler from cargo water.
22. Buy a repair kit, carry it to the boiler/bridge/wheels RepairPoint, E
    repairs that system; machine wear slowly degrades systems under use.
23. Hunger/thirst/energy drain (faster in sun/storm/off-ship); eating a
    carried ration / drinking water (E, no target) restores them; running a
    need to 0 downs the player; a market trade revives the crew; all dead →
    back to lobby with a message.

---

## Extending the project — checklist

**New interactable**

- Inherit `scripts/interactable.gd` (`Interactable`); root is an `Area3D` on
  collision layer 2 (the interact ray's mask).
- Gate `interact(peer_id)` with `if not multiplayer.is_server(): return`;
  broadcast side-effects via `@rpc("authority", "call_local", "reliable")`.
- Override `get_prompt(player)` for context-sensitive text. Set a default
  `prompt_text` in `_ready()`.
- For a *carry source*, mirror `coal_bunker.gd`: check
  `player.can_carry_item()` then `player.rpc("set_carried_item", "<id>")`.
  Add a visual factory + match arm in
  `player_controller._refresh_carried_visual` for new item ids.
- For a *local UI* interactable (like the market), join a group, detect it in
  `player_controller._poll_interact`, and open the UI directly (don't route
  through the host) — let the UI RPC its own requests.

**New replicated ship state**

- Add the property to `ship_controller.gd`.
- If it's a smooth float/vector: add a
  `properties/N/path = NodePath(".:my_prop")` block to the
  `SceneReplicationConfig` in `ship.tscn`.
- If it's discrete/dict state: follow the `system_integrity`/`money` pattern
  — host-only mutator → sender-validated (`id ∈ {0,1}`) `call_local` RPC →
  emit a `*_changed` signal the HUD binds to.

**New ship system for the damage model**

- Add a key to `ship_controller.system_integrity`. If it's an **internal**
  system (behind the hull), add a centroid lookup in
  `_get_system_positions()` (+ a `_SYSTEM_POSITION_FALLBACKS` entry) so the
  penetration cone can target it. If it's **external** (like `mobility`),
  do *not* add it there — it should only take direct hits.
- Map struck collider names to it in `_part_to_primary_system` and
  `cannonball._classify_part_by_name`.
- Add it to the HUD readout in `hud._refresh_damage_label`.

**New terrain feature / prop**

- Add construction to `ChunkGen` (a factory in `spawn_placeholder_object`
  and/or a record in `build_object_records`). **Keep RNG draw order stable**
  — runtime and editor preview must agree.
- Seed any randomness from `hash(key)` so a chunk always rebuilds identically.
- For hand-authored placement, use the chunk_editor dock (overlay or full
  scene) rather than special-casing the manager.

**New tradeable good**

- Add an entry to `Goods.ALL` (with `carry_id` + colour) and a price row in
  `Goods.PRICES` for every oasis type. The trade panel, crate visuals, and
  cargo helpers pick it up automatically; add the key to
  `ship_controller.cargo` so it can be stowed/sold.

**Day/night or weather changes**

- Keep the system deterministic from `GameState.world_time()` +
  `weather_seed`. Never add per-frame replication — if a value must be
  shared, send it once like `notify_world_clock`. Anything random must seed
  from `weather_seed` so all peers agree.
- Anything that should act as a navigation reference must be computed in the
  fixed world frame and rotated by `Basis(UP, -ship.virtual_yaw)` (mirror
  ChunkManager) and pinned to the ship (not parented into WorldMap's scroll)
  so it doesn't parallax.
- A storm element that should stay put in the dunes goes under WorldMap with
  its local position set to world coordinates (chunk-body convention).
- `WeatherSystem` must process *after* `DayNightCycle` (it composes onto the
  env fog colour) — preserve the `world_map.tscn` child order.
- New systems that react to weather/time should group-lookup `"day_night"` /
  `"weather"` and call the public API, not reach into internals.
