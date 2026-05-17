class_name ChunkOverlay
extends Resource

# Tier-2 bespoke authoring: keeps the procedural noise mesh untouched (so chunk
# edges stay seamless for free) and only edits the props on top of it.
#
#   removed — indices into the chunk's deterministic procedural object list
#             (same ordering ChunkGen.build_object_records produces) to skip.
#   added   — extra hand-placed objects to spawn after the procedural pass.
#
# `added` is left untyped on purpose: typed Array[ChunkObject] serialises
# awkwardly into hand-written .tres files, and this resource is meant to be
# hand-authorable until the phase-4 editor plugin lands.

@export var removed: PackedInt32Array = PackedInt32Array()
@export var added: Array = []
