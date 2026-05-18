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
│   │   ├── oasis_market.tscn  cargo_hold_deposit.tscn  gangway.tscn
│   └── ui/
│       ├── hud.tscn  lobby.tscn  name_tag.tscn
│       ├── gun_overlay.tscn                   # Crosshair / elevation / reload bar (gunner only)
│       └── trade_panel.tscn                   # Buy/sell modal at a market
└── scripts/
    ├── main.gd  network_manager.gd (autoload)  game_state.gd  audio_manager.gd
    ├── ship_controller.gd                     # Locomotion + damage model + economy state
    ├── steam_plant.gd                         # Coal → heat → pressure → power
    ├── player_controller.gd                   # Movement, look, interact, carry, helm/gun lock
    ├── player_nametag.gd  hud.gd  lobby.gd  gun_overlay.gd  trade_panel.gd
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
        ├── repair_point.gd  workshop.gd (kit repository)
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
at 0 → **dead**: the body freezes (`set_survival_dead` RPC broadcasts it).
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

**Machine wear (Tier 1, T1.3).** `_apply_machine_wear` runs **server-side**
(ahead of the authority gate, since the host owns the steam plant and the
`_apply_damage` RPC only accepts sender 0/1). `mobility` wears with distance
× terrain roughness, `power` with engine order, `control` with hard yaw at
speed. Wear accumulates and flushes through `_apply_damage` in discrete
`wear_apply_step` chunks (low RPC cadence). The existing performance
penalties give it immediate teeth; tuning lives in the `*_wear_*` exports.

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

---

## Day/night & weather

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

## Chunk system & bespoke editor

`chunk_manager.gd` streams `chunk_size` tiles within `load_radius`. All
mesh/prop construction is **node-free static code in `ChunkGen`**
(`chunk_gen.gd`) so the in-editor preview is bit-identical to the streamed
runtime. Heights are sampled at world-grid positions (seamless borders);
prop layout is deterministic (`rng.seed = hash(key)` — **draw order must not
change** or previews diverge). Oases are hand-placed
(`ChunkGen.HAND_PLACED_OASES`, mirrored from the manager); water towers are
seeded/hand-placed outside the load radius.

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
`chunks/scenes|overlays/`, and merge the registry entry. The dock params
must match `ChunkManager`'s exports or previews diverge.

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

Context-sensitive remapping (player_controller):

- **On foot**: WASD walks (camera-relative), Space jumps, E interacts.
- **At the helm**: W/S step the engine telegraph (Full Astern −2 … Stop 0 …
  Full Ahead +4), A/D steer, B brakes, E releases. Stepping off the trigger
  auto-releases.
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
