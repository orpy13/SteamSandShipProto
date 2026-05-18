extends Interactable
##
## WATER TANK — onboard boiler-feedwater access point (Tier 1, ROADMAP.md →
## T1.2).
##
## The boiler reservoir lives on `SteamPlant` (water towers out in the desert
## still top it up directly). This station lets the crew refill it from the
## hold's `water` cargo while under way, so you no longer have to find a tower
## — but it costs traded `water`, which is then unavailable to sell.
##
## Explicit, server-only: one E press transfers as much hold `water` as the
## boiler can take (each cargo unit = `water_per_unit` boiler units).
##

@export var water_per_unit: float = 25.0  # boiler water gained per cargo "water" unit


func _ready() -> void:
	prompt_text = "Press E to feed boiler from hold"


## Context-aware prompt: boiler fill + hold water on hand.
func get_prompt(_player: Node) -> String:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null:
		return prompt_text
	var plant := ship.get_node_or_null("SteamPlant")
	var pct := 0
	if plant != null and "water_level" in plant and "max_water_level" in plant:
		pct = int(round(float(plant.water_level) / maxf(float(plant.max_water_level), 0.001) * 100.0))
	var hold := _hold_water()
	if pct >= 100:
		return "Boiler water full (%d in hold)" % hold
	if hold <= 0:
		return "No water in hold (boiler %d%%)" % pct
	return "Press E to feed boiler from hold (boiler %d%%, %d in hold)" % [pct, hold]


## Server-only. Spend hold `water` to fill the boiler reservoir.
func interact(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not ship.has_method("remove_cargo"):
		return
	var plant := ship.get_node_or_null("SteamPlant")
	if plant == null or not plant.has_method("add_water") \
			or not "water_level" in plant or not "max_water_level" in plant:
		return
	var deficit: float = float(plant.max_water_level) - float(plant.water_level)
	if deficit <= 0.01:
		return  # already full
	var want_units: int = int(ceil(deficit / maxf(water_per_unit, 0.001)))
	var move: int = mini(want_units, _hold_water())
	if move <= 0:
		return
	if not ship.remove_cargo("water", move):
		return
	super(peer_id)
	# add_water caps at the reservoir max internally; any rounding spill is a
	# negligible, intentional simplification.
	plant.call("add_water", float(move) * water_per_unit)


func _hold_water() -> int:
	var ship := get_tree().get_first_node_in_group("ship")
	if ship == null or not "cargo" in ship:
		return 0
	return int(ship.cargo.get("water", 0))
