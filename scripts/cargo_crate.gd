extends Interactable
##
## CARGO CRATE — a physical crate of a single good, sitting at an oasis.
##
## Spawned by an OasisMarket after a successful Buy RPC. Lives as a child of
## the oasis (so it unloads with the chunk if the player sails away without
## picking it up — for v1 that's an acceptable "you snooze you lose"). When a
## crew member picks it up, the crate sets their carry slot to the matching
## "cargo_<good>" id and despawns on every peer.
##
## The mesh is tinted at runtime to match the good's colour from the registry,
## so we only need one scene for all goods.
##

@export var good_id: String = "coal"


func _ready() -> void:
	add_to_group("cargo_crate")
	_update_visual()


## Set the prompt + crate colour from the registry. Called once on _ready;
## also safe to call again if good_id is changed at runtime.
func _update_visual() -> void:
	prompt_text = "Press E to pick up %s" % Goods.get_display_name(good_id).to_lower()
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh != null:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Goods.get_color(good_id)
		mat.roughness = 0.85
		mesh.material_override = mat


## Server-only. Player picks up the crate; their carry slot becomes the
## matching "cargo_<good>" id. RPC despawn on all peers.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)
	if player == null or not player.has_method("can_carry_item") or not bool(player.call("can_carry_item")):
		return
	super(peer_id)
	var carry_id := Goods.get_carry_id(good_id)
	if carry_id.is_empty():
		return
	player.rpc("set_carried_item", carry_id)
	_despawn.rpc()


@rpc("authority", "call_local", "reliable")
func _despawn() -> void:
	queue_free()


func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))
