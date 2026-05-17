class_name ChunkObject
extends Resource

# One hand-authored object placed into a chunk via an overlay.
# If scene_path is set, that scene is instantiated; otherwise `type` selects a
# built-in placeholder primitive (rock / crate / post / water_tower) built by
# ChunkGen — the same factories the procedural pass uses.

@export var type: String = "rock"
@export var scene_path: String = ""
# Chunk-local position. y should be the terrain height at (x, z); the editor
# plugin (phase 4) will snap this for you.
@export var pos: Vector3 = Vector3.ZERO
@export var yaw: float = 0.0
@export var scale: float = 1.0
