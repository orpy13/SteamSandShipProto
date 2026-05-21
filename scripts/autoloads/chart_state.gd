extends Node
##
## CHART STATE (autoload) — crew-shared navigation state (Tier 2, T2.3).
##
## Host-authoritative. Tracks discovered POIs, player-placed markers, the
## bearing-line array used for triangulation (Slice B), the most recent
## position fix (DR reset point), and the dead-reckoning toggle.
##
## Replication mirrors `ship_controller.cargo` exactly: each mutator is an
## `any_peer / call_local / reliable` RPC; the host validates the sender id
## (∈ {0, 1}), updates locally, and broadcasts via a `_set_*` RPC. Joining
## peers receive a single-shot snapshot from `NetworkManager.notify_chart_state`.
##
## ChartState lives long — autoload — so a session that ends back in the lobby
## leaves stale state behind. Call `reset_session_state()` from the host's
## new-session entry point if you want a clean start. (Not wired in v1; the
## lobby-on-disconnect flow re-uses the autoload as-is.)
##

signal markers_changed
signal discovered_changed
signal bearing_lines_changed
signal last_fix_changed
signal dr_mode_changed

## Cap so a runaway marker spam doesn't flood the synchroniser.
const MAX_MARKERS := 16

# id (String) → true. Membership-only; the value is unused.
var discovered_pois: Dictionary = {}
# [{ world_pos: Vector3, label: String, color: Color, placed_by: int }]
var markers: Array = []
# Slice-B placeholder. [{ poi_id: String, bearing_deg: float, placed_by: int }]
var bearing_lines: Array = []
# {} when none; otherwise { world_pos: Vector3, time: float }.
var last_fix: Dictionary = {}
# When false, the chart shows no live position estimate — only the last fix
# and any bearings the crew draws. Hard mode.
var dr_enabled: bool = true


func _ready() -> void:
	_seed_default_discovery()


## All curated settlements are "main POIs" — pre-marked at session start.
## Called by _ready and apply_snapshot.
func _seed_default_discovery() -> void:
	for s in POIRegistry.all_settlements():
		discovered_pois[String(s["id"])] = true


func is_discovered(poi_id: String) -> bool:
	return discovered_pois.has(poi_id)


## Wipe shared state and re-seed defaults. Host calls this when starting a
## new session; clients sync via the apply_snapshot path on join.
func reset_session_state() -> void:
	markers.clear()
	bearing_lines.clear()
	last_fix.clear()
	discovered_pois.clear()
	_seed_default_discovery()
	discovered_changed.emit()
	markers_changed.emit()
	bearing_lines_changed.emit()
	last_fix_changed.emit()


# ── Markers ──────────────────────────────────────────────────────────────────

## Any peer can request; host validates the cap, stamps `placed_by`, and
## broadcasts the new list. Sender id 0 (host-self) is normalised to the
## host's peer id (always 1) so the marker is attributed correctly.
@rpc("any_peer", "call_local", "reliable")
func request_add_marker(world_pos: Vector3, label: String, color: Color) -> void:
	if not multiplayer.is_server():
		return
	if markers.size() >= MAX_MARKERS:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var entry := {
		"world_pos": world_pos,
		"label": label,
		"color": color,
		"placed_by": sender,
	}
	var next := markers.duplicate()
	next.append(entry)
	_set_markers.rpc(next)


@rpc("any_peer", "call_local", "reliable")
func request_remove_marker(idx: int) -> void:
	if not multiplayer.is_server():
		return
	if idx < 0 or idx >= markers.size():
		return
	var next := markers.duplicate()
	next.remove_at(idx)
	_set_markers.rpc(next)


@rpc("any_peer", "call_local", "reliable")
func request_clear_markers() -> void:
	if not multiplayer.is_server():
		return
	_set_markers.rpc([])


@rpc("any_peer", "call_local", "reliable")
func _set_markers(new_value: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	markers = new_value.duplicate(true)
	markers_changed.emit()


# ── DR mode ──────────────────────────────────────────────────────────────────

@rpc("any_peer", "call_local", "reliable")
func request_set_dr_enabled(enabled: bool) -> void:
	if not multiplayer.is_server():
		return
	_set_dr_enabled.rpc(enabled)


@rpc("any_peer", "call_local", "reliable")
func _set_dr_enabled(enabled: bool) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	dr_enabled = enabled
	dr_mode_changed.emit()


# ── Last fix ─────────────────────────────────────────────────────────────────

## Host-only entry point: stamp a new position fix. Triangulation (Slice B)
## and landmark arrival both call this.
func host_set_last_fix(world_pos: Vector3, time: float) -> void:
	if not multiplayer.is_server():
		return
	_set_last_fix.rpc(world_pos, time)


@rpc("any_peer", "call_local", "reliable")
func _set_last_fix(world_pos: Vector3, time: float) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	last_fix = { "world_pos": world_pos, "time": time }
	last_fix_changed.emit()


# ── Discovery ────────────────────────────────────────────────────────────────

## Host-only entry point. Slice B: telescope spot + landmark arrival both
## call this. Idempotent (silently skips already-discovered).
func host_mark_discovered(poi_id: String) -> void:
	if not multiplayer.is_server():
		return
	if discovered_pois.has(poi_id):
		return
	_set_discovered.rpc(poi_id)


@rpc("any_peer", "call_local", "reliable")
func _set_discovered(poi_id: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	discovered_pois[poi_id] = true
	discovered_changed.emit()


# ── Bearing lines (Slice B writes; UI reads in Slice A) ──────────────────────

@rpc("any_peer", "call_local", "reliable")
func request_clear_bearing_lines() -> void:
	if not multiplayer.is_server():
		return
	_set_bearing_lines.rpc([])


@rpc("any_peer", "call_local", "reliable")
func _set_bearing_lines(new_value: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	bearing_lines = new_value.duplicate(true)
	bearing_lines_changed.emit()


# ── Peer-join snapshot ───────────────────────────────────────────────────────

## Host packs all crew-shared state for a joining peer.
func host_snapshot() -> Dictionary:
	return {
		"discovered": discovered_pois.keys(),
		"markers": markers.duplicate(true),
		"bearing_lines": bearing_lines.duplicate(true),
		"last_fix": last_fix.duplicate(true),
		"dr_enabled": dr_enabled,
	}


## Client replaces local state with the host's snapshot. Emits every signal
## so any UI bound to this state redraws once.
func apply_snapshot(snap: Dictionary) -> void:
	discovered_pois.clear()
	for id in snap.get("discovered", []):
		discovered_pois[String(id)] = true
	markers = (snap.get("markers", []) as Array).duplicate(true)
	bearing_lines = (snap.get("bearing_lines", []) as Array).duplicate(true)
	last_fix = (snap.get("last_fix", {}) as Dictionary).duplicate(true)
	dr_enabled = bool(snap.get("dr_enabled", true))
	discovered_changed.emit()
	markers_changed.emit()
	bearing_lines_changed.emit()
	last_fix_changed.emit()
	dr_mode_changed.emit()
