extends Interactable
##
## WORKSHOP — repair-kit repository (Tier 1, ROADMAP.md → T1.4).
##
## No longer repairs anything itself — repairs happen at the damaged part
## (see `repair_point.gd`). This is just a store of kits: take one to carry,
## or (when empty) batch-load it from the hold's `repair_kit` cargo. Mirrors
## the coal-bunker pattern exactly.
##
## Carried id is `cargo_repair_kit` (same as a kit crate from a market), so it
## uses the generic cargo carry visual and a RepairPoint accepts it directly.
##

@export var workshop_capacity: int = 6

# Server-authoritative, replicated for prompts via _set_workshop_kits.
var workshop_kits: int = 0


func _ready() -> void:
	prompt_text = "Press E to take repair kit"
	workshop_kits = workshop_capacity


## Context-aware prompt: take vs. load vs. dry.
func get_prompt(_player: Node) -> String:
	if workshop_kits > 0:
		return "Press E to take repair kit (store: %d)" % workshop_kits
	var hold := _hold_kits()
	if hold > 0:
		return "Press E to load kits from hold (%d in hold)" % hold
	return "No repair kits in store or hold"


## Server-only. Dispense one kit if stocked, else batch-load from cargo.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	if workshop_kits <= 0:
		_load_from_hold()
		return

	var player := _find_player(peer_id)
	if player == null or not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	workshop_kits -= 1
	_set_workshop_kits.rpc(workshop_kits)
	player.rpc("set_carried_item", "cargo_repair_kit")


## Pull as many kits as the store can hold out of the hold, in one action.
func _load_from_hold() -> void:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("remove_cargo"):
		return
	var move: int = mini(workshop_capacity - workshop_kits, _hold_kits())
	if move <= 0:
		return
	if not ship.remove_cargo("repair_kit", move):
		return
	workshop_kits += move
	_set_workshop_kits.rpc(workshop_kits)


@rpc("authority", "call_local", "reliable")
func _set_workshop_kits(n: int) -> void:
	workshop_kits = n


func _hold_kits() -> int:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not "cargo" in ship:
		return 0
	return int(ship.cargo.get("repair_kit", 0))


func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
