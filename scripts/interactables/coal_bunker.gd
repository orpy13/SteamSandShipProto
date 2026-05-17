extends Interactable
##
## COAL BUNKER — pick up one load of coal to carry to the firebox.
##
## Single-use per pickup: the player walks away with coal in their carry slot
## and has to drop it off at the BoilerFirebox before they can grab more.
##

## Configure the prompt at runtime so it stays accurate even if the scene
## inherits the default from the Interactable base class.
func _ready() -> void:
	prompt_text = "Press E to take coal"


## Server-only. Hand a load of coal to the player if their hands are free.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	# Broadcast via player RPC so every peer sees the coal mesh in their socket.
	player.rpc("set_carried_item", "coal")


## Look up the player node for `peer_id`. They live in PlayerContainer on the
## ship, named after their peer id (see NetworkManager.spawn_player_for_peer).
func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
