extends Interactable
##
## OASIS MARKET — the trade interactable at an oasis.
##
## Pressing E on a market doesn't go through the host (it's purely a local UI
## action); player_controller detects the "oasis_market" group and opens the
## trade panel locally. The actual buy/sell calls are RPC'd from the trade
## panel to the host's market node via `request_buy` / `request_sell`.
##
## Host validates funds + cargo capacity, mutates ship.money / ship.cargo,
## and (on buy) spawns physical crates next to the stall for the crew to
## carry back to the ship's cargo hold.
##

const CARGO_CRATE_SCENE: PackedScene = preload("res://scenes/world/cargo_crate.tscn")

@export var oasis_type: String = "mining"  # "mining" or "caravan"
@export var crate_forward_offset: float = 2.5  # metres in front of the stall
@export var crate_lateral_spacing: float = 0.7 # spacing when multiple crates spawn


func _ready() -> void:
	add_to_group("oasis_market")
	prompt_text = "Press E to trade"


## Trade panel UI calls this; goes to the host for validation. `qty` is the
## number of crates to buy. Sanity-capped to keep a runaway client from
## buying 10000 crates at once.
@rpc("any_peer", "call_local", "reliable")
func request_buy(good_id: String, qty: int) -> void:
	if not multiplayer.is_server():
		return
	if qty <= 0 or qty > 5:
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return
	var buy_price := Goods.get_buy_price(oasis_type, good_id)
	if buy_price <= 0:
		return
	var total_cost := buy_price * qty
	# Capacity check first so we don't spend the money then fail.
	if int(ship.get_cargo_total()) + qty > int(ship.cargo_capacity):
		return
	if int(ship.money) < total_cost:
		return
	if not ship.try_spend(total_cost):
		return
	for i in range(qty):
		_spawn_crate(good_id, i)
	_revive_crew()


@rpc("any_peer", "call_local", "reliable")
func request_sell(good_id: String, qty: int) -> void:
	if not multiplayer.is_server():
		return
	if qty <= 0 or qty > 5:
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return
	var sell_price := Goods.get_sell_price(oasis_type, good_id)
	if sell_price <= 0:
		return
	if not ship.remove_cargo(good_id, qty):
		return
	ship.receive_money(sell_price * qty)
	_revive_crew()


## Reaching a settlement and trading patches the crew up (T1.5). Server-only;
## clears `is_dead` and re-provisions everyone via their replicated RPC.
func _revive_crew() -> void:
	var ship := get_tree().get_first_node_in_group("ship")
	var container: Node = ship.get_node_or_null("PlayerContainer") if ship != null else null
	var wm := get_tree().get_first_node_in_group("terrain")
	for peer_id in NetworkManager.players.keys():
		var node: Node = null
		if container != null and container.has_node(str(peer_id)):
			node = container.get_node(str(peer_id))
		elif wm != null and wm.has_node(str(peer_id)):
			node = wm.get_node(str(peer_id))
		if node != null and node.has_method("revive_survival"):
			node.revive_survival.rpc()


## Spawn a crate at a local-space position in front of the stall. Multiple
## crates from the same trade fan out laterally so they don't stack.
func _spawn_crate(good_id: String, index: int) -> void:
	var spawn_local: Vector3 = self.position \
			+ Vector3(0.0, 0.0, crate_forward_offset) \
			+ Vector3(crate_lateral_spacing * float(index), 0.0, 0.0)
	_spawn_crate_at.rpc(good_id, spawn_local)


## All peers: instantiate a crate as a child of the parent oasis at the given
## local position. good_id is set BEFORE add_child so the crate's _ready can
## tint the mesh correctly.
@rpc("authority", "call_local", "reliable")
func _spawn_crate_at(good_id: String, local_pos: Vector3) -> void:
	var oasis := get_parent()
	if oasis == null:
		return
	var crate: Node = CARGO_CRATE_SCENE.instantiate()
	crate.set("good_id", good_id)
	oasis.add_child(crate)
	if crate is Node3D:
		(crate as Node3D).position = local_pos
