extends Node3D
##
## CHUNK MANAGER — the procedural desert under the sand ship.
##
## Two responsibilities:
##
##   1. Generate the dune-field on demand. We tile the world into square
##      chunks of `chunk_size` units, each built from a noise-driven height
##      mesh. Adjacent chunks share edge samples (noise is evaluated at
##      world-grid positions, not chunk-local ones), so borders match
##      seamlessly with no stitching.
##
##   2. Scroll the world to fake ship motion. The ship never moves in world
##      space; instead we read its `virtual_yaw` and `world_offset` and apply
##      the *inverse* to this node's transform so the dunes slide under a
##      stationary deck. See ship_controller.gd for the full explanation.
##
## Determinism: every chunk's procedural-prop layout is seeded from
## `hash(key)`. Reloading a chunk produces the same props in the same places.
##
## All mesh/object generation lives in ChunkGen (node-free, static) so the
## bespoke-chunk editor previews exactly what the runtime streams. Per-chunk
## bespoke overrides are resolved through an optional ChunkRegistry:
##   - "scene"   → a hand-authored .tscn replaces the procedural chunk
##   - "overlay" → procedural mesh kept; props added/removed on top
##

@export var chunk_size: float = 80.0
@export var load_radius: int = 3          # chunks loaded in each direction from ship
@export var subdivisions: int = 16        # vertices per side = subdivisions + 1
## Shared world seed for the regional noise field (Regions autoload). Per-region
## noise frequencies / octaves / amplitudes are defined in `regions.gd`; this
## seed is the only piece of world state ChunkManager still owns.
@export var noise_seed: int = 1337
# Inset used when picking random positions for chunk objects so they don't
# straddle chunk borders.
@export var placeholder_spawn_margin: float = 8.0

# Bespoke-chunk registry. Assign in the inspector, or drop a registry at the
# default path below and it is picked up automatically (export-PCK safe).
@export var chunk_registry: ChunkRegistry
const DEFAULT_REGISTRY_PATH := "res://chunks/registry.tres"

# Currently live chunks. Freed once they leave the load radius.
var _chunks: Dictionary = {}  # Vector2i → StaticBody3D

# Persistent per-chunk state across unload/reload (this session).
# Schema: { "removed": Array[int], "objects": Array[Dictionary] }
var _chunk_data: Dictionary = {}

var _ship: Node3D = null


## Hand our world seed to the Regions autoload (so the regional noise field
## stays deterministic from the same export) and load the chunks around the
## origin.
func _ready() -> void:
	add_to_group("terrain")
	Regions.set_world_seed(noise_seed)
	if chunk_registry == null and ResourceLoader.exists(DEFAULT_REGISTRY_PATH):
		chunk_registry = load(DEFAULT_REGISTRY_PATH)
	_build_sea_plane()
	_update_chunks(Vector3.ZERO)


## Code-built water plane (Tier 2, T2.1). Parented to WorldMap so the
## world-scroll trick keeps it pinned to the geographic origin while the ship
## sails over it. Sized to the finite world extent; sits at SEA_LEVEL. Coast
## terrain (Regions.ID_COAST) is offset well below this Y so it reads as
## submerged shore; everywhere else the terrain is above water and hides the
## plane.
func _build_sea_plane() -> void:
	if has_node("SeaPlane"):
		return
	var extent: float = Regions.WORLD_HALF_EXTENT * 2.0 + Regions.BORDER_BAND * 2.0
	var mesh := MeshInstance3D.new()
	mesh.name = "SeaPlane"
	var pm := PlaneMesh.new()
	pm.size = Vector2(extent, extent)
	mesh.mesh = pm
	mesh.position = Vector3(0.0, Regions.SEA_LEVEL, 0.0)
	var mat := StandardMaterial3D.new()
	# A muted blue-teal: not photoreal, but readable as "that's the sea" at
	# distance. Slight transparency so the underlying coast dunes hint through.
	mat.albedo_color = Color(0.18, 0.30, 0.42, 0.92)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.metallic = 0.1
	mat.roughness = 0.35
	mesh.material_override = mat
	# Don't shadow the dunes inland — the plane stretches far past any chunk.
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh)


## Public hook for ship_controller.gd. Returns dune height at a virtual world
## (x, z) so the ship can pitch/roll in response to the terrain underneath it.
## Forwards to ChunkGen, which blends every active region's contribution.
func sample_height(world_x: float, world_z: float) -> float:
	return ChunkGen.sample_height(world_x, world_z)


## The world-scroll trick (see file header). Every physics frame: rotate and
## translate this node by the inverse of the ship's virtual pose so the
## dunes appear to slide past a stationary deck.
func _physics_process(_delta: float) -> void:
	if _ship == null or not is_instance_valid(_ship):
		_ship = get_tree().get_first_node_in_group("ship")
	if _ship == null:
		return
	var off: Vector3 = _ship.world_offset
	var yaw: float = _ship.virtual_yaw
	# Pre-rotate the offset so the rotation pivot stays exactly under the ship.
	position = -(Basis(Vector3.UP, -yaw) * off)
	rotation.y = -yaw
	_update_chunks(off)


## Spawn anything inside `load_radius` chunks of `center` and free anything
## outside it. Called every physics frame; cheap because the loaded set
## changes slowly.
func _update_chunks(center: Vector3) -> void:
	var cx := int(floor(center.x / chunk_size))
	var cz := int(floor(center.z / chunk_size))
	var needed: Dictionary = {}
	for dx in range(-load_radius, load_radius + 1):
		for dz in range(-load_radius, load_radius + 1):
			var key := Vector2i(cx + dx, cz + dz)
			needed[key] = true
			if not _chunks.has(key):
				_chunks[key] = _spawn_chunk(key)
	var to_remove: Array = []
	for key in _chunks.keys():
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		_unload_chunk(key)


## Persist any mutations into `_chunk_data` (todo) then free the live node.
func _unload_chunk(key: Vector2i) -> void:
	var node: Node = _chunks.get(key)
	if not _chunk_data.has(key):
		_chunk_data[key] = {"removed": [], "objects": []}
	if node and is_instance_valid(node):
		node.queue_free()
	_chunks.erase(key)


## Build one chunk. Resolution order: bespoke scene override → procedural mesh
## (+ optional overlay) → plain procedural.
func _spawn_chunk(key: Vector2i) -> Node3D:
	var entry := _registry_entry(key)
	if String(entry.get("mode", "")) == "scene":
		return _spawn_scene_chunk(key, String(entry.get("path", "")))

	var built := ChunkGen.build_chunk_body(key, chunk_size, subdivisions)
	var body: StaticBody3D = built["body"]
	var heights: PackedFloat32Array = built["heights"]
	var n: int = built["n"]
	var step: float = built["step"]
	var half: float = built["half"]

	var overlay := _load_overlay(entry)
	_spawn_procedural_objects(body, key, heights, n, step, half, overlay)
	_spawn_overlay_added(body, overlay)

	add_child(body)
	return body


## Look up the bespoke entry for a chunk key, {} if none / no registry.
func _registry_entry(key: Vector2i) -> Dictionary:
	if chunk_registry == null:
		return {}
	return chunk_registry.get_entry(key)


## Load the ChunkOverlay resource referenced by an overlay-mode entry.
func _load_overlay(entry: Dictionary) -> ChunkOverlay:
	if String(entry.get("mode", "")) != "overlay":
		return null
	var path := String(entry.get("path", ""))
	if path == "" or not ResourceLoader.exists(path):
		push_warning("ChunkManager: overlay path missing: %s" % path)
		return null
	var res: Resource = load(path)
	if res is ChunkOverlay:
		return res
	push_warning("ChunkManager: %s is not a ChunkOverlay" % path)
	return null


## Bespoke tier-1: instantiate a hand-authored chunk scene in place of the
## procedural one. Position is re-applied here (the .tscn root is authored at
## the origin) so the saved scene is grid-independent.
func _spawn_scene_chunk(key: Vector2i, path: String) -> Node3D:
	if path == "" or not ResourceLoader.exists(path):
		push_warning("ChunkManager: scene chunk path missing: %s" % path)
		return null
	var ps: Resource = load(path)
	if not (ps is PackedScene):
		push_warning("ChunkManager: %s is not a PackedScene" % path)
		return null
	var body: Node3D = (ps as PackedScene).instantiate()
	body.name = "Chunk_%d_%d" % [key.x, key.y]
	if not body.is_in_group("terrain_chunk"):
		body.add_to_group("terrain_chunk")
	var half: float = chunk_size * 0.5
	body.position = Vector3(key.x * chunk_size + half, 0.0,
			key.y * chunk_size + half)
	add_child(body)
	return body


## Spawn the overlay's hand-placed objects after the procedural pass.
func _spawn_overlay_added(body: Node3D, overlay: ChunkOverlay) -> void:
	if overlay == null:
		return
	for i in range(overlay.added.size()):
		var obj: Variant = overlay.added[i]
		if obj is ChunkObject:
			ChunkGen.spawn_overlay_object(body, obj, i)
		else:
			push_warning("ChunkManager: overlay.added[%d] is not a ChunkObject" % i)


## Scatter deterministic props for this chunk via ChunkGen, skipping any the
## overlay removes. The same key always produces the same layout.
func _spawn_procedural_objects(body: Node3D, key: Vector2i,
		heights: PackedFloat32Array, n: int, step: float, half: float,
		overlay: ChunkOverlay) -> void:
	_ensure_chunk_data(key, heights, n, step, half)
	var data: Dictionary = _chunk_data[key]
	var removed: Array = data.get("removed", [])
	var objects: Array = data.get("objects", [])
	for idx in range(objects.size()):
		if removed.has(idx):
			continue
		if overlay != null and idx in overlay.removed:
			continue
		ChunkGen.spawn_placeholder_object(body, objects[idx], idx)


## Lazily compute the persistent prop record for a chunk (delegated to
## ChunkGen so previews and runtime agree exactly).
func _ensure_chunk_data(key: Vector2i, heights: PackedFloat32Array,
		n: int, step: float, half: float) -> void:
	if _chunk_data.has(key):
		return
	var objects := ChunkGen.build_object_records(key, heights, n, step, half,
			load_radius, placeholder_spawn_margin)
	_chunk_data[key] = {"removed": [], "objects": objects}
