extends Control
##
## HUD — the in-game heads-up display.
##
## Reads from three live sources:
##   • NetworkManager (crew roster, helmsman changes)
##   • The Ship node (speed, engine order, heading, world position)
##   • The Ship/SteamPlant child (boiler pressure / heat / coal / water)
##   • The local player's interact_prompt_changed signal (action prompt)
##
## We re-bind to the local player each frame in _process because the player
## node may not exist yet at _ready (it's spawned by NetworkManager after the
## lobby flow completes).
##

@onready var _speed_label: Label = $TopLeft/SpeedPanel/SpeedLabel
@onready var _engine_order_label: Label = $TopLeft/EngineOrderPanel/EngineOrderLabel
@onready var _player_count_label: Label = $TopLeft/CrewPanel/PlayerCountLabel
@onready var _world_pos_label: Label = $TopLeft/WorldPosPanel/WorldPosLabel
@onready var _helm_label: Label = $TopRight/HelmPanel/HelmsmanLabel
@onready var _damage_label: Label = $TopRight/DamagePanel/DamageLabel
@onready var _money_label: Label = $TopLeft/MoneyPanel/MoneyLabel
@onready var _pressure_bar: ProgressBar = $TopCenter/PressurePanel/PressureBar
@onready var _boiler_label: Label = $TopCenter/BoilerPanel/BoilerLabel
@onready var _heading_label: Label = $TopCenter/HeadingPanel/HeadingLabel
@onready var _prompt_label: Label = $BottomCenter/PromptPanel/PromptLabel

var _ship: CharacterBody3D = null
# Path of the player node we're currently subscribed to. Tracked so we don't
# double-connect to the same signal every frame.
var _bound_player_path: NodePath = NodePath()
# Code-built survival readout (T1.7) — avoids editing hud.tscn.
var _survival_label: Label = null
# True once we've connected to the ship's system_changed signal.
var _damage_signal_bound: bool = false


## Subscribe to network signals and seed labels with whatever's already known.
func _ready() -> void:
	NetworkManager.player_list_changed.connect(_on_players_changed)
	NetworkManager.helmsman_changed.connect(_on_helmsman_changed)
	_pressure_bar.min_value = 0.0
	_pressure_bar.max_value = 100.0
	_on_players_changed(NetworkManager.players)
	_on_helmsman_changed(NetworkManager.current_helmsman)
	_build_survival_label()
	set_process(true)


## Bottom-left needs readout, built in code so no hud.tscn change is needed.
func _build_survival_label() -> void:
	_survival_label = Label.new()
	_survival_label.name = "SurvivalLabel"
	_survival_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_survival_label.position = Vector2(16, -64)
	_survival_label.text = "Hunger -- | Thirst -- | Energy --"
	add_child(_survival_label)


## Per-frame: refresh ship-derived labels and (re)subscribe to the local
## player's interact prompt as soon as that node exists.
func _process(_delta: float) -> void:
	var local_id := multiplayer.get_unique_id()
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return
	_update_heading(ship)
	_update_world_pos(ship)
	_update_engine_order(ship)
	_update_boiler(ship)
	# Find the local player whether aboard (PlayerContainer) or disembarked
	# (reparented under WorldMap by the gangway) — stranded crew still need
	# their survival readout.
	var p: Node = null
	var container: Node = ship.get_node_or_null("PlayerContainer")
	if container != null and container.has_node(str(local_id)):
		p = container.get_node(str(local_id))
	else:
		var wm := get_tree().get_first_node_in_group("terrain")
		if wm != null and wm.has_node(str(local_id)):
			p = wm.get_node(str(local_id))
	if p != null:
		var path := p.get_path()
		if path != _bound_player_path:
			_bound_player_path = path
			if p.has_signal("interact_prompt_changed") \
					and not p.interact_prompt_changed.is_connected(_on_prompt_changed):
				p.interact_prompt_changed.connect(_on_prompt_changed)
			if p.has_signal("survival_changed") \
					and not p.survival_changed.is_connected(_on_survival_changed):
				p.survival_changed.connect(_on_survival_changed)


## Convert virtual_yaw (radians) into a 0–360° compass heading plus cardinal.
func _update_heading(ship: Node) -> void:
	if not "virtual_yaw" in ship:
		return
	var heading := fmod(-rad_to_deg(ship.virtual_yaw), 360.0)
	if heading < 0.0:
		heading += 360.0
	var deg := int(heading)
	var line := "HDG: %03d° %s" % [deg, _cardinal(deg)]
	# Append sky phase and a storm warning. Kept on the heading line so no HUD
	# scene change is needed and the navigational info stays grouped.
	var sky := get_tree().get_first_node_in_group("day_night")
	if sky != null and sky.has_method("get_phase_name"):
		line += "  ·  " + String(sky.get_phase_name())
	var weather := get_tree().get_first_node_in_group("weather")
	if weather != null and weather.has_method("get_storm_intensity"):
		var si := float(weather.get_storm_intensity())
		if si > 0.15:
			line += "  ·  SANDSTORM" + (" (heavy)" if si > 0.6 else "")
	_heading_label.text = line


## Show the ship's virtual position in the dunes (NOT scene-graph position —
## the ship's scene position is always (0, terrain_y, 0); see ship_controller).
func _update_world_pos(ship: Node) -> void:
	if not "world_offset" in ship:
		return
	var off: Vector3 = ship.world_offset
	_world_pos_label.text = "X: %.1f  Z: %.1f" % [off.x, off.z]


## Telegraph display — Stop / Slow Ahead / Half Ahead / etc.
func _update_engine_order(ship: Node) -> void:
	if not "engine_order" in ship:
		return
	_engine_order_label.text = "Order: " + _engine_order_name(int(ship.engine_order))


## Boiler readout. We pull fields directly from the SteamPlant node — it's
## simulated on host and replicated to clients, so this works for everyone.
func _update_boiler(ship: Node) -> void:
	var plant := ship.get_node_or_null("SteamPlant")
	if plant == null:
		_pressure_bar.value = 0.0
		_boiler_label.text = "Steam: --"
		return
	var pressure := float(plant.get("steam_pressure"))
	var heat := float(plant.get("fire_heat"))
	var coal := float(plant.get("coal_in_firebox"))
	var water := float(plant.get("water_level"))
	_pressure_bar.value = clampf(pressure, 0.0, 100.0)
	_boiler_label.text = "Steam: %.0f psi  Heat: %.0f  Coal: %.1f  Water: %.0f%%" % [pressure, heat, coal, water]


## Map an integer telegraph order to its display string.
func _engine_order_name(order: int) -> String:
	match order:
		-2: return "Full Astern"
		-1: return "Half Astern"
		1:  return "Slow Ahead"
		2:  return "Half Ahead"
		3:  return "Three Quarter"
		4:  return "Full Ahead"
		_:  return "Stop"


## Compass cardinal (8 points) for a heading in degrees.
func _cardinal(deg: int) -> String:
	const DIRS: Array[String] = ["N","NE","E","SE","S","SW","W","NW","N"]
	return DIRS[int(round(float(deg) / 45.0)) % 8]


## Called from main.gd once the ship is in the scene. Subscribes to its speed
## signal AND its system_changed signal so the damage readout refreshes live;
## also wires money/cargo signals for the money panel.
func bind_ship(ship: CharacterBody3D) -> void:
	_ship = ship
	if not _ship.speed_changed.is_connected(_on_speed_changed):
		_ship.speed_changed.connect(_on_speed_changed)
	if _ship.has_signal("system_changed") and not _damage_signal_bound:
		_ship.system_changed.connect(_on_system_changed)
		_damage_signal_bound = true
	if _ship.has_signal("money_changed") and not _ship.money_changed.is_connected(_on_money_changed):
		_ship.money_changed.connect(_on_money_changed)
	if _ship.has_signal("cargo_changed") and not _ship.cargo_changed.is_connected(_on_cargo_changed):
		_ship.cargo_changed.connect(_on_cargo_changed)
	_refresh_damage_label()
	_refresh_money_label()


## Refresh the money panel when either money or cargo state changes.
func _on_money_changed(_v: int) -> void:
	_refresh_money_label()


func _on_cargo_changed(_g: String, _v: int) -> void:
	_refresh_money_label()


func _refresh_money_label() -> void:
	if _ship == null:
		_money_label.text = "£--   Hold --/--"
		return
	var money := int(_ship.money)
	var total := int(_ship.call("get_cargo_total"))
	var cap := int(_ship.cargo_capacity)
	_money_label.text = "£%d   Hold %d/%d" % [money, total, cap]


## Refresh the damage readout when any system's integrity changes.
func _on_system_changed(_system: String, _integrity: float) -> void:
	_refresh_damage_label()


## Build a compact two-line readout of all 9 integrity values.
## Line 1: hull faces (L/R/F/A/D). Line 2: internal systems (Mob/Pwr/Ctl/Crg).
func _refresh_damage_label() -> void:
	if _ship == null or not "system_integrity" in _ship:
		_damage_label.text = "Damage: --"
		return
	var s: Dictionary = _ship.system_integrity
	_damage_label.text = "Hull L%d R%d F%d A%d D%d\nMob%d Pwr%d Ctl%d Crg%d" % [
		int(round(float(s.get("hull_left", 1.0)) * 100)),
		int(round(float(s.get("hull_right", 1.0)) * 100)),
		int(round(float(s.get("hull_fore", 1.0)) * 100)),
		int(round(float(s.get("hull_aft", 1.0)) * 100)),
		int(round(float(s.get("hull_deck", 1.0)) * 100)),
		int(round(float(s.get("mobility", 1.0)) * 100)),
		int(round(float(s.get("power", 1.0)) * 100)),
		int(round(float(s.get("control", 1.0)) * 100)),
		int(round(float(s.get("cargo", 1.0)) * 100)),
	]


## Convert m/s into knots for the speed readout (1 m/s ≈ 1.94 kn).
func _on_speed_changed(speed: float) -> void:
	_speed_label.text = "Speed: %.1f kn" % (speed * 1.94384)


## Crew counter — pulled from the live roster, capped at MAX_PLAYERS.
func _on_players_changed(players: Dictionary) -> void:
	_player_count_label.text = "Crew: %d / %d" % [players.size(), NetworkManager.MAX_PLAYERS]


## Helm display — current helmsman's name, or a dash if no one's at the wheel.
func _on_helmsman_changed(peer_id: int) -> void:
	if peer_id == 0:
		_helm_label.text = "Helm: -"
		return
	var nm := "Peer %d" % peer_id
	if NetworkManager.players.has(peer_id):
		nm = String(NetworkManager.players[peer_id].get("name", nm))
	_helm_label.text = "Helm: " + nm


## Show or hide the interact prompt as the local ray-target changes.
func _on_prompt_changed(text: String) -> void:
	_prompt_label.text = text
	_prompt_label.get_parent().visible = not text.is_empty()


## Local crew member's needs (T1.5/T1.7). Red when downed.
func _on_survival_changed(h: float, t: float, e: float, dead: bool) -> void:
	if _survival_label == null:
		return
	if dead:
		_survival_label.text = "DOWNED — reach a settlement"
		_survival_label.modulate = Color(1.0, 0.3, 0.3)
		return
	# Collapsing (a need bottomed out, grace period before death).
	if h <= 0.0 or t <= 0.0:
		var what := "FOOD" if h <= 0.0 else "WATER"
		_survival_label.text = "COLLAPSING — no %s! eat/drink NOW" % what
		# Pulse red so it's impossible to miss.
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.012)
		_survival_label.modulate = Color(1.0, 0.2 + 0.2 * pulse, 0.2)
		return
	var low := 25.0
	var warns: Array[String] = []
	if h < low: warns.append("FOOD")
	if t < low: warns.append("WATER")
	if e < low: warns.append("ENERGY")
	_survival_label.text = "Hunger %d | Thirst %d | Energy %d" % [
		int(round(h)), int(round(t)), int(round(e))]
	if warns.is_empty():
		_survival_label.modulate = Color(1, 1, 1)
	else:
		_survival_label.text += "   ⚠ LOW " + " / ".join(warns)
		_survival_label.modulate = Color(1.0, 0.72, 0.2)  # amber
