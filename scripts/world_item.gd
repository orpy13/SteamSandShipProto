extends Interactable
##
## WORLD ITEM — the Interactable behaviour for a dropped / market-spawned
## prop sitting in the world (Tier 1 follow-up, see ROADMAP.md → Future →
## "Drop carried items into the world").
##
## Lives on the `InteractArea` child of a prop scene's RigidBody3D root
## (barrel / crate / sack / water_bottle / sausage). Two responsibilities:
##
##   1. Show a Label3D with the contents name when the local player is in
##      pickup range — the world has visually identical props for paired
##      goods (water vs drinking_water both barrels; food vs repair_kit
##      both crates), so the label is what disambiguates.
##   2. On E-interact, set the player's carry slot to `carry_id` and free
##      the parent RigidBody (the actual world item).
##
## `carry_id` is set per-instance at spawn (`oasis_market` buys,
## `drop_manager` drops) since the prop scene alone can't tell which good
## it represents.
##

## Carry id this item grants on pickup. e.g. "cargo_coal",
## "item_water_bottle". Set externally at spawn time.
@export var carry_id: String = ""
## Distance (m) from local player below which the Label3D becomes visible.
## Roughly matches the player interact-ray range so the label appears just
## before the prompt does.
@export var label_visible_range: float = 4.5


func _ready() -> void:
	add_to_group("world_item")
	prompt_text = "Press E to pick up %s" % _display_name().to_lower()
	_refresh_label()


## Server-only pickup: set the player's carry slot to this item's
## `carry_id`, then free the prop (the InteractArea's parent — the
## RigidBody root). Mirrors the old `cargo_crate.interact` flow.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if carry_id.is_empty():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	player.rpc("set_carried_item", carry_id)
	_despawn.rpc()


## Despawn the prop on every peer. Frees the InteractArea's parent (the
## RigidBody root). Safe to call even if the parent was already freed —
## queue_free is idempotent.
@rpc("authority", "call_local", "reliable")
func _despawn() -> void:
	var root := get_parent()
	if root != null and is_instance_valid(root):
		root.queue_free()


## Proximity Label3D toggle, per-peer (each peer evaluates against its own
## local player — no replication needed since visibility is cosmetic).
func _process(_delta: float) -> void:
	var label := _get_label()
	if label == null:
		return
	var local := _find_local_player()
	if local == null:
		label.visible = false
		return
	# Distance from the prop root (the InteractArea may sit slightly above
	# the body's centre, so use the parent's transform).
	var root := get_parent()
	if root == null or not (root is Node3D):
		label.visible = false
		return
	var d := ((root as Node3D).global_position - local.global_position).length()
	label.visible = d <= label_visible_range


## Display name resolved via Goods (cargo and consumable both registered).
func _display_name() -> String:
	if carry_id.is_empty():
		return "item"
	var good_id := Goods.good_from_carry_id(carry_id)
	if good_id.is_empty():
		return carry_id
	return Goods.get_display_name(good_id)


## Refresh the Label3D text when carry_id changes (called from _ready;
## drop_manager / oasis_market also poke it after assigning carry_id).
func _refresh_label() -> void:
	var label := _get_label()
	if label == null:
		return
	label.text = _display_name()


## Sibling Label3D under the prop root. Returns null if absent (the prop
## scene should ship with one, but defensive guard).
func _get_label() -> Label3D:
	var root := get_parent()
	if root == null:
		return null
	return root.get_node_or_null("Label") as Label3D


## Resolve the local player's body. Handles on-ship (PlayerContainer) and
## disembarked (WorldMap) cases identically to ChartPanel / CargoCrate.
func _find_local_player() -> Node3D:
	var local_id := multiplayer.get_unique_id()
	if local_id <= 0:
		return null
	var ship := get_tree().get_first_node_in_group("ship")
	if ship != null:
		var container := ship.get_node_or_null("PlayerContainer")
		if container != null and container.has_node(str(local_id)):
			return container.get_node(str(local_id)) as Node3D
	var wm := get_tree().get_first_node_in_group("terrain")
	if wm != null and wm.has_node(str(local_id)):
		return wm.get_node(str(local_id)) as Node3D
	return null


## Resolve a player node by peer id for server-side pickup attribution.
func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship != null:
		var container := ship.get_node_or_null("PlayerContainer")
		if container != null and container.has_node(str(peer_id)):
			return container.get_node(str(peer_id))
	var wm := get_tree().get_first_node_in_group("terrain")
	if wm != null and wm.has_node(str(peer_id)):
		return wm.get_node(str(peer_id))
	return null
