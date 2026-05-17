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


## Update the phase and notify listeners (currently just main.gd).
func set_phase(p: String) -> void:
	current_phase = p
	phase_changed.emit(p)
