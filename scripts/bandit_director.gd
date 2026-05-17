extends Node
##
## BANDIT DIRECTOR — host-only spawn manager for bandit ships and the
## broadcast hub for cannonball spawn/despawn RPCs.
##
## Lives as a child of WorldMap (see world_map.tscn). One instance per session.
##
## Responsibilities:
##   • On a slow timer, roll the dice to spawn a bandit behind the moving player.
##     One bandit at a time for v1 — once it dies or is freed, the timer resumes.
##   • Provide central spawn/despawn RPCs for cannonballs so AI ships don't
##     have to know about networking themselves.
##
## All AI logic itself lives in ai_ship_controller.gd; this node only handles
## *when* and *where* to spawn things.
##

const AI_SHIP_SCENE: PackedScene = preload("res://scenes/ship/ai_ship.tscn")
const CANNONBALL_SCENE: PackedScene = preload("res://scenes/projectiles/cannonball.tscn")

# ── Spawn pacing ─────────────────────────────────────────────────────────────
@export var check_interval: float = 4.0      # seconds between spawn rolls
@export var spawn_chance: float = 0.35       # probability per roll
@export var min_player_speed: float = 2.0    # ship must be moving above this (m/s)
@export var spawn_distance: float = 260.0    # spawn well outside ai_ship.engage_distance so they steam in
@export var spawn_lateral_jitter: float = 60.0  # left/right scatter at spawn
# Sandstorms favour raiders — at full storm intensity the per-roll chance is
# multiplied by (1 + this). Bandits use the murk as cover.
@export var storm_spawn_boost: float = 1.5

# ── Internal state (host only) ──────────────────────────────────────────────
var _current_bandit: Node = null             # one-at-a-time guard
var _check_timer: float = 0.0
var _cannonball_id: int = 0                  # monotonically increases — unique names


## Register in the group so AI ships and the player ship can locate us.
func _ready() -> void:
	add_to_group("bandit_director")


## Host-only tick. Roll for a spawn every `check_interval` seconds, but only
## if the player ship is actually moving (no ambushing a parked ship).
func _process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	# Validate the cached bandit reference — it may have been freed.
	if _current_bandit != null and not is_instance_valid(_current_bandit):
		_current_bandit = null
	if _current_bandit != null:
		return  # already have one out there
	_check_timer += delta
	if _check_timer < check_interval:
		return
	_check_timer = 0.0
	var eff_chance := spawn_chance
	var weather := get_tree().get_first_node_in_group("weather")
	if weather != null and weather.has_method("get_storm_intensity"):
		eff_chance *= 1.0 + storm_spawn_boost * float(weather.get_storm_intensity())
	if randf() > eff_chance:
		return
	var player := get_tree().get_first_node_in_group("ship")
	if player == null:
		return
	if absf(float(player.current_speed)) < min_player_speed:
		return
	_spawn_bandit_behind(player)


## Host-only. Pick a spot behind the player, broadcast spawn to every peer.
func _spawn_bandit_behind(player: Node) -> void:
	var yaw: float = float(player.virtual_yaw)
	var forward := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var lateral := randf_range(-spawn_lateral_jitter, spawn_lateral_jitter)
	var spawn_world: Vector3 = player.world_offset - forward * spawn_distance + right * lateral
	# Spawning bandit faces the player's general heading so its first move is
	# to close the gap rather than turning a full 180°.
	var spawn_yaw := yaw
	var bandit_id := _next_bandit_id()
	_spawn_ai_ship.rpc(bandit_id, spawn_world, spawn_yaw)
	# call_local means we just spawned our own copy via the RPC; grab it
	# directly from WorldMap (our parent).
	var world_map := get_parent()
	if world_map != null:
		_current_bandit = world_map.get_node_or_null(bandit_id)


## Per-session unique name for the bandit node. Time-stamped so reload/respawn
## won't collide with a previous ID still in the freeing queue.
func _next_bandit_id() -> String:
	return "Bandit_%d" % Time.get_ticks_msec()


## Spawn the bandit ship as a child of WorldMap on every peer. Authority is
## the server, since the AI is server-simulated.
@rpc("authority", "call_local", "reliable")
func _spawn_ai_ship(bandit_name: String, spawn_world: Vector3, spawn_yaw: float) -> void:
	var world_map := get_parent()
	if world_map == null:
		return
	if world_map.has_node(bandit_name):
		return
	var ship: Node = AI_SHIP_SCENE.instantiate()
	ship.name = bandit_name
	ship.set_multiplayer_authority(1)  # server runs the brain
	world_map.add_child(ship, true)
	# Initial state — the synchronizer will catch up other clients shortly.
	if "world_offset" in ship:
		ship.world_offset = spawn_world
	if "virtual_yaw" in ship:
		ship.virtual_yaw = spawn_yaw


## Public — called by ai_ship_controller (bandit shells) or deck_gun (player
## shells) from the host whenever a cannon fires. Generates a unique name and
## broadcasts the spawn so every peer simulates the same trajectory locally.
##
## `target_group` selects whose hulls the shell can damage — "ship" for bandit
## broadsides aimed at the player, "bandit" for player return-fire.
func spawn_cannonball(origin: Vector3, velocity: Vector3, target_group: String = "ship") -> void:
	if not multiplayer.is_server():
		return
	_cannonball_id += 1
	var ball_name := "Cannonball_%d" % _cannonball_id
	_spawn_cannonball.rpc(ball_name, origin, velocity, target_group)


## Public — called by cannonball.gd from the host on impact. Removes the ball
## from every peer's scene tree.
func despawn_cannonball(ball_name: String) -> void:
	if not multiplayer.is_server():
		return
	_despawn_cannonball.rpc(ball_name)


## Instantiate one cannonball as a child of WorldMap. Each peer's copy runs
## its own deterministic trajectory simulation from `origin` + `velocity`,
## hunting for collisions against the named `target_group`.
@rpc("authority", "call_local", "reliable")
func _spawn_cannonball(ball_name: String, origin: Vector3, velocity: Vector3, target_group: String) -> void:
	var world_map := get_parent()
	if world_map == null:
		return
	if world_map.has_node(ball_name):
		return
	var ball: Node = CANNONBALL_SCENE.instantiate()
	ball.name = ball_name
	world_map.add_child(ball, true)
	if ball.has_method("initialize"):
		ball.initialize(origin, velocity, target_group)


## Remove a cannonball by name on every peer (called when the server registers
## a hit; timeout-based despawn happens locally without RPC).
@rpc("authority", "call_local", "reliable")
func _despawn_cannonball(ball_name: String) -> void:
	var world_map := get_parent()
	if world_map == null:
		return
	var ball := world_map.get_node_or_null(ball_name)
	if ball != null:
		ball.queue_free()


## Public — called by ai_ship_controller (host-side) once the bandit has
## absorbed enough hits to be destroyed. Broadcasts despawn so every peer
## removes the ship at the same moment.
func destroy_bandit(bandit_name: String) -> void:
	if not multiplayer.is_server():
		return
	if _current_bandit != null and is_instance_valid(_current_bandit) and _current_bandit.name == bandit_name:
		_current_bandit = null
	_destroy_bandit.rpc(bandit_name)


@rpc("authority", "call_local", "reliable")
func _destroy_bandit(bandit_name: String) -> void:
	var world_map := get_parent()
	if world_map == null:
		return
	var b := world_map.get_node_or_null(bandit_name)
	if b != null:
		b.queue_free()
