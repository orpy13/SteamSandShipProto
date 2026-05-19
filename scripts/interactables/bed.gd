extends Interactable
##
## BED — rest to recover crew energy (Tier 1 follow-up).
##
## Lives as an Area3D child ("RestPoint") of the bed_single scene so the
## interact ray can see it (the bed mesh itself is a StaticBody, not on the
## interact layer). One E press tops the interacting crew member's energy by
## `rest_amount`; press again to keep resting.
##

@export var rest_amount: float = 35.0


func _ready() -> void:
	prompt_text = "Press E to rest"


func get_prompt(player: Node) -> String:
	if player != null and "energy" in player:
		var e := int(round(float(player.energy)))
		if e >= 100:
			return "Fully rested"
		return "Press E to rest (energy %d%%)" % e
	return prompt_text


## Server-only. Bump the interacting player's energy via their replicated RPC.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("rest_energy"):
		return
	super(peer_id)
	player.rest_energy.rpc(rest_amount)


func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
