extends Node3D
##
## OASIS — a village in the dunes with a market for trade.
##
## For the prototype an oasis is just a market stall with a couple of
## decorative huts around it. `oasis_type` propagates to the child Market so
## the chunk manager can spawn variants (mining vs caravan) without needing
## two separate scenes.
##

@export var oasis_type: String = "mining":
	set(value):
		oasis_type = value
		_apply_type_to_market()


func _ready() -> void:
	_apply_type_to_market()


## Push our oasis_type down to the Market child if present. Tolerant of being
## called before _ready (setter path) when the child node may not exist yet.
func _apply_type_to_market() -> void:
	var market := get_node_or_null("Market")
	if market != null:
		market.set("oasis_type", oasis_type)
