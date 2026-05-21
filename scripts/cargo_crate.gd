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
## Visual model: a slot under `Visual` is populated at `_ready` from
## `Goods.get_prop_scene(good_id)` — barrel for liquids, sack/crate for
## solids. Silhouettes intentionally share between paired goods (water /
## drinking_water both barrel, food / repair_kit both crate); the
## `Label3D` child shows the actual contents when the local player gets
## close enough to pick the crate up.
##

@export var good_id: String = "coal"
## Distance (m) from local player below which the floating contents label
## becomes visible. Tuned a bit larger than the player's interact ray so
## the label appears just before the prompt does.
@export var label_visible_range: float = 4.5

@onready var _visual: Node3D = $Visual
@onready var _label: Label3D = $Label


func _ready() -> void:
	add_to_group("cargo_crate")
	_update_visual()


## Instantiate the prop scene for this good under `Visual` and update the
## label text. Safe to call again if `good_id` changes; clears the previous
## prop first. Prop RigidBody is frozen and stripped of collision so it
## reads as decoration alongside the Area3D pickup volume.
func _update_visual() -> void:
	prompt_text = "Press E to pick up %s" % Goods.get_display_name(good_id).to_lower()
	if _label != null:
		_label.text = Goods.get_display_name(good_id)
		# Tint the label with the good's colour so chart / HUD palette
		# stays consistent. White text + dark outline reads at any distance.
		_label.modulate = Color.WHITE
		_label.outline_modulate = Color(0, 0, 0, 1)
	# Tear down any prior prop (re-entrancy guard).
	if _visual != null:
		for c in _visual.get_children():
			c.queue_free()
	var scene_path := Goods.get_prop_scene(good_id)
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return
	var ps: Resource = load(scene_path)
	if not (ps is PackedScene):
		return
	var inst: Node = (ps as PackedScene).instantiate()
	if inst is RigidBody3D:
		var rb := inst as RigidBody3D
		rb.freeze = true
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.collision_layer = 0
		rb.collision_mask = 0
	_visual.add_child(inst)


## Per-frame, per-peer: each peer flips the Label3D for *its* local player
## based on proximity. No replication — visibility is purely cosmetic and
## independent on every screen.
func _process(_delta: float) -> void:
	if _label == null:
		return
	var local := _find_local_player()
	if local == null:
		_label.visible = false
		return
	var d := (local.global_position - global_position).length()
	_label.visible = d <= label_visible_range


func _find_local_player() -> Node3D:
	var local_id := multiplayer.get_unique_id()
	if local_id <= 0:
		return null
	var ship := get_tree().get_first_node_in_group("ship")
	if ship != null:
		var container := ship.get_node_or_null("PlayerContainer")
		if container != null and container.has_node(str(local_id)):
			return container.get_node(str(local_id)) as Node3D
	# Disembarked players live under WorldMap (the gangway reparents them).
	var wm := get_tree().get_first_node_in_group("terrain")
	if wm != null and wm.has_node(str(local_id)):
		return wm.get_node(str(local_id)) as Node3D
	return null


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
