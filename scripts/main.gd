extends Node
##
## MAIN — the entry-point scene controller.
##
## Owns the top-level wiring: shows the Lobby until a session is established,
## then swaps to the HUD. Listens to NetworkManager for session events and
## hands the HUD a reference to the Ship for its speed display.
##

@onready var _lobby: Control = $UILayer/Lobby
@onready var _hud: Control = $UILayer/HUD
@onready var _ship: CharacterBody3D = $Ship
@onready var _ui_layer: CanvasLayer = $UILayer
var _debug_panel: DebugPanel = null


## Wire up NetworkManager → UI transitions and give the HUD its ship reference.
func _ready() -> void:
	_hud.visible = false
	_lobby.visible = true
	NetworkManager.server_started.connect(_on_session_started)
	NetworkManager.connection_succeeded.connect(_on_session_started)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	if _hud.has_method("bind_ship"):
		_hud.bind_ship(_ship)
	# Debug/god-mode overlay (F1). Spawned on every peer so the autoload flag
	# stays in sync, but only the host can toggle it on (see DebugPanel).
	_debug_panel = DebugPanel.new()
	_debug_panel.name = "DebugPanel"
	_ui_layer.add_child(_debug_panel)


## Hide the lobby and show the HUD once we have a live session — host start
## and successful client connect both land here.
func _on_session_started() -> void:
	_lobby.visible = false
	_hud.visible = true
	GameState.set_phase("playing")


## Bring the lobby back with an error message if the connection drops.
func _on_connection_failed(reason: String) -> void:
	_lobby.visible = true
	_hud.visible = false
	# Player controllers capture the mouse; the lobby needs it back or you
	# can't click Host/Join after a drop or an all-crew-dead run end.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _lobby.has_method("set_status"):
		_lobby.set_status(reason)
