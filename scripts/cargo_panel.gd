class_name CargoPanel
extends Control
##
## CARGO WITHDRAW CHOOSER — pick an item to pull out of the hold into hand.
##
## Built entirely in code (no .tscn) and parented under the UILayer at runtime
## by player_controller, so no scene needs editing. Mirrors trade_panel's
## "host validates, UI just sends an RPC" model: each Take button calls the
## hold's `request_withdraw` RPC; the host moves one unit from `ship.cargo`
## into the caller's hands.
##

var _hold: Node = null
var _ship: Node = null

var _rows: VBoxContainer = null
var _header: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-180, -160)
	panel.custom_minimum_size = Vector2(360, 320)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	_header = Label.new()
	_header.text = "Cargo Hold"
	vbox.add_child(_header)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	vbox.add_child(_rows)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_close)
	vbox.add_child(close_btn)


## player_controller calls this when E is pressed at the hold empty-handed.
func open_for_hold(hold: Node) -> void:
	_hold = hold
	_ship = get_tree().get_first_node_in_group("ship")
	if _ship != null and _ship.has_signal("cargo_changed") \
			and not _ship.cargo_changed.is_connected(_on_cargo_changed):
		_ship.cargo_changed.connect(_on_cargo_changed)
	_rebuild()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _ship != null and _ship.has_signal("cargo_changed") \
			and _ship.cargo_changed.is_connected(_on_cargo_changed):
		_ship.cargo_changed.disconnect(_on_cargo_changed)
	_hold = null


## Esc closes (intercept before player_controller's debug-Esc).
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()


func _on_cargo_changed(_g: String, _v: int) -> void:
	if visible:
		_rebuild()


## One row per cargo entry with a positive quantity.
func _rebuild() -> void:
	for c in _rows.get_children():
		c.queue_free()
	if _ship == null or not "cargo" in _ship:
		return
	var cap := int(_ship.cargo_capacity) if "cargo_capacity" in _ship else 20
	var total := int(_ship.call("get_cargo_total")) if _ship.has_method("get_cargo_total") else 0
	_header.text = "Cargo Hold  (%d/%d)" % [total, cap]
	for good_id in _ship.cargo.keys():
		var qty := int(_ship.cargo[good_id])
		if qty <= 0:
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lbl := Label.new()
		lbl.text = "%s  ×%d" % [Goods.get_display_name(good_id), qty]
		lbl.custom_minimum_size = Vector2(220, 0)
		row.add_child(lbl)
		var take := Button.new()
		take.text = "Take"
		take.pressed.connect(_on_take.bind(good_id))
		row.add_child(take)
		_rows.add_child(row)
	if _rows.get_child_count() == 0:
		var empty := Label.new()
		empty.text = "(hold is empty)"
		_rows.add_child(empty)


func _on_take(good_id: String) -> void:
	if _hold == null or not is_instance_valid(_hold):
		return
	if multiplayer.is_server():
		_hold.request_withdraw(good_id)
	else:
		_hold.request_withdraw.rpc_id(1, good_id)
