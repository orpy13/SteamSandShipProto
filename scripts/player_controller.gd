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
## Local-only: HUD subscribes to draw this crew member's needs (T1.7).
signal survival_changed(hunger: float, thirst: float, energy: float, dead: bool)

@export var MOVEMENT_SPEED: float = 5.0
@export var JUMP_VELOCITY: float = 4.5
@export var MOUSE_SENSITIVITY: float = 0.002
# ── Over-the-shoulder camera ────────────────────────────────────────────────
@export var shoulder_offset: float = 0.6     # camera lateral offset (+ = right shoulder)
@export var camera_height: float = 0.2        # camera vertical nudge on the arm
@export var spring_collision_mask: int = 1    # world solids the arm pulls in front of
# Degrees added to the character model's facing if it imports back-to-front.
@export var model_yaw_offset_deg: float = 0.0
@export var GRAVITY: float = 12.0

# ── Survival (Tier 1, ROADMAP.md → T1.5) ─────────────────────────────────────
# Per-player, simulated on the player's own authority. Stats 0..100. Drain
# scales with activity and the environment (midday sun + sandstorm + being off
# the ship in the open desert). hunger or thirst hitting 0 = dead (frozen);
# revival happens when the ship reaches a settlement (any market trade).
@export var hunger_drain: float = 0.45          # per second, baseline
@export var thirst_drain: float = 0.65          # per second, baseline
@export var energy_drain_idle: float = 0.20     # per second at rest
@export var energy_drain_active: float = 0.85   # per second moving / carrying
@export var energy_regen_fed: float = 0.6       # per second resting & well-fed
@export var heat_thirst_mult: float = 1.8       # ×thirst at full daylight
@export var storm_thirst_mult: float = 1.6      # ×thirst at full sandstorm
@export var exposed_drain_mult: float = 2.2     # ×hunger/thirst when off-ship in the dunes
@export var low_energy_speed_floor: float = 0.45 # movement multiplier at 0 energy
@export var food_restore: float = 55.0          # hunger per ration eaten (+ a little energy)
@export var water_restore: float = 60.0         # thirst per drinking-water consumed
@export var low_warn_threshold: float = 25.0    # HUD turns amber below this
@export var critical_grace: float = 14.0        # seconds collapsing at 0 before death
@export var critical_speed_mult: float = 0.22   # movement while collapsing (very slow)

var hunger: float = 100.0
var thirst: float = 100.0
var energy: float = 100.0
var is_dead: bool = false
# Grace period: hunger/thirst at 0 → collapsing (barely able to move) for
# `critical_grace` seconds before actually dying. Eating/drinking in time
# pulls you back out.
var _critical: bool = false
var _critical_timer: float = 0.0

# Lazily-built cargo withdraw chooser (one per local player).
var _cargo_panel: CargoPanel = null

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
@onready var _mesh: MeshInstance3D = get_node_or_null("MeshInstance3D")  # legacy capsule (gone w/ model)
@onready var _carry_socket: Node3D = $CarrySocket
@onready var _model: Node3D = get_node_or_null("characterMedium")
@onready var _anim: AnimationPlayer = get_node_or_null("characterMedium/Root/AnimationPlayer")

var _yaw: float = 0.0           # camera + character yaw (free-look drives the body)
var _pitch: float = 0.0
# Resolved animation clip names (idle/run/jump) + last-applied state.
var _anim_idle: String = ""
var _anim_run: String = ""
var _anim_jump: String = ""
var _anim_state: int = -1       # -1 unset, 0 idle, 1 run, 2 jump
var _current_interactable: Interactable = null
var _last_emitted_prompt: String = ""  # to debounce per-frame prompt refreshes
var _is_helmsman: bool = false  # true while *this* player is driving the ship
var _is_gunner: bool = false    # true while *this* player is manning the deck gun
var _is_observer: bool = false  # true while *this* player is at the telescope (T2.3)

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
		# Over-the-shoulder framing + let the spring arm pull the camera in
		# front of walls/terrain instead of clipping through them.
		_camera.position = Vector3(shoulder_offset, camera_height, 0.0)
		_spring.collision_mask = spring_collision_mask
		_spring.margin = 0.3
		_spring.add_excluded_object(get_rid())  # never collide with our own body
	else:
		_camera.current = false
	# All peers: model facing offset (preserve baked scale/axis) + anim setup.
	if _model != null and not is_zero_approx(model_yaw_offset_deg):
		var t := _model.transform
		_model.transform = Transform3D(
				Basis(Vector3.UP, deg_to_rad(model_yaw_offset_deg)) * t.basis, t.origin)
	_resolve_animations()
	NetworkManager.helmsman_changed.connect(_on_helmsman_changed)
	NetworkManager.gunner_changed.connect(_on_gunner_changed)
	NetworkManager.observer_changed.connect(_on_observer_changed)
	_is_helmsman = NetworkManager.current_helmsman != 0 \
			and NetworkManager.current_helmsman == multiplayer.get_unique_id()
	_is_gunner = NetworkManager.current_gunner != 0 \
			and NetworkManager.current_gunner == multiplayer.get_unique_id()
	_is_observer = NetworkManager.current_observer != 0 \
			and NetworkManager.current_observer == multiplayer.get_unique_id()
	if _is_helmsman:
		_emit_prompt("Press E to release the helm")
	elif _is_gunner:
		_refresh_gunner_prompt()
	elif _is_observer:
		_emit_prompt("Press E to leave the telescope")
	# Subscribe to ship damage events for local screen shake. Fires on every
	# peer (the ship's damage signal is RPC-broadcast), so each crew member
	# feels the hit on their own screen.
	var ship := get_tree().get_first_node_in_group("ship")
	if ship and ship.has_signal("damage_taken") and not ship.damage_taken.is_connected(_on_ship_damage_taken):
		ship.damage_taken.connect(_on_ship_damage_taken)


## Match the imported clip names by keyword (robust to "Root|Idle",
## "run/Root|Run", etc.), set looping where appropriate, and start idle.
func _resolve_animations() -> void:
	if _anim == null:
		return
	# Match on the CLIP name (after the "lib/" prefix), not the library —
	# each fbx holds a "…|0_Targeting Pose" take alongside the real clip, so
	# keying off the library would grab the wrong one (the bug you saw).
	for n in _anim.get_animation_list():
		var s := String(n)
		var clip := s.get_slice("/", s.get_slice_count("/") - 1)  # part after last '/'
		var low := clip.to_lower()
		if low.contains("targeting") or low.contains("pose"):
			continue  # skip the bind/targeting take in each fbx
		if _anim_jump == "" and low.contains("jump"):
			_anim_jump = s
		elif _anim_run == "" and (low.contains("run") or low.contains("walk")):
			_anim_run = s
		elif _anim_idle == "" and low.contains("idle"):
			_anim_idle = s
	# Last-ditch: if idle still unknown, take the first animation we have.
	if _anim_idle == "":
		var all := _anim.get_animation_list()
		if all.size() > 0:
			_anim_idle = String(all[0])
	for nm in [_anim_idle, _anim_run]:
		if nm != "" and _anim.has_animation(nm):
			_anim.get_animation(nm).loop_mode = Animation.LOOP_LINEAR
	_play_anim_state(0)


## Play the clip for a state (0 idle / 1 run / 2 jump) on this peer.
func _play_anim_state(state: int) -> void:
	if _anim == null:
		return
	var clip := _anim_idle
	if state == 1 and _anim_run != "":
		clip = _anim_run
	elif state == 2 and _anim_jump != "":
		clip = _anim_jump
	if clip != "" and _anim.has_animation(clip) and _anim.current_animation != clip:
		_anim.play(clip)


## Authority decides the state from movement; broadcast only on change so the
## reliable RPC stays quiet. call_local plays it here too.
func _update_anim_state() -> void:
	var state := 0
	if _is_helmsman or _is_gunner or _is_observer or is_dead:
		state = 0
	elif not is_on_floor():
		state = 2
	elif Vector2(velocity.x, velocity.z).length() > 0.6:
		state = 1
	if state != _anim_state:
		_anim_state = state
		_set_anim_state.rpc(state)


@rpc("any_peer", "call_local", "reliable")
func _set_anim_state(state: int) -> void:
	_anim_state = state
	_play_anim_state(state)


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


## Locate the Camera3D mounted to the telescope. Returns null pre-init.
func _find_telescope_camera(t: Node) -> Camera3D:
	if t == null:
		return null
	return t.get_node_or_null("TraverseMount/ElevateBarrel/TelescopeCamera") as Camera3D


## Track the observer role. Mirrors `_on_gunner_changed`: snap to seat,
## swap camera to the scope, freeze input. The telescope_overlay listens to
## NetworkManager.observer_changed itself to flip its visibility.
func _on_observer_changed(peer_id: int) -> void:
	if not is_multiplayer_authority():
		return
	var was := _is_observer
	_is_observer = peer_id != 0 and peer_id == multiplayer.get_unique_id()
	var telescope := get_tree().get_first_node_in_group("telescope")
	var t_cam := _find_telescope_camera(telescope)
	if _is_observer:
		_snap_to_observer_seat()
		_camera.current = false
		if t_cam != null:
			t_cam.current = true
		_emit_prompt("Press E to leave the telescope")
	elif was:
		if t_cam != null:
			t_cam.current = false
		_camera.current = true
		# Same fix as the gun: the seat snap inherits ship pitch/roll into our
		# body rotation; clear so move_and_slide doesn't think we're tilted.
		rotation = Vector3.ZERO
		var prompt := ""
		if _current_interactable != null:
			prompt = _current_interactable.get_prompt(self)
		_emit_prompt(prompt)


## Pose the body on the telescope's OperatorSeat marker. Called on entry +
## every physics tick while observing (ship pitches under us otherwise).
func _snap_to_observer_seat() -> void:
	var t := get_tree().get_first_node_in_group("telescope")
	if t == null or not t.has_method("get_operator_seat"):
		return
	var seat: Marker3D = t.get_operator_seat()
	if seat:
		global_transform = seat.global_transform


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
	var base := _rig_spring_euler()
	if _shake_strength <= 0.0:
		_spring.rotation = base
		return
	# Decay roughly linearly so a "small" hit ends quickly and a "big" hit lingers.
	_shake_strength = maxf(0.0, _shake_strength - delta * 1.8)
	var jitter_x := randf_range(-_shake_strength, _shake_strength) * 0.06
	var jitter_y := randf_range(-_shake_strength, _shake_strength) * 0.06
	_spring.rotation = base + Vector3(jitter_x, jitter_y, 0.0)


## Spring-arm euler by mode: free-look keeps yaw on the BODY (so the character
## turns with the camera and it replicates), so the arm only pitches; while
## helming the body is locked, so the arm carries yaw too.
func _rig_spring_euler() -> Vector3:
	if _is_helmsman:
		return Vector3(_pitch, _yaw, 0.0)
	return Vector3(_pitch, 0.0, 0.0)


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
		if _is_gunner or _is_observer:
			return  # mouse-look frozen — view belongs to the manned camera
		# Suppress camera turn whenever the mouse is visible (trade panel
		# open, debug Esc, etc.) so menu-clicks don't yank the view.
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		_yaw -= event.relative.x * MOUSE_SENSITIVITY
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, -1.22, 1.22)
		# Rig (spring + body + ray) is applied in _process / _physics_process.
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# Quick mouse-release for debugging in the editor.
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Walk + jump + interact polling. Gated to local authority so each peer only
## drives their own body; remote bodies are interpolated by the synchronizer.
func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_tick_survival(delta)
	if is_dead:
		# Frozen until the crew reaches a settlement (any market trade).
		velocity = Vector3.ZERO
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		move_and_slide()
		_update_anim_state()
		return
	if _is_gunner:
		# Locked at the gun seat. Re-snap each tick because the ship's terrain
		# pitch/roll would otherwise shake us off the marker. Aim/fire/release
		# input goes through _poll_interact.
		velocity = Vector3.ZERO
		_snap_to_gunner_seat()
		_interact_ray.rotation = Vector3(_pitch, _yaw, 0.0)
		_update_anim_state()
		_poll_interact()
		return
	if _is_observer:
		# Same lock as gunner: snap each tick (terrain pitch/roll shake) and
		# route inputs to the telescope. E unmounts via _poll_interact.
		velocity = Vector3.ZERO
		_snap_to_observer_seat()
		_interact_ray.rotation = Vector3(_pitch, _yaw, 0.0)
		_update_anim_state()
		_poll_interact()
		return
	if _is_helmsman:
		# Locked at the wheel. Still rotate the interact ray so the prompt
		# updates, and still poll E (used to release the helm).
		velocity = Vector3.ZERO
		_interact_ray.rotation = Vector3(_pitch, _yaw, 0.0)
		_update_anim_state()
		_poll_interact()
		return

	# Free-look: the character body carries the yaw, so the model turns with
	# the camera and it replicates to other peers (rotation is synchronised).
	rotation = Vector3(0.0, _yaw, 0.0)

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
	# Low energy saps your pace (never below low_energy_speed_floor); a
	# collapsing crew member can only just shuffle.
	var spd := MOVEMENT_SPEED * lerpf(low_energy_speed_floor, 1.0, clampf(energy / 100.0, 0.0, 1.0))
	if _critical:
		spd *= critical_speed_mult
	# Debug speed boost (a poor-man's free-fly — fast enough to cross the map
	# without spending real time, but walking still respects collisions unless
	# no-clip is also enabled).
	if GameState.debug_mode:
		spd *= GameState.debug_speed_mult
	velocity.x = move.x * spd
	velocity.z = move.z * spd
	# No-clip: pass through everything and fly vertically with jump (up) /
	# brake (down). The lateral speed above is reused, so move_right/left/etc.
	# steer the flight in camera space.
	var noclip := GameState.debug_mode and GameState.debug_noclip
	_apply_noclip(noclip)
	if noclip:
		var vy := 0.0
		if Input.is_action_pressed("jump"):
			vy += spd
		if Input.is_action_pressed("brake"):
			vy -= spd
		velocity.y = vy
	elif is_on_floor():
		if Input.is_action_just_pressed("jump"):
			var jv := JUMP_VELOCITY
			if GameState.debug_mode:
				jv *= GameState.debug_jump_mult
			velocity.y = jv
		else:
			# Small negative velocity keeps us "stuck" to ramped surfaces.
			velocity.y = -1.0
	else:
		velocity.y -= GRAVITY * delta
	move_and_slide()
	# Body already carries yaw; the ray only needs pitch.
	_interact_ray.rotation = Vector3(_pitch, 0.0, 0.0)
	_update_anim_state()
	_poll_interact()


## Drive the interact prompt and send `_request_interact` to the host when E
## is pressed. While at the helm, E always targets the helm (release). While
## at the gun, E targets the gun (release) and A/D/W/S/click drive the gun.
func _poll_interact() -> void:
	if _is_gunner:
		_poll_gun_input()
		return
	if _is_observer:
		_poll_telescope_input()
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
		# Cargo hold: deposit when carrying a crate (host path), otherwise
		# open the local withdraw chooser.
		if _current_interactable.is_in_group("cargo_hold") and not is_carrying_cargo():
			_open_cargo_panel(_current_interactable)
			return
		# Chart table: open the local chart overlay (UI replicates its own
		# mutations through ChartState RPCs — no host interact() round-trip).
		if _current_interactable.is_in_group("chart_table"):
			var chart := get_tree().get_first_node_in_group("chart_panel")
			if chart != null and chart.has_method("open"):
				chart.open()
			return
		_request_interact.rpc_id(1, _current_interactable.get_path())
	elif Input.is_action_just_pressed("interact") and _current_interactable == null:
		# Not aimed at anything — E eats/drinks a carried ration / water.
		_try_consume_carried()


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


## Telescope inputs (Tier 2, T2.3 Slice B). A/D and W/S nudge the scope a
## small step each tap (no auto-repeat); left-click spots; E unmounts via
## the standard interact path so role bookkeeping stays in one place.
##
## Steering convention mirrors the deck gun: A turns the scope LEFT visually
## (positive yaw rotates the mount such that the barrel tips to +X, which is
## screen-right for an observer looking down the barrel — so we negate D).
func _poll_telescope_input() -> void:
	var telescope := get_tree().get_first_node_in_group("telescope")
	if telescope == null:
		return
	if Input.is_action_just_pressed("move_right"):
		telescope.request_traverse.rpc_id(1, -1)
	if Input.is_action_just_pressed("move_left"):
		telescope.request_traverse.rpc_id(1, 1)
	if Input.is_action_just_pressed("move_forward"):
		telescope.request_elevate.rpc_id(1, 1)
	if Input.is_action_just_pressed("move_back"):
		telescope.request_elevate.rpc_id(1, -1)
	if Input.is_action_just_pressed("fire"):
		telescope.request_spot.rpc_id(1)
	if Input.is_action_just_pressed("interact"):
		_request_interact.rpc_id(1, telescope.get_path())


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


# ── Debug: no-clip toggle (mask 0 lets us pass through walls/terrain/ship) ──
# Cached so we restore the original mask exactly when no-clip flips off.
var _noclip_saved_mask: int = -1


func _apply_noclip(on: bool) -> void:
	if on and _noclip_saved_mask < 0:
		_noclip_saved_mask = collision_mask
		collision_mask = 0
	elif not on and _noclip_saved_mask >= 0:
		collision_mask = _noclip_saved_mask
		_noclip_saved_mask = -1


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
		"item_water_bottle":
			_carried_visual = _make_item_visual("res://scenes/items/water_bottle.tscn")
		"item_sausage":
			_carried_visual = _make_item_visual("res://scenes/items/sausage.tscn")
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


## Instance a physical item scene (water bottle / sausage) as the held prop.
## The source scenes are RigidBody3D — freeze them and clear collision so they
## sit still in the carry socket instead of falling / shoving the player.
func _make_item_visual(scene_path: String) -> Node3D:
	if not ResourceLoader.exists(scene_path):
		return null
	var ps: Resource = load(scene_path)
	if not (ps is PackedScene):
		return null
	var inst: Node = (ps as PackedScene).instantiate()
	if inst is RigidBody3D:
		var rb := inst as RigidBody3D
		rb.freeze = true
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.collision_layer = 0
		rb.collision_mask = 0
	return inst as Node3D


# ── Cargo carry helpers (used by oasis market + cargo hold deposit) ──────────

## True if our carry slot holds any cargo crate.
func is_carrying_cargo() -> bool:
	return Goods.is_cargo_carry(carried_item_type)


## The good_id we're carrying ("coal", "water", "spice"), or "" if hands are
## empty / carrying something non-cargo.
func get_carried_cargo_good() -> String:
	return Goods.good_from_carry_id(carried_item_type)


# ── Survival (Tier 1, T1.5) ──────────────────────────────────────────────────

## Per-frame needs sim. Authority-only (called from _physics_process). Drain
## scales with activity + environment (midday sun / sandstorm / being off-ship
## in the open dunes). hunger or thirst at 0 → dead.
func _tick_survival(delta: float) -> void:
	# Debug/god mode: freeze needs at full and revive on the fly. The early
	# return below skips drain entirely (no death possible).
	if GameState.debug_mode:
		hunger = 100.0
		thirst = 100.0
		energy = 100.0
		_critical = false
		_critical_timer = 0.0
		if is_dead:
			# Broadcast so every peer un-freezes our body, not just us.
			set_survival_dead.rpc(false)
		else:
			survival_changed.emit(hunger, thirst, energy, is_dead)
		return
	if is_dead:
		return

	var daylight := 0.0
	var dn := get_tree().get_first_node_in_group("day_night")
	if dn != null and dn.has_method("get_daylight"):
		daylight = float(dn.get_daylight())
	var storm := 0.0
	var w := get_tree().get_first_node_in_group("weather")
	if w != null and w.has_method("get_storm_intensity"):
		storm = float(w.get_storm_intensity())
	# Off the ship (reparented under WorldMap by the gangway) = exposed.
	var p := get_parent()
	var exposed := p != null and p.is_in_group("terrain")
	var exposure := exposed_drain_mult if exposed else 1.0

	hunger = clampf(hunger - hunger_drain * exposure * delta, 0.0, 100.0)
	# Region thirst modifier (T2.0) — salt flats etc. drain faster. Read the
	# *ship's* world position so all crew share the same regional climate,
	# not their per-player scene-local spot (which is always near 0).
	var region_thirst_mult := 1.0
	var ship := get_tree().get_first_node_in_group("ship")
	if ship != null and "world_offset" in ship:
		region_thirst_mult = Regions.get_modifier_at(
				float(ship.world_offset.x), float(ship.world_offset.z),
				Regions.HAZ_THIRST_MULT, 1.0)
	var thirst_rate := thirst_drain * region_thirst_mult \
			* (1.0 + heat_thirst_mult * daylight + storm_thirst_mult * storm) \
			* exposure
	thirst = clampf(thirst - thirst_rate * delta, 0.0, 100.0)

	var active := velocity.length() > 0.5 or not carried_item_type.is_empty()
	if active:
		energy = clampf(energy - energy_drain_active * delta, 0.0, 100.0)
	elif hunger > 20.0 and thirst > 20.0:
		energy = clampf(energy + energy_regen_fed * delta, 0.0, 100.0)
	else:
		energy = clampf(energy - energy_drain_idle * delta, 0.0, 100.0)

	# Collapsing grace: at 0 you don't drop dead — you can barely move for
	# `critical_grace` seconds, enough to crawl to food/water or be carried
	# back. Recover above 0 and you're out of it.
	if hunger <= 0.0 or thirst <= 0.0:
		_critical = true
		_critical_timer += delta
		if _critical_timer >= critical_grace:
			set_survival_dead.rpc(true)  # call_local applies here too
	else:
		_critical = false
		_critical_timer = 0.0
	survival_changed.emit(hunger, thirst, energy, is_dead)


## Open (building it once) the cargo withdraw chooser for `hold`.
func _open_cargo_panel(hold: Node) -> void:
	if _cargo_panel == null or not is_instance_valid(_cargo_panel):
		_cargo_panel = CargoPanel.new()
		var ui := get_tree().current_scene.get_node_or_null("UILayer")
		if ui != null:
			ui.add_child(_cargo_panel)
		else:
			add_child(_cargo_panel)
	_cargo_panel.open_for_hold(hold)


## E with empty aim eats a carried ration / drinks carried water.
func _try_consume_carried() -> void:
	if carried_item_type == "cargo_food" or carried_item_type == "item_sausage":
		hunger = minf(100.0, hunger + food_restore)
		energy = minf(100.0, energy + food_restore * 0.3)
		set_carried_item.rpc("")
		survival_changed.emit(hunger, thirst, energy, is_dead)
	elif carried_item_type == "cargo_drinking_water" or carried_item_type == "item_water_bottle":
		thirst = minf(100.0, thirst + water_restore)
		set_carried_item.rpc("")
		survival_changed.emit(hunger, thirst, energy, is_dead)


## Broadcast death so every peer freezes this body and the host can run the
## all-crew-dead check. Permissive sender (co-op, no anti-cheat need).
@rpc("any_peer", "call_local", "reliable")
func set_survival_dead(value: bool) -> void:
	is_dead = value
	survival_changed.emit(hunger, thirst, energy, is_dead)
	if value and multiplayer.is_server():
		_check_all_dead()


## Bed rest — top up energy (permissive sender; co-op). Applied on the
## authority instance (which simulates energy) and harmless elsewhere.
@rpc("any_peer", "call_local", "reliable")
func rest_energy(amount: float) -> void:
	energy = clampf(energy + amount, 0.0, 100.0)
	survival_changed.emit(hunger, thirst, energy, is_dead)


## Reaching a settlement (any market trade) revives + re-provisions the crew.
@rpc("any_peer", "call_local", "reliable")
func revive_survival() -> void:
	is_dead = false
	_critical = false
	_critical_timer = 0.0
	hunger = maxf(hunger, 50.0)
	thirst = maxf(thirst, 55.0)
	energy = maxf(energy, 55.0)
	survival_changed.emit(hunger, thirst, energy, is_dead)


## Server-only: if every crew member is dead the run is over.
func _check_all_dead() -> void:
	if not multiplayer.is_server():
		return
	var any := false
	for peer_id in NetworkManager.players.keys():
		var node := _locate_crew_node(int(peer_id))
		if node == null or not ("is_dead" in node):
			continue
		any = true
		if not bool(node.is_dead):
			return  # someone's still standing (or ashore)
	if any:
		NetworkManager.report_all_dead()


## Find a crew member's body whether aboard (PlayerContainer) or disembarked
## (reparented under WorldMap). Node name == peer id (NetworkManager).
static func _locate_crew_node(peer_id: int) -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var ship := tree.get_first_node_in_group("ship")
	if ship != null:
		var container := ship.get_node_or_null("PlayerContainer")
		if container != null and container.has_node(str(peer_id)):
			return container.get_node(str(peer_id))
	var wm := tree.get_first_node_in_group("terrain")
	if wm != null and wm.has_node(str(peer_id)):
		return wm.get_node(str(peer_id))
	return null
