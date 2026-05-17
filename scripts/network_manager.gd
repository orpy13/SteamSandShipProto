extends Node
##
## NETWORK MANAGER (autoload).
##
## ENet host/client wrapper. Tracks the crew roster, replicates it to all
## peers, spawns player nodes on join, and reassigns ship authority when the
## helmsman changes or disconnects.
##
## Glossary:
##   crew member = a peer registered in `players`
##   helmsman    = the peer currently driving the ship (multiplayer authority of Ship)
##

signal server_started
signal connection_succeeded
signal connection_failed(reason: String)
signal player_list_changed(players: Dictionary)
signal helmsman_changed(peer_id: int)
signal gunner_changed(peer_id: int)

const DEFAULT_PORT: int = 7777
const MAX_PLAYERS: int = 4

# peer_id → { "name": String }. Host's own entry is added immediately on host_game().
var players: Dictionary = {}
# 0 = no one in the role; otherwise the peer_id currently filling it.
var current_helmsman: int = 0
var current_gunner: int = 0
# The local crew name we'll register with once handshake completes.
var _pending_local_name: String = "Crew"


## Start an ENet server on `port` and register self as peer 1.
func host_game(player_name: String, port: int = DEFAULT_PORT) -> void:
	_pending_local_name = player_name
	GameState.local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		connection_failed.emit("Failed to host: " + str(err))
		return
	multiplayer.multiplayer_peer = peer
	# Guard each connect: host_game might be called again after a previous session.
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	players.clear()
	players[1] = {"name": player_name}
	current_helmsman = 0
	current_gunner = 0
	# Stamp the shared world clock + weather seed at session start. Every peer
	# derives day/night and storms deterministically from these (no per-frame
	# sync); joining clients receive them in _on_peer_connected.
	GameState.world_epoch = Time.get_unix_time_from_system()
	GameState.weather_seed = randi()
	server_started.emit()
	player_list_changed.emit(players)
	helmsman_changed.emit(0)
	gunner_changed.emit(0)
	# Spawn host's own player on every peer (just us, initially).
	spawn_player_for_peer.rpc(1)


## Dial a host at ip:port. On a successful TCP handshake we'll RPC our name to
## the server, which inserts us into the roster and spawns our player node.
func join_game(player_name: String, ip: String, port: int = DEFAULT_PORT) -> void:
	_pending_local_name = player_name
	GameState.local_player_name = player_name
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		connection_failed.emit("Failed to connect: " + str(err))
		return
	multiplayer.multiplayer_peer = peer
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)


## Tear down any active connection and clear cached roster.
func disconnect_game() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	players.clear()
	player_list_changed.emit(players)


## Server hook: a peer just finished the transport handshake. Replay the
## current world state to them so their HUD matches and every existing crew
## member's player node spawns on their machine.
func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		update_player_list.rpc_id(peer_id, players)
		notify_world_clock.rpc_id(peer_id, GameState.world_epoch, GameState.weather_seed)
		notify_helmsman_changed.rpc_id(peer_id, current_helmsman)
		notify_gunner_changed.rpc_id(peer_id, current_gunner)
		for existing_id in players.keys():
			spawn_player_for_peer.rpc_id(peer_id, existing_id)


## Client hook: TCP handshake to the server is up — register our name.
func _on_connected_to_server() -> void:
	connection_succeeded.emit()
	register_player.rpc_id(1, _pending_local_name)


## Client hook: the host refused us or the address was bad.
func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	connection_failed.emit("Connection failed")


## Client hook: we were connected but the host went away (crash, kicked, etc.).
func _on_server_disconnected() -> void:
	disconnect_game()
	connection_failed.emit("Server disconnected")


## Server-side cleanup when a peer drops. Release any roles they were filling
## (helm or gun) so the remaining crew can pick them up.
func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		players.erase(peer_id)
		update_player_list.rpc(players)
		_remove_player_node.rpc(peer_id)
		if current_helmsman == peer_id:
			current_helmsman = 0
			var ship := get_tree().get_first_node_in_group("ship")
			if ship:
				ship.set_multiplayer_authority(1)
			notify_helmsman_changed.rpc(0)
		if current_gunner == peer_id:
			current_gunner = 0
			notify_gunner_changed.rpc(0)


## Server-only entry point for a freshly-connected client to announce themselves.
## We mark `any_peer` because the caller is, by definition, not the server yet.
@rpc("any_peer", "reliable")
func register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	players[sender_id] = {"name": player_name}
	update_player_list.rpc(players)
	spawn_player_for_peer.rpc(sender_id)


## Replace each peer's local crew dictionary and notify any UI listening in.
@rpc("authority", "call_local", "reliable")
func update_player_list(updated: Dictionary) -> void:
	players = updated.duplicate(true)
	player_list_changed.emit(players)


## Instantiate `player.tscn` for `peer_id` on every peer, parent it to the
## ship's PlayerContainer, set its multiplayer authority, and visually tint it.
## Idempotent — if a player node already exists for this peer we skip.
@rpc("authority", "call_local", "reliable")
func spawn_player_for_peer(peer_id: int) -> void:
	var container := _get_player_container()
	if container == null:
		return
	if container.has_node(str(peer_id)):
		return
	var scene: PackedScene = load("res://scenes/player/player.tscn")
	if scene == null:
		return
	var p: Node = scene.instantiate()
	# Naming convention: the node name *is* the peer id. The nametag and
	# interact systems both rely on this to map nodes back to peers.
	p.name = str(peer_id)
	p.set_multiplayer_authority(peer_id)
	container.add_child(p, true)
	var ship := get_tree().get_first_node_in_group("ship")
	if ship and ship.has_node("SpawnPoint"):
		var marker: Node3D = ship.get_node("SpawnPoint")
		if p is Node3D:
			(p as Node3D).global_transform = marker.global_transform
	if p.has_method("apply_peer_visuals"):
		p.apply_peer_visuals(peer_id)


## Host → client: hand over the shared world clock so the joining peer's
## day/night cycle and storm schedule line up with everyone else's. Sent once
## during the connection handshake; thereafter each peer computes locally.
@rpc("authority", "reliable")
func notify_world_clock(epoch: float, seed_value: int) -> void:
	GameState.world_epoch = epoch
	GameState.weather_seed = seed_value


## Broadcast: a new peer has the helm. Every peer updates its local cache so
## HUD labels and player-controller helm-locked state stay in sync.
@rpc("authority", "call_local", "reliable")
func notify_helmsman_changed(peer_id: int) -> void:
	current_helmsman = peer_id
	helmsman_changed.emit(peer_id)


## Broadcast: a new peer is manning the deck gun (or 0 = nobody).
@rpc("authority", "call_local", "reliable")
func notify_gunner_changed(peer_id: int) -> void:
	current_gunner = peer_id
	gunner_changed.emit(peer_id)


## Remove a disconnected peer's player node on every machine. Disembarked
## players live under WorldMap (not PlayerContainer), so we check both.
@rpc("authority", "call_local", "reliable")
func _remove_player_node(peer_id: int) -> void:
	var container := _get_player_container()
	if container and container.has_node(str(peer_id)):
		container.get_node(str(peer_id)).queue_free()
		return
	# Fall-through: might be off-ship in WorldMap.
	var world_map := get_tree().get_first_node_in_group("terrain")
	if world_map and world_map.has_node(str(peer_id)):
		world_map.get_node(str(peer_id)).queue_free()


## Locate the PlayerContainer node — child of the Ship, holds all player bodies.
func _get_player_container() -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	return ship.get_node_or_null("PlayerContainer")
