class_name Goods
extends Object
##
## GOODS REGISTRY — central data for every tradeable commodity.
##
## Pure static helper (no scene). Reference via `Goods.foo(...)` from anywhere
## without preload. Goods are identified by their `good_id` string ("coal",
## "water", "spice"). Each has a display name, a carry-item id used when a
## player picks up a crate, and a tint colour applied to the crate mesh.
##
## Prices are per-oasis-type — Mining oases produce coal cheap and pay top
## £ for spice; Caravan oases are the inverse. Buy > sell at every oasis
## (the oasis's margin), so profit only comes from inter-oasis arbitrage.
##

const ALL: Dictionary = {
	"coal": {
		"display_name": "Coal",
		"carry_id": "cargo_coal",
		"color": Color(0.08, 0.08, 0.08, 1),
	},
	"water": {
		"display_name": "Water",
		"carry_id": "cargo_water",
		"color": Color(0.3, 0.5, 0.7, 1),
	},
	"spice": {
		"display_name": "Spice",
		"carry_id": "cargo_spice",
		"color": Color(0.85, 0.45, 0.15, 1),
	},
	# ── Tier 1 provisions / supplies (see ROADMAP.md → T1.1) ────────────────
	# Just goods like any other: bought/sold at oasis markets, held in the
	# hold, but also *consumable* — kits repair ship parts, food/drinking
	# water satisfy crew needs. One generic food for now.
	"repair_kit": {
		"display_name": "Repair Kit",
		"carry_id": "cargo_repair_kit",
		"color": Color(0.45, 0.30, 0.15, 1),
	},
	"food": {
		"display_name": "Rations",
		"carry_id": "cargo_food",
		"color": Color(0.55, 0.45, 0.25, 1),
	},
	"drinking_water": {
		"display_name": "Drinking Water",
		"carry_id": "cargo_drinking_water",
		"color": Color(0.35, 0.65, 0.80, 1),
	},
	# ── Physical consumable items (scenes/items/*). Not market-traded for now
	# (`tradeable=false` keeps them out of the trade panel); they live in the
	# hold, are withdrawn into hand, and are eaten/drunk to satisfy needs.
	"water_bottle": {
		"display_name": "Water Bottle",
		"carry_id": "item_water_bottle",
		"color": Color(0.35, 0.65, 0.85, 1),
		"tradeable": false,
	},
	"sausage": {
		"display_name": "Sausage",
		"carry_id": "item_sausage",
		"color": Color(0.7, 0.35, 0.25, 1),
		"tradeable": false,
	},
}


## Market-tradeable? Defaults true; physical test items set it false so the
## trade panel skips them.
static func is_tradeable(good_id: String) -> bool:
	if not ALL.has(good_id):
		return false
	return bool(ALL[good_id].get("tradeable", true))

const PRICES: Dictionary = {
	"mining": {
		"coal":  { "buy": 8,  "sell": 6 },
		"water": { "buy": 14, "sell": 10 },
		"spice": { "buy": 30, "sell": 25 },
		"repair_kit":     { "buy": 40, "sell": 30 },
		"food":           { "buy": 12, "sell": 8 },
		"drinking_water": { "buy": 10, "sell": 7 },
	},
	"caravan": {
		"coal":  { "buy": 20, "sell": 15 },
		"water": { "buy": 8,  "sell": 6 },
		"spice": { "buy": 15, "sell": 10 },
		"repair_kit":     { "buy": 35, "sell": 26 },
		"food":           { "buy": 9,  "sell": 6 },
		"drinking_water": { "buy": 14, "sell": 10 },
	},
}


static func get_buy_price(oasis_type: String, good_id: String) -> int:
	if not PRICES.has(oasis_type) or not PRICES[oasis_type].has(good_id):
		return 0
	return int(PRICES[oasis_type][good_id].get("buy", 0))


static func get_sell_price(oasis_type: String, good_id: String) -> int:
	if not PRICES.has(oasis_type) or not PRICES[oasis_type].has(good_id):
		return 0
	return int(PRICES[oasis_type][good_id].get("sell", 0))


## carry_id is the string the player_controller stores in carried_item_type
## when holding a crate of this good (e.g. "cargo_coal").
static func get_carry_id(good_id: String) -> String:
	if not ALL.has(good_id):
		return ""
	return String(ALL[good_id].get("carry_id", ""))


## Inverse lookup — given a carry_id like "cargo_coal", return the good_id.
static func good_from_carry_id(carry_id: String) -> String:
	for good_id in ALL.keys():
		if String(ALL[good_id].get("carry_id", "")) == carry_id:
			return good_id
	return ""


static func get_display_name(good_id: String) -> String:
	if not ALL.has(good_id):
		return good_id.capitalize()
	return String(ALL[good_id].get("display_name", good_id.capitalize()))


static func get_color(good_id: String) -> Color:
	if not ALL.has(good_id):
		return Color.WHITE
	return ALL[good_id].get("color", Color.WHITE)


## True if the supplied carry_id matches any cargo good.
static func is_cargo_carry(carry_id: String) -> bool:
	return not good_from_carry_id(carry_id).is_empty()
