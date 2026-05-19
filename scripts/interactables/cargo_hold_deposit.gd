extends Interactable
##
## CARGO HOLD DEPOSIT — interact point on the ship where crew stow crates.
##
## Sits on top of the existing CargoHold StaticBody3D. When a player carrying
## a "cargo_<good>" crate presses E, we increment `ship.cargo[good]` by 1 and
## clear their carry slot. Selling later happens via the trade panel — it
## reads directly from `ship.cargo`, no need to physically pull crates back.
##


func _ready() -> void:
	prompt_text = "Bring cargo here"
	add_to_group("cargo_hold")  # player_controller opens the withdraw chooser


## Contextual prompt: shows what good the player is carrying, plus the
## current hold fill, or "Cargo hold full" if there's no room.
func get_prompt(player: Node) -> String:
	if player == null:
		return "Bring cargo here"
	if not player.has_method("is_carrying_cargo") or not bool(player.call("is_carrying_cargo")):
		return "Press E to take from hold"
	var good_id := String(player.call("get_carried_cargo_good"))
	if good_id.is_empty():
		return "Bring cargo here"
	var ship := get_tree().get_first_node_in_group("ship")
	var total := 0
	var cap := 20
	if ship != null:
		if ship.has_method("get_cargo_total"):
			total = int(ship.call("get_cargo_total"))
		if "cargo_capacity" in ship:
			cap = int(ship.cargo_capacity)
	if total >= cap:
		return "Cargo hold full (%d/%d)" % [total, cap]
	return "Press E to stow %s (%d/%d)" % [Goods.get_display_name(good_id).to_lower(), total, cap]


## Server-only. Validate that the player is actually carrying cargo and that
## the hold has room; on success, bump the cargo dict and clear their hands.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("is_carrying_cargo"):
		return
	if not bool(player.call("is_carrying_cargo")):
		return
	var good_id := String(player.call("get_carried_cargo_good"))
	if good_id.is_empty():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("add_cargo"):
		return
	if not ship.add_cargo(good_id, 1):
		return  # capacity full — keep the crate in hand
	super(peer_id)
	player.rpc("set_carried_item", "")


## Withdraw one unit of `good_id` from the hold into the caller's hands.
## Server-validated; the chooser UI (cargo_panel.gd) RPCs this.
@rpc("any_peer", "call_local", "reliable")
func request_withdraw(good_id: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var player := _find_player(sender)
	if player == null or not player.has_method("can_carry_item"):
		return
	if not bool(player.call("can_carry_item")):
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("remove_cargo"):
		return
	if int(ship.cargo.get(good_id, 0)) <= 0:
		return
	if not ship.remove_cargo(good_id, 1):
		return
	var carry_id := Goods.get_carry_id(good_id)
	if carry_id.is_empty():
		return
	player.rpc("set_carried_item", carry_id)


func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
