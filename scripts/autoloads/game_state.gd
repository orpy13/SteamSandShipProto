extends Node
##
## GAME STATE (autoload) — global session-level state.
##
## Currently minimal: tracks which UI phase we're in and the local player's
## chosen name. Originally also held shared resources like fuel; those moved
## into SteamPlant on the Ship. Add new cross-scene globals here rather than
## scattering autoloads.
##

signal phase_changed(new_phase: String)

# "lobby" before a session is established; "playing" after.
var current_phase: String = "lobby"

# The name the local player entered on the lobby screen. Stamped in
# NetworkManager.host_game / join_game.
var local_player_name: String = "Player"

# ── Shared world clock (set by NetworkManager) ───────────────────────────────
# `world_epoch` is a Unix timestamp captured by the host at session start and
# replicated once to every peer. `weather_seed` seeds the deterministic storm
# schedule. Both 0 until a session establishes them; consumers fall back to a
# local clock / fixed seed so the cycle still runs solo in the editor.
#
# Determinism model: every peer computes time-of-day and storm state locally
# from (now - world_epoch). No per-frame replication — see day_night_cycle.gd
# and weather_system.gd. Assumes roughly synced wall clocks (LAN co-op); a
# host-correction RPC can be added later if drift becomes visible.
var world_epoch: float = 0.0
var weather_seed: int = 0


## Seconds since the shared epoch. Falls back to a process-local clock when no
## epoch has been set yet (solo editor runs / pre-session), so visuals still
## animate instead of freezing at t=0.
func world_time() -> float:
	if world_epoch <= 0.0:
		return Time.get_ticks_msec() / 1000.0
	return Time.get_unix_time_from_system() - world_epoch


## Update the phase and notify listeners (currently just main.gd).
func set_phase(p: String) -> void:
	current_phase = p
	phase_changed.emit(p)
