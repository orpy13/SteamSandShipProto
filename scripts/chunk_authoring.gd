class_name ChunkAuthoring
extends RefCounted

# Authoring-side persistence shared by the headless bake tool and the editor
# plugin/dock. All editor/runtime divergence risk stays out of the UI layer:
# the dock just collects input and calls these.

const REGISTRY_PATH := "res://chunks/registry.tres"
const SCENES_DIR := "res://chunks/scenes"
const OVERLAYS_DIR := "res://chunks/overlays"

static func key_str(key: Vector2i) -> String:
	return "%d,%d" % [key.x, key.y]

static func _ensure_dir(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

static func load_or_make_registry() -> ChunkRegistry:
	if ResourceLoader.exists(REGISTRY_PATH):
		var r: Resource = load(REGISTRY_PATH)
		if r is ChunkRegistry:
			return r
	return ChunkRegistry.new()

# Merge one entry, preserving every other registered chunk.
static func register_entry(key: Vector2i, mode: String, path: String) -> int:
	var reg := load_or_make_registry()
	reg.entries[key_str(key)] = {"mode": mode, "path": path}
	_ensure_dir(REGISTRY_PATH.get_base_dir())
	return ResourceSaver.save(reg, REGISTRY_PATH)

# Tier-1: edge-lock, pack a self-owned duplicate, save, register as "scene".
# Duplicating decouples the saved file from whatever scene currently owns the
# preview node in the editor.
static func save_scene_chunk(body: Node3D, noise: FastNoiseLite, key: Vector2i,
		chunk_size: float, subdivisions: int, height_scale: float) -> String:
	ChunkGen.lock_chunk_edges(body, noise, key, chunk_size, subdivisions,
			height_scale)
	var dup: Node3D = body.duplicate()
	ChunkGen._stamp_owner(dup, dup)
	var packed := PackedScene.new()
	if packed.pack(dup) != OK:
		dup.free()
		push_error("ChunkAuthoring: pack failed for %s" % key_str(key))
		return ""
	dup.free()
	_ensure_dir(SCENES_DIR)
	var path := "%s/chunk_%d_%d.tscn" % [SCENES_DIR, key.x, key.y]
	if ResourceSaver.save(packed, path) != OK:
		push_error("ChunkAuthoring: scene save failed for %s" % path)
		return ""
	register_entry(key, "scene", path)
	return path

# Tier-2: diff the preview's prop children against the procedural baseline and
# write a ChunkOverlay. Baseline props carry meta "chunk_proc_idx"; anything
# without it (and with a known type or scene) is a hand-added object.
static func save_overlay(key: Vector2i, body: Node3D,
		baseline_count: int) -> String:
	var present := {}
	for c in body.get_children():
		if c.has_meta("chunk_proc_idx"):
			present[int(c.get_meta("chunk_proc_idx"))] = true
	var removed := PackedInt32Array()
	for idx in range(baseline_count):
		if not present.has(idx):
			removed.append(idx)
	var added: Array = []
	for c in body.get_children():
		if c.has_meta("chunk_proc_idx"):
			continue
		if c.name == "Mesh" or c.name == "Collision":
			continue  # the terrain body itself, never an overlay prop
		var co := _node_to_chunk_object(c)
		if co != null:
			added.append(co)
		else:
			push_warning("ChunkAuthoring: skipped un-serialisable added node '%s' (no scene_file_path or chunk_type meta)" % c.name)
	var ov := ChunkOverlay.new()
	ov.removed = removed
	ov.added = added
	_ensure_dir(OVERLAYS_DIR)
	var path := "%s/chunk_%d_%d.tres" % [OVERLAYS_DIR, key.x, key.y]
	if ResourceSaver.save(ov, path) != OK:
		push_error("ChunkAuthoring: overlay save failed for %s" % path)
		return ""
	register_entry(key, "overlay", path)
	return path

static func _node_to_chunk_object(c: Node) -> ChunkObject:
	if not (c is Node3D):
		return null
	var n3: Node3D = c
	var co := ChunkObject.new()
	co.pos = n3.position
	co.yaw = n3.rotation.y
	co.scale = n3.scale.x
	if n3.scene_file_path != "":
		co.scene_path = n3.scene_file_path
		return co
	if n3.has_meta("chunk_type"):
		co.type = String(n3.get_meta("chunk_type"))
		return co
	return null
