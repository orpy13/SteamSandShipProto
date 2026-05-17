extends Interactable
##
## GANGWAY — the boarding point. Reparents a player between the ship's
## PlayerContainer (so they move with the ship) and WorldMap (so they stay
## put in the dunes). Toggles direction based on the player's current parent.
##
## Why reparenting? See instructions.md → "The world-scroll trick". The
## ship is stationary at scene origin; the world scrolls underneath it. So
## anything that wants to stay in the dunes (disembarked crew, oases,
## bandits) must be a child of WorldMap. Anything that wants to ride the
## ship (helmsman, gunner, walkers on deck) must be a child of Ship's
## PlayerContainer.
##
## Server validates the swap and broadcasts via RPC so every peer reparents
## simultaneously. The disembark/embark spots are exposed as @exports — move
## them in the editor when you want to relocate the boarding point.
##

@export var disembark_offset: Vector3 = Vector3(-13.0, 0.0, 0.0)  # ship-local; past port hull
@export var embark_local_pos: Vector3 = Vector3(-9.0, 5.0, 0.0)   # ship-local; on deck near port edge
@export var disembark_height_offset: float = 1.0  # metres above terrain on touch-down
@export var max_action_speed: float = 0.5         # ship must be ~stopped (m/s)


func _ready() -> void:
	add_to_group("gangway")
	prompt_text = "Press E to disembark"


## Contextual prompt depends on which side of the swap the player is on, and
## whether the ship is stopped enough to allow it.
func get_prompt(player: Node) -> String:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return prompt_text
	if absf(float(ship.current_speed)) > max_action_speed:
		return "Ship must be stopped"
	return "Press E to disembark" if _is_player_on_ship(player) else "Press E to climb aboard"


## Server-only entry. Validates ship-stopped, finds the calling player node,
## and dispatches to the disembark/embark RPC pair.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return
	if absf(float(ship.current_speed)) > max_action_speed:
		return
	var player := _find_player_node(peer_id)
	if player == null:
		return
	super(peer_id)
	if _is_player_on_ship(player):
		_do_disembark(peer_id, ship)
	else:
		_do_embark(peer_id)


## Compute world drop-off coordinates and broadcast the world-reparent.
##
## Y coordinate comes from sampling the chunk manager's noise field at the
## drop-off position + a small clearance, so the player lands on top of the
## dune surface rather than inside it.
func _do_disembark(peer_id: int, ship: Node) -> void:
	var world_pos: Vector3 = ship.world_offset \
			+ Basis(Vector3.UP, ship.virtual_yaw) * disembark_offset
	var terrain := get_tree().get_first_node_in_group("terrain")
	var y: float = 1.0
	if terrain != null and terrain.has_method("sample_height"):
		y = float(terrain.call("sample_height", world_pos.x, world_pos.z)) + disembark_height_offset
	world_pos.y = y
	_reparent_to_world.rpc(peer_id, world_pos)


## Embark target is fixed in ship-local space — the player pops back onto the
## deck next to the gangway regardless of where they were standing outside.
func _do_embark(peer_id: int) -> void:
	_reparent_to_ship.rpc(peer_id, embark_local_pos)


## All peers: reparent the named player node into WorldMap and set their
## position to the given world coordinates. The host's MultiplayerSynchronizer
## will continue replicating position from the player's authority after this
## point — the explicit set here just snaps the initial pose.
##
## reparent(true) preserves global transform across the swap (no visible pop
## between reparent and the position set on the same frame).
@rpc("authority", "call_local", "reliable")
func _reparent_to_world(peer_id: int, world_pos: Vector3) -> void:
	var player := _find_player_node(peer_id)
	var world_map := get_tree().get_first_node_in_group("terrain")
	if player == null or world_map == null:
		return
	if player.get_parent() != world_map:
		player.reparent(world_map, true)
	if player is Node3D:
		(player as Node3D).position = world_pos
		(player as Node3D).rotation = Vector3.ZERO


## All peers: reparent back into PlayerContainer and snap to the embark spot
## on the deck.
@rpc("authority", "call_local", "reliable")
func _reparent_to_ship(peer_id: int, ship_local_pos: Vector3) -> void:
	var player := _find_player_node(peer_id)
	var ship := get_tree().get_first_node_in_group("ship")
	if player == null or ship == null:
		return
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return
	if player.get_parent() != container:
		player.reparent(container, true)
	if player is Node3D:
		(player as Node3D).position = ship_local_pos
		(player as Node3D).rotation = Vector3.ZERO


## True if the player node is currently a child of the ship's PlayerContainer.
func _is_player_on_ship(player: Node) -> bool:
	if player == null:
		return false
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return false
	var container := ship.get_node_or_null("PlayerContainer")
	return player.get_parent() == container


## Player nodes are named str(peer_id) (see NetworkManager.spawn_player_for_peer).
## After disembark they're children of WorldMap; before, they're in
## PlayerContainer. Check both.
func _find_player_node(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship != null:
		var container := ship.get_node_or_null("PlayerContainer")
		if container != null:
			var p := container.get_node_or_null(str(peer_id))
			if p != null:
				return p
	var world_map := get_tree().get_first_node_in_group("terrain")
	if world_map != null:
		return world_map.get_node_or_null(str(peer_id))
	return null
