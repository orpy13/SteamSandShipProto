extends Node3D
##
## AI SAND SHIP — a bandit ship that paces the player and fires broadsides.
##
## Lives as a child of `WorldMap` (NOT the player ship). Its authoritative
## state is the same `world_offset` / `virtual_yaw` pattern the player ship
## uses, so it shares a coordinate system with the player and the chunk
## manager's world-scroll trick automatically positions it on screen.
##
## See instructions.md → "The world-scroll trick" for the underlying model.
##
## States:
##   APPROACH  — drive straight at the player, ramp speed up.
##   PACE      — once inside engage_distance, lock to a side and match the
##                player's heading + speed at a fixed standoff.
##   (No retreat yet — bandit fights to the death.)
##
## Authority: server only simulates the AI. All peers replicate
## world_offset / virtual_yaw / current_speed / state via MultiplayerSynchronizer.
##

# ── Drive tuning ──────────────────────────────────────────────────────────────
@export var max_speed: float = 18.0           # has to keep ahead-of-pace at long standoff
@export var acceleration: float = 4.0
@export var turn_speed: float = 0.9           # rad/s
@export var turn_acceleration: float = 2.5

# ── Engagement geometry ──────────────────────────────────────────────────────
# engage_distance is comfortably > standoff_distance so the bandit arcs into
# its slot rather than charging the player and then yanking 90° at the end.
@export var engage_distance: float = 180.0    # switch APPROACH → PACE inside this
@export var standoff_distance: float = 130.0  # how far to the side we sit while pacing
@export var fire_interval: float = 3.5        # seconds between cannon shots — long range = deliberate
@export var cannonball_speed: float = 80.0    # m/s — fast enough to cover 130m in ~1.6s but still dodgeable
@export var spread_radians: float = deg_to_rad(1.0)  # half-angle of dispersion cone

# ── Terrain following (mirrors ship_controller pattern, scaled to AI hull) ───
@export var terrain_clearance: float = 0.3
@export var terrain_tilt_lerp: float = 5.0
@export var terrain_height_lerp: float = 6.0
@export var terrain_pitch_amount: float = 1.0
@export var terrain_roll_amount: float = 1.0
@export var terrain_contact_front: float = 16.0
@export var terrain_contact_back: float = -16.0
@export var terrain_contact_side: float = 5.5

# ── Replicated state (authority = server) ────────────────────────────────────
const STATE_APPROACH := 0
const STATE_PACE := 1
var world_offset: Vector3 = Vector3.ZERO
var virtual_yaw: float = 0.0
var current_speed: float = 0.0
var state: int = STATE_APPROACH

# ── Damage ───────────────────────────────────────────────────────────────────
# Bandits use a simpler two-system model: hull integrity for absorption (zero =
# destroyed) and mobility for speed cap. Both are *external* — hull-face walls
# and the wheels — so every hit is a direct hit; there is no penetration cone
# (bandits have no systems behind the hull for fragments to reach).
signal damage_taken(hit_count: int, part: String)
signal system_changed(system: String, integrity: float)

@export var direct_hit_damage: float = 0.15
@export var min_mobility_factor: float = 0.3

var hit_count: int = 0
var last_hit_part: String = ""

var system_integrity: Dictionary = {
	"hull":     1.0,
	"mobility": 1.0,
}

# ── Server-local state (not replicated) ──────────────────────────────────────
var _current_turn_rate: float = 0.0
var _engagement_side: int = 1     # +1 = starboard (right), -1 = port (left)
var _fire_timer: float = 0.0
var _terrain: Node = null
var _player_ship: Node = null

# ── Local visual state (per-peer; smoothed for pitch/roll feel) ──────────────
var _current_pitch: float = 0.0
var _current_roll: float = 0.0
var _current_y: float = 0.0


## Register in the bandit group so player shells (target_group = "bandit") can
## find us. Choose a side to engage on, seed the fire timer.
func _ready() -> void:
	add_to_group("bandit")
	# Picked once at spawn so the bandit doesn't waffle between sides mid-fight.
	_engagement_side = 1 if randf() < 0.5 else -1
	_fire_timer = fire_interval * 0.5  # first shot comes faster than the rest


## Called by player shells on hit. Same shape as ship_controller.register_hit
## (the impact/velocity args are accepted for call compatibility but unused —
## bandits have no internal systems, so every hit is a direct hit, no cone).
## Server-only entry. Bandit is destroyed once hull integrity hits 0.
func register_hit(part: String, _impact_world: Vector3 = Vector3.ZERO, _velocity_world: Vector3 = Vector3.ZERO) -> void:
	if not multiplayer.is_server():
		return
	_apply_hit.rpc(part)
	var primary := _part_to_primary_system(part)
	if primary.is_empty():
		return
	_apply_damage.rpc(primary, direct_hit_damage)
	# Destruction check: hull integrity at zero, the wagon comes apart.
	if float(system_integrity.get("hull", 1.0)) <= 0.0:
		var bdir := get_tree().get_first_node_in_group("bandit_director")
		if bdir != null and bdir.has_method("destroy_bandit"):
			bdir.destroy_bandit(name)


## Bandits don't have hull sub-buckets — every hull-face name and the generic
## "hull" collapse to a single "hull" bucket. Wheel hits go to mobility.
func _part_to_primary_system(part: String) -> String:
	match part:
		"hull", "hull_left", "hull_right", "hull_fore", "hull_aft":
			return "hull"
		"wheel":  return "mobility"
		"bridge": return "hull"  # bandits have no bridge system; absorb as hull
		_:        return ""


## All peers: bump hit counter + emit pulse (existing behaviour, preserved
## for screen-shake parity with the player ship).
@rpc("any_peer", "call_local", "reliable")
func _apply_hit(part: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	hit_count += 1
	last_hit_part = part
	damage_taken.emit(hit_count, part)


## Apply an integrity delta on every peer and notify listeners.
@rpc("any_peer", "call_local", "reliable")
func _apply_damage(system: String, amount: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	if not system_integrity.has(system):
		return
	var new_value := clampf(float(system_integrity[system]) - amount, 0.0, 1.0)
	system_integrity[system] = new_value
	system_changed.emit(system, new_value)


## Server simulates the AI. All peers (including server) read replicated state
## and pose the visual in WorldMap-local space.
func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_simulate(delta)
	# Visual pose — WorldMap's transform takes care of relating us to the player.
	_apply_visual_pose()


## Host-only: run the state machine and update authoritative state.
func _simulate(delta: float) -> void:
	var player := _get_player_ship()
	if player == null:
		# Without a player to chase we just drift. Shouldn't happen in practice.
		current_speed = move_toward(current_speed, 0.0, acceleration * delta)
		_integrate(delta)
		return

	# Geometry the state machine reasons about.
	var player_offset: Vector3 = player.world_offset
	var to_player: Vector3 = player_offset - world_offset
	to_player.y = 0.0
	var distance := to_player.length()

	# State transition: snap into PACE once we're close enough.
	if state == STATE_APPROACH and distance <= engage_distance:
		state = STATE_PACE

	# Mobility damage caps how fast we can go. At zero integrity we still limp
	# along at min_mobility_factor× max_speed — damaged bandits become slow,
	# easy targets but not stationary ones.
	var mobility_factor := lerpf(min_mobility_factor, 1.0, float(system_integrity.get("mobility", 1.0)))
	var eff_max_speed := max_speed * mobility_factor

	# Target pose depends on state.
	var target_offset: Vector3
	var target_yaw: float
	var target_speed: float
	if state == STATE_APPROACH:
		target_offset = player_offset
		target_yaw = atan2(to_player.x, to_player.z)
		target_speed = eff_max_speed
	else:
		# PACE: hold a position broadside-on to the player at standoff_distance.
		# We try to match the player's speed, but the clamp below caps us at
		# our own (possibly damaged) maximum — slow bandits fall behind.
		var player_right := Vector3(cos(player.virtual_yaw), 0.0, -sin(player.virtual_yaw))
		target_offset = player_offset + player_right * standoff_distance * float(_engagement_side)
		target_yaw = player.virtual_yaw
		target_speed = float(player.current_speed)

	# Steer + throttle toward the target pose.
	_steer_toward(target_yaw, target_offset, delta)
	current_speed = move_toward(current_speed, target_speed, acceleration * delta)
	current_speed = clampf(current_speed, -eff_max_speed, eff_max_speed)
	_integrate(delta)

	# Fire if we're in pace and the timer says so — but not in a whiteout: a
	# heavy sandstorm blinds the bandit's gun crew too (and it would be unfair
	# to be shelled by something you can't see to shoot back at).
	if state == STATE_PACE:
		_fire_timer -= delta
		if _fire_timer <= 0.0:
			_fire_timer = fire_interval
			if _storm_intensity() < 0.6:
				_fire_cannon(player_offset)


## Rotate toward the desired heading. If we're not yet in PACE we just point
## the bow at the target; otherwise we also use the *positional* error so we
## actually slot into the standoff slot rather than just orbiting.
func _steer_toward(target_yaw: float, target_offset: Vector3, delta: float) -> void:
	var heading_error := wrapf(target_yaw - virtual_yaw, -PI, PI)
	# In PACE, fold positional error into the steering signal so we converge
	# on the slot instead of just paralleling the player.
	if state == STATE_PACE:
		var offset_error: Vector3 = target_offset - world_offset
		offset_error.y = 0.0
		# Sideways component of the error in the bandit's own frame.
		var bandit_right := Vector3(cos(virtual_yaw), 0.0, -sin(virtual_yaw))
		var side_error := offset_error.dot(bandit_right)
		heading_error += clampf(side_error * 0.04, -0.6, 0.6)
		heading_error = clampf(heading_error, -PI, PI)
	var target_turn_rate := clampf(heading_error * 2.0, -turn_speed, turn_speed)
	_current_turn_rate = move_toward(_current_turn_rate, target_turn_rate, turn_acceleration * delta)
	virtual_yaw += _current_turn_rate * delta


## Advance world_offset by the heading × current_speed.
func _integrate(delta: float) -> void:
	var forward := Vector3(sin(virtual_yaw), 0.0, cos(virtual_yaw))
	world_offset += forward * current_speed * delta


## Pose the visual mesh in WorldMap-local space. Mirrors the player ship's
## four-point terrain sampler so the bandit pitches and rolls over dunes.
##
## Why the rotation works: setting `rotation = (pitch, virtual_yaw, roll)` on
## a Node3D with YXZ Euler order produces R_y(yaw)·R_x(pitch)·R_z(roll). After
## WorldMap counter-rotates by -player_yaw, the final scene rotation is
## R_y(yaw - player_yaw)·R_x(pitch)·R_z(roll) — i.e. pitch and roll applied in
## the bandit's own body frame, which is what we want visually.
func _apply_visual_pose() -> void:
	if _terrain == null or not is_instance_valid(_terrain):
		_terrain = get_tree().get_first_node_in_group("terrain")

	var target_y: float = 0.0
	var target_pitch: float = 0.0
	var target_roll: float = 0.0
	if _terrain != null and _terrain.has_method("sample_height"):
		var front_h := _sample_terrain_height(Vector3(0.0, 0.0, terrain_contact_front))
		var back_h := _sample_terrain_height(Vector3(0.0, 0.0, terrain_contact_back))
		var right_h := _sample_terrain_height(Vector3(terrain_contact_side, 0.0, 0.0))
		var left_h := _sample_terrain_height(Vector3(-terrain_contact_side, 0.0, 0.0))
		var wheel_base := terrain_contact_front - terrain_contact_back
		var track_width := terrain_contact_side * 2.0
		# Sit on top of the highest contact — same logic as the player ship.
		target_y = maxf(maxf(front_h, back_h), maxf(left_h, right_h)) + terrain_clearance
		target_pitch = atan2(back_h - front_h, wheel_base) * terrain_pitch_amount
		target_roll = atan2(right_h - left_h, track_width) * terrain_roll_amount

	var dt := get_physics_process_delta_time()
	var height_weight := clampf(terrain_height_lerp * dt, 0.0, 1.0)
	var tilt_weight := clampf(terrain_tilt_lerp * dt, 0.0, 1.0)
	_current_y = lerpf(_current_y, target_y, height_weight)
	_current_pitch = lerpf(_current_pitch, target_pitch, tilt_weight)
	_current_roll = lerpf(_current_roll, target_roll, tilt_weight)

	position = Vector3(world_offset.x, _current_y, world_offset.z)
	rotation = Vector3(_current_pitch, virtual_yaw, _current_roll)


## Translate a body-local contact offset into the world position used by the
## noise sampler — same trick as ship_controller._sample_terrain_height.
func _sample_terrain_height(local_offset: Vector3) -> float:
	var sample_pos := world_offset + Basis(Vector3.UP, virtual_yaw) * local_offset
	return float(_terrain.call("sample_height", sample_pos.x, sample_pos.z))


## Spawn a cannonball from the engaged-side muzzle, aimed at the player's
## hull with ballistic drop compensation so long-range shots actually arrive.
##
## Y convention: cannonballs treat `world_offset.y` as their scene-space Y
## (see cannonball.gd). The bandit's own `world_offset.y` is always 0, so
## for muzzle/aim heights we use the visual scene Y (`_current_y` for us,
## `global_position.y` for the player) — otherwise both ends sit at world Y=0
## and every shot effectively flies through the dunes.
##
## No lead prediction — players can dodge by altering course while the ball
## is in flight.
func _fire_cannon(player_offset: Vector3) -> void:
	var bandit_right := Vector3(cos(virtual_yaw), 0.0, -sin(virtual_yaw))
	var muzzle: Vector3 = world_offset + bandit_right * float(_engagement_side) * 6.0
	muzzle.y = _current_y + 3.0  # 3m above the visual deck

	# Resolve the player ship's true scene Y so we aim at hull height, not
	# at the ground (world_offset.y == 0 would put the aim point at the dunes).
	var player_ship_y: float = 0.0
	var player := _get_player_ship()
	if player != null:
		player_ship_y = float((player as Node3D).global_position.y)

	# Estimate flight time → ballistic drop compensation. Uses the cannonball
	# scene's gravity literal; if you retune it there, update this constant too.
	const SHELL_GRAVITY: float = 5.0
	var horiz_distance := Vector2(player_offset.x - muzzle.x, player_offset.z - muzzle.z).length()
	var travel_time := horiz_distance / maxf(cannonball_speed, 0.001)
	var drop_compensation: float = 0.5 * SHELL_GRAVITY * travel_time * travel_time

	var aim_target := Vector3(player_offset.x, player_ship_y + 3.0 + drop_compensation, player_offset.z)
	var aim: Vector3 = aim_target - muzzle
	if aim.length_squared() < 0.001:
		return
	# Add per-shot spread so the bandit isn't a laser even with drop compensation.
	var velocity: Vector3 = _apply_spread(aim.normalized(), spread_radians) * cannonball_speed
	var bdir := _get_bandit_director()
	if bdir != null:
		bdir.spawn_cannonball(muzzle, velocity)


## Perturb an aim vector by a random angle inside a cone of `half_angle`
## radians. Same dispersion helper deck_gun.gd uses for the player cannon.
func _apply_spread(direction: Vector3, half_angle: float) -> Vector3:
	if half_angle <= 0.0:
		return direction
	var dir := direction.normalized()
	var helper := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var perp1 := dir.cross(helper).normalized()
	var perp2 := dir.cross(perp1).normalized()
	var azimuth := randf() * TAU
	var polar := randf() * half_angle
	var offset := (perp1 * cos(azimuth) + perp2 * sin(azimuth)) * sin(polar)
	return (dir * cos(polar) + offset).normalized()


## Find the player ship lazily; cached for the lifetime of this AI.
func _get_player_ship() -> Node:
	if _player_ship != null and is_instance_valid(_player_ship):
		return _player_ship
	_player_ship = get_tree().get_first_node_in_group("ship")
	return _player_ship


func _get_bandit_director() -> Node:
	return get_tree().get_first_node_in_group("bandit_director")


## Current sandstorm intensity at the ship (0 clear .. 1 whiteout), or 0 if the
## weather system isn't present. Server-only path, so a plain group lookup is
## fine (no replication needed — intensity is deterministic everywhere).
func _storm_intensity() -> float:
	var weather := get_tree().get_first_node_in_group("weather")
	if weather != null and weather.has_method("get_storm_intensity"):
		return float(weather.get_storm_intensity())
	return 0.0
