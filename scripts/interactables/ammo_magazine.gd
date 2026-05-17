extends Interactable
##
## AMMO MAGAZINE — pick up a 5-shell clip to carry to the deck gun.
##
## Mirrors the CoalBunker pattern. Server-only validation, broadcasts the
## new carry-item state via the player's RPC. Each clip is one full reload
## (deck_gun.max_ammo shells); the player can only carry one clip at a time.
##

func _ready() -> void:
	prompt_text = "Press E to take ammo clip"


## Server-only. Hand a clip to the player if their hands are free.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	# RPC so every peer sees the clip mesh in the player's carry socket.
	player.rpc("set_carried_item", "clip")


## Resolve the player node for peer_id — they live in PlayerContainer named
## after their peer id (see NetworkManager.spawn_player_for_peer).
func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
