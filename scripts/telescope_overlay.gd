class_name TelescopeOverlay
extends Control
##
## TELESCOPE OVERLAY — code-built HUD shown while the local player is at the
## telescope (Tier 2, T2.3 Slice B).
##
## Mirrors the gun_overlay pattern: instantiated once under `UILayer` by
## `main.gd`, hidden by default, visibility flipped on the local
## `observer_changed` signal. Reads:
##
##   • Telescope.bearing_updated  → live "BRG 047.3°" readout.
##   • Telescope.spot_result      → latest sighting line ("Rust Pump @ 047°,
##                                  1.2 km"). The spotter reads this out
##                                  over voice; the chart player types it
##                                  into the chart.
##   • Telescope.spot_failed      → "Nothing in scope."
##
## Crosshair is two thin centered lines (cheap; no texture needed).
##

const CROSSHAIR_COLOR := Color(1.0, 0.9, 0.4, 0.85)
const READOUT_COLOR := Color(1.0, 0.95, 0.85)

var _bearing_label: Label
var _spot_label: Label
var _telescope_ref: Node  # cached subscription target


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("telescope_overlay")
	_build_ui()
	visible = false
	NetworkManager.observer_changed.connect(_on_observer_changed)
	# Already-observer at scene start? (shouldn't happen for v1 — added on
	# join — but guard anyway.)
	if NetworkManager.current_observer == multiplayer.get_unique_id() \
			and multiplayer.get_unique_id() != 0:
		_attach()


func _build_ui() -> void:
	# Crosshair: two thin lines at screen centre.
	var ch_h := ColorRect.new()
	ch_h.color = CROSSHAIR_COLOR
	ch_h.size = Vector2(48, 1)
	ch_h.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ch_h.offset_left = -24.0
	ch_h.offset_right = 24.0
	ch_h.offset_top = 0.0
	ch_h.offset_bottom = 1.0
	ch_h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ch_h)
	var ch_v := ColorRect.new()
	ch_v.color = CROSSHAIR_COLOR
	ch_v.size = Vector2(1, 48)
	ch_v.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	ch_v.offset_left = 0.0
	ch_v.offset_right = 1.0
	ch_v.offset_top = -24.0
	ch_v.offset_bottom = 24.0
	ch_v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ch_v)

	# Bearing readout — top centre, big, monospace.
	_bearing_label = Label.new()
	_bearing_label.text = "BRG ---.-°"
	_bearing_label.add_theme_color_override("font_color", READOUT_COLOR)
	_bearing_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_bearing_label.add_theme_constant_override("outline_size", 4)
	_bearing_label.add_theme_font_size_override("font_size", 28)
	_bearing_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_bearing_label.position = Vector2(-90, 40)
	_bearing_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bearing_label)

	# Spot result — bottom centre, persistent until next click or unmount.
	_spot_label = Label.new()
	_spot_label.text = ""
	_spot_label.add_theme_color_override("font_color", READOUT_COLOR)
	_spot_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_spot_label.add_theme_constant_override("outline_size", 4)
	_spot_label.add_theme_font_size_override("font_size", 22)
	_spot_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_spot_label.position = Vector2(-220, -90)
	_spot_label.custom_minimum_size = Vector2(440, 0)
	_spot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spot_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_spot_label)


# ── Mount / unmount on observer-role change ──────────────────────────────────

func _on_observer_changed(peer_id: int) -> void:
	var local := multiplayer.get_unique_id()
	if local == 0:
		# Solo-editor / pre-network — no role transitions matter.
		visible = false
		_detach()
		return
	if peer_id == local:
		_attach()
	else:
		_detach()


func _attach() -> void:
	visible = true
	_spot_label.text = ""
	var telescope := get_tree().get_first_node_in_group("telescope")
	if telescope == null:
		return
	_telescope_ref = telescope
	if not telescope.bearing_updated.is_connected(_on_bearing_updated):
		telescope.bearing_updated.connect(_on_bearing_updated)
	if not telescope.spot_result.is_connected(_on_spot_result):
		telescope.spot_result.connect(_on_spot_result)
	if not telescope.spot_failed.is_connected(_on_spot_failed):
		telescope.spot_failed.connect(_on_spot_failed)


func _detach() -> void:
	visible = false
	if _telescope_ref != null and is_instance_valid(_telescope_ref):
		if _telescope_ref.bearing_updated.is_connected(_on_bearing_updated):
			_telescope_ref.bearing_updated.disconnect(_on_bearing_updated)
		if _telescope_ref.spot_result.is_connected(_on_spot_result):
			_telescope_ref.spot_result.disconnect(_on_spot_result)
		if _telescope_ref.spot_failed.is_connected(_on_spot_failed):
			_telescope_ref.spot_failed.disconnect(_on_spot_failed)
	_telescope_ref = null


# ── Readout updates ──────────────────────────────────────────────────────────

func _on_bearing_updated(bearing_deg: float) -> void:
	_bearing_label.text = "BRG %05.1f°" % bearing_deg


func _on_spot_result(_poi_id: String, display_name: String,
		bearing_deg: float, range_m: float) -> void:
	# Range pretty-printed: km if >= 1000m, else m.
	var range_text := "%.0f m" % range_m if range_m < 1000.0 else "%.2f km" % (range_m / 1000.0)
	_spot_label.text = "%s — bearing %.1f° — %s" % [display_name, bearing_deg, range_text]


func _on_spot_failed(reason: String) -> void:
	_spot_label.text = reason
