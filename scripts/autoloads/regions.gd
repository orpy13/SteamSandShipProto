extends Node
##
## REGIONS — biome / sub-region field for the desert world (Tier 2, T2.0).
##
## A single queryable layer that ChunkGen, the hazard hookups, the chart system
## (T2.3, planned) and the bespoke-chunk editor all read from. Two-tier API:
##
##   region_at(x, z)        → dominant region id (for chart pins, prop tables,
##                            point-hazard reads on the ship).
##   region_weights(x, z)   → Dictionary[id: float], sums ~1.0 — used by
##                            ChunkGen to blend heights and tints smoothly
##                            across borders (no chunk-aligned seams).
##
## The actual (x, z) → weight mapping lives behind a `RegionSampler` strategy.
## v1 ships `NoiseRegionSampler` (low-frequency simplex banded by thresholds,
## linear blend in a halfwidth around each threshold). The "Future" hand-drawn
## **region map** (T2.1) just needs a new `TextureRegionSampler` and
## `set_sampler(...)` — every consumer (chunks, hazards, chart) keeps working
## unchanged. The chart's "where am I?" query in T2.3 is `region_at()`; planned
## settlement / POI placement in T2.2 will also hang off this same field.
##
## Determinism: the sampler seeds from `world_seed` (set once by ChunkManager
## from its `noise_seed` export) so every peer sees the same regions.
##

# Region IDs are short snake-case strings — readable in saved scenes / logs
# and trivially serialisable. Keep them stable; consumers compare by string.
const ID_DUNES := "dunes"
const ID_SALT_FLATS := "salt_flats"
const ID_BADLANDS := "badlands"

# Per-region tuning. height_scale / noise_frequency / noise_octaves drive the
# chunk heightfield; tint colours the terrain mesh via vertex colours; the
# hazard_modifiers Dictionary is read by ship_controller, player_controller,
# etc. — keys here are public contracts (see "Hazard modifier keys" below).
class RegionData extends RefCounted:
	var id: String
	var display_name: String
	var tint: Color
	var noise_frequency: float
	var noise_octaves: int
	var noise_lacunarity: float
	var height_scale: float
	var hazard_modifiers: Dictionary  # String → float

	func _init(p_id: String, p_display: String, p_tint: Color,
			p_freq: float, p_oct: int, p_lac: float, p_height: float,
			p_haz: Dictionary) -> void:
		id = p_id
		display_name = p_display
		tint = p_tint
		noise_frequency = p_freq
		noise_octaves = p_oct
		noise_lacunarity = p_lac
		height_scale = p_height
		hazard_modifiers = p_haz


# Hazard modifier keys (public; read with Regions.get_modifier_at(...)).
# Default value if the region doesn't override is 1.0 (= no change).
const HAZ_THIRST_MULT := "thirst_mult"           # multiplies player thirst drain
const HAZ_ROLLING_MULT := "rolling_resistance_mult"  # multiplies ship grade rolling resistance

# Built-in region table. Tuned conservatively so v1 reads as "regions exist
# and feel different" without nuking the baseline dunes feel.
const _REGION_DATA: Array = [
	# Baseline dunes — matches the old single-noise look so most of the map
	# stays visually familiar.
	{
		"id": ID_DUNES,
		"display": "Dunes",
		"tint": Color(0.551, 0.488, 0.333, 1.0),    # current TERRAIN_ALBEDO
		"freq": 0.006,
		"oct": 2,
		"lac": 2.0,
		"height": 3.5,
		"haz": {},
	},
	# Salt flats — flatter, paler, hotter on thirst.
	{
		"id": ID_SALT_FLATS,
		"display": "Salt Flats",
		"tint": Color(0.86, 0.83, 0.74, 1.0),
		"freq": 0.004,
		"oct": 1,
		"lac": 2.0,
		"height": 0.8,
		"haz": { HAZ_THIRST_MULT: 1.5 },
	},
	# Badlands — sharper, darker, rougher to roll across.
	{
		"id": ID_BADLANDS,
		"display": "Badlands",
		"tint": Color(0.32, 0.25, 0.20, 1.0),
		"freq": 0.012,
		"oct": 3,
		"lac": 2.2,
		"height": 6.5,
		"haz": { HAZ_ROLLING_MULT: 1.8 },
	},
]


# ── Sampler abstraction ──────────────────────────────────────────────────────
# Strategy that maps (world_x, world_z) → weight dictionary. v1 noise-based;
# T2.1 plans a TextureRegionSampler that reads a hand-drawn region map.
class RegionSampler extends RefCounted:
	## Returns { region_id: weight }. Weights sum to ~1.0. May omit zero entries.
	func sample(_x: float, _z: float) -> Dictionary:
		return {ID_DUNES: 1.0}


# Low-frequency simplex noise banded by thresholds, with linear blending in a
# small halfwidth around each threshold so neighbours fade rather than snap.
class NoiseRegionSampler extends RegionSampler:
	# Each row = { "above": float, "low": String, "high": String } — when the
	# field value `r` is near `above`, blend from `low` (below) to `high`.
	var _bands: Array
	var _blend_halfwidth: float
	var _noise: FastNoiseLite
	var _default_id: String

	func _init(seed_value: int, bands: Array, blend_halfwidth: float = 0.05,
			default_id: String = ID_DUNES) -> void:
		_bands = bands
		_blend_halfwidth = maxf(blend_halfwidth, 0.0001)
		_default_id = default_id
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.seed = seed_value
		# Roughly one region cluster every ~600m at chunk_size=80. Tunable but
		# this gives 7-8 chunks of one region between borders — enough room
		# to read as a "place".
		_noise.frequency = 0.0018
		_noise.fractal_octaves = 1

	func sample(x: float, z: float) -> Dictionary:
		var r := _noise.get_noise_2d(x, z)   # [-1, 1]
		# Walk the (sorted-ascending) bands. r below the lowest threshold sits
		# fully in the first band's "low" region; above the highest, fully in
		# the last band's "high" region.
		for band in _bands:
			var t: float = band["above"]
			if r < t - _blend_halfwidth:
				return {String(band["low"]): 1.0}
			if r < t + _blend_halfwidth:
				# Linear lerp across the blend zone: at r==t, 50/50.
				var w := (r - (t - _blend_halfwidth)) / (2.0 * _blend_halfwidth)
				w = clampf(w, 0.0, 1.0)
				return {
					String(band["low"]): 1.0 - w,
					String(band["high"]): w,
				}
		# Above every band → final region.
		var last: Dictionary = _bands[_bands.size() - 1]
		return {String(last["high"]): 1.0}


# ── Autoload state ───────────────────────────────────────────────────────────
var world_seed: int = 1337
var sampler: RegionSampler
# id → RegionData. Built once from _REGION_DATA.
var _regions: Dictionary = {}


func _ready() -> void:
	_build_region_table()
	sampler = _default_sampler()


func _build_region_table() -> void:
	_regions.clear()
	for row in _REGION_DATA:
		var rd := RegionData.new(
			String(row["id"]), String(row["display"]),
			row["tint"] as Color,
			float(row["freq"]), int(row["oct"]), float(row["lac"]),
			float(row["height"]),
			(row["haz"] as Dictionary).duplicate())
		_regions[rd.id] = rd


## Build the default 3-region noise sampler from the current `world_seed`.
func _default_sampler() -> RegionSampler:
	return NoiseRegionSampler.new(world_seed, [
		{ "above": -0.25, "low": ID_BADLANDS,   "high": ID_DUNES },
		{ "above":  0.30, "low": ID_DUNES,      "high": ID_SALT_FLATS },
	])


# ── Public API ───────────────────────────────────────────────────────────────

## Re-seed the active sampler. ChunkManager calls this in _ready from its
## `noise_seed` export so every peer's region field agrees.
func set_world_seed(seed_value: int) -> void:
	if seed_value == world_seed and sampler != null:
		return
	world_seed = seed_value
	sampler = _default_sampler()


## Swap the strategy. Future T2.1 work hands in a TextureRegionSampler.
func set_sampler(s: RegionSampler) -> void:
	if s != null:
		sampler = s


## Weight dictionary at a world point. Sums to ~1.0; zero-weight regions may
## be omitted. Consumers should iterate the keys returned.
func region_weights(x: float, z: float) -> Dictionary:
	if sampler == null:
		return {ID_DUNES: 1.0}
	return sampler.sample(x, z)


## Dominant region id — the entry with the highest weight in `region_weights`.
## Used by point queries (props, hazards at the ship, chart pins).
func region_at(x: float, z: float) -> String:
	var w := region_weights(x, z)
	var best_id := ID_DUNES
	var best_w := -1.0
	for id in w.keys():
		var v: float = float(w[id])
		if v > best_w:
			best_w = v
			best_id = String(id)
	return best_id


## Region row by id (or the dunes baseline if unknown — safer than null).
func get_data(id: String) -> RegionData:
	if _regions.has(id):
		return _regions[id]
	return _regions[ID_DUNES]


## Read a single hazard modifier for a region (default returned if unset).
func get_modifier(id: String, key: String, default: float = 1.0) -> float:
	var rd := get_data(id)
	return float(rd.hazard_modifiers.get(key, default))


## Convenience point query: dominant region's modifier at (x, z).
func get_modifier_at(x: float, z: float, key: String, default: float = 1.0) -> float:
	return get_modifier(region_at(x, z), key, default)
