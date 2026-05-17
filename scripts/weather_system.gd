extends Node3D
##
## WEATHER SYSTEM — deterministic, localized sandstorms.
##
## Lives as a child of WorldMap and MUST process AFTER DayNightCycle (it reads
## the env fog colour the cycle just set and lerps it toward storm ochre). The
## world_map.tscn child order enforces this; keep DayNightCycle first.
##
## ── Localized, not global ────────────────────────────────────────────────────
## A storm is a *place* in the dunes, not a global toggle. Each storm has a
## centre in `world_offset` space, a radius, and a time window. The FogVolume
## is a child of this node (a child of WorldMap), positioned at the storm's
## world coordinates — the SAME convention chunk bodies use (ChunkManager adds
## chunks at their world position and WorldMap's scroll transform maps it under
## the stationary ship). So the storm stays fixed in the dunes while the ship
## sails past it, for free, via the world-scroll trick.
##
## ── Determinism / multiplayer ────────────────────────────────────────────────
## The whole schedule is a pure function of GameState.weather_seed +
## GameState.world_time(). Every peer computes the identical storm timeline; no
## replication. The centre is latched once from the (replicated, deterministic)
## ship.world_offset when a storm first goes active, so storms appear along the
## crew's actual route rather than uselessly far away — same idea as
## bandit_director spawning relative to the moving player.
##
## ── Layering ─────────────────────────────────────────────────────────────────
##   • Environment depth fog  — ochre distance falloff (tinted from intensity).
##   • Volumetric fog + FogVolume — the storm's visible body / sun shafts.
##   • GPUParticles3D         — foreground grit, pinned to the ship.
## Intensity (0..1) is distance-to-centre × time-ramp; exposed for the HUD,
## bandit_director (more raids), and AI gunnery (hold fire in a whiteout).
##

@export var storm_period: float = 600.0          # one potential storm window per this many seconds
@export var storm_chance: float = 0.55            # probability a given window actually storms
@export var storm_duration_min: float = 120.0
@export var storm_duration_max: float = 260.0
@export var storm_radius_min: float = 220.0
@export var storm_radius_max: float = 420.0
@export var spawn_ahead_min: float = 150.0        # storm centre is dropped this far around the ship
@export var spawn_ahead_max: float = 520.0
@export var edge_ramp: float = 18.0               # seconds to fade a storm in / out at its window edges
@export var max_extra_fog_density: float = 0.045  # added to env depth fog at full intensity
@export var grit_max_amount: int = 900            # GPUParticles3D amount at full intensity

var _ship: Node = null
var _env: Environment = null
var _fog_volume: FogVolume = null
var _fog_mat: FogMaterial = null
var _grit: GPUParticles3D = null
var _base_fog_density: float = 0.005

# period index → latched { "center": Vector3, "radius": float,
#                           "start": float, "duration": float }  (or {} = no storm)
var _latched: Dictionary = {}
var _intensity: float = 0.0
var _ochre := Color(0.62, 0.45, 0.22)


func _ready() -> void:
	add_to_group("weather")
	_resolve_env()
	_build_fog_volume()
	_build_grit()


func _resolve_env() -> void:
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	var we := _find_first(root, "WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		_env = we.environment
		_base_fog_density = _env.fog_density
		# Forward+ volumetric fog — global, but gated by the player's local
		# intensity below so it only reads as fog when you're IN the storm.
		_env.volumetric_fog_enabled = true
		_env.volumetric_fog_density = 0.0


func _find_first(node: Node, cls: String) -> Node:
	for child in node.get_children():
		if child.is_class(cls):
			return child
		var found := _find_first(child, cls)
		if found != null:
			return found
	return null


## The visible storm body. A box FogVolume centred on the storm; density is
## scaled by live intensity so it grows/decays smoothly at the window edges.
func _build_fog_volume() -> void:
	_fog_volume = FogVolume.new()
	_fog_volume.name = "SandstormVolume"
	_fog_volume.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	_fog_mat = FogMaterial.new()
	_fog_mat.density = 0.0
	_fog_mat.albedo = Color(0.78, 0.62, 0.36)
	_fog_volume.material = _fog_mat
	_fog_volume.visible = false
	add_child(_fog_volume)


## Foreground grit. Pinned to the ship (top_level) so it follows the deck in
## scene space; emission amount tracks intensity.
func _build_grit() -> void:
	_grit = GPUParticles3D.new()
	_grit.name = "SandGrit"
	_grit.top_level = true
	_grit.amount = grit_max_amount
	_grit.lifetime = 1.4
	_grit.emitting = false
	_grit.local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(60.0, 30.0, 60.0)
	pm.direction = Vector3(1.0, 0.05, 0.3)
	pm.spread = 25.0
	pm.initial_velocity_min = 28.0
	pm.initial_velocity_max = 46.0
	pm.gravity = Vector3.ZERO
	pm.scale_min = 0.4
	pm.scale_max = 1.1
	pm.color = Color(0.80, 0.66, 0.42, 0.55)
	_grit.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.35, 0.35)
	var qm := StandardMaterial3D.new()
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.albedo_color = Color(0.82, 0.68, 0.44, 0.5)
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	quad.material = qm
	_grit.draw_pass_1 = quad
	add_child(_grit)


func _resolve_ship() -> void:
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("ship")


## Deterministic per-window storm descriptor. Pure function of weather_seed and
## the period index — every peer derives the same start time / radius / chance.
## The centre is latched lazily (needs the live ship position) the first time
## the window is queried while active; the latch is cached so it's stable.
func _storm_for_period(p: int) -> Dictionary:
	if _latched.has(p):
		return _latched[p]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(GameState.weather_seed, p))
	if rng.randf() > storm_chance:
		_latched[p] = {}
		return {}
	var duration := rng.randf_range(storm_duration_min, storm_duration_max)
	var start := float(p) * storm_period \
			+ rng.randf_range(0.0, maxf(0.0, storm_period - duration))
	var radius := rng.randf_range(storm_radius_min, storm_radius_max)
	# Centre is resolved later (needs ship pos at activation). Stash the RNG
	# draws we need for a stable offset so the latch is deterministic.
	var ang := rng.randf() * TAU
	var dist := rng.randf_range(spawn_ahead_min, spawn_ahead_max)
	var desc := {
		"start": start,
		"duration": duration,
		"radius": radius,
		"offset": Vector3(cos(ang) * dist, 0.0, sin(ang) * dist),
		"center": Vector3.INF,   # sentinel: not yet latched
	}
	_latched[p] = desc
	return desc


## Window-edge time ramp: 0 before/after, 1 in the steady middle, linear
## `edge_ramp`-second fades at each end.
func _time_ramp(now: float, start: float, duration: float) -> float:
	if now < start or now > start + duration:
		return 0.0
	var into := now - start
	var out := (start + duration) - now
	return clampf(minf(into, out) / maxf(edge_ramp, 0.001), 0.0, 1.0)


func _process(_delta: float) -> void:
	_resolve_ship()
	var now := GameState.world_time()
	var ship_off := Vector3.ZERO
	if _ship != null and "world_offset" in _ship:
		ship_off = _ship.world_offset

	# Consider the current and previous window (a storm can straddle the edge).
	var p_now := int(floor(now / storm_period))
	var best := 0.0
	var active_center := Vector3.ZERO
	var active_radius := 1.0
	for p in [p_now - 1, p_now]:
		var s := _storm_for_period(p)
		if s.is_empty():
			continue
		var ramp := _time_ramp(now, s["start"], s["duration"])
		if ramp <= 0.0:
			continue
		# Latch the centre once, the first active frame, from the live (shared)
		# ship position so the storm sits along the crew's route.
		if (s["center"] as Vector3) == Vector3.INF:
			s["center"] = ship_off + (s["offset"] as Vector3)
			_latched[p] = s
		var center: Vector3 = s["center"]
		var radius: float = s["radius"]
		var d := Vector2(ship_off.x - center.x, ship_off.z - center.z).length()
		# 1 in the core, smoothly 0 by the radius edge.
		var spatial := 1.0 - smoothstep(radius * 0.45, radius, d)
		var inten := spatial * ramp
		if inten > best:
			best = inten
			active_center = center
			active_radius = radius

	_intensity = best
	_apply(active_center, active_radius, ship_off)


## Drive the three fog layers from the resolved intensity. Reads the env fog
## colour DayNightCycle set this frame and lerps it toward ochre, so day/night
## tinting and storms compose instead of fighting (requires this node to
## process after DayNightCycle — enforced by world_map.tscn child order).
func _apply(center: Vector3, radius: float, ship_off: Vector3) -> void:
	var k := _intensity

	if _env != null:
		_env.fog_density = _base_fog_density + max_extra_fog_density * k
		if k > 0.001:
			_env.fog_light_color = _env.fog_light_color.lerp(_ochre, clampf(k, 0.0, 0.9))
		_env.volumetric_fog_density = 0.05 * k

	if _fog_volume != null:
		if k > 0.001:
			_fog_volume.visible = true
			# Local position = world coords (chunk-body convention under WorldMap).
			_fog_volume.position = Vector3(center.x, ship_off.y, center.z)
			_fog_volume.size = Vector3(radius * 2.0, 120.0, radius * 2.0)
			_fog_mat.density = 0.06 * k
		else:
			_fog_volume.visible = false

	if _grit != null:
		if _ship != null and is_instance_valid(_ship):
			_grit.global_position = (_ship as Node3D).global_position
		_grit.emitting = k > 0.05
		var pm := _grit.process_material as ParticleProcessMaterial
		if pm != null:
			pm.color = Color(0.80, 0.66, 0.42, clampf(0.15 + 0.6 * k, 0.0, 0.85))
		_grit.amount_ratio = clampf(k, 0.0, 1.0)


# ── Public API (HUD / bandit_director / AI) ──────────────────────────────────

## 0 = clear, 1 = full whiteout at the storm core.
func get_storm_intensity() -> float:
	return _intensity


func is_storming() -> bool:
	return _intensity > 0.15
