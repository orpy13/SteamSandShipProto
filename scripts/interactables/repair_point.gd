extends Interactable
##
## REPAIR POINT — repair a specific ship system at its physical location
## (Tier 1, ROADMAP.md → T1.4).
##
## One instance per worn system: boiler → `power`, bridge → `control`,
## wheels → `mobility`. Carrying a `cargo_repair_kit` (from the workshop store
## or a market crate), press E here to consume it and restore `repair_amount`
## of THIS system's integrity. Spatial + co-op: someone has to fetch a kit and
## bring it to the break.
##

## Which system this point mends. Override per-instance in ship.tscn.
@export var target_system: String = "power"
@export var repair_amount: float = 0.4  # integrity restored per kit


func _ready() -> void:
	prompt_text = "Repair point"


## Context-aware prompt: needs a kit, shows this system's integrity.
func get_prompt(player: Node) -> String:
	var name_str := _pretty_name(target_system)
	var pct := int(round(_integrity() * 100.0))
	var has_kit: bool = player != null and player.has_method("is_carrying_item") \
			and bool(player.call("is_carrying_item", "cargo_repair_kit"))
	if _integrity() >= 1.0:
		return "%s OK (100%%)" % name_str
	if not has_kit:
		return "%s damaged (%d%%) — bring a repair kit" % [name_str, pct]
	return "Press E to repair %s (%d%%)" % [name_str, pct]


## Server-only. Consume the carried kit and mend this system.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("repair_system"):
		return
	if _integrity() >= 1.0:
		return  # already sound — keep the kit
	var player := _find_player(peer_id)
	if player == null or not player.has_method("is_carrying_item"):
		return
	if not bool(player.call("is_carrying_item", "cargo_repair_kit")):
		return
	super(peer_id)
	ship.repair_system(target_system, repair_amount)
	player.rpc("set_carried_item", "")


func _integrity() -> float:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not "system_integrity" in ship:
		return 1.0
	return float(ship.system_integrity.get(target_system, 1.0))


func _pretty_name(system: String) -> String:
	return system.replace("_", " ").capitalize()


func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
