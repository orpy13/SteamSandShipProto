extends Control
##
## LOBBY — pre-session UI. Host/Join forms plus a live status line wired to
## NetworkManager. Hidden by main.gd as soon as a session starts.
##

@onready var _name_edit: LineEdit = $Panel/VBox/NameEdit
@onready var _ip_edit: LineEdit = $Panel/VBox/IPEdit
@onready var _port_edit: LineEdit = $Panel/VBox/PortEdit
@onready var _host_button: Button = $Panel/VBox/HostButton
@onready var _join_button: Button = $Panel/VBox/JoinButton
@onready var _status: Label = $Panel/VBox/StatusLabel


## Wire buttons and let NetworkManager events update the status label.
func _ready() -> void:
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	NetworkManager.server_started.connect(func(): set_status("Hosting — awaiting crew…"))
	NetworkManager.connection_succeeded.connect(func(): set_status("Connected!"))
	NetworkManager.connection_failed.connect(set_status)


## Public — main.gd calls this when reverting to lobby after a failure.
func set_status(text: String) -> void:
	_status.text = text


## Read the form and start hosting. Empty name → "Captain"; bad port → default.
func _on_host_pressed() -> void:
	var pname := _name_edit.text.strip_edges()
	if pname.is_empty():
		pname = "Captain"
	var port := int(_port_edit.text)
	if port <= 0:
		port = NetworkManager.DEFAULT_PORT
	set_status("Starting server…")
	NetworkManager.host_game(pname, port)


## Read the form and dial the host. Empty name → "Crew"; empty IP → localhost.
func _on_join_pressed() -> void:
	var pname := _name_edit.text.strip_edges()
	if pname.is_empty():
		pname = "Crew"
	var ip := _ip_edit.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var port := int(_port_edit.text)
	if port <= 0:
		port = NetworkManager.DEFAULT_PORT
	set_status("Connecting to %s:%d…" % [ip, port])
	NetworkManager.join_game(pname, ip, port)
