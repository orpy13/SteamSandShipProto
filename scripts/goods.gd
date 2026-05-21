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

## Cargo good entries. `prop_scene` is the physical RigidBody3D scene used
## both as a world item (spawned by DropManager / OasisMarket) and as the
## in-hand carry visual; `carry_scale` shrinks the same prop to a sensible
## hand size. World items have their physics live; carry instances are
## frozen kinematic + collision-zero (see `player_controller._make_item_visual`).
## Pairs intentionally share a prop (water/drinking_water → barrel,
## food/repair_kit → crate) so silhouettes read as "vaguely similar" at
## distance and the Label3D disambiguates at pickup range.
const ALL: Dictionary = {
	"coal": {
		"display_name": "Coal",
		"carry_id": "cargo_coal",
		"color": Color(0.08, 0.08, 0.08, 1),
		"prop_scene": "res://scenes/items/sack_1.tscn",
		"carry_scale": 0.45,
	},
	"water": {
		"display_name": "Water",
		"carry_id": "cargo_water",
		"color": Color(0.3, 0.5, 0.7, 1),
		"prop_scene": "res://scenes/items/barrel.tscn",
		"carry_scale": 0.45,
	},
	"spice": {
		"display_name": "Spice",
		"carry_id": "cargo_spice",
		"color": Color(0.85, 0.45, 0.15, 1),
		"prop_scene": "res://scenes/items/sack_prop.tscn",
		"carry_scale": 0.45,
	},
	# ── Tier 1 provisions / supplies (see ROADMAP.md → T1.1) ────────────────
	# Just goods like any other: bought/sold at oasis markets, held in the
	# hold, but also *consumable* — kits repair ship parts, food/drinking
	# water satisfy crew needs. One generic food for now.
	"repair_kit": {
		"display_name": "Repair Kit",
		"carry_id": "cargo_repair_kit",
		"color": Color(0.45, 0.30, 0.15, 1),
		"prop_scene": "res://scenes/items/crate.tscn",
		"carry_scale": 0.30,
	},
	"food": {
		"display_name": "Rations",
		"carry_id": "cargo_food",
		"color": Color(0.55, 0.45, 0.25, 1),
		"prop_scene": "res://scenes/items/crate.tscn",
		"carry_scale": 0.30,
	},
	"drinking_water": {
		"display_name": "Drinking Water",
		"carry_id": "cargo_drinking_water",
		"color": Color(0.35, 0.65, 0.80, 1),
		"prop_scene": "res://scenes/items/barrel.tscn",
		"carry_scale": 0.45,
	},
	# ── Physical consumable items (scenes/items/*). Not market-traded for now
	# (`tradeable=false` keeps them out of the trade panel); they live in the
	# hold, are withdrawn into hand, and are eaten/drunk to satisfy needs.
	"water_bottle": {
		"display_name": "Water Bottle",
		"carry_id": "item_water_bottle",
		"color": Color(0.35, 0.65, 0.85, 1),
		"prop_scene": "res://scenes/items/water_bottle.tscn",
		"carry_scale": 1.0,
		"tradeable": false,
	},
	"sausage": {
		"display_name": "Sausage",
		"carry_id": "item_sausage",
		"color": Color(0.7, 0.35, 0.25, 1),
		"prop_scene": "res://scenes/items/sausage.tscn",
		"carry_scale": 1.0,
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


## Path to the physical prop scene used both as a world item (DropManager /
## OasisMarket spawns) and as the in-hand carry visual. Empty string for
## goods without a prop (e.g. raw tools like the coal shovel).
static func get_prop_scene(good_id: String) -> String:
	if not ALL.has(good_id):
		return ""
	return String(ALL[good_id].get("prop_scene", ""))


## Scale applied when the prop is instanced into the player's carry socket.
## Defaults to 0.45 — prop_scenes are sized for the world, so shrink for hand.
static func get_carry_scale(good_id: String) -> float:
	if not ALL.has(good_id):
		return 0.45
	return float(ALL[good_id].get("carry_scale", 0.45))


## Reverse-lookup convenience: `prop_scene` for a `carry_id`. Used by the
## DropManager + the player carry visual factory so callers don't have to
## go through `good_from_carry_id` first.
static func prop_scene_for_carry(carry_id: String) -> String:
	var good_id := good_from_carry_id(carry_id)
	if good_id.is_empty():
		return ""
	return get_prop_scene(good_id)


## Same shape, for the carry-socket scale of an item identified by
## `carry_id`.
static func carry_scale_for_carry(carry_id: String) -> float:
	var good_id := good_from_carry_id(carry_id)
	if good_id.is_empty():
		return 0.45
	return get_carry_scale(good_id)


## True if the supplied carry_id matches any cargo good.
static func is_cargo_carry(carry_id: String) -> bool:
	return not good_from_carry_id(carry_id).is_empty()
