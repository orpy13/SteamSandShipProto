class_name ChunkRegistry
extends Resource

# Single source of truth for which chunk keys are bespoke and how.
# String keys "x,y" (instead of Vector2i) keep the .tres hand-authorable and
# diff-friendly. The phase-4 editor plugin will maintain this automatically.
#
# entries: { "x,y": { "mode": "overlay" | "scene", "path": "res://..." } }

@export var entries: Dictionary = {}

func get_entry(key: Vector2i) -> Dictionary:
	var e: Variant = entries.get("%d,%d" % [key.x, key.y], null)
	if e is Dictionary:
		return e
	return {}
