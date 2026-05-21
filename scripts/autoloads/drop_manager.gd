extends Node
##
## DROP MANAGER (autoload) — central spawner for in-world prop items.
##
## Two entry points:
##   • `request_drop` (any peer → host): a player asks to drop whatever they
##     are carrying. Host validates the sender's carry slot, clears it,
##     and broadcasts a spawn.
##   • `host_spawn_world_item` (host-only direct call): the oasis market
##     uses this to spawn freshly-bought crates without a player request.
##
## Spawns the prop scene mapped by `Goods.prop_scene_for_carry(carry_id)`
## directly — the prop scene's own RigidBody3D simulates physics. Host runs
## the simulation; clients freeze their copy as kinematic and receive the
## host's transform via the `MultiplayerSynchronizer` baked into each prop
## scene. Pickup happens through the `world_item.gd` script on each prop's
## `InteractArea` child — see that file for the carry-slot grant + despawn.
##

## Per-session unique id for spawned items. Names are "Dropped_%d" so each
## peer's tree gets the same node names for the same spawn (mirror of the
## bandit_director cannonball-id scheme).
var _next_id: int = 0


## Any-peer entry point. Client RPCs in: "I'm holding `carry_id`, parent
## node `parent_path`, drop at local pos `drop_local` with yaw `yaw`".
## Host validates, clears the carry slot, and broadcasts the spawn.
@rpc("any_peer", "call_local", "reliable")
func request_drop(carry_id: String, parent_path: NodePath, drop_local: Vector3, yaw: float) -> void:
	if not multiplayer.is_server():
		return
	if carry_id.is_empty():
		return
	var prop_path := Goods.prop_scene_for_carry(carry_id)
	if prop_path.is_empty():
		return                                                # not droppable
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var player := _find_player(sender)
	if player == null:
		return
	# Sender must actually be holding what they claim — anti-desync /
	# anti-cheat. The carry slot is replicated via player.set_carried_item.
	if String(player.get("carried_item_type")) != carry_id:
		return
	# Clear carry slot, then spawn the world item.
	player.rpc("set_carried_item", "")
	host_spawn_world_item(carry_id, parent_path, drop_local, yaw)


## Host-only direct spawn — same path the oasis market takes when a buy
## drops a crate next to the stall. Returns the new node on the host so
## the caller can poke at it (e.g. set a starting velocity).
func host_spawn_world_item(carry_id: String, parent_path: NodePath, pos: Vector3, yaw: float) -> Node:
	if not multiplayer.is_server():
		return null
	var item_name := "Item_%d" % _next_id
	_next_id += 1
	_spawn_world_item.rpc(item_name, carry_id, parent_path, pos, yaw)
	# Local copy already spawned via call_local; grab it for the caller.
	var parent := get_node_or_null(parent_path)
	if parent == null:
		return null
	return parent.get_node_or_null(item_name)


## Broadcast spawn. Each peer instantiates the prop scene at the same
## position with the same name. Host unfreezes its copy to run physics;
## clients keep theirs kinematic-frozen so the MultiplayerSynchronizer
## inside the prop scene can drive transforms cleanly without local
## physics fighting the replicated values.
@rpc("authority", "call_local", "reliable")
func _spawn_world_item(item_name: String, carry_id: String, parent_path: NodePath, pos: Vector3, yaw: float) -> void:
	var parent := get_node_or_null(parent_path)
	if parent == null:
		return
	if parent.has_node(item_name):
		return                                                 # already spawned
	var prop_path := Goods.prop_scene_for_carry(carry_id)
	if prop_path.is_empty() or not ResourceLoader.exists(prop_path):
		return
	var scene: Resource = load(prop_path)
	if not (scene is PackedScene):
		return
	var item: Node = (scene as PackedScene).instantiate()
	item.name = item_name
	if item is RigidBody3D:
		var rb := item as RigidBody3D
		# Host simulates; clients are kinematic puppets driven by the
		# synchronizer. Setting authority to 1 keeps the host as the
		# physics owner across helm transfers.
		rb.set_multiplayer_authority(1)
		if multiplayer.is_server():
			rb.freeze = false
			rb.collision_layer = 1
			rb.collision_mask = 1
		else:
			rb.freeze = true
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
			rb.collision_layer = 0     # don't fight player movement client-side
			rb.collision_mask = 0
	# Hand the carry_id to the InteractArea so pickup grants the right slot
	# and the Label3D shows the right contents.
	var area := item.get_node_or_null("InteractArea")
	if area != null:
		area.set("carry_id", carry_id)
		if area.has_method("_refresh_label"):
			area.call("_refresh_label")
	if item is Node3D:
		(item as Node3D).position = pos
		(item as Node3D).rotation.y = yaw
	parent.add_child(item)


## Resolve a player by peer id (PlayerContainer or WorldMap — see
## NetworkManager / world_item for the same pattern).
func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship != null:
		var container := ship.get_node_or_null("PlayerContainer")
		if container != null and container.has_node(str(peer_id)):
			return container.get_node(str(peer_id))
	var wm := get_tree().get_first_node_in_group("terrain")
	if wm != null and wm.has_node(str(peer_id)):
		return wm.get_node(str(peer_id))
	return null
