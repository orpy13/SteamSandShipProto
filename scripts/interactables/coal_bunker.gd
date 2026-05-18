extends Interactable
##
## COAL BUNKER — the ship's working coal store (Tier 1, ROADMAP.md → T1.2).
##
## Finite stock, no longer infinite. Two explicit E actions on the one node,
## chosen by context:
##   • Bunker has coal + hands free → take one load to carry to the firebox.
##   • Bunker empty → load it from the hold (`ship.cargo["coal"]`), in one
##     batch up to capacity. (Explicit, deliberate — no auto-draw.)
##
## Server-authoritative; `bunker_coal` is broadcast so every peer's prompt is
## accurate. Empty bunker + empty hold → no fuel → the ship strands (T1.6).
##

@export var bunker_capacity: int = 10

# Server-authoritative, replicated for prompts via _set_bunker_coal.
var bunker_coal: int = 0


## Start with a working load so a fresh session can get under way; after that
## it's on the crew to keep it topped from cargo.
func _ready() -> void:
	prompt_text = "Press E to take coal"
	bunker_coal = bunker_capacity


## Context-aware prompt: take vs. load vs. dry.
func get_prompt(_player: Node) -> String:
	if bunker_coal > 0:
		return "Press E to take coal (bunker: %d)" % bunker_coal
	var hold := _hold_coal()
	if hold > 0:
		return "Press E to load coal from hold (%d in hold)" % hold
	return "Bunker empty — no coal in hold"


## Server-only. Dispense one load if stocked, otherwise batch-load from cargo.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return

	if bunker_coal <= 0:
		_load_from_hold()
		return

	var player := _find_player(peer_id)
	if player == null or not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	bunker_coal -= 1
	_set_bunker_coal.rpc(bunker_coal)
	player.rpc("set_carried_item", "coal")


## Pull as much coal as the bunker can hold out of the hold, in one action.
func _load_from_hold() -> void:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("remove_cargo"):
		return
	var want: int = bunker_capacity - bunker_coal
	var avail: int = _hold_coal()
	var move: int = mini(want, avail)
	if move <= 0:
		return
	if not ship.remove_cargo("coal", move):
		return
	bunker_coal += move
	_set_bunker_coal.rpc(bunker_coal)


## Broadcast the stock so client prompts stay correct (server is authority).
@rpc("authority", "call_local", "reliable")
func _set_bunker_coal(n: int) -> void:
	bunker_coal = n


## Coal currently in the ship's hold (replicated via ship's _set_cargo).
func _hold_coal() -> int:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not "cargo" in ship:
		return 0
	return int(ship.cargo.get("coal", 0))


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
