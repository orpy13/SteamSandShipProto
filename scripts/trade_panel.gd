extends Control
##
## TRADE PANEL — modal-ish trade UI shown when a crew member opens a market.
##
## Lives inside the HUD scene tree (one instance per peer). Hidden by default;
## becomes visible when the local player_controller presses E on an oasis
## market interactable. Reads live `ship.money` and `ship.cargo` via direct
## node access (server-authoritative; updates broadcast via the ship's
## money_changed / cargo_changed signals).
##
## Buy and Sell buttons call the matching `request_buy` / `request_sell` RPCs
## on the active market — the host validates and broadcasts the result.
##

@onready var _header_label: Label = $Panel/VBox/HeaderLabel
@onready var _good_rows: VBoxContainer = $Panel/VBox/GoodRows
@onready var _close_btn: Button = $Panel/VBox/CloseBtn

var _active_market: Node = null
var _ship: Node = null

# good_id → Label showing held quantity in the cargo hold. Stored at build
# time so _refresh doesn't have to scan the tree.
var _qty_labels: Dictionary = {}


## Hidden until a market explicitly opens us. Joins the "trade_panel" group
## so player_controller can find us via group lookup.
func _ready() -> void:
	add_to_group("trade_panel")
	visible = false
	_close_btn.pressed.connect(_close)
	mouse_filter = Control.MOUSE_FILTER_STOP


## Public entry point. player_controller calls this when the local player
## presses E on an oasis market.
func open_for_market(market: Node) -> void:
	_active_market = market
	_ship = get_tree().get_first_node_in_group("ship")
	_build_rows()
	_refresh()
	visible = true
	# Free the cursor for clicking.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Live-refresh on money/cargo changes from the host.
	if _ship and _ship.has_signal("money_changed") and not _ship.money_changed.is_connected(_on_money_changed):
		_ship.money_changed.connect(_on_money_changed)
	if _ship and _ship.has_signal("cargo_changed") and not _ship.cargo_changed.is_connected(_on_cargo_changed):
		_ship.cargo_changed.connect(_on_cargo_changed)


## Close + unsubscribe + recapture mouse.
func _close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _ship:
		if _ship.has_signal("money_changed") and _ship.money_changed.is_connected(_on_money_changed):
			_ship.money_changed.disconnect(_on_money_changed)
		if _ship.has_signal("cargo_changed") and _ship.cargo_changed.is_connected(_on_cargo_changed):
			_ship.cargo_changed.disconnect(_on_cargo_changed)
	_active_market = null


## Esc closes the panel. Handled here (not in player_controller) so the
## panel can intercept before the player_controller's debug-Esc kicks in.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()


func _on_money_changed(_v: int) -> void:
	_refresh()


func _on_cargo_changed(_g: String, _v: int) -> void:
	_refresh()


## Build one row per good — name + prices + buy button + held qty + sell button.
func _build_rows() -> void:
	_qty_labels.clear()
	for child in _good_rows.get_children():
		child.queue_free()
	if _active_market == null:
		return
	var oasis_type := String(_active_market.get("oasis_type"))
	for good_id in Goods.ALL.keys():
		if not Goods.is_tradeable(good_id):
			continue  # physical consumables aren't market goods
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var name_lbl := Label.new()
		name_lbl.text = "%s  Buy:£%d  Sell:£%d" % [
			Goods.get_display_name(good_id),
			Goods.get_buy_price(oasis_type, good_id),
			Goods.get_sell_price(oasis_type, good_id),
		]
		name_lbl.custom_minimum_size = Vector2(220, 0)
		row.add_child(name_lbl)

		var buy_btn := Button.new()
		buy_btn.text = "Buy"
		buy_btn.pressed.connect(_on_buy.bind(good_id))
		row.add_child(buy_btn)

		var qty_lbl := Label.new()
		qty_lbl.text = "Held 0"
		qty_lbl.custom_minimum_size = Vector2(70, 0)
		qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_qty_labels[good_id] = qty_lbl
		row.add_child(qty_lbl)

		var sell_btn := Button.new()
		sell_btn.text = "Sell"
		sell_btn.pressed.connect(_on_sell.bind(good_id))
		row.add_child(sell_btn)

		_good_rows.add_child(row)


## Refresh header (money + cargo total) and per-good held quantities.
func _refresh() -> void:
	if _ship == null:
		_header_label.text = "Money: --"
		return
	var money := int(_ship.money)
	var cargo_total := int(_ship.call("get_cargo_total"))
	var cap := int(_ship.cargo_capacity)
	_header_label.text = "£%d   Hold %d/%d" % [money, cargo_total, cap]
	for good_id in _qty_labels.keys():
		var qty := int(_ship.cargo.get(good_id, 0))
		(_qty_labels[good_id] as Label).text = "Held %d" % qty


## Buy 1 crate. Host calls request_buy directly; clients RPC to peer 1.
func _on_buy(good_id: String) -> void:
	if _active_market == null:
		return
	if multiplayer.is_server():
		_active_market.request_buy(good_id, 1)
	else:
		_active_market.request_buy.rpc_id(1, good_id, 1)


func _on_sell(good_id: String) -> void:
	if _active_market == null:
		return
	if multiplayer.is_server():
		_active_market.request_sell(good_id, 1)
	else:
		_active_market.request_sell.rpc_id(1, good_id, 1)
