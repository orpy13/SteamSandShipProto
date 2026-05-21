class_name ChartPanel
extends Control
##
## CHART PANEL — code-built navigation chart UI (Tier 2, T2.3 Slice A).
##
## Opened from a ChartTable interactable (mirrors the trade-panel pattern —
## the player_controller intercepts the interact press on a `chart_table`
## group node and calls `open()` locally instead of sending the host an
## interact RPC). Shows:
##
##   • Pre-rendered region tint map (ChartMap.build).
##   • Discovered POI pins from POIRegistry (curated mains are pre-marked).
##   • Player-placed markers from ChartState.markers.
##   • The ship's current world position as a heading-arrow.
##   • Host-only DR toggle, click-to-place markers, clear-markers.
##
## Slice B adds bearing-line rendering (already a no-op listener here),
## triangulation intersection / "Take fix", and DR estimate math when
## ChartState.dr_enabled is true.
##
## Coordinate mapping: world (x, z) ∈ [−extent, +extent] → chart UV ∈ [0, 1].
## +Z (north) is the TOP of the chart. Same convention as ChartMap and the
## TextureRegionSampler.
##

const MAP_TEXTURE_PX := 256       # resolution of the pre-rendered tint map
const PANEL_PX := 720.0           # on-screen chart side length (square)
const POI_PIN_COLOR := Color(0.95, 0.85, 0.30)
const MARKER_PIN_COLOR := Color(1.0, 0.45, 0.40)
const SHIP_COLOR := Color(0.95, 0.30, 0.30)
const DR_COLOR := Color(0.35, 0.75, 1.0)
const LAST_FIX_COLOR := Color(0.55, 0.85, 0.55)
# Distinct colours per spotter so chart readers can tell whose bearings cross.
const SPOTTER_COLORS: Array[Color] = [
	Color(0.95, 0.30, 0.30, 0.85),
	Color(0.30, 0.60, 0.95, 0.85),
	Color(0.30, 0.85, 0.45, 0.85),
	Color(0.95, 0.85, 0.30, 0.85),
	Color(0.75, 0.40, 0.95, 0.85),
	Color(0.95, 0.55, 0.20, 0.85),
]
const POI_PIN_RADIUS := 6.0
const MARKER_PIN_RADIUS := 5.0
const SHIP_ARROW_SIZE := 12.0
# Bearing lines extend this far through the POI in BOTH directions (world
# metres). World half-extent is 2 km so 4 km covers the full map.
const BEARING_LINE_LENGTH := 4500.0

var _map_rect: TextureRect
var _pin_layer: Control          # POI / marker pins rebuilt on signal change
var _bearing_layer: Control      # triangulation lines (one Line2D per entry)
var _ship_layer: Control         # ship arrow / DR estimate / uncertainty (per-frame)
var _dr_btn: CheckBox
var _marker_label: LineEdit
var _status: Label
var _placing_marker_btn: Button
var _bearing_poi: OptionButton
var _bearing_deg: SpinBox
var _take_fix_btn: Button
var _world_extent: float
var _placing_marker: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("chart_panel")
	_world_extent = Regions.WORLD_HALF_EXTENT + Regions.BORDER_BAND
	_build_ui()
	_refresh_pins()
	_refresh_dr_button()
	visible = false
	ChartState.markers_changed.connect(_refresh_pins)
	ChartState.discovered_changed.connect(_on_discovered_changed)
	ChartState.bearing_lines_changed.connect(_refresh_bearings)
	ChartState.last_fix_changed.connect(_refresh_bearings)  # take-fix button enable state
	ChartState.dr_mode_changed.connect(_refresh_dr_button)
	# DR-mode label updates depend on host status; clients can't flip it.
	NetworkManager.player_list_changed.connect(func(_p): _refresh_dr_button())


func _build_ui() -> void:
	# Dim full-screen backdrop so the chart reads as a modal.
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.55)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(bg)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(centre)

	var panel := PanelContainer.new()
	centre.add_child(panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var title := Label.new()
	title.text = "CHART"
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	v.add_child(title)

	# Map + overlay layers stack inside a fixed-size Control.
	var map_holder := Control.new()
	map_holder.custom_minimum_size = Vector2(PANEL_PX, PANEL_PX)
	v.add_child(map_holder)

	_map_rect = TextureRect.new()
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_map_rect.size = Vector2(PANEL_PX, PANEL_PX)
	_map_rect.texture = ChartMap.build(MAP_TEXTURE_PX, _world_extent)
	_map_rect.mouse_filter = Control.MOUSE_FILTER_PASS
	_map_rect.gui_input.connect(_on_map_input)
	map_holder.add_child(_map_rect)

	# Layer order matters: bearing lines under pins; ship/DR overlay on top.
	_bearing_layer = Control.new()
	_bearing_layer.size = Vector2(PANEL_PX, PANEL_PX)
	_bearing_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_holder.add_child(_bearing_layer)

	_pin_layer = Control.new()
	_pin_layer.size = Vector2(PANEL_PX, PANEL_PX)
	_pin_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_holder.add_child(_pin_layer)

	_ship_layer = Control.new()
	_ship_layer.size = Vector2(PANEL_PX, PANEL_PX)
	_ship_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_holder.add_child(_ship_layer)

	# Marker tools row.
	var controls := HBoxContainer.new()
	v.add_child(controls)
	_placing_marker_btn = Button.new()
	_placing_marker_btn.text = "Place marker (click map)"
	_placing_marker_btn.toggle_mode = true
	_placing_marker_btn.toggled.connect(_on_placing_toggled)
	controls.add_child(_placing_marker_btn)
	_marker_label = LineEdit.new()
	_marker_label.placeholder_text = "Label"
	_marker_label.custom_minimum_size = Vector2(140, 0)
	controls.add_child(_marker_label)
	var clear_btn := Button.new()
	clear_btn.text = "Clear markers"
	clear_btn.pressed.connect(_on_clear_markers)
	controls.add_child(clear_btn)

	# Bearing entry row — the chart player types in what the telescope
	# spotter calls out over voice.
	var bearing_row := HBoxContainer.new()
	v.add_child(bearing_row)
	var blbl := Label.new()
	blbl.text = "Bearing:"
	bearing_row.add_child(blbl)
	_bearing_poi = OptionButton.new()
	_bearing_poi.custom_minimum_size = Vector2(160, 0)
	bearing_row.add_child(_bearing_poi)
	_bearing_deg = SpinBox.new()
	_bearing_deg.min_value = 0.0
	_bearing_deg.max_value = 359.9
	_bearing_deg.step = 0.1
	_bearing_deg.custom_minimum_size = Vector2(110, 0)
	bearing_row.add_child(_bearing_deg)
	var dlbl := Label.new()
	dlbl.text = "°"
	bearing_row.add_child(dlbl)
	var add_b := Button.new()
	add_b.text = "Add"
	add_b.pressed.connect(_on_add_bearing)
	bearing_row.add_child(add_b)
	_take_fix_btn = Button.new()
	_take_fix_btn.text = "Take fix (2+)"
	_take_fix_btn.pressed.connect(_on_take_fix)
	bearing_row.add_child(_take_fix_btn)
	var clear_b := Button.new()
	clear_b.text = "Clear lines"
	clear_b.pressed.connect(_on_clear_bearings)
	bearing_row.add_child(clear_b)
	_refresh_bearing_poi_options()

	_dr_btn = CheckBox.new()
	_dr_btn.text = "DR enabled (host-only)"
	_dr_btn.toggled.connect(_on_dr_toggled)
	v.add_child(_dr_btn)

	var bottom := HBoxContainer.new()
	v.add_child(bottom)
	_status = Label.new()
	_status.text = "Esc or Close to put the chart away."
	bottom.add_child(_status)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(close)
	bottom.add_child(close_btn)


# ── Open / close ─────────────────────────────────────────────────────────────

## Called by player_controller when E is pressed on a chart_table group node.
func open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_pins()
	_refresh_bearings()
	_refresh_dr_button()
	_refresh_bearing_poi_options()


func close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_placing_marker = false
	if _placing_marker_btn != null:
		_placing_marker_btn.set_pressed_no_signal(false)


## Esc closes — same convenience as the trade panel.
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()


# ── Coord conversion ─────────────────────────────────────────────────────────

func _world_to_chart(world_pos: Vector3) -> Vector2:
	var span := 2.0 * _world_extent
	var u := clampf((world_pos.x + _world_extent) / span, 0.0, 1.0)
	# Flip Y so +Z (north) sits at the top of the chart.
	var v := clampf(1.0 - (world_pos.z + _world_extent) / span, 0.0, 1.0)
	return Vector2(u * PANEL_PX, v * PANEL_PX)


func _chart_to_world(local: Vector2) -> Vector3:
	var span := 2.0 * _world_extent
	var u := clampf(local.x / PANEL_PX, 0.0, 1.0)
	var v := clampf(local.y / PANEL_PX, 0.0, 1.0)
	return Vector3(u * span - _world_extent, 0.0,
			(1.0 - v) * span - _world_extent)


# ── Pin rendering ────────────────────────────────────────────────────────────

func _refresh_pins() -> void:
	for c in _pin_layer.get_children():
		c.queue_free()
	# Discovered POIs (curated settlements are pre-discovered).
	for s in POIRegistry.all_settlements():
		var id := String(s["id"])
		if not ChartState.is_discovered(id):
			continue
		_add_pin(_world_to_chart(s["world_pos"]),
				String(s["display_name"]),
				POI_PIN_COLOR, POI_PIN_RADIUS)
	# Player-placed markers.
	for m in ChartState.markers:
		_add_pin(_world_to_chart(m["world_pos"]),
				String(m.get("label", "")),
				m.get("color", MARKER_PIN_COLOR), MARKER_PIN_RADIUS)


func _add_pin(pos: Vector2, label: String, color: Color, radius: float) -> void:
	var dot := ColorRect.new()
	dot.color = color
	dot.size = Vector2(radius * 2.0, radius * 2.0)
	dot.position = pos - Vector2(radius, radius)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pin_layer.add_child(dot)
	if not label.is_empty():
		var lbl := Label.new()
		lbl.text = label
		lbl.add_theme_color_override("font_color", Color(1, 1, 1))
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0))
		lbl.add_theme_constant_override("outline_size", 3)
		lbl.position = pos + Vector2(radius + 3.0, -10.0)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_pin_layer.add_child(lbl)


# ── Ship arrow (continuous re-position) ──────────────────────────────────────

## Per-frame ship / DR / last-fix overlay. Slice B branches on
## ChartState.dr_enabled and the presence of a fix:
##   • DR on,  fix present  → draw the *drifted* estimate arrow + uncertainty
##                            circle. Real position is hidden.
##   • DR on,  no fix yet   → real ship arrow (no error to drift from).
##   • DR off, fix present  → static last-fix marker only, no live arrow.
##   • DR off, no fix yet   → no arrow at all (the chart is truly blind —
##                            triangulate to populate the first fix).
func _process(_delta: float) -> void:
	if not visible:
		return
	for c in _ship_layer.get_children():
		c.queue_free()
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not "world_offset" in ship:
		return
	var ship_pos: Vector3 = ship.world_offset
	var ship_yaw := float(ship.virtual_yaw)
	var has_fix := not ChartState.last_fix.is_empty()

	if ChartState.dr_enabled:
		if has_fix:
			var now := GameState.world_time()
			var est := ChartState.dr_estimate(now, ship_pos)
			var rad_m := ChartState.dr_uncertainty_radius(now)
			_add_uncertainty_circle(_world_to_chart(est), rad_m)
			_add_ship_arrow(_world_to_chart(est), ship_yaw, DR_COLOR)
		else:
			# No fix → estimate IS the truth (no drift accumulated yet).
			_add_ship_arrow(_world_to_chart(ship_pos), ship_yaw, SHIP_COLOR)
	# Static last-fix marker (always drawn when a fix exists; doubles as the
	# only position info in hard mode).
	if has_fix:
		_add_last_fix_marker(_world_to_chart(ChartState.last_fix["world_pos"]))


func _add_ship_arrow(pos: Vector2, yaw: float, color: Color = SHIP_COLOR) -> void:
	var s := SHIP_ARROW_SIZE
	var poly := Polygon2D.new()
	# Triangle tip at -Y (chart north). Body splays back to either side.
	poly.polygon = PackedVector2Array([
		Vector2(0.0, -s),
		Vector2(s * 0.6, s * 0.6),
		Vector2(-s * 0.6, s * 0.6),
	])
	poly.color = color
	poly.position = pos
	# virtual_yaw rotates the world by -yaw under the ship; on the chart we
	# want the arrow to point along the ship's heading. World +Z = north;
	# the polygon's tip is at -Y (chart north). A yaw of 0 means facing
	# north (no rotation); positive yaw turns right (east). Polygon2D
	# rotation positive = clockwise visually, which matches.
	poly.rotation = yaw
	_ship_layer.add_child(poly)


## A small "X" at the last fix, in fix-green. Persistent reference point;
## doubles as the only position cue in hard mode.
func _add_last_fix_marker(pos: Vector2) -> void:
	var s := 7.0
	var l1 := Line2D.new()
	l1.points = PackedVector2Array([pos + Vector2(-s, -s), pos + Vector2(s, s)])
	l1.width = 2.0
	l1.default_color = LAST_FIX_COLOR
	_ship_layer.add_child(l1)
	var l2 := Line2D.new()
	l2.points = PackedVector2Array([pos + Vector2(-s, s), pos + Vector2(s, -s)])
	l2.width = 2.0
	l2.default_color = LAST_FIX_COLOR
	_ship_layer.add_child(l2)


## Dashed-ish circle drawn from line segments — Godot has no circle primitive
## on Control nodes. Radius is converted from world metres to chart pixels.
func _add_uncertainty_circle(centre: Vector2, world_radius_m: float) -> void:
	if world_radius_m <= 0.5:
		return
	var span := 2.0 * _world_extent
	var px_radius: float = world_radius_m / span * PANEL_PX
	const SEGMENTS := 36
	var pts := PackedVector2Array()
	pts.resize(SEGMENTS + 1)
	for i in range(SEGMENTS + 1):
		var a := float(i) / float(SEGMENTS) * TAU
		pts[i] = centre + Vector2(cos(a), sin(a)) * px_radius
	var line := Line2D.new()
	line.points = pts
	line.width = 1.5
	line.default_color = Color(DR_COLOR.r, DR_COLOR.g, DR_COLOR.b, 0.55)
	_ship_layer.add_child(line)


# ── Bearing lines ────────────────────────────────────────────────────────────

func _refresh_bearings() -> void:
	for c in _bearing_layer.get_children():
		c.queue_free()
	for i in range(ChartState.bearing_lines.size()):
		_add_bearing_line(ChartState.bearing_lines[i])
	_refresh_take_fix_button()


func _add_bearing_line(entry: Dictionary) -> void:
	var poi := POIRegistry.get_settlement(String(entry["poi_id"]))
	if poi.is_empty():
		return
	var origin: Vector3 = poi["world_pos"]
	# Line passes through the POI along the back-azimuth (bearing+180°) and
	# the forward azimuth — we draw both directions so the chart player can
	# see the intersection point even when it falls beyond the spotter.
	var t := deg_to_rad(float(entry["bearing_deg"]))
	var dir := Vector3(-sin(t), 0.0, -cos(t))
	var a := _world_to_chart(origin - dir * BEARING_LINE_LENGTH)
	var b := _world_to_chart(origin + dir * BEARING_LINE_LENGTH)
	var line := Line2D.new()
	line.points = PackedVector2Array([a, b])
	line.width = 2.0
	line.default_color = _spotter_color(int(entry.get("placed_by", 0)))
	_bearing_layer.add_child(line)


func _spotter_color(peer_id: int) -> Color:
	if peer_id <= 0:
		return SPOTTER_COLORS[0]
	return SPOTTER_COLORS[peer_id % SPOTTER_COLORS.size()]


func _refresh_take_fix_button() -> void:
	if _take_fix_btn == null:
		return
	_take_fix_btn.disabled = ChartState.bearing_lines.size() < 2


# ── POI dropdown options ─────────────────────────────────────────────────────
# Rebuilt whenever discovery state changes — undiscovered POIs shouldn't show
# up in the bearing-entry list (you can't enter a bearing for a POI you've
# never heard of).
func _refresh_bearing_poi_options() -> void:
	if _bearing_poi == null:
		return
	var prev_id := ""
	if _bearing_poi.item_count > 0 and _bearing_poi.selected >= 0:
		prev_id = String(_bearing_poi.get_item_metadata(_bearing_poi.selected))
	_bearing_poi.clear()
	for s in POIRegistry.all_settlements():
		var id := String(s["id"])
		if not ChartState.is_discovered(id):
			continue
		_bearing_poi.add_item(String(s["display_name"]))
		_bearing_poi.set_item_metadata(_bearing_poi.item_count - 1, id)
		if id == prev_id:
			_bearing_poi.select(_bearing_poi.item_count - 1)


func _on_discovered_changed() -> void:
	_refresh_pins()
	_refresh_bearing_poi_options()


# ── Inputs ───────────────────────────────────────────────────────────────────

func _on_placing_toggled(pressed: bool) -> void:
	_placing_marker = pressed
	if pressed:
		_status.text = "Click anywhere on the chart to drop a marker."
	else:
		_status.text = "Esc or Close to put the chart away."


func _on_map_input(event: InputEvent) -> void:
	if not _placing_marker:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var local := mb.position    # relative to _map_rect because gui_input
	var world := _chart_to_world(local)
	var label := _marker_label.text.strip_edges()
	if label.is_empty():
		label = "Marker"
	ChartState.request_add_marker.rpc_id(1, world, label, MARKER_PIN_COLOR)
	_placing_marker = false
	_placing_marker_btn.set_pressed_no_signal(false)
	_status.text = "Marker placed at (%d, %d)." % [int(world.x), int(world.z)]


func _on_clear_markers() -> void:
	ChartState.request_clear_markers.rpc_id(1)


func _on_add_bearing() -> void:
	if _bearing_poi == null or _bearing_poi.item_count == 0:
		_status.text = "No discovered POIs to triangulate against."
		return
	var idx := _bearing_poi.selected
	if idx < 0:
		idx = 0
	var poi_id := String(_bearing_poi.get_item_metadata(idx))
	var deg: float = float(_bearing_deg.value)
	ChartState.request_add_bearing.rpc_id(1, poi_id, deg)
	_status.text = "Added bearing %.1f° from %s." % [deg, _bearing_poi.get_item_text(idx)]


func _on_clear_bearings() -> void:
	ChartState.request_clear_bearing_lines.rpc_id(1)


func _on_take_fix() -> void:
	if ChartState.bearing_lines.size() < 2:
		_status.text = "Need at least two bearings to triangulate."
		return
	ChartState.request_take_fix.rpc_id(1)
	_status.text = "Fix requested — DR error reset at the intersection."


func _on_dr_toggled(value: bool) -> void:
	if not multiplayer.is_server():
		# Clients can't flip — snap the button back to authoritative state.
		_refresh_dr_button()
		return
	ChartState.request_set_dr_enabled.rpc_id(1, value)


func _refresh_dr_button() -> void:
	if _dr_btn == null:
		return
	_dr_btn.set_pressed_no_signal(ChartState.dr_enabled)
	# Only the host can flip — clients see it as a read-only indicator.
	_dr_btn.disabled = not multiplayer.is_server()
