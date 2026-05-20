class_name ChunkGen
extends RefCounted

# Shared, node-free chunk generation. Both the runtime streamer
# (chunk_manager.gd) and the editor authoring tools call into here so a
# previewed chunk is bit-identical to a streamed one.
#
# Region-aware (Tier 2, T2.0): the heightfield is a per-vertex weighted blend
# of every region's own noise, and the terrain tint is a per-vertex blend of
# region colours (painted via vertex colours; the material multiplies by
# white so the per-vertex blend is the visible albedo). See
# `scripts/autoloads/regions.gd` for the sampler that drives this.

const WATER_TOWER_SCENE: PackedScene = preload("res://scenes/interactables/water_tower.tscn")
const OASIS_SCENE: PackedScene = preload("res://scenes/world/oasis.tscn")

# Curated oasis / settlement placement moved to `POIRegistry` (Tier 2, T2.2).
# Kept as a compatibility shim so anything reading this const still resolves;
# new code should call POIRegistry.settlements_in_chunk(key, chunk_size).
const HAND_PLACED_OASES: Dictionary = {}

# Per-region FastNoiseLite cache. Keyed by "{region_id}:{world_seed}" so a
# world-seed change invalidates entries automatically. Static so the runtime
# streamer and the editor preview share the same instances (parity).
static var _noise_cache: Dictionary = {}


## Get (or lazily build) the FastNoiseLite that drives a region's heightfield.
## Seeds combine the region id and `Regions.world_seed` so each region has its
## own pattern that still moves deterministically when the world seed changes.
static func _region_noise(rd) -> FastNoiseLite:
	var seed_value: int = Regions.world_seed
	var key := "%s:%d" % [rd.id, seed_value]
	if _noise_cache.has(key):
		return _noise_cache[key]
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = seed_value ^ hash(rd.id)
	noise.frequency = rd.noise_frequency
	noise.fractal_octaves = rd.noise_octaves
	noise.fractal_lacunarity = rd.noise_lacunarity
	noise.fractal_gain = 0.5
	_noise_cache[key] = noise
	return noise


## Blended height at a world point.
##   height = Σ weight_i × (noise_i(x,z) × scale_i + offset_i)
## The offset term lets border biomes anchor well above (mountains) or below
## (coast) sea level without changing the wave shape. Public — see
## `ChunkManager.sample_height`.
static func sample_height(world_x: float, world_z: float) -> float:
	var weights := Regions.region_weights(world_x, world_z)
	var h := 0.0
	for id in weights.keys():
		var w: float = float(weights[id])
		if w <= 0.0:
			continue
		var rd = Regions.get_data(String(id))
		h += w * (_region_noise(rd).get_noise_2d(world_x, world_z) * rd.height_scale + rd.height_offset)
	return h


## Blended terrain tint at a world point (vertex-colour input).
static func sample_tint(world_x: float, world_z: float) -> Color:
	var weights := Regions.region_weights(world_x, world_z)
	var c := Color(0.0, 0.0, 0.0, 1.0)
	for id in weights.keys():
		var w: float = float(weights[id])
		if w <= 0.0:
			continue
		var rd = Regions.get_data(String(id))
		c.r += rd.tint.r * w
		c.g += rd.tint.g * w
		c.b += rd.tint.b * w
	return Color(c.r, c.g, c.b, 1.0)


# Build the height-mapped mesh for one chunk key.
# Returns { mesh, heights, n, step, half } — heights/n/step/half are reused
# by the caller for object placement so nothing is recomputed.
static func build_mesh(key: Vector2i,
		chunk_size: float, subdivisions: int) -> Dictionary:
	var n: int = subdivisions + 1
	var step: float = chunk_size / float(subdivisions)
	var half: float = chunk_size * 0.5
	# World-space origin of this chunk's (0,0) corner in the chunk grid.
	var origin_x: float = key.x * chunk_size
	var origin_z: float = key.y * chunk_size

	# Sample heights + tints at chunk-grid world positions so adjacent chunks
	# share edge values (seamless borders) AND share the same region-blend.
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	var tints := PackedColorArray()
	tints.resize(n * n)
	for j in range(n):
		for i in range(n):
			var wx := origin_x + i * step
			var wz := origin_z + j * step
			var idx := j * n + i
			heights[idx] = sample_height(wx, wz)
			tints[idx] = sample_tint(wx, wz)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(n):
		for i in range(n):
			var lx := float(i) * step - half
			var lz := float(j) * step - half
			var idx := j * n + i
			st.set_uv(Vector2(float(i) / subdivisions, float(j) / subdivisions))
			st.set_color(tints[idx])
			st.add_vertex(Vector3(lx, heights[idx], lz))
	# Winding: v00→v01→v10 and v01→v11→v10 both produce a +Y normal.
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
	return {
		"mesh": arr_mesh,
		"heights": heights,
		"n": n,
		"step": step,
		"half": half,
	}


# Assemble the StaticBody3D for one chunk: noise mesh + material + trimesh
# collision, named/grouped/positioned to the runtime contract. Shared by the
# runtime streamer and the editor bake so a baked scene is bit-identical to a
# streamed procedural chunk. Objects are NOT added here (the caller owns prop
# spawning + overlay merge). Returns { body, heights, n, step, half }.
static func build_chunk_body(key: Vector2i,
		chunk_size: float, subdivisions: int) -> Dictionary:
	var gen := build_mesh(key, chunk_size, subdivisions)
	var arr_mesh: ArrayMesh = gen["mesh"]
	var half: float = gen["half"]

	var body := StaticBody3D.new()
	body.name = "Chunk_%d_%d" % [key.x, key.y]
	# persistent so PackedScene.pack() (editor bake) stores the group too.
	body.add_to_group("terrain_chunk", true)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Mesh"
	mesh_inst.mesh = arr_mesh
	# Region tints live on vertex colours, multiplied by white albedo — the
	# StandardMaterial3D blend is what makes the boundary between regions read
	# as a smooth gradient instead of a chunk-aligned step.
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	mat.roughness = 1.0
	mat.metallic = 0.0
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)

	var coll := CollisionShape3D.new()
	coll.name = "Collision"
	coll.shape = arr_mesh.create_trimesh_shape()
	body.add_child(coll)

	# Centre the body so local vertices straddle the origin.
	body.position = Vector3(key.x * chunk_size + half, 0.0,
			key.y * chunk_size + half)
	return {
		"body": body,
		"heights": gen["heights"],
		"n": gen["n"],
		"step": gen["step"],
		"half": half,
	}

# Bake a fully editable starting scene for a bespoke chunk: the procedural
# body plus its deterministic props, all parented and owner-stamped so the
# tree can be PackedScene.pack()'d. Edges are correct by construction here;
# call lock_chunk_edges() again at save time after the mesh is hand-edited.
static func bake_chunk_scene(key: Vector2i,
		chunk_size: float, subdivisions: int,
		load_radius: int, placeholder_spawn_margin: float) -> StaticBody3D:
	var built := build_chunk_body(key, chunk_size, subdivisions)
	var body: StaticBody3D = built["body"]
	var objects := build_object_records(key, built["heights"], built["n"],
			built["step"], built["half"], load_radius,
			placeholder_spawn_margin)
	for idx in range(objects.size()):
		spawn_placeholder_object(body, objects[idx], idx)
	_stamp_owner(body, body)
	return body

static func _stamp_owner(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_stamp_owner(child, root)

# Re-snap the boundary vertex ring of an already-built (possibly hand-edited)
# grid chunk mesh back to the regional heightfield, so a bespoke scene chunk
# stays seamless against its procedural neighbours no matter what was sculpted
# inside. Assumes the mesh still has the n*n grid topology bake produced
# (sculpt interiors; do not add/remove vertices). Rebuilds normals, tangents
# and the trimesh collision. Mutates the body in place.
static func lock_chunk_edges(body: Node3D, key: Vector2i,
		chunk_size: float, _subdivisions: int) -> bool:
	var mesh_inst: MeshInstance3D = body.get_node_or_null("Mesh") as MeshInstance3D
	if mesh_inst == null or not (mesh_inst.mesh is ArrayMesh):
		push_warning("ChunkGen.lock_chunk_edges: no grid Mesh found")
		return false
	var src: ArrayMesh = mesh_inst.mesh
	var arrays: Array = src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty():
		push_warning("ChunkGen.lock_chunk_edges: mesh is not indexed")
		return false
	var half: float = chunk_size * 0.5
	var origin_x: float = key.x * chunk_size
	var origin_z: float = key.y * chunk_size
	# A grid vertex is on the chunk boundary iff its local x or z sits on the
	# ±half edge. Array-order independent — SurfaceTool.commit() doesn't
	# preserve insertion order, so we must key off geometry, not index.
	var eps: float = 0.001
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for vi in range(verts.size()):
		var v: Vector3 = verts[vi]
		var on_x_edge := absf(absf(v.x) - half) < eps
		var on_z_edge := absf(absf(v.z) - half) < eps
		var wx := origin_x + (v.x + half)
		var wz := origin_z + (v.z + half)
		if on_x_edge or on_z_edge:
			# local (x,z) → world: corner (-half,-half) maps to (origin_x, origin_z).
			v.y = sample_height(wx, wz)
		if uvs.size() == verts.size():
			st.set_uv(uvs[vi])
		# Re-paint region tint on edge verts too, so the seam blend reads.
		# Interior tints we preserve (the user may have authored a chunk that
		# manipulates colour) — but in v1 there's no sculpt UI for colour, so
		# both branches end up identical.
		if on_x_edge or on_z_edge:
			st.set_color(sample_tint(wx, wz))
		elif colors.size() == verts.size():
			st.set_color(colors[vi])
		else:
			st.set_color(sample_tint(wx, wz))
		st.add_vertex(v)
	for idx in indices:
		st.add_index(idx)
	st.generate_normals()
	st.generate_tangents()
	var locked: ArrayMesh = st.commit()
	mesh_inst.mesh = locked
	var coll: CollisionShape3D = body.get_node_or_null("Collision") as CollisionShape3D
	if coll != null:
		coll.shape = locked.create_trimesh_shape()
	return true

# Deterministic prop layout for a chunk key. Same key always produces the
# same records, so streaming and editor previews agree. Mirrors
# chunk_manager._ensure_chunk_data exactly: water tower (if any) is recorded
# first, then a hand-placed oasis (if any). RNG draw order must not change or
# previews diverge from the live game.
static func build_object_records(key: Vector2i, heights: PackedFloat32Array,
		n: int, step: float, half: float, load_radius: int,
		placeholder_spawn_margin: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var objects: Array = []
	if should_spawn_water_tower(key, load_radius):
		objects.append(_make_water_tower_record(rng, heights, n, step, half,
				placeholder_spawn_margin))
	# Curated settlements from POIRegistry (T2.2). A chunk may contain more
	# than one in principle (none currently do) — we spawn each in order.
	var chunk_size := step * float(n - 1)
	for settlement in POIRegistry.settlements_in_chunk(key, chunk_size):
		objects.append(_make_settlement_record(settlement, key, chunk_size,
				heights, n, step, half))
	return objects

static func _make_settlement_record(settlement: Dictionary, key: Vector2i,
		chunk_size: float, heights: PackedFloat32Array, n: int, step: float,
		half: float) -> Dictionary:
	# Resolve the curated world_pos into chunk-local coords. The chunk body
	# is positioned at (key * chunk_size + half), so local = world - that.
	var world_pos: Vector3 = settlement["world_pos"]
	var lx: float = world_pos.x - (key.x * chunk_size + half)
	var lz: float = world_pos.z - (key.y * chunk_size + half)
	var h := height_from_grid(heights, n, step, half, lx, lz)
	# Stable yaw per settlement id so rebuilds match (no RNG draw — keeps the
	# editor preview deterministic and free of order-sensitive coupling).
	var yaw := wrapf(float(hash(String(settlement["id"]))) * 0.001, -PI, PI)
	return {
		"type": "oasis",
		"subtype": String(settlement["oasis_subtype"]),
		"poi_id": String(settlement["id"]),
		"pos": Vector3(lx, h, lz),
		"yaw": yaw,
	}

static func should_spawn_water_tower(key: Vector2i, load_radius: int) -> bool:
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

static func _make_water_tower_record(rng: RandomNumberGenerator,
		heights: PackedFloat32Array, n: int, step: float, half: float,
		placeholder_spawn_margin: float) -> Dictionary:
	var lx := rng.randf_range(-half + placeholder_spawn_margin, half - placeholder_spawn_margin)
	var lz := rng.randf_range(-half + placeholder_spawn_margin, half - placeholder_spawn_margin)
	var h := height_from_grid(heights, n, step, half, lx, lz)
	return {
		"type": "water_tower",
		"pos": Vector3(lx, h, lz),
		"yaw": rng.randf_range(-PI, PI),
		"scale": 1.0,
	}

static func height_from_grid(heights: PackedFloat32Array, n: int, step: float,
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

# ── Placeholder prop node factories ─────────────────────────────────────────
# Node construction kept here so the editor preview builds props identically.

# Spawn one hand-authored overlay object. Arbitrary scene if scene_path is set,
# otherwise reuse the procedural placeholder factories so a previewed overlay
# object looks identical to a streamed one.
static func spawn_overlay_object(body: Node3D, obj: ChunkObject, idx: int) -> void:
	if obj == null:
		return
	if obj.scene_path != "":
		var ps: Resource = load(obj.scene_path)
		if ps == null or not (ps is PackedScene):
			push_warning("ChunkGen: overlay scene_path not a PackedScene: %s" % obj.scene_path)
			return
		var inst: Node = (ps as PackedScene).instantiate()
		inst.name = "Overlay_%03d" % idx
		if inst is Node3D:
			inst.position = obj.pos
			inst.rotation.y = obj.yaw
			inst.scale = Vector3.ONE * obj.scale
		body.add_child(inst)
		return
	spawn_placeholder_object(body, {
		"type": obj.type,
		"pos": obj.pos,
		"yaw": obj.yaw,
		"scale": obj.scale,
	}, idx)

static func spawn_placeholder_object(body: Node3D, obj: Dictionary, idx: int) -> void:
	var obj_type := String(obj.get("type", "rock"))
	if obj_type == "water_tower":
		var tower := WATER_TOWER_SCENE.instantiate()
		tower.name = "WaterTower_%03d" % idx
		tower.position = obj.get("pos", Vector3.ZERO)
		tower.rotation.y = float(obj.get("yaw", 0.0))
		body.add_child(tower)
		return
	if obj_type == "oasis":
		var oasis := OASIS_SCENE.instantiate()
		oasis.name = "Oasis_%03d" % idx
		# Set oasis_type before add_child so _ready propagates it to the
		# child Market in time (mirrors chunk_manager).
		oasis.set("oasis_type", String(obj.get("subtype", "mining")))
		oasis.position = obj.get("pos", Vector3.ZERO)
		oasis.rotation.y = float(obj.get("yaw", 0.0))
		body.add_child(oasis)
		return
	var root := StaticBody3D.new()
	root.name = "Placeholder_%03d_%s" % [idx, String(obj.get("type", "object"))]
	root.position = obj.get("pos", Vector3.ZERO)
	root.rotation.y = float(obj.get("yaw", 0.0))
	var object_scale := float(obj.get("scale", 1.0))
	match String(obj.get("type", "rock")):
		"crate":
			_add_placeholder_box(root, object_scale)
		"post":
			_add_placeholder_post(root, object_scale)
		_:
			_add_placeholder_rock(root, object_scale)
	body.add_child(root)

static func _add_placeholder_rock(root: StaticBody3D, object_scale: float) -> void:
	var radius := 0.7 * object_scale
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 1.3
	mesh.mesh = sphere
	mesh.position.y = radius * 0.55
	mesh.material_override = _placeholder_material(Color(0.23, 0.22, 0.2, 1.0))
	root.add_child(mesh)
	var coll := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	coll.shape = shape
	coll.position.y = radius
	root.add_child(coll)

static func _add_placeholder_box(root: StaticBody3D, object_scale: float) -> void:
	var size := Vector3(1.1, 0.9, 1.1) * object_scale
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position.y = size.y * 0.5
	mesh.material_override = _placeholder_material(Color(0.42, 0.29, 0.16, 1.0))
	root.add_child(mesh)
	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	coll.shape = shape
	coll.position.y = size.y * 0.5
	root.add_child(coll)

static func _add_placeholder_post(root: StaticBody3D, object_scale: float) -> void:
	var height := 2.2 * object_scale
	var radius := 0.18 * object_scale
	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	mesh.mesh = cylinder
	mesh.position.y = height * 0.5
	mesh.material_override = _placeholder_material(Color(0.18, 0.3, 0.18, 1.0))
	root.add_child(mesh)
	var coll := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	coll.shape = shape
	coll.position.y = height * 0.5
	root.add_child(coll)

static func _placeholder_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat
