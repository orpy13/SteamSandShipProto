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


# ── Bearing lines + triangulation fix ────────────────────────────────────────

## Crew member calls this from the chart UI after the spotter at the
## telescope calls out (POI, bearing) over voice chat. Host stores it; chart
## panels re-render the line from `poi.world_pos` along the spotter's
## back-azimuth.
@rpc("any_peer", "call_local", "reliable")
func request_add_bearing(poi_id: String, bearing_deg: float) -> void:
	if not multiplayer.is_server():
		return
	var poi := POIRegistry.get_settlement(poi_id)
	if poi.is_empty():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	var entry := {
		"poi_id": poi_id,
		"bearing_deg": wrapf(bearing_deg, 0.0, 360.0),
		"placed_by": sender,
	}
	var next := bearing_lines.duplicate()
	next.append(entry)
	_set_bearing_lines.rpc(next)


@rpc("any_peer", "call_local", "reliable")
func request_remove_bearing_at(idx: int) -> void:
	if not multiplayer.is_server():
		return
	if idx < 0 or idx >= bearing_lines.size():
		return
	var next := bearing_lines.duplicate()
	next.remove_at(idx)
	_set_bearing_lines.rpc(next)


@rpc("any_peer", "call_local", "reliable")
func request_clear_bearing_lines() -> void:
	if not multiplayer.is_server():
		return
	_set_bearing_lines.rpc([])


## Take a position fix from the two most recent bearing lines. Stamps
## `last_fix` at the intersection (which resets DR error). Bearing lines are
## intentionally left in place — the user requested they stay until manually
## cleared (more bearings can refine a fix visually).
@rpc("any_peer", "call_local", "reliable")
func request_take_fix() -> void:
	if not multiplayer.is_server():
		return
	if bearing_lines.size() < 2:
		return
	var fix = _compute_fix_from_two_latest()
	if fix == null:
		return
	_set_last_fix.rpc(fix, GameState.world_time())


@rpc("any_peer", "call_local", "reliable")
func _set_bearing_lines(new_value: Array) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	bearing_lines = new_value.duplicate(true)
	bearing_lines_changed.emit()


## Intersect the two newest bearing lines. Each line passes through its POI
## along the spotter's BACK-azimuth (bearing + 180°). Returns null when the
## lines are parallel within tolerance.
func _compute_fix_from_two_latest():
	var n: int = bearing_lines.size()
	var b1: Dictionary = bearing_lines[n - 2]
	var b2: Dictionary = bearing_lines[n - 1]
	var poi1 := POIRegistry.get_settlement(String(b1["poi_id"]))
	var poi2 := POIRegistry.get_settlement(String(b2["poi_id"]))
	if poi1.is_empty() or poi2.is_empty():
		return null
	var p1: Vector3 = poi1["world_pos"]
	var p2: Vector3 = poi2["world_pos"]
	# +Z is north; bearing 0 = +Z, 90 = +X. Forward direction from POI back
	# along the line of sight = (sin(β+180), cos(β+180)) = (-sinβ, -cosβ).
	var t1 := deg_to_rad(float(b1["bearing_deg"]))
	var t2 := deg_to_rad(float(b2["bearing_deg"]))
	var d1 := Vector3(-sin(t1), 0.0, -cos(t1))
	var d2 := Vector3(-sin(t2), 0.0, -cos(t2))
	# Solve p1 + a*d1 = p2 + b*d2 in (x, z). Matrix [d1.x, -d2.x; d1.z, -d2.z].
	var det := d1.x * (-d2.z) - (-d2.x) * d1.z
	if absf(det) < 0.0001:
		return null                            # parallel
	var dx := p2.x - p1.x
	var dz := p2.z - p1.z
	var a := (dx * (-d2.z) - (-d2.x) * dz) / det
	return Vector3(p1.x + a * d1.x, 0.0, p1.z + a * d1.z)


# ── Dead reckoning ───────────────────────────────────────────────────────────
# Deterministic — every peer computes the same drift from shared world_time
# and shared last_fix. The drift is intentionally non-zero so the chart's DR
# estimate visibly diverges from the real position as time since the last
# fix grows, motivating a fresh triangulation. Hard mode (`dr_enabled =
# false`) hides the estimate entirely — only the static last fix remains.

## Drifted position estimate at `now_time`. Returns `current_ship_pos` when
## no fix has been taken yet (no error to integrate from).
func dr_estimate(now_time: float, current_ship_pos: Vector3) -> Vector3:
	if last_fix.is_empty():
		return current_ship_pos
	var elapsed := maxf(0.0, now_time - float(last_fix["time"]))
	if elapsed <= 0.0:
		return current_ship_pos
	var freq := 0.015
	# Seed offset per-fix so consecutive fixes don't share the same drift
	# phase — a re-fix in the same spot still has fresh-looking error.
	var pos_seed: Vector3 = last_fix["world_pos"]
	var seed_off := float(int(hash(str(pos_seed))) % 1000) * 0.01
	var mag := minf(elapsed * 0.4, 150.0)   # cap at 150 m so it stays usable
	var dx := sin(elapsed * freq + seed_off) * mag
	var dz := cos(elapsed * freq * 1.3 + seed_off) * mag
	return current_ship_pos + Vector3(dx, 0.0, dz)


## Uncertainty radius (metres) shown as a circle around the DR estimate.
func dr_uncertainty_radius(now_time: float) -> float:
	if last_fix.is_empty():
		return 0.0
	var elapsed := maxf(0.0, now_time - float(last_fix["time"]))
	return clampf(elapsed * 0.7, 0.0, 200.0)


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
