extends Node
##
## AUDIO MANAGER (autoload) — central place for one-shot sound effects.
##
## Currently just `play_sfx`. Future work: ambient loops, mixer buses,
## positional 3D variants. Keep it as an autoload so interactables can call
## `AudioManager.play_sfx(...)` from anywhere without holding a reference.
##


## Spawn an AudioStreamPlayer, play the given stream once, then auto-free.
## Returns immediately — fire-and-forget.
func play_sfx(stream: AudioStream) -> void:
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()
