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
# Border biomes (Tier 2, T2.1) — push in from the world edges. Each one
# uses height_scale + height_offset to enforce a diegetic wall: coast dips
# below sea level, mountains rear up past the climbable grade, jungle is
# heavy props and rolling resistance you can push through at a cost.
const ID_COAST := "coast"
const ID_MOUNTAINS := "mountains"
const ID_JUNGLE := "jungle"

# Finite world bounds (Tier 2, T2.1). The interior is the rectangle
# [-WORLD_HALF_EXTENT, +WORLD_HALF_EXTENT] in both axes; the BORDER_BAND-wide
# ring around the inside edge is the soft transition into border biomes.
const WORLD_HALF_EXTENT := 2000.0   # ~50 chunks each way at chunk_size=80
const BORDER_BAND := 240.0          # transition width (3 chunks-ish)
## Water plane Y. Sits below the lowest interior dune trough (dunes ±3.5,
## badlands ±6.5 with no offset) so the sea is only ever visible inside the
## coast border, where height_offset drops terrain past this Y. Bumping this
## up would let the sea bleed into salt flats / dunes — don't.
const SEA_LEVEL := -8.0

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
	## Additive Y bias applied AFTER noise×scale. Lets borders sit well above
	## (mountains) or below (coast) sea level without changing the wave shape.
	var height_offset: float
	var hazard_modifiers: Dictionary  # String → float

	func _init(p_id: String, p_display: String, p_tint: Color,
			p_freq: float, p_oct: int, p_lac: float, p_height: float,
			p_offset: float, p_haz: Dictionary) -> void:
		id = p_id
		display_name = p_display
		tint = p_tint
		noise_frequency = p_freq
		noise_octaves = p_oct
		noise_lacunarity = p_lac
		height_scale = p_height
		height_offset = p_offset
		hazard_modifiers = p_haz


# Hazard modifier keys (public; read with Regions.get_modifier_at(...)).
# Default value if the region doesn't override is 1.0 (= no change).
const HAZ_THIRST_MULT := "thirst_mult"           # multiplies player thirst drain
const HAZ_ROLLING_MULT := "rolling_resistance_mult"  # multiplies ship grade rolling resistance

# Built-in region table. Tuned conservatively so v1 reads as "regions exist
# and feel different" without nuking the baseline dunes feel. `offset` is the
# additive Y bias for borders (mountains rear up; coast dips below sea level).
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
		"offset": 0.0,
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
		"offset": 0.0,
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
		"offset": 0.0,
		"haz": { HAZ_ROLLING_MULT: 1.8 },
	},
	# Coast — terrain dips well below SEA_LEVEL (−8) so a water plane reads
	# as ocean. Offset is biased so the deepest trough is ~7 m under water
	# and the shallowest crest still sits ~2 m below — no spurious sand
	# pokes through unless the user widens BORDER_BAND. No hazards (the
	# water itself is the wall).
	{
		"id": ID_COAST,
		"display": "Coast",
		"tint": Color(0.78, 0.70, 0.52, 1.0),       # damp sand
		"freq": 0.005,
		"oct": 1,
		"lac": 2.0,
		"height": 2.5,
		"offset": -13.0,
		"haz": {},
	},
	# Mountains — height_scale + a big positive offset push terrain past the
	# climbable grade (ship_controller.grade_speed_sensitivity defaults to 6;
	# with 25m + ~10m of noise the slopes are unclimbable except at the
	# fringes — a diegetic soft wall).
	{
		"id": ID_MOUNTAINS,
		"display": "Mountains",
		"tint": Color(0.34, 0.32, 0.30, 1.0),
		"freq": 0.014,
		"oct": 3,
		"lac": 2.4,
		"height": 10.0,
		"offset": 25.0,
		"haz": { HAZ_ROLLING_MULT: 2.4 },
	},
	# Jungle — passable but punishing: heavy rolling resistance, slower thirst
	# recovery (humidity doesn't help dehydration in this fiction). Visual is
	# a deep green-brown tint; prop density goes here in a follow-up.
	{
		"id": ID_JUNGLE,
		"display": "Jungle",
		"tint": Color(0.22, 0.32, 0.18, 1.0),
		"freq": 0.010,
		"oct": 2,
		"lac": 2.0,
		"height": 4.0,
		"offset": 1.5,
		"haz": { HAZ_ROLLING_MULT: 2.0 },
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


# Finite-world border ring (Tier 2, T2.1). Wraps an inner sampler and replaces
# its output with a border-biome blend inside `border_band` metres of the
# world edge. Which border depends on which axis is closest to the edge:
#   +x → coast, −x → mountains, +z → mountains, −z → jungle.
# Beyond the world extent, full border weight (interior contribution → 0).
class BoundedRegionSampler extends RegionSampler:
	var _inner: RegionSampler
	var _half: float
	var _band: float

	func _init(inner: RegionSampler, half_extent: float, band: float) -> void:
		_inner = inner
		_half = maxf(half_extent, band + 1.0)
		_band = maxf(band, 1.0)

	## How much "border" weight applies at (x, z). 0 inside, 1 at/past the edge,
	## linear in between across `band`. Uses the bigger overrun of x vs z.
	func _border_weight(x: float, z: float) -> float:
		var dx := (absf(x) - (_half - _band)) / _band
		var dz := (absf(z) - (_half - _band)) / _band
		return clampf(maxf(dx, dz), 0.0, 1.0)

	## Pick the border id based on which edge dominates. Ties favour the X axis
	## (coast/mountains) so equator corners read as ocean/cliff, not jungle.
	func _border_id_for(x: float, z: float) -> String:
		var x_over := absf(x) - (_half - _band)
		var z_over := absf(z) - (_half - _band)
		if x_over >= z_over:
			return ID_COAST if x > 0.0 else ID_MOUNTAINS
		return ID_MOUNTAINS if z > 0.0 else ID_JUNGLE

	func sample(x: float, z: float) -> Dictionary:
		var inner_w := _inner.sample(x, z)
		var bw := _border_weight(x, z)
		if bw <= 0.0:
			return inner_w
		var bid := _border_id_for(x, z)
		# Scale interior contributions down; add the border weight on top.
		var out: Dictionary = {}
		var inv := 1.0 - bw
		for id in inner_w.keys():
			out[id] = float(inner_w[id]) * inv
		out[bid] = float(out.get(bid, 0.0)) + bw
		return out


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
			float(row["height"]), float(row["offset"]),
			(row["haz"] as Dictionary).duplicate())
		_regions[rd.id] = rd


## Build the default sampler stack: interior noise bands wrapped by a bounded
## border ring (Tier 2, T2.1). Swap the whole stack later via `set_sampler`.
func _default_sampler() -> RegionSampler:
	var interior := NoiseRegionSampler.new(world_seed, [
		{ "above": -0.25, "low": ID_BADLANDS,   "high": ID_DUNES },
		{ "above":  0.30, "low": ID_DUNES,      "high": ID_SALT_FLATS },
	])
	return BoundedRegionSampler.new(interior, WORLD_HALF_EXTENT, BORDER_BAND)


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
