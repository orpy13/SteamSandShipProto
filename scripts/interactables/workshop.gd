extends Interactable
##
## WORKSHOP — source of repair kits AND the place you apply them.
##
## Dual-mode interaction (same pattern the DeckGun uses for load vs. man):
##   • Empty-handed → take a repair kit (carry-item, mirrors coal_bunker).
##   • Carrying a kit → consume the kit, repair the ship's most-damaged system
##     by `repair_amount`. The "most-damaged system" auto-selects so the crew
##     doesn't have to micromanage which face to patch.
##
## Infinite kit supply for the prototype; a future economy pass can make kits
## scarce or tied to oasis stops.
##

@export var repair_amount: float = 0.4  # one kit restores this much integrity to one system


func _ready() -> void:
	prompt_text = "Press E at workshop"


## Contextual prompt — depends on whether the player is carrying a kit and on
## the ship's current damage state.
func get_prompt(player: Node) -> String:
	var has_kit: bool = player != null and player.has_method("is_carrying_item") \
			and bool(player.call("is_carrying_item", "repair_kit"))
	if has_kit:
		var ship := get_tree().get_first_node_in_group("ship")
		var worst := _find_most_damaged(ship)
		if worst.is_empty():
			return "Ship undamaged"
		var pct := int(round(_get_integrity(ship, worst) * 100.0))
		return "Press E to repair %s (%d%%)" % [_pretty_name(worst), pct]
	return "Press E to take repair kit"


## Server-only. Two branches:
##   1. Carrying a kit → consume it, heal the most-damaged system on the ship.
##   2. Empty-handed → hand the player a kit (if their hands are free).
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null:
		return

	var has_kit: bool = player.has_method("is_carrying_item") and bool(player.call("is_carrying_item", "repair_kit"))
	if has_kit:
		var ship := get_tree().get_first_node_in_group("ship")
		var worst := _find_most_damaged(ship)
		if worst.is_empty():
			return  # nothing to repair — keep the kit in hand
		if ship == null or not ship.has_method("repair_system"):
			return
		super(peer_id)
		ship.repair_system(worst, repair_amount)
		player.rpc("set_carried_item", "")
		return

	# Empty-handed: take a kit if the player has free hands.
	if not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	player.rpc("set_carried_item", "repair_kit")


## Scan the ship's system_integrity dict, return the key with the lowest value.
## Empty string if everything is at 1.0 (fully repaired).
func _find_most_damaged(ship: Node) -> String:
	if ship == null or not "system_integrity" in ship:
		return ""
	var worst := ""
	var worst_value := 1.0
	for key in ship.system_integrity.keys():
		var val := float(ship.system_integrity[key])
		if val < worst_value:
			worst_value = val
			worst = String(key)
	if worst_value >= 1.0:
		return ""
	return worst


## Look up the integrity of a single system on the ship, with a 1.0 fallback.
func _get_integrity(ship: Node, system: String) -> float:
	if ship == null or not "system_integrity" in ship:
		return 1.0
	return float(ship.system_integrity.get(system, 1.0))


## Pretty-print a system key like "hull_left" → "Hull left" for the prompt.
func _pretty_name(system: String) -> String:
	return system.replace("_", " ").capitalize()


## Player node lookup — same pattern the other interactables use.
func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
