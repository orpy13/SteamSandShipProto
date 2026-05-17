@tool
extends EditorPlugin

const DockScript := preload("res://addons/chunk_editor/chunk_editor_dock.gd")

var _dock: Control

func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.plugin = self
	_dock.name = "Chunks"
	add_control_to_dock(DOCK_SLOT_LEFT_BR, _dock)

func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.free()
		_dock = null
