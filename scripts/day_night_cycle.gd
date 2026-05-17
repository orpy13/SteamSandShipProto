extends Node3D
##
## DAY / NIGHT CYCLE — a navigationally-relevant celestial system.
##
## Lives as a child of WorldMap. Drives the existing main.tscn WorldEnvironment
## and DirectionalLight3D (no duplicate rig is spawned — we find and steer the
## nodes that are already there) plus a code-built Moon light and a Pole Star
## marker for night-time heading.
##
## ── Navigational relevance ───────────────────────────────────────────────────
## The ship never moves or yaws in scene space; ChunkManager scrolls the world
## by the inverse of `virtual_yaw` (rotation.y = -yaw). For the sun to read as
## a real compass it must obey that SAME inverse rotation — otherwise it stays
## glued to a fixed screen direction no matter which way you steer.
##
## So: we compute the sun/star direction in a fixed WORLD frame (a fixed
## "east"), then rotate it by Basis(UP, -ship.virtual_yaw) before applying it
## to the lights. Turn the ship and the sun sweeps across the sky exactly as
## the dunes rotate beneath it; hold a heading by keeping the sun at a constant
## screen angle. At night the Pole Star plays the same role.
##
## The Moon/PoleStar rig is pinned to the ship's scene position every frame and
## ONLY rotated, so finite-distance markers don't parallax as `world_offset`
## grows — they behave as if at infinity (a true bearing reference).
##
## ── Determinism / multiplayer ────────────────────────────────────────────────
## time_of_day is derived purely from GameState.world_time() (shared epoch set
## by the host, replicated once on join). No per-frame replication; every peer
## computes the identical sky locally. See game_state.gd / network_manager.gd.
##

## Full sunrise→sunrise period in seconds. 2400 = 40 minutes (user spec).
@export var day_length_seconds: float = 2400.0
## Southward tilt of the solar arc (0 = straight overhead E→W, higher = lower
## arc through the southern sky). Purely aesthetic; doesn't affect the compass.
@export var solar_tilt: float = 0.25
## Local distance the Pole Star marker sits from the rig origin.
@export var pole_star_distance: float = 600.0
## Distance the sun-halo / moon billboards sit from the rig (keep < camera far).
@export var celestial_distance: float = 1400.0
## Apparent angular diameter of the sun glow billboard, in degrees (stylized,
## bigger than the real ~0.5° so the bloom has a shaped falloff).
@export var sun_disc_angular_deg: float = 7.0
## Apparent angular diameter of the moon billboard, in degrees.
@export var moon_disc_angular_deg: float = 5.0
## Glow intensity at full day (ramped to near-zero at night). The over-bright
## sun disc blooms through this — it's what sells "too bright to look at".
@export var glow_day_intensity: float = 0.9
## Auto-exposure makes the scene stop down when the sun is in frame (sells the
## brightness) but also lifts night somewhat. Disable if night reads too pale.
@export var use_auto_exposure: bool = true

# World-frame cardinal convention (also documented in instructions.md):
#   +X = East, -X = West, +Z = North, -Z = South, +Y = up.
# Sun rises toward +X, peaks overhead, sets toward -X.

var _ship: Node = null
var _sun: DirectionalLight3D = null            # the existing main.tscn light
var _world_env: WorldEnvironment = null
var _env: Environment = null
var _sky_mat: ProceduralSkyMaterial = null
var _moon: DirectionalLight3D = null
var _rig: Node3D = null                        # holds Pole Star + billboards; pinned + rotated
var _pole_star: MeshInstance3D = null
var _sun_halo: MeshInstance3D = null           # additive glow billboard at the sun
var _moon_disc: MeshInstance3D = null          # emissive billboard at the anti-sun
var _camera_anchor: Node3D = null              # what we pin the rig to (ship)

# Cached so HUD / weather / AI can read the cycle without recomputing.
var _time_of_day: float = 0.0                  # [0,1): 0=dawn .25=noon .5=dusk .75=midnight
var _daylight: float = 1.0                     # 0 = full night, 1 = full day


func _ready() -> void:
	add_to_group("day_night")
	_find_environment_and_sun()
	_setup_environment()
	_build_moon()
	_build_pole_star()
	_build_celestial_billboards()


## Recursively locate the WorldEnvironment + the first DirectionalLight3D that
## isn't our own Moon. Done by scan (not group/path) so we don't have to edit
## main.tscn — the rig already exists there, we just adopt it.
func _find_environment_and_sun() -> void:
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	var we := _find_first(root, "WorldEnvironment") as WorldEnvironment
	_world_env = we
	if we != null and we.environment != null:
		_env = we.environment
		if _env.sky != null and _env.sky.sky_material is ProceduralSkyMaterial:
			_sky_mat = _env.sky.sky_material
	_sun = _find_first(root, "DirectionalLight3D", _moon) as DirectionalLight3D


## Depth-first search for the first node whose class matches `cls`, skipping
## `except`. Returns null if none found.
func _find_first(node: Node, cls: String, except: Node = null) -> Node:
	for child in node.get_children():
		if child != except and child.is_class(cls):
			return child
		var found := _find_first(child, cls, except)
		if found != null:
			return found
	return null


## A dim, cool fill light for night so the dunes stay readable (Forward+ has
## no GI in this project — without this, night is unplayably black).
func _build_moon() -> void:
	_moon = DirectionalLight3D.new()
	_moon.name = "MoonLight"
	_moon.light_color = Color(0.55, 0.62, 0.85)
	_moon.light_energy = 0.0          # ramped in _update_lighting
	_moon.shadow_enabled = false
	add_child(_moon)


## The Pole Star: a small emissive marker fixed to world-North. It rides a rig
## that is re-pinned to the ship every frame and rotated by -virtual_yaw, so it
## holds a constant true bearing (acts as the night-time compass).
func _build_pole_star() -> void:
	_rig = Node3D.new()
	_rig.name = "CelestialRig"
	_rig.top_level = true             # ignore WorldMap's scroll transform; we drive it explicitly
	add_child(_rig)

	_pole_star = MeshInstance3D.new()
	_pole_star.name = "PoleStar"
	var sphere := SphereMesh.new()
	sphere.radius = 6.0
	sphere.height = 12.0
	_pole_star.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(0.85, 0.9, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.albedo_color = Color(0.9, 0.95, 1.0)
	_pole_star.material_override = mat
	# Local +Z = North, raised a little so it sits above the horizon.
	_pole_star.position = Vector3(0.0, pole_star_distance * 0.35, pole_star_distance)
	_pole_star.visible = false
	_rig.add_child(_pole_star)


## Configure the shared Environment for the "bright sun" look: HDR glow so the
## over-bright disc blooms, a filmic tonemap so highlights roll off instead of
## hard-clipping, and auto-exposure so the scene stops down when the sun is in
## frame (the biggest single contributor to "too bright to look at").
func _setup_environment() -> void:
	if _env != null:
		_env.glow_enabled = true
		_env.glow_bloom = 0.15
		_env.glow_hdr_threshold = 1.0
		_env.glow_intensity = glow_day_intensity
		_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	# Auto-exposure rides on the WorldEnvironment's camera attributes so every
	# player camera inherits it (none of them set their own attributes).
	if _world_env != null and use_auto_exposure:
		var ca := CameraAttributesPractical.new()
		ca.auto_exposure_enabled = true
		ca.auto_exposure_scale = 0.4
		ca.auto_exposure_speed = 0.6
		_world_env.camera_attributes = ca


## A soft radial alpha gradient (white core → transparent edge), generated in
## code so we ship no texture files (matches the project's procedural ethos).
func _make_radial_texture(core: Color, edge_fade: float) -> GradientTexture2D:
	var grad := Gradient.new()
	grad.set_color(0, core)
	grad.set_color(1, Color(core.r, core.g, core.b, 0.0))
	grad.add_point(edge_fade, Color(core.r, core.g, core.b, core.a * 0.5))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


## Quad side length for a billboard of `angular_deg` apparent diameter sitting
## at `celestial_distance`.
func _disc_size(angular_deg: float) -> float:
	return 2.0 * celestial_distance * tan(deg_to_rad(angular_deg) * 0.5)


## Build the sun-glow and moon billboards as children of the rig (same rig the
## Pole Star rides — pinned to the ship, rotated by -yaw, so they sit at the
## correct apparent sky position with no parallax). Camera-facing quads with
## procedural radial textures; the sun is additive so it blooms, the moon is a
## crisper emissive disc.
func _build_celestial_billboards() -> void:
	if _rig == null:
		return

	_sun_halo = MeshInstance3D.new()
	_sun_halo.name = "SunHalo"
	var sq := QuadMesh.new()
	sq.size = Vector2.ONE * _disc_size(sun_disc_angular_deg)
	_sun_halo.mesh = sq
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	sm.billboard_keep_scale = true
	sm.disable_receive_shadows = true
	sm.albedo_texture = _make_radial_texture(Color(1.0, 0.95, 0.85, 1.0), 0.35)
	sm.emission_enabled = true
	sm.emission = Color(1.0, 0.93, 0.80)
	sm.emission_energy_multiplier = 6.0     # >1 so it blooms through glow
	_sun_halo.material_override = sm
	_sun_halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rig.add_child(_sun_halo)

	_moon_disc = MeshInstance3D.new()
	_moon_disc.name = "MoonDisc"
	var mq := QuadMesh.new()
	mq.size = Vector2.ONE * _disc_size(moon_disc_angular_deg)
	_moon_disc.mesh = mq
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mm.billboard_keep_scale = true
	mm.disable_receive_shadows = true
	# Crisper edge than the sun (opaque core, quick falloff) so it reads as a
	# disc, not a glow.
	mm.albedo_texture = _make_radial_texture(Color(0.86, 0.89, 1.0, 1.0), 0.72)
	mm.emission_enabled = true
	mm.emission = Color(0.70, 0.76, 0.95)
	mm.emission_energy_multiplier = 1.6
	_moon_disc.material_override = mm
	_moon_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon_disc.visible = false
	_rig.add_child(_moon_disc)


## Place the sun glow at the (pre-yaw, fixed-frame) sun direction and the moon
## opposite it; the rig basis applies -yaw so both land at the right apparent
## spot. Visibility cross-fades with daylight.
func _update_billboards(sun_world: Vector3) -> void:
	if _sun_halo != null:
		_sun_halo.position = sun_world * celestial_distance
		_sun_halo.visible = _daylight > 0.02
		var sm := _sun_halo.material_override as StandardMaterial3D
		if sm != null:
			sm.emission_energy_multiplier = lerpf(1.5, 6.0, _daylight)
	if _moon_disc != null:
		_moon_disc.position = -sun_world * celestial_distance
		# Visible through night + twilight, faded out by full day.
		_moon_disc.visible = _daylight < 0.85
		var mm := _moon_disc.material_override as StandardMaterial3D
		if mm != null:
			var a := clampf(1.0 - smoothstep(0.45, 0.85, _daylight), 0.0, 1.0)
			mm.albedo_color = Color(1.0, 1.0, 1.0, a)


## Resolve and cache the ship (authority-independent group lookup).
func _resolve_ship() -> void:
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("ship")
		_camera_anchor = _ship as Node3D


func _process(_delta: float) -> void:
	_resolve_ship()

	# ── Time of day from the shared clock ────────────────────────────────────
	var secs := GameState.world_time()
	_time_of_day = fposmod(secs, day_length_seconds) / day_length_seconds

	# ── Solar position in the fixed WORLD frame ──────────────────────────────
	# ang: 0 at dawn (+X horizon), PI/2 at noon (+Y), PI at dusk (-X), 3PI/2 at
	# midnight (-Y, below ground). z carries the southward tilt of the arc.
	var ang := _time_of_day * TAU
	var sun_world := Vector3(cos(ang), sin(ang), -solar_tilt).normalized()

	# ── Compass coupling: rotate by -virtual_yaw (mirror ChunkManager) ───────
	var yaw := 0.0
	if _ship != null and "virtual_yaw" in _ship:
		yaw = float(_ship.virtual_yaw)
	var sky_rot := Basis(Vector3.UP, -yaw)
	var sun_dir := sky_rot * sun_world          # apparent sun position (unit)

	# ── Daylight factor (smooth dawn/dusk) ───────────────────────────────────
	# Sun height above the horizon, softened so the transition isn't a hard cut.
	_daylight = clampf(smoothstep(-0.08, 0.18, sun_dir.y), 0.0, 1.0)

	_orient_lights(sun_dir)
	_update_lighting()
	_update_rig(sky_rot)
	_update_billboards(sun_world)


## Point the sun (and the anti-solar moon) along the apparent directions.
## A DirectionalLight shines along its local -Z, so we look_at the direction
## the light travels (from the body toward the ground = -body_dir).
func _orient_lights(sun_dir: Vector3) -> void:
	if _sun != null:
		_sun.global_position = Vector3.ZERO
		_aim_light(_sun, -sun_dir)
		_sun.visible = _daylight > 0.001
	if _moon != null:
		_moon.global_position = Vector3.ZERO
		# Moon sits opposite the sun; only matters visually at night.
		_aim_light(_moon, sun_dir)
		_moon.visible = _daylight < 0.999


## Orient a DirectionalLight so its -Z points along `travel_dir`. Guards the
## degenerate case where the direction is parallel to UP (sun at zenith).
func _aim_light(light: DirectionalLight3D, travel_dir: Vector3) -> void:
	if travel_dir.length_squared() < 0.0001:
		return
	var up := Vector3.UP
	if absf(travel_dir.normalized().dot(Vector3.UP)) > 0.999:
		up = Vector3.FORWARD
	light.look_at(travel_dir, up)


## Cross-fade sun/moon energy, ambient, sky and fog tint across the cycle.
## Hand-authored ramps (no GI in Compatibility-era assets / Forward+ here we
## still drive ambient explicitly so dusk reads warm and night reads cold).
func _update_lighting() -> void:
	var d := _daylight
	# Warm low sun → neutral noon. Blend by a "high sun" weight.
	var noon := smoothstep(0.15, 0.75, d)
	if _sun != null:
		_sun.light_energy = lerpf(0.0, 1.25, d)
		_sun.light_color = Color(1.0, 0.62, 0.42).lerp(Color(1.0, 0.97, 0.92), noon)

	if _moon != null:
		_moon.light_energy = lerpf(0.16, 0.0, d)

	if _env != null:
		_env.ambient_light_energy = lerpf(0.16, 0.55, d)
		var night_amb := Color(0.20, 0.26, 0.40)
		var day_amb := Color(0.55, 0.65, 0.80)
		_env.ambient_light_color = night_amb.lerp(day_amb, d)
		# Distance haze recolours with the sky (kept thin; the weather system
		# thickens it during sandstorms).
		var night_fog := Color(0.10, 0.13, 0.22)
		var day_fog := Color(0.62, 0.70, 0.80)
		_env.fog_light_color = night_fog.lerp(day_fog, d)
		# Strong bloom under the noon sun, almost none at night (otherwise the
		# moon/stars smear).
		_env.glow_intensity = lerpf(0.08, glow_day_intensity, d)

	if _sky_mat != null:
		var dusk_top := Color(0.12, 0.13, 0.26)
		var day_top := Color(0.18, 0.32, 0.55)
		_sky_mat.sky_top_color = dusk_top.lerp(day_top, d)
		var dusk_hz := Color(0.55, 0.32, 0.20)
		var day_hz := Color(0.65, 0.75, 0.85)
		_sky_mat.sky_horizon_color = dusk_hz.lerp(day_hz, smoothstep(0.0, 0.6, d))
		_sky_mat.sky_energy_multiplier = lerpf(0.35, 1.0, d)


## Pin the Pole-Star rig to the ship and apply ONLY the -yaw rotation, so the
## marker holds a fixed world bearing without parallaxing as world_offset grows.
func _update_rig(sky_rot: Basis) -> void:
	if _rig == null:
		return
	var origin := Vector3.ZERO
	if _camera_anchor != null and is_instance_valid(_camera_anchor):
		origin = _camera_anchor.global_position
	# Assign a whole Transform3D — `node.global_transform.basis = x` only
	# mutates a temporary copy in GDScript and would not persist.
	_rig.global_transform = Transform3D(sky_rot, origin)
	if _pole_star != null:
		# Fade the star in as the sky darkens.
		_pole_star.visible = _daylight < 0.65
		var m := _pole_star.material_override as StandardMaterial3D
		if m != null:
			m.emission_energy_multiplier = lerpf(5.0, 0.0, clampf(_daylight / 0.65, 0.0, 1.0))


# ── Public API (HUD / weather / AI) ──────────────────────────────────────────

## 0=dawn, 0.25=noon, 0.5=dusk, 0.75=midnight (wraps).
func get_time_of_day() -> float:
	return _time_of_day


## 0 at full night, 1 at full day, smoothly through dawn/dusk.
func get_daylight() -> float:
	return _daylight


func is_night() -> bool:
	return _daylight < 0.25


## Coarse clock label for the HUD ("Dawn", "Day", "Dusk", "Night").
func get_phase_name() -> String:
	if _daylight >= 0.85:
		return "Day"
	if _daylight <= 0.15:
		return "Night"
	# Rising vs falling sun → dawn vs dusk.
	return "Dawn" if _time_of_day < 0.25 else "Dusk"
