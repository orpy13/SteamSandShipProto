extends Interactable
##
## DECK GUN — manned deck-mounted cannon on the foredeck.
##
## Layout (see deck_gun.tscn):
##   DeckGun (Area3D, this script)
##     ├── BaseMesh
##     ├── TraverseMount (Node3D — rotation.y = traverse_yaw)
##     │   ├── HousingMesh
##     │   └── ElevateBarrel (Node3D — rotation.x = elevate_pitch)
##     │       ├── BarrelMesh
##     │       └── Muzzle (Marker3D)
##     └── GunnerSeat (Marker3D — where the manning player locks)
##
## Authority: stays on the server. The gunner's input is RPC'd in as discrete
## traverse/elevate/fire commands; the server updates state and the
## MultiplayerSynchronizer broadcasts traverse_yaw + elevate_pitch.
##
## Mirrors the helm's "manned interactable" pattern but doesn't transfer
## multiplayer authority (the gun's discrete inputs are cheap to RPC, so we
## keep the server in charge of all state — including the reload timer).
##

# ── Tuning ────────────────────────────────────────────────────────────────────
@export var traverse_step: float = deg_to_rad(2.0)    # rad per A/D tap
@export var elevate_step: float = deg_to_rad(1.5)     # rad per W/S tap
@export var min_elevation: float = deg_to_rad(-5.0)   # depression limit
@export var max_elevation: float = deg_to_rad(60.0)   # elevation limit
@export var reload_time: float = 4.0                  # seconds between shots — long-range = deliberate
@export var muzzle_velocity: float = 80.0             # m/s — matches the bandit's shell speed
@export var spread_radians: float = deg_to_rad(0.6)   # half-angle of per-shot dispersion cone
@export var shell_target_group: String = "bandit"     # cannonball hunts this group
@export var max_ammo: int = 5                         # clip size; gun capacity

# Local signal — fires on every peer when the gun actually shoots, used by
# the gun overlay's reload bar.
signal fired

# ── Replicated state (server-authoritative; broadcast via synchronizer) ──────
var traverse_yaw: float = 0.0
var elevate_pitch: float = 0.0
var ammo: int = 0                                     # shells loaded in the gun

# Local-per-peer signal: fires when this peer's view of `ammo` changes (via
# the synchronizer on clients, or directly on the host). Drives prompt
# updates so the gunner sees their ammo count tick down in real time.
signal ammo_changed(new_value: int)

# ── Server-only state ────────────────────────────────────────────────────────
var _last_fire_time: float = -1000.0
# Per-peer cache to detect synchronized changes to `ammo` (see _process).
var _last_observed_ammo: int = -1

# ── Scene references ─────────────────────────────────────────────────────────
@onready var _traverse_mount: Node3D = $TraverseMount
@onready var _elevate_barrel: Node3D = $TraverseMount/ElevateBarrel
@onready var _muzzle: Marker3D = $TraverseMount/ElevateBarrel/Muzzle
@onready var _gunner_seat: Marker3D = $GunnerSeat


## Register in the deck_gun group so the player controller can find us and
## set the interact prompt.
func _ready() -> void:
	add_to_group("deck_gun")
	prompt_text = "Press E to man the gun"


## Every peer: apply replicated state to the visual mounts so the barrel
## tracks the gunner's intent on all screens. Also detect synchronized ammo
## changes and emit our local signal so listeners (gunner's HUD prompt) can
## refresh.
##
## Sign note: we store `elevate_pitch` as "positive = barrel up". A positive
## rotation around the mount's local X axis would tilt the barrel's +Z
## (forward) toward -Y (down). So we negate when applying.
func _process(_delta: float) -> void:
	if _traverse_mount:
		_traverse_mount.rotation.y = traverse_yaw
	if _elevate_barrel:
		_elevate_barrel.rotation.x = -elevate_pitch
	if ammo != _last_observed_ammo:
		_last_observed_ammo = ammo
		ammo_changed.emit(ammo)


## Public — used by player_controller to snap a gunner's body onto the seat.
func get_gunner_seat() -> Marker3D:
	return _gunner_seat


## Server-only entry. Three behaviours depending on context:
##   1. Player carrying a clip AND gun isn't already full → load (consume clip).
##   2. Player already mans the gun → release (free up the role).
##   3. Gun is unmanned AND player isn't the helmsman → take the gun.
##
## Loading takes priority over manning so a clip-bearer's tap doesn't
## accidentally lock them into the seat with a full clip wasted.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var player := _find_player(peer_id)

	# Priority 1: load a clip — but only when the gun is fully empty. Real
	# clip-fed guns can't accept a partial top-up; the magazine has to be
	# cleared first. Reject without consuming the clip otherwise.
	if player != null and player.has_method("is_carrying_item") and bool(player.call("is_carrying_item", "clip")):
		if ammo > 0:
			return
		super(peer_id)
		ammo = max_ammo
		player.rpc("set_carried_item", "")
		return

	# Priority 2 / 3: take or release the gunner role.
	if NetworkManager.current_gunner == peer_id:
		super(peer_id)
		NetworkManager.notify_gunner_changed.rpc(0)
	elif NetworkManager.current_gunner == 0:
		# Can't man two roles at once.
		if NetworkManager.current_helmsman == peer_id:
			return
		super(peer_id)
		NetworkManager.notify_gunner_changed.rpc(peer_id)


## Context-aware prompt for whoever's looking at the gun. Returns one of:
##   • "Press E to load clip"      — carrying a clip and gun is empty
##   • "Fire all shells first"     — carrying a clip but gun still has ammo
##   • "Press E to leave the gun"  — already manning the gun
##   • "Gun in use"                — someone else is gunning
##   • "Press E to man the gun"    — gun is free
func get_prompt(player: Node) -> String:
	var has_clip: bool = player != null and player.has_method("is_carrying_item") \
			and bool(player.call("is_carrying_item", "clip"))
	if has_clip:
		if ammo > 0:
			return "Fire all shells first (%d/%d)" % [ammo, max_ammo]
		return "Press E to load clip"
	# Resolve the player's peer id from their node name (set by NetworkManager).
	var peer_id: int = 0
	if player != null and String(player.name).is_valid_int():
		peer_id = int(player.name)
	if NetworkManager.current_gunner == peer_id and peer_id != 0:
		return "Press E to leave the gun (%d/%d)" % [ammo, max_ammo]
	if NetworkManager.current_gunner != 0:
		return "Gun in use"
	return "Press E to man the gun (%d/%d)" % [ammo, max_ammo]


## Resolve the player node for a peer id (same lookup the bunker/firebox use).
func _find_player(peer_id: int) -> Node:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return null
	var container := ship.get_node_or_null("PlayerContainer")
	if container == null:
		return null
	return container.get_node_or_null(str(peer_id))


## Gunner-input RPC: traverse one step left or right.
## `step_dir` is +1 or -1; everything else is a no-op.
@rpc("any_peer", "call_local", "reliable")
func request_traverse(step_dir: int) -> void:
	if not multiplayer.is_server():
		return
	if not _sender_is_current_gunner():
		return
	traverse_yaw = wrapf(traverse_yaw + float(step_dir) * traverse_step, -PI, PI)


## Gunner-input RPC: elevate one step up or down. Clamped to the gun's
## physical envelope so the barrel can't pass through the deck or rear up
## past 60°.
@rpc("any_peer", "call_local", "reliable")
func request_elevate(step_dir: int) -> void:
	if not multiplayer.is_server():
		return
	if not _sender_is_current_gunner():
		return
	elevate_pitch = clampf(elevate_pitch + float(step_dir) * elevate_step, min_elevation, max_elevation)


## Gunner-input RPC: pull the trigger. Ammo-gated AND reload-gated — if either
## fails we silently drop the shot. Shell spawns via the projectile director
## with target_group = "bandit".
@rpc("any_peer", "call_local", "reliable")
func request_fire() -> void:
	if not multiplayer.is_server():
		return
	if not _sender_is_current_gunner():
		return
	if ammo <= 0:
		return  # out of shells — loader needs to bring a clip
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_fire_time < reload_time:
		return
	_last_fire_time = now
	ammo -= 1
	_spawn_shell()
	# Broadcast a local "we fired" pulse to every peer so each one's gun
	# overlay can start its own reload bar in sync.
	_notify_fired.rpc()


@rpc("authority", "call_local", "reliable")
func _notify_fired() -> void:
	fired.emit()


## Compute muzzle position + velocity in world-offset coordinates, then ask
## the projectile director to spawn the shell on every peer.
##
## Coordinate dance: the gun is a child of the player ship, which lives at
## scene origin with yaw absorbed by WorldMap. We rotate the muzzle's
## HORIZONTAL offset from ship into world frame; the VERTICAL is special.
##
## Y convention: cannonballs treat `world_offset.y` as their scene-space Y
## directly (because the ship's `world_offset.y` is always 0 and WorldMap
## doesn't translate vertically). So for the spawn we use the muzzle's
## absolute scene Y, not its offset from the ship. The earlier version
## conflated the two and spawned shells at world Y == offset-above-ship
## (≈5m), which is well below the muzzle whenever terrain is above scene 0.
func _spawn_shell() -> void:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or _muzzle == null:
		return
	var ship_yaw: float = float(ship.virtual_yaw)
	var ship_offset: Vector3 = ship.world_offset

	var muzzle_scene_offset: Vector3 = _muzzle.global_position - (ship as Node3D).global_position
	var rot := Basis(Vector3.UP, ship_yaw)
	# Horizontal: rotate XZ into world frame and add the ship's world_offset.
	var muzzle_world: Vector3 = ship_offset + rot * Vector3(muzzle_scene_offset.x, 0.0, muzzle_scene_offset.z)
	# Vertical: take the muzzle's absolute scene Y.
	muzzle_world.y = _muzzle.global_position.y

	# Barrel forward direction = +Z of the muzzle (project convention; the ship
	# also uses +Z forward — see ship_controller.gd). Rotate into world frame,
	# then perturb by per-shot spread so we're not laser-accurate.
	var muzzle_forward_scene: Vector3 = _muzzle.global_transform.basis.z
	var muzzle_forward_world: Vector3 = rot * muzzle_forward_scene
	if muzzle_forward_world.length_squared() < 0.0001:
		return
	var aim_dir := _apply_spread(muzzle_forward_world.normalized(), spread_radians)
	var velocity: Vector3 = aim_dir * muzzle_velocity

	var bdir := get_tree().get_first_node_in_group("bandit_director")
	if bdir != null and bdir.has_method("spawn_cannonball"):
		bdir.spawn_cannonball(muzzle_world, velocity, shell_target_group)


## Verify the RPC's caller is the peer currently registered as gunner.
## Sender id 0 = local call on host (host-as-gunner); otherwise it must match.
func _sender_is_current_gunner() -> bool:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	return sender == NetworkManager.current_gunner and NetworkManager.current_gunner != 0


## Perturb an aim vector by a random angle inside a cone of `half_angle`
## radians. Used to give each shot a touch of dispersion so the gun isn't
## a laser. Server-side only — host applies it before broadcasting.
func _apply_spread(direction: Vector3, half_angle: float) -> Vector3:
	if half_angle <= 0.0:
		return direction
	var dir := direction.normalized()
	# Construct an orthonormal basis perpendicular to dir so we can offset
	# inside the perpendicular plane.
	var helper := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var perp1 := dir.cross(helper).normalized()
	var perp2 := dir.cross(perp1).normalized()
	var azimuth := randf() * TAU            # which way around the cone
	var polar := randf() * half_angle       # how far off-axis
	var offset := (perp1 * cos(azimuth) + perp2 * sin(azimuth)) * sin(polar)
	return (dir * cos(polar) + offset).normalized()
