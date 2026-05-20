extends Node
##
## POI REGISTRY — curated settlements + future minor POIs (Tier 2, T2.2).
##
## Replaces the ad-hoc `ChunkGen.HAND_PLACED_OASES` dict with a single source
## of truth that ChunkGen, the DebugPanel teleport, and the planned chart
## system (T2.3) all read from. Two tiers:
##
##   • Curated settlements — named, fixed `world_pos`, service flags. These
##     are the "places" on the map: where you trade, refuel, repair. v1 keeps
##     the four oases that already existed so balance / playtests don't move.
##   • Minor POIs (planned) — deterministic per-region (salvage / wrecks /
##     ruins) seeded from `Regions.world_seed`. Not built yet; the framework
##     leaves a `minor_pois_in_region` API stub.
##
## Lookup is by world position (an oasis can live at any (x, z), not on a
## chunk-grid corner) — `pois_in_chunk(key, chunk_size)` resolves which
## settlements fall inside a given chunk for the streamer.
##
## Determinism: the curated list is a const; minor POIs (future) will be a
## pure function of `Regions.world_seed`. No replication needed.
##

# Service flags. A settlement advertises what it offers — chart UI in T2.3
# will use these to draw icons; AI quest generation (Future) will route
# delivery jobs accordingly. Mining-vs-caravan oasis subtype still drives the
# market price table (see oasis.gd / Goods.PRICES).
const SVC_MARKET := "market"
const SVC_FUEL := "fuel"            # coal preferentially cheap
const SVC_WATER := "water"          # water tower nearby
const SVC_PROVISIONS := "provisions"
const SVC_REPAIR := "repair"
const SVC_CONTRACTS := "contracts"  # quest board — Future

# Settlement entry shape:
#   id           : stable short identifier (used by chart pins, save state).
#   display_name : human label for HUD / chart / debug teleport.
#   world_pos    : Vector3 in world_offset space (Y is informational; the
#                  oasis prop will be re-seated on the terrain at spawn).
#   oasis_subtype: "mining" or "caravan" — selects the market price column.
#   services     : Array[String] of SVC_* flags.
const SETTLEMENTS: Array = [
	{
		"id": "rust_pump",
		"display_name": "Rust Pump",
		"world_pos": Vector3(6 * 80.0 + 40.0, 0.0, 4 * 80.0 + 40.0),
		"oasis_subtype": "mining",
		"services": [SVC_MARKET, SVC_FUEL, SVC_REPAIR],
	},
	{
		"id": "tin_lantern",
		"display_name": "Tin Lantern",
		"world_pos": Vector3(-5 * 80.0 + 40.0, 0.0, -3 * 80.0 + 40.0),
		"oasis_subtype": "caravan",
		"services": [SVC_MARKET, SVC_PROVISIONS, SVC_WATER],
	},
	{
		"id": "dust_anvil",
		"display_name": "Dust Anvil",
		"world_pos": Vector3(9 * 80.0 + 40.0, 0.0, -7 * 80.0 + 40.0),
		"oasis_subtype": "mining",
		"services": [SVC_MARKET, SVC_FUEL],
	},
	{
		"id": "salt_thread",
		"display_name": "Salt Thread",
		"world_pos": Vector3(-10 * 80.0 + 40.0, 0.0, 8 * 80.0 + 40.0),
		"oasis_subtype": "caravan",
		"services": [SVC_MARKET, SVC_PROVISIONS, SVC_REPAIR],
	},
]


# ── Public API ───────────────────────────────────────────────────────────────

## All curated settlements (read-only — don't mutate the returned dicts).
func all_settlements() -> Array:
	return SETTLEMENTS


## Look up a settlement by its short id ("rust_pump" etc). Returns {} if
## unknown so callers can guard cleanly.
func get_settlement(id: String) -> Dictionary:
	for s in SETTLEMENTS:
		if String(s["id"]) == id:
			return s
	return {}


## Settlements whose world_pos falls inside the chunk at `key` (chunk grid).
## Used by ChunkGen.build_object_records to spawn the oasis prop.
func settlements_in_chunk(key: Vector2i, chunk_size: float) -> Array:
	var out: Array = []
	var min_x: float = key.x * chunk_size
	var max_x: float = min_x + chunk_size
	var min_z: float = key.y * chunk_size
	var max_z: float = min_z + chunk_size
	for s in SETTLEMENTS:
		var p: Vector3 = s["world_pos"]
		if p.x >= min_x and p.x < max_x and p.z >= min_z and p.z < max_z:
			out.append(s)
	return out


## Chart pin label list — id → display_name. Built once on demand; tiny array.
func display_label_map() -> Dictionary:
	var d: Dictionary = {}
	for s in SETTLEMENTS:
		d[String(s["id"])] = String(s["display_name"])
	return d
