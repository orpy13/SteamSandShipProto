extends Node3D
##
## PLAYER NAMETAG — floating Label3D shown above remote players.
##
## Hidden on the local player (no one needs to read their own name above their
## own head). Listens to NetworkManager.player_list_changed so name edits
## propagate live.
##
## Note: derives its owning peer id from the *grandparent* node name. The
## scene tree is:
##   PlayerContainer/<peer_id>/NameTagAnchor/<this nametag>
## so `get_parent().get_parent().name == "<peer_id>"`.
##

@onready var _label: Label3D = $Label3D


## Resolve our peer id, hide on local, otherwise show the registered crew name.
func _ready() -> void:
	var peer_id := _resolve_peer_id()
	if peer_id == multiplayer.get_unique_id():
		visible = false
		return
	_update_label(peer_id, NetworkManager.players)
	NetworkManager.player_list_changed.connect(_on_players_changed)


## React to roster updates (someone joined, left, or renamed themselves).
func _on_players_changed(updated: Dictionary) -> void:
	_update_label(_resolve_peer_id(), updated)


## Read the player node's name (= peer id) two levels up. See file header for
## the expected scene structure.
func _resolve_peer_id() -> int:
	var anchor := get_parent()
	if anchor == null:
		return 0
	var player := anchor.get_parent()
	if player == null:
		return 0
	var n := str(player.name)
	return int(n) if n.is_valid_int() else 0


## Set the label text, falling back to "Player" if the roster doesn't have us yet.
func _update_label(peer_id: int, roster: Dictionary) -> void:
	if roster.has(peer_id):
		_label.text = String(roster[peer_id].get("name", "Player"))
	else:
		_label.text = "Player"
