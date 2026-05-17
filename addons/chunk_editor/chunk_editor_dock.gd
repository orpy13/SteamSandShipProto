@tool
extends VBoxContainer

# Bespoke-chunk authoring dock. Pure UI + glue — every operation that must
# stay consistent with the runtime is delegated to ChunkGen / ChunkAuthoring.
#
# Workflow:
#   1. Open the scene you want to author against (any scene; the chunk is
#      added as a temporary preview node under its root).
#   2. Pick chunk X / Z and a mode, press Load.
#   3. Overlay mode: add props (Add Prop) / delete baseline props in the
#      scene tree — the mesh is read-only and ignored on save.
#      Full scene mode: sculpt the mesh and edit props freely.
#   4. Press Save. Edges are auto-locked for full scenes; the registry is
#      updated. Delete the preview node when done.

var plugin: EditorPlugin

const _PARAM_DEFS := [
	["chunk_size", 80.0, false],
	["subdivisions", 16.0, true],
	["height_scale", 3.5, false],
	["noise_seed", 1337.0, true],
	["noise_frequency", 0.006, false],
	["noise_octaves", 2.0, true],
	["noise_lacunarity", 2.0, false],
	["load_radius", 3.0, true],
	["placeholder_spawn_margin", 8.0, false],
]
const _PROP_TYPES := ["rock", "crate", "post", "water_tower"]

var _spin: Dictionary = {}
var _x_spin: SpinBox
var _z_spin: SpinBox
var _mode: OptionButton
var _prop_type: OptionButton
var _status: Label

var _preview: Node3D = null
var _key: Vector2i
var _is_scene_mode := false
var _baseline := 0
var _noise: FastNoiseLite
var _added_counter := 1000

var _host: VBoxContainer

func _ready() -> void:
	if get_child_count() > 0:
		return
	custom_minimum_size = Vector2(220, 0)
	# Scroll wrapper so the buttons are reachable at any dock height.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_host = VBoxContainer.new()
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_host)

	_add_label("Bespoke Chunk Editor")

	var coord := HBoxContainer.new()
	_x_spin = _make_spin(-9999, 9999, 1.0, 0.0)
	_z_spin = _make_spin(-9999, 9999, 1.0, 0.0)
	coord.add_child(_labelled("X", _x_spin))
	coord.add_child(_labelled("Z", _z_spin))
	_host.add_child(coord)

	_mode = OptionButton.new()
	_mode.add_item("Overlay (props only)")
	_mode.add_item("Full scene (mesh + props)")
	_host.add_child(_mode)

	# Actions first so they are always visible without scrolling.
	var load_btn := Button.new()
	load_btn.text = "Load chunk"
	load_btn.pressed.connect(_on_load)
	_host.add_child(load_btn)

	var add_row := HBoxContainer.new()
	_prop_type = OptionButton.new()
	for t in _PROP_TYPES:
		_prop_type.add_item(t)
	add_row.add_child(_prop_type)
	var add_btn := Button.new()
	add_btn.text = "Add Prop"
	add_btn.pressed.connect(_on_add_prop)
	add_row.add_child(add_btn)
	_host.add_child(add_row)

	var save_btn := Button.new()
	save_btn.text = "Save bespoke chunk"
	save_btn.pressed.connect(_on_save)
	_host.add_child(save_btn)

	var clear_btn := Button.new()
	clear_btn.text = "Clear preview"
	clear_btn.pressed.connect(_clear_preview)
	_host.add_child(clear_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 48)
	_host.add_child(_status)
	_set_status("Idle.")

	_host.add_child(HSeparator.new())
	var params_fold := _add_label("Params (match ChunkManager)")
	params_fold.add_theme_font_size_override("font_size", 10)
	for d in _PARAM_DEFS:
		var sp := _make_spin(-100000, 100000,
				(1.0 if d[2] else 0.0001), d[1])
		_spin[d[0]] = sp
		_host.add_child(_labelled(d[0], sp))

# ── UI helpers ──────────────────────────────────────────────────────────────
func _add_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	_host.add_child(l)
	return l

func _labelled(text: String, ctrl: Control) -> Control:
	var box := VBoxContainer.new()
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 10)
	box.add_child(l)
	box.add_child(ctrl)
	return box

func _make_spin(lo: float, hi: float, stp: float, val: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = stp
	if stp < 1.0:
		s.custom_arrow_step = 0.0
	s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg
	print("[ChunkEditor] ", msg)

func _p(name: String) -> float:
	return (_spin[name] as SpinBox).value

func _edited_root() -> Node:
	if plugin == null:
		return null
	return plugin.get_editor_interface().get_edited_scene_root()

func _build_noise() -> FastNoiseLite:
	return ChunkGen.make_noise(int(_p("noise_seed")), _p("noise_frequency"),
			int(_p("noise_octaves")), _p("noise_lacunarity"), 0.5)

func _stamp(node: Node, root: Node) -> void:
	for c in node.get_children():
		c.owner = root
		_stamp(c, root)

func _select(node: Node) -> void:
	var sel := plugin.get_editor_interface().get_selection()
	sel.clear()
	sel.add_node(node)

# ── Actions ─────────────────────────────────────────────────────────────────
func _on_load() -> void:
	var root := _edited_root()
	if root == null:
		_set_status("Open a scene first — the chunk is previewed under its root.")
		return
	_clear_preview()
	_key = Vector2i(int(_x_spin.value), int(_z_spin.value))
	_is_scene_mode = _mode.selected == 1
	_noise = _build_noise()
	var cs := _p("chunk_size")
	var sub := int(_p("subdivisions"))
	var hs := _p("height_scale")

	if _is_scene_mode:
		_preview = ChunkGen.bake_chunk_scene(_noise, _key, cs, sub, hs,
				int(_p("load_radius")),
				_p("placeholder_spawn_margin"))
		_baseline = 0
	else:
		var built := ChunkGen.build_chunk_body(_noise, _key, cs, sub, hs)
		_preview = built["body"]
		var records := ChunkGen.build_object_records(_key, built["heights"],
				built["n"], built["step"], built["half"],
				int(_p("load_radius")),
				_p("placeholder_spawn_margin"))
		for idx in range(records.size()):
			ChunkGen.spawn_placeholder_object(_preview, records[idx], idx)
			var node := _preview.get_child(_preview.get_child_count() - 1)
			node.set_meta("chunk_proc_idx", idx)
			node.set_meta("chunk_type", String(records[idx].get("type", "rock")))
		_baseline = records.size()

	_preview.name = "ChunkPreview_%d_%d" % [_key.x, _key.y]
	# build_chunk_body positions the body at its grid world cell (e.g. ~1 km
	# out for chunk 12,12). Author at the scene origin instead — runtime
	# re-applies the grid position, and saved data is all chunk-local / keyed.
	_preview.position = Vector3.ZERO
	root.add_child(_preview)
	_preview.owner = root
	_stamp(_preview, root)
	_select(_preview)
	var m := "scene" if _is_scene_mode else "overlay"
	_set_status("Loaded (%d,%d) as %s. Edit, then Save." % [_key.x, _key.y, m])

func _on_add_prop() -> void:
	if not _preview_valid():
		_set_status("Load a chunk first.")
		return
	var t: String = _PROP_TYPES[_prop_type.selected]
	ChunkGen.spawn_placeholder_object(_preview, {
		"type": t, "pos": Vector3.ZERO, "yaw": 0.0, "scale": 1.0,
	}, _added_counter)
	_added_counter += 1
	var node := _preview.get_child(_preview.get_child_count() - 1)
	node.set_meta("chunk_type", t)
	_stamp(_preview, _edited_root())
	_select(node)
	_set_status("Added '%s' at chunk origin — move it into place." % t)

func _on_save() -> void:
	if not _preview_valid():
		_set_status("Nothing to save — Load a chunk first.")
		return
	var path := ""
	if _is_scene_mode:
		path = ChunkAuthoring.save_scene_chunk(_preview, _noise, _key,
				_p("chunk_size"), int(_p("subdivisions")), _p("height_scale"))
	else:
		path = ChunkAuthoring.save_overlay(_key, _preview, _baseline)
	if path == "":
		_set_status("Save FAILED — see Output for details.")
		return
	plugin.get_editor_interface().get_resource_filesystem().scan()
	_set_status("Saved %s and updated registry. Safe to Clear preview." % path)

func _preview_valid() -> bool:
	return _preview != null and is_instance_valid(_preview)

func _clear_preview() -> void:
	if _preview_valid():
		_preview.get_parent().remove_child(_preview)
		_preview.free()
	_preview = null
