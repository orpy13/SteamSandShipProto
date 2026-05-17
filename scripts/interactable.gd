class_name Interactable
extends Area3D
##
## Base class for everything the interact ray can hit (helm, coal bunker,
## boiler firebox, water tower).
##
## Conventions for subclasses:
##   • Root must be an Area3D on collision layer 2 (the interact ray's mask).
##   • Override `interact(peer_id)` and gate the body with
##     `if not multiplayer.is_server(): return` so only the host actually
##     validates and applies the effect.
##   • Broadcast any side-effects via `@rpc("authority", "call_local", "reliable")`
##     so every peer's view stays in sync.
##

@export var prompt_text: String = "Press E to interact"

signal interacted(peer_id: int)


## Base hook — subclasses should call `super(peer_id)` after their own checks
## pass so anyone watching the `interacted` signal sees the success.
func interact(peer_id: int) -> void:
	interacted.emit(peer_id)


## Context-aware prompt. The default returns the static `prompt_text`; override
## in subclasses when the message depends on the player approaching (e.g. the
## deck gun shows "load clip" if the player is carrying one, "leave the gun"
## if they're already manning it, otherwise "man the gun").
func get_prompt(_player: Node) -> String:
	return prompt_text
