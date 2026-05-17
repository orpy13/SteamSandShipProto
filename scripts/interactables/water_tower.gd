extends Interactable
##
## WATER TOWER — a desert oasis station that refills the boiler reservoir.
##
## Rules:
##   • The ship must be physically inside the tower's trigger volume.
##   • The ship must be stopped (|speed| ≤ stopped_speed_threshold).
##   • A crew member presses E inside the trigger to start filling.
##   • Filling continues until the boiler is full, the ship moves, or the ship
##     leaves the trigger.
##
## Procedurally placed by the chunk manager — always at least one chunk
## outside the starting load radius, so reaching one is a real journey.
##

@export var stopped_speed_threshold: float = 0.15  # m/s tolerance for "stopped"
@export var fill_rate: float = 18.0                # water units per second

# Server-only state. Clients learn about a fill via the steam plant's normal
# state broadcast (the water_level field) — no need to replicate these flags.
var _ship_inside: bool = false
var _filling: bool = false


func _ready() -> void:
	prompt_text = "Press E to fill boiler water"
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	# Only run physics when actively filling. Saves cycles in the common case
	# where the ship is nowhere near a tower.
	set_physics_process(false)


## Server-only. Begin filling iff the ship is here AND stopped.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not _ship_inside or not _ship_is_stopped(ship):
		return
	super(peer_id)
	_filling = true
	set_physics_process(true)


## Server-only fill tick. Stops automatically if the ship moves, leaves, or
## the boiler reaches full capacity.
func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if not _filling:
		set_physics_process(false)
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not _ship_inside or not _ship_is_stopped(ship):
		_stop_filling()
		return
	var plant := ship.get_node_or_null("SteamPlant")
	if plant == null or not plant.has_method("add_water"):
		_stop_filling()
		return
	# add_water returns false when the reservoir is full — stop on that signal.
	if not bool(plant.call("add_water", fill_rate * delta)):
		_stop_filling()


func _on_body_entered(body: Node3D) -> void:
	if body != null and body.is_in_group("ship"):
		_ship_inside = true


func _on_body_exited(body: Node3D) -> void:
	if body != null and body.is_in_group("ship"):
		_ship_inside = false
		_stop_filling()


## True when the ship is sitting still enough for safe refuelling. We check
## `current_speed` directly because the ship doesn't actually move in world
## space (see ship_controller.gd) — its physics velocity is irrelevant.
func _ship_is_stopped(ship: Node) -> bool:
	if not "current_speed" in ship:
		return false
	return absf(float(ship.current_speed)) <= stopped_speed_threshold


func _stop_filling() -> void:
	_filling = false
	set_physics_process(false)
