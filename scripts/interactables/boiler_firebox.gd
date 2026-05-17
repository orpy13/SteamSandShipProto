extends Interactable
##
## BOILER FIREBOX — drop carried coal in to feed the steam plant.
##
## Player must be carrying coal AND the firebox must have capacity (the steam
## plant caps coal_in_firebox at 8 loads). If either check fails the player
## keeps their coal — no wasted trips.
##

func _ready() -> void:
	prompt_text = "Press E to add coal"


## Server-only. Validate the carry-item state, ask the plant to accept the
## coal, and only then consume it from the player. Order matters: we don't
## want to take the coal and then discover the firebox is full.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("is_carrying_item"):
		return
	if not bool(player.call("is_carrying_item", "coal")):
		return
	var plant := _find_steam_plant()
	if plant == null or not plant.has_method("add_coal"):
		return
	if not bool(plant.call("add_coal", 1.0)):
		return  # firebox full — keep the coal in hand
	super(peer_id)
	# Clear the player's carry slot only after the firebox accepted the load.
	player.rpc("set_carried_item", "")


func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))


func _find_steam_plant() -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	return ship.get_node_or_null("SteamPlant")
