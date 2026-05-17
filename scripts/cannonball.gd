extends Node3D
##
## CANNONBALL — a generic shell, used for both bandit broadsides and the
## player's deck gun.
##
## Trajectory is simulated *locally on every peer* from the spawn parameters
## (origin + velocity), not replicated per-frame. Once everyone agrees on
## "spawned at X with velocity V at time T0", they compute the same arc.
##
## Hit detection is server-only and uses a physics shape query, so we identify
## *which* part was struck (hull / bridge / cargo / stair / wheel / rail).
## The `target_group` selects whose hull to look for — "ship" means we hit the
## player; "bandit" means we hit an AI raider.
##

@export var lifetime: float = 12.0          # auto-despawn timeout (seconds) — long enough for high-arc lobs
@export var hit_probe_radius: float = 0.5   # sphere radius for the per-frame collision query
@export var gravity: float = 5.0            # gravity — gives shots a visible arc
@export_flags_3d_physics var hit_layers: int = 1
@export var target_group: String = "ship"   # "ship" or "bandit" — whose hulls we're looking for

var origin: Vector3 = Vector3.ZERO
var velocity: Vector3 = Vector3.ZERO
var world_offset: Vector3 = Vector3.ZERO    # current simulated position

var _elapsed: float = 0.0
var _has_hit: bool = false                  # server-side guard against double-hits


## Stamp spawn parameters and snap into place. Called on every peer right
## after instantiation by the projectile director.
func initialize(spawn_origin: Vector3, spawn_velocity: Vector3, target: String = "ship") -> void:
	origin = spawn_origin
	velocity = spawn_velocity
	target_group = target
	world_offset = spawn_origin
	_apply_visual_pose()


## Integrate ballistic trajectory each frame; on the server, run hit detection.
func _physics_process(delta: float) -> void:
	_elapsed += delta
	# Closed-form: pos = origin + v0*t + ½·g·t² (gravity along -Y).
	world_offset = origin + velocity * _elapsed + Vector3(0.0, -0.5 * gravity * _elapsed * _elapsed, 0.0)
	_apply_visual_pose()

	if _elapsed >= lifetime:
		queue_free()  # local cleanup on timeout — no RPC needed
		return

	if multiplayer.is_server() and not _has_hit:
		_check_for_hit()


## Server-only: shape-query our current scene-space position, classify the
## first ship-part hit, dispatch register_hit on the target, and broadcast
## despawn. Works in scene space because WorldMap's transform places our
## `global_position` exactly on top of target colliders.
##
## We pass our current world-frame position and instantaneous velocity to
## register_hit so the damage model can run its penetration cone math (the
## cone projects forward along our velocity from the impact point).
func _check_for_hit() -> void:
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	var sphere := SphereShape3D.new()
	sphere.radius = hit_probe_radius
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = sphere
	query.transform = Transform3D(Basis(), global_position)
	query.collision_mask = hit_layers
	query.collide_with_areas = false
	query.collide_with_bodies = true

	var hits := space.intersect_shape(query, 8)
	for hit in hits:
		var collider := hit.get("collider") as Node
		if collider == null:
			continue
		var resolved := _resolve_target(collider)
		if resolved.is_empty():
			continue
		_has_hit = true
		var target_node: Node = resolved["node"]
		var part: String = resolved["part"]
		# Compute instantaneous velocity at impact (initial + gravity drop).
		var current_velocity := velocity + Vector3(0.0, -gravity * _elapsed, 0.0)
		if target_node != null and target_node.has_method("register_hit"):
			target_node.register_hit(part, world_offset, current_velocity)
		var bdir := get_tree().get_first_node_in_group("bandit_director")
		if bdir != null:
			bdir.despawn_cannonball(name)
		return


## Classify a collision result. Returns an empty dict if the collider isn't
## part of `target_group`; otherwise `{ "node": <hit ship>, "part": <name> }`.
##
## Strategy: the player Ship's hull/deck colliders return the CharacterBody
## itself (which IS in the target group); bandit parts are StaticBody3D
## children of a Node3D root that's in the group. So we check the collider
## first, then its parent.
func _resolve_target(collider: Node) -> Dictionary:
	var target_node: Node = null
	if collider.is_in_group(target_group):
		target_node = collider
		return {"node": target_node, "part": "hull"}
	var parent := collider.get_parent()
	if parent != null and parent.is_in_group(target_group):
		target_node = parent
		return {"node": target_node, "part": _classify_part_by_name(String(collider.name))}
	return {}


## Name-prefix dispatcher for sub-body part classification. Shared between
## player ship and bandits. The hull wall names map to the five hull
## sub-buckets the damage model tracks separately; the ship's deck and inner
## hull collision shapes return `hull` (their collider is the Ship root,
## handled in the first branch of _resolve_target) which the ship's damage
## model treats as `hull_deck`.
func _classify_part_by_name(n: String) -> String:
	if n.begins_with("Wheel"):
		return "wheel"
	if n.begins_with("Rail"):
		return "rail"
	match n:
		"StbWall":     return "hull_right"
		"PortWall":    return "hull_left"
		"BowWall":     return "hull_fore"
		"AftWall":     return "hull_aft"
		"BridgeHouse": return "bridge"
		"CargoHold":   return "cargo"
		"Stair":       return "stair"
		"HullBody":    return "hull"
		_:             return "unknown"


## Position the mesh inside WorldMap. WorldMap's transform handles the rest.
func _apply_visual_pose() -> void:
	position = world_offset
