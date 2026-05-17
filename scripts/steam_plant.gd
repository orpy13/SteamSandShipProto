extends Node
##
## STEAM PLANT — the ship's boiler simulation.
##
## Chain of cause and effect:
##
##     coal_in_firebox  ──burn──▶  fire_heat  ──heat × pressure_gain──▶  steam_pressure
##                                                                            │
##                                                                            ▼
##                                                                   request_power → drive
##
## Water is consumed proportional to steam generated; if water_level hits 0
## we stop generating steam. Above relief_pressure the safety valve dumps
## pressure to keep us from overshooting max_pressure.
##
## Authority: simulated only on the host. State broadcast to clients via the
## delta-throttled `_receive_state` RPC — we don't use a MultiplayerSynchronizer
## because the noise of float updates would otherwise spam the network.
##

signal steam_changed(pressure: float, heat: float, coal: float, water: float)

# ── Capacities and limits ────────────────────────────────────────────────────
@export var max_pressure: float = 100.0       # safety-valve ceiling
@export var working_pressure: float = 45.0    # power_ratio reaches 1.0 here
@export var max_water_level: float = 100.0

# ── Coal combustion ──────────────────────────────────────────────────────────
@export var coal_energy: float = 50.0         # heat units per coal-mass burned
@export var coal_burn_rate: float = 0.1      # coal mass burned per second
@export var heat_gain_rate: float = 7.0       # multiplier on burned-coal → heat
@export var heat_loss_rate: float = 3.0       # ambient cooling per second

# ── Steam dynamics ───────────────────────────────────────────────────────────
@export var pressure_gain_rate: float = 0.09  # heat × this × dt = pressure gained
@export var pressure_loss_rate: float = 1.1   # idle leak per second
@export var steam_draw_rate: float = 9.0      # pressure consumed per unit demand
@export var water_use_rate: float = 0.04      # water consumed per pressure generated
@export var relief_pressure: float = 95.0     # safety valve cracks open here
@export var relief_rate: float = 15.0         # how fast it vents

# ── Live state (authoritative on host, replicated to clients) ────────────────
var steam_pressure: float = 0.0
var fire_heat: float = 0.0
var coal_in_firebox: float = 0.0
var max_coal: float = 10
var water_level: float = 100.0
var current_load: float = 0.0  # last-frame demand reported by the ship

# Cache of last broadcast values — we only RPC when something changed enough
# to be worth a packet. Saves a *lot* of bandwidth at steady state.
var _last_sync_pressure: float = -1.0
var _last_sync_heat: float = -1.0
var _last_sync_coal: float = -1.0
var _last_sync_water: float = -1.0


## Host-only simulation tick. Burn coal, generate steam, satisfy load.
##
## Reads the parent ship's `system_integrity["power"]` once per tick to scale
## natural pressure loss and water consumption. A damaged boiler leaks more —
## same coal/water inputs produce less effective range until repaired.
func _physics_process(delta: float) -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return

	# Damage scaling: power integrity 1.0 = leaks at baseline rates; 0.0 = up
	# to leak_max× faster on both pressure and water consumption.
	var ship := get_parent()
	var power_int := 1.0
	if ship != null and "system_integrity" in ship:
		power_int = float(ship.system_integrity.get("power", 1.0))
	const LEAK_MAX_MULT := 3.0
	var leak_mult := 1.0 + (1.0 - power_int) * (LEAK_MAX_MULT - 1.0)

	# ── Burn coal → heat ──────────────────────────────────────────────────
	var burn := minf(coal_in_firebox, coal_burn_rate * delta)
	coal_in_firebox -= burn
	fire_heat += burn * coal_energy * heat_gain_rate
	fire_heat = move_toward(fire_heat, 0.0, heat_loss_rate * delta)

	# ── Heat + water → steam pressure ─────────────────────────────────────
	# Water leaks at leak_mult, so damaged boilers drain the reservoir faster.
	if water_level > 0.0 and fire_heat > 1.0:
		var generation := fire_heat * pressure_gain_rate * delta
		steam_pressure = minf(steam_pressure + generation, max_pressure)
		water_level = maxf(0.0, water_level - generation * water_use_rate * leak_mult)

	# ── Engine draw → pressure consumption ────────────────────────────────
	var engine_order := 0
	if ship != null and "engine_order" in ship:
		engine_order = int(ship.engine_order)
	var demand := _order_demand(engine_order)
	current_load = demand
	if demand > 0.0:
		steam_pressure = maxf(0.0, steam_pressure - steam_draw_rate * demand * delta)

	# ── Natural losses and safety valve ───────────────────────────────────
	# Pressure also leaks faster on a damaged boiler.
	var natural_loss := pressure_loss_rate * leak_mult * delta
	steam_pressure = maxf(0.0, steam_pressure - natural_loss)
	if steam_pressure > relief_pressure:
		steam_pressure = maxf(relief_pressure, steam_pressure - relief_rate * delta)

	fire_heat = clampf(fire_heat, 0.0, 100.0)
	steam_pressure = clampf(steam_pressure, 0.0, max_pressure)
	_sync_if_changed()


## Add coal to the firebox. Returns false if the firebox is already full
## (the stoker hangs onto their load instead of wasting it).
func add_coal(loads: float = 1.0) -> bool:
	if coal_in_firebox >= max_coal:
		return false
	coal_in_firebox = minf(coal_in_firebox + loads, max_coal)
	_sync_if_changed(true)
	return true


## Add water to the boiler reservoir. Returns false at capacity so the water
## tower can know to stop the fill.
func add_water(amount: float) -> bool:
	if water_level >= max_water_level:
		return false
	water_level = minf(water_level + amount, max_water_level)
	_sync_if_changed(true)
	return true


## Called by the ship each frame: "I want this much engine power — what
## fraction can you actually give me?". Below working_pressure we deliver a
## proportional amount; above it we deliver full power.
func request_power(engine_order: int, _delta: float) -> float:
	var demand := _order_demand(engine_order)
	current_load = demand
	if demand <= 0.0:
		return 0.0
	var available := clampf(steam_pressure / working_pressure, 0.0, 1.0)
	return available


## Convenience for the HUD: pressure as 0–100%.
func get_pressure_percent() -> float:
	return clampf(steam_pressure / max_pressure * 100.0, 0.0, 100.0)


## Telegraph-order → fraction of full steam draw. Higher orders demand
## disproportionately more steam — slow ahead is cheap, full ahead is hungry.
func _order_demand(engine_order: int) -> float:
	match abs(engine_order):
		1: return 0.35
		2: return 0.6
		3: return 0.82
		4: return 1.0
		_: return 0.0


## Emit local signal and (host only) broadcast state to clients, but only when
## something has drifted past the per-field threshold. `force = true` for
## discrete events like add_coal / add_water that need to be seen immediately.
func _sync_if_changed(force: bool = false) -> void:
	if not force:
		if absf(steam_pressure - _last_sync_pressure) < 0.25 \
				and absf(fire_heat - _last_sync_heat) < 0.25 \
				and absf(coal_in_firebox - _last_sync_coal) < 0.05 \
				and absf(water_level - _last_sync_water) < 0.25:
			return
	_last_sync_pressure = steam_pressure
	_last_sync_heat = fire_heat
	_last_sync_coal = coal_in_firebox
	_last_sync_water = water_level
	steam_changed.emit(steam_pressure, fire_heat, coal_in_firebox, water_level)
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_receive_state.rpc(steam_pressure, fire_heat, coal_in_firebox, water_level, current_load)


## Client-side state overwrite. Unreliable is fine — we'll get another update
## shortly and the simulation reads as smooth at this update cadence.
@rpc("authority", "call_remote", "unreliable")
func _receive_state(pressure: float, heat: float, coal: float, water: float, load: float) -> void:
	steam_pressure = pressure
	fire_heat = heat
	coal_in_firebox = coal
	water_level = water
	current_load = load
	steam_changed.emit(steam_pressure, fire_heat, coal_in_firebox, water_level)
