extends Interactable
##
## TELESCOPE — manned deck spy-glass for navigation triangulation
## (Tier 2, T2.3 Slice B).
##
## Mirrors the deck gun's "manned interactable" pattern: server-authoritative
## traverse + elevate, client RPCs in discrete steps, no authority transfer.
## The active observer is tracked on `NetworkManager.current_observer`
## (parallels current_gunner) so player_controller can swap to the telescope
## camera and lock movement.
##
## Spotting workflow (gameplay):
##   1. Observer mans the telescope (E), camera swaps to the scope, mouse
##      look freezes (same as the gun).
##   2. WASD traverses / elevates the scope (cheap reliable RPCs).
##      The telescope_overlay shows the live world bearing in degrees.
##   3. Observer points at a POI and clicks (Fire). request_spot() runs on
##      the host: finds the nearest discovered POI inside the crosshair
##      cone and within range (range falls off with sandstorm intensity
##      and at night). The host broadcasts the result back to the spotter
##      via `_notify_spot_result` — POI name + exact bearing. The spotter
##      reads it out over voice; the chart player enters it.
##   4. Hitting a NEW POI (not yet in ChartState.discovered_pois) also flags
##      it discovered — this is how minor POIs come on-chart in the future.
##
## Layout (see telescope.tscn):
##   Telescope (Area3D, this script)
##     ├── BaseMesh
##     ├── TraverseMount (Node3D — rotation.y = traverse_yaw)
##     │   ├── PostMesh
##     │   └── ElevateBarrel (Node3D — rotation.x = elevate_pitch)
##     │       ├── TubeMesh
##     │       └── TelescopeCamera (Camera3D, narrow FOV)
##     └── OperatorSeat (Marker3D — where the manning player locks)
##

# ── Tuning ────────────────────────────────────────────────────────────────────
## Held-key turn rate (rad/sec). Hold A/D/W/S for a continuous sweep; mouse
## motion adds on top for fine aim.
@export var key_aim_rate: float = deg_to_rad(45.0)
@export var min_elevation: float = deg_to_rad(-30.0)
@export var max_elevation: float = deg_to_rad(45.0)
## Half-angle of the spotting cone. POIs within this angle of the crosshair
## (in world bearing space) are candidates for a successful spot.
@export var spot_cone_deg: float = 3.0
## Effectively infinite — if you can see a POI through the scope, you can
## spot it. Storm/night degrade visibility *visually* (fog occludes,
## night dims), so we don't gate spotting on range as well. Set to a finite
## large number rather than INF so it survives serialisation.
@export var max_range: float = 1.0e9

# Local signal — fires on the spotter peer after a successful spot.
signal spot_result(poi_id: String, display_name: String, bearing_deg: float, range_m: float)
# Local signal — fires on the spotter peer when a spot returns nothing.
signal spot_failed(reason: String)
# Local signal: live world bearing in degrees. Refreshed each _process tick on
# every peer (since traverse_yaw is replicated). The overlay binds to this.
signal bearing_updated(bearing_deg: float)

# ── Replicated state (server-authoritative; broadcast via synchronizer) ──────
var traverse_yaw: float = 0.0
var elevate_pitch: float = 0.0

# ── Scene references ─────────────────────────────────────────────────────────
@onready var _traverse_mount: Node3D = $TraverseMount
@onready var _elevate_barrel: Node3D = $TraverseMount/ElevateBarrel
@onready var _operator_seat: Marker3D = $OperatorSeat


func _ready() -> void:
	add_to_group("telescope")
	prompt_text = "Press E to use telescope"


## Every peer applies replicated state to visuals and emits the live bearing
## so the spotter's overlay can read it.
func _process(_delta: float) -> void:
	if _traverse_mount:
		_traverse_mount.rotation.y = traverse_yaw
	if _elevate_barrel:
		# Sign mirrors deck_gun: "positive = barrel up".
		_elevate_barrel.rotation.x = -elevate_pitch
	bearing_updated.emit(current_world_bearing_deg())


## Public — current crosshair bearing in world frame. Combines the ship's
## heading and the telescope's local traverse. 0° = north (+Z), 90° = east.
func current_world_bearing_deg() -> float:
	var ship := get_tree().get_first_node_in_group("ship")
	var ship_yaw := 0.0
	if ship != null and "virtual_yaw" in ship:
		ship_yaw = float(ship.virtual_yaw)
	return wrapf(rad_to_deg(ship_yaw + traverse_yaw), 0.0, 360.0)


## Public — used by player_controller to snap the observer onto the seat.
func get_operator_seat() -> Marker3D:
	return _operator_seat


## Server-only mount toggle. No clip / carry logic — telescope is purely an
## observation post.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	if NetworkManager.current_observer == peer_id:
		super(peer_id)
		NetworkManager.notify_observer_changed.rpc(0)
		return
	if NetworkManager.current_observer != 0:
		return   # someone else already on it
	# Don't double-book — telescope is incompatible with helm/gun.
	if NetworkManager.current_helmsman == peer_id:
		return
	if NetworkManager.current_gunner == peer_id:
		return
	super(peer_id)
	NetworkManager.notify_observer_changed.rpc(peer_id)


## Context-aware prompt.
func get_prompt(player: Node) -> String:
	var peer_id: int = 0
	if player != null and String(player.name).is_valid_int():
		peer_id = int(player.name)
	if NetworkManager.current_observer == peer_id and peer_id != 0:
		return "Press E to leave the telescope"
	if NetworkManager.current_observer != 0:
		return "Telescope in use"
	return "Press E to use telescope"


# ── Observer input RPCs (sender must be current observer) ────────────────────

## Continuous aim delta — sent each physics tick by the observer. Combines
## mouse motion + held-key sweeps into a single yaw/pitch delta. Unreliable
## so we don't flood the wire at 60 Hz; a dropped packet just delays the
## rotation by one tick.
@rpc("any_peer", "call_local", "unreliable")
func request_aim_delta(yaw_delta: float, pitch_delta: float) -> void:
	if not multiplayer.is_server():
		return
	if not _sender_is_current_observer():
		return
	# Anti-cheat clamp — no single tick should swing more than ~10°.
	const MAX_TICK := 0.18
	yaw_delta = clampf(yaw_delta, -MAX_TICK, MAX_TICK)
	pitch_delta = clampf(pitch_delta, -MAX_TICK, MAX_TICK)
	traverse_yaw = wrapf(traverse_yaw + yaw_delta, -PI, PI)
	elevate_pitch = clampf(elevate_pitch + pitch_delta, min_elevation, max_elevation)


## Server-side spot: find the nearest discovered POI inside the crosshair
## cone and within effective range. Returns nothing if the cone is empty or
## the conditions (storm / night) shrunk range past the candidates.
##
## If the hit POI was not yet in `ChartState.discovered_pois`, it's marked
## discovered (so minor POIs come on-chart this way once they exist). For
## v1 all curated settlements are pre-discovered, so this is a no-op today.
@rpc("any_peer", "call_local", "reliable")
func request_spot() -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if NetworkManager.current_observer != sender:
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not "world_offset" in ship:
		return
	var ship_pos: Vector3 = ship.world_offset
	var crosshair_deg := current_world_bearing_deg()
	var cone := spot_cone_deg
	var best_id := ""
	var best_name := ""
	var best_range := INF
	var best_bearing := 0.0
	for s in POIRegistry.all_settlements():
		var pos: Vector3 = s["world_pos"]
		var delta_x := pos.x - ship_pos.x
		var delta_z := pos.z - ship_pos.z
		var r := sqrt(delta_x * delta_x + delta_z * delta_z)
		if r > max_range:
			continue
		# Bearing from ship to POI in degrees clockwise from north (+Z).
		var poi_bearing := wrapf(rad_to_deg(atan2(delta_x, delta_z)), 0.0, 360.0)
		var d := absf(_signed_angle_diff(crosshair_deg, poi_bearing))
		if d > cone:
			continue
		if r < best_range:
			best_range = r
			best_id = String(s["id"])
			best_name = String(s["display_name"])
			best_bearing = poi_bearing
	if best_id.is_empty():
		_notify_spot_failed.rpc_id(sender, "Nothing in scope.")
		return
	# Mark discovered (idempotent — already-discovered POIs are skipped).
	ChartState.host_mark_discovered(best_id)
	_notify_spot_result.rpc_id(sender, best_id, best_name, best_bearing, best_range)


## Signed difference of two compass bearings in degrees, wrapped to [−180, 180].
static func _signed_angle_diff(a_deg: float, b_deg: float) -> float:
	var d := wrapf(b_deg - a_deg, -180.0, 180.0)
	return d


## Server-side sender validation, mirroring deck_gun's _sender_is_current_gunner.
func _sender_is_current_observer() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return NetworkManager.current_observer == sender


@rpc("authority", "reliable")
func _notify_spot_result(poi_id: String, display_name: String,
		bearing_deg: float, range_m: float) -> void:
	spot_result.emit(poi_id, display_name, bearing_deg, range_m)


@rpc("authority", "reliable")
func _notify_spot_failed(reason: String) -> void:
	spot_failed.emit(reason)
