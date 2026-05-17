extends CharacterBody3D
##
## SHIP CONTROLLER — the heart of the sand ship.
##
## The ship's actual scene-graph position is (0, terrain_height, 0). It never
## moves in world space horizontally. Two pieces of state stand in for its
## "real" pose:
##
##   virtual_yaw   — heading in radians (positive = right-turn).
##   world_offset  — Vector3 position out in the dune-field.
##
## The ChunkManager applies the *inverse* of both to the WorldMap each frame,
## so the world slides and rotates underneath a stationary ship. Players walking
## on the deck don't need any vehicle-velocity compensation; ship-local space
## *is* world space for them, and `move_and_slide()` just works.
##
## Authority: starts on the host (peer 1) and transfers to whichever peer takes
## the helm. The MultiplayerSynchronizer in ship.tscn replicates the four
## variables flagged below to all other peers — non-authority peers fall
## through to terrain-following only.
##

signal speed_changed(speed: float)
signal damage_taken(hit_count: int, part: String)
signal money_changed(new_value: int)
signal cargo_changed(good_id: String, new_quantity: int)

# ── Drive tuning ──────────────────────────────────────────────────────────────
@export var max_forward_speed: float = 12.0
@export var max_reverse_speed: float = 4.0
@export var acceleration: float = 3.0           # m/s² when steam is available
@export var deceleration_drag: float = 1.5      # coasting drag (no input, no brake)
@export var brake_drag: float = 6.0             # extra drag when braking
@export var turn_speed: float = 0.6             # max yaw rate (rad/s)
@export var turn_speed_penalty: float = 0.04    # turn rate falls off at high speed
@export var turn_acceleration: float = 1.8      # how fast we ramp into a turn
@export var turn_deceleration: float = 3.0      # how fast we ramp out of a turn

# ── Visual tilt (body roll on turns) ──────────────────────────────────────────
@export var tilt_amount: float = 0.02
@export var tilt_lerp: float = 4.0

# ── Terrain following ────────────────────────────────────────────────────────
# Local-space contact points used to estimate pitch/roll over the dunes. These
# correspond to roughly the four corners of the hull footprint.
@export var terrain_clearance: float = 0.0
@export var terrain_height_lerp: float = 6.0
@export var terrain_tilt_lerp: float = 5.0
@export var terrain_pitch_amount: float = 1.0
@export var terrain_roll_amount: float = 1.0
@export var terrain_contact_front: float = 22.35
@export var terrain_contact_back: float = -17.15
@export var terrain_contact_side: float = 12.25
@export var terrain_contact_local_y: float = -2.0

# Only solid bodies on this mask block forward motion (terrain chunks excluded).
@export_flags_3d_physics var obstacle_collision_mask: int = 1


# ── Authoritative state (replicated via MultiplayerSynchronizer) ──────────────
var virtual_yaw: float = 0.0      # heading
var world_offset: Vector3 = Vector3.ZERO  # position out in the dunes
var current_speed: float = 0.0    # signed scalar along forward axis
var engine_order: int = 0         # telegraph: -2 … +4 (see _get_engine_order_speed)

# ── Damage state ─────────────────────────────────────────────────────────────
# `hit_count` and `last_hit_part` are kept for the screen-shake hookup in
# player_controller; the *real* damage state is `system_integrity` below.
var hit_count: int = 0
var last_hit_part: String = ""

# Per-system integrity, server-authoritative. 5 hull sub-buckets (one per
# face) + 4 internal systems. Repair adds; hits and penetration subtract.
# Dictionary is replicated via RPC pulses (not the synchronizer — Godot 4's
# synchronizer doesn't broadcast individual dict entry changes nicely).
signal system_changed(system: String, integrity: float)

# ── Economy state (server-authoritative, RPC-broadcast on change) ───────────
@export var starting_money: int = 100
@export var cargo_capacity: int = 20  # total crates the hold can store

var money: int = 100
var cargo: Dictionary = {
	"coal":  0,
	"water": 0,
	"spice": 0,
}

var system_integrity: Dictionary = {
	"hull_left":  1.0,
	"hull_right": 1.0,
	"hull_fore":  1.0,
	"hull_aft":   1.0,
	"hull_deck":  1.0,
	"mobility":   1.0,
	"power":      1.0,
	"control":    1.0,
	"cargo":      1.0,
}

# ── Damage tuning ────────────────────────────────────────────────────────────
@export var direct_hit_damage: float = 0.15         # integrity lost per direct hit on a part
@export var penetration_damage: float = 0.10        # integrity lost per successful penetration roll
@export var penetration_half_angle: float = deg_to_rad(25.0)
@export var penetration_cone_length: float = 10.0   # m — how deep the cone reaches
@export var penetration_base_max: float = 0.8       # max chance scalar at 0% wall HP
@export var min_mobility_factor: float = 0.3        # mobility at 0% integrity still allows 30% speed
@export var min_control_factor: float = 0.2         # control at 0% integrity is sluggish but not dead

# Fallback ship-local centroids used only when the corresponding scene node
# can't be found (e.g. someone renamed it). The live values come from
# `_get_system_positions()` below, which reads the actual node transforms so
# moving / replacing the bridge house, cargo hold, etc. updates the damage
# cone automatically.
const _SYSTEM_POSITION_FALLBACKS: Dictionary = {
	"mobility": Vector3(0.0, 0.0, 0.0),
	"power":    Vector3(0.0, 0.5, -17.0),
	"control":  Vector3(0.0, 7.0, -22.0),
	"cargo":    Vector3(0.0, 5.5, 4.0),
}

# ── Local state (computed each frame on every peer) ──────────────────────────
var current_turn_rate: float = 0.0
var current_tilt: float = 0.0     # body-roll from turning
var current_pitch: float = 0.0    # smoothed pitch from terrain
var current_roll: float = 0.0     # smoothed roll from terrain
var _terrain: Node = null         # cached ChunkManager reference

@onready var _steam_plant: Node = get_node_or_null("SteamPlant")


## Register in the "ship" group so other systems can locate us.
func _ready() -> void:
	add_to_group("ship")
	position = Vector3.ZERO
	money = starting_money


## Authority drives input and updates virtual_yaw/world_offset; all peers run
## the terrain-following pass so the ship visually pitches/rolls over dunes.
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		_apply_terrain_following(delta)
		speed_changed.emit(current_speed)
		return

	var turn_input: float = 0.0
	var braking: bool = false
	# Only the helmsman's local input counts. (Authority can be transferred
	# without anyone manning the helm — e.g. host on startup — in which case
	# the ship coasts.)
	if NetworkManager.current_helmsman != 0 \
			and NetworkManager.current_helmsman == multiplayer.get_unique_id():
		if Input.is_action_just_pressed("move_forward"):
			engine_order = mini(engine_order + 1, 4)
		if Input.is_action_just_pressed("move_back"):
			engine_order = maxi(engine_order - 1, -2)
		turn_input = Input.get_action_strength("move_right") \
				- Input.get_action_strength("move_left")
		braking = Input.is_action_pressed("brake")

	# Compute effective max speeds and turn rate from system integrity once per
	# frame. Damaged mobility caps the ship's top speed; damaged control bleeds
	# turning responsiveness. lerpf keeps each system from going fully to 0 —
	# even a wrecked ship limps along rather than locking in place.
	var mobility_factor := lerpf(min_mobility_factor, 1.0, float(system_integrity.get("mobility", 1.0)))
	var control_factor := lerpf(min_control_factor, 1.0, float(system_integrity.get("control", 1.0)))
	var eff_max_forward := max_forward_speed * mobility_factor
	var eff_max_reverse := max_reverse_speed * mobility_factor
	var eff_turn_speed := turn_speed * mobility_factor * control_factor

	var target_speed := _get_engine_order_speed(eff_max_forward, eff_max_reverse)
	var power_ratio := _get_steam_power_ratio(delta)
	if not is_zero_approx(target_speed):
		# Accelerate only as fast as the boiler will let us; if the boiler is
		# starved (no pressure / no water / no coal) we coast.
		if power_ratio > 0.02:
			current_speed = move_toward(current_speed, target_speed, acceleration * power_ratio * delta)
		else:
			current_speed = move_toward(current_speed, 0.0, deceleration_drag * delta)
	else:
		var drag: float = brake_drag if braking else deceleration_drag
		current_speed = move_toward(current_speed, 0.0, drag * delta)
	current_speed = clampf(current_speed, -eff_max_reverse, eff_max_forward)

	_update_turning(turn_input, delta, eff_max_forward, eff_max_reverse, eff_turn_speed)

	# Body-roll tilts the ship into its turns — purely visual.
	var turn_ratio := current_turn_rate / maxf(turn_speed, 0.001)
	var target_tilt: float = clampf(turn_ratio, -1.0, 1.0) * tilt_amount
	current_tilt = lerpf(current_tilt, target_tilt, clampf(tilt_lerp * delta, 0.0, 1.0))

	# Advance the virtual position by the heading vector × speed.
	var forward := Vector3(sin(virtual_yaw), 0.0, cos(virtual_yaw))
	_move_virtual_offset(forward * current_speed * delta)

	_apply_terrain_following(delta)
	speed_changed.emit(current_speed)


## Move the ship's *virtual* position, but cancel the move if the hull would
## intersect a non-terrain solid (rocks, posts, props). Terrain chunks are
## handled by the pitch/roll system, not by collision.
func _move_virtual_offset(motion: Vector3) -> void:
	if motion.length_squared() < 0.000001:
		return
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = $HullCollision.shape
	query.transform = $HullCollision.global_transform.translated(motion)
	query.collision_mask = obstacle_collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hits := get_world_3d().direct_space_state.intersect_shape(query, 16)
	if _has_blocking_hit(hits):
		# Hard stop on obstacle contact. (No bounce, no slide — keeps it simple
		# for a prototype and reads as "the ship rams something solid".)
		current_speed = 0.0
		current_turn_rate = 0.0
		return
	world_offset += motion


## Filter shape-query results: ignore self and ignore terrain chunks.
func _has_blocking_hit(hits: Array) -> bool:
	for hit in hits:
		var collider := hit.get("collider") as Node
		if collider == null:
			continue
		if collider.is_in_group("terrain_chunk"):
			continue
		if collider == self or is_ancestor_of(collider):
			continue
		return true
	return false


## Ask the boiler how much of the demanded power it can actually deliver
## (0.0 = no pressure, 1.0 = at working pressure or above).
func _get_steam_power_ratio(delta: float) -> float:
	if engine_order == 0:
		return 0.0
	if _steam_plant == null or not is_instance_valid(_steam_plant):
		_steam_plant = get_node_or_null("SteamPlant")
	if _steam_plant == null or not _steam_plant.has_method("request_power"):
		return 0.0
	return float(_steam_plant.call("request_power", engine_order, delta))


## Map the engine-order telegraph (–2 … +4) to a target speed, using effective
## max speeds (post-damage). Caller computes the effective values once per
## tick from system_integrity.
func _get_engine_order_speed(eff_max_forward: float, eff_max_reverse: float) -> float:
	match engine_order:
		-2: return -eff_max_reverse
		-1: return -eff_max_reverse * 0.5
		1:  return eff_max_forward * 0.25
		2:  return eff_max_forward * 0.5
		3:  return eff_max_forward * 0.75
		4:  return eff_max_forward
		_:  return 0.0


## Lerp the current turn rate toward the target and integrate into virtual_yaw.
## At zero speed we can't turn at all (no traction); the faster we go the less
## responsive the wheel. Effective max speeds and turn rate come from the
## caller, already reduced by system integrity.
func _update_turning(turn_input: float, delta: float, eff_max_forward: float, eff_max_reverse: float, eff_turn_speed: float) -> void:
	var max_speed_for_direction := eff_max_forward if current_speed >= 0.0 else eff_max_reverse
	var speed_ratio := clampf(absf(current_speed) / maxf(max_speed_for_direction, 0.001), 0.0, 1.0)
	if is_zero_approx(speed_ratio):
		current_turn_rate = 0.0
		return
	var capped_turn_speed := maxf(0.0, eff_turn_speed - absf(current_speed) * turn_speed_penalty)
	# When reversing, steering inverts — same convention as a real wheeled vehicle.
	var velocity_direction := 1.0 if current_speed > 0.0 else -1.0
	var target_turn_rate := -turn_input * capped_turn_speed * speed_ratio * velocity_direction
	var turn_lerp_speed := turn_acceleration if absf(target_turn_rate) > absf(current_turn_rate) \
			else turn_deceleration
	current_turn_rate = move_toward(current_turn_rate, target_turn_rate, turn_lerp_speed * delta)
	virtual_yaw += current_turn_rate * delta


## Pose the ship to match the dunes underneath it. Samples four contact points
## (front, back, left, right) on the height field, then derives pitch and roll
## from the height differences. The ship's X/Z stay at 0 — only Y and the two
## rotational axes change.
func _apply_terrain_following(delta: float) -> void:
	if _terrain == null or not is_instance_valid(_terrain):
		_terrain = get_tree().get_first_node_in_group("terrain")
		if _terrain == null:
			_terrain = get_node_or_null("../WorldMap")

	var target_height: float = terrain_clearance
	var target_pitch: float = 0.0
	var target_roll: float = current_tilt
	if _terrain != null and _terrain.has_method("sample_height"):
		var front_height: float = _sample_terrain_height(Vector3(0.0, 0.0, terrain_contact_front))
		var back_height: float = _sample_terrain_height(Vector3(0.0, 0.0, terrain_contact_back))
		var right_height: float = _sample_terrain_height(Vector3(terrain_contact_side, 0.0, 0.0))
		var left_height: float = _sample_terrain_height(Vector3(-terrain_contact_side, 0.0, 0.0))
		var wheel_base := terrain_contact_front - terrain_contact_back
		var track_width := terrain_contact_side * 2.0
		# Sit on the highest contact point so we never clip into a dune crest.
		var contact_height := maxf(maxf(front_height, back_height), maxf(left_height, right_height))
		target_height = contact_height - terrain_contact_local_y + terrain_clearance
		target_pitch = atan2(back_height - front_height, wheel_base) * terrain_pitch_amount
		target_roll = current_tilt + atan2(right_height - left_height, track_width) * terrain_roll_amount

	var height_weight := clampf(terrain_height_lerp * delta, 0.0, 1.0)
	var tilt_weight := clampf(terrain_tilt_lerp * delta, 0.0, 1.0)
	current_pitch = lerpf(current_pitch, target_pitch, tilt_weight)
	current_roll = lerpf(current_roll, target_roll, tilt_weight)
	# Ship stays at the X/Z origin with no yaw; the terrain rotates and scrolls instead.
	position = Vector3(0.0, lerpf(position.y, target_height, height_weight), 0.0)
	rotation = Vector3(current_pitch, 0.0, current_roll)


## Translate a ship-local contact offset into the (virtual) world position used
## by the noise sampler — accounts for the current heading.
func _sample_terrain_height(local_offset: Vector3) -> float:
	var sample_pos := world_offset + Basis(Vector3.UP, virtual_yaw) * local_offset
	return float(_terrain.call("sample_height", sample_pos.x, sample_pos.z))


## Called by projectiles on hit. `part` is the classified collider name (e.g.
## "hull_left", "wheel", "bridge"). `impact_world` and `velocity_world` come
## from the shell at the moment of impact and feed the penetration cone math.
##
## Server-only entry. Broadcasts:
##   • _apply_hit — screen-shake / hit-count pulse (existing path)
##   • _apply_damage — integrity change per system
## ...so every peer's HUD and feel stay in sync.
func register_hit(part: String, impact_world: Vector3 = Vector3.ZERO, velocity_world: Vector3 = Vector3.ZERO) -> void:
	if not multiplayer.is_server():
		return
	_apply_hit.rpc(part)

	# Map the classified part to the primary integrity bucket it damages.
	var primary := _part_to_primary_system(part)
	if primary.is_empty():
		return
	_apply_damage.rpc(primary, direct_hit_damage)

	# Penetration only triggers from hull face hits. The chance to penetrate
	# rises as the wall's integrity falls — fresh walls are nearly impervious,
	# perforated walls let almost everything through.
	if primary.begins_with("hull_"):
		var impact_local := _world_to_ship_local_point(impact_world)
		var velocity_local := _world_to_ship_local_direction(velocity_world)
		var wall_hp := float(system_integrity.get(primary, 1.0))
		_run_penetration(impact_local, velocity_local, wall_hp)


## Mapping from classified part name to which integrity bucket takes the hit.
## Hull walls map 1:1; internal-system colliders (wheel/bridge/cargo) map to
## their respective system. Anything else returns "" and is ignored.
func _part_to_primary_system(part: String) -> String:
	match part:
		"hull_left", "hull_right", "hull_fore", "hull_aft":
			return part
		"hull":        return "hull_deck"   # Ship-root hit = deck-area collision
		"wheel":       return "mobility"
		"bridge":      return "control"
		"cargo":       return "cargo"
		"stair":       return "hull_deck"
		_:             return ""


## Roll the penetration cone against each internal system. Cone origin is the
## impact point, axis is the shell's velocity (forward into the ship); systems
## within the cone get an independent chance to take damage. Multiple systems
## can be damaged per shell — by design, see damage discussion turn.
func _run_penetration(impact_local: Vector3, velocity_local: Vector3, wall_hp: float) -> void:
	if velocity_local.length_squared() < 0.0001:
		return
	var base_chance := (1.0 - wall_hp) * penetration_base_max
	if base_chance <= 0.0:
		return  # pristine wall — no penetration
	var dir := velocity_local.normalized()
	var cos_half := cos(penetration_half_angle)
	var positions := _get_system_positions()
	for sys_name in positions.keys():
		var sys_pos: Vector3 = positions[sys_name]
		var vec: Vector3 = sys_pos - impact_local
		var dist := vec.length()
		if dist > penetration_cone_length or dist < 0.001:
			continue
		var cos_angle := vec.normalized().dot(dir)
		if cos_angle < cos_half:
			continue  # outside the cone
		# `angle_factor` is 1.0 along the axis, 0.0 at the cone edge.
		# `distance_factor` is 1.0 at the impact, 0.0 at the cone tip.
		var angle_factor := (cos_angle - cos_half) / (1.0 - cos_half)
		var distance_factor := 1.0 - (dist / penetration_cone_length)
		var chance := base_chance * angle_factor * distance_factor
		if randf() < chance:
			_apply_damage.rpc(sys_name, penetration_damage)


## Look up each internal-system centroid from the actual scene nodes so the
## damage cone tracks them when art is replaced or nodes are repositioned.
## Conventions:
##   • mobility → average position of every Wheel* child
##   • power    → BoilerFirebox.position (SteamPlant itself is a non-spatial Node)
##   • control  → BridgeHouse.position
##   • cargo    → CargoHold.position
## Missing nodes fall back to the const values above so the model still works
## on partial scenes.
func _get_system_positions() -> Dictionary:
	var positions: Dictionary = {}

	var wheel_sum := Vector3.ZERO
	var wheel_count := 0
	for child in get_children():
		if child is Node3D and String(child.name).begins_with("Wheel"):
			wheel_sum += (child as Node3D).position
			wheel_count += 1
	positions["mobility"] = (wheel_sum / float(wheel_count)) if wheel_count > 0 \
			else _SYSTEM_POSITION_FALLBACKS["mobility"]

	var firebox := get_node_or_null("BoilerFirebox") as Node3D
	positions["power"] = firebox.position if firebox != null \
			else _SYSTEM_POSITION_FALLBACKS["power"]

	var bridge := get_node_or_null("BridgeHouse") as Node3D
	positions["control"] = bridge.position if bridge != null \
			else _SYSTEM_POSITION_FALLBACKS["control"]

	var cargo := get_node_or_null("CargoHold") as Node3D
	positions["cargo"] = cargo.position if cargo != null \
			else _SYSTEM_POSITION_FALLBACKS["cargo"]

	return positions


## All peers: bump the counter, record the struck part, and emit the signal
## that drives screen shake and (eventually) damage UI.
##
## Mode is `any_peer` (not `authority`) because the ship's multiplayer
## authority transfers to whichever peer holds the helm — but hit detection
## runs on the *host*, which may not currently be that authority. We restrict
## who can fire this RPC by validating the sender below.
@rpc("any_peer", "call_local", "reliable")
func _apply_hit(part: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	hit_count += 1
	last_hit_part = part
	damage_taken.emit(hit_count, part)


## Apply an integrity delta to a single system on every peer, then emit
## system_changed. Same sender-validation pattern as _apply_hit since the gun's
## authority is the helmsman but hits originate from the host.
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


## Repair a system by `amount`. Called by the workshop's interact() on the
## server when a player consumes a repair kit on the ship.
func repair_system(system: String, amount: float) -> void:
	if not multiplayer.is_server():
		return
	if not system_integrity.has(system):
		return
	_apply_repair.rpc(system, amount)


@rpc("any_peer", "call_local", "reliable")
func _apply_repair(system: String, amount: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	if not system_integrity.has(system):
		return
	var new_value := clampf(float(system_integrity[system]) + amount, 0.0, 1.0)
	system_integrity[system] = new_value
	system_changed.emit(system, new_value)


# ── Coordinate helpers ───────────────────────────────────────────────────────

## Convert a world-frame point into ship-local space (for penetration math).
## Ship-local = world translated by -world_offset and rotated by -virtual_yaw.
func _world_to_ship_local_point(world_pos: Vector3) -> Vector3:
	var delta := world_pos - world_offset
	return Basis(Vector3.UP, -virtual_yaw) * delta


## Same as above but for direction vectors (no translation).
func _world_to_ship_local_direction(world_dir: Vector3) -> Vector3:
	return Basis(Vector3.UP, -virtual_yaw) * world_dir


# ── Economy API ──────────────────────────────────────────────────────────────
# All money/cargo mutations flow through these methods on the host. They
# broadcast via the _set_money / _set_cargo RPCs which run on every peer
# (same sender-validation pattern as _apply_hit/_apply_damage).

## Total crates currently in the hold (sum over all goods).
func get_cargo_total() -> int:
	var sum := 0
	for k in cargo.keys():
		sum += int(cargo[k])
	return sum


## Try to spend `amount`. Returns true if successful; false if insufficient
## funds (no money is deducted).
func try_spend(amount: int) -> bool:
	if not multiplayer.is_server():
		return false
	if amount <= 0:
		return true
	if money < amount:
		return false
	_set_money.rpc(money - amount)
	return true


## Credit money to the ship's bank. Used for sale proceeds and (future)
## bounties / salvage.
func receive_money(amount: int) -> void:
	if not multiplayer.is_server():
		return
	if amount <= 0:
		return
	_set_money.rpc(money + amount)


@rpc("any_peer", "call_local", "reliable")
func _set_money(new_value: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	money = new_value
	money_changed.emit(money)


## Add cargo to the hold. Returns false if capacity would be exceeded; no
## change is made on failure.
func add_cargo(good_id: String, qty: int) -> bool:
	if not multiplayer.is_server():
		return false
	if not cargo.has(good_id) or qty <= 0:
		return false
	if get_cargo_total() + qty > cargo_capacity:
		return false
	_set_cargo.rpc(good_id, int(cargo[good_id]) + qty)
	return true


## Remove cargo from the hold. Returns false if we don't have enough.
func remove_cargo(good_id: String, qty: int) -> bool:
	if not multiplayer.is_server():
		return false
	if not cargo.has(good_id) or qty <= 0:
		return false
	if int(cargo[good_id]) < qty:
		return false
	_set_cargo.rpc(good_id, int(cargo[good_id]) - qty)
	return true


@rpc("any_peer", "call_local", "reliable")
func _set_cargo(good_id: String, new_qty: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	if not cargo.has(good_id):
		return
	cargo[good_id] = new_qty
	cargo_changed.emit(good_id, new_qty)
