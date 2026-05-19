class_name DebugPanel
extends Control
##
## DEBUG PANEL — host-only god-mode overlay (instructions.md → Debug / god mode).
##
## Toggled with F1. Only the host can flip `GameState.debug_mode` (the flag is
## broadcast via NetworkManager.notify_debug_mode); clients see the panel
## hidden. Built entirely in code so we don't add another .tscn for a tool UI.
##
## Buttons issue host-only side-effects directly on the relevant nodes
## (ship.add_cargo / repair_system, bandit_director.debug_spawn_one, etc).
## Sliders write to GameState.debug_force_* / debug_*_mult shadow variables —
## consumers (day_night_cycle, weather_system, player_controller) read those
## when debug_mode is on.
##

const TELEPORT_TARGETS: Array[Dictionary] = [
	{"label": "Mining (6, 4)",    "offset": Vector3(480.0, 0.0, 320.0)},
	{"label": "Caravan (-5, -3)", "offset": Vector3(-400.0, 0.0, -240.0)},
	{"label": "Mining (9, -7)",   "offset": Vector3(720.0, 0.0, -560.0)},
	{"label": "Caravan (-10, 8)", "offset": Vector3(-800.0, 0.0, 640.0)},
	{"label": "Origin",           "offset": Vector3.ZERO},
]

var _root: PanelContainer
var _master_btn: Button
var _status_label: Label
var _daylight_slider: HSlider
var _daylight_value: Label
var _storm_slider: HSlider
var _storm_value: Label
var _speed_slider: HSlider
var _speed_value: Label
var _jump_slider: HSlider
var _jump_value: Label
var _noclip_btn: CheckBox

# Teleport mapping mirrors ChunkGen.HAND_PLACED_OASES; offsets are
# (key * chunk_size) where chunk_size defaults to 80. Kept as a const above so
# the panel doesn't drag in ChunkGen at parse time.


func _ready() -> void:
	# Stretch over the whole screen but draw nothing — the inner PanelContainer
	# is sized + anchored to the top-right corner.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()
	visible = false
	# React to host-flag changes so a client peer doesn't accidentally see
	# stale UI state if it ever opens the panel for inspection.
	GameState.debug_mode_changed.connect(_on_debug_mode_changed)
	_refresh_status()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("debug_toggle"):
		return
	# Only the host can drive the debug panel — clients have no authority to
	# flip the global flag. Silently no-op for them.
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return
	visible = not visible
	# Capturing the mouse while debugging is the usual pain point; surface it
	# automatically whenever the panel is open and hand back when closed.
	if visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_root.position = Vector2(-360.0, 12.0)
	_root.custom_minimum_size = Vector2(340.0, 0.0)
	add_child(_root)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_root.add_child(v)

	var title := Label.new()
	title.text = "DEBUG / GOD MODE  (F1)"
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	v.add_child(title)

	_master_btn = Button.new()
	_master_btn.text = "Enable god mode"
	_master_btn.toggle_mode = true
	_master_btn.pressed.connect(_on_master_pressed)
	v.add_child(_master_btn)

	_status_label = Label.new()
	_status_label.text = "off"
	v.add_child(_status_label)

	v.add_child(HSeparator.new())

	_add_action(v, "Refill cargo + money",  _on_refill_pressed)
	_add_action(v, "Repair all systems",     _on_repair_pressed)
	_add_action(v, "Refuel boiler now",      _on_refuel_pressed)
	_add_action(v, "Spawn bandit (one-off)", _on_spawn_bandit_pressed)
	_add_action(v, "Kill all bandits",       _on_kill_bandits_pressed)

	v.add_child(HSeparator.new())

	# Teleport row — a dropdown of curated oases (mirrors HAND_PLACED_OASES).
	var tp_row := HBoxContainer.new()
	v.add_child(tp_row)
	var tp_lbl := Label.new()
	tp_lbl.text = "Teleport:"
	tp_row.add_child(tp_lbl)
	var tp_opt := OptionButton.new()
	for i in range(TELEPORT_TARGETS.size()):
		tp_opt.add_item(String(TELEPORT_TARGETS[i]["label"]), i)
	tp_row.add_child(tp_opt)
	var tp_go := Button.new()
	tp_go.text = "Go"
	tp_go.pressed.connect(func(): _on_teleport_pressed(tp_opt.selected))
	tp_row.add_child(tp_go)

	v.add_child(HSeparator.new())

	# Force daylight slider (0..1, plus a "release" button for NAN).
	_daylight_slider = _add_slider(v, "Force daylight",
			0.0, 1.0, 0.05, 1.0, _on_daylight_slider_changed)
	_daylight_value = v.get_child(v.get_child_count() - 1) as Label
	_add_action(v, "Release daylight override", _on_daylight_release_pressed)

	# Force storm intensity slider (0..1).
	_storm_slider = _add_slider(v, "Force storm",
			0.0, 1.0, 0.05, 0.0, _on_storm_slider_changed)
	_storm_value = v.get_child(v.get_child_count() - 1) as Label
	_add_action(v, "Release storm override", _on_storm_release_pressed)

	v.add_child(HSeparator.new())

	_speed_slider = _add_slider(v, "Move speed ×",
			1.0, 10.0, 0.5, 1.0, _on_speed_slider_changed)
	_speed_value = v.get_child(v.get_child_count() - 1) as Label
	_jump_slider = _add_slider(v, "Jump ×",
			1.0, 5.0, 0.25, 1.0, _on_jump_slider_changed)
	_jump_value = v.get_child(v.get_child_count() - 1) as Label

	_noclip_btn = CheckBox.new()
	_noclip_btn.text = "No-clip (disable player collision)"
	_noclip_btn.toggled.connect(_on_noclip_toggled)
	v.add_child(_noclip_btn)


## Append a button to `parent` and wire its pressed signal.
func _add_action(parent: Node, label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


## Append a labelled slider + value-readout label. Returns the slider; the
## value label is the last child appended (caller can grab it).
func _add_slider(parent: Node, label: String,
		mn: float, mx: float, step: float, init: float, cb: Callable) -> HSlider:
	var lbl := Label.new()
	lbl.text = label
	parent.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value = init
	sl.custom_minimum_size = Vector2(0.0, 18.0)
	parent.add_child(sl)
	var val := Label.new()
	val.text = "%.2f" % init
	parent.add_child(val)
	sl.value_changed.connect(func(v: float):
		val.text = "%.2f" % v
		cb.call(v))
	return sl


# ── Master toggle ────────────────────────────────────────────────────────────

func _on_master_pressed() -> void:
	if not multiplayer.is_server():
		return
	NetworkManager.set_debug_mode(_master_btn.button_pressed)


func _on_debug_mode_changed(_enabled: bool) -> void:
	_refresh_status()


func _refresh_status() -> void:
	if _master_btn == null:
		return
	_master_btn.button_pressed = GameState.debug_mode
	_master_btn.text = "DISABLE god mode" if GameState.debug_mode else "Enable god mode"
	_status_label.text = "on" if GameState.debug_mode else "off"
	_status_label.add_theme_color_override("font_color",
			Color(0.4, 1.0, 0.4) if GameState.debug_mode else Color(0.7, 0.7, 0.7))


# ── One-shot actions (all host-only) ─────────────────────────────────────────

func _on_refill_pressed() -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return
	# Top up money to a generous test float (don't reset — additive).
	if ship.has_method("receive_money"):
		ship.receive_money(10000)
	# Pack the hold to capacity: split evenly across every key in `cargo`.
	if "cargo" in ship and "cargo_capacity" in ship:
		var keys = (ship.cargo as Dictionary).keys()
		var slice: int = maxi(1, int(ship.cargo_capacity) / maxi(1, keys.size()))
		for k in keys:
			ship.add_cargo(String(k), slice)


func _on_repair_pressed() -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("repair_system"):
		return
	for k in (ship.system_integrity as Dictionary).keys():
		ship.repair_system(String(k), 1.0)


func _on_refuel_pressed() -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return
	var plant: Node = ship.get_node_or_null("SteamPlant")
	if plant != null:
		if "max_coal" in plant and plant.has_method("add_coal"):
			plant.add_coal(float(plant.max_coal))
		if "max_water_level" in plant and plant.has_method("add_water"):
			plant.add_water(float(plant.max_water_level))


func _on_spawn_bandit_pressed() -> void:
	if not multiplayer.is_server():
		return
	var dir := get_tree().get_first_node_in_group("bandit_director")
	if dir == null or not dir.has_method("debug_spawn_one"):
		return
	dir.debug_spawn_one()


func _on_kill_bandits_pressed() -> void:
	if not multiplayer.is_server():
		return
	var dir := get_tree().get_first_node_in_group("bandit_director")
	if dir == null:
		return
	var wm := dir.get_parent()
	if wm == null:
		return
	for child in wm.get_children():
		if String(child.name).begins_with("Bandit_"):
			dir.destroy_bandit(String(child.name))


func _on_teleport_pressed(idx: int) -> void:
	if not multiplayer.is_server():
		return
	if idx < 0 or idx >= TELEPORT_TARGETS.size():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("debug_set_offset"):
		return
	# Route through an RPC so the offset lands on every peer regardless of who
	# currently holds ship authority (helmsman may be a client).
	ship.debug_set_offset.rpc(TELEPORT_TARGETS[idx]["offset"] as Vector3)


# ── Slider handlers (drive shadow variables on GameState) ────────────────────

func _on_daylight_slider_changed(v: float) -> void:
	GameState.debug_force_daylight = v

func _on_daylight_release_pressed() -> void:
	GameState.debug_force_daylight = NAN

func _on_storm_slider_changed(v: float) -> void:
	GameState.debug_force_storm = v

func _on_storm_release_pressed() -> void:
	GameState.debug_force_storm = NAN

func _on_speed_slider_changed(v: float) -> void:
	GameState.debug_speed_mult = v

func _on_jump_slider_changed(v: float) -> void:
	GameState.debug_jump_mult = v

func _on_noclip_toggled(on: bool) -> void:
	GameState.debug_noclip = on
