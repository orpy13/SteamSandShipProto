# Steam Sand Ship — Co-op Prototype

A 3D co-op multiplayer game in Godot 4 (GDScript, ENet, no third-party addons).
2–4 players crew a steam-powered **sand ship** that crosses a procedurally
generated desert. One player is host (also plays); others join as clients. The
ship is authoritative on whichever peer currently holds the helm.

> This document is the up-to-date spec. The original prototype was a generic
> wheeled vehicle; the project has since grown into a crewed steam ship that
> sails over dunes. Code is the source of truth — this file mirrors it.

---

## The fiction

The ship has a coal-fired boiler. Steam pressure drives the wheels. Without
fuel and water it coasts to a stop. The crew shares responsibilities:

| Role           | What they do                                                          |
|----------------|-----------------------------------------------------------------------|
| **Helmsman**   | Stands at the helm, sets engine order (Stop → Full Ahead) and steers. |
| **Stoker**     | Carries coal from the bunker and feeds the boiler firebox.            |
| **Water hand** | When parked at a desert water tower, refills the boiler reservoir.    |

Any player can swap between roles freely — the helm releases as soon as you
step off it, and the carry-coal state is per-player.

---

## Multiplayer model

- **Host / server**: peer ID 1, runs the world, spawns players, validates interactions.
- **Clients**: connect via IP, simulate their own player body locally, replicate position via `MultiplayerSynchronizer`.
- **Ship authority**: starts on the host. Taking the helm transfers multiplayer authority for the `Ship` node (and its `MultiplayerSynchronizer`) to the helmsman so their inputs drive the ship for everyone.
- **Interact validation**: every interactable's `interact()` method is server-only (`multiplayer.is_server()` gate). Clients send `_request_interact.rpc_id(1, target_path)`.
- **Steam plant**: simulated server-side, broadcast to clients via `_receive_state` RPC throttled by a delta threshold.

---

## Project layout

```
res://
├── main.tscn                                  # Entry scene
├── project.godot
├── instructions.md                            # This file
├── scenes/
│   ├── world/world_map.tscn                   # Holds the ChunkManager
│   ├── ship/ship.tscn                         # Sand ship (hull, deck, rails, wheels, helm, boiler, …)
│   ├── player/player.tscn                     # CharacterBody3D + camera + interact ray
│   ├── interactables/
│   │   ├── helm.tscn                          # Take/release ship authority
│   │   ├── coal_bunker.tscn                   # Pick up coal
│   │   ├── boiler_firebox.tscn                # Drop coal in → boiler heat
│   │   └── water_tower.tscn                   # World-placed oasis, refills water
│   └── ui/
│       ├── hud.tscn                           # Speed, pressure, helm, prompts
│       ├── lobby.tscn                         # Name / IP / port + Host/Join
│       └── name_tag.tscn                      # Floating Label3D over remote players
└── scripts/
    ├── main.gd                                # Wires lobby/HUD to NetworkManager
    ├── network_manager.gd                     # Autoload — ENet, peer tracking, spawning
    ├── ship_controller.gd                     # Virtual-yaw / world-offset locomotion
    ├── steam_plant.gd                         # Coal → heat → pressure → power
    ├── player_controller.gd                   # Movement, mouse-look, interact ray
    ├── player_nametag.gd                      # Hide on local; show name on remote
    ├── chunk_manager.gd                       # Procedural desert chunks under the ship
    ├── interactable.gd                        # Base Area3D class
    ├── interactables/
    │   ├── helm.gd
    │   ├── coal_bunker.gd
    │   ├── boiler_firebox.gd
    │   └── water_tower.gd
    └── autoloads/
        ├── game_state.gd                      # Game phase
        └── audio_manager.gd                   # play_sfx helper
```

---

## The world-scroll trick (important!)

The ship never moves in world space. Its `position.x` and `position.z` stay
at 0; only `position.y` lerps to follow terrain height. Two pieces of state
on `ship_controller.gd` are authoritative:

- `virtual_yaw` — the heading the ship is "really" facing.
- `world_offset` — the position the ship is "really" at in the dunes.

The `chunk_manager.gd` reads both each physics frame and applies the inverse
to the `WorldMap` node: it rotates the world by `-virtual_yaw` and translates
it by `-world_offset`. From the player's perspective the ship is sailing
through the desert; mechanically, the desert is sliding underneath a
stationary ship.

**Why this matters:** players walking on the deck never need vehicle-velocity
compensation. The ship's local space is also world space for them.
`move_and_slide()` Just Works.

This is the single most important thing to understand before extending the
project. If you add anything that needs world-space position (e.g. a minimap,
or a fixed waypoint), use `ship.world_offset` — **not** `ship.global_position`.

---

## Replication summary

| Node                        | Authority             | Replicated state |
|-----------------------------|-----------------------|------------------|
| `Ship`                      | Helmsman (or host)    | `virtual_yaw`, `current_speed`, `world_offset`, `engine_order` |
| `Ship/SteamPlant`           | Host                  | Pressure/heat/coal/water (delta-throttled RPC, not synchronizer) |
| `PlayerContainer/<peer_id>` | The peer themselves   | Position/rotation (synchronizer in player.tscn) |
| `Helm`, other interactables | Host                  | Side effects RPC'd from `interact()` |
| `chunk_manager.gd`          | All peers (each computes the same noise seed locally) | — |

---

## Lobby flow

1. App opens on `main.tscn` → `Lobby` UI visible, `HUD` hidden.
2. Host enters name + port → `NetworkManager.host_game()` → server starts, host spawns on the deck.
3. Client enters name + IP + port → `NetworkManager.join_game()` → on
   `connected_to_server`, client RPCs `register_player(name)` to host. Host
   stores them in `players`, broadcasts the new list, and spawns their player
   node on every peer.
4. UI swaps to HUD on `server_started` / `connection_succeeded`.
5. Peer disconnect: host removes them from the dict, frees their node on all
   peers, and (if they held the helm) releases authority back to itself.

---

## Input map

| Action          | Key   |
|-----------------|-------|
| `move_forward`  | W     |
| `move_back`     | S     |
| `move_left`     | A     |
| `move_right`    | D     |
| `jump`          | Space |
| `brake`         | B     |
| `interact`      | E     |

At the helm, `W`/`S` step the engine telegraph up/down (Stop / Slow / Half /
Three Quarter / Full Ahead, plus Half / Full Astern). `A`/`D` steer. `B`
brakes. `E` releases the helm.

---

## Success criteria (test these)

1. Two Godot instances on localhost — one hosts (`127.0.0.1:7777`), the other joins.
2. Both see the ship and both player capsules in distinct colours.
3. Host steps onto the helm, hits W to ring up Slow Ahead — ship drifts forward on both screens.
4. The other player walks across the deck — both screens see them move.
5. Stoker picks up coal from the bunker, walks to the firebox, presses E — boiler coal increases on the HUD.
6. Pressure rises as the firebox burns; once it climbs above ~20% of working pressure, the ship actually accelerates.
7. Drive to a water tower out in the desert, stop the ship, press E inside it — water bar refills.
8. Run pressure to 0 or water to 0 — ship coasts to a stop.
9. Closing the client cleanly removes that player from the host's screen, and vice-versa.
10. No errors in the Godot output panel on launch.

---

## Extending the project — checklist

When adding a new interactable:

- Inherit from `scripts/interactable.gd` (the `Interactable` class).
- Root must be an `Area3D` on collision layer 2 (the interact ray's mask).
- Gate `interact()` with `if not multiplayer.is_server(): return` and broadcast side-effects via `@rpc("authority", "call_local", "reliable")`.
- Set `prompt_text` in `_ready()` or in the editor.

When adding new ship state that needs to replicate:

- Add the property to `ship_controller.gd`.
- Add a `properties/N/path = NodePath(".:my_property")` block to the `SceneReplicationConfig` inside `ship.tscn`.

When adding terrain features:

- Hook into `chunk_manager._ensure_chunk_data()` (extend the `objects` array).
- Add a corresponding case in `_spawn_placeholder_object()` or instance a scene like the water tower does.
- Seed the RNG from `hash(key)` so the same chunk always produces the same layout.
