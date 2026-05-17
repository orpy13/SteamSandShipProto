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
## `hash(key)`. Reloading a chunk produces the same rocks/crates/posts in the
## same places, so unload-and-reload is a no-op for the player.
##

const WATER_TOWER_SCENE: PackedScene = preload("res://scenes/interactables/water_tower.tscn")
const OASIS_SCENE: PackedScene = preload("res://scenes/world/oasis.tscn")

# Hand-placed oasis locations so a playtest can reach them deterministically.
# Each entry: chunk key → oasis type ("mining" or "caravan").
const _HAND_PLACED_OASES: Dictionary = {
	Vector2i(6, 4):   "mining",
	Vector2i(-5, -3): "caravan",
	Vector2i(9, -7):  "mining",
	Vector2i(-10, 8): "caravan",
}

@export var chunk_size: float = 80.0
@export var load_radius: int = 3          # chunks loaded in each direction from ship
@export var subdivisions: int = 16        # vertices per side = subdivisions + 1
@export var height_scale: float = 3.5     # noise amplitude — dune height in metres
@export var noise_seed: int = 1337
@export var noise_frequency: float = 0.006
@export var noise_octaves: int = 2
@export var noise_lacunarity: float = 2.0
@export var noise_gain: float = 0.5
# Inset used when picking random positions for chunk objects (currently water
# towers; future villages, bandit camps, etc.) so they don't straddle chunk
# borders.
@export var placeholder_spawn_margin: float = 8.0

# Currently live chunks. Freed once they leave the load radius.
var _chunks: Dictionary = {}  # Vector2i → StaticBody3D

# Persistent per-chunk state across unload/reload (this session). Future hook
# for player-driven mutations (e.g. "this crate was destroyed in chunk 3,2").
# Schema: { "removed": Array[int], "objects": Array[Dictionary] }
var _chunk_data: Dictionary = {}

var _ship: Node3D = null
var _noise: FastNoiseLite


## Configure the noise sampler and load the chunks around the origin.
func _ready() -> void:
	add_to_group("terrain")
	_noise = FastNoiseLite.new()
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = noise_seed
	_noise.frequency = noise_frequency
	_noise.fractal_octaves = noise_octaves
	_noise.fractal_lacunarity = noise_lacunarity
	_noise.fractal_gain = 0.5
	_update_chunks(Vector3.ZERO)


## Public hook for ship_controller.gd. Returns dune height at a virtual world
## (x, z) so the ship can pitch/roll in response to the terrain underneath it.
func sample_height(world_x: float, world_z: float) -> float:
	if _noise == null:
		return 0.0
	return _noise.get_noise_2d(world_x, world_z) * height_scale


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
	# Future: scan node children for interactive objects whose state has
	# changed and write deltas into _chunk_data[key] before freeing.
	if node and is_instance_valid(node):
		node.queue_free()
	_chunks.erase(key)


## Build one chunk: height-field mesh + matching trimesh collider + scattered
## props. Vertices are evaluated at world-grid coordinates so neighbouring
## chunks naturally share edge values and the seams disappear.
func _spawn_chunk(key: Vector2i) -> Node3D:
	var body := StaticBody3D.new()
	body.name = "Chunk_%d_%d" % [key.x, key.y]
	body.add_to_group("terrain_chunk")  # ship_controller filters these out of collision

	var n: int = subdivisions + 1
	var step: float = chunk_size / float(subdivisions)
	var half: float = chunk_size * 0.5
	# World-space origin of this chunk's (0,0) corner in the chunk grid.
	var origin_x: float = key.x * chunk_size
	var origin_z: float = key.y * chunk_size

	# ── Height samples ──────────────────────────────────────────────────────
	# Evaluated at world-grid positions (not chunk-local) so adjacent chunks
	# share their edge heights and produce seamless borders for free.
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	for j in range(n):
		for i in range(n):
			var wx := origin_x + i * step
			var wz := origin_z + j * step
			heights[j * n + i] = _noise.get_noise_2d(wx, wz) * height_scale

	# ── Mesh ────────────────────────────────────────────────────────────────
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(n):
		for i in range(n):
			var lx := float(i) * step - half
			var lz := float(j) * step - half
			st.set_uv(Vector2(float(i) / subdivisions, float(j) / subdivisions))
			st.add_vertex(Vector3(lx, heights[j * n + i], lz))
	# Both triangle windings of a quad face produce a +Y normal (upward face).
	for j in range(subdivisions):
		for i in range(subdivisions):
			var v00 := j * n + i
			var v01 := j * n + (i + 1)
			var v10 := (j + 1) * n + i
			var v11 := (j + 1) * n + (i + 1)
			st.add_index(v00); st.add_index(v01); st.add_index(v10)
			st.add_index(v01); st.add_index(v11); st.add_index(v10)
	st.generate_normals()
	st.generate_tangents()
	var arr_mesh: ArrayMesh = st.commit()
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = arr_mesh
	# Sandy-tan dune colour.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.551, 0.488, 0.333, 1.0)
	mat.roughness = 1.0
	mat.metallic = 0.0
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	# ── Collision ───────────────────────────────────────────────────────────
	# create_trimesh_shape() mirrors the mesh exactly — no scaling gymnastics.
	# Used for player footing only; ship-vs-terrain is handled by the height
	# sampler above (see ship_controller._apply_terrain_following).
	var coll := CollisionShape3D.new()
	coll.shape = arr_mesh.create_trimesh_shape()
	body.add_child(coll)

	# Position the chunk so its local-space (0,0) sits at the chunk centre.
	body.position = Vector3(origin_x + half, 0.0, origin_z + half)

	_spawn_procedural_objects(body, key, heights, n, step, half)
	if _chunk_data.has(key):
		_apply_chunk_data(body, key)

	add_child(body)
	return body


## Scatter deterministic props for this chunk. The same key always produces
## the same layout, so reloading is seamless. Hook new world-features in here
## by extending `_ensure_chunk_data` and `_spawn_placeholder_object`.
func _spawn_procedural_objects(body: Node3D, key: Vector2i,
		heights: PackedFloat32Array, n: int, step: float, half: float) -> void:
	_ensure_chunk_data(key, heights, n, step, half)
	var data: Dictionary = _chunk_data[key]
	var removed: Array = data.get("removed", [])
	var objects: Array = data.get("objects", [])
	for idx in range(objects.size()):
		if removed.has(idx):
			continue
		_spawn_placeholder_object(body, objects[idx], idx)


## Lazily compute the persistent prop record for a chunk. Seeded from
## `hash(key)` so the layout is deterministic per-chunk.
##
## Currently only spawns water towers (sparse, never inside the starting load
## radius). The procedural rocks/crates/posts that used to scatter every
## chunk were removed; future meaningful props (oasis villages, bandit camps,
## wrecks) should plug in here alongside the water-tower branch.
func _ensure_chunk_data(key: Vector2i, heights: PackedFloat32Array,
		n: int, step: float, half: float) -> void:
	if _chunk_data.has(key):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var objects: Array = []
	if _should_spawn_water_tower(key):
		objects.append(_make_water_tower_record(rng, heights, n, step, half))
	if _HAND_PLACED_OASES.has(key):
		objects.append(_make_oasis_record(rng, heights, n, step, half, _HAND_PLACED_OASES[key]))
	_chunk_data[key] = {"removed": [], "objects": objects}


## Build the persistent record for an oasis instance. Subtype is "mining" or
## "caravan"; goes into the chunk_data so respawning the chunk re-creates the
## same oasis at the same position.
func _make_oasis_record(rng: RandomNumberGenerator, heights: PackedFloat32Array,
		n: int, step: float, half: float, oasis_type: String) -> Dictionary:
	# Place near the chunk centre; markets need flat-ish space and the centre
	# is the most "interior" part of the chunk relative to the load radius.
	var lx := rng.randf_range(-6.0, 6.0)
	var lz := rng.randf_range(-6.0, 6.0)
	var h := _height_from_grid(heights, n, step, half, lx, lz)
	return {
		"type": "oasis",
		"subtype": oasis_type,
		"pos": Vector3(lx, h, lz),
		"yaw": rng.randf_range(-PI, PI),
	}


## Should this chunk contain a water tower? Hand-placed at a handful of named
## coordinates for guaranteed early discovery; sparse random elsewhere. Never
## spawns inside the starting load radius (you have to actually travel to one).
func _should_spawn_water_tower(key: Vector2i) -> bool:
	var distance := maxi(absi(key.x), absi(key.y))
	if distance <= load_radius:
		return false
	if key == Vector2i(7, -5) or key == Vector2i(-8, 6) \
			or key == Vector2i(11, 4) or key == Vector2i(-12, -7):
		return true
	var roll := absi(hash(key)) % 100
	if distance <= 8:
		return roll < 3
	return roll < 2


## Build the persistent record for a water tower in this chunk.
func _make_water_tower_record(rng: RandomNumberGenerator, heights: PackedFloat32Array,
		n: int, step: float, half: float) -> Dictionary:
	var lx := rng.randf_range(-half + placeholder_spawn_margin, half - placeholder_spawn_margin)
	var lz := rng.randf_range(-half + placeholder_spawn_margin, half - placeholder_spawn_margin)
	var h := _height_from_grid(heights, n, step, half, lx, lz)
	return {
		"type": "water_tower",
		"pos": Vector3(lx, h, lz),
		"yaw": rng.randf_range(-PI, PI),
		"scale": 1.0,
	}


## Bilinear height lookup at an arbitrary chunk-local (lx, lz). Used to pose
## procedural props flush against the dune surface.
func _height_from_grid(heights: PackedFloat32Array, n: int, step: float,
		half: float, lx: float, lz: float) -> float:
	var gx := clampf((lx + half) / step, 0.0, float(n - 1))
	var gz := clampf((lz + half) / step, 0.0, float(n - 1))
	var x0 := int(floor(gx))
	var z0 := int(floor(gz))
	var x1 := mini(x0 + 1, n - 1)
	var z1 := mini(z0 + 1, n - 1)
	var tx := gx - float(x0)
	var tz := gz - float(z0)
	var h00 := heights[z0 * n + x0]
	var h10 := heights[z0 * n + x1]
	var h01 := heights[z1 * n + x0]
	var h11 := heights[z1 * n + x1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


## Instance one prop into the chunk. Dispatch on the `type` string in the
## record; new prop kinds add a branch here and (typically) a corresponding
## entry in `_ensure_chunk_data`.
func _spawn_placeholder_object(body: Node3D, obj: Dictionary, idx: int) -> void:
	match String(obj.get("type", "")):
		"water_tower":
			var tower := WATER_TOWER_SCENE.instantiate()
			tower.name = "WaterTower_%03d" % idx
			tower.position = obj.get("pos", Vector3.ZERO)
			tower.rotation.y = float(obj.get("yaw", 0.0))
			body.add_child(tower)
		"oasis":
			var oasis := OASIS_SCENE.instantiate()
			oasis.name = "Oasis_%03d" % idx
			# Set oasis_type BEFORE add_child so _ready propagates it to the
			# child Market in time.
			oasis.set("oasis_type", String(obj.get("subtype", "mining")))
			oasis.position = obj.get("pos", Vector3.ZERO)
			oasis.rotation.y = float(obj.get("yaw", 0.0))
			body.add_child(oasis)
		_:
			# Unknown type — silently skip rather than spawning placeholder geometry.
			pass


## Re-apply persisted mutations on top of the freshly generated chunk.
## "removed" lists procedural-object indices to skip; "objects" lists
## manually placed/modified objects to re-spawn with their saved state.
func _apply_chunk_data(body: Node3D, key: Vector2i) -> void:
	@warning_ignore("unused_variable")
	var data: Dictionary = _chunk_data[key]
	# Future:
	#   for idx in data["removed"]: skip or destroy procedural object at idx
	#   for obj in data["objects"]: instantiate obj["scene"] at obj["pos"] with obj["state"]
	pass
