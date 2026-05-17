extends SceneTree

# Headless chunk bake tool — the shared core the phase-4 editor plugin/dock
# will wrap behind a button. Bakes the procedural chunk at (x, z) into an
# editable scene, edge-locks it, saves res://chunks/scenes/chunk_x_z.tscn,
# and points the registry at it in "scene" mode.
#
# Usage:
#   godot --headless --script scripts/tools/bake_chunk.gd -- <x> <z>
#
# Noise/grid params mirror the chunk_manager.gd export defaults. If you change
# those in the scene, pass matching values here (kept simple on purpose; the
# phase-4 dock will read them off the live ChunkManager node instead).

const CHUNK_SIZE := 80.0
const SUBDIVISIONS := 16
const HEIGHT_SCALE := 3.5
const NOISE_SEED := 1337
const NOISE_FREQUENCY := 0.006
const NOISE_OCTAVES := 2
const NOISE_LACUNARITY := 2.0
const NOISE_GAIN := 0.5
const LOAD_RADIUS := 3
const SPAWN_MARGIN := 8.0

func _init() -> void:
	var args := _user_args()
	if args.size() < 2:
		push_error("bake_chunk: expected <x> <z> after --")
		quit(1)
		return
	var key := Vector2i(int(args[0]), int(args[1]))
	var noise := ChunkGen.make_noise(NOISE_SEED, NOISE_FREQUENCY,
			NOISE_OCTAVES, NOISE_LACUNARITY, NOISE_GAIN)

	var body := ChunkGen.bake_chunk_scene(noise, key, CHUNK_SIZE, SUBDIVISIONS,
			HEIGHT_SCALE, LOAD_RADIUS, SPAWN_MARGIN)
	# save_scene_chunk edge-locks, packs and registers. Edge-lock is a no-op on
	# a fresh bake (edges already match) but exercises the editor save path.
	var scene_path := ChunkAuthoring.save_scene_chunk(body, noise, key,
			CHUNK_SIZE, SUBDIVISIONS, HEIGHT_SCALE)
	body.free()
	if scene_path == "":
		push_error("bake_chunk: save failed")
		quit(1)
		return
	print("bake_chunk: wrote %s and registered (%d,%d) as scene"
			% [scene_path, key.x, key.y])
	quit(0)

func _user_args() -> PackedStringArray:
	return OS.get_cmdline_user_args()
