extends Interactable
##
## HELM — the ship's wheel. Take it, you drive; release it, the ship coasts.
##
## Mechanically this transfers the multiplayer authority of the Ship node (and
## its MultiplayerSynchronizer specifically) to the helmsman. Their inputs
## then drive virtual_yaw / world_offset for everyone.
##
## The transfer is *non-recursive* so the Helm node itself stays server-owned
## — that's important, because the server uses `_release_helm.rpc()` later and
## needs to remain authority over this node.
##

# peer_id → true. Only peers standing inside the trigger volume can take the
# helm — this prevents anyone from taking it remotely by clicking from afar.
var _bodies_inside: Dictionary = {}


## Register in the helm group so player_controller can find us for "release".
func _ready() -> void:
	add_to_group("helm")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)


## Server-only entry point. Toggle take/release based on who is asking:
##   • If the caller already holds the helm → release.
##   • Otherwise, if no one holds it AND they aren't busy gunning AND they're
##     physically on the helm → take.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if NetworkManager.current_helmsman == peer_id:
		super(peer_id)
		_release_helm.rpc()
	elif NetworkManager.current_helmsman == 0:
		# Can't man two roles at once.
		if NetworkManager.current_gunner == peer_id:
			return
		if not _bodies_inside.has(peer_id):
			return
		super(peer_id)
		_transfer_authority.rpc(peer_id)


## Reassign ship authority and announce the new helmsman. The
## MultiplayerSynchronizer is updated explicitly (its authority is independent
## of its parent's) so it actually broadcasts state *from* the new helmsman
## rather than ignoring their writes.
@rpc("authority", "call_local", "reliable")
func _transfer_authority(peer_id: int) -> void:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship:
		ship.set_multiplayer_authority(peer_id, false)  # non-recursive: keeps Helm server-owned
		var sync := ship.get_node_or_null("MultiplayerSynchronizer")
		if sync:
			sync.set_multiplayer_authority(peer_id)
	if multiplayer.is_server():
		NetworkManager.notify_helmsman_changed.rpc(peer_id)


## Hand authority back to the host and clear the helmsman.
@rpc("authority", "call_local", "reliable")
func _release_helm() -> void:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship:
		ship.set_multiplayer_authority(1, false)
		var sync := ship.get_node_or_null("MultiplayerSynchronizer")
		if sync:
			sync.set_multiplayer_authority(1)
	if multiplayer.is_server():
		NetworkManager.notify_helmsman_changed.rpc(0)


## Track who is standing in the trigger volume (server only — the check that
## actually matters happens in `interact`).
func _on_body_entered(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := _peer_id_from_body(body)
	if peer_id != 0:
		_bodies_inside[peer_id] = true


## If the helmsman steps off the wheel, automatically release the helm — no
## one is going to be happy with a ship that locks them in place while they
## walked away.
func _on_body_exited(body: Node3D) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := _peer_id_from_body(body)
	if peer_id == 0:
		return
	_bodies_inside.erase(peer_id)
	if NetworkManager.current_helmsman == peer_id:
		_release_helm.rpc()


## Player nodes are named after their peer id (see
## NetworkManager.spawn_player_for_peer); translate a body back to that id.
func _peer_id_from_body(body: Node3D) -> int:
	if body == null:
		return 0
	var n := str(body.name)
	if n.is_valid_int():
		return int(n)
	return 0
