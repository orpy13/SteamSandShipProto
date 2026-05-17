extends CharacterBody3D
##
## PLAYER CONTROLLER — one instance per crew member.
##
## Spawned by NetworkManager as a child of `Ship/PlayerContainer`. The node
## name is the peer_id (see network_manager.spawn_player_for_peer).
##
## Three modes of operation:
##
##   1. Local non-helmsman:  walk around the deck, look with the mouse, press E
##                           to interact with whatever the camera ray is on.
##   2. Local helmsman:      body locks in place at the wheel; movement input
##                           is intercepted by the ship_controller instead.
##   3. Remote player:       camera disabled, mouse-look ignored. Position and
##                           rotation come in via MultiplayerSynchronizer.
##
## Movement happens in ship-local space — because the ship never moves in world
## space (see ship_controller.gd), we don't need vehicle-velocity compensation.
##

signal interact_prompt_changed(text: String)

@export var MOVEMENT_SPEED: float = 5.0
@export var JUMP_VELOCITY: float = 4.5
@export var MOUSE_SENSITIVITY: float = 0.002
@export var GRAVITY: float = 12.0

# Distinct capsule colours so each peer is visually identifiable on deck.
const PEER_COLORS: Array[Color] = [
	Color(0.95, 0.30, 0.30),
	Color(0.30, 0.60, 0.95),
	Color(0.30, 0.85, 0.45),
	Color(0.95, 0.85, 0.30),
	Color(0.75, 0.40, 0.95),
	Color(0.95, 0.55, 0.20),
]

@onready var _camera: Camera3D = $SpringArm3D/Camera3D
@onready var _spring: SpringArm3D = $SpringArm3D
@onready var _interact_ray: RayCast3D = $InteractRay
@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _carry_socket: Node3D = $CarrySocket

var _yaw: float = 0.0           # camera yaw — body rotation stays at identity
var _pitch: float = 0.0
var _current_interactable: Interactable = null
var _last_emitted_prompt: String = ""  # to debounce per-frame prompt refreshes
var _is_helmsman: bool = false  # true while *this* player is driving the ship
var _is_gunner: bool = false    # true while *this* player is manning the deck gun

# Items carried in the hand. Empty string = nothing. Replicated via RPC so
# remote players see the visual prop in our socket.
var carried_item_type: String = ""
var _carried_visual: Node3D = null

# Screen-shake state (local only — driven by ship.damage_taken).
var _shake_strength: float = 0.0  # decays toward 0 each frame


## Capture mouse, enable our camera (only on the local player), and subscribe
## to helm changes. Initial state may already have us as helmsman — e.g. if we
## just took the wheel and the player node respawned for some reason.
func _ready() -> void:
	if is_multiplayer_authority():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_camera.current = true
	else:
		_camera.current = false
	NetworkManager.helmsman_changed.connect(_on_helmsman_changed)
	NetworkManager.gunner_changed.connect(_on_gunner_changed)
	_is_helmsman = NetworkManager.current_helmsman != 0 \
			and NetworkManager.current_helmsman == multiplayer.get_unique_id()
	_is_gunner = NetworkManager.current_gunner != 0 \
			and NetworkManager.current_gunner == multiplayer.get_unique_id()
	if _is_helmsman:
		_emit_prompt("Press E to release the helm")
	elif _is_gunner:
		_refresh_gunner_prompt()
	# Subscribe to ship damage events for local screen shake. Fires on every
	# peer (the ship's damage signal is RPC-broadcast), so each crew member
	# feels the hit on their own screen.
	var ship := get_tree().get_first_node_in_group("ship")
	if ship and ship.has_signal("damage_taken") and not ship.damage_taken.is_connected(_on_ship_damage_taken):
		ship.damage_taken.connect(_on_ship_damage_taken)


## Update local helm-locked flag when the helmsman role changes hands.
func _on_helmsman_changed(peer_id: int) -> void:
	if not is_multiplayer_authority():
		return
	var was := _is_helmsman
	_is_helmsman = peer_id != 0 and peer_id == multiplayer.get_unique_id()
	if _is_helmsman:
		_emit_prompt("Press E to release the helm")
	elif was:
		# Just stepped down. Clear the prompt unless we're already eyeing something else.
		var prompt := ""
		if _current_interactable != null:
			prompt = _current_interactable.get_prompt(self)
		_emit_prompt(prompt)


## Track the gunner role. On entry: snap our body onto the seat, switch the
## active Camera3D from the player rig to the gun rig (so the view aligns with
## the barrel), and subscribe to ammo changes. On exit: undo all of that and
## restore the contextual prompt.
##
## Mouse-look is frozen while gunning (gated in _unhandled_input below) so the
## player's underlying _yaw/_pitch don't drift in the background — when they
## leave the gun their camera resumes exactly where they left it.
func _on_gunner_changed(peer_id: int) -> void:
	if not is_multiplayer_authority():
		return
	var was := _is_gunner
	_is_gunner = peer_id != 0 and peer_id == multiplayer.get_unique_id()
	var gun := get_tree().get_first_node_in_group("deck_gun")
	var gun_camera := _find_gun_camera(gun)
	if _is_gunner:
		_snap_to_gunner_seat()
		# Camera swap: deactivate the player rig, activate the gun's barrel-mounted camera.
		_camera.current = false
		if gun_camera != null:
			gun_camera.current = true
		if gun and gun.has_signal("ammo_changed") and not gun.ammo_changed.is_connected(_on_gun_ammo_changed):
			gun.ammo_changed.connect(_on_gun_ammo_changed)
		_refresh_gunner_prompt()
	elif was:
		# Camera swap back to the player rig.
		if gun_camera != null:
			gun_camera.current = false
		_camera.current = true
		# The seat-snap inherited the ship's pitch/roll into our body rotation;
		# reset to identity so walking + CharacterBody3D's floor detection don't
		# get confused by a tilted body.
		rotation = Vector3.ZERO
		if gun and gun.has_signal("ammo_changed") and gun.ammo_changed.is_connected(_on_gun_ammo_changed):
			gun.ammo_changed.disconnect(_on_gun_ammo_changed)
		var prompt := ""
		if _current_interactable != null:
			prompt = _current_interactable.get_prompt(self)
		_emit_prompt(prompt)


## Locate the Camera3D mounted to the gun's ElevateBarrel. Returns null if
## the gun isn't in the scene yet (e.g. very early in startup).
func _find_gun_camera(gun: Node) -> Camera3D:
	if gun == null:
		return null
	return gun.get_node_or_null("TraverseMount/ElevateBarrel/GunCamera") as Camera3D


## Re-show the gunner's prompt with the latest ammo count.
func _on_gun_ammo_changed(_new_value: int) -> void:
	if _is_gunner:
		_refresh_gunner_prompt()


## Format the gunner's persistent prompt with the live ammo count.
func _refresh_gunner_prompt() -> void:
	var gun := get_tree().get_first_node_in_group("deck_gun")
	if gun == null:
		return
	var ammo: int = int(gun.get("ammo")) if "ammo" in gun else 0
	var capacity: int = int(gun.get("max_ammo")) if "max_ammo" in gun else 5
	_emit_prompt("Press E to leave the gun (%d/%d)" % [ammo, capacity])


## Pose this player body exactly on the gun's GunnerSeat marker. Called on
## entry and every physics tick while gunning (since the ship pitches over
## terrain underneath us, we'd drift otherwise).
func _snap_to_gunner_seat() -> void:
	var gun := get_tree().get_first_node_in_group("deck_gun")
	if gun == null or not gun.has_method("get_gunner_seat"):
		return
	var seat: Marker3D = gun.get_gunner_seat()
	if seat:
		global_transform = seat.global_transform


## Apply (and decay) the screen-shake offset on the camera rig each frame.
## Runs at render rate so the shake reads smoothly. Only local player.
func _process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if _shake_strength <= 0.0:
		_spring.rotation = Vector3(_pitch, _yaw, 0.0)
		return
	# Decay roughly linearly so a "small" hit ends quickly and a "big" hit lingers.
	_shake_strength = maxf(0.0, _shake_strength - delta * 1.8)
	var jitter_x := randf_range(-_shake_strength, _shake_strength) * 0.06
	var jitter_y := randf_range(-_shake_strength, _shake_strength) * 0.06
	_spring.rotation = Vector3(_pitch + jitter_x, _yaw + jitter_y, 0.0)


## Stack a fresh shake on top of any in-progress shake (so rapid hits feel worse).
## Shake intensity varies by hit location — solid parts (hull, bridge, cargo)
## rock the whole ship; wheels and rails are a glancing rattle.
func _on_ship_damage_taken(_hit_count: int, part: String) -> void:
	if not is_multiplayer_authority():
		return
	var impulse: float = 1.0
	match part:
		"bridge", "hull", "cargo": impulse = 1.2
		"stair":                   impulse = 0.9
		"rail":                    impulse = 0.6
		"wheel":                   impulse = 0.5
		_:                         impulse = 1.0
	_shake_strength = minf(_shake_strength + impulse, 2.0)


## Mouse motion rotates the camera rig only. The CharacterBody's own rotation
## stays at identity so it remains parented cleanly inside the ship.
##
## While gunning we freeze yaw/pitch entirely — the active view is the gun's
## own Camera3D, and we don't want the background player rig drifting so that
## leaving the gun snaps the view to some random angle the mouse wandered to.
func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseMotion:
		if _is_gunner:
			return  # mouse-look frozen — view belongs to the gun camera
		# Suppress camera turn whenever the mouse is visible (trade panel
		# open, debug Esc, etc.) so menu-clicks don't yank the view.
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		_yaw -= event.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.22, 1.22)
		_spring.rotation = Vector3(_pitch, _yaw, 0.0)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# Quick mouse-release for debugging in the editor.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Walk + jump + interact polling. Gated to local authority so each peer only
## drives their own body; remote bodies are interpolated by the synchronizer.
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if _is_gunner:
		# Locked at the gun seat. Re-snap each tick because the ship's terrain
		# pitch/roll would otherwise shake us off the marker. Aim/fire/release
		# input goes through _poll_interact.
		velocity = Vector3.ZERO
		_snap_to_gunner_seat()
		_interact_ray.rotation = Vector3(_pitch, _yaw, 0.0)
		_poll_interact()
		return
	if _is_helmsman:
		# Locked at the wheel. Still rotate the interact ray so the prompt
		# updates, and still poll E (used to release the helm).
		velocity = Vector3.ZERO
		_interact_ray.rotation = Vector3(_pitch, _yaw, 0.0)
		_poll_interact()
		return

	# Movement input is taken in camera-relative space so "forward" matches
	# the screen even though the ship beneath us is rotating in world space.
	var cam_forward := -_camera.global_transform.basis.z
	cam_forward.y = 0.0
	if cam_forward.length_squared() < 0.0001:
		cam_forward = -global_transform.basis.z
		cam_forward.y = 0.0
	cam_forward = cam_forward.normalized()
	var cam_right := cam_forward.cross(Vector3.UP).normalized()
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	)
	var move := cam_right * input_dir.x - cam_forward * input_dir.y
	if move.length() > 1.0:
		move = move.normalized()
	velocity.x = move.x * MOVEMENT_SPEED
	velocity.z = move.z * MOVEMENT_SPEED
	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			velocity.y = JUMP_VELOCITY
		else:
			# Small negative velocity keeps us "stuck" to ramped surfaces.
			velocity.y = -1.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()
	_interact_ray.rotation = Vector3(_pitch, _yaw, 0.0)
	_poll_interact()


## Drive the interact prompt and send `_request_interact` to the host when E
## is pressed. While at the helm, E always targets the helm (release). While
## at the gun, E targets the gun (release) and A/D/W/S/click drive the gun.
func _poll_interact() -> void:
	if _is_gunner:
		_poll_gun_input()
		return
	if _is_helmsman:
		if Input.is_action_just_pressed("interact"):
			var helm := get_tree().get_first_node_in_group("helm")
			if helm:
				_request_interact.rpc_id(1, helm.get_path())
		return
	var hit_interactable: Interactable = null
	if _interact_ray.is_colliding():
		var collider := _interact_ray.get_collider()
		if collider is Interactable:
			hit_interactable = collider
	_current_interactable = hit_interactable
	# Refresh every frame because some prompts (deck gun) depend on our carry
	# state — which can change while we're still looking at the same node.
	# _emit_prompt internally debounces against the last-emitted string.
	_emit_prompt(_current_interactable.get_prompt(self) if _current_interactable != null else "")
	if Input.is_action_just_pressed("interact") and _current_interactable != null:
		# Market interactables open a local trade UI directly instead of
		# routing through the host's interact() path — trade clicks then
		# generate their own RPCs from the panel.
		if _current_interactable.is_in_group("oasis_market"):
			var panel := get_tree().get_first_node_in_group("trade_panel")
			if panel != null and panel.has_method("open_for_market"):
				panel.open_for_market(_current_interactable)
			return
		_request_interact.rpc_id(1, _current_interactable.get_path())


## Emit only when the prompt text actually changes, so HUD listeners aren't
## hammered with a redundant signal every physics frame.
func _emit_prompt(text: String) -> void:
	if text == _last_emitted_prompt:
		return
	_last_emitted_prompt = text
	interact_prompt_changed.emit(text)


## Handle the gunner's controls. Each direction tap = one discrete step
## (no auto-repeat — tap-tap-tap for WW1/WW2 hand-crank feel). Mouse-click
## fires (server gates with reload_time). E releases the gun.
func _poll_gun_input() -> void:
	var gun := get_tree().get_first_node_in_group("deck_gun")
	if gun == null:
		return
	# Traverse step is inverted at the input layer: the gunner sits behind the
	# gun looking at +Z, so their *visual* right is world -X. A positive Y
	# rotation around the mount sends the barrel toward +X (their left), so we
	# negate D's step_dir to keep "press right → barrel goes right".
	if Input.is_action_just_pressed("move_right"):
		gun.request_traverse.rpc_id(1, -1)
	if Input.is_action_just_pressed("move_left"):
		gun.request_traverse.rpc_id(1, 1)
	if Input.is_action_just_pressed("move_forward"):
		gun.request_elevate.rpc_id(1, 1)
	if Input.is_action_just_pressed("move_back"):
		gun.request_elevate.rpc_id(1, -1)
	if Input.is_action_just_pressed("fire"):
		gun.request_fire.rpc_id(1)
	if Input.is_action_just_pressed("interact"):
		# Route through the standard interact path so the gun's own toggle
		# logic in interact() handles release attribution to the right peer.
		_request_interact.rpc_id(1, gun.get_path())


## Host-side validation. The client sends a node path; we resolve it and call
## the interactable's `interact()` with the *sender's* peer id so any side
## effects (e.g. helm transfer) attribute to the right player.
@rpc("any_peer", "call_local", "reliable")
func _request_interact(target_path: NodePath) -> void:
	if not multiplayer.is_server():
		return
	var target := get_node_or_null(target_path)
	if target and target is Interactable:
		var sender := multiplayer.get_remote_sender_id()
		# When the host clicks E on themselves, get_remote_sender_id() is 0;
		# attribute the call to the host's own peer id (always 1).
		if sender == 0:
			sender = multiplayer.get_unique_id()
		(target as Interactable).interact(sender)


## Tint the capsule based on peer id so each crew member reads as distinct.
func apply_peer_visuals(peer_id: int) -> void:
	var color := PEER_COLORS[peer_id % PEER_COLORS.size()]
	if _mesh and _mesh.mesh:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		_mesh.material_override = mat


# ── Carry-item API (used by coal_bunker / boiler_firebox) ────────────────────

## True if our hands are free.
func can_carry_item() -> bool:
	return carried_item_type.is_empty()


## True if we're carrying exactly this item type.
func is_carrying_item(item_type: String) -> bool:
	return carried_item_type == item_type


## Drop / consume whatever we're holding if it matches. Returns success so the
## caller can decide whether to perform its own side-effect.
func consume_carried_item(item_type: String) -> bool:
	if carried_item_type != item_type:
		return false
	set_carried_item.rpc("")
	return true


## RPC entry point for the carry slot. Broadcast so the visual prop syncs to
## all peers (otherwise remote players would see empty-handed couriers).
@rpc("any_peer", "call_local", "reliable")
func set_carried_item(item_type: String) -> void:
	carried_item_type = item_type
	_refresh_carried_visual()


## Tear down any existing prop and (if applicable) instantiate the new one
## inside our CarrySocket. Extend the match-block here for new item types.
func _refresh_carried_visual() -> void:
	if _carried_visual != null and is_instance_valid(_carried_visual):
		_carried_visual.queue_free()
	_carried_visual = null
	match carried_item_type:
		"coal":
			_carried_visual = _make_coal_visual()
		"clip":
			_carried_visual = _make_clip_visual()
		"repair_kit":
			_carried_visual = _make_repair_kit_visual()
		_:
			# Cargo crates use a string like "cargo_coal" / "cargo_water" /
			# "cargo_spice". The Goods registry tells us the tint.
			if Goods.is_cargo_carry(carried_item_type):
				_carried_visual = _make_cargo_visual(carried_item_type)
	if _carried_visual != null:
		_carry_socket.add_child(_carried_visual)


## A small black box in the carry socket — coal for the boiler.
func _make_coal_visual() -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = "CarriedCoal"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.35, 0.25, 0.28)
	n.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.035, 0.032, 0.03, 1.0)
	mat.roughness = 0.95
	n.material_override = mat
	return n


## A brass-coloured slab — 5-shell clip for the deck gun.
func _make_clip_visual() -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = "CarriedClip"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.4, 0.12, 0.22)
	n.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.65, 0.25, 1.0)
	mat.metallic = 0.6
	mat.roughness = 0.35
	n.material_override = mat
	return n


## A wooden tool-crate — repair kit for damaged ship systems.
func _make_repair_kit_visual() -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.name = "CarriedRepairKit"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.4, 0.25, 0.3)
	n.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.3, 0.15, 1.0)
	mat.roughness = 0.85
	n.material_override = mat
	return n


## A cargo crate held in hand. Tint comes from the goods registry so all
## three goods (coal/water/spice) share one visual factory.
func _make_cargo_visual(carry_id: String) -> MeshInstance3D:
	var good_id := Goods.good_from_carry_id(carry_id)
	if good_id.is_empty():
		return null
	var n := MeshInstance3D.new()
	n.name = "CarriedCargo_" + good_id
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 0.4, 0.4)
	n.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Goods.get_color(good_id)
	mat.roughness = 0.85
	n.material_override = mat
	return n


# ── Cargo carry helpers (used by oasis market + cargo hold deposit) ──────────

## True if our carry slot holds any cargo crate.
func is_carrying_cargo() -> bool:
	return Goods.is_cargo_carry(carried_item_type)


## The good_id we're carrying ("coal", "water", "spice"), or "" if hands are
## empty / carrying something non-cargo.
func get_carried_cargo_good() -> String:
	return Goods.good_from_carry_id(carried_item_type)
