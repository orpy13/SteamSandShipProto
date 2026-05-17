extends Control
##
## GUN OVERLAY — HUD elements visible only while *this* peer is manning the
## deck gun. Three minimal pieces:
##
##   • Crosshair       — centred "+" reticle (two ColorRects)
##   • Elevation       — barrel pitch in degrees, e.g. "+12°"
##   • Reload bar      — empty just after firing, fills to full over reload_time
##
## No lead indicator, no trajectory preview — the long-range tuning means
## players should learn the ballistics through practice, not from arrows on
## screen. The elevation readout is the one "magic info" element here, and it
## earns its keep because you mentally calibrate ranges by it.
##
## Lifecycle:
##   _ready: subscribe to NetworkManager.gunner_changed
##   On gunner take: connect to the gun's `fired` signal, show overlay
##   On gun.fired:   reset reload_remaining to reload_total (bar drops to 0)
##   _process:       decay reload_remaining, update bar value + elevation text
##

@onready var _reload_bar: ProgressBar = $ReloadBar
@onready var _elevation_label: Label = $ElevationLabel

var _gun: Node = null
var _reload_remaining: float = 0.0
var _reload_total: float = 1.0


## Hidden by default until we become the gunner.
func _ready() -> void:
	visible = false
	NetworkManager.gunner_changed.connect(_on_gunner_changed)


## Show / hide the overlay as we take / leave the gun. Subscribe to the gun's
## `fired` signal so we can drop the reload bar each time a shot lands.
func _on_gunner_changed(peer_id: int) -> void:
	var is_local := peer_id != 0 and peer_id == multiplayer.get_unique_id()
	visible = is_local
	if is_local:
		_gun = get_tree().get_first_node_in_group("deck_gun")
		if _gun != null and "reload_time" in _gun:
			_reload_total = float(_gun.reload_time)
		if _gun != null and _gun.has_signal("fired") and not _gun.fired.is_connected(_on_gun_fired):
			_gun.fired.connect(_on_gun_fired)
		# Assume ready on entry — a stale reload from a previous gunner is rare
		# enough that we don't bother replicating `_last_fire_time` for it.
		_reload_remaining = 0.0
	elif _gun != null and is_instance_valid(_gun):
		if _gun.has_signal("fired") and _gun.fired.is_connected(_on_gun_fired):
			_gun.fired.disconnect(_on_gun_fired)
		_gun = null


## Drop the reload bar to empty; _process refills it.
func _on_gun_fired() -> void:
	_reload_remaining = _reload_total


## Each frame: count down the reload timer, update the bar, update the
## elevation readout from the gun's replicated `elevate_pitch`.
func _process(delta: float) -> void:
	if not visible:
		return
	if _reload_remaining > 0.0:
		_reload_remaining = maxf(0.0, _reload_remaining - delta)
	_reload_bar.value = 1.0 - (_reload_remaining / maxf(_reload_total, 0.001))
	if _gun != null and "elevate_pitch" in _gun:
		var degrees := rad_to_deg(float(_gun.elevate_pitch))
		_elevation_label.text = "%+d°" % int(round(degrees))
